#include "ssd_search.hpp"
#include "log.hpp"
#include <set>
#include "utils.hpp"
#include "pq_search.hpp"

#include <argparse/argparse.hpp>

std::shared_ptr<spdlog::logger> logger_ = nullptr;

int main(int argc, char** argv) {  
  logger_ = CuHNSWLogger().get_logger();
  CuHNSWLogger().set_log_level(3);

  argparse::ArgumentParser program("search_disk");
  gustann::BaMConfig config;
  bool copy_data = false;
  bool only_copy = false;
  std::string query_file ;
  std::string gt_file;
  std::string index_file;
#ifdef FLOAT_DATA
  std::string data_type = "float";
#else
  std::string data_type = "uint8";
#endif
  
  config.num_page = 16384;
  config.num_ctrls = 5;
  config.num_queues = 135;

  int topk = 100;
  int ef_search = 300;

  int thread, batch, ctx_per_thread;
  std::string pq_data;
  int repeat = 20; // FIXME: repeat value cannot be too small???
  gustann::GustANN::Config search_config;

  std::string ssd_list_file;

#ifdef _USE_BAM
  program.add_argument("--num_ctrls").store_into(config.num_ctrls);
  program.add_argument("--copy_data").store_into(copy_data);
#endif
  program.add_argument("--query").required().store_into(query_file);
  program.add_argument("--index").required().store_into(index_file);
  program.add_argument("--ground_truth").store_into(gt_file);
  //program.add_argument("--data_type").store_into(data_type);
  program.add_argument("--topk").store_into(topk);
  program.add_argument("--ef_search").store_into(ef_search);
  program.add_argument("--cache_page").store_into(config.num_page);
  program.add_argument("--copy_only").store_into(only_copy);
#ifdef HYBRID_CALC
  program.add_argument("--minibatch", "-B").required().store_into(batch);
  program.add_argument("--thread", "-T").required().store_into(thread);
  program.add_argument("--ctx_per_thread", "-C").required().store_into(ctx_per_thread);
#endif
  program.add_argument("--repeat", "-R").store_into(repeat);
  program.add_argument("--pq_data").required().store_into(pq_data);
  program.add_argument("--nav_graph").store_into(search_config.nav_data);
  program.add_argument("--warmup").store_into(search_config.warmup_batch);
  program.add_argument("--ssd_list_file").store_into(ssd_list_file);
  
  try {
    program.parse_args(argc, argv);
  }
  catch (const std::exception& err) {
    std::cerr << err.what() << std::endl;
    std::cerr << program;
    exit(1);
  }

  INFO("Num ctlrs: {}, Copy Data: {}, Query File: {}, Index File: {}, Ground Truth file: {}, Data Type: {}, topk: {}, ef_search: {}", config.num_ctrls, copy_data, query_file, index_file, gt_file, data_type, topk, ef_search);

  std::fstream stream(ssd_list_file);
  if (stream) {
    std::string s;
    while(stream >> s) {
      INFO("USE SSD: \"{}\"", s);
      search_config.ssd_list.push_back(s);
    }
  }

  int deviceCount;
  cudaGetDeviceCount(&deviceCount);
  int device;
  for (device = 0; device < deviceCount; ++device) {
    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, device);
    INFO("Device {}({}) has compute capability {}.{}.\n", device,
         deviceProp.name, deviceProp.major, deviceProp.minor);
  }

  
  gustann::DataType dtype = gustann::FLOAT;
  if (data_type == "float") {

  } else if (data_type == "uint8") {
    dtype = gustann::UINT8;
  } else {
    CRITICAL("unrecognized data type {}", data_type);
    exit(-1);
  }
  
  gustann::GustANN a(dtype);

#ifdef HYBRID_CALC
  a.init_hybrid(index_file);
#else
  a.init(config,
         index_file, copy_data);
#endif


  PQSearch pq_search;
  pq_search.read_data(pq_data + "_pivots.bin",
                      pq_data + "_compressed.bin"
                      );
  
  size_t d, nq;
  //float* 
  float* data;
  switch (dtype) {
  case gustann::FLOAT: {
    data = fvecs_read(query_file.c_str(), &d, &nq);
    break;
  }
  case gustann::UINT8: {
    uint8_t* tmp_data = bvecs_read(query_file.c_str(), &d, &nq);
    data = new float [d * nq];
    std::copy(tmp_data, tmp_data + d * nq, data);
    delete [] tmp_data;    
    break;
  }
  }
  if (only_copy) return 0;
  
  DEBUG("Read {} queries", nq);

  if (true) {
    int rep = repeat;
    //int rep = 20;
    int new_nq = nq * rep;
    float* new_data = new float [d * new_nq];
    for (int i = 0; i < rep; i++) {
      std::copy(data, data + d * nq, new_data + i * d * nq);
    }
    delete [] data;
    data = new_data;
    nq = new_nq;
  }
  
  std::unique_ptr<int[]> nns(new int [nq * topk]);
  std::unique_ptr<float[]> dis(new float [nq * topk]);
  std::unique_ptr<int[]> found_cnt(new int [nq]);
      
#ifdef HYBRID_CALC
  a.search_hybrid(data, nq, topk, ef_search, nns.get(), dis.get(), found_cnt.get(),
                  batch, thread, ctx_per_thread, search_config, &pq_search);
#else
  a.search(data, nq, topk, ef_search, nns.get(), dis.get(), found_cnt.get(), search_config, &pq_search);
#endif

  
  for (int i = 0; i < 5; i++) {
    for (int j = 0; j < 5; j++) {
      printf("%lf(%d)\t", dis[i * topk + j], nns[i * topk + j]);
    }
    printf("\n");
  }

  if (gt_file.length() > 0) {
    size_t gt_d, gt_nq;
    int* gt = ivecs_read(gt_file.c_str(), &gt_d, &gt_nq);
    //printf("%d\n", gt[0]);
    double recall = calc_recall(nns.get(), gt, gt_nq, gt_d, topk);    
    printf("Recall @ %d: %lf\n", topk, recall);
    printf("[REPORT] RECALL: %lf\n", recall);
  }
  
}
