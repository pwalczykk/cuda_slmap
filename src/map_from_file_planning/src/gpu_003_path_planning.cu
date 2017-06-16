#include "../include/gpu_003_path_planning.cuh"

__global__ void pathPlanningKernel(
    GpuPath* dev_paths,
    int16_t *costmap,
    const int map_x,
    const int map_y,
    const GpuPathPoint odom,
    const GpuPathPoint goal,
    const int sampling,
    const int max_iteration,
    const int min_division_length,
    const int global_seed,
    float *dev_debug
)
{
    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    int idy = blockDim.y * blockIdx.y + threadIdx.y;
    int tid = idy + idx * gridDim.y * blockDim.y;

    int bid = blockIdx.x * gridDim.y + blockIdx.y;
    int sid = threadIdx.x * blockDim.y + threadIdx.y;

    int threads_no = blockDim.x * blockDim.y;

    // int local_seed = global_seed + 0xffffffffffffff / (tid+1);
    uint32_t local_seed = global_seed + tid * 0xffff;

    // Shared memory allocation
    __shared__ GpuPath initial_path;
    __shared__ GpuPath divided_path;
    // __shared__ GpuPath mutated_path;
    __shared__ GpuPathPoint new_points_buff[GPU_PATH_MAX_SIZE];
    __shared__ uint32_t new_points_costs[PLANNER_THREADS_PER_PATH];

    initial_path.p[0] = odom;
    initial_path.p[1] = goal;
    initial_path.total_size = 2;
    initial_path.total_cost = 0;

    divided_path.total_size = 0;
    divided_path.total_cost = 0;

for(int i = 0; i < 2; i++)
{
    dividePath_Multithread(
        costmap,
        map_x,
        map_y,
        &divided_path,
        &initial_path,
        new_points_buff,
        new_points_costs,
        &local_seed,
        sampling,
        sid,
        threads_no,
        dev_debug);

    __syncthreads();

    copyPath_Multithread(&initial_path, &divided_path, sid, threads_no);

    __syncthreads();

}

    copyPath_Multithread(&dev_paths[bid], &divided_path, sid, threads_no);
}

// GPU function to perform one iteration of path division
// It takes path_input, divide it, and save result path to path_output
// Each episode is divided separatley by each threads concurently
// Best episode division is chosen at the end
__device__ inline void dividePath_Multithread(
    int16_t *costmap,
    const int map_x,
    const int map_y,
    GpuPath *path_output,
    GpuPath *path_input,
    GpuPathPoint *new_points_buff,
    uint32_t *new_points_costs,
    uint32_t *local_seed,
    const int sampling,
    const int sid,
    const int threads_no,
    float* dev_debug
)
{

    if(sid == 0)
    {
        path_output->p[0] = path_input->p[0];
        path_output->total_size = (path_input->total_size - 1) * (PLANNER_EPISODE_DIVISIONS + 1) + 1;
    }

    // Iterating through path episodes
    for(int i = 0; i < path_input->total_size - 1; i++)
    {
        uint32_t thread_cost = 0;


        // Generating random points
        // First and last episode point are added on the start and end
        GpuPathPoint thread_points[PLANNER_EPISODE_DIVISIONS + 2];

        thread_points[0] = path_input->p[i]; // Assign first point
        for(int j = 0; j < PLANNER_EPISODE_DIVISIONS; j++)
        {
            thread_points[j+1] =  generateRandomPoint(&path_input->p[i], &path_input->p[i+1], 1, 1, sid, threads_no, (*local_seed)++);  // Assign all random points
        }
        thread_points[PLANNER_EPISODE_DIVISIONS + 1] = path_input->p[i+1]; // Assign last point
        __syncthreads();


        // Calculating cost of episode
        for(int j = 0; j < PLANNER_EPISODE_DIVISIONS + 1; j++)
        {
             thread_points[j + 1].cost = calcEpisodeCost_Singlethread(costmap, map_x, map_y, &thread_points[j], &thread_points[j+1], sampling);
             thread_cost += thread_points[j + 1].cost;
        }
        new_points_costs[sid] = thread_cost;

        __syncthreads();

        // Assigning best episode to path_output

        dev_debug[sid] = thread_cost;

        dev_debug[31] = findCheapestThreadPath(new_points_costs, sid, threads_no);

        int best_thread = findCheapestThreadPath(new_points_costs, sid, threads_no);

        // TODO : LOWEST COST
        if(sid == best_thread)
        {
            for(int j = 0; j < PLANNER_EPISODE_DIVISIONS + 1; j++)
            {
                int output_idx = (PLANNER_EPISODE_DIVISIONS + 1) * i + j + 1;
                path_output->p[output_idx] = thread_points[j+1];
            }


            // Update episode total cost
            path_output->total_cost += thread_cost;
            path_output->total_cost -= path_input->p[i+1].cost;
        }
    }

}

