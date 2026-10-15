# GustANN: High-Throughput, Cost-Effective Billion-Scale Vector Search with a Single GPU

Welcome to the artifact repository of SIGMOD'26 paper: *High-Throughput, Cost-Effective Billion-Scale Vector Search with a Single GPU.*

This branch contains the scripts to reproduce the primary results described in the paper.

## Quick Start (for AE reviewers)

We have prepared the experiment environment for the AE reviewer. To access the environment, please follow the instructions on the HotCRP website or contact the authors directly.

To run the experiment, simply:

```bash
cd GustANN/scripts/ae
./run_all.sh # Run all experiments
python3 -m notebook --no-browser --ip=0.0.0.0 --port=8888 plot_results.ipynb # Or use the VS Code Jupyter extension
```

Open the URL printed in the terminal in your browser. Use the server's address or SSH port forwarding to access the notebook.

Set `LOG_PREFIX` on the first line of the notebook to your log directory name, such as `test-20261014-180519`, rather than its full path. The notebook exports PDF figures to `figures/<LOG_PREFIX>/` in the repository root.

Experiment logs are stored in `log/<prefix>-<timestamp>/` in the repository root.

If you face any problems, or the scripts fail during the process, please contact the authors.

## Setup Guide

Here we show how to set up the artifact environment (including both GustANN and the compared baselines) from scratch.

### Hardware Configurations

+ CPU: x86 CPU supporting huge pages (You may verify this through `grep pdpe1gb /proc/cpuinfo`).
+ OS: We have tested the scripts on Linux 5.15.0-177-generic, Ubuntu 24.04. Root privilege is needed.
+ DRAM: ~40GB for vector search. Additional memory space is needed for building the index.
+ SSD: Empty SSDs for running the experiment
  - To reproduce the results, we recommend to use at least 4 PM1743 or equivalent SSDs.
  - To store all datasets and indices, an additional ~4 TB of space (on the filesystem) is needed.
