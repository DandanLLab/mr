cmake_minimum_required(VERSION 3.18)
project(quickjs_c_bridge C)

# QuickJS C 源码目录（项目根目录 quickjs/，鸿蒙 / Android / iOS 共享同一份源码）
#
# 本 CMakeLists.txt 由 CI 从 quickjs/ohos/CMakeLists.txt 复制到
# ohos/entry/src/main/cpp/CMakeLists.txt 后执行。
# 路径关系：ohos/entry/src/main/cpp/ → 项目根 = ../../../../.. （5 级）
get_filename_component(PROJECT_ROOT_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

# native_core 模块（桥接初始化与扩展入口）
set(NATIVE_CORE_DIR ${PROJECT_ROOT_DIR}/native_core)

# QuickJS 源码文件（与 android/app/src/main/cpp/CMakeLists.txt 保持一致）
# 不编译 quickjs-libc.c（鸿蒙上不需要标准库辅助函数，且部分 POSIX 调用不兼容）
set(QUICKJS_SOURCES
    ${PROJECT_ROOT_DIR}/quickjs/quickjs.c
    ${PROJECT_ROOT_DIR}/quickjs/cutils.c
    ${PROJECT_ROOT_DIR}/quickjs/dtoa.c
    ${PROJECT_ROOT_DIR}/quickjs/libregexp.c
    ${PROJECT_ROOT_DIR}/quickjs/libunicode.c
    ${PROJECT_ROOT_DIR}/quickjs/quickjs_bridge.c
    ${PROJECT_ROOT_DIR}/quickjs/lzstring.c
    ${PROJECT_ROOT_DIR}/quickjs/batch_decompress.c
    ${PROJECT_ROOT_DIR}/quickjs/html_native.c
    ${PROJECT_ROOT_DIR}/quickjs/charset_conv.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/md5.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/sha1.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/sha256.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/hmac_sha256.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/aes.c
    ${PROJECT_ROOT_DIR}/quickjs/handle_table.c
    ${PROJECT_ROOT_DIR}/quickjs/memory_tracker.c
    ${PROJECT_ROOT_DIR}/quickjs/image_native.c
    ${NATIVE_CORE_DIR}/bridge_init.c
)

# libwebp: WebP 图片解码（仅解码器，不含编码器）
# 与 android/app/src/main/cpp/CMakeLists.txt 保持一致
set(LIBWEBP_SRC_DIR ${PROJECT_ROOT_DIR}/quickjs/libwebp-1.5.0/src)
file(GLOB LIBWEBP_DEC_SOURCES ${LIBWEBP_SRC_DIR}/dec/*.c)
file(GLOB LIBWEBP_DSP_SOURCES ${LIBWEBP_SRC_DIR}/dsp/*.c)
file(GLOB LIBWEBP_UTILS_SOURCES ${LIBWEBP_SRC_DIR}/utils/*.c)
set(LIBWEBP_SOURCES ${LIBWEBP_DEC_SOURCES} ${LIBWEBP_DSP_SOURCES} ${LIBWEBP_UTILS_SOURCES})

# 编译为共享库 libquickjs_c_bridge.so
# Dart FFI 通过 DynamicLibrary.open('libquickjs_c_bridge.so') 加载
add_library(quickjs_c_bridge SHARED ${QUICKJS_SOURCES} ${LIBWEBP_SOURCES})

# 体积优化（与 Android 版本保持一致）
# -Oz：极致体积优先
# -ffunction-sections -fdata-sections：配合 --gc-sections 裁剪未引用代码
# -fomit-frame-pointer：释放 fp 寄存器
target_compile_options(quickjs_c_bridge PRIVATE
    -Wno-implicit-function-declaration
    -Wno-unused-parameter
    -Wno-sign-compare
    -Wno-unused-function
    -Wno-unused-variable
    -Oz
    -ffunction-sections
    -fdata-sections
    -fomit-frame-pointer
)

# quickjs.c 巨无霸，CI runner 上易 OOM，单独降级优化（同 Android 策略）
# -fno-lto / -fno-inline-functions / -fno-unroll-loops / -fno-tree-vectorize
# -mllvm -inline-threshold=0（OHOS NDK 基于 LLVM，支持该选项）
set_source_files_properties(${PROJECT_ROOT_DIR}/quickjs/quickjs.c PROPERTIES
    COMPILE_FLAGS "-Oz -fno-lto -fno-inline-functions -fno-unroll-loops -fno-tree-vectorize -mllvm -inline-threshold=0"
)
set_source_files_properties(
    ${PROJECT_ROOT_DIR}/quickjs/cutils.c
    ${PROJECT_ROOT_DIR}/quickjs/dtoa.c
    ${PROJECT_ROOT_DIR}/quickjs/libregexp.c
    ${PROJECT_ROOT_DIR}/quickjs/libunicode.c
    ${PROJECT_ROOT_DIR}/quickjs/quickjs_bridge.c
    ${PROJECT_ROOT_DIR}/quickjs/lzstring.c
    ${PROJECT_ROOT_DIR}/quickjs/batch_decompress.c
    ${PROJECT_ROOT_DIR}/quickjs/html_native.c
    ${PROJECT_ROOT_DIR}/quickjs/charset_conv.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/md5.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/sha1.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/sha256.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/hmac_sha256.c
    ${PROJECT_ROOT_DIR}/quickjs/crypto/aes.c
    ${PROJECT_ROOT_DIR}/quickjs/handle_table.c
    ${PROJECT_ROOT_DIR}/quickjs/memory_tracker.c
    ${PROJECT_ROOT_DIR}/quickjs/image_native.c
    ${NATIVE_CORE_DIR}/bridge_init.c
    PROPERTIES COMPILE_FLAGS "-flto"
)

# 链接期优化（OHOS NDK 的 lld 支持 --gc-sections / --version-script / -flto）
# 注意：鸿蒙 SDK 的 crtn.o 与 lld --icf=safe 不兼容（SHT_LLVM_ADDRSIG 冲突），禁用 ICF
target_link_options(quickjs_c_bridge PRIVATE
    -Wl,--gc-sections
    -Wl,--icf=none
    -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/quickjs_bridge.map
    -Wl,-s
    -flto
)

# 预处理宏定义（与 Android 保持一致）
# __OHOS__：鸿蒙平台标识（C 代码当前未使用，保留以备后用）
# CONFIG_NO_ATOMICS：裁剪 Atomics/SharedArrayBuffer（单线程 JS 引擎不需要）
target_compile_definitions(quickjs_c_bridge PRIVATE
    _GNU_SOURCE
    __OHOS__
    CONFIG_VERSION="2026.06.04"
    CONFIG_NO_ATOMICS
)

# 头文件搜索路径
# - quickjs/: 用于 image_native.c 的 #include "webp/decode.h" 等
# - libwebp-1.5.0/src: 同上
# - libwebp-1.5.0: libwebp 内部源码用 #include "src/dec/xxx.h" 形式，从根目录算起
target_include_directories(quickjs_c_bridge PUBLIC
    ${PROJECT_ROOT_DIR}/quickjs
    ${PROJECT_ROOT_DIR}/quickjs/libwebp-1.5.0/src
    ${PROJECT_ROOT_DIR}/quickjs/libwebp-1.5.0
)

# 链接库
# 鸿蒙 OHOS NDK：
#   - hilog_ndk.z：鸿蒙日志（对应 Android 的 log 库）
#   - m：数学库（QuickJS 需要）
target_link_libraries(quickjs_c_bridge
    hilog_ndk.z
    m
)
