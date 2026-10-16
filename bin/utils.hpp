#pragma once

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cassert>
#include <cstdint>
#include <fstream>
#include <set>


#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>



inline double elapsed() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return tv.tv_sec + tv.tv_usec * 1e-6;
}

inline float *fvecs_read(const char *fname, size_t *d_out, size_t *n_out) {
  FILE *f = fopen(fname, "r");
  if (!f) {
    fprintf(stderr, "could not open %s\n", fname);
    perror("");
    abort();
  }
  int d;
  fread(&d, 1, sizeof(int), f);
  assert((d > 0 && d < 1000000) || !"unreasonable dimension");
  fseek(f, 0, SEEK_SET);
  struct stat st;
  fstat(fileno(f), &st);
  size_t sz = st.st_size;
  assert(sz % ((d + 1) * 4) == 0 || !"weird file size");
  size_t n = sz / ((d + 1) * 4);

  *d_out = d;
  *n_out = n;
  float *x = new float[n * (d + 1)];
  size_t nr = fread(x, sizeof(float), n * (d + 1), f);
  assert(nr == n * (d + 1) || !"could not read whole file");

  // shift array to remove row headers
  for (size_t i = 0; i < n; i++)
    memmove(x + i * d, x + 1 + i * (d + 1), d * sizeof(*x));

  fclose(f);
  return x;
}

// not very clean, but works as long as sizeof(int) == sizeof(float)
inline int *ivecs_read(const char *fname, size_t *d_out, size_t *n_out) {
  return (int *)fvecs_read(fname, d_out, n_out);
}

inline uint8_t *bvecs_read(const char *fname, size_t *d_out, size_t *n_out) {
  FILE *f = fopen(fname, "r");
  if (!f) {
    fprintf(stderr, "could not open %s\n", fname);
    perror("");
    abort();
  }
  int d;
  fread(&d, 1, sizeof(int), f);
  assert((d > 0 && d < 1000000) || !"unreasonable dimension");
  fseek(f, 0, SEEK_SET);
  struct stat st;
  fstat(fileno(f), &st);
  size_t sz = st.st_size;
  assert(sz % (d + 4) == 0 || !"weird file size");
  size_t n = sz / (d + 4);

  *d_out = d;
  *n_out = n;
  uint8_t *x = new uint8_t [n * (d + 4)];
  size_t nr = fread(x, sizeof(uint8_t), n * (d + 4), f);
  assert(nr == n * (d + 4) || !"could not read whole file");

  // shift array to remove row headers
  for (size_t i = 0; i < n; i++)
    memmove(x + i * d, x + 4 + i * (d + 4), d * sizeof(*x));

  fclose(f);
  return x;
}

template <class T>
inline T* bin_read(const char* fname, size_t &d_out, size_t &n_out) {
  std::ifstream ifile(fname, std::ios::binary);
  int npts, ndims;
  ifile.read((char *)&npts, sizeof(int32_t));
  ifile.read((char *)&ndims, sizeof(int32_t));
  d_out = ndims;
  n_out = npts;
  T* result = new T[1l * ndims * npts];
  ifile.read((char *) result, sizeof(T) * ndims * npts);
  return result;
}


inline float calc_recall(int* res, int* gt, int num, int dim, int k) {
  int cnt = 0;
  assert(k <= dim);
  for (int i = 0; i < num; i++) {
    std::set<int> s(gt + i * dim, gt + i * dim + k);
    for (int j = 0; j < k; j++) {
      if (s.find(res[i * k + j]) != s.end()) {
        cnt++;
      }
    }
  }
  return 1.0 * cnt / (num * k);
}

