#include "../interface.hpp"

#include "spdk/env.h"
#include "spdk_wrapper.h"
#include <atomic>
#include <ctime>
#include <mutex>
#include <queue>
#include <thread>
#include <algorithm>
#include <numeric>

#include <tuple>
#include <set>

//#define DATA_PROBE

template <class T>
struct Queue {
  int head, tail, size, cap;
  T* data;
  Queue(int cap): cap(cap) {
    data = new T[cap];
    head = 0, tail = 0, size = 0;
  }
  bool empty() {
    return size == 0;
  }
  void push(const T &x) {
    data[tail] = x;
    tail = (tail + 1) % cap;
    size++;
  }
  T pop() {
    int r = head;
    head = (head + 1) % cap;
    size--;
    return data[r];
  }
};

template <class T> struct SPSCQueue {
  alignas(64) std::atomic<int> head;
  alignas(64) std::atomic<int> tail;
  int cap;
  T* data;
  SPSCQueue(int cap): head(0), tail(0), cap(cap) {
    data = new T[cap];
  }
  void push(const T &x) {
    int t = tail.load();
    data[t] = x;
    t = (t + 1) % cap;
    tail.store(t);
  }
  bool pop(T &x) {
    int h = head.load();
    int t = tail.load();
    if (h == t) return false;
    x = data[h];
    h = (h + 1) % cap;
    head.store(h);
    return true;
  }  
}; 

template <class T>
struct MPSCQueue {
  int threads;
  int cur;
  std::vector<SPSCQueue<T>*> q;
  MPSCQueue(int cap, int thread): threads(thread), cur(0) {
    for (int i = 0; i < threads; i++) {
      q.push_back(new SPSCQueue<T>(cap + 1));
    }
  }
  void push(const T &x, int t) {
    q[t]->push(x);
  }
  bool pop(T &x) {
    for (int i = 0; i < threads; i++) {
      int t = cur;
      cur = (cur + 1) % threads;
      if (q[t]->pop(x)) return true;
      
    }
    return false;
  }
  /*
  // TODO: lock free!
  std::mutex mutex;
  std::queue<T> q;
  void push(const T &x) {
  std::lock_guard<std::mutex> guard(mutex);
  q.push(x);
  }
  bool pop(T &x) {
  std::lock_guard<std::mutex> guard(mutex);
  if (q.empty()) return false;
  x = q.front();
  q.pop();
  return true;    
  }
  */

  
};

// TODO: better core config
static void bind_core(int core_num) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(core_num, &set);
  if (pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &set) != 0) {
    perror("pthread_setaffinity_np");
    exit(-1);
  }
}


namespace gustann {
  // Keep counters for different contexts and SSDs on separate cache lines.
  struct alignas(64) AlignedCounter {
    std::atomic<int> value{0};
  };

  class SpdkIOImpl: public IndexLoader {
  public:
    void submit_task(const std::vector<IoRequest> & req, int tid, int cid) override {
      for (auto [blk, dst]: req) {
        int ssd = blk % num_ssd;
        int off = blk / num_ssd;
        submit_queue[ssd]->push(Req(cid, off, dst), tid);
      }
      ready[cid].value.fetch_add(req.size());
    }
    bool poll_task(int cid) override {
      return ready[cid].value.load() == 0;
    }

    void init(const std::vector<std::string>& ssds,
              int queue_cap,
              int thread_cnt,
              int ctx_cnt) {
      spdk = spdk_wrapper::SpdkWrapper::create(32);
      spdk->Init(ssds);
      ready = new AlignedCounter[ctx_cnt];
      num_ssd = ssds.size();
      for (int i = 0; i < num_ssd; i++) {
        submit_queue.push_back(new MPSCQueue<Req>(queue_cap, thread_cnt));
      }
      /*
        auto run = [&]() {
        worker_thread();
        };
        worker.emplace_back(run);
      */
      worker_thread();
    }

