#include <iostream>
#include <fstream>
#include <cassert>
#include <sstream>
#include <algorithm>
#include <numeric>

#include <sys/time.h>

#include <thrust/copy.h>
#include <thrust/fill.h>
#include <thrust/random.h>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/binary_search.h>
#include <thrust/execution_policy.h>


#include "common.hpp"
#include "log.hpp"
#include "ssd_search.hpp"
#include "ssd_search_kernel.hpp"

#include "nav_graph.hpp"


#ifdef _USE_BAM
const char *const ctrls_paths[6] = {"/dev/libnvm0","/dev/libnvm1","/dev/libnvm2","/dev/libnvm3","/dev/libnvm4","/dev/libnvm5"};
#endif

static double elapsed() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return tv.tv_sec + tv.tv_usec * 1e-6;
}

void init_opt();

namespace gustann {
  // TODO: optimize
#ifdef _USE_BAM
  template <class T>
  __global__ void copy_data_to_ssd(array_d_t<T>* dest, T* src, size_t len, size_t offset) {
    uint64_t tid = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t thread_num = blockDim.x * gridDim.x;
    for (size_t i = tid; i < len; i += thread_num) {
      (*dest)(i + offset, src[i]);
    }
  }

  __global__ void copy_page_to_ssd(Controller** ctrls, page_cache_d_t* pc, uint64_t n_ctrls, uint8_t* src, size_t start_lba, size_t len, size_t page_size) {
#ifdef ASYNC_READ
    uint64_t cache_pages = pc->n_pages;
    
    
    uint32_t batch_per_block = cache_pages / gridDim.x;
    //if (blockIdx.x == 0 && threadIdx.x == 0) printf("%lu %lu %lu %u\n", start_lba, len, cache_pages, batch_per_block);
    uint32_t fetch_head = 0, fetch_tail = 0;
    
    for (int i = blockIdx.x; i < len; i += gridDim.x) {
      if (fetch_tail - fetch_head == batch_per_block) {
        if (threadIdx.x == 0) {
          uint32_t cache_idx = fetch_head % batch_per_block + batch_per_block * blockIdx.x;
          write_data_await(pc->cache_pages[cache_idx].qp,
                           &pc->cache_pages[cache_idx].ctx);
        }
        fetch_head++;
      }
      __syncthreads();
      uint32_t cache_idx = (fetch_tail++) % batch_per_block + batch_per_block * blockIdx.x;
      uint64_t* dest_p = (uint64_t *) (pc->base_addr + cache_idx * page_size);
      uint64_t* src_p = (uint64_t *) (src + i * page_size);
      for (int j = threadIdx.x; j < page_size / sizeof(uint64_t); j += blockDim.x) {
        dest_p[j] = src_p[j];
      }
      __syncthreads();

      if (threadIdx.x == 0) {
        uint64_t dest_page = start_lba + i;
        uint32_t ctrl = dest_page % n_ctrls;
        uint32_t block = dest_page / n_ctrls;
        uint32_t queue = ctrls[ctrl]->queue_counter.fetch_add(1, simt::memory_order_relaxed) %
          (ctrls[ctrl]->n_qps);
        
        QueuePair *qp = &ctrls[ctrl]->d_qps[queue];
        write_data_async(pc, qp, block * pc->n_blocks_per_page, pc->n_blocks_per_page,
                         cache_idx, &pc->cache_pages[cache_idx].ctx);
        pc->cache_pages[cache_idx].qp = qp;
      }
    }
    //if (threadIdx.x == 0) printf("%u %u\n", fetch_head, fetch_tail);
    __syncthreads();
    for (uint32_t i = threadIdx.x + fetch_head; i < fetch_tail; i += blockDim.x) {
      uint32_t cache_idx = i % batch_per_block + batch_per_block * blockIdx.x;

      write_data_await(pc->cache_pages[cache_idx].qp,
                       &pc->cache_pages[cache_idx].ctx);
    }

#else
    uint64_t tid = blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t warp = tid / 32;
    uint64_t ctrl_slot = warp % n_ctrls;
    uint64_t num_warps = uint64_t(blockDim.x) * gridDim.x / 32;
    uint64_t warps_per_ctrl = (num_warps + n_ctrls - 1 - ctrl_slot) / n_ctrls;
    uint64_t first_page = (warp / n_ctrls * 32 + tid % 32) * n_ctrls + ctrl_slot;
    uint64_t stride = warps_per_ctrl * 32 * n_ctrls;

    // Keep each warp on one controller and queue, as in BaM's copy kernels.
    size_t n_pages = len;
    for (size_t i = first_page; i < n_pages; i += stride) {
      // Match the STRIPE layout used by the reader.
      uint64_t current_page_idx = start_lba + i;
      uint32_t ctrl = current_page_idx % n_ctrls;
      uint32_t queue = (tid / 32) % (ctrls[ctrl]->n_qps);
      uint32_t blk_size_log = ctrls[ctrl]->d_qps[queue].block_size_log;
      uint64_t n_blocks = page_size >> blk_size_log;
      uint64_t start_block = ((current_page_idx / n_ctrls) * page_size) >> blk_size_log;

      // The host limits each batch to the DMA cache capacity.
      uint64_t pc_idx = i;
      uint8_t* dst_ptr = (uint8_t*)pc->base_addr + pc_idx * page_size;
      uint8_t* src_ptr = src + i * page_size;
      for (size_t b = 0; b < page_size; ++b) {
        dst_ptr[b] = src_ptr[b];
      }
      write_data(pc, ctrls[ctrl]->d_qps + queue, start_block, n_blocks, pc_idx);
    }
#endif
  }

