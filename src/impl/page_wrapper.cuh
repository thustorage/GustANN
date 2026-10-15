#pragma once

namespace gustann {

  struct ReadCtx {
    int64_t r;
    int64_t start_idx;
    data_page_t* page;
  };

  template <class T>
  struct GraphData {
    int deg;
    int* edge;
    T* data;
    __inline__ __device__
    int operator [] (int x) const { return edge[x]; }
  };

  
  struct PageData {
    int nodes_per_page;
    int node_len;
    int data_len;
    DiskData* disk;
    static const int page_size = 4096;
    __inline__ __device__ void init() {}
    __inline__ __device__ int get_block(int nodeid) {
      return nodeid / nodes_per_page;
    }
    __inline__ __device__ int get_offset(int nodeid) {
      return nodeid % nodes_per_page * node_len;
    }
    __inline__ __device__ uint8_t* read_node(int nodeid, ReadCtx& ctx) {
      int block = get_block(nodeid);
      //if (threadIdx.x == 0) printf("B %d\n", block);
      ctx.start_idx = (int64_t) block * page_size;
      size_t s, e;
      return (uint8_t*) disk->acquire_page(ctx.start_idx, ctx.page, s, e, ctx.r);
    }
    template<class T>
    __inline__ __device__ GraphData<T> get_graph(int nodeid, ReadCtx& ctx) {
      size_t start, end;
      // TODO: bypass range impl

      int offset = get_offset(nodeid);
      //if (threadIdx.x == 0) printf("O %d\n", offset);
      uint8_t* tmp = (read_node(nodeid, ctx) + offset);
      T* data = (T*) tmp;
      int* result = (int*)(tmp + data_len);
      return (GraphData<T>) { result[0], result + 1, data };
    }
    // TODO: template
    template<class T>
    __inline__ __device__ T* get_data(int nodeid, ReadCtx& ctx) {
      int offset = get_offset(nodeid);
      //if (threadIdx.x == 0) printf("GetData %d\n", nodeid);
      return (T*) (read_node(nodeid, ctx) + offset);      
    }    
    __inline__ __device__ void prefetch(int nodeid) {
      int block = get_block(nodeid);
      //printf("Prefetch %d %d\n", nodeid, block);
      //disk->prefetch((uint64_t) block * page_size);
    }
    __inline__ __device__ void drop(const ReadCtx& ctx) {
      disk->release_page(ctx.page, ctx.r, ctx.start_idx);
    }
                                                         
  };
}
