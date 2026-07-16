cmake_minimum_required(VERSION 3.18)
project(quickjs_c_bridge C)

# QuickJS C 源码目录（项目根目录 quickjs/，iOS 和 Android 共享）
# PROJECT_ROOT_DIR 由 build.gradle.kts 传入，指向项目根目录
# 与 iOS Podfile 的 :path => '../quickjs' 引用同一份源码
file(TO_CMAKE_PATH "${PROJECT_ROOT_DIR}" PROJECT_ROOT_DIR_CMAKE)
set(QUICKJS_SRC_DIR ${PROJECT_ROOT_DIR_CMAKE}/quickjs)

# QuickJS 源码文件
# 不编译 quickjs-libc.c（Android 上不需要标准库辅助函数，且部分 POSIX 调用不兼容）
# native_core 模块（桥接初始化与扩展入口）
set(NATIVE_CORE_DIR ${PROJECT_ROOT_DIR_CMAKE}/native_core)

set(QUICKJS_SOURCES
    ${QUICKJS_SRC_DIR}/quickjs.c
    ${QUICKJS_SRC_DIR}/cutils.c
    ${QUICKJS_SRC_DIR}/dtoa.c
    ${QUICKJS_SRC_DIR}/libregexp.c
    ${QUICKJS_SRC_DIR}/libunicode.c
    ${QUICKJS_SRC_DIR}/quickjs_bridge.c
    ${QUICKJS_SRC_DIR}/lzstring.c
    ${QUICKJS_SRC_DIR}/batch_decompress.c
    ${QUICKJS_SRC_DIR}/html_native.c
    ${QUICKJS_SRC_DIR}/charset_conv.c
    ${QUICKJS_SRC_DIR}/crypto/md5.c
    ${QUICKJS_SRC_DIR}/crypto/sha1.c
    ${QUICKJS_SRC_DIR}/crypto/sha256.c
    ${QUICKJS_SRC_DIR}/crypto/hmac_sha256.c
    ${QUICKJS_SRC_DIR}/crypto/aes.c
    ${QUICKJS_SRC_DIR}/handle_table.c
    ${QUICKJS_SRC_DIR}/memory_tracker.c
    ${QUICKJS_SRC_DIR}/image_native.c
    ${NATIVE_CORE_DIR}/bridge_init.c
)

