cmake_minimum_required(VERSION 3.25)

#强制指定 C / C++ 编译器路径  ,开发过程有可能多套环境 ， 指定版本
set(CMAKE_C_COMPILER "/usr/bin/gcc" CACHE FILEPATH "C compiler" FORCE )
set(CMAKE_CXX_COMPILER "/usr/bin/g++" CACHE FILEPATH "C++ compiler" FORCE )

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

project(pans VERSION 0.1.0 LANGUAGES CXX C)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

option(PANS_BUILD_EXAMPLES "Build examples" ON)
option(PANS_BUILD_TESTS    "Build tests"    ON)  # 是否编译测试程序
option(PANS_BUILD_TOOLS    "Build tools"    ON)  # 是否编译工具程序


if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Choose the type of build." FORCE)
endif()
set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS Debug Release RelWithDebInfo MinSizeRel)
message(STATUS "Build Type: ${CMAKE_BUILD_TYPE}")



# 统一目标输出目录
# 静态库：libpans.a
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${PROJECT_SOURCE_DIR}/lib")
# 动态库：libpans.so
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${PROJECT_SOURCE_DIR}/lib")
# 可执行程序：测试程序和工具程序
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${PROJECT_SOURCE_DIR}/bin")
#PROJECT_SOURCE_DIR 与 CMAKE_CURRENT_SOURCE_DIR 
# 根目录下的 ./lib 


include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/pansOptions.cmake")

add_subdirectory(pans)

if(PANS_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

if(PANS_BUILD_TOOLS)
    add_subdirectory(tools)
endif()