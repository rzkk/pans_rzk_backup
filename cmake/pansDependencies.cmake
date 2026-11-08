# 本文件的目标：把 third_party 中的源码分别配置、编译并安装到一个缓存目录，
# 再让 pans 使用这些安装结果。它刻意不使用 add_subdirectory(third_party/xxx)，
# 这样第三方库的选项、目标名和编译设置不会污染 pans 自己的 CMake 工程。
#
# 阅读时先区分 CMake 的两个阶段：
# 1. 配置阶段：执行本文件中的 set()/if()/function()/add_custom_target() 等命令，
#    生成底层构建系统（例如 Makefile 或 Ninja 文件）。
# 2. 构建阶段：真正执行 add_custom_command() 中登记的“配置第三方库、编译、安装”命令。
# execute_process() 是例外，它会在配置阶段立即执行。
#
# 当前工程状态提醒：顶层 CMakeLists.txt 需要 include() 本文件，本逻辑才会生效；
# build_commands 还要求 cmake/writeDependencyStamp.cmake 存在，kcp 包装构建还要求
# cmake/kcp/CMakeLists.txt 存在。缺少这些接入条件时，本文件的设计尚不能完整运行。

# 第三方依赖的源码根目录。CACHE PATH 表示它会写入 CMakeCache.txt，用户可以在
# 首次配置时用 -DPANS_THIRD_PARTY_DIR=/some/path 覆盖默认值，之后会沿用缓存值。
set(PANS_THIRD_PARTY_DIR "${PROJECT_SOURCE_DIR}/third_party" CACHE PATH "third-party source")
# 每个依赖最终执行 cmake --install 的根目录；这里也保存构建目录和缓存标记。
set(PANS_THIRD_PARTY_OUTPUT_DIR "${PANS_THIRD_PARTY_DIR}/output" CACHE PATH "compiled third-party output")
# 第三方库统一按 Release 构建，与 pans 自身的 CMAKE_BUILD_TYPE 相互独立。
set(PANS_THIRD_PARTY_BUILD_TYPE Release CACHE STRING "third-party build-type")
# STRINGS 主要给 cmake-gui/ccmake 提供下拉候选项；它不会自行拒绝其他字符串。
set_property(CACHE PANS_THIRD_PARTY_BUILD_TYPE PROPERTY STRINGS Debug Release RelWithDebInfo MinSizeRel)

# 是否在依赖缺失时初始化或更新 Git 子模块。
option(PANS_UPDATE_SUBMODULES "Initialize missing third-party git submodules" ON)

# 是否优先复用 third_party/output 中与当前配置兼容的已编译依赖。
# 关闭后通常会强制走第三方依赖的重新构建流程。
option(PANS_REUSE_INSTALLED_DEPENDENCIES "Reuse compatible dependencies from third_party/output" ON)


# 子模块完整性检查清单。CMake 的 list 本质上由分号分隔，因此这里先用不易出现在
# 路径中的“|”保存两个字段，遍历时再转换为“目录;哨兵文件”这两个列表元素。
# 哨兵文件（sentinel）是“依赖已存在”的证据。只检查目录不够，因为 Git 可能已经
# 创建了空的子模块目录，但尚未检出其中内容。
set(_pans_required_submodules
    "third_party/yaml-cpp|CMakeLists.txt"
    "third_party/abseil-cpp|CMakeLists.txt"
    "third_party/protobuf|CMakeLists.txt"
    "third_party/rapidjson|include/rapidjson/document.h"
    "third_party/tinyxml2|CMakeLists.txt"
    "third_party/kcp|ikcp.c"
    "third_party/zlib|CMakeLists.txt"
)

# 安静地查找 Git。只有在需要初始化或更新子模块时，后续逻辑才需要使用它；
# 使用 QUIET 可避免未安装 Git 时在这里直接输出无关的查找信息。
find_package(Git QUIET)