__device__ inline int findCheapestThreadPath(uint32_t *new_points_costs, int sid, int threads_no)
{
    __shared__ int sid_array[PLANNER_THREADS_PER_PATH];
    sid_array[sid] = sid;

    int max_sid = PLANNER_THREADS_PER_PATH / 2;

    while(max_sid > 0 && sid < max_sid)
    {
        if(new_points_costs[sid_array[sid]] < new_points_costs[sid_array[sid + max_sid]])
        {
            // sid_array[sid] = sid_array[sid];  DO NOTHING
        }else{
            sid_array[sid] = sid_array[sid + max_sid];
        }

        max_sid /= 2;
    }

    __syncthreads();

    return sid_array[0];

}

__device__ inline float sqrf (float x)
{
    return x * x;
}

__device__ inline void copyPath_Singlethread(
    GpuPath *path_output,
    GpuPath *path_input)
{
    int total_size = path_input->total_size;

    path_output->total_size = total_size;
    path_output->total_cost = path_input->total_cost;

    // Index of first point to copy in this thread
    int point_index = 0;

    // Copying points from path_output to path_input.
    while(point_index < total_size)
    {
        path_output->p[point_index] = path_input->p[point_index];
        point_index += 1;
    }
}

__device__ inline void copyPath_Multithread(
    GpuPath *path_output,
    GpuPath *path_input,
    int sid,
    int threads_no)
{
    int total_size = path_input->total_size;

    if(sid == 0)
    {
        path_output->total_size = total_size;
        path_output->total_cost = path_input->total_cost;
    }

    // Index of first point to copy in this thread
    int point_index = sid;

    // Copying points from path_output to path_output.
    while(point_index < total_size)
    {
        path_output->p[point_index] = path_input->p[point_index];
        point_index += threads_no;
    }
}

__device__ inline GpuPathPoint generateRandomPoint(
    const GpuPathPoint *p1,
    const GpuPathPoint *p2,
    const int ep_div_no,
    const int ep_div_total,
    const int sid,
    const int threads_no,
    const int global_seed)
{
    GpuPathPoint random_point;

    curandState_t state;
    curand_init(global_seed, 0, 0, &state);
    random_point.x = curand(&state) % 255;
    random_point.y = curand(&state) % 255;

    return random_point;

}

__device__ inline void addPathPoints_Multithread(
    GpuPath *path_output,
    GpuPath *path_input,
    GpuPathPoint *new_points,
    int sid,
    int threads_no,
    int new_points_index)
{
    // Index of last point do move
    int old_total_size = path_input->total_size;
    __syncthreads();

    int new_points_number = PLANNER_EPISODE_DIVISIONS;

    // Index of first point to copy in this thread
    int point_index = sid;

    // Copying points from path_input to path_output.
    // Points with indexes higher or equal to new_points_index are moved by offset new_points_number
    while(point_index < old_total_size)
    {

        if(point_index < new_points_index)
        {
            path_output->p[point_index] = path_input->p[point_index];
        }
        else
        {
            path_output->p[point_index + new_points_number] = path_input->p[point_index];
        }

        point_index += threads_no;
    }

    // Adding new points to new path
    if(sid < new_points_number)
    {
        path_output->p[new_points_index + sid] = new_points[sid];
    }

    // Save new total cost.
    // if(sid == threads_no - 2){  path_output->total_cost +=  1;  }

    // Save new total points number.
    if(sid == 0){   path_output->total_size += new_points_number; }

}


