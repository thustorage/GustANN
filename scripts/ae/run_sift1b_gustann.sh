#!/bin/bash

set -o pipefail

HOME_DIR=$(readlink -f "$(dirname "$0")/../..")
source "$HOME_DIR"/scripts/ae/ae-setup.sh || exit 1
init_root_experiment "$@" || exit 1
trap finish_experiment EXIT

# please modify the place for these files (similar to scripts/setup.sh)
sift1b_setup;
require_search_inputs raw || exit 1

INDEX_FILE=${INDEX_PREFIX}_disk.index
PQ_FILE=${INDEX_PREFIX}_pq
EXEC=search_disk_hybrid
EXEC_NONAV=search_disk_hybrid_nonav
EXEC_PROF=search_disk_hybrid_prof

"$HOME_DIR"/scripts/ae/write_spdk_ae.sh "$INDEX_FILE" "$SSD_LIST" || exit 1


echo Exp: SIFT1B k=1 GustANN

# TOP-1
for ef in 12 20 30 40 50 60 70 80 90 100 120; do
    echo "[REPORT]" TOP 1 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE" --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH"  --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C 20 --topk 1 --ef_search $ef -R 500
done

# TOP-10

echo Exp: SIFT1B k=10 GustANN
for ef in 20 30 40 50 60 70 80 90 110 130 150; do
    echo "[REPORT]" TOP 10 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C 20 --topk 10 --ef_search $ef -R 500;
done

# TOP-10 MOCK
for ef in 20 30 40 50 60 70 80 90 110 130 150; do
    echo "[REPORT]" TOP 10 EF $ef MOCK
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE_MOCK" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C 20 --topk 10 --ef_search $ef -R 5;
done

# TOP-10 Latency
for B in 280 560; do
    echo "[REPORT]" TOP 10 EF 30 CTX ${B}x1x2
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                              -B ${B} -T 2 -C 1 --topk 10 --ef_search 50 -R 500;
done

for C in 1 2 4 6 8 10 12 14 16 18 20; do
    echo "[REPORT]" TOP 10 EF 30 CTX ${C}x2
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                              --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                              -B $((1120)) -T 2 -C $C --topk 10 --ef_search 50 -R 500;
done

# TOP-10 nonav

for ef in 20 30 40 50 60 70 80 90 110 130 150; do
    echo "[REPORT]" TOP 10 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC_NONAV --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                                    --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                                    -B $((1120)) -T 2 -C 20 --topk 10 --ef_search $ef -R 500;
done

echo Exp: SIFT1B k=10 GustANN
for ef in 20 30 40 50 60 70 80 90 110 130 150; do
    echo "[REPORT]" TOP 10 EF $ef
    run_case gpu_run "$HOME_DIR"/build/bin/$EXEC_PROF --query "$QUERY_FILE" --index "$INDEX_FILE"  --ground_truth "$GT_FILE" \
                                    --pq_data "$PQ_FILE" --nav_graph "$NAV_GRAPH" --ssd_list_file "$SSD_LIST" \
                                    -B $((1120)) -T 2 -C 20 --topk 10 --ef_search $ef -R 500;
done