  __global__ void f__k(array_d_t<uint8_t>* a) {
    int x = 159494;
    printf("%x %x %x %x\n", (*a)[x * 4096 + 128 * 4], (*a)[x * 4096 + 128 * 4 + 1], (*a)[x * 4096 + 128 * 4 + 2], (*a)[x * 4096 + 128 * 4 + 3]);
  }
#endif  
  GustANN::GustANN(DataType data_type) {
    block_cnt_ = 112 * 100;
    block_dim_ = 32;
    visited_list_size_ = 8192 * 8;
    visited_table_size_ = visited_list_size_ * 2;
    data_type_ = data_type;

    logger_ = CuHNSWLogger().get_logger();
  }

  void GustANN::init_bam_(const BaMConfig &config, int64_t ssd_pages) {
#ifdef _USE_BAM
    for (int i = 0; i < config.num_ctrls; i++) {
      bam_data_.ctrls.push_back
        (new Controller(ctrls_paths[i],
                        config.nvm_namespace,
                        config.cuda_device,
                        config.queue_depth,
                        config.num_queues));
    }
    
    int ele_per_page = config.page_size;  
    
    int num_pages = config.num_page;
    
    DEBUG("Cache page: {}", num_pages);
    DEBUG("Page size: {}", config.page_size);
    DEBUG("Data page: {}", ssd_pages);
    
    bam_data_.h_pc = new page_cache_t(config.page_size,
                                     num_pages,
                                     config.cuda_device,
                                     bam_data_.ctrls[0][0],
                                     64,
                                     bam_data_.ctrls);
    int64_t data_size = ssd_pages * config.page_size;

    page_size_ = config.page_size;

    if (config.use_simple_cache) {
      this->use_simple_cache = true;
    } else {
      this->use_simple_cache = false;
      bam_data_.h_range = new range_t<uint8_t>
        (0, data_size, 0,
         ssd_pages,
         0, config.page_size, bam_data_.h_pc,
         config.cuda_device,
         STRIPE);
      bam_data_.d_range = (range_d_t<uint8_t>*) bam_data_.h_range->d_range_ptr;
      bam_data_.vr.push_back(bam_data_.h_range);
      bam_data_.a = new array_t<uint8_t> (data_size, 0, bam_data_.vr, config.cuda_device);
    }
    
    DEBUG0("Inited BaM device");
#else
    CRITICAL0("Not Implemented!\n");
    throw;
#endif
  }

#define READ_U64(stream, val) stream.read((char *)&val, sizeof(uint64_t))
#define READ_U32(stream, val) stream.read((char *)&val, sizeof(uint32_t))
#define READ_UNSIGNED(stream, val) stream.read((char *)&val, sizeof(unsigned))
  void GustANN::parse_diskann_metadata(const std::string& fpath) {
    std::ifstream input(fpath, std::ios::binary);
    if (!input.is_open()) {
      CRITICAL("Failed to open file {}", fpath);
      exit(-1);
    }
    
    DEBUG("load DiskANN index from {}", fpath);
    
    // reqd meta values
    DEBUG0("read meta values");
    
    // from: https://github.com/microsoft/DiskANN/blob/main/src/pq_flash_index.cpp#L1043
    
    uint32_t nr, nc; // metadata itself is stored as bin format (nr is number of
    // metadata, nc should be 1)
    READ_U32(input, nr);
    READ_U32(input, nc);
    
    uint64_t disk_nnodes;
    uint64_t disk_ndims; // can be disk PQ dim if disk_PQ is set to true
    READ_U64(input, disk_nnodes);
    READ_U64(input, disk_ndims);
    
    num_data_ = disk_nnodes;
    num_dims_ = disk_ndims;
    uint64_t _disk_bytes_per_point = num_dims_ * get_data_size();
    
    uint64_t medoid_id_on_file;
    uint64_t _max_node_len, _nnodes_per_sector;
    READ_U64(input, medoid_id_on_file);
    enter_point_ = medoid_id_on_file;
    
    READ_U64(input, _max_node_len);
    READ_U64(input, _nnodes_per_sector);
    max_m0_ = ((_max_node_len - _disk_bytes_per_point) / sizeof(uint32_t)) - 1;
    
    // setting up concept of frozen points in disk index for streaming-DiskANN
    size_t _num_frozen_points, _reorder_data_exists;
    READ_U64(input, _num_frozen_points);
    uint64_t file_frozen_id;
    READ_U64(input, file_frozen_id);
    
    READ_U64(input, _reorder_data_exists);
    
    DEBUG("meta values loaded, num_data: {}, num_dims: {}, max_m0: {}, enter_point: {}",
          num_data_, num_dims_, max_m0_, enter_point_);

    nodes_per_page_ = _nnodes_per_sector;
    num_pages_ = (num_data_ + nodes_per_page_ - 1) / nodes_per_page_;
    node_size_ = _max_node_len;
    data_size_ = _disk_bytes_per_point;

    DEBUG("node size: {}, data size: {}, nodes_per_page: {}, tot_pages: {}",
          node_size_,
          data_size_,
          nodes_per_page_,
          num_pages_);
  }

