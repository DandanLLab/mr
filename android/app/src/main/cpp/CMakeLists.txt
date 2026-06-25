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
)

# 编译为共享库 libquickjs_c_bridge.so
# Dart FFI 通过 DynamicLibrary.open('libquickjs_c_bridge.so') 加载
add_library(quickjs_c_bridge SHARED ${QUICKJS_SOURCES})

# 编译选项（与 iOS podspec 保持一致）
target_compile_options(quickjs_c_bridge PRIVATE
    -Wno-implicit-function-declaration
    -Wno-unused-parameter
    -Wno-sign-compare
    -Wno-unused-function
    -Wno-unused-variable
    -O2
)

# 预处理宏定义
# CONFIG_VERSION 必须是字符串字面量，CMake 的 target_compile_definitions
# 会正确保留引号，使 quickjs.c 中 "..." CONFIG_VERSION "..." 拼接合法
target_compile_definitions(quickjs_c_bridge PRIVATE
    _GNU_SOURCE
    CONFIG_VERSION="2026.06.04"
)

# 头文件搜索路径
target_include_directories(quickjs_c_bridge PUBLIC ${QUICKJS_SRC_DIR})

# 链接库
target_link_libraries(quickjs_c_bridge
    log    # Android log（日志输出）
    m      # 数学库（QuickJS 需要）
)