    void log_latency(const std::vector<double> &percentages) override {
      printf("\t\t");
      for (auto percentage: percentages) {
        printf("%lf\t", percentage*100);
      }
      printf("\n");
      for (int i = 0; i < num_ssd; i++) {
        if (latency[i].empty()) continue;
        std::sort(latency[i].begin(), latency[i].end());
        printf("[REPORT] SSD %d\t", i);
        int size = latency[i].size();
        if (size == 0) continue;
      
        for (auto percentage: percentages) {
          const auto& ret = latency[i][size * percentage];
          //printf("%lf lat: %lf(%d)    ", percentage, ret.first, ret.second);
          printf("%lf\t", ret.first);
        }

        std::set<int> f;
        for (int j = size * 0.9; j < size; j++) {
          f.insert(latency[i][j].second);
        }
        //printf("%lu %d", f.size(), fail[i]);
        printf("\n");
      
        /*
          std::set<int> f;
          for (int j = size-1000; j < size; j++) {
          f.insert(latency[i][j].second);
          }
          for (auto x: f) {
          printf("%d ", x);
          }
        */
        printf("\n");
      }
    }
    void clear_stats() override {
      for (int i = 0; i < num_ssd; i++) {
        latency[i].clear();
      }
    }
    ~SpdkIOImpl() {
    
      finished.store(true);
      for (auto &th: worker) {
        th.join();
      }
#ifdef DATA_PROBE
      std::vector<double> percentages;
      for (int i = 900; i < 1000; i += 5) {
        percentages.push_back(1. * i / 1000);
      }

      print_stats(percentages);
#endif
    }

  private:
    struct Ctx {
      int ns_id;
      int qp_id;
      int cid;
      long r;
      void* buffer;
      std::atomic<int>* read_cnt;
      Queue<Ctx*>* wait_queue;
      Queue<Ctx*>* idle_queue;
      SpdkIOImpl* ctx;

      std::chrono::time_point<std::chrono::high_resolution_clock> start;
    };

    struct Req {
      int cid;
      int r;
      void* dst;
      Req() {}
      Req(int cid, int r, void* dst): cid(cid), r(r), dst(dst) {}
    };
    int num_ssd;
    std::unique_ptr<spdk_wrapper::SpdkWrapper> spdk;
    std::vector<MPSCQueue<Req>*> submit_queue;
    AlignedCounter* ready;
    std::vector<std::thread> worker;

    std::vector<std::vector<std::pair<double, int>>> latency;
    std::vector<int> fail;
  
    int b;
    std::atomic<int> idle_cnt;
    static const int PG_SIZE = 4096;
    static void callback(void* ctx, const struct spdk_nvme_cpl *cpl) {
      if (spdk_nvme_cpl_is_error(cpl)) {
        printf("Error!!!!");
        return;
      }
    
      Ctx* cur = (Ctx*) ctx;
    
      auto end = std::chrono::high_resolution_clock::now();
      std::chrono::duration<double> diff = end - cur->start;
#ifdef DATA_PROBE
      cur->ctx->latency[cur->ns_id].emplace_back(diff.count(), cur->r);
#endif

    
      //printf("Ready !!! %d %d\n", cur->tid, cur->ctx->ready[cur->tid].value.load());
      if (cur->ctx->ready[cur->cid].value.fetch_sub(1) == 1) cur->ctx->fail[cur->ns_id]++;
      if (cur->ctx->find_ready(cur->ns_id, cur->cid, cur->r, cur->buffer)) {
        submit(cur);
      } else {
        cur->ctx->idle_cnt.fetch_add(1);
        cur->idle_queue->push(cur);
      }

    }

    static bool submit(Ctx* ctx) {
      int ret = ctx->ctx->spdk->TrySubmitReadCommand(ctx->buffer, PG_SIZE, ctx->r, callback, ctx,
                                                     ctx->ns_id, ctx->qp_id);
      if (ret != 0) {
        if (ret == -ENOMEM) {
          ctx->wait_queue->push(ctx);
          return false;
        } else {
          printf("Error!!!\n");
        }
      }
      ctx->start = std::chrono::high_resolution_clock::now();
      ctx->read_cnt->fetch_add(1);
      return true;
    }

