#include "../include/cpu_map_ui32.hpp"

CpuMapUI32::CpuMapUI32()
{
    this->size_x = 0;
    this->size_y = 0;
}

CpuMapUI32::CpuMapUI32(int size_x, int size_y)
{
    this->resize(size_x, size_y);
}


CpuMapUI32::CpuMapUI32(int size_x, int size_y, const uint32_t fill_value)
{
    this->resize(size_x, size_y);
    this->fill(fill_value);
}


void CpuMapUI32::allocate(int size_x, int size_y)
{
    this->size_x = size_x;
    this->size_y = size_y;

    this->data = (uint32_t*) malloc(size_x * size_y * sizeof(uint32_t));

    this->img = cv::Mat(size_x, size_y, CV_8UC1);

}


void CpuMapUI32::resize(int size_x, int size_y)
{
    release();
    allocate(size_x, size_y);
}


void CpuMapUI32::fill(const uint32_t fill_value)
{
    for(int i = 0; i < size_x * size_y; i++)
    {
        this->data[i] = fill_value;
    }
}


void CpuMapUI32::release()
{
    this->img.release();
    free(this->data);
}


void CpuMapUI32::display(std::string win_name)
{
    int min_height = this->data[0];
    int max_height = this->data[0];

    // Finding maximum and minium height
    for(int i = 0; i < size_x * size_y; i++)
    {
        if(this->data[i] == UNKNOWN) continue;   // Unknown

        if(min_height > this->data[i]) min_height = this->data[i];
        if(max_height < this->data[i]) max_height = this->data[i];
    }


    if(min_height == max_height)
    {
        // Max and min height equal - cant do histogram equalization
        for(int i = 0; i < size_x * size_y; i++)
        {
            this->img.data[i] = 0;
        }
    }
    else
    {
        // Histogram equalization
        float height_amplitude = (float) max_height - min_height;

        // printf ("hamp %f\n", height_amplitude);
        // printf ("min_height %d\n", min_height);
        // printf ("max_height %d\n", max_height);

        for(int i = 0; i < size_x * size_y; i++)
        {
            if(this->data[i] == UNKNOWN)
            {
                this->img.data[i] = 0;
                continue;
            }
            this->img.data[i] = (uint8_t) ((this->data[i] - min_height) * 255.0 / height_amplitude);
        }
    }


    cv::namedWindow(win_name, 0);
    cv::imshow(win_name, img);
    cv::waitKey(10);
}

void CpuMapUI32::info()
{
    int min = data[0];
    int max = data[0];
    int size = size_x * size_y;
    for(int i = 1; i < size; i++)
    {
        if( data[i] < min)  min = data[i];
        if( data[i] > max)  max = data[i];
    }

    printf("cpu_map_ui32 info:\n");
    printf("size_x = %d | size_y = %d\n", size_x, size_y);
    printf("min = %u | max = %u\n", min, max);

}
