 # Almost all CMake files should start with this
# You should always specify a range with the newest
# and oldest tested versions of CMake. This will ensure
# you pick up the best policies.
cmake_minimum_required(VERSION 3.18)

# This is your project statement. You should always list languages;
# Listing the version is nice here since it sets lots of useful variables
project(
  Test
  LANGUAGES CXX)

enable_language(CUDA)
enable_language(C)
find_package(CUDAToolkit REQUIRED)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

set(CMAKE_BUILD_TYPE DEBUG)

set(CMAKE_VERBOSE_MAKEFILE ON)
set(CMAKE_CUDA_ARCHITECTURES "80;90")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(GUSTANN_USE_BAM "Enable BaM support" OFF)
option(GUSTANN_USE_SPDK "Enable SPDK (Storage Performance Development Kit) support" OFF)
option(GUSTANN_USE_URING "Enable io_uring support" OFF)
option(GUSTANN_USE_AIO "Enable libaio support" OFF)
message(${GUSTANN_USE_BAM} ${GUSTANN_USE_SPDK})

if (GUSTANN_USE_SPDK)
  add_compile_definitions(USE_SPDK)
endif()

# If you set any CMAKE_ variables, that can go here.
# (But usually don't do this, except maybe for C++ standard)

# Find packages go here.

find_package(OpenMP)



#add_subdirectory(deps/json11)
add_subdirectory(deps/spdlog)
add_subdirectory(deps/argparse)

add_subdirectory(src)
add_subdirectory(bin/)
