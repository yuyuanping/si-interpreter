cmake_minimum_required(VERSION 3.16)
project("si-mt" VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Vendored llama.cpp (v0.9.0) — see cpp/llama.cpp/LICENSE. Trimmed to ggml/src/common/
# include/vendor/cmake: everything the `llama` + `llama-common` targets need.
set(LLAMA_SRC ${CMAKE_CURRENT_LIST_DIR}/llama.cpp)
add_subdirectory(${LLAMA_SRC} build-llama)

# Unity builds generate #include lines with ABSOLUTE source paths; clang on Windows mangles
# the non-ASCII project path (同声传译) in those lines and fails to open the files. Per-file
# compilation costs a few minutes more once, then caches.
set_property(TARGET llama PROPERTY UNITY_BUILD OFF)

add_library(si_mt SHARED si-mt.cpp)

target_include_directories(si_mt PRIVATE
        ${LLAMA_SRC}
        ${LLAMA_SRC}/common
        ${LLAMA_SRC}/include
        ${LLAMA_SRC}/ggml/include)

target_link_libraries(si_mt
        llama
        llama-common
        android
        log)
