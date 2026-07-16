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

  # [libwebp] 计算 pod 根目录的绝对路径，用于 OTHER_CFLAGS 中的 -I 参数
  # 完全不依赖 $(PODS_ROOT) 等 Xcode 变量，避免 use_frameworks! + development pod
  # 模式下路径解析不一致导致的头文件找不到问题
  pod_root = File.expand_path(File.dirname(__FILE__))
  libwebp_root = File.join(pod_root, 'libwebp-1.5.0')
  libwebp_src = File.join(libwebp_root, 'src')
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
  #
  # [libwebp] 添加 WebP 解码器源文件（仅解码器，对齐 Android CMakeLists.txt 的 GLOB）
  # - dec/: 解码器核心
  # - dsp/: DSP 例程（含解码路径使用的反变换/滤波等）
  # - utils/: 工具函数（位读取、颜色空间转换等）
  # - webp/: 公共头文件（decode.h/format_constants.h/types.h 等）
  s.source_files     = '*.{c,h}', 'crypto/*.{c,h}', '../native_core/*.{c,h}',
                       'libwebp-1.5.0/src/dec/*.{c,h}',
                       'libwebp-1.5.0/src/dsp/*.{c,h}',
                       'libwebp-1.5.0/src/utils/*.{c,h}',
                       'libwebp-1.5.0/src/webp/*.{c,h}'
  # 对齐 Android CMakeLists.txt：不编译 quickjs-libc.c
  # Android 注释：不需要标准库辅助函数，且部分 POSIX 调用不兼容
  # iOS 同为 POSIX，为避免潜在不兼容（如 fork/exec），对齐 Android 排除
  s.exclude_files    = 'quickjs-libc.c'
  s.public_header_files = 'quickjs.h', 'quickjs-libc.h', 'cutils.h', 'dtoa.h', 'libregexp.h', 'libunicode.h', 'list.h', 'quickjs_bridge.h'
  s.libraries        = 'm', 'pthread'
  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => 'CONFIG_VERSION=\"2026.06.04\" CONFIG_NO_ATOMICS=1',
    # [libwebp] 直接通过 OTHER_CFLAGS 传 -I 设置头文件搜索路径
    # 用 Ruby 计算出的绝对路径，完全不依赖 $(PODS_ROOT) 等 Xcode 变量，
    # 避免 use_frameworks! + development pod 模式下路径解析不一致。
    # 同时保留 $(inherited) 继承 CocoaPods 默认编译选项。
    'OTHER_CFLAGS' => '$(inherited) -D_GNU_SOURCE -Wno-implicit-function-declaration -Oz -fomit-frame-pointer -fvisibility=default' +
                      " -I\"#{pod_root}\"" +
                      " -I\"#{libwebp_root}\"" +
                      " -I\"#{libwebp_src}\""
  }
  # 动态框架方案下，Dart FFI 用 DynamicLibrary.open('QuickJS.framework/QuickJS') 查找符号
  # 不再依赖 app target 的 -all_load 强制链接静态库
  # 47 个 quickjs_bridge_* 符号在 quickjs_bridge.c 中定义，-fvisibility=default 确保导出
  s.swift_version    = '5.0'
end
