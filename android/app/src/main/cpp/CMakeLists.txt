cmake_minimum_required(VERSION 3.18)
project(quickjs_c_bridge C)

# QuickJS C 源码目录（项目根目录 quickjs/，iOS 和 Android 共享）
# 路径: android/app/src/main/cpp/ → mr/quickjs/（5 个 ..）
set(QUICKJS_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../quickjs)

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
    -D_GNU_SOURCE
    -DCONFIG_VERSION="2026.06.04"
    -Wno-implicit-function-declaration
    -Wno-unused-parameter
    -Wno-sign-compare
    -Wno-unused-function
    -Wno-unused-variable
    -O2
)

# 头文件搜索路径
target_include_directories(quickjs_c_bridge PUBLIC ${QUICKJS_SRC_DIR})

# 链接库
target_link_libraries(quickjs_c_bridge
    log    # Android log（日志输出）
    m      # 数学库（QuickJS 需要）
)
