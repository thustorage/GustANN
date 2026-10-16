#!/bin/bash

set -e

HOME_DIR=$(readlink -f $(dirname $0)/..)

pushd $HOME_DIR
echo "=========== Welcome to GustANN ==========="

echo "=========== Building GustANN ============="

./scripts/build_gustann.sh

echo "=========== Building DiskANN ============="

./scripts/build_diskann.sh

echo "====== Downloading SIFT1M dataset ========"
mkdir -p data
cd data
curl -O ftp://ftp.irisa.fr/local/texmex/corpus/sift.tar.gz
tar -xvf sift.tar.gz

echo "======== Preparing graph index ==========="
../deps/DiskANN/build/apps/utils/fvecs_to_bin float sift/sift_base.fvecs sift/sift_base.fbin
../deps/DiskANN/build/apps/build_disk_index --data_type float --dist_fn l2 --index_path_prefix index --data_path ./sift/sift_base.fbin -B 0.03 -M 64 -R 32 -L 64

echo "======== Search with GustANN ============="

../build/bin/search_mem  --query sift/sift_query.fvecs --index index_disk.index --ground_truth sift/sift_groundtruth.ivecs --data_type float --topk 10 --ef_search 50 --pq_data index_pq -R 10 -G

popd
