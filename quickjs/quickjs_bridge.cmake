# QuickJS C 桥接库共享编译配置（Windows/Linux 桌面端）
# 被 windows/runner/CMakeLists.txt 和 linux/runner/CMakeLists.txt 引用
# 调用方需先设置 PROJECT_ROOT_DIR 指向项目根目录
#
# 编译产物：quickjs_c_bridge.dll (Windows) / libquickjs_c_bridge.so (Linux)
# Dart FFI 通过 DynamicLibrary.open() 加载

set(QUICKJS_SRC_DIR "${PROJECT_ROOT_DIR}/quickjs")

set(QUICKJS_SOURCES
    ${QUICKJS_SRC_DIR}/quickjs.c
    ${QUICKJS_SRC_DIR}/cutils.c
    ${QUICKJS_SRC_DIR}/dtoa.c
    ${QUICKJS_SRC_DIR}/libregexp.c
    ${QUICKJS_SRC_DIR}/libunicode.c
    ${QUICKJS_SRC_DIR}/quickjs_bridge.c
    ${QUICKJS_SRC_DIR}/lzstring.c
    ${QUICKJS_SRC_DIR}/batch_decompress.c
    ${QUICKJS_SRC_DIR}/crypto/md5.c
    ${QUICKJS_SRC_DIR}/crypto/sha1.c
    ${QUICKJS_SRC_DIR}/crypto/sha256.c
    ${QUICKJS_SRC_DIR}/crypto/hmac_sha256.c
    ${QUICKJS_SRC_DIR}/crypto/aes.c
)

add_library(quickjs_c_bridge SHARED ${QUICKJS_SOURCES})

target_include_directories(quickjs_c_bridge PUBLIC ${QUICKJS_SRC_DIR})

target_compile_definitions(quickjs_c_bridge PRIVATE
    _GNU_SOURCE
    CONFIG_VERSION="2026.06.04"
)

if(MSVC)
    # Windows MSVC 编译选项
    target_compile_options(quickjs_c_bridge PRIVATE /O1 /W1)
    target_compile_definitions(quickjs_c_bridge PRIVATE NOMINMAX)
else()
    # Linux GCC/Clang 编译选项
    target_compile_options(quickjs_c_bridge PRIVATE
        -Os
        -Wno-implicit-function-declaration
        -Wno-unused-parameter
        -Wno-sign-compare
        -Wno-unused-function
        -Wno-unused-variable
    )
    target_link_libraries(quickjs_c_bridge PRIVATE m)
endif()
