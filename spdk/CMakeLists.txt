find_package(PkgConfig REQUIRED)

set(SPDK_PATH "../deps/spdk")
set(ENV{PKG_CONFIG_PATH} "${SPDK_PATH}/build/lib/pkgconfig")

execute_process(
    COMMAND pkg-config --libs spdk_nvme spdk_env_dpdk
    OUTPUT_VARIABLE SPDK_LIBRARY
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )

execute_process(
    COMMAND pkg-config --libs --static spdk_syslibs
    OUTPUT_VARIABLE SPDK_SYSLIBS
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )


separate_arguments(SPDK_LIBRARY UNIX_COMMAND "${SPDK_LIBRARY}")
separate_arguments(SPDK_SYSLIBS UNIX_COMMAND "${SPDK_SYSLIBS}")

message(STATUS "SPDK libraries: ${SPDK_LIBRARY}")

message(STATUS "SPDK system libraries: ${SPDK_SYSLIBS}")

add_library(spdk_wrapper spdk_wrapper.cc)
target_include_directories(spdk_wrapper PUBLIC 
    ${SPDK_PATH}/build/include
)

target_compile_options(spdk_wrapper PUBLIC "-O2")
target_link_libraries(spdk_wrapper PRIVATE spdlog)
target_link_options(spdk_wrapper INTERFACE
    -pthread
    "SHELL:-Wl,--whole-archive"
    "SHELL:-Wl,-Bstatic"
    ${SPDK_LIBRARY}
    "SHELL:-Wl,-Bdynamic"
    "SHELL:-Wl,--no-whole-archive"
    ${SPDK_SYSLIBS}
)




add_library(spdk_io spdk_io.cpp)
target_link_libraries(spdk_io PUBLIC spdk_wrapper)
target_compile_options(spdk_io PUBLIC "-O2")

add_library(spdk_io_probe spdk_io.cpp)
target_link_libraries(spdk_io_probe PUBLIC spdk_wrapper)
target_compile_options(spdk_io_probe PUBLIC "-O2")
target_compile_definitions(spdk_io_probe PUBLIC DATA_PROBE)

add_executable(test_spdk test_spdk.cpp)
target_link_libraries(test_spdk spdk_wrapper)
target_compile_options(test_spdk PUBLIC "-O2")

add_executable(spdk_write spdk_write.cpp)
target_link_libraries(spdk_write spdk_wrapper)

add_executable(test_spdk_2 test_spdk_2.cpp)
target_link_libraries(test_spdk_2 spdk_io)
target_compile_options(test_spdk_2 PUBLIC "-O2")


add_executable(range_test range_test.cpp)
target_link_libraries(range_test spdk_io)
target_compile_options(range_test
  PUBLIC "-O2"
  PUBLIC "-g")
