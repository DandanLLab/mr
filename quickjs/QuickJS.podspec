Pod::Spec.new do |s|
  s.name             = 'QuickJS'
  s.version          = '2026.06.04'
  s.summary          = 'QuickJS JavaScript Engine'
  s.description      = 'QuickJS is a small and embeddable JavaScript engine compiled from C source.'
  s.homepage         = 'https://bellard.org/quickjs/'
  s.license          = 'MIT'
  s.author           = 'Fabrice Bellard'
  s.source           = { :path => '.' }
  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '10.14'
  # [动态运行时库方案] 改为动态框架（.framework 含可执行文件）
  # 之前 static_framework=true 编译为静态库，符号靠 -all_load 卷入主二进制，
  # Dart FFI 用 DynamicLibrary.process() 查找。但静态链接存在以下问题：
  #   1. duplicate symbol _main（lexbor 子目录 100+ 个 main 函数污染）
  #   2. -all_load 强制链接所有 .o，主二进制体积膨胀
  #   3. 符号查找不稳定（依赖 -all_load + DEAD_CODE_STRIPPING=NO 双重保障）
  # 动态框架方案：
  #   - QuickJS 编译为 QuickJS.framework/QuickJS 可执行文件
  #   - Dart FFI 用 DynamicLibrary.open('QuickJS.framework/QuickJS') 明确查找
  #   - 符号隔离在动态库内，不影响主二进制
  #   - 不依赖 -all_load，链接错误更易诊断
  s.static_framework = false
  # [修复 iOS 链接失败] source_files 显式指定顶层 + crypto/，对齐 Android CMakeLists.txt
  # 之前用 '**/*.{c,h}' 通配符，会把 lexbor/ 子目录 100+ 个含 main 函数的 .c 文件卷入编译
  # 导致 iOS 链接时 duplicate symbol _main 失败（"连接符掉了"）
  # lexbor 是历史遗留死代码，html_native.c 自实现 HTML 解析，不依赖 lexbor
  s.source_files     = '*.{c,h}', 'crypto/*.{c,h}'
  # 对齐 Android CMakeLists.txt：不编译 quickjs-libc.c
  # Android 注释：不需要标准库辅助函数，且部分 POSIX 调用不兼容
  # iOS 同为 POSIX，为避免潜在不兼容（如 fork/exec），对齐 Android 排除
  s.exclude_files    = 'quickjs-libc.c'
  s.public_header_files = 'quickjs.h', 'quickjs-libc.h', 'cutils.h', 'dtoa.h', 'libregexp.h', 'libunicode.h', 'list.h', 'quickjs_bridge.h'
  s.libraries        = 'm', 'pthread'
  s.pod_target_xcconfig = {
    # Xcode 的 GCC_PREPROCESSOR_DEFINITIONS 中字符串宏必须用 \" 转义引号
    # 否则引号被吃掉，CONFIG_VERSION 变成 2026.06.04（浮点数）而非 "2026.06.04"（字符串）
    # 导致 quickjs.c 中 "..." CONFIG_VERSION "..." 字符串拼接编译失败
    'GCC_PREPROCESSOR_DEFINITIONS' => 'CONFIG_VERSION=\"2026.06.04\" CONFIG_NO_ATOMICS=1',
    # 体积优化：编译选项 —— 体积优先
    # -Oz：极致体积优先（比 -O3 体积小 20-30%，速度损失约 10-15%，移动端首选）
    #   注：QuickJS 主要计算开销已沉降至 C 原生函数（Phase 1-3），解释器速度损失用户感知不强
    # -fomit-frame-pointer：释放 fp 寄存器
    #
    # [动态框架方案] 不再需要移除 -flto
    # 之前静态框架时，-flto 会裁剪只被 Dart FFI 引用的符号（LTO 看不到 FFI 引用）
    # 现在动态框架下，符号导出由动态库自身控制，-fvisibility=default 确保所有
    # quickjs_bridge_* 符号在动态库导出表中可见，LTO 不会裁剪导出符号
    # 但为保守起见，仍不启用 -flto，避免 LTO 对动态库符号导出的潜在影响
    'OTHER_CFLAGS' => '-D_GNU_SOURCE -Wno-implicit-function-declaration -Oz -fomit-frame-pointer -fvisibility=default'
  }
  # 动态框架方案下，Dart FFI 用 DynamicLibrary.open('QuickJS.framework/QuickJS') 查找符号
  # 不再依赖 app target 的 -all_load 强制链接静态库
  # 47 个 quickjs_bridge_* 符号在 quickjs_bridge.c 中定义，-fvisibility=default 确保导出
  s.swift_version    = '5.0'
end