+ GPU: ~40GB GPU memory for billion-scale vector search (e.g., NVIDIA A100)
  - We tested the scripts on CUDA 12.8, NVIDIA driver 590.44.01.
  - Note that to run the [BaM](https://github.com/ZaidQureshi/bam) baseline (Figure 11), you need to install an open-source version of the NVIDIA driver.
+ gcc/g++: Version 12 (Some baselines cannot be compiled, or need additional adjustments on GCC 13).

### Software Dependencies

You need to install the following packages:

``` bash
apt install make cmake g++ libaio-dev libgoogle-perftools-dev clang-format libboost-all-dev libmkl-full-dev libjemalloc-dev
```

### Build GustANN

First, clone the repository:

``` bash
git clone --branch ae --recursive https://github.com/thustorage/GustANN.git
cd GustANN
```

Then, build the SPDK dependency:

``` bash
cd deps/spdk
sudo scripts/pkgdep.sh # Install the dependency of SPDK
./configure
make -j
cd ../..
```

Finally, build GustANN:

``` bash
mkdir -p build
cd build
cmake .. -DGUSTANN_USE_BAM=OFF
make -j
cd ..
```



### Build other baselines

We include a patch file in `scripts/ae/patch` for each baseline, containing bug fixes and additional logging for the log parser.

If a baseline's CMake configuration cannot detect the GPU architecture and supports `CMAKE_CUDA_ARCHITECTURES`, specify it explicitly, for example `cmake -DCMAKE_CUDA_ARCHITECTURES="80;90" ..`. Keep the quotes so the shell does not interpret the semicolon as a command separator. GustANN currently sets its architectures directly in the root `CMakeLists.txt`; change that setting there if needed.

#### DiskANN (core dependency)

DiskANN is the main baseline compared to GustANN. DiskANN is also used to build the graph index. Therefore, it is highly recommended to be prepared.

```bash
cd deps/DiskANN
mkdir build && cd build
cmake .. && make -j
cd ../../..
```

#### Starling

We assume the baseline is placed in `baselines/`.

```bash
# Clone the repo
mkdir -p baselines
cd baselines
git clone https://github.com/zilliztech/starling.git
cd starling
git checkout 17dc3e8a011533a62374445f53963e951b72883a # The commit we tested
git submodule update --init --recursive --depth 1
git apply ../../scripts/ae/patch/starling.patch

# Build
mkdir build
cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make
cd ../../..
```

#### SPANN

We assume the baseline is placed in `baselines/`.

```bash
# Clone the repo
mkdir -p baselines
cd baselines
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/microsoft/SPTAG
cd SPTAG
git checkout 4ecf2495eb6187b555c0a6ee7d3b5394d5362183 # The commit we tested
git submodule update --init --recursive --depth 1
git apply ../../scripts/ae/patch/spann.patch

# Build
mkdir build
cd build
cmake ..
make
cd ../../..
```

#### BANG

```bash
# Clone the repo
mkdir -p baselines
cd baselines
git clone https://github.com/karthik86248/BANG-Billion-Scale-ANN.git
cd BANG-Billion-Scale-ANN
git checkout aceab75d7ae9975e22c08f214fa8a2e6eb779258
git apply ../../scripts/ae/patch/bang.patch

# Build
cd BANG_Base
mkdir build
cd build
cmake ..
make
cd ../../../..
```

#### Rummy

``` bash
# Clone the repo
mkdir -p baselines
cd baselines
git clone https://github.com/pkusys/Rummy.git
cd Rummy
git checkout accf7f81996d67460654a7493183af952dc3ff28
git submodule update --init --recursive --depth 1
git apply ../../scripts/ae/patch/rummy.patch

# Build
mkdir build
cd build
cmake -DFAISS_ENABLE_GPU=YES -DFAISS_ENABLE_PYTHON=NO ..
make
make overall_billion
cd ../../..
```
#### BaM

``` bash
# Clone the repo
cd deps/
git clone https://github.com/ZaidQureshi/bam.git
cd bam
git checkout 2edd33c
git submodule update --init --recursive --depth 1
git apply ../../scripts/ae/patch/bam.patch

# Build
mkdir build
cd build
cmake ..
make
cd module
make
# To check whether the kernel module of BaM works.
sudo make load
sudo make unload
cd ../../../..

# Recompile GustANN
cd build
cmake .. -DGUSTANN_USE_BAM=ON
make -j
cd ..
```

## Dataset and Index Preparation

### Dataset Download & Conversion

You can download the datasets from the following links: [SIFT1B](http://corpus-texmex.irisa.fr/) and [DEEP1B](http://corpus-texmex.irisa.fr/). At a minimum, download the following files: base set (the vectors in the vector database), query set (the query vectors), and the ground truth (the real top-$k$ nearest neighbors). You can use `./deps/DiskANN/build/apps/utils/compute_groundtruth` to generate the ground truth if needed. Convert its output to `.ivecs` using `scripts/io_utils.py`: read the ID matrix with `ibin_read()` and write it with `ivecs_write()`.

Please note that there are two main types of data format in ANNS: bin format (`.fbin` for `float` data and `.bbin` for `uint8` data) and vecs format (`fvecs/ivecs/bvecs` for `float/int32/uint8` respectively).
Different baselines use different data formats.
DiskANN provides tools to convert from vecs format to bin format.

``` bash
./deps/DiskANN/build/apps/utils/fvecs_to_bin <float/uint8> input_vecs output_bin
```

We provide a Python helper `scripts/io_utils.py`, which supports I/O and conversion for these formats, although converting large datasets may exceed the available DRAM.

To generate SIFT100M/DEEP100M, you only need to extract the first 100M vectors from the base set (Recomputation of groundtruth may be needed).

Rummy also requires a DEEP training subset in `.fvecs` format, configured as `data/deep/1M.fvecs`, which can be prepared from the first 1M DEEP vectors.

### Build DiskANN/GustANN Index

DiskANN and GustANN indices can be constructed with the following commands:

``` bash
# SIFT1B
./deps/DiskANN/build/apps/build_disk_index --data_type uint8 --dist_fn l2 --index_path_prefix <index_prefix> --data_path <dataset_file> -B 30.5 -M <memory> -R 128 -L 200

# DEEP1B
./deps/DiskANN/build/apps/build_disk_index --data_type float --dist_fn l2 --index_path_prefix <index_prefix> --data_path <dataset_file> -B 30.5 -M <memory> -R 128 -L 200

# SIFT100M
./deps/DiskANN/build/apps/build_disk_index --data_type uint8 --dist_fn l2 --index_path_prefix <index_prefix> --data_path <dataset_file> -B 3.3 -M <memory> -R 128 -L 200

# DEEP100M
./deps/DiskANN/build/apps/build_disk_index --data_type float --dist_fn l2 --index_path_prefix <index_prefix> --data_path <dataset_file> -B 3.3 -M <memory> -R 128 -L 200
```

The key parameters are specified like this:
+ `index_prefix`: the directory and the name of the index. For example, if you use `/data/index`, then DiskANN will create index files with this prefix (e.g., `/data/index_disk.index`).
+ `dataset_file`: the dataset in `bin` format
+ `memory`: The maximum memory available for building the index (recommended > 200GB).

Then GustANN needs to build a pivot graph.

We have provided scripts to build the pivot graph easily.
Please modify the `scripts/setup.sh` according to the instruction in it, and run:

``` shell-session
$ ./scripts/gen_pivot_graph.sh
```

### Build Starling Index

Starling needs to convert the DiskANN into its own format.
We use SIFT100M as an example. For DEEP100M, replace `uint8` with `float`.

``` bash
cd baselines/starling/build
./graph_partition/partitioner --index_file <index_prefix>_disk.index --data_type uint8 --gp_file <gp_part.bin> -T 16 --ldg_times 16
./tests/utils/index_relayout <index_prefix>_disk.index <gp_part.bin>
ln -s <gp_part.bin> <index_prefix>_partition.bin
cd ../../..
```

The `<gp_part.bin>` is the Starling Index. It also generates additional intermediate files for the search.

### Build BANG Index

We use SIFT100M as an example. For DEEP100M, replace `uint8` with `float` in the index-building command. In the preprocessing command, change the dimension from `128` to `96` and the data type code from `1` (uint8) to `2` (float).

```bash
deps/DiskANN/build/apps/build_disk_index --data_type uint8 --dist_fn l2 --index_path_prefix <bang_index_prefix> --data_path <dataset_file> -B 6.3 -M <memory> -R 64 -L 100
python3 baselines/BANG-Billion-Scale-ANN/BANG_Base/bang_preprocess.py <bang_index_prefix>_disk.index <bang_index_prefix>_disk.bin 128 1 64
```

### Build SPANN Index

First, modify the data path in the `scripts/ae/{sift,deep}100m_build.ini`, then run

```bash
ulimit -s unlimited # To avoid stack overflow
./baselines/SPTAG/Release/ssdserving scripts/ae/sift100m_build.ini # OR deep100m_build.ini
```


## Prepare experiment

Before executing the all-in-one scripts above, modify the following files to match your index paths:
+ `scripts/ae/ae-setup.sh`
+ `scripts/ae/run_{sift,deep}100m_starling.sh`: Make sure that `DISK_FILE` variable is valid
+ `baselines/Rummy/eval/overall_billion.cu`: Update the paths on lines 232-235 to match your dataset locations. After that, rebuild Rummy.
+ `ssd_list.txt`: list the PCIe addresses of your **EMPTY SSDs** in the `XXXX:XX:XX.X` format, one per line. You can find them with the `lspci` command. **The data on the SSDs will be erased once the experiments start, so be careful with this step!**

One experiment (Figure 16) uses 1M synthetic SIFT queries generated by combining 8-dimensional segments from the original queries. Update `ifile` and `ofile` in `scripts/ae/data_argument.py` to the paths of the original queries and `bigann_query_arg.bvecs`, then run the generator and convert its output to bin format:

```bash
python3 scripts/ae/data_argument.py
./deps/DiskANN/build/apps/utils/fvecs_to_bin uint8 /path/to/bigann_query_arg.bvecs /path/to/bigann_query_arg.bbin
```

Set `QUERY_FILE_MOCK` and `QUERY_BIN_FILE_MOCK` in `scripts/ae/ae-setup.sh` to these two files.
