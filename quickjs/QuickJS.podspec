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
  s.static_framework = true
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
    # [修复 iOS 引擎初始化失败] 移除 -flto 和 -ffunction-sections -fdata-sections
    # 原因：Dart FFI 通过 DynamicLibrary.process().lookup('symbol_name') 在运行时
    #       按字符串查找 C 函数符号，这种引用对 LTO 和链接器静态分析完全不可见。
    #       -flto 会在链接阶段进行全局优化，将只被 Dart FFI 引用的导出函数
    #       （如 get_cpu_count、quickjs_bridge_create 等）视为"未引用代码"并移除，
    #       导致运行时 lookup 抛出 ArgumentError → 引擎初始化失败。
    #       -all_load 只强制加载 .o 文件，无法阻止 LTO 在链接阶段裁剪符号。
    #       DEAD_CODE_STRIPPING=NO 只控制链接器 dead strip pass，不控制 LTO 死代码消除。
    # 修复：移除 -flto（阻止 LTO 裁剪 FFI 符号）
    #       移除 -ffunction-sections -fdata-sections（配合 dead strip 使用，现已不需要）
    #       保留 -Oz -fomit-frame-pointer（纯体积优化，不影响符号导出）
    # 影响范围：仅 iOS/macOS，不影响 Android（Android 使用 CMakeLists.txt）
    'OTHER_CFLAGS' => '-D_GNU_SOURCE -Wno-implicit-function-declaration -Oz -fomit-frame-pointer'
  }
  # -all_load 在 project.pbxproj 的 OTHER_LDFLAGS 中设置（不在这里设，避免 xcconfig 冲突）
  # Dart FFI 运行时按字符串查找符号，链接器静态分析看不到引用
  # -all_load 强制链接所有静态库的所有 .o 文件
  s.swift_version    = '5.0'
end