function(pans_init_third_party_submodules)
    # function() 会创建局部变量作用域；这里不会污染调用者的 missing_submodules。
    set(missing_submodules)
    # IN LISTS 后面写的是“变量名”，不是 ${变量值}。
    foreach(entry IN LISTS _pans_required_submodules)
        # "a|b" -> "a;b"；分号让 parts 成为含两个元素的 CMake 列表。
        string(REPLACE "|" ";" parts "${entry}")
        list(GET parts 0 submodule_path)
        list(GET parts 1 sentinel)
        if(NOT EXISTS "${PROJECT_SOURCE_DIR}/${submodule_path}/${sentinel}")
            list(APPEND missing_submodules "${submodule_path}")
        endif()
    endforeach()
    # CMake 的 if() 会把空字符串、OFF、FALSE、0 等视为假。
    if(NOT missing_submodules)
        return()
    endif()

    # 用户明确禁止自动更新时立即停止。FATAL_ERROR 会终止“配置阶段”，避免到链接时
    # 才出现难以理解的头文件或库缺失错误。
    if(NOT PANS_UPDATE_SUBMODULES)
        message(FATAL_ERROR
            "Missing third-party source trees: ${missing_submodules}\n"
            "Enable PANS_UPDATE_SUBMODULES or run:\n"
            "  git submodule update --init --recursive")
    endif()

    # 网站下载的源码压缩包通常没有 .git，因此不可能执行 git submodule update。
    if(NOT EXISTS "${PROJECT_SOURCE_DIR}/.git")
        message(FATAL_ERROR
            "Missing third-party source trees: ${missing_submodules}\n"
            "The source tree is not a git checkout, so CMake cannot initialize them.")
    endif()

    if(NOT Git_FOUND)
        message(FATAL_ERROR "Git is required to initialize missing submodules.")
    endif()

    message(STATUS "Initializing missing git submodules: ${missing_submodules}")
    # execute_process() 在 CMake 配置阶段立即运行外部进程。
    # -- 后面的内容只会被 Git 当作路径，避免路径被误认为命令行选项。
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" submodule update --init --recursive -- ${missing_submodules}
        WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
        RESULT_VARIABLE submodule_result
        OUTPUT_VARIABLE submodule_output
        ERROR_VARIABLE submodule_error
    )

    if(NOT submodule_result EQUAL 0)
        message(FATAL_ERROR
            "git submodule update failed (exit=${submodule_result}):\n"
            "${submodule_output}${submodule_error}")
    endif()

    # Git 返回 0 仍不代表每个所需文件一定存在，因此再次检查实际结果。
    foreach(entry IN LISTS _pans_required_submodules)
        string(REPLACE "|" ";" parts "${entry}")
        list(GET parts 0 submodule_path)
        list(GET parts 1 sentinel)
        if(NOT EXISTS "${PROJECT_SOURCE_DIR}/${submodule_path}/${sentinel}")
            message(FATAL_ERROR
                "Required third-party source is still missing: "
                "${submodule_path}/${sentinel}")
        endif()
    endforeach()

endfunction()

pans_init_third_party_submodules()


