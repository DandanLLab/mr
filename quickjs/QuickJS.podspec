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
  s.source_files     = '*.{c,h}'
  s.public_header_files = 'quickjs.h', 'quickjs-libc.h', 'cutils.h', 'dtoa.h', 'libregexp.h', 'libunicode.h', 'list.h', 'quickjs_bridge.h'
  s.libraries        = 'm', 'pthread'
  s.pod_target_xcconfig = {
    # Xcode 的 GCC_PREPROCESSOR_DEFINITIONS 中字符串宏必须用 \" 转义引号
    # 否则引号被吃掉，CONFIG_VERSION 变成 2026.06.04（浮点数）而非 "2026.06.04"（字符串）
    # 导致 quickjs.c 中 "..." CONFIG_VERSION "..." 字符串拼接编译失败
    'GCC_PREPROCESSOR_DEFINITIONS' => 'CONFIG_VERSION=\"2026.06.04\"',
    'OTHER_CFLAGS' => '-D_GNU_SOURCE -Wno-implicit-function-declaration'
  }
  # s.xcconfig 会应用到消费者（主工程）的 build settings
  # -all_load 强制链接所有静态库的所有 .o 文件
  # Dart FFI 运行时按字符串查找符号（DynamicLibrary.process().lookup），
  # 链接器静态分析看不到引用，默认不链接未引用的 .o 文件
  # 没有 -all_load，quickjs_bridge_create 等符号会被链接器丢弃
  # 注：-force_load 需指定路径，但 CocoaPods static_framework 的输出路径不确定，故用 -all_load
  s.xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -all_load'
  }
  s.swift_version    = '5.0'
end
