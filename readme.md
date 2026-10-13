# GustANN

**GustANN** is a high-throughput, billion-scale, graph-based vector store built for GPUs. It is based on our SIGMOD '26 paper: 
> 📄 [*High-Throughput, Cost-Effective Billion-Scale Vector Search with a Single GPU.*](https://dl.acm.org/doi/10.1145/3769799)

### ✨ Key Features
+ 🚀 **High Throughput**: Achieves ~250K QPS on billion-scale datasets (SIFT1B, top-10, recall=0.9)—**7.81x faster than DiskANN**.
+ 🧠 **Memory Efficient**: Requires only ~40GB of memory for *both* GPU and CPU on billion-scale datasets.
+ 🔀 **Flexible Interface**: Supports multiple search modes (SSD-based, all-in-DRAM, all-in-GPU) and storage backends (SPDK, liburing, libaio).

---

> [!TIP]
> **For convenience**, we highly recommend modifying `scripts/setup.sh` first to specify your file paths and save locations, and then using the provided automated scripts.
> 
> If you prefer to execute the commands **step-by-step manually** (or need deeper customization), please refer to our [**guide**](details.md).

---

## ⚡ Quickstart

You can quickly set up a 1M vector database to try GustANN using our automated script:
```bash
./scripts/quick_start.sh
```

### 💻 System Requirements
To ensure optimal performance, please verify your hardware meets the following configurations:

*   **CPU:** x86 CPU supporting huge pages (Verify with: `grep pdpe1gb /proc/cpuinfo`).
*   **System RAM (DRAM):** **~40GB** minimum for vector search. *(Note: Building the index requires additional memory).*
*   **GPU:** **~40GB VRAM** required for billion-scale search (e.g., NVIDIA A100).
*   **Dataset Constraints:** Maximum of **< 2 Billion vectors** (to avoid integer overflow). Record size (`vector_size + 4 + 4 * num_neighbors`) must be **< 4KB**.
*   **Storage (SSD):** ~700GB for SIFT1B or ~1TB for DEEP1B. Multi-SSD configurations are supported.
    *   *Recommendation:* Use **SPDK** for maximum performance. Alternatively, use io-uring, aio, or in-memory indexing.

---

## 🛠️ Installation & Build

### 1. Install Dependencies
GustANN relies on [DiskANN](https://github.com/microsoft/DiskANN) for index building. Install the following system dependencies (Ubuntu 22.04):

```bash
sudo apt update
sudo apt install make cmake g++ libaio-dev libgoogle-perftools-dev clang-format libboost-all-dev libmkl-full-dev libjemalloc-dev
```
> [!NOTE]
> You must also install [CUDA](https://developer.nvidia.com/cuda-downloads) following NVIDIA's official instructions.

### 2. Clone the Repository
```bash
git clone https://github.com/thustorage/GustANN.git --recursive
cd GustANN
```

### 3. Build GustANN
```bash
mkdir -p build && cd build
cmake .. # Use flags here for specific backends (see below)
make -j
cd ..
```
*Note: To build with a specific storage backend, append the switch to the CMake command: `-DGUSTANN_USE_{SPDK,URING,AIO}=ON`.*

---

## 📊 Dataset and Index Preparation

> [!NOTE]
> **If you already have a built index, you can skip this step.**
> For complete dataset preparation instructions from scratch, refer to the [PipeANN repository](https://github.com/thustorage/PipeANN?tab=readme-ov-file#for-others-starting-from-scratch).

### 1. Build DiskANN
First, compile DiskANN:
```bash
cd deps/DiskANN
mkdir build && cd build
cmake .. && make -j
cd ../../..
```

### 2. Convert Dataset Format
To build a DiskANN index, you need to prepare your dataset in `bin` format. DiskANN provides a utility to convert from `bvec/fvec` formats (e.g., the format used by the SIFT dataset):
```bash
./deps/DiskANN/build/apps/utils/fvecs_to_bin <float/uint8> input_vecs output_bin
```

### 3. Build the DiskANN Index
Once the dataset is converted, update `scripts/setup.sh` with your paths, and run:
```bash
./scripts/build_disann_index.sh <pq_size> <memory>
```
*   `pq_size`: **3.3** for 100M-scale datasets, **33** for 1B-scale datasets (generates 32-bit PQ vectors).
*   `memory`: Maximum memory available for building the index.

### 4. Prepare the GustANN Index (Pivot Graph)
In addition to the DiskANN index, GustANN requires building a pivot graph. Update `scripts/setup.sh`, then run:
```bash
./scripts/gen_pivot_graph.sh
```

---

## 🏃 Running GustANN

### Mode A: In-Memory Search (Recommended for < 100M vectors)
For smaller datasets, keeping data in DRAM or GPU memory yields the best performance. After updating `scripts/setup.sh`, run:

```bash
./scripts/run_mem.sh --topk <topk> --ef_search <L> [<L2> ...] -R <R> [-G]
```
*   **`-G` Flag:** Enables **pure GPU search** (Fastest, but limited to small datasets).
*   **`-L` Flag:** Number of vectors stored during search (Higher = more accurate).
*   **`-R` Flag:** Repeat the query `R` times for accurate benchmarking on small query sets.

---

### Mode B: On-SSD Search (Billion-Scale)

You can run GustANN using SPDK (fastest), liburing, or libaio. 

#### 🔥 SPDK Setup (Highest Performance)
> [!WARNING]
> **SPDK requires root privileges**. There must be NO partitions or filesystems on the target SSDs. Using `nvme format` **WILL ERASE ALL DATA ON THE DISK. Do this at your own risk!**

1.  **Build SPDK & GustANN:**
    ```bash
    git clone https://github.com/spdk/spdk deps/spdk 
    # Note: We have tested GustANN on git commit 7c0720d1d
    
    cd deps/spdk
    sudo scripts/pkgdep.sh # Install the dependency of SPDK
    ./configure && make -j
    cd ../..
    
    # Remember to rebuild GustANN with SPDK enabled: 
    # cd build && cmake .. -DGUSTANN_USE_SPDK=ON && make -j && cd ..
    ```
2.  **Setup SPDK:**
    ```bash
    sudo ./deps/spdk/scripts/setup.sh
    sudo ./deps/spdk/build/examples/hello_world # Verify it works
    ```
3.  **Prepare SSD List & Write Index:** Collect the PCIe addresses of your SSDs into a file (`ssd_list.txt`), update `scripts/setup.sh`, and run:
    ```bash
    sudo ./scripts/write_spdk.sh
    ```

#### ⚙️ liburing / libaio Setup
*   **liburing:** 
    ```bash
    git clone https://github.com/axboe/liburing.git deps/liburing 
    # Note: We have tested on commit 20b3fe67
    
    cd deps/liburing
    ./configure && make -j
    cd ../..
    
    # Remember to rebuild GustANN with: 
    # cd build && cmake .. -DGUSTANN_USE_URING=ON && make -j && cd ..
    ```
*   **libaio:** Ensure your Linux kernel supports libaio. Rebuild GustANN with `-DGUSTANN_USE_AIO=ON`.

#### ▶️ Execute On-SSD Search
Update `scripts/setup.sh`, then run the appropriate script for your backend:

```bash
sudo ./scripts/run_spdk.sh  --topk <topk> --ef_search <L> -B <B> -T <T> -C <C> -R <R> # for SPDK
./scripts/run_uring.sh      --topk <topk> --ef_search <L> -B <B> -T <T> -C <C> -R <R> # for liburing
./scripts/run_aio.sh        --topk <topk> --ef_search <L> -B <B> -T <T> -C <C> -R <R> # for libaio
./scripts/run.sh            --topk <topk> --ef_search <L> -B <B> -T <T> -C <C> -R <R> # for in-memory fallback testing
```

> [!IMPORTANT]  
> **Crucial Tuning Parameters (`B`, `T`, `C`):**
> Different I/O backends favor different worker configurations:
> *   **SPDK:** `-T 2` (Worker threads), `-C 20` (Minibatches/thread), `-B >=1000` (Minibatch size)
> *   **Uring / Memory:** `-T 20`, `-C 1`, `-B >=1000`
> *   **AIO:** `-T 2`, `-C 10`, `-B 256` *(Setting B too large may cause AIO to crash!)*

*After execution, the runtime, total SSD I/Os, and recall metrics will be printed to stdout.*

---

## 🧪 Experimental Features
*   **GPU Direct-IO Support:** See [bam.md](bam.md) for experimental GPU Direct Storage setup.

---

## 📚 Citation
If you find GustANN useful in your research, please cite our SIGMOD '26 paper:

```bibtex
@inproceedings{sigmod26gustann,
    author = {Haodi Jiang and Hao Guo and Minhui Xie and Jiwu Shu and Youyou Lu},
    title = {{High-Throughput, Cost-Effective Billion-Scale Vector Search with a Single GPU}},
    year = {2026},
    publisher = {Association for Computing Machinery},
    booktitle = {Proceedings of the 2026 International Conference on Management of Data},
    address = {Bengaluru, India},
    series = {SIGMOD '26}
}
```

## 🙏 Acknowledgements
Some GPU kernel implementations are adapted from [CuHNSW](https://github.com/js1010/cuhnsw). We greatly appreciate their open-source contributions.
