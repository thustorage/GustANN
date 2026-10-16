#include <cstdio>
#include <cstring>
#include <algorithm>
#include <iostream>
#include <cstdint>


#include "utils.hpp"



int main(int argc, char** argv) {
  if (argc != 3) {
    std::cout << argv[0] << ": output_bin ground_truth_bin" << std::endl;
    exit(-1);
  }

  size_t dim, num;
  int* ground_truth = ivecs_read(argv[2], &dim, &num);
  
  size_t dim2, num2;
  int* output = bin_read<int>(argv[1], dim2, num2);
  if (dim < dim2) {
    std::cout << "DIM mismatch: " << dim << " vs " << dim2 << std::endl;
    exit(-1);
  }
  if (num != num2) {
    std::cout << "NUM mismatch: " << dim << " vs " << dim2 << std::endl;
    exit(-1);
  }

  std::cout << "Recall @ " << dim2 << ": " << calc_recall(output, ground_truth, num, dim, dim2) << std::endl;
}