# 取得依赖源码版本，作为后面缓存键的一部分。源码版本变化时，旧二进制缓存必须失效。
function(pans_get_source_revision source_dir output_variable)
    # Git 仓库（包括 .git 为文件的子模块）使用精确 commit ID。
    if(Git_FOUND AND EXISTS "${source_dir}/.git")
        execute_process(
            COMMAND "${GIT_EXECUTABLE}" -C "${source_dir}" rev-parse HEAD
            RESULT_VARIABLE revision_result
            OUTPUT_VARIABLE revision
            ERROR_VARIABLE revision_error
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        if(NOT revision_result EQUAL 0)
            message(FATAL_ERROR "Failed to read third-party revision in ${source_dir}: ${revision_error}")
        endif()
    else()
        # 非 Git 源码只能退化为文件哈希。注意：这里只哈希 CMakeLists.txt，若其他源码
        # 被修改而此文件不变，缓存不会失效；这是当前实现的一个准确性限制。
        file(SHA256 "${source_dir}/CMakeLists.txt" revision)
    endif()
    # 函数有独立作用域，PARENT_SCOPE 才能把结果写回调用者指定的变量。
    set(${output_variable} "${revision}" PARENT_SCOPE)
endfunction()


function(pans_add_cmake_dependency)
    # 这是本文件的核心函数，用统一流程管理一个“使用 CMake 构建”的依赖。
    # cmake_parse_arguments 的三组参数依次是：布尔选项、单值参数、多值参数。
    # PARSE_ARGV 0 表示从本函数的第 0 个实参开始解析，并把结果放进 dep_ 前缀变量。
    cmake_parse_arguments(PARSE_ARGV 0 dep ""
        "NAME;SOURCE_DIR;SOURCE_REVISION"
        "CMAKE_ARGS;SENTINELS;DEPENDS;KEY_MATERIAL")

    # 尽早验证函数契约，让调用错误停在最接近根因的位置。
    if(NOT dep_NAME OR NOT dep_SOURCE_DIR OR NOT dep_SOURCE_REVISION)
        message(FATAL_ERROR "pans_add_cmake_dependency requires NAME, SOURCE_DIR and SOURCE_REVISION")
    endif()
    if(NOT dep_SENTINELS)
        message(FATAL_ERROR "pans_add_cmake_dependency(${dep_NAME}) requires SENTINELS")
    endif()

    # 二进制库是否兼容，不只取决于源码版本，还取决于编译器、平台、生成器、运行库、
    # 架构和构建选项，这些共同构成 ABI/构建环境指纹。任一项变化就应使用新缓存。
    string(CONCAT cache_material
        "${dep_SOURCE_REVISION};${CMAKE_C_COMPILER};${CMAKE_C_COMPILER_ID};"
        "${CMAKE_C_COMPILER_VERSION};${CMAKE_CXX_COMPILER};${CMAKE_CXX_COMPILER_ID};"
        "${CMAKE_CXX_COMPILER_VERSION};${CMAKE_SYSTEM_NAME};${CMAKE_SYSTEM_PROCESSOR};"
        "${CMAKE_GENERATOR};${CMAKE_GENERATOR_PLATFORM};${CMAKE_GENERATOR_TOOLSET};"
        "${CMAKE_OSX_ARCHITECTURES};${CMAKE_OSX_DEPLOYMENT_TARGET};"
        "${CMAKE_MSVC_RUNTIME_LIBRARY};${PANS_THIRD_PARTY_BUILD_TYPE};static;"
        "${dep_CMAKE_ARGS};${dep_KEY_MATERIAL}")

    # SHA256 把很长的配置指纹变为稳定键；目录名只取前 16 位以保持路径简短，
    # stamp 文件仍保存完整哈希以降低误判风险。
    string(SHA256 cache_key "${cache_material}")
    string(SUBSTRING "${cache_key}" 0 16 cache_key_short)
    
    set(install_dir "${PANS_THIRD_PARTY_OUTPUT_DIR}/${dep_NAME}/${cache_key_short}")
    set(build_dir "${PANS_THIRD_PARTY_OUTPUT_DIR}/build/${dep_NAME}-${cache_key_short}")
    set(cache_stamp "${install_dir}/.pans-cache-${cache_key}")

    # SENTINELS 是安装结果中必须存在的代表文件，例如包配置、公开头文件、静态库。
    # 仅有安装目录不能证明上一次构建完整成功，因此需要逐个检查。
    set(installed_outputs "${cache_stamp}")
    set(cache_complete TRUE)
    foreach(sentinel IN LISTS dep_SENTINELS)
        if(IS_ABSOLUTE "${sentinel}")
            set(sentinel_path "${sentinel}")
        else()
            set(sentinel_path "${install_dir}/${sentinel}")
        endif()
        list(APPEND installed_outputs "${sentinel_path}")
        if(NOT EXISTS "${sentinel_path}")
            set(cache_complete FALSE)
        endif()
    endforeach()

    if(NOT EXISTS "${cache_stamp}")
        set(cache_complete FALSE)
    endif()

    # 用列表逐项构造命令，而不是拼成一个大字符串。VERBATIM 会负责路径转义，
    # 因而包含空格的路径也能作为一个完整参数传递。
    set(configure_command "${CMAKE_COMMAND}" -S "${dep_SOURCE_DIR}" -B "${build_dir}" -G "${CMAKE_GENERATOR}")
    # VS/Xcode 等生成器可能需要平台(-A)和工具集(-T)，第三方库必须与主工程一致。
    if(CMAKE_GENERATOR_PLATFORM)
        list(APPEND configure_command -A "${CMAKE_GENERATOR_PLATFORM}")
    endif()
    if(CMAKE_GENERATOR_TOOLSET)
        list(APPEND configure_command -T "${CMAKE_GENERATOR_TOOLSET}")
    endif()
    
    # 所有依赖都安装到独立前缀、生成位置无关的静态库，并关闭它们自己的测试。
    list(APPEND configure_command
        "-DCMAKE_INSTALL_PREFIX=${install_dir}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DCMAKE_BUILD_TYPE=${PANS_THIRD_PARTY_BUILD_TYPE}"
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
        "-DBUILD_TESTING=OFF"
    )
    
    if(CMAKE_C_COMPILER)
        list(APPEND configure_command "-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}")
    endif()
    if(CMAKE_CXX_COMPILER)
        list(APPEND configure_command "-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}")
    endif()
    # 交叉编译时 toolchain file 决定目标平台，遗漏它会错误地构建成本机库。
    if(CMAKE_TOOLCHAIN_FILE)
        list(APPEND configure_command "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}")
    endif()
    if(CMAKE_MSVC_RUNTIME_LIBRARY)
        list(APPEND configure_command "-DCMAKE_MSVC_RUNTIME_LIBRARY=${CMAKE_MSVC_RUNTIME_LIBRARY}")
    endif()
    if(CMAKE_OSX_ARCHITECTURES)
        list(APPEND configure_command "-DCMAKE_OSX_ARCHITECTURES=${CMAKE_OSX_ARCHITECTURES}")
    endif()
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        list(APPEND configure_command "-DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    # 每个依赖自己的开关最后追加，调用者可按该依赖支持的选项定制构建。
    list(APPEND configure_command ${dep_CMAKE_ARGS})

    # 登记四步流水线：配置 -> 编译 -> 安装 -> 成功标记。
    # 这些 COMMAND 此时不会执行，要到用户运行 cmake --build 时才执行。
    # stamp 必须最后写入；若前一步失败，缓存不会被误认为完整。
    set(build_commands
        COMMAND ${configure_command}
        COMMAND "${CMAKE_COMMAND}" --build "${build_dir}" --config "${PANS_THIRD_PARTY_BUILD_TYPE}" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL}"
        COMMAND "${CMAKE_COMMAND}" --install "${build_dir}" --config "${PANS_THIRD_PARTY_BUILD_TYPE}"
        COMMAND "${CMAKE_COMMAND}" "-DPANS_DEPS_STAMP_FILE=${cache_stamp}" "-DPANS_DEPS_STAMP_VALUE=${cache_key}" -P "${PROJECT_SOURCE_DIR}/cmake/writeDependencyStamp.cmake"
    )

    # CMake target 名统一使用下划线，避免依赖名称中的连字符影响后续引用习惯。
    set(ready_target "pans_dep_${dep_NAME}_ready")
    string(REPLACE "-" "_" ready_target "${ready_target}")
    
    if(PANS_REUSE_INSTALLED_DEPENDENCIES)
        # OUTPUT 形式是“有产物的构建规则”：产物都存在且未过期时，构建工具可跳过命令。
        add_custom_command(
            OUTPUT ${installed_outputs}
            ${build_commands}
            COMMENT "Building and installing third-party dependency: ${dep_NAME}"
            VERBATIM
            COMMAND_EXPAND_LISTS
        )
        add_custom_target("${ready_target}" DEPENDS ${installed_outputs})
    else()
        # 自定义 target 没有 OUTPUT，因而每次构建该 target 都会重新执行命令。
        add_custom_target("${ready_target}"
            ${build_commands}
            COMMENT "Rebuilding third-party dependency: ${dep_NAME}"
            VERBATIM
            COMMAND_EXPAND_LISTS
        )
    endif()
    # target 级依赖只规定构建先后。例如 protobuf 必须等 Abseil 与 zlib 安装完成，
    # 才能在自己的配置阶段通过 absl_DIR/ZLIB_ROOT 找到它们。
    if(dep_DEPENDS)
        add_dependencies("${ready_target}" ${dep_DEPENDS})
    endif()
    
    if(cache_complete AND PANS_REUSE_INSTALLED_DEPENDENCIES)
        message(STATUS "${dep_NAME}: reusing ${install_dir}")
    else()
        message(STATUS "${dep_NAME}: build scheduled; output ${install_dir}")
    endif()
    
    # 把函数计算结果作为“返回值”导出。例如 NAME yaml-cpp 会得到
    # PANS_YAML_CPP_INSTALL_DIR、PANS_YAML_CPP_CACHE_COMPLETE 等变量。
    string(TOUPPER "${dep_NAME}" variable_prefix)
    string(REPLACE "-" "_" variable_prefix "${variable_prefix}")
    set("PANS_${variable_prefix}_INSTALL_DIR" "${install_dir}" PARENT_SCOPE)
    set("PANS_${variable_prefix}_CACHE_KEY" "${cache_key}" PARENT_SCOPE)
    set("PANS_${variable_prefix}_CACHE_COMPLETE" "${cache_complete}" PARENT_SCOPE)
    set("PANS_${variable_prefix}_DEPENDENCY_TARGET" "${ready_target}" PARENT_SCOPE)

endfunction()



# CMAKE_STATIC_LIBRARY_PREFIX/SUFFIX 由平台决定：Linux 常为 lib + .a，
# Windows 常为 "" + .lib。先做模板，再替换 @NAME@，可避免写死平台文件名。
set(_pans_static_library "${CMAKE_STATIC_LIBRARY_PREFIX}@NAME@${CMAKE_STATIC_LIBRARY_SUFFIX}")

# -------- abseil-cpp --------
# 每个依赖实例都遵循同一模式：确定源码 -> 取得版本 -> 推导产物名 -> 调核心函数。
set(_pans_absl_source "${PANS_THIRD_PARTY_DIR}/abseil-cpp")
pans_get_source_revision("${_pans_absl_source}" _pans_absl_revision)
string(REPLACE "@NAME@" "absl_base" _pans_absl_library "${_pans_static_library}")
pans_add_cmake_dependency(
    NAME abseil-cpp
    SOURCE_DIR "${_pans_absl_source}"
    SOURCE_REVISION "${_pans_absl_revision}"
    CMAKE_ARGS
        # 只生成静态库；开启 install 规则；让 Abseil 继承调用者要求的 C++ 标准。
        "-DBUILD_SHARED_LIBS=OFF"
        "-DABSL_ENABLE_INSTALL=ON"
        "-DABSL_PROPAGATE_CXX_STD=ON"
        "-DABSL_BUILD_TESTING=OFF"
    SENTINELS
        # 同时检查 CMake package、公开头文件和一个核心库，避免只安装了一部分。
        "lib/cmake/absl/abslConfig.cmake"
        "include/absl/base/config.h"
        "lib/${_pans_absl_library}"
)

# -------- zlib --------
set(_pans_zlib_source "${PANS_THIRD_PARTY_DIR}/zlib")
pans_get_source_revision("${_pans_zlib_source}" _pans_zlib_revision)
string(REPLACE "@NAME@" "z" _pans_zlib_library "${_pans_static_library}")
if(MSVC)
    # 同一个库在 MSVC 与 Unix 工具链下使用不同的基础文件名。
    string(REPLACE "@NAME@" "zlibstatic" _pans_zlib_library "${_pans_static_library}")
endif()
pans_add_cmake_dependency(
    NAME zlib
    SOURCE_DIR "${_pans_zlib_source}"
    SOURCE_REVISION "${_pans_zlib_revision}"
    CMAKE_ARGS
        "-DZLIB_BUILD_TESTING=OFF"
        "-DZLIB_BUILD_SHARED=OFF"
        "-DZLIB_BUILD_STATIC=ON"
        "-DZLIB_INSTALL=ON"
    SENTINELS
        "lib/cmake/zlib/ZLIBConfig.cmake"
        "include/zlib.h"
        "lib/${_pans_zlib_library}"
)

# -------- yaml-cpp --------
set(_pans_yaml_source "${PANS_THIRD_PARTY_DIR}/yaml-cpp")
pans_get_source_revision("${_pans_yaml_source}" _pans_yaml_revision)
string(REPLACE "@NAME@" "yaml-cpp" _pans_yaml_library "${_pans_static_library}")
pans_add_cmake_dependency(
    NAME yaml-cpp
    SOURCE_DIR "${_pans_yaml_source}"
    SOURCE_REVISION "${_pans_yaml_revision}"
    CMAKE_ARGS
        "-DBUILD_SHARED_LIBS=OFF"
        "-DYAML_BUILD_SHARED_LIBS=OFF"
        "-DYAML_CPP_BUILD_TESTS=OFF"
        "-DYAML_CPP_BUILD_TOOLS=OFF"
        "-DYAML_CPP_FORMAT_SOURCE=OFF"
        "-DYAML_CPP_INSTALL=ON"
        "-DYAML_CPP_DISABLE_UNINSTALL=ON"
    SENTINELS
        "lib/cmake/yaml-cpp/yaml-cpp-config.cmake"
        "include/yaml-cpp/yaml.h"
        "lib/${_pans_yaml_library}"
)

# -------- tinyxml2 --------
set(_pans_tinyxml2_source "${PANS_THIRD_PARTY_DIR}/tinyxml2")
pans_get_source_revision("${_pans_tinyxml2_source}" _pans_tinyxml2_revision)
string(REPLACE "@NAME@" "tinyxml2" _pans_tinyxml2_library "${_pans_static_library}")
pans_add_cmake_dependency(
    NAME tinyxml2
    SOURCE_DIR "${_pans_tinyxml2_source}"
    SOURCE_REVISION "${_pans_tinyxml2_revision}"
    CMAKE_ARGS
        "-DBUILD_SHARED_LIBS=OFF"
        "-Dtinyxml2_SHARED_LIBS=OFF"
        "-Dtinyxml2_BUILD_TESTING=OFF"
    SENTINELS
        "lib/cmake/tinyxml2/tinyxml2-config.cmake"
        "include/tinyxml2.h"
        "lib/${_pans_tinyxml2_library}"
)

# -------- kcp --------
set(_pans_kcp_source "${PANS_THIRD_PARTY_DIR}/kcp")
pans_get_source_revision("${_pans_kcp_source}" _pans_kcp_revision)
# kcp 自带的构建规则不一定满足本项目的安装/导出要求，因此设计上使用
# cmake/kcp/CMakeLists.txt 作为包装工程。包装文件变化也必须令缓存失效。
file(SHA256 "${PROJECT_SOURCE_DIR}/cmake/kcp/CMakeLists.txt" _pans_kcp_wrapper_hash)
string(REPLACE "@NAME@" "kcp" _pans_kcp_library "${_pans_static_library}")
pans_add_cmake_dependency(
    NAME kcp
    SOURCE_DIR "${PROJECT_SOURCE_DIR}/cmake/kcp"
    SOURCE_REVISION "${_pans_kcp_revision}"
    KEY_MATERIAL "wrapper=${_pans_kcp_wrapper_hash}"
    CMAKE_ARGS
        "-DPANS_KCP_SOURCE_DIR=${_pans_kcp_source}"
        "-DBUILD_SHARED_LIBS=OFF"
    SENTINELS
        "lib/cmake/kcp/kcp-config.cmake"
        "include/ikcp.h"
        "lib/${_pans_kcp_library}"
)

# -------- protobuf：依赖预先安装好的 Abseil 与 zlib --------
set(_pans_protobuf_source "${PANS_THIRD_PARTY_DIR}/protobuf")
pans_get_source_revision("${_pans_protobuf_source}" _pans_protobuf_revision)
string(REPLACE "@NAME@" "protobuf" _pans_protobuf_library "${_pans_static_library}")
if(MSVC)
    string(REPLACE "@NAME@" "libprotobuf" _pans_protobuf_library "${_pans_static_library}")
endif()
set(_pans_protoc "bin/protoc${CMAKE_EXECUTABLE_SUFFIX}")
pans_add_cmake_dependency(
    NAME protobuf
    SOURCE_DIR "${_pans_protobuf_source}"
    SOURCE_REVISION "${_pans_protobuf_revision}"
    # protobuf 的二进制结果还取决于其依赖的具体缓存版本。因此即使 protobuf
    # 自身源码不变，只要 Abseil/zlib 变化，也必须生成新的 protobuf 缓存。
    KEY_MATERIAL
        "abseil=${PANS_ABSEIL_CPP_CACHE_KEY}"
        "zlib=${PANS_ZLIB_CACHE_KEY}"
    DEPENDS
        # 这是“构建顺序”；先完成两个 ready target，再配置 protobuf。
        "${PANS_ABSEIL_CPP_DEPENDENCY_TARGET}"
        "${PANS_ZLIB_DEPENDENCY_TARGET}"
    CMAKE_ARGS
        "-DCMAKE_CXX_STANDARD=20"
        "-DBUILD_SHARED_LIBS=OFF"
        "-Dprotobuf_BUILD_SHARED_LIBS=OFF"
        "-Dprotobuf_BUILD_TESTS=OFF"
        "-Dprotobuf_BUILD_CONFORMANCE=OFF"
        "-Dprotobuf_BUILD_EXAMPLES=OFF"
        "-Dprotobuf_LOCAL_DEPENDENCIES_ONLY=ON"
        "-Dprotobuf_WITH_ZLIB=ON"
        # 给 protobuf 的 find_package 提供精确位置，避免误用系统中的其他版本。
        "-Dabsl_DIR=${PANS_ABSEIL_CPP_INSTALL_DIR}/lib/cmake/absl"
        "-DZLIB_ROOT=${PANS_ZLIB_INSTALL_DIR}"
        "-DZLIB_INCLUDE_DIR=${PANS_ZLIB_INSTALL_DIR}/include"
        "-DZLIB_LIBRARY=${PANS_ZLIB_INSTALL_DIR}/lib/${_pans_zlib_library}"
    SENTINELS
        "lib/cmake/protobuf/protobuf-config.cmake"
        "include/google/protobuf/message.h"
        "lib/${_pans_protobuf_library}"
        "${_pans_protoc}"
)

# RapidJSON 是纯头文件库：使用者只需要 include 路径，没有需要链接的 .a/.so，
# 所以用 INTERFACE IMPORTED target 表达“使用要求”，无需进入编译安装缓存流水线。
if(NOT TARGET rapidjson::rapidjson)
    add_library(rapidjson::rapidjson INTERFACE IMPORTED GLOBAL)
    set_target_properties(rapidjson::rapidjson PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${PANS_THIRD_PARTY_DIR}/rapidjson/include"
    )
endif()
message(STATUS "rapidjson: header-only; using ${PANS_THIRD_PARTY_DIR}/rapidjson/include")

# 聚合 target 本身不产生文件，只依赖所有第三方 ready target。
# ALL 表示普通的 cmake --build 也会默认构建它，不必手工指定 target 名。
# 但 ALL 不表示“先于其他 ALL target 完成”。将来 pans 真正链接这些库时，还要用
# add_dependencies(消费者 pans_third_party_dependencies) 建立明确顺序，避免并行构建竞态。
add_custom_target(pans_third_party_dependencies ALL)
add_dependencies(pans_third_party_dependencies
    "${PANS_ABSEIL_CPP_DEPENDENCY_TARGET}"
    "${PANS_ZLIB_DEPENDENCY_TARGET}"
    "${PANS_YAML_CPP_DEPENDENCY_TARGET}"
    "${PANS_TINYXML2_DEPENDENCY_TARGET}"
    "${PANS_KCP_DEPENDENCY_TARGET}"
    "${PANS_PROTOBUF_DEPENDENCY_TARGET}"
)

# -------- pans 当前直接依赖 --------
# Threads 是 CMake 的跨平台线程抽象；使用 Threads::Threads 比硬编码 -lpthread 更可移植。
find_package(Threads REQUIRED)

# libdw 用于 Linux 上读取 DWARF 调试信息。PkgConfig::PANS_LIBDW imported target 会携带
# include 路径、库路径和链接选项，比手工读取 PANS_LIBDW_LIBRARIES 更完整。
# Debian/Ubuntu 缺失时通常需要安装 libdw-dev。
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(PANS_LIBDW REQUIRED IMPORTED_TARGET libdw)
endif()

if(PANS_YAML_CPP_CACHE_COMPLETE)
    # 缓存完整时，直接读取 yaml-cpp 安装生成的 package config。
    # NO_DEFAULT_PATH 很重要：只接受本脚本选定的版本，不回退到系统版本。
    find_package(yaml-cpp CONFIG REQUIRED PATHS "${PANS_YAML_CPP_INSTALL_DIR}" NO_DEFAULT_PATH)
else()
    # 首次配置时 yaml-cpp 尚未在“构建阶段”安装，find_package 当然还找不到它。
    # 因此先手工声明一个 IMPORTED target，位置指向未来将产生的静态库。
    # 预建 include 目录是因为 CMake 会检查 imported target 的接口路径是否存在。
    # IMPORTED target 只描述外部文件，并不会自动构建该文件；消费者仍需依赖对应的
    # ready target（或上面的聚合 target），才能保证链接前静态库已经生成。
    file(MAKE_DIRECTORY "${PANS_YAML_CPP_INSTALL_DIR}/include")
    add_library(yaml-cpp::yaml-cpp STATIC IMPORTED GLOBAL)
    set_target_properties(yaml-cpp::yaml-cpp PROPERTIES
        IMPORTED_LOCATION "${PANS_YAML_CPP_INSTALL_DIR}/lib/${_pans_yaml_library}"
        INTERFACE_COMPILE_DEFINITIONS YAML_CPP_STATIC_DEFINE
        INTERFACE_INCLUDE_DIRECTORIES "${PANS_YAML_CPP_INSTALL_DIR}/include"
    )
endif()

# 安装 pans 时，把已构建的依赖一并复制进同一个安装前缀，使最终安装树包含
# lib、include 和各依赖的 CMake package 文件。缓存 stamp 是内部实现，不应发布。
foreach(_pans_dependency_install_dir IN ITEMS
    "${PANS_YAML_CPP_INSTALL_DIR}"
    "${PANS_ABSEIL_CPP_INSTALL_DIR}"
    "${PANS_ZLIB_INSTALL_DIR}"
    "${PANS_PROTOBUF_INSTALL_DIR}"
    "${PANS_TINYXML2_INSTALL_DIR}"
    "${PANS_KCP_INSTALL_DIR}"
)
    install(
        DIRECTORY "${_pans_dependency_install_dir}/"
        DESTINATION "."
        PATTERN ".pans-cache-*" EXCLUDE
    )
endforeach()

install(
    # RapidJSON 没有单独的安装缓存，直接复制其公开头文件。
    DIRECTORY "${PANS_THIRD_PARTY_DIR}/rapidjson/include/"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)

# 清理仅供本文件内部使用的目录作用域变量。函数内部变量会自动随函数返回而消失，
# 但这两个变量是在文件所在目录作用域创建的，所以显式取消可减少命名污染。
unset(_pans_required_submodules)
unset(_pans_static_library)
