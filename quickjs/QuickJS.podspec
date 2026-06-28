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
  s.source_files     = '**/*.{c,h}'
  s.public_header_files = 'quickjs.h', 'quickjs-libc.h', 'cutils.h', 'dtoa.h', 'libregexp.h', 'libunicode.h', 'list.h', 'quickjs_bridge.h'
  s.libraries        = 'm', 'pthread'
  s.pod_target_xcconfig = {
    # Xcode 的 GCC_PREPROCESSOR_DEFINITIONS 中字符串宏必须用 \" 转义引号
    # 否则引号被吃掉，CONFIG_VERSION 变成 2026.06.04（浮点数）而非 "2026.06.04"（字符串）
    # 导致 quickjs.c 中 "..." CONFIG_VERSION "..." 字符串拼接编译失败
    'GCC_PREPROCESSOR_DEFINITIONS' => 'CONFIG_VERSION=\"2026.06.04\" CONFIG_NO_ATOMICS=1',
    # 体积优化：编译选项 —— 体积优先 + 裁剪未引用代码
    # -Oz：极致体积优先（比 -O3 体积小 20-30%，速度损失约 10-15%，移动端首选）
    #   注：QuickJS 主要计算开销已沉降至 C 原生函数（Phase 1-3），解释器速度损失用户感知不强
    # -flto：链接期跨文件内联 + 死代码消除（同时优化速度和体积）
    # -fomit-frame-pointer：释放 fp 寄存器
    # -ffunction-sections -fdata-sections：配合 app target 的 -dead_strip 裁剪未引用代码
    # （注：-dead_strip 与 -all_load 在 project.pbxproj 中配置，不在此处重复设置，
    #   避免 pod_target_xcconfig 与 app target xcconfig 冲突）
    # iOS QuickJS 为 static_framework，符号导出由 app target -dead_strip 控制，无需 version-script
    'OTHER_CFLAGS' => '-D_GNU_SOURCE -Wno-implicit-function-declaration -Oz -flto -fomit-frame-pointer -ffunction-sections -fdata-sections'
  }
  # -all_load 在 project.pbxproj 的 OTHER_LDFLAGS 中设置（不在这里设，避免 xcconfig 冲突）
  # Dart FFI 运行时按字符串查找符号，链接器静态分析看不到引用
  # -all_load 强制链接所有静态库的所有 .o 文件
  s.swift_version    = '5.0'
end
