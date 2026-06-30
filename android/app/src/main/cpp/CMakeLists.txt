cmake_minimum_required(VERSION 3.18)
project(quickjs_c_bridge C)

# QuickJS C 源码目录（项目根目录 quickjs/，iOS 和 Android 共享）
# PROJECT_ROOT_DIR 由 build.gradle.kts 传入，指向项目根目录
# 与 iOS Podfile 的 :path => '../quickjs' 引用同一份源码
set(QUICKJS_SRC_DIR ${PROJECT_ROOT_DIR}/quickjs)

# QuickJS 源码文件
# 不编译 quickjs-libc.c（Android 上不需要标准库辅助函数，且部分 POSIX 调用不兼容）
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
    ${QUICKJS_SRC_DIR}/http_client.c
    ${QUICKJS_SRC_DIR}/handle_table.c
    ${QUICKJS_SRC_DIR}/memory_tracker.c
)

# 编译为共享库 libquickjs_c_bridge.so
# Dart FFI 通过 DynamicLibrary.open('libquickjs_c_bridge.so') 加载
add_library(quickjs_c_bridge SHARED ${QUICKJS_SOURCES})

# 体积优化：编译选项 —— 体积优先 + 裁剪未引用代码
# -Oz：极致体积优先（比 -O3 体积小 20-30%，速度损失约 10-15%，移动端首选）
#   注：QuickJS 主要计算开销已沉降至 C 原生函数（Phase 1-3），解释器速度损失用户感知不强
# -flto：链接期跨文件内联 + 死代码消除（同时优化速度和体积）
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
    -flto
)

# quickjs.c 异常大（5万+行），带 LTO 编译在低内存 CI runner 上容易 OOM
# -fno-lto 覆盖 target 的 -flto，只影响 quickjs.c 一个文件
set_source_files_properties(${QUICKJS_SRC_DIR}/quickjs.c PROPERTIES COMPILE_FLAGS "-fno-lto")

# 链接期优化：LTO + gc-sections + version-script 精确控制导出符号 + strip
# -Wl,--gc-sections：移除未引用的函数/数据段
# -Wl,--version-script：仅导出 quickjs_bridge_* 和批量解压函数，QuickJS 内部符号全部隐藏
#   避免 .dynsym 表膨胀（QuickJS 有数百个内部 JS_* 函数），so 体积可减 10-30KB
# -Wl,-s：strip 所有符号表和重定位信息（AGP Release 也会自动 strip，这里显式确保）
# -flto：链接期优化（与编译期 -flto 配合）
target_link_options(quickjs_c_bridge PRIVATE
    -Wl,--gc-sections
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
target_include_directories(quickjs_c_bridge PUBLIC ${QUICKJS_SRC_DIR})

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