  void GustANN::copy_to_bam(const std::string& fpath) {
#ifdef _USE_BAM
    DEBUG("start copy, total page {}", num_pages_);
    //std::ifstream input(fpath, std::ios::binary);
    FILE* input = fopen(fpath.c_str(), "rb");
    uint8_t* buff;

    uint64_t copy_block_cnt = 112 * 4;
    uint64_t copy_batch = 1000 * 1024 / 4 / copy_block_cnt;
    // Bound each batch by the launch size and DMA cache capacity.
    uint64_t copy_pages = std::min(copy_block_cnt * copy_batch,
                                  std::min(uint64_t(bam_data_.h_pc->pdt.n_pages),
                                           copy_block_cnt * uint64_t(block_dim_)));

    /*
    {
      input.seekg(0, std::ios::end);      
      auto pos = input.tellg();
      uint64_t len = pos;
      DEBUG("Len: {}", len);
    }
    */
    CHECK_CUDA(cudaMallocHost(&buff, page_size_ * copy_pages));
    fseek(input, page_size_, SEEK_SET);
    //input.seekg(page_size_, std::ios::beg);
    CHECK_CUDA(cudaDeviceSynchronize());
    double start = elapsed();

    uint64_t tot_cnt = 0;
    int gb_cnt = 1;
    for (int64_t i = 0; i < num_pages_; i += copy_pages) {
      // readsome may cause problems when reading large datasets
      // https://bugzilla.redhat.com/show_bug.cgi?id=1122595
      //size_t size = input.readsome((char*) buff, copy_pages * page_size_);
      size_t size = fread((char*) buff, sizeof(char), copy_pages * page_size_, input);
      //copy_data_to_ssd<<<copy_block_cnt, block_dim_>>>
      //  (bam_data_.a->d_array_ptr, buff, size, page_size_ * i);
      copy_page_to_ssd<<<copy_block_cnt, block_dim_>>>
        (bam_data_.h_pc->pdt.d_ctrls, bam_data_.h_pc->d_pc_ptr,
         bam_data_.ctrls.size(), buff, i, (size + page_size_ - 1) / page_size_, page_size_);

      auto pos = ftell(input);
            
      tot_cnt += (size + page_size_ - 1) / page_size_;
      if (tot_cnt >= gb_cnt * 10ll * 1024 * 1024 * 1024 / page_size_) {
        DEBUG("{} GB Copied", tot_cnt * page_size_ / 1024 / 1024 / 1024);
        gb_cnt++;
      }
      CHECK_CUDA(cudaDeviceSynchronize());
      /*
      if (i <= 159494 && 159494 < i + block_cnt_) {
        int a = 159494 - i;
        printf("%d\n", *(int*)(buff + a * 4096 + 128 * 4));
      }
      */
    }
    DEBUG("{} {}", tot_cnt, num_pages_);
    ASSERT((tot_cnt == num_pages_));
    //bam_data_.h_pc->clear_cache();
    CHECK_CUDA(cudaDeviceSynchronize());
    double end = elapsed();
    CHECK_CUDA(cudaFreeHost(buff));
    f__k<<<1, 1>>>(bam_data_.a->d_array_ptr);
    DEBUG("finish copy, bandwidth = {} GB/s", 1. * num_pages_ * page_size_ / 1024 / 1024 / 1024 / (end - start));
    fclose(input);
#else
    CRITICAL0("Not Implemented!\n");
    throw;
#endif
  }
  
