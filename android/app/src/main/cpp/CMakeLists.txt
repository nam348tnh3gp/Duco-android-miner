cmake_minimum_required(VERSION 3.10)
project(ducominer)

add_library(miner SHARED
    miner_ffi.c
)

target_include_directories(miner PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

find_library(log-lib log)
target_link_libraries(miner ${log-lib})
