#!/bin/bash

# Please specify which GPU to use (for multi-GPU machines)
export CUDA_VISIBLE_DEVICES=0

# Please specify the SSD_LIST file (see README)
SSD_LIST=ssd_list.txt

# Please specify the dataset and index locations:

# Original dataset, in `bin` format
# (DiskANN provides a utility for changing fvecs/bvecs to bin in
#  `deps/DiskANN/build/apps/utils/fvecs_to_bin`)
#DATASET_FILE=/mnt/data/jhd/data/sift/100M.bbin
#DATASET_FILE=/mnt/data/jhd/data/sift/bigann.bbin
DATASET_FILE=/mnt/ssd/jhd_tmp/deep/base.fbin

# Query file, in `bvecs/fvecs` format
#QUERY_FILE=/mnt/data/jhd/data/sift/bigann_query.bvecs
QUERY_FILE=/mnt/data/jhd/data/deep/deep1B_queries.fvecs

# Ground truth file, in `ivecs` format
GT_FILE=/mnt/data/jhd/data/sift/gnd/idx_100M.ivecs

# DiskANN Index prefix, the same to DiskANN's arguments
INDEX_PREFIX=/mnt/data/jhd/index/sift100m/index_R128_L200

# GustANN's additional Pivot Graph, specify the directory to store:
#PIVOT_GRAPH=/mnt/data/jhd/index/sift100m/nav/
PIVOT_GRAPH=/mnt/data2/jhd/sift1b-ref-128/nav
PIVOT_GRAPH=/mnt/data2/jhd/deep1b-ref-128/nav

# Dataset Type:
# SIFT -> uint8
# DEEP -> float
DATA_TYPE=uint8
DATA_TYPE=float

# =================================================
# Typically, you do not need to modify the following contents.

INDEX_FILE=${INDEX_PREFIX}_disk.index
PQ_FILE=${INDEX_PREFIX}_pq

case $DATA_TYPE in
    uint8)
        DATA_SIZE=1
        EXEC=search_disk_hybrid
        ;;
    float)
        DATA_SIZE=4
        EXEC=search_disk_hybrid_float  
        ;;
    *)
        echo "[ERROR] Unrecognized data type!"
        exit -1
        ;;
esac