// Calcualtes cost of traveling via episode
__device__ inline int calcEpisodeCost_Singlethread(
    int16_t *costmap,
    const int map_x,
    const int map_y,
    const GpuPathPoint *p1,
    const GpuPathPoint *p2,
    const int sampling
                            )
{
    // Totoal cost of traveling through this episode
    int total_cost = 0;

    // Distance between two points - length of episode
    int dist_x = p2->x - p1->x;
    int dist_y = p2->y - p1->y;
    float dist = sqrtf(sqrf(dist_x) + sqrf(dist_y));

    // Number of samples taken from episode
    int samples_num = (int)ceilf(dist / sampling);

    // Adding cost for each consecutive point
    GpuPathPoint sampling_point;
    for(int i = 1; i <= samples_num; i++)       // i = 1 - Avoiding taking the same points 2 times to caluclation in diffrent episodes
    {
        sampling_point.x = p1->x + (int)roundf(dist_x * i / samples_num);
        sampling_point.y = p1->y + (int)roundf(dist_y * i / samples_num);

        total_cost += costmap[sampling_point.x * map_y + sampling_point.y];
        // costmap[sampling_point.x * map_y + sampling_point.y] = 16000;               // DRAWING POINTS ON MAP!!!!
    }

    return total_cost;
}


GpuPathPlanning::GpuPathPlanning(_RobotPlannerMaps *_rpm, _ROSBuffor *_ros)
{
    this->_rpm = _rpm;
    this->_ros = _ros;
}

void GpuPathPlanning::allocateMemory()
{
    // PATH
    gpuErrchk( cudaMalloc((void**)&dev_path, planner_concurrent_paths * sizeof(GpuPath)) );
    host_path = (GpuPath*) malloc(planner_concurrent_paths * sizeof(GpuPath));

    // DEBUG
    gpuErrchk( cudaMalloc((void**)&dev_debug, 32*sizeof(float)) );
    host_debug = (float*) malloc(32*sizeof(float));

    gpuErrchk( cudaDeviceSynchronize() );
}

void GpuPathPlanning::copyInputToDevice()
{

}

void GpuPathPlanning::executeKernel()
{

    GpuPathPoint robot_onmap;
    robot_onmap.x = _rpm->robot_onmap_x;
    robot_onmap.y = _rpm->robot_onmap_y;
    robot_onmap.cost = 0;

    GpuPathPoint goal_onmap;
    goal_onmap.x = _rpm->goal_onmap_x;
    goal_onmap.y = _rpm->goal_onmap_y;
    goal_onmap.cost = 0;

    // Seed for cuRand
    gettimeofday(&host_time, 0);
    uint32_t global_seed = host_time.tv_sec + host_time.tv_usec;

    pathPlanningKernel<<<planner_concurrent_paths, PLANNER_THREADS_PER_PATH>>>(
                            dev_path,
                            _rpm->dev_costmap.data,
                            _rpm->dev_costmap.size_x,
                            _rpm->dev_costmap.size_y,
                            robot_onmap,
                            goal_onmap,
                            planner_cost_sampling,
                            planner_max_iteration,
                            planner_min_division_length,
                            global_seed,
                            dev_debug
    );
    gpuErrchk( cudaPeekAtLastError() );
    gpuErrchk( cudaDeviceSynchronize() );

}

void GpuPathPlanning::copyOutputToHost()
{
    gpuErrchk( cudaMemcpy(host_path, dev_path, planner_concurrent_paths * sizeof(GpuPath), cudaMemcpyDeviceToHost) );
    gpuErrchk( cudaMemcpy(host_debug, dev_debug, 32 * sizeof(float), cudaMemcpyDeviceToHost) );

    gpuErrchk( cudaDeviceSynchronize() );

}

void GpuPathPlanning::display()
{

    for(int j = 0; j < host_path[0].total_size -1; j++)
    {
        _rpm->host_costmap.drawEpiosde(
            "costmap",
            128,
            host_path[0].p[j].x,
            host_path[0].p[j].y,
            host_path[0].p[j+1].x,
            host_path[0].p[j+1].y);
    }


    for(int i = 0; i < planner_concurrent_paths; i++)
    {
        printf("===========\n");
        printf("host path %d\n\n", i);

        for(int j = 0; j < host_path[i].total_size; j++)
        {
            printf("    point: %d\n", j);
            printf("    x: %d\n", host_path[i].p[j].x);
            printf("    y: %d\n", host_path[i].p[j].y);
            printf("    cost: %d\n\n", host_path[i].p[j].cost);
        }
        printf("    total size: %d\n", host_path[i].total_size);
        printf("    total cost: %d\n", host_path[i].total_cost);
        printf("===========\n");
    }

    printf("debug:\n");
    for(int i = 0; i < 32; i++)
    {
        printf("    debug %d: %f\n", i, host_debug[i]);
    }
    printf("===========\n");

}