# libwebp: WebP 图片解码（仅解码器，不含编码器）
set(LIBWEBP_SRC_DIR ${QUICKJS_SRC_DIR}/libwebp-1.5.0/src)
file(GLOB LIBWEBP_DEC_SOURCES ${LIBWEBP_SRC_DIR}/dec/*.c)
file(GLOB LIBWEBP_DSP_SOURCES ${LIBWEBP_SRC_DIR}/dsp/*.c)
file(GLOB LIBWEBP_UTILS_SOURCES ${LIBWEBP_SRC_DIR}/utils/*.c)
set(LIBWEBP_SOURCES ${LIBWEBP_DEC_SOURCES} ${LIBWEBP_DSP_SOURCES} ${LIBWEBP_UTILS_SOURCES})

# 编译为共享库 libquickjs_c_bridge.so
# Dart FFI 通过 DynamicLibrary.open('libquickjs_c_bridge.so') 加载
add_library(quickjs_c_bridge SHARED ${QUICKJS_SOURCES} ${LIBWEBP_SOURCES})

# 体积优化：编译选项 —— 体积优先 + 裁剪未引用代码
# -Oz：极致体积优先（比 -O3 体积小 20-30%，速度损失约 10-15%，移动端首选）
#   注：QuickJS 主要计算开销已沉降至 C 原生函数（Phase 1-3），解释器速度损失用户感知不强
# -flto：链接期跨文件内联 + 死代码消除
#   quickjs.c（5万+行）在 CI runner 上易 OOM，不给它加 -flto
# -ffunction-sections -fdata-sections：按函数/数据分段，配合 --gc-sections 裁剪未引用代码
# -fomit-frame-pointer：释放 fp 寄存器（arm64 默认行为，显式声明）
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

# quickjs.c 巨无霸（5万+行、2MB、1507 个 static 函数），完整 LTO IR 在 CI 7GB runner 上 OOM
# 内存优化策略（全部叠加）：
#   -fno-lto              ← 不产生 LTO GIMPLE IR，省 4-6GB
#   -fno-inline-functions ← 不内联，函数体不复制到调用处，省 20-30% IR
#   -fno-unroll-loops     ← 不展开循环，避免 IR 膨胀 10-20%
#   -fno-tree-vectorize   ← 不自动矢量化，省向量化分析内存
#   -mllvm -inline-threshold=0
#                         ← LLVM 内联阈值降为 0，进一步阻止内联
# 注：quickjs.c 主要是 JS 解释器 + 内置对象，这些优化不影响关键路径性能
#     C 原生性能函数（AES/Base64/LZString）全在其他 17 个文件中
set_source_files_properties(${QUICKJS_SRC_DIR}/quickjs.c PROPERTIES
    COMPILE_FLAGS "-Oz -fno-lto -fno-inline-functions -fno-unroll-loops -fno-tree-vectorize -mllvm -inline-threshold=0"
)
set_source_files_properties(
    ${QUICKJS_SRC_DIR}/cutils.c
    ${QUICKJS_SRC_DIR}/dtoa.c
    ${QUICKJS_SRC_DIR}/libregexp.c
    ${QUICKJS_SRC_DIR}/libunicode.c
    ${QUICKJS_SRC_DIR}/quickjs_bridge.c
    ${QUICKJS_SRC_DIR}/lzstring.c
    ${QUICKJS_SRC_DIR}/batch_decompress.c
    ${QUICKJS_SRC_DIR}/html_native.c
    ${QUICKJS_SRC_DIR}/charset_conv.c
    ${QUICKJS_SRC_DIR}/crypto/md5.c
    ${QUICKJS_SRC_DIR}/crypto/sha1.c
    ${QUICKJS_SRC_DIR}/crypto/sha256.c
    ${QUICKJS_SRC_DIR}/crypto/hmac_sha256.c
    ${QUICKJS_SRC_DIR}/crypto/aes.c
    ${QUICKJS_SRC_DIR}/handle_table.c
    ${QUICKJS_SRC_DIR}/memory_tracker.c
    ${QUICKJS_SRC_DIR}/image_native.c
    ${NATIVE_CORE_DIR}/bridge_init.c
    PROPERTIES COMPILE_FLAGS "-flto"
)

# 链接期优化：LTO + ICF + gc-sections + version-script + strip
# -Wl,--icf=safe：链接时合并相同代码（Identical Code Folding）
#   不同编译单元的相同函数合并为一份，so 体积省 3-8%
# -Wl,--gc-sections：移除未引用的函数/数据段
# -Wl,--version-script：仅导出 quickjs_bridge_* 和批量解压函数，QuickJS 内部符号全部隐藏
#   避免 .dynsym 表膨胀（QuickJS 有数百个内部 JS_* 函数），so 体积可减 10-30KB
# -Wl,-s：strip 所有符号表和重定位信息（AGP Release 也会自动 strip，这里显式确保）
# -flto：链接期优化（与编译期 -flto 配合）
target_link_options(quickjs_c_bridge PRIVATE
    -Wl,--gc-sections
    -Wl,--icf=safe
    -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/quickjs_bridge.map
    -Wl,-s
    -flto
)

# 预处理宏定义
# CONFIG_VERSION 必须是字符串字面量，CMake 的 target_compile_definitions
# 会正确保留引号，使 quickjs.c 中 "..." CONFIG_VERSION "..." 拼接合法
# CONFIG_NO_ATOMICS：裁剪 Atomics/SharedArrayBuffer（单线程 JS 引擎不需要，省约 5-15KB）
target_compile_definitions(quickjs_c_bridge PRIVATE
    _GNU_SOURCE
    CONFIG_VERSION="2026.06.04"
    CONFIG_NO_ATOMICS
)

# 头文件搜索路径
# - QUICKJS_SRC_DIR: quickjs/ （用于 image_native.c 的 #include "webp/decode.h" 等）
# - LIBWEBP_SRC_DIR: quickjs/libwebp-1.5.0/src （同上）
# - LIBWEBP 根目录: quickjs/libwebp-1.5.0 （libwebp 内部源码用 #include "src/dec/xxx.h" 形式，从根目录算起）
target_include_directories(quickjs_c_bridge PUBLIC
    ${QUICKJS_SRC_DIR}
    ${LIBWEBP_SRC_DIR}
    ${QUICKJS_SRC_DIR}/libwebp-1.5.0
)

# 链接库
target_link_libraries(quickjs_c_bridge
    log    # Android log（日志输出）
    m      # 数学库（QuickJS 需要）
)

# 参考 quickjs-ng：Windows 平台栈大小必须设为 8MB
# MSVC 默认 1MB 与 QuickJS 的 1MB JS 栈相同会溢出崩溃
if(WIN32 AND CMAKE_C_COMPILER_ID STREQUAL "MSVC")
    target_link_options(quickjs_c_bridge PRIVATE /STACK:8388608)
endif()