    bool find_ready(int ns_id, int &cid, long& blk, void* &dest) {

      Req res;
      //cid = 0;
      //blk = b++;
      //return true;

      if (submit_queue[ns_id]->pop(res)) {
        dest = res.dst;
        blk = res.r;
        cid = res.cid;
        return true;
      }
      return false;

    }


  
    AlignedCounter* read_cnt;
    std::atomic<int> finished;
    void worker_thread() {
      read_cnt = new AlignedCounter[num_ssd];
      idle_cnt = 0;
    
      finished = false;
      latency.resize(num_ssd);
      fail.resize(num_ssd);
    
      auto monitor = [&]() {
        auto start = std::chrono::high_resolution_clock::now();
        auto last_t = start;
        int last_idle = 0;
        std::vector<long> last(num_ssd);
        while(!finished.load()) {
          sleep(1);
        
          auto end = std::chrono::high_resolution_clock::now();
          std::chrono::duration<double> elapsed = end - start;
          std::vector<long> rds;
          for (int i = 0; i < num_ssd; i++) {
            long cur = read_cnt[i].value.load();
            long r = cur - last[i];
            last[i] = cur;
            rds.push_back(r);
          }

          long r = std::accumulate(rds.begin(), rds.end(), 0);
        
          printf("Bandwidth: %lf GB/s, %ld\n", r * PG_SIZE / elapsed.count() / 1024 / 1024 / 1024, r);
          printf("IOPS: ");
          for (int i = 0; i < num_ssd; i++) {
            printf("%ld, ", rds[i]);
          }
          printf("\n");
          
          int idle_cur = idle_cnt.load();
          int val = idle_cur - last_idle;
          last_idle = idle_cur;
          printf("Idle cnt: %d\n", val);

          printf("Queue Occupacy: ");
          for (auto& q: submit_queue) {
            for (auto& sq: q->q) {
              auto head = sq->head.load();
              auto tail = sq->tail.load();
              int size;
              if (head <= tail) {
                size = tail - head;
              } else {
                size = tail - head + sq->cap;
              }
              printf("%d, ", size);
            }
          }
          printf("\n");

          start = end;
        }
      };
      auto runner = [&](int nid) {
        const int BATCH_SIZE = 1024;
        bind_core(nid * 2 + 3);
        printf("TID: %d %d\n", gettid(), sched_getcpu());

        std::vector<Ctx> ctxs(BATCH_SIZE);
        Queue<Ctx*> idle_queue(BATCH_SIZE), wait_queue(BATCH_SIZE);

        char* buff = (char*) spdk_dma_zmalloc(BATCH_SIZE * PG_SIZE, PG_SIZE, nullptr);
      
        for (int i = 0; i < BATCH_SIZE; i++) {
          int id = i;
          ctxs[i].ns_id = nid;
          ctxs[i].qp_id = 0;
          ctxs[i].wait_queue = &wait_queue;
          ctxs[i].idle_queue = &idle_queue;
          ctxs[i].read_cnt = &read_cnt[nid].value;
          ctxs[i].ctx = this;
          ctxs[i].buffer = buff + i * PG_SIZE;
          ctxs[i].cid = 0;
          ctxs[i].r = i;
          ctxs[i].idle_queue->push(&ctxs[i]);
          //submit(&ctxs[i]);
        }


        while(!finished.load()) {

          while(!wait_queue.empty()) {
            auto c = wait_queue.pop();
            if (!submit(c)) {
              break;
            }
          }
        
          spdk->PollCompleteQueue(nid, 0);
        
          long r;
          void* dst;
          int tid;

          while (!idle_queue.empty() && find_ready(nid, tid, r, dst)) {
            auto c = idle_queue.pop();
            c->cid = tid;
            c->r = r;
            c->buffer = dst;
            submit(c);
          }
        }
      };
      worker.emplace_back(monitor);
      for (int i = 0; i < num_ssd; i++) {
        worker.emplace_back(runner, i);
      }
    }

    uint8_t* create_buffer(int64_t size) override {
      return (uint8_t *)spdk_dma_zmalloc_socket(sizeof(uint8_t) * size,
                                                PAGE_SIZE, NULL, 1);
    }

    void destroy_buffer(uint8_t* buf) override {
      spdk_free(buf);
    }
  };

  std::shared_ptr<IndexLoader>
  create_spdk_loader(const std::vector<std::string> &ssds, int queue_cap,
                     int thread_cnt, int ctx_cnt) {
    std::shared_ptr<SpdkIOImpl> spdk_io =
        std::make_shared<SpdkIOImpl>();
    spdk_io->init(ssds, queue_cap, thread_cnt, ctx_cnt);
    return spdk_io;
  }
} // namespace gustann