  void GustANN::init(const BaMConfig& config, const std::string& fpath, bool copy) {
    parse_diskann_metadata(fpath);
    DEBUG("{} {}", node_size_ * nodes_per_page_, config.page_size);
    ASSERT(node_size_ * nodes_per_page_ <= config.page_size);

    //page_size_ = config.page_size;
    init_bam_(config, num_pages_);
    if (copy) {
      copy_to_bam(fpath);
    }
#ifdef _USE_MEM
    read_to_mem(fpath);
#endif
    DEBUG0("Initialization finished");
  }

#ifdef _USE_BAM
  __global__ void fetch_all_data(array_d_t<uint8_t>* a, int num_pages) {
    for (int i = threadIdx.x; i < num_pages; i += blockDim.x) {
      (*a)[i * 4096];
    }
  }
#endif
  
  void GustANN::read_to_mem(const std::string& fpath) {
    FILE* input = fopen(fpath.c_str(), "rb");
    fseek(input, page_size_, SEEK_SET);
    CHECK_CUDA(cudaHostAlloc(&mem_data_, num_pages_ * page_size_, cudaHostAllocPortable));
    uint8_t* mem_data_host = mem_data_; //new uint8_t[num_pages_ * page_size_];
    ASSERT(fread(mem_data_host, 1, num_pages_ * page_size_, input) == num_pages_ * page_size_);
    //CHECK_CUDA(cudaMalloc(&mem_data_, num_pages_ * page_size_));
    //CHECK_CUDA(cudaMemcpy(mem_data_, mem_data_host, num_pages_ * page_size_, cudaMemcpyHostToDevice));
    fclose(input);
    //delete [] mem_data_host;
  }
  
