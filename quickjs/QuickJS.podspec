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
  # -all_load 在 project.pbxproj 的 OTHER_LDFLAGS 中设置（不在这里设，避免 xcconfig 冲突）
  # Dart FFI 运行时按字符串查找符号，链接器静态分析看不到引用
  # -all_load 强制链接所有静态库的所有 .o 文件
  s.swift_version    = '5.0'
end
