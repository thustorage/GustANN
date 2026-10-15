
add_executable(split_file split_file.cpp)
add_executable(analyze analyze.cpp)
add_executable(gen_small_file gen_small_file.cpp)
add_executable(trans_vec transform_vec.cpp)
add_executable(check_recall check_recall.cpp)

set(HYBRID_LINK_LIBRARY spdlog json11 argparse)
set(HYBRID_INCLUDE_LIBRARY ../include)

add_executable(search_disk_hybrid search_disk.cu
  ../src/log.cc ../src/ssd_search.cu ../src/ssd_search_kernel_hybrid.cu ../src/pq_search.cu ../src/ssd_search_hybrid.cu ../src/nav_graph.cu)
target_include_directories(search_disk_hybrid PRIVATE ${HYBRID_INCLUDE_LIBRARY})
target_link_libraries(search_disk_hybrid PRIVATE ${HYBRID_LINK_LIBRARY})
target_include_directories(search_disk_hybrid PRIVATE ../spdk)
target_link_libraries(search_disk_hybrid PRIVATE spdk_io)
target_compile_options(search_disk_hybrid
  PRIVATE "-lineinfo"
  PRIVATE "-DHYBRID_CALC"
)

add_executable(search_disk_hybrid_prof search_disk.cu
  ../src/log.cc ../src/ssd_search.cu ../src/ssd_search_kernel_hybrid.cu ../src/pq_search.cu ../src/ssd_search_hybrid.cu ../src/nav_graph.cu)
target_include_directories(search_disk_hybrid_prof PRIVATE ${HYBRID_INCLUDE_LIBRARY})
target_link_libraries(search_disk_hybrid_prof PRIVATE ${HYBRID_LINK_LIBRARY})
target_include_directories(search_disk_hybrid_prof PRIVATE ../spdk)
target_link_libraries(search_disk_hybrid_prof PRIVATE spdk_io_probe)
target_compile_options(search_disk_hybrid_prof
  PRIVATE "-DDEF_PROFILE"
  PRIVATE "-lineinfo"
  PRIVATE "-DHYBRID_CALC"
)

add_executable(search_disk_hybrid_nonav search_disk.cu
  ../src/log.cc ../src/ssd_search.cu ../src/ssd_search_kernel_hybrid.cu ../src/pq_search.cu ../src/ssd_search_hybrid.cu ../src/nav_graph.cu)
target_include_directories(search_disk_hybrid_nonav PRIVATE ${HYBRID_INCLUDE_LIBRARY})
target_link_libraries(search_disk_hybrid_nonav PRIVATE ${HYBRID_LINK_LIBRARY})
target_include_directories(search_disk_hybrid_nonav PRIVATE ../spdk)
target_link_libraries(search_disk_hybrid_nonav PRIVATE spdk_io_probe)
target_compile_options(search_disk_hybrid_nonav
  PRIVATE "-DDEF_ABLATION_GRAPH"
  PRIVATE "-lineinfo"
  PRIVATE "-DHYBRID_CALC"
)


add_executable(search_disk_hybrid_float search_disk.cu
  ../src/log.cc ../src/ssd_search.cu ../src/ssd_search_kernel_hybrid.cu ../src/pq_search.cu ../src/ssd_search_hybrid.cu ../src/nav_graph.cu)
target_include_directories(search_disk_hybrid_float PRIVATE ${HYBRID_INCLUDE_LIBRARY})
target_link_libraries(search_disk_hybrid_float PRIVATE ${HYBRID_LINK_LIBRARY})
target_include_directories(search_disk_hybrid_float PRIVATE ../spdk)
target_link_libraries(search_disk_hybrid_float PRIVATE spdk_io)
target_compile_options(search_disk_hybrid_float
  PRIVATE "-lineinfo"
  PRIVATE "-DHYBRID_CALC"
  PRIVATE "-DFLOAT_DATA"
)

IF(GUSTANN_USE_BAM)
  set(APP_LINK_LIBRARY spdlog json11 argparse
    ${CMAKE_SOURCE_DIR}/deps/bam/build/lib/libnvm.so)
  set(APP_INCLUDE_LIBRARY ../include
    ../deps/bam/include ../deps/bam/include/freestanding/include)
  
  add_executable(search_disk search_disk.cu
    ../src/log.cc ../src/ssd_search.cu ../src/ssd_search_kernel.cu ../src/pq_search.cu
    ../src/nav_graph.cu
  )
  target_include_directories(search_disk PRIVATE ${APP_INCLUDE_LIBRARY})
  target_link_libraries(search_disk PRIVATE ${APP_LINK_LIBRARY})
  target_compile_options(search_disk
    PRIVATE "-D_USE_BAM"
    PRIVATE "-lineinfo"
    PRIVATE "-O2"
  )
ENDIF()