  void GustANN::search(const float *qdata, const int num_queries_, const int topk,
                      const int ef_search, int *nns, float *distances, int *found_cnt,
                      const Config& config, PQSearch* pq) {
#ifdef _USE_BAM
#if 0
    int num_queries = num_queries_;
    if (search_type == HYBRID) {
      //GustANN::search_hybrid(qdata, num_queries, topk, ef_search, nns, distances, found_cnt);
      return;
    }

    if (pq) pq->init_device(num_dims_, num_data_, block_cnt_, ef_search);
    //::init_opt();
    
    thrust::device_vector<float> d_qdata(num_queries * num_dims_);
    thrust::copy(qdata, qdata + num_queries * num_dims_, d_qdata.begin());

    std::vector<int> entries(num_queries, enter_point_);
    thrust::device_vector<int> d_entries(num_queries);
    thrust::device_vector<int> d_nns(num_queries * topk);
    thrust::device_vector<float> d_distances(num_queries * topk);
    thrust::device_vector<int> d_found_cnt(num_queries);
    thrust::device_vector<int> d_visited_table(visited_table_size_ * block_cnt_, -1);
    thrust::device_vector<int> d_visited_list(visited_list_size_ * block_cnt_);
    thrust::device_vector<int64_t> d_acc_visited_cnt(block_cnt_, 0);
    thrust::device_vector<Neighbor> d_neighbors(ef_search * block_cnt_);
    thrust::device_vector<int> d_cand_nodes(ef_search * block_cnt_);
    thrust::device_vector<float> d_cand_distances(ef_search * block_cnt_);

    thrust::copy(entries.begin(), entries.end(), d_entries.begin());
    DEBUG0("Start Search");

    //fetch_all_data<<<1, 32>>>(bam_data_.a->d_array_ptr, num_pages_);
                                               
    bam_data_.a->print_reset_stats();
    CHECK_CUDA(cudaDeviceSynchronize());
    double start = elapsed();
    search_disk_graph_kernel<<<block_cnt_, block_dim_>>>(
      thrust::raw_pointer_cast(d_qdata.data()),
      num_queries,
#ifdef _IN_MEM
      mem_data_,
#else
      bam_data_.a->d_array_ptr,
#endif
      num_data_, num_dims_, max_m0_, ef_search, 
      thrust::raw_pointer_cast(d_entries.data()),
      topk,
      thrust::raw_pointer_cast(d_nns.data()), 
      thrust::raw_pointer_cast(d_distances.data()), 
      thrust::raw_pointer_cast(d_found_cnt.data()), 
      thrust::raw_pointer_cast(d_visited_table.data()),
      thrust::raw_pointer_cast(d_visited_list.data()),
      visited_table_size_, visited_list_size_,
      thrust::raw_pointer_cast(d_acc_visited_cnt.data()),
      thrust::raw_pointer_cast(d_neighbors.data()),
      nodes_per_page_, node_size_, data_size_, data_type_,
      (pq ? pq->get_device_ptr() : nullptr)
    );
    CHECK_CUDA(cudaDeviceSynchronize());
    double end = elapsed();

    DEBUG0("End Search");
    INFO("Use time: {}", end - start);
    std::vector<int64_t> acc_visited_cnt(block_cnt_);
    thrust::copy(d_acc_visited_cnt.begin(), d_acc_visited_cnt.end(), acc_visited_cnt.begin());
    thrust::copy(d_nns.begin(), d_nns.end(), nns);
    thrust::copy(d_distances.begin(), d_distances.end(), distances);
    thrust::copy(d_found_cnt.begin(), d_found_cnt.end(), found_cnt);
    CHECK_CUDA(cudaDeviceSynchronize());
    int64_t full_visited_cnt = std::accumulate(acc_visited_cnt.begin(), acc_visited_cnt.end(), 0LL);
    DEBUG("full number of visited nodes: {}", full_visited_cnt);
    DEBUG("max: {}, min: {}", *std::max_element(acc_visited_cnt.begin(), acc_visited_cnt.end()),
          *std::min_element(acc_visited_cnt.begin(), acc_visited_cnt.end()));

    bam_data_.a->print_reset_stats();
#else
    __global__ void get_entry_kernel
      (float* qdata_global, uint8_t* data_g, int* graph, int qcnt,
       const int num_nodes, const int num_dims, const int max_m,
       const int ef_search, const int entry, int* result,
       uint32_t* neighbor_id, float* neighbor_dist
       );

    __global__ void search_disk_graph_kernel2
    (DiskData* data, float* qdata, const int num_dims,
     PQSearchData* pq_data,
     int nodes_per_page, int node_len, int data_len,
     int* entries,
     const int max_m, const int ef_search, const int topk,
     int* nns, float* distances, int* found_cnt,
     int qcnt);

    int num_queries = num_queries_;
    //num_queries = 10;
    
    NavGraph nav_graph;
    const std::string nav_index_file = config.nav_data + "/" + "nav_index";
    const std::string nav_data_file = config.nav_data + "/"+ "nav_index.data";
    const std::string nav_map_file = config.nav_data + "/" + "map.txt";

    INFO0("Use small navigation graph!");
    nav_graph.init(nav_index_file, nav_data_file, nav_map_file);
    
    thrust::device_vector<float> d_qdata(num_queries * num_dims_);
    thrust::copy(qdata, qdata + num_queries * num_dims_, d_qdata.begin());

    int aligned_ef = (ef_search + max_m0_ + 31) / 32 * 32;

    thrust::device_vector<int> d_entries(num_queries);
    thrust::device_vector<int> d_nns(num_queries * topk);
    thrust::device_vector<float> d_distances(num_queries * topk);
    thrust::device_vector<int> d_found_cnt(num_queries);
    thrust::device_vector<uint32_t> d_neighbors_id(aligned_ef * block_cnt_);
    thrust::device_vector<float> d_neighbors_dist(aligned_ef * block_cnt_);


    DEBUG0("Start Search");

    //fetch_all_data<<<1, 32>>>(bam_data_.a->d_array_ptr, num_pages_);
    if (pq) pq->init_device(num_dims_, num_data_, block_cnt_, ef_search);                                               
    bam_data_.a->print_reset_stats();
    CHECK_CUDA(cudaDeviceSynchronize());
    double start = elapsed();


    int init_ef = std::min(ef_search, 5);
    get_entry_kernel<<<(num_queries + 1) / 2, 64, 0>>>
      (thrust::raw_pointer_cast(d_qdata.data()),
       nav_graph.data_dev, nav_graph.graph_dev, num_queries,
       nav_graph.num_node, num_dims_, nav_graph.max_m,
       init_ef, nav_graph.start,
       thrust::raw_pointer_cast(d_entries.data()),
       thrust::raw_pointer_cast(d_neighbors_id.data()),
       thrust::raw_pointer_cast(d_neighbors_dist.data())
       );

    CHECK_CUDA(cudaDeviceSynchronize());
    std::vector<int> entries(num_queries);
    thrust::copy(d_entries.begin(), d_entries.end(), entries.begin());
    nav_graph.translate(entries.data(), entries.size());
    thrust::copy(entries.begin(), entries.end(), d_entries.begin());
    double t1 = elapsed();
    INFO("Init: {}", t1 - start);

    search_disk_graph_kernel2<<<
      block_cnt_, (max_m0_ + 31) / 32 * 32,
      (sizeof(int) * 3 + sizeof(float) * 2) * (ef_search + max_m0_)
                             >>>
      (
#ifdef _USE_MEM
       mem_data_,
#else
       bam_data_.a->d_array_ptr,
#endif
       thrust::raw_pointer_cast(d_qdata.data()),
       num_dims_,
       pq->get_device_ptr(),
       nodes_per_page_, node_size_, data_size_,
       thrust::raw_pointer_cast(d_entries.data()),
       max_m0_, ef_search, topk,
       thrust::raw_pointer_cast(d_nns.data()), 
       thrust::raw_pointer_cast(d_distances.data()), 
       thrust::raw_pointer_cast(d_found_cnt.data()), 
       num_queries
       );
    
    CHECK_CUDA(cudaDeviceSynchronize());
    double end = elapsed();

    DEBUG0("End Search");
    INFO("Use time: {}", end - start);
    std::vector<int64_t> acc_visited_cnt(block_cnt_);
    thrust::copy(d_nns.begin(), d_nns.end(), nns);
    thrust::copy(d_distances.begin(), d_distances.end(), distances);
    thrust::copy(d_found_cnt.begin(), d_found_cnt.end(), found_cnt);
    CHECK_CUDA(cudaDeviceSynchronize());

    bam_data_.a->print_reset_stats();
#endif
#else
    CRITICAL0("Not Implemented!");
    throw;
#endif
  }
}
