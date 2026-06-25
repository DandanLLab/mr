Pod::Spec.new do |s|
  s.name             = 'QuickJS'
  s.version          = '2026.06.04'
  s.summary          = 'QuickJS JavaScript Engine'
  s.description      = 'QuickJS is a small and embeddable JavaScript engine compiled from C source.'
  s.homepage         = 'https://bellard.org/quickjs/'
  s.license          = 'MIT'
  s.author           = 'Fabrice Bellard'
  s.source           = { :path => '.' }
  s.ios.deployment_target = '17.0'
  s.static_framework = true
  s.source_files     = '*.{c,h}'
  s.public_header_files = 'quickjs.h', 'quickjs-libc.h', 'cutils.h', 'dtoa.h', 'libregexp.h', 'libunicode.h', 'list.h', 'quickjs_bridge.h'
  s.libraries        = 'm', 'pthread'
  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => 'CONFIG_VERSION="2026.06.04"',
    'OTHER_CFLAGS' => '-D_GNU_SOURCE -DCONFIG_VERSION="2026.06.04" -Wno-implicit-function-declaration'
  }
  s.swift_version    = '5.0'
end
