import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'quickjs_runtime_stub.dart'
    if (dart.library.io) 'quickjs_runtime.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart' as archive;
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import 'package:synchronized/synchronized.dart';
import '../app_logger.dart';
import '../crash_log_service.dart';
import '../source_engine/analyze_url.dart' as legado_url;
import 'platform_channel.dart';
import 'platform_bridge.dart';
import 'shared_js_scope.dart';

// ===== 分流引擎架构 =====

/// JS 引擎类型枚举
enum JsEngineType {
  /// QuickJS 引擎（flutter_js），原生支持 ES6+
  quickjs,
}

/// 引擎分流解析结果
class _EngineResolveResult {
  final JsEngineType engine;
  final String code;

  const _EngineResolveResult(this.engine, this.code);
}

/// JS 执行追踪节点（构建完整执行树）
class JsTraceNode {
  final String id;
  final String engine;        // QuickJS
  final String caller;        // 调用来源（AnalyzeRule / processJsRule / executeSync 等）
  final String? ruleStep;     // 规则步骤描述（如 "步骤1/2: @href"）
  final String codePreview;   // JS 代码预览
  final String? inputPreview; // 输入内容预览
  String? outputPreview;      // 输出内容预览
  String? outputType;         // 输出类型
  String? error;              // 错误信息
  final DateTime startTime;
  DateTime? endTime;
  final List<JsTraceNode> children = [];
  final JsTraceNode? parent;

  JsTraceNode({
    required this.id,
    required this.engine,
    required this.caller,
    this.ruleStep,
    required this.codePreview,
    this.inputPreview,
    this.parent,
  }) : startTime = DateTime.now();

  Duration? get duration => endTime?.difference(startTime);

  /// 生成树形字符串
  String toTreeString({int indent = 0}) {
    final prefix = '  ' * indent;
    final buf = StringBuffer();
    final dur = duration != null ? '${duration!.inMilliseconds}ms' : '?';
    final errMark = error != null ? ' [ERROR]' : '';
    buf.writeln('$prefix├─ [$engine] $caller${ruleStep != null ? " | $ruleStep" : ""} ($dur)$errMark');

    final codeLines = codePreview.split('\n');
    for (final line in codeLines.take(3)) {
      buf.writeln('$prefix│  code: ${line.length > 80 ? '${line.substring(0, 80)}...' : line}');
    }
    if (codeLines.length > 3) {
      buf.writeln('$prefix│  code: ... (${codeLines.length - 3} more lines)');
    }

    if (inputPreview != null && inputPreview!.isNotEmpty) {
      final inp = inputPreview!.replaceAll('\n', '\\n');
      buf.writeln('$prefix│  input: $inp');
    }
    if (outputPreview != null && outputPreview!.isNotEmpty) {
      final out = outputPreview!.replaceAll('\n', '\\n');
      buf.writeln('$prefix│  output($outputType): $out');
    }
    if (error != null) {
      buf.writeln('$prefix│  error: $error');
    }
    for (final child in children) {
      buf.write(child.toTreeString(indent: indent + 1));
    }
    return buf.toString();
  }
}

/// JS 执行追踪器（全局单例，构建执行树）
class JsTracer {
  JsTracer._();
  static final JsTracer instance = JsTracer._();

  /// 当前追踪树根节点
  JsTraceNode? _currentRoot;

  /// 当前活跃节点栈（支持嵌套调用追踪）
  final List<JsTraceNode> _stack = [];

  /// 获取当前栈深度（公开访问）
  int get stackDepth => _stack.length;

  /// 当前栈顶节点是否为空（公开访问）
  bool get isStackEmpty => _stack.isEmpty;

  /// 获取当前栈顶节点
  JsTraceNode? get currentStackTop => _stack.isNotEmpty ? _stack.last : null;

  /// 是否启用追踪（Release 模式禁用，避免构建大执行树导致 OOM）
  bool enabled = kDebugMode;

  /// 追踪 ID 计数器
  int _idCounter = 0;

  /// 开始一个新的追踪根
  JsTraceNode beginRoot(String caller, String engine, String codePreview, {String? inputPreview, String? ruleStep}) {
    final node = JsTraceNode(
      id: 'trace_${_idCounter++}',
      engine: engine,
      caller: caller,
      codePreview: codePreview,
      inputPreview: inputPreview,
      ruleStep: ruleStep,
    );
    _currentRoot = node;
    _stack.clear();
    _stack.add(node);
    return node;
  }

  /// 在当前节点下添加子节点
  JsTraceNode addChild(String caller, String engine, String codePreview, {String? inputPreview, String? ruleStep}) {
    final parent = _stack.isNotEmpty ? _stack.last : null;
    final node = JsTraceNode(
      id: 'trace_${_idCounter++}',
      engine: engine,
      caller: caller,
      codePreview: codePreview,
      inputPreview: inputPreview,
      ruleStep: ruleStep,
      parent: parent,
    );
    parent?.children.add(node);
    return node;
  }

  /// 进入一个节点（压栈）
  void push(JsTraceNode node) {
    _stack.add(node);
  }

  /// 退出当前节点（弹栈）
  void pop({String? outputPreview, String? outputType, String? error}) {
    if (_stack.isEmpty) return;
    final node = _stack.removeLast();
    node.endTime = DateTime.now();
    if (outputPreview != null) node.outputPreview = outputPreview;
    if (outputType != null) node.outputType = outputType;
    if (error != null) node.error = error;
  }

  /// 获取完整追踪树字符串
  String getTreeString() {
    if (_currentRoot == null) return '(no trace)';
    return _currentRoot!.toTreeString();
  }

  /// 获取当前根节点
  JsTraceNode? get currentRoot => _currentRoot;

  /// 清空追踪
  void clear() {
    _currentRoot = null;
    _stack.clear();
    _idCounter = 0;
  }
}

/// JS/TS 运行时引擎
///
/// 架构设计：
/// - QuickJS 引擎：处理 ES6+ 语法，作为默认引擎
/// - 分流策略：显式声明 > 关键词自动识别 > 默认 QuickJS
/// - 桥接层：通过 Dart 侧 NativeChannel 桥接 Java 互操作
class JsEngine {
  static JsEngine? _instance;
  static JsEngine get instance => _instance ??= JsEngine._();

  JsEngine._();

  /// JS 执行互斥锁：防止并发调用时全局变量（result/baseUrl 等）被覆盖
  final Lock _evalLock = Lock();

  // 热路径正则常量
  // 检测代码以 return 开头（顶层 return），允许多行代码内部的 function return 不误判
  static final _returnStartRegex = RegExp(r'^return\b');
  // 检测代码是否包含 return 关键字（可能在函数内部）
  static final _returnKeywordRegex = RegExp(r'\breturn\b');
  static final _jsTagRegex = RegExp(r'<js>([\s\S]*?)</js>', caseSensitive: false);
  static final _jsPrefixRegex = RegExp(r'^@js:', caseSensitive: false);
  static final _templateVarRegex = RegExp(r'\{\{([\s\S]*?)\}\}');
  // <js></js> 标签剥离正则
  static final _engineTagRegex = RegExp(r'^<js>|</js>$', caseSensitive: false);

  // _preCacheBridgeCalls 正则常量
  static final _literalPattern = RegExp(
    r"""(?:java\.(?:ajax|get|post)|fetch)\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );
  static final _varPattern = RegExp(
    r"""(?:java\.(?:ajax|get|post)|fetch)\s*\(\s*([^"')\s][^)]*?)\s*\)""",
    multiLine: true,
  );
  static final _templatePattern = RegExp(r'`([^`]*\$\{[^}]+\}[^`]*)`');
  static final _templateVarPattern = RegExp(r'\$\{([^}]+)\}');
  static final _md5Pattern = RegExp(
    r"""java\.md5Encode\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );
  static final _sha1Pattern = RegExp(
    r"""java\.sha1Encode\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );
  static final _sha256Pattern = RegExp(
    r"""java\.sha256Encode\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );
  static final _hmacPattern = RegExp(
    r"""java\.hmacSHA256\s*\(\s*["']([^"']+)["']\s*,\s*["']([^"']+)["']""",
    multiLine: true,
  );
  static final _postPattern = RegExp(
    r"""java\.post\s*\(\s*["']([^"']+)["']\s*,\s*["']([^"']*)["']""",
    multiLine: true,
  );
  static final _headPattern = RegExp(
    r"""java\.head\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );
  static final _cookiePattern = RegExp(
    r"""java\.getCookie\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );
  // [legado URL 选项兼容] 匹配 java.ajax/get/post/connect("url,{...}") 或 fetch("url,{...}")
  // 支持转义引号，正确捕获完整字符串参数（含嵌套 {}）
  // 策略：匹配引号开始 → 贪婪匹配到 ,{ → 贪婪匹配到最后一个 } → 对应引号结束
  static final _urlOptionCallPattern = RegExp(
    r"""(?:java\.(?:ajax|get|post|connect)|fetch)\s*\(\s*(['"])((?:\\.|(?!\1).)*,\{(?:\\.|(?!\1).)*\})\1""",
    multiLine: true,
  );
  static final _htmlParsePattern = RegExp(
    r'''(?:_JsoupLite\.(selectFirst|selectAll)|java\.(?:jsoup\.(select|selectFirst|getAttr)|getString|getElement|getElements))\s*\(\s*([^,)]+)(?:\s*,\s*([^,)]+))?(?:\s*,\s*([^)]+))?\s*\)''',
    multiLine: true,
  );
  static final _cacheVarPattern = RegExp(r'\{\{(\w+)\}\}');

  /// Dart 端缓存键跟踪（避免 JS 端 _isCached 的 evaluate 调用）
  final Set<String> _cachedKeys = {};

  bool _initialized = false;
  JavascriptRuntime? _jsRuntime;
  /// 日志 flush 防递归标志：_flushConsoleLogs 内部调用 evaluate 时设为 true
  bool _isFlushingLogs = false;
  /// 最近一次 _executeQuickJSSync 的错误信息（供 executeSync 读取后写入 traceNode）
  String? _lastEvalError;

  /// 公开 getter：供 decodeImage 等调用方读取最近一次 JS 执行错误
  String? get lastEvalError => _lastEvalError;
  /// 并发防护：同步调用中标志，processJsRule 执行时自旋等待
  bool _evalBusy = false;
  final Map<String, String> _installedPackages = {};
  final Map<String, String> _moduleCache = {};

  // ===== 脚本编译缓存（借鉴 legado 的 scriptCache）=====
  /// 缓存编译后的脚本结果，避免重复 evaluate 相同代码
  /// key: JS代码的MD5, value: evaluate结果
  final Map<String, dynamic> _scriptCache = {};
  static const int _maxScriptCacheSize = 16;

  // ===== 共享作用域变量（借鉴 legado 的 SharedJsScope）=====
  /// 书源级共享变量，跨规则共享
  final Map<String, Map<String, String>> _sharedScopeVars = {};

  /// 书源级 jsLib 缓存（借鉴 legado 的 SharedJsScope）
  /// key: bookSourceUrl, value: jsLib 代码
  final Map<String, String> _jsLibCache = {};

  /// 当前已加载到 globalThis 的 jsLib 所属的书源 URL
  /// 借鉴 legado 的 SharedJsScope：同一书源的 jsLib 只加载一次，切换书源时清除旧的
  String? _currentJsLibSourceUrl;

  /// 当前已加载的 jsLib 中定义的全局函数名列表
  /// 用于切换书源时清除旧函数，避免全局污染
  final List<String> _currentJsLibFunctions = [];

  // ===== 引擎桥接层：跨引擎共享缓存 =====

  /// 跨引擎共享缓存
  final Map<String, String> _bridgeCache = {};

  /// 缓存 jsonEncode(source Map) 结果
  /// 同一书源的 source Map 在整个调试过程中不变，
  /// 但每次 _executeQuickJSRule 都会重新 jsonEncode（CPU 密集型）。
  /// 1000 章解析时 6000 次 jsonEncode → 缓存后仅 1 次。
  String? _cachedSourceJson;
  String? _cachedSourceKey;

  /// 获取缓存的 source JSON 字符串（同一书源复用）
  String getCachedSourceJson(Map<String, dynamic>? sourceMap) {
    if (sourceMap == null || sourceMap.isEmpty) return '{}';
    // 用 bookSourceUrl 作为缓存键（同一书源 source Map 不变）
    final key = sourceMap['bookSourceUrl'] as String? ?? '';
    if (key == _cachedSourceKey && _cachedSourceJson != null) {
      return _cachedSourceJson!;
    }
    final encoded = jsonEncode(sourceMap);
    _cachedSourceJson = encoded;
    _cachedSourceKey = key;
    return encoded;
  }

  /// 获取桥接缓存
  String bridgeGet(String key) => _bridgeCache[key] ?? '';

  /// 写入桥接缓存
  void bridgePut(String key, String value) {
    _bridgeCache[key] = value;
  }

  /// 删除桥接缓存
  void bridgeDelete(String key) {
    _bridgeCache.remove(key);
  }

  // ===== 初始化 =====

  /// 初始化 JS 引擎
  Future<bool> init() async {
    // [覆盖安装闪退修复] 仅 Android：在 FFI 调用前通过 MethodChannel 验证 .so 完整性
    // Android 动态链接 libquickjs_c_bridge.so，覆盖安装时 .so 提取存在竞争，需检查。
    // [动态运行时库方案] iOS 改为动态框架（QuickJS.framework），由系统在 App 启动时
    // 自动 dlopen 嵌入的 .framework，符号在进程内可见。无需 MethodChannel 检查，
    // 否则 MissingPluginException 会导致引擎启动失败。
    if (Platform.isAndroid) {
      try {
        _nativeLibChecked = await NativeChannel.instance.checkNativeLib('quickjs_c_bridge');
      } catch (_) {
        _nativeLibChecked = false;
      }
      // native lib 未就绪 → 跳过所有 FFI 调用，避免 SIGSEGV
      if (!_nativeLibChecked) return false;
    } else {
      // iOS / 其他平台：动态框架由系统自动加载，无需检查
      _nativeLibChecked = true;
    }

    // [覆盖安装闪退修复] 快路径：_initialized 为真且 runtime 存在直接信任，零 FFI 调用
    // 不做 evaluate() 健康检查，避免 SIGSEGV 裸奔（FFI 段错误 Dart catch 不住）
    if (_initialized && _jsRuntime != null) return true;

    // [状态一致性修复] 上次 init() 在 getJavascriptRuntime() 之后失败的情况：
    // _jsRuntime 已赋值但 _initialized=false，旧 runtime 未正确 dispose。
    // 直接置 null 会让 Finalizer 在 GC 时回收，但时机不确定，可能在后续 FFI 调用
    // 过程中释放 C 侧 bridge → 野指针 → SIGSEGV。这里主动 dispose 确保立即释放。
    if (_jsRuntime != null && !_initialized) {
      try {
        _jsRuntime!.dispose();
      } catch (_) {}
      _jsRuntime = null;
    }

    // [FFI 健康检查] 在 getJavascriptRuntime() 之前，先调用简单的 C 函数验证 FFI 可用
    // nativeGetCpuCount() 只调用 sysconf，不会 SIGSEGV
    // 如果 DynamicLibrary.open 或 lookup 失败，会抛 ArgumentError（可捕获）
    // 覆盖安装后第一次启动时，若 .so 未完全就绪，这里能安全检测并返回 false
    // Dart 顶层 final 初始化失败后，后续访问会重新尝试初始化，故第二次 init() 可恢复
    try {
      final cpuCount = nativeGetCpuCount();
      if (cpuCount <= 0) {
        debugPrint('JsEngine init: FFI 健康检查失败，cpuCount=$cpuCount');
        _nativeLibChecked = false;
        return false;
      }
    } catch (e, st) {
      debugPrint('JsEngine init: FFI 健康检查异常（.so 可能未就绪）: $e\n$st');
      _nativeLibChecked = false;
      return false;
    }

    try {
      _jsRuntime = getJavascriptRuntime();
      // P2: 设置默认 JS 执行超时 5 秒，防止死循环卡死 App
      _jsRuntime!.setEvalTimeout(5000);
      // 加载 java-bridge.js（纯路由脚本，替代内联 polyfill）
      // 包含：Node 兼容层、URL/Buffer、btoa/atob→__nativeBase64、
      //       CryptoJS→__nativeCrypto、_JsoupLite→__nativeHtml、
      //       java 桥接对象（网络标记协议）
      await _loadJavaBridge();
      await _loadInstalledPackages();

      // 验证注入是否成功
      final verifyResult = evaluate('typeof java !== "undefined" && typeof CryptoJS !== "undefined" && typeof _javaCache !== "undefined"');
      if (verifyResult != 'true') {
        // 尝试重新加载
        await _loadJavaBridge();
        final retryResult = evaluate('typeof java !== "undefined"');
        if (retryResult != 'true') {
          // [状态一致性修复] 验证失败时 dispose runtime，避免下次 init() 创建新 runtime
          // 导致旧 runtime 的 Finalizer 在不确定时机释放 C 侧 bridge
          try {
            _jsRuntime!.dispose();
          } catch (_) {}
          _jsRuntime = null;
          return false;
        }
      }

      _initialized = true;
      return true;
    } catch (e, st) {
      // FFI lookup 失败（QuickJS 符号未链接到二进制）会在此抛出 ArgumentError
      // 之前被静默吞掉，现在打印日志便于诊断
      debugPrint('JsEngine init failed: $e\n$st');
      // [状态一致性修复] 异常路径 dispose runtime，避免野指针
      if (_jsRuntime != null) {
        try {
          _jsRuntime!.dispose();
        } catch (_) {}
        _jsRuntime = null;
      }
      return false;
    }
  }

  /// 加载 java-bridge.js 桥接脚本
  ///
  /// 从 assets/js_polyfill/java-bridge.js 加载纯路由脚本，替代内联 JS polyfill。
  /// 脚本包含：
  /// - Node.js 最小兼容层（process, Buffer, URL, URLSearchParams）
  /// - btoa/atob → __nativeBase64（C 原生）
  /// - LZString → __nativeLz（C 原生）
  /// - CryptoJS 兼容层 → __nativeCrypto（C 原生）
  /// - _JsoupLite → __nativeHtml（C 原生）
  /// - java 桥接对象（网络标记协议，HTTP 请求由 Dart Dio 处理）
  /// - console 增强（日志缓存）
  Future<void> _loadJavaBridge() async {
    if (_jsRuntime == null) return;
    try {
      // 1. 加载 java-bridge.js（核心桥接脚本）
      final script = await rootBundle.loadString('assets/js_polyfill/java-bridge.js');
      _jsRuntime!.evaluate(script);
      // 预编译脚本到字节码缓存（加速后续 evaluate）
      _jsRuntime!.precompile(script);
      // 2. 加载 console-utils.js（日志提取与恢复工具）
      final consoleUtils = await rootBundle.loadString('assets/js_polyfill/console-utils.js');
      _jsRuntime!.evaluate(consoleUtils);
      _jsRuntime!.precompile(consoleUtils);
    } catch (e, st) {
      debugPrint('JsEngine: 加载 java-bridge.js 失败: $e\n$st');
      // 回退：加载最小 polyfill 脚本，避免后续 evaluate 崩溃
      try {
        final fallback = await rootBundle.loadString('assets/js_polyfill/fallback-polyfill.js');
        _jsRuntime!.evaluate(fallback);
      } catch (_) {}
    }
  }

  /// [覆盖安装闪退修复] Native lib 完整性安全验证
  /// 通过 MethodChannel 走到 Java 层检查 .so 文件 + loadLibrary，
  /// 不执行任何 FFI 调用，100% 避免 SIGSEGV。
  /// 初始为 false，init() 成功设为 true，dispose() 重置
  bool _nativeLibChecked = false;

  bool get isAvailable => _initialized && _jsRuntime != null;

  // ===== Phase 6: 性能统计接口（代理到 JavascriptRuntime）=====

  /// 获取 C 原生加密累计统计快照
  /// 包含 AES/MD5/SHA/LZString/AES+LZ 原子组合/批量解压 所有路径
  /// 返回 null 表示 runtime 未初始化（Web 平台返回零值对象）
  CryptoStats? getCryptoStats() => _jsRuntime?.getCryptoStats();

  /// 重置统计计数器
  void resetCryptoStats() => _jsRuntime?.resetCryptoStats();

  // ===== Phase 4: 字节码缓存接口（代理到 JavascriptRuntime）=====

  /// 预编译脚本到字节码缓存（不执行）
  ///
  /// 后续 evaluate 同一脚本时跳过词法/语法分析，直接走 JS_EvalFunction。
  /// 适用于核心库初始化、书源规则预热等场景。
  /// Web 平台返回 false（不支持）。
  bool precompile(String script) {
    if (_jsRuntime == null) return false;
    return _jsRuntime!.precompile(script);
  }

  /// 清空字节码缓存
  ///
  /// 释放所有缓存条目占用的内存。适用于书源切换、内存压力、调试场景。
  void clearBytecodeCache() => _jsRuntime?.clearBytecodeCache();

  /// 暴露 CPU 核心数（用于面板显示并行能力，Web 返回 1）
  int get nativeCpuCount {
    try {
      return nativeGetCpuCount();
    } catch (_) {
      return 1;
    }
  }

  // ===== 参考 quickjs-ng/quickjs-zh：高价值 API 代理 =====

  /// QuickJS 引擎版本号（Web 平台返回 'Web (no QuickJS)'）
  String get quickJsVersion {
    try {
      return nativeGetQuickJsVersion();
    } catch (_) {
      return 'unknown';
    }
  }

  /// 获取 QuickJS 引擎内部内存统计（20+ 字段，来自 JS_ComputeMemoryUsage）
  /// 返回 null 表示 runtime 未初始化（Web 平台返回零值对象）
  JsMemoryStats? getJsMemoryStats() => _jsRuntime?.getJsMemoryStats();

  /// 手动触发 GC（JS_RunGC）
  void runGc() => _jsRuntime?.runGc();

  /// 检查当前 context 是否有未捕获的异常（不取出）
  bool get hasException => _jsRuntime?.hasException() ?? false;

  /// 获取 Promise 状态
  /// 返回: 0=非Promise, 1=pending, 2=fulfilled, 3=rejected
  int promiseState(String varName) {
    if (_jsRuntime == null) return 0;
    try {
      return _jsRuntime!.promiseState(varName);
    } catch (_) {
      return 0;
    }
  }

  /// 流式打印 JS 值（调试用）
  String? printValue(String jsExpr, {int maxDepth = 0, int maxStringLength = 0}) {
    if (_jsRuntime == null) return null;
    try {
      return _jsRuntime!.printValue(jsExpr,
          maxDepth: maxDepth, maxStringLength: maxStringLength);
    } catch (_) {
      return null;
    }
  }

  // ===== 解析加速：原生字符串工具（代理到 C 层）=====

  /// C 原生 HTML 实体反转义
  /// 单次扫描替代 Dart RegExp + replaceAllMapped，1300 章×6 字段场景收益显著
  String unescapeHtmlNative(String input) {
    try {
      return nativeUnescapeHtml(input);
    } catch (_) {
      return input;
    }
  }

  /// C 原生 URL 编码（支持指定字符集：GBK/GB2312/GB18030/UTF-8）
  /// 通过 quickjs_bridge_charset_url_encode 实现
  String urlEncodeNative(String input, String charset) {
    try {
      return nativeCharsetUrlEncode(input, charset);
    } catch (_) {
      return input;
    }
  }

  /// C 原生 URL 解码（percent-decode，+ 解码为空格）
  String urlDecodeNative(String input) {
    try {
      return nativeUrlDecode(input);
    } catch (_) {
      return input;
    }
  }

  // ===== 解析加速：C 原生 HTML 解析 + CSS 选择器 =====

  /// C 原生 HTML 解析 + CSS 查询 + 属性提取（原子调用）
  ///
  /// 单次 FFI 完成全部操作，替代 Dart html 包的 querySelectorAll + 多层 fallback。
  /// 1300 章目录场景下消除 1300 次 html_parser.parse 和 7800 次 CSS 查询的 Dart 开销。
  ///
  /// [html] HTML 字符串
  /// [selector] CSS 选择器（tag .class #id [attr] [attr=val] 后代 子代 :nth-child :eq）
  /// [attr] 属性名，特殊值: @text @html @outerHtml @tag
  /// [listMode] true=返回 JSON 数组字符串, false=返回第一个匹配的纯字符串
  String htmlQueryExtractNative(String html, String selector, String attr, bool listMode) {
    try {
      return nativeHtmlQueryExtract(html, selector, attr, listMode);
    } catch (_) {
      return listMode ? '[]' : '';
    }
  }

  // ===== 分流策略 =====

  /// 解析规则代码，剥离 @js: 前缀和 <js></js> 标签
  ///
  /// 只保留 @js: 作为唯一前缀声明，其他引擎类型声明已移除
  _EngineResolveResult resolveEngine(String ruleCode, {JsEngineType? sourceEngine}) {
    String code = ruleCode;

    // 1. 剥离 @js: 前缀
    if (_jsPrefixRegex.hasMatch(code)) {
      code = code.replaceFirst(_jsPrefixRegex, '').trim();
    }

    // 2. 剥离 <js></js> 标签
    if (code.startsWith('<js>')) {
      code = code.replaceAll(_engineTagRegex, '').trim();
    }

    return _EngineResolveResult(JsEngineType.quickjs, code);
  }

  // ===== 以下内联 JS polyfill 已全部迁移到 assets/js_polyfill/java-bridge.js =====
  // 删除的方法：_injectNodePolyfills / _injectAesEngine / _injectAesFallback /
  //            _injectMd5Engine / _injectShaEngine / _injectJavaBridge
  // 这些方法已被 _loadJavaBridge() 加载的 java-bridge.js 完全替代

  // ===== 自定义库管理 =====

  Future<bool> installPackage(String name, String code, {String? version}) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final pkgDir = Directory('${dir.path}/js_packages/$name');
      if (!await pkgDir.exists()) {
        await pkgDir.create(recursive: true);
      }

      final file = File('${pkgDir.path}/index.js');
      await file.writeAsString(code);

      final info = {
        'name': name,
        'version': version ?? '1.0.0',
        'installedAt': DateTime.now().toIso8601String(),
      };
      final infoFile = File('${pkgDir.path}/package.json');
      await infoFile.writeAsString(jsonEncode(info));

      _installedPackages[name] = code;
      _registerPackage(name, code);

      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> installPackageFromUrl(String name, String url) async {
    try {
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> uninstallPackage(String name) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final pkgDir = Directory('${dir.path}/js_packages/$name');
      if (await pkgDir.exists()) {
        await pkgDir.delete(recursive: true);
      }
      _installedPackages.remove(name);
      _moduleCache.remove(name);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getInstalledPackages() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final pkgDir = Directory('${dir.path}/js_packages');
      if (!await pkgDir.exists()) return [];

      final packages = <Map<String, dynamic>>[];
      await for (final entity in pkgDir.list()) {
        if (entity is Directory) {
          final infoFile = File('${entity.path}/package.json');
          if (await infoFile.exists()) {
            final info = jsonDecode(await infoFile.readAsString());
            packages.add(info as Map<String, dynamic>);
          }
        }
      }
      return packages;
    } catch (e) {
      return [];
    }
  }

  Future<void> _loadInstalledPackages() async {
    final packages = await getInstalledPackages();
    for (final pkg in packages) {
      final name = pkg['name'] as String?;
      if (name == null) continue;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/js_packages/$name/index.js');
      if (await file.exists()) {
        final code = await file.readAsString();
        _installedPackages[name] = code;
        _registerPackage(name, code);
      }
    }
  }

  void _registerPackage(String name, String code) {
    final wrappedCode = '''
      _modules['$name'] = function(module, exports, require) {
        $code
      };
    ''';
    evaluate(wrappedCode);
  }

  // ===== QuickJS 引擎执行 =====

  dynamic evaluate(String script) {
    if (_jsRuntime == null) return null;
    // [并发安全] 如果 processJsRule/batchEvaluate 正持有 _evalLock，
    // 同步 evaluate 无法等待锁，直接返回 null 避免并发调用 _bridgeEval 导致 SIGSEGV
    if (_evalBusy) {
      debugPrint('⚠️ evaluate 跳过：JS引擎正忙（_evalLock 占用中）');
      return null;
    }
    _evalBusy = true;
    final sw = Stopwatch()..start();
    String? resultStr;
    bool isError = false;
    String? errMsg;
    try {
      final result = _jsRuntime!.evaluate(script);
      isError = result.isError;
      resultStr = result.stringResult;
      return resultStr;
    } catch (e) {
      isError = true;
      errMsg = e.toString();
      return null;
    } finally {
      _evalBusy = false;
      sw.stop();
      // 自动 flush JS console 日志（防递归：日志 flush 内部调用 evaluate 时不再次 flush）
      if (!_isFlushingLogs) {
        _flushConsoleLogs();
        // 输出执行链路：脚本预览 + 行数 + 耗时 + 结果
        _logExecutionTrace(script, sw.elapsedMilliseconds, isError, errMsg ?? resultStr);
      }
    }
  }

  /// 输出 JS 执行链路追踪：脚本预览 + 行数 + 耗时 + 结果
  /// message 以 [JS] 开头，匹配调试 tab 的注入规则（debug 级 + [JS] 前缀）
  void _logExecutionTrace(String script, int elapsedMs, bool isError, String? resultOrErr) {
    if (!kDebugMode) return;
    // 日志出锁设计：锁内只记录关键信息，字符串构建移到 AppLogger 中异步处理
    // 避免锁内在 debugPrint 上停留
    final scriptPreview = script.length > 80 ? '${script.substring(0, 80)}...' : script;
    AppLogger.instance.info(LogCategory.js, '[JS] eval ${elapsedMs}ms ${isError ? "ERROR" : "OK"} | $scriptPreview',
      detail: resultOrErr != null && resultOrErr.length > 200 ? '${resultOrErr.substring(0, 200)}...' : (resultOrErr ?? ''));
  }

  /// 批量 JS 执行（轻量路径，用于目录/搜索列表批量解析）
  ///
  /// 跳过 processJsRule 的重路径：不执行 _preCacheBridgeCalls 正则扫描、
  /// 不构建巨大 wrappedScript、不执行 JsTracer。
  /// 通过 _evalLock 串行保证线程安全。
  /// 仅在出错时记录日志（正常路径零日志）。
  ///
  /// [script] 完整的 JS 脚本（调用方已构造好，含变量注入）
  /// 返回 evaluate 的原始字符串结果
  Future<String?> batchEvaluate(String script) async {
    if (_jsRuntime == null) return null;
    try {
      return _evalLock.synchronized(() {
        _evalBusy = true;
        try {
          final result = _jsRuntime!.evaluate(script);
          if (result.isError) {
            // 仅在出错时记录日志
            AppLogger.instance.logJsError('batchEvaluate', result.stringResult);
            return null;
          }
          return result.stringResult;
        } finally {
          _evalBusy = false;
        }
      });
    } catch (e) {
      AppLogger.instance.logJsError('batchEvaluate', e.toString());
      return null;
    }
  }

  Future<dynamic> evaluateAsync(String script) async {
    if (!_initialized || _jsRuntime == null) return null;
    try {
      final result = await _jsRuntime!.evaluateAsync(script);
      if (result.isError) {
        return null;
      }
      return result.stringResult;
    } catch (e) {
      return null;
    }
  }

  /// 同步执行 JS 代码（用于 AnalyzeRule 规则解析）
  /// 默认走 QuickJS
  /// 注意：此方法是同步的，不要直接调用 QuickJS FFI 的面板方法（getJsMemoryStats 等）
  /// 调试面板已移除自动刷新 FFI 调用，避免并发崩溃
  dynamic executeSync(String jsCode, dynamic content, {String? baseUrl, JsEngineType? sourceEngine, Map<String, dynamic>? variables, String? ruleStep}) {
    // 先提取 JS 代码（去掉 <js></js> 标签或 @js: 前缀）
    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final resolved = resolveEngine(extracted, sourceEngine: sourceEngine);

    final engineTag = 'QuickJS';
    final codePreview = resolved.code;

    // 显式增加 QuickJS 执行计数（统一计数入口）
    AppLogger.instance.incrementQuickjsCount();
    // JS 执行链路日志（info 级别，Release 模式可见）：输出完整代码与输入
    AppLogger.instance.logJsExecute(engineTag, codePreview);
    AppLogger.instance.logJsStep(engineTag, '同步执行JS 开始',
      detail: 'ruleStep=${ruleStep ?? "N/A"}, codeLen=${codePreview.length}, contentLen=${content?.toString().length ?? 0}');
    AppLogger.instance.logJsInput(engineTag, content?.toString(), tag: 'sync');

    // 追踪树：创建节点
    JsTraceNode? traceNode;
    if (JsTracer.instance.enabled) {
      final tracer = JsTracer.instance;
      String? inputPreview;
      if (content is List || content is Map) {
        try {
          inputPreview = jsonEncode(content);
        } catch (_) {
          inputPreview = content.toString();
        }
      } else {
        inputPreview = content?.toString();
      }
      if (tracer._stack.isEmpty) {
        traceNode = tracer.beginRoot('executeSync', engineTag, codePreview,
          inputPreview: inputPreview, ruleStep: ruleStep);
      } else {
        traceNode = tracer.addChild('executeSync', engineTag, codePreview,
          inputPreview: inputPreview, ruleStep: ruleStep);
      }
      tracer.push(traceNode);
    }

    dynamic result;
    Object? caughtError;
    String? evalError;
    _lastEvalError = null;
    try {
      result = _executeQuickJSSync(resolved.code, content, baseUrl: baseUrl, variables: variables);
      evalError = _lastEvalError;
    } catch (e) {
      caughtError = e;
      rethrow;
    } finally {
      // 追踪树：记录输出（无论成功或异常都 pop，保证栈平衡）
      if (traceNode != null) {
        final outputStr = result?.toString();
        // 输出完整内容到日志（不再截断），便于调试页面查看
        JsTracer.instance.pop(
          outputPreview: outputStr,
          outputType: result?.runtimeType.toString(),
          error: caughtError?.toString() ?? evalError,
        );
      }
      // 输出完整执行结果到日志链路
      AppLogger.instance.logJsOutput(engineTag, result?.toString(),
        outputType: result?.runtimeType.toString(), tag: 'sync');
    }

    return result;
  }

  /// 异步执行 JS 代码（用于图片解密等异步场景）
  ///
  /// 与 [executeSync] 功能相同，但通过 _evalLock 等待锁释放，
  /// 不会被 _evalBusy 挡掉返回 null。
  /// 当图片解密与章节解析等 JS 任务并发时，必须使用此方法。
  Future<dynamic> executeAsync(String jsCode, dynamic content,
      {String? baseUrl, JsEngineType? sourceEngine, Map<String, dynamic>? variables}) async {
    // 入口清空上次错误，避免状态污染（executeAsync 可能在 init 失败时直接返回 null，
    // 此时 _lastEvalError 应为 null 而非旧值）
    _lastEvalError = null;
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) {
        _lastEvalError = 'JS引擎未初始化';
        return null;
      }
    }

    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final resolved = resolveEngine(extracted, sourceEngine: sourceEngine);

    return _evalLock.synchronized(() {
      _evalBusy = true;
      try {
        return _executeQuickJSSync(resolved.code, content,
            baseUrl: baseUrl, variables: variables, skipBusyCheck: true);
      } finally {
        _evalBusy = false;
      }
    });
  }

  /// QuickJS 同步执行
  /// 支持并发防护 _evalBusy：如果 processJsRule 正持有锁，快速返回 null 避免 QuickJS 崩溃
  dynamic _executeQuickJSSync(String jsCode, dynamic content, {String? baseUrl, Map<String, dynamic>? variables, bool skipBusyCheck = false}) {
    if (!_initialized || _jsRuntime == null) {
      return null;
    }

    // 并发防护：_evalBusy=true 表示 processJsRule 正通过 _evalLock 占用 QuickJS
    // 同步路径无法等待锁释放，直接返回 null，调用方（analyze_rule）收到 null 自动兜底
    // skipBusyCheck=true 时跳过检查（已通过 executeAsync 获取锁）
    if (_evalBusy && !skipBusyCheck) {
      _lastEvalError = 'JS引擎正忙（processJsRule 占用中），跳过同步执行';
      debugPrint('⚠️ $_lastEvalError');
      AppLogger.instance.warn(LogCategory.parse, _lastEvalError!);
      return null;
    }

    _evalBusy = true;
    // 清空上次错误信息，避免污染本次诊断（成功执行后保持为 null）
    _lastEvalError = null;
    try {
      // content 序列化：List/Map 直接 jsonEncode，String 也 jsonEncode（加引号转义），其他 toString
      final contentStr = serializeForJs(content);

      // 自动补 return：如果 JS 代码不以 return 结尾，自动包裹使其返回最后一个表达式的值
      final wrappedCode = _wrapJsCode(jsCode);

      // 构建变量注入代码（排除核心变量，避免覆盖 result/baseUrl/src）
      // 'content' 不作为核心变量：对齐 legado evalJS（只注入 src=content，不注入 content 变量），
      // 否则会把 content 注入成字符串，破坏书源 content(result) 这类函数调用，并覆盖书源自定义 content。
      final coreVars = {'result', 'baseUrl', 'src'};
      final varInjections = <String>[];
      final globalVarInjections = <String>[];
      if (variables != null) {
        for (final entry in variables.entries) {
          if (!coreVars.contains(entry.key)) {
            varInjections.add('var ${entry.key} = ${jsonEncode(entry.value)};');
            // 同步到 globalThis，让 jsLib 全局函数也能访问
            globalVarInjections.add('globalThis.${entry.key} = ${jsonEncode(entry.value)};');
          }
        }
      }
      final varCode = varInjections.join('\n');
      final globalVarCode = globalVarInjections.join('\n');

      // 构建共享作用域变量注入（借鉴 legado 的 scope 链）
      final sharedVars = <String, String>{};
      final sourceUrl = variables?['source']?['bookSourceUrl'] as String?;
      if (sourceUrl != null && _sharedScopeVars.containsKey(sourceUrl)) {
        sharedVars.addAll(_sharedScopeVars[sourceUrl]!);
      }
      final sharedVarsCode = sharedVars.entries.map((e) =>
        'var ${e.key} = ${jsonEncode(e.value)};'
      ).join('\n');

      // jsLib 已通过 loadJsLib() 加载到全局作用域
      // 借鉴 legado：evalJS 时 bindings.prototype = sharedScope
      // QuickJS 等价：jsLib 函数在 globalThis 上，IIFE 内部自动可访问

      final wrappedScript = '''
        (function() {
          var result = $contentStr;
          var baseUrl = ${jsonEncode(baseUrl ?? '')};
          var src = ${variables?.containsKey('src') == true ? jsonEncode(variables!['src']?.toString() ?? '') : contentStr};
          $sharedVarsCode
          $varCode

          // 同步关键变量到 globalThis，让 jsLib 全局函数也能访问
          globalThis.result = result;
          globalThis.baseUrl = baseUrl;
          globalThis.src = src;
          $globalVarCode

          var __returnValue;
          try {
            __returnValue = (function() { $wrappedCode })();
          } catch (e) {
            // 兜底捕获 jsLib 函数未处理的异常（如 aesDecryptNative 抛出的 TypeError）
            // 避免异常传播到 evaluate 顶层导致 evalResult.isError=true，调用方收到 null
            console.error('[JS引擎] 函数执行异常: ' + e);
            __returnValue = null;
          }
          if (typeof __returnValue === 'object' && __returnValue !== null) {
// Uint8Array / ArrayBuffer → base64 字符串（C 原生 b64FromBytes）
// 避免大图片解密后用 JSON.stringify(Array.from(...)) 生成超长 JSON 数字数组
// 调用方（decodeImage）通过 base64Decode 还原字节
if (__returnValue instanceof Uint8Array) {
return __nativeBase64.b64FromBytes(__returnValue);
}
if (__returnValue instanceof ArrayBuffer) {
return __nativeBase64.b64FromBytes(new Uint8Array(__returnValue));
}
return JSON.stringify(__returnValue);
}
return __returnValue;
})();
''';
final evalResult = _jsRuntime!.evaluate(wrappedScript);
_flushConsoleLogs();
if (evalResult.isError) {
  // 记录完整错误信息 + 代码片段，方便诊断
  final codePreview = jsCode.length > 200 ? '${jsCode.substring(0, 200)}...' : jsCode;
  final errStr = evalResult.stringResult;
  final errPreview = errStr.length > 80 ? errStr.substring(0, 80) : errStr;
  // 标题包含错误概要，避免日志去重时丢失关键信息
  AppLogger.instance.error(LogCategory.js,
      '[QuickJS] 执行失败: $errPreview',
      detail: '完整错误: $errStr\n  代码片段: $codePreview');
  debugPrint('❌ [QuickJS] 执行失败: $errStr\n  代码: $codePreview');
  _lastEvalError = errStr;
  return null;
}
      final parsed = _parseJsResult(evalResult.stringResult);
      // 诊断：parsed 为空或 null 时记录原始 stringResult，帮助定位解密失败原因
      if (parsed == null || (parsed is String && parsed.isEmpty)) {
        final rawPreview = evalResult.stringResult.length > 80
            ? '${evalResult.stringResult.substring(0, 80)}...'
            : evalResult.stringResult;
        _lastEvalError = 'JS返回空值: stringResult=$rawPreview';
        // 强制提取 console 日志（即使 Release 模式），帮助定位 null 根因
        // decryptImage 等函数内部 try-catch 的异常只通过 console.error 记录，
        // Release 模式下 _flushConsoleLogs 会跳过提取，导致诊断信息丢失
        final consoleLogs = _extractConsoleLogsForDiagnosis();
        AppLogger.instance.error(LogCategory.js,
            '[QuickJS] 返回空值: $rawPreview',
            detail: '完整 stringResult: ${evalResult.stringResult}${consoleLogs.isNotEmpty ? '\nconsole日志: $consoleLogs' : ''}');
      }
      // 同步执行完成日志（info 级别，Release 模式可见）
      AppLogger.instance.logJsStep('QuickJS', '同步执行完成',
        detail: 'resultType=${parsed?.runtimeType}, resultLen=${parsed?.toString().length ?? 0}, isError=${evalResult.isError}');
      return parsed;
    } catch (e) {
      final errStr = e.toString();
      final errPreview = errStr.length > 80 ? errStr.substring(0, 80) : errStr;
      AppLogger.instance.error(LogCategory.js,
          '[QuickJS] 捕获异常: $errPreview',
          detail: '完整错误: $errStr');
      _lastEvalError = errStr;
      // 引擎级错误（OOM/段错误兜底）记录到崩溃日志
      unawaited(CrashLogService.instance.logJsEngineError('QuickJS.eval', errStr));
      return null;
    } finally {
      _evalBusy = false;
    }
  }

  /// 包裹 JS 代码，确保最后一个表达式的值被返回
  ///
  /// 策略：
  /// 1. 代码以 return 开头 → 直接使用（顶层已有 return）
  /// 2. 单行代码 → `return <code>`
  /// 3. 多行代码包含 return 关键字 → `return (function(){ <code> })()`
  ///    内层函数确保 return 语句从函数返回（不触发 eval 的 return 兼容性问题）
  /// 4. 多行代码无 return 关键字 → `return eval(<code>)`
  ///    eval 返回最后一个表达式的值（如 `imgTags;` 的值），内层函数无法做到
  String _wrapJsCode(String code) {
    final trimmed = code.trim();

    // 代码以 return 开头 → 直接使用（顶层已有 return）
    if (_returnStartRegex.hasMatch(trimmed)) {
      return trimmed;
    }

    // 单行代码：直接 return
    final lines = trimmed.split('\n');
    if (lines.length == 1) {
      return 'return $trimmed';
    }

    // 多行代码：根据是否包含 return 关键字选择包裹方式
    if (_returnKeywordRegex.hasMatch(trimmed)) {
      // 有 return：用内层函数包裹，return 从内层函数返回
      return 'return (function() {\n$trimmed\n})();';
    }
    // 无 return：用 eval 包裹，返回最后一个表达式的值
    return 'return eval(${jsonEncode(trimmed)})';
  }

  /// 从规则字符串中提取 JS 代码
  /// 支持：<js>code</js>、@js:code
  String? _extractJsCode(String rule) {
    // <js>code</js> 格式
    final jsTagMatch = _jsTagRegex.firstMatch(rule);
    if (jsTagMatch != null) {
      return jsTagMatch.group(1)?.trim();
    }

    // @js:code 格式
    if (_jsPrefixRegex.hasMatch(rule)) {
      return rule.replaceFirst(_jsPrefixRegex, '').trim();
    }

    // {{expression}} 格式
    final templateMatch = _templateVarRegex.firstMatch(rule);
    if (templateMatch != null) {
      return 'return ${templateMatch.group(1)?.trim()}';
    }

    return null;
  }

  // ===== 书源规则执行（分流核心）=====

  /// 处理 JS 书源规则（异步）
  Future<String?> processJsRule(String content, String jsCode, {String? baseUrl, JsEngineType? sourceEngine, Map<String, dynamic>? env, dynamic dynamicContent}) async {
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) return null;
    }

    // 先提取 JS 代码（去掉 <js></js> 标签或 @js: 前缀）
    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final resolved = resolveEngine(extracted, sourceEngine: sourceEngine);

    // 显式增加 QuickJS 执行计数（统一计数入口）
    AppLogger.instance.incrementQuickjsCount();
    // JS 执行链路日志（info 级别，Release 模式可见）：打印完整 JS 代码
    AppLogger.instance.logJsExecute('QuickJS', resolved.code);

    // 合并 env：传入的 env 优先，补充 baseUrl
    final mergedEnv = <String, dynamic>{
      'baseUrl': baseUrl ?? '',
    };
    if (env != null) {
      mergedEnv.addAll(env);
      if (!mergedEnv.containsKey('baseUrl')) mergedEnv['baseUrl'] = baseUrl ?? '';
    }

    // 优先使用 dynamicContent（保留原始类型：List/Map 等）
    // 否则用 content（String 类型，会被 jsonEncode 加引号）
    final actualResult = dynamicContent ?? content;

    // 网络标记协议：不再预缓存，JS 执行时遇到 java.get/post 会抛出 __NEED_NETWORK__ 标记，
    // 由 _executeQuickJSRule 内部捕获并用 Dio 发起请求，结果写入 _javaCache 后重新执行。
    // 优势：支持动态 URL（运行时构造），无需正则扫描，代码量减少 ~1500 行。

    // 输出 processJsRule 入参信息（info 级别，Release 模式可见）
    AppLogger.instance.logJsInput('QuickJS',
      actualResult is String ? actualResult : actualResult?.toString(),
      tag: 'processJsRule');
    AppLogger.instance.logJsStep('QuickJS', '[processJsRule] 入参',
      detail: 'result type=${actualResult.runtimeType}, len=${actualResult is String ? actualResult.length : (actualResult is List ? actualResult.length : '?')}, baseUrl=$baseUrl');

    // 优化：移除多余的 await Future(() {})，_executeQuickJSRule 内部已有让出事件循环的逻辑
    // 对于时间戳敏感的短小 JS（如搜索 URL 生成），减少 ~5-10ms 延迟

    return _evalLock.synchronized(() {
      _evalBusy = true;
      try {
        return _executeQuickJSRule(resolved.code, result: actualResult, env: mergedEnv, variables: _extractVariables(mergedEnv));
      } finally {
        _evalBusy = false;
      }
    });
  }

  /// 处理带书籍上下文的 JS 规则
  Future<String?> processJsWithBook(
    String jsCode, {
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
    Map<String, dynamic>? source,
    String? content,
    int? index,
    JsEngineType? sourceEngine,
  }) async {
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) return null;
    }

    // 先提取 JS 代码
    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final resolved = resolveEngine(extracted, sourceEngine: sourceEngine);

    return _evalLock.synchronized(() async {
      try {
      final wrappedCode = _wrapJsCode(resolved.code);

      // 构建共享作用域变量注入
      final sharedVars = <String, String>{};
      final sourceUrl = source?['bookSourceUrl'] as String?;
      if (sourceUrl != null && _sharedScopeVars.containsKey(sourceUrl)) {
        sharedVars.addAll(_sharedScopeVars[sourceUrl]!);
      }
      final sharedVarsCode = sharedVars.entries.map((e) =>
        'var ${e.key} = ${jsonEncode(e.value)};'
      ).join('\n');

      final wrappedScript = '''
        (function() {
          var result = ${jsonEncode(content ?? '')};
          var baseUrl = ${jsonEncode(book?['bookUrl'] ?? '')};
          var book = ${jsonEncode(book ?? {})};
          var chapter = ${jsonEncode(chapter ?? {})};
          var source = ${jsonEncode(source ?? {})};
          var cookie = ${jsonEncode(<String, String>{})};
          var index = ${jsonEncode(index ?? 0)};
          $sharedVarsCode

          // 同步关键变量到 globalThis，让 jsLib 全局函数也能访问
          globalThis.result = result;
          globalThis.baseUrl = baseUrl;
          globalThis.book = book;
          globalThis.chapter = chapter;
          globalThis.source = source;
          globalThis.cookie = cookie;

          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
// Uint8Array / ArrayBuffer → base64 字符串（C 原生 b64FromBytes）
// 避免大图片解密后用 JSON.stringify(Array.from(...)) 生成超长 JSON 数字数组
// 调用方（decodeImage）通过 base64Decode 还原字节
if (__returnValue instanceof Uint8Array) {
return __nativeBase64.b64FromBytes(__returnValue);
}
if (__returnValue instanceof ArrayBuffer) {
return __nativeBase64.b64FromBytes(new Uint8Array(__returnValue));
}
return JSON.stringify(__returnValue);
}
return __returnValue;
})();
''';
// 先 yield 让出事件循环
      await Future(() {});
      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      _flushConsoleLogs();
      if (evalResult.isError) {
        AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
        return null;
      }
      return evalResult.stringResult;
      } catch (e) {
        AppLogger.instance.logJsError('QuickJS', e.toString());
        return null;
      }
    });
  }

  /// 执行书源规则（统一入口）
  ///
  /// 规则前缀：
  /// - @js: / <js> → 剥离前缀后走 QuickJS
  /// - 无前缀 → 直接走 QuickJS
  Future<String?> evaluateBookRule(String ruleCode, {
    dynamic result,
    Map<String, dynamic>? env,
    JsEngineType? sourceEngine,
  }) async {
    final resolved = resolveEngine(ruleCode, sourceEngine: sourceEngine);
    var code = resolved.code;

    return _evalLock.synchronized(() =>
      _executeQuickJSRule(code, result: result, env: env)
    );
  }

  // ===== QuickJS 规则执行 =====

  /// 从 env 中提取非核心变量，用于注入到 JS 作用域
  static const _coreEnvVars = {'result', 'baseUrl', 'src', 'book', 'chapter', 'source', 'cookie', 'title'};

  Map<String, dynamic>? _extractVariables(Map<String, dynamic>? env) {
    if (env == null) return null;
    final vars = <String, dynamic>{};
    for (final entry in env.entries) {
      if (!_coreEnvVars.contains(entry.key)) {
        vars[entry.key] = entry.value;
      }
    }
    return vars.isEmpty ? null : vars;
  }

  Future<String?> _executeQuickJSRule(String jsCode, {
    dynamic result,
    Map<String, dynamic>? env,
    Map<String, dynamic>? variables,
    String? ruleStep,
  }) async {
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) return null;
    }
    // 追踪树：创建节点（提到 try 之前，catch 块也能访问）
    JsTraceNode? traceNode;
    try {
      // 断点1：记录原始JS代码
      final codePreview = jsCode;
      // JS 执行链路日志（info 级别，Release 模式可见）：打印完整 JS 代码
      AppLogger.instance.logJsStep('QuickJS', '[QuickJS] 开始异步执行',
        detail: 'ruleStep=${ruleStep ?? "N/A"}, codeLen=${codePreview.length}');
      AppLogger.instance.logJsInput('QuickJS',
        result is String ? result : result?.toString(),
        tag: 'async');

      // 追踪树：创建节点
      if (JsTracer.instance.enabled) {
        final tracer = JsTracer.instance;
        // 安全生成 inputPreview：List/Map 用 jsonEncode（截断），String 截断，其他 toString
        String? inputPreview;
        if (result is List || result is Map) {
          final encoded = jsonEncode(result);
          inputPreview = encoded.length > 500 ? '${encoded.substring(0, 500)}...' : encoded;
        } else if (result is String) {
          inputPreview = result.length > 500 ? '${result.substring(0, 500)}...' : result;
        } else {
          inputPreview = result?.toString();
          if (inputPreview != null && inputPreview.length > 500) {
            inputPreview = '${inputPreview.substring(0, 500)}...';
          }
        }
        final codePreviewTrunc = codePreview.length > 500
            ? '${codePreview.substring(0, 500)}...' : codePreview;
        if (tracer._stack.isEmpty) {
          traceNode = tracer.beginRoot('_executeQuickJSRule', 'QuickJS', codePreviewTrunc,
            inputPreview: inputPreview, ruleStep: ruleStep);
        } else {
          traceNode = tracer.addChild('_executeQuickJSRule', 'QuickJS', codePreviewTrunc,
            inputPreview: inputPreview, ruleStep: ruleStep);
        }
        tracer.push(traceNode);
      }

      // 自动补 return
      final wrappedCode = _wrapJsCode(jsCode);

      // 断点2：记录包装后的代码（info 级别，Release 模式可见）
      AppLogger.instance.logJsStep('QuickJS', '[QuickJS] 代码包装完成',
        detail: wrappedCode);

      // 构建共享作用域变量注入（借鉴 legado 的 scope 链）
      final sharedVars = <String, String>{};
      final sourceUrl = env?['source']?['bookSourceUrl'] as String?;
      if (sourceUrl != null && _sharedScopeVars.containsKey(sourceUrl)) {
        sharedVars.addAll(_sharedScopeVars[sourceUrl]!);
      }

      // 构建共享变量注入代码
      final sharedVarsCode = sharedVars.entries.map((e) =>
        'var ${e.key} = ${jsonEncode(e.value)};'
      ).join('\n');

      // 构建额外变量注入代码（排除核心变量，避免覆盖）
      final coreVars = {'result', 'baseUrl', 'src', 'book', 'chapter', 'source', 'cookie', 'title'};
      final varInjections = <String>[];
      final globalVarInjections = <String>[];
      if (variables != null) {
        for (final entry in variables.entries) {
          if (!coreVars.contains(entry.key)) {
            final encoded = jsonEncode(entry.value);
            varInjections.add('var ${entry.key} = $encoded;');
            // 同步到 globalThis，让 jsLib 全局函数也能访问
            globalVarInjections.add('globalThis.${entry.key} = $encoded;');
          }
        }
      }
      final varCode = varInjections.join('\n');
      final globalVarCode = globalVarInjections.join('\n');

      // jsLib 已通过 loadJsLib() 加载到全局作用域
      // 借鉴 legado：evalJS 时 bindings.prototype = sharedScope
      // QuickJS 等价：jsLib 函数在 globalThis 上，IIFE 内部自动可访问

      // 正确序列化 result：List/Map 直接 jsonEncode 生成 JS 数组/对象，
      // String 需要 jsonEncode 加引号转义，其他类型转字符串
      final resultStr = serializeForJs(result);

      final wrappedScript = '''
        (function() {
          var result = $resultStr;
          var baseUrl = ${jsonEncode(env?['baseUrl'] ?? '')};
          var book = ${jsonEncode(env?['book'] ?? {})};
          var chapter = ${jsonEncode(env?['chapter'] ?? {})};
          var source = (function() {
            var _data = ${getCachedSourceJson(env?['source'] as Map<String, dynamic>?)};
            var _vars = ${jsonEncode(env?['sourceVars'] ?? {})};
            // 借鉴 legado：source.getVariable() 无参返回 variable 字段的原始字符串值
            // source.getVariable(key) 有参返回指定 key 的值
            // source.setVariable(value) 设置整个 variable 字符串
            var obj = Object.assign({}, _data);
            obj.getVariable = function(key) {
              if (key === undefined) {
                // 无参：返回 variable 字段的原始值（legado 从 CacheManager 读取）
                return _data['variable'] || '';
              }
              return _vars[key] || _data[key] || '';
            };
            obj.setVariable = function(keyOrValue, value) {
              if (value === undefined) {
                // 单参数：设置整个 variable 字符串（legado 风格）
                _data['variable'] = String(keyOrValue);
              } else {
                // 双参数：设置指定 key
                _vars[keyOrValue] = String(value);
              }
              return keyOrValue;
            };
            obj.putVariable = function(value) {
              _data['variable'] = String(value);
              return value;
            };
            return obj;
          })();
          var cookie = ${jsonEncode(env?['cookie'] ?? {})};
          var title = ${jsonEncode(env?['chapter']?['title'] ?? '')};
          var src = result;

          // 注入共享作用域变量（借鉴 legado SharedJsScope）
          $sharedVarsCode

          // 注入额外变量（如 key, page 等）
          $varCode

          // 同步关键变量到 globalThis，让 jsLib 全局函数（如 search()）也能访问
          // jsLib 函数通过 loadJsLib() 加载到全局作用域，无法访问 IIFE 内的局部变量
          globalThis.result = result;
          globalThis.baseUrl = baseUrl;
          globalThis.book = book;
          globalThis.chapter = chapter;
          globalThis.source = source;
          globalThis.cookie = cookie;
          globalThis.src = src;
          $globalVarCode

          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
// Uint8Array / ArrayBuffer → base64 字符串（C 原生 b64FromBytes）
// 避免大图片解密后用 JSON.stringify(Array.from(...)) 生成超长 JSON 数字数组
// 调用方（decodeImage）通过 base64Decode 还原字节
if (__returnValue instanceof Uint8Array) {
return __nativeBase64.b64FromBytes(__returnValue);
}
if (__returnValue instanceof ArrayBuffer) {
return __nativeBase64.b64FromBytes(new Uint8Array(__returnValue));
}
return JSON.stringify(__returnValue);
}
return __returnValue;
})();
''';
// 优化：仅在 JS 代码较长时让出事件循环
      // 阈值 5KB：超过此长度的 JS 可能执行较久，需要让出事件循环避免阻塞 UI
      if (wrappedScript.length > 5000) {
        await Future(() {});
      }

      // ===== 网络标记协议 =====
      // JS 侧 java.get/post 在 _javaCache 未命中时抛出 __NEED_NETWORK__:{JSON} 标记，
      // Dart 侧捕获后用 Dio 发起请求，结果写入 _javaCache，然后重新执行 JS。
      // 最多重试 10 次，防止无限循环。
      const maxNetworkRetries = 10;
      String? strResult;
      bool isNetworkError = false;

      for (int retry = 0; retry <= maxNetworkRetries; retry++) {
        final evalResult = _jsRuntime!.evaluate(wrappedScript);
        _flushConsoleLogs();

        final evalResultStr = evalResult.stringResult;
        AppLogger.instance.logJsStep('QuickJS', '[QuickJS] 执行完成 (retry=$retry)',
          detail: 'isError=${evalResult.isError}, resultLen=${evalResultStr.length}');

        // 检查是否是网络标记
        if (evalResult.isError && evalResultStr.startsWith('__NEED_NETWORK__:')) {
          isNetworkError = true;
          try {
            final jsonStr = evalResultStr.substring('__NEED_NETWORK__:'.length);
            final request = jsonDecode(jsonStr) as Map<String, dynamic>;
            final method = request['method'] as String? ?? 'GET';
            final url = request['url'] as String? ?? '';
            final body = request['body'] as String? ?? '';
            final cacheKey = request['cacheKey'] as String? ?? '';
            final headers = <String, String>{};
            if (request['headers'] is Map) {
              (request['headers'] as Map).forEach((k, v) {
                headers[k.toString()] = v.toString();
              });
            }

            AppLogger.instance.logJsStep('QuickJS', '[网络标记] 捕获网络请求',
              detail: 'method=$method, url=$url, retry=$retry');

            // 使用 PlatformBridge (Dio) 发起 HTTP 请求
            String? responseBody;
            if (method == 'GET') {
              responseBody = await PlatformBridge.instance.httpGet(url, headers: headers.isNotEmpty ? headers : null);
            } else if (method == 'POST') {
              responseBody = await PlatformBridge.instance.httpPost(url, body: body, headers: headers.isNotEmpty ? headers : null);
            } else if (method == 'HEAD') {
              final headResult = await PlatformBridge.instance.httpHead(url, headers: headers.isNotEmpty ? headers : null);
              responseBody = headResult != null ? jsonEncode(headResult) : '';
            }

            if (responseBody != null && cacheKey.isNotEmpty) {
              // 将结果写入 _javaCache，JS 重新执行时可直接获取
              final injectScript = '__setCache(${jsonEncode(cacheKey)}, ${jsonEncode(responseBody)});';
              _jsRuntime!.evaluate(injectScript);
              AppLogger.instance.logJsStep('QuickJS', '[网络标记] 结果已注入 _javaCache',
                detail: 'cacheKey=$cacheKey, bodyLen=${responseBody.length}');
            }
            // 继续循环，重新执行 JS
            if (wrappedScript.length > 5000) {
              await Future(() {});
            }
            continue;
          } catch (e) {
            AppLogger.instance.logJsError('QuickJS', '[网络标记] 处理失败: $e');
            // 网络标记处理失败，注入空响应避免卡死
            final cacheKey = evalResultStr;
            try {
              final jsonStr = evalResultStr.substring('__NEED_NETWORK__:'.length);
              final request = jsonDecode(jsonStr) as Map<String, dynamic>;
              final ck = request['cacheKey'] as String? ?? '';
              if (ck.isNotEmpty) {
                _jsRuntime!.evaluate('__setCache(${jsonEncode(ck)}, "");');
              }
            } catch (_) {}
            continue;
          }
        }

        // 非网络标记的正常结果或错误
        if (evalResult.isError) {
          AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
          if (traceNode != null) {
            JsTracer.instance.pop(
              outputPreview: evalResultStr,
              outputType: 'error',
              error: evalResultStr,
            );
          }
          _logCurrentTraceTree();
          return null;
        }

        strResult = evalResult.stringResult;
        if (traceNode != null) {
          JsTracer.instance.pop(
            outputPreview: strResult,
            outputType: 'String',
          );
        }
        AppLogger.instance.logJsOutput('QuickJS', strResult, outputType: 'String', tag: 'async');
        _logCurrentTraceTree();
        if (strResult == 'undefined') return '';
        if (strResult == 'null') return null;
        return strResult;
      }

      // 达到最大重试次数
      AppLogger.instance.warn(LogCategory.js, '网络标记协议达到最大重试次数 ($maxNetworkRetries)',
          detail: '可能存在循环网络请求');
      if (traceNode != null) {
        JsTracer.instance.pop(
          outputPreview: strResult ?? '',
          outputType: isNetworkError ? 'network_limit' : 'String',
          error: isNetworkError ? 'max_network_retries' : null,
        );
      }
      _logCurrentTraceTree();
      return strResult;
    } catch (e) {
      AppLogger.instance.logJsError('QuickJS', e.toString());
      // 追踪树：记录异常
      if (traceNode != null) {
        JsTracer.instance.pop(
          outputType: 'exception',
          error: e.toString(),
        );
      }
      // 异常时也输出执行树
      _logCurrentTraceTree();
      // 即使异常也尝试提取 console 日志
      _flushConsoleLogs();
      return null;
    }
  }

  /// 输出当前 JsTracer 执行树到日志（info 级别）
  /// 当栈为空时（根节点已 pop）才输出整棵树，避免中途输出碎片
  void _logCurrentTraceTree() {
    if (!JsTracer.instance.enabled) return;
    // 仅当追踪栈为空时输出整棵树（说明根节点已完成）
    if (!JsTracer.instance.isStackEmpty) return;
    final treeStr = JsTracer.instance.getTreeString();
    AppLogger.instance.logJsTree('QuickJS', treeStr);
  }

  /// 提取 QuickJS 中 console 缓存的日志，同步到 AppLogger
  /// 借鉴 legado 的调试输出机制：JS 中的 console.log/warn/error 输出到调试页面
  /// 优化：合并为单次 evaluate，Release 模式跳过
  ///
  /// 关键设计：直接调用 _jsRuntime!.evaluate，**不走 evaluate() 包装**。
  /// 原因：本方法常在 processJsRule / batchEvaluate 的 _evalLock 锁内被调用，
  /// 此时 _evalBusy=true，若走 evaluate() 会被 `if (_evalBusy) return null` 拦截，
  /// 导致 console 日志永远无法提取。直接调用 _jsRuntime!.evaluate 可绕过此拦截，
  /// 安全性由 _isFlushingLogs 防递归标志 + 调用方已持锁保证。
  void _flushConsoleLogs() {
    if (!_initialized || _jsRuntime == null) return;
    // Release 模式跳过日志提取（性能优化）
    if (kReleaseMode) return;
    // 防递归：内部调用 evaluate 时不再次触发 _flushConsoleLogs
    if (_isFlushingLogs) return;
    _isFlushingLogs = true;
    try {
      // 调用 console-utils.js 中的 __flushConsoleLogs() 函数
      final evalResult = _jsRuntime!.evaluate('__flushConsoleLogs()');
      final result = evalResult.stringResult;
      if (evalResult.isError) {
        // 诊断日志：提取脚本本身报错（极少见，runtime 异常时可能发生）
        AppLogger.instance.warn(LogCategory.js, 'console 日志提取失败',
            detail: 'evalResult: $result');
        return;
      }
      if (result == 'undefined' || result == '[]' || result.isEmpty) {
        // 诊断日志：console 无输出（用户代码未调用 console.log，或 console 被覆盖但 _getLogs 仍存在）
        // 注意：这里用 info 级别，确保在日志 tab 默认级别下可见
        AppLogger.instance.info(LogCategory.js, 'console 无日志输出（_consoleLogs 为空）');
        return;
      }
      if (result == 'NEED_REINJECT') {
        // 诊断日志：console 被用户代码覆盖（如 eval(result) 里有 console = {...}）
        // 此时原有 console.log 日志已丢失，无法恢复，只能重新注入供下次使用
        AppLogger.instance.warn(LogCategory.js, 'console 被用户代码覆盖，重新注入',
            detail: '用户 JS 中的 eval(result) 或直接赋值覆盖了 globalThis.console，'
                '覆盖前的 console.log 输出已丢失');
        // 重新注入 console（直接调用 _jsRuntime，避免 _evalBusy 拦截）
        _jsRuntime!.evaluate('__reinjectConsole()');
        return;
      }
      if (!result.startsWith('[')) return;
      final logs = jsonDecode(result) as List;
      if (logs.isNotEmpty) {
        // 诊断日志：记录提取到的日志数量，便于排查 console.log 没输出的问题
        AppLogger.instance.debug(LogCategory.js, 'console 提取到 ${logs.length} 条日志');
      }
      for (final log in logs) {
        if (log is! Map) continue;
        final level = log['level'] as String? ?? 'log';
        final msg = log['msg']?.toString() ?? '';
        if (msg.isEmpty) continue;
        // 加 [JS] 前缀标记，调试页面可据此将 JS 打印指令注入调试 tab
        final taggedMsg = '[JS] $msg';
        switch (level) {
          case 'error':
            AppLogger.instance.error(LogCategory.js, taggedMsg);
            break;
          case 'warn':
            AppLogger.instance.warn(LogCategory.js, taggedMsg);
            break;
          case 'info':
            AppLogger.instance.info(LogCategory.js, taggedMsg);
            break;
          case 'debug':
            AppLogger.instance.debug(LogCategory.js, taggedMsg);
            break;
          default:
            AppLogger.instance.info(LogCategory.js, taggedMsg);
        }
      }
    } catch (e) {
      // 诊断日志：提取过程异常（如 runtime 被销毁、JSON 解析失败等）
      AppLogger.instance.warn(LogCategory.js, 'console 日志提取异常',
          detail: e.toString());
    } finally {
      _isFlushingLogs = false;
    }
  }

  /// 诊断用：提取 console 日志（不受 Release 模式限制）
  /// 仅在 JS 返回 null/空值时调用，帮助定位根因
  /// 返回 console 日志的 JSON 字符串（如 '[{"level":"error","msg":"..."}]'），
  /// 如果无日志或提取失败返回空字符串
  String _extractConsoleLogsForDiagnosis() {
    if (!_initialized || _jsRuntime == null) return '';
    if (_isFlushingLogs) return '';
    _isFlushingLogs = true;
    try {
      final evalResult = _jsRuntime!.evaluate('__flushConsoleLogs()');
      if (evalResult.isError) return '';
      final result = evalResult.stringResult;
      if (result.isEmpty || result == 'undefined' || result == '[]' || result == 'NEED_REINJECT') {
        return '';
      }
      return result;
    } catch (_) {
      return '';
    } finally {
      _isFlushingLogs = false;
    }
  }

  // ===== 序列化工具方法 =====

  /// 序列化 content：List/Map 用 jsonEncode，String 直接用，其他 toString
  static String serializeContent(dynamic content) {
    if (content is List || content is Map) {
      return jsonEncode(content);
    } else if (content is String) {
      return content;
    } else {
      return content?.toString() ?? '';
    }
  }

  /// 序列化 content 为 JSON 字符串（用于嵌入 JS 脚本）
  static String serializeForJs(dynamic content) {
    if (content is List || content is Map) {
      // Uint8List → C 原生 decodeToBytes（返回 Uint8Array），匹配 Legado ByteArray 契约
      // 用 base64 注入而非数字字面量，避免大图片（几百 KB）生成几 MB 的
      // `new Uint8Array([1,2,3,...])` 字面量导致 QuickJS 解析失败/超时
      if (content is Uint8List) {
        final b64 = base64Encode(content);
        // new Uint8Array(...) 包裹：decodeToBytes 返回 ArrayBuffer（无 .length/不可索引），
        // Uint8Array 才有 .length 和索引访问，匹配 JS 解密规则对 result 的操作
        return "new Uint8Array(__nativeBase64.decodeToBytes('$b64'))";
      }
      return jsonEncode(content);
    } else if (content is String) {
      return jsonEncode(content);
    } else {
      return jsonEncode(content?.toString() ?? '');
    }
  }

  // ===== 工具方法 =====

  Future<String?> regexReplace(String text, String pattern, String replacement) async {
    if (!_initialized || _jsRuntime == null) return null;
    try {
      final script = '__regexReplace(${jsonEncode(text)}, ${jsonEncode(pattern)}, ${jsonEncode(replacement)})';
      // 先 yield 让出事件循环
      await Future(() {});
      final evalResult = _jsRuntime!.evaluate(script);
      if (evalResult.isError) return null;
      return evalResult.stringResult;
    } catch (e) {
      return null;
    }
  }

  /// cssSelect（异步，每次调用前 yield）
  Future<String?> cssSelect(String html, String selector) async {
    if (!_initialized || _jsRuntime == null) return null;
    try {
      final script = '__cssSelect(${jsonEncode(html)}, ${jsonEncode(selector)})';
      // 先 yield 让出事件循环
      await Future(() {});
      final evalResult = _jsRuntime!.evaluate(script);
      if (evalResult.isError) return null;
      return evalResult.stringResult;
    } catch (e) {
      return null;
    }
  }

  Future<String?> xpathSelect(String html, String xpath) async {
    return null;
  }

  Future<dynamic> jsonPath(String jsonStr, String path) async {
    if (!_initialized || _jsRuntime == null) return null;
    try {
      final script = '__jsonPath(${jsonEncode(jsonStr)}, ${jsonEncode(path)})';
      // 先 yield 让出事件循环
      await Future(() {});
      final evalResult = _jsRuntime!.evaluate(script);
      if (evalResult.isError) return null;
      return evalResult.stringResult;
    } catch (e) {
      return null;
    }
  }

  dynamic _parseJsResult(String result) {
    // undefined → 返回空字符串（而不是 null，避免书源规则误判）
    if (result == 'undefined') return '';
    if (result == 'null') return null;
    if (result == 'true') return true;
    if (result == 'false') return false;
    final numVal = num.tryParse(result);
    if (numVal != null) return numVal;
    // 快速判断：只有可能是 JSON 时才尝试 jsonDecode
    if (result.startsWith('{') || result.startsWith('[') || result.startsWith('"')) {
      try {
        return jsonDecode(result);
      } catch (_) {}
    }
    return result;
  }

  // ===== 共享作用域管理（借鉴 legado SharedJsScope）=====

  /// 加载书源的 jsLib 并创建共享作用域
  /// 借鉴 legado 的 BaseSource.getShareScope() + SharedJsScope.getScope()
  /// 加载书源 jsLib（借鉴 legado 的 SharedJsScope + getShareScope 机制）
  ///
  /// legado 的做法：
  /// 1. SharedJsScope.getScope(jsLib) 把 jsLib eval 到一个独立的 scope 对象中
  /// 2. evalJS 时 bindings.prototype = sharedScope，通过原型链访问 jsLib 函数
  /// 3. 同一书源的 jsLib 只加载一次（LRU 缓存），切换书源时用新的 scope
  ///
  /// QuickJS 的等价实现：
  /// 1. 把 jsLib eval 到 globalThis 上（等价于 legado 的 eval(jsLib, scope)）
  /// 2. 同一书源只加载一次，切换书源时先清除旧的全局函数
  /// 3. 用 _currentJsLibSourceUrl 追踪当前加载了哪个书源的 jsLib
  void loadJsLib(String sourceUrl, String jsLib) {
    if (jsLib.trim().isEmpty) {
      AppLogger.instance.warn(LogCategory.js,
          '[loadJsLib] jsLib 为空，跳过加载: $sourceUrl');
      return;
    }

    AppLogger.instance.info(LogCategory.js,
        '[loadJsLib] 开始加载: $sourceUrl, jsLib长度=${jsLib.length}');

    // 缓存 jsLib 代码
    _jsLibCache[sourceUrl] = jsLib;

    // 如果当前已加载的就是同一个书源，不需要重新加载
    if (_currentJsLibSourceUrl == sourceUrl) {
      AppLogger.instance.info(LogCategory.js,
          '[loadJsLib] 同一书源，跳过加载: $sourceUrl');
      return;
    }

    // 切换书源：先清除旧的 jsLib 全局函数
    _clearCurrentJsLib();

    // 「全局属性 diff」方案：记录 jsLib 加载前后的全局属性差异
    // 原因：jsvmp 混淆代码不用 function/var 声明，正则提取函数名完全失效，
    //       导致切换书源时旧 jsvmp 全局函数（如 decode）不会被清理，
    //       新书源调用 decode 时实际执行的是旧书源的残留函数 → 返回 null
    String? beforeProps;
    if (_jsRuntime != null) {
      try {
        final r = _jsRuntime!.evaluate(
          'JSON.stringify(Object.getOwnPropertyNames(globalThis))'
        );
        beforeProps = r.stringResult;
      } catch (_) {}
    }

    // 把 jsLib eval 到全局作用域（等价于 legado 的 RhinoScriptEngine.eval(jsLib, scope)）
    // [Bug 修复] evaluate() 返回 JsEvalResult 不抛异常，必须检查 isError 字段
    // 否则 jsLib 有语法错误时会被静默吞掉，search 等函数不会被定义到全局
    try {
      final evalResult = _jsRuntime?.evaluate(jsLib);
      if (evalResult != null && evalResult.isError) {
        final preview = jsLib.length > 200 ? '${jsLib.substring(0, 200)}...' : jsLib;
        AppLogger.instance.error(LogCategory.js,
            '[loadJsLib] jsLib 加载失败: $sourceUrl',
            detail: '错误: ${evalResult.stringResult}\n  jsLib预览: $preview');
        return;
      }
      _currentJsLibSourceUrl = sourceUrl;
      AppLogger.instance.info(LogCategory.js,
          '[loadJsLib] eval 成功: $sourceUrl');
    } catch (e) {
      final preview = jsLib.length > 200 ? '${jsLib.substring(0, 200)}...' : jsLib;
      AppLogger.instance.error(LogCategory.js,
          '[loadJsLib] jsLib 加载失败: $sourceUrl',
          detail: '错误: $e\n  jsLib预览: $preview');
      return;
    }

    // 计算新创建的全局属性（jsLib 的产物），存入 _currentJsLibFunctions 供下次切换时清理
    if (_jsRuntime != null && beforeProps != null) {
      try {
        final afterR = _jsRuntime!.evaluate(
          'JSON.stringify(Object.getOwnPropertyNames(globalThis))'
        );
        final afterProps = afterR.stringResult;
        _computeNewGlobals(beforeProps, afterProps);
        AppLogger.instance.info(LogCategory.js,
            '[loadJsLib] 新增全局函数: ${_currentJsLibFunctions.length}个: ${_currentJsLibFunctions.take(10).join(", ")}');
      } catch (_) {}
    }

    // 验证 search 函数是否在全局（undefined 时输出 warn 级别，调试页面可见）
    if (_jsRuntime != null) {
      try {
        final r = _jsRuntime!.evaluate('typeof search');
        final searchType = r.stringResult;
        if (searchType == 'undefined') {
          // search 未定义：可能是 jsLib 有语法错误，或 search 函数被包裹在 IIFE 中
          AppLogger.instance.warn(LogCategory.js,
              '[loadJsLib] ⚠️ search 函数未定义！jsLib 可能加载失败或语法错误: $sourceUrl');
        } else {
          AppLogger.instance.info(LogCategory.js,
              '[loadJsLib] 验证: typeof search = $searchType');
        }
      } catch (_) {}
    }
  }

  /// 从 before/after 全局属性 JSON 列表计算 jsLib 新创建的全局属性
  void _computeNewGlobals(String beforeJson, String afterJson) {
    _currentJsLibFunctions.clear();
    try {
      final before = (jsonDecode(beforeJson) as List).cast<String>();
      final after = (jsonDecode(afterJson) as List).cast<String>();
      final beforeSet = before.toSet();
      for (final prop in after) {
        if (!beforeSet.contains(prop)) {
          _currentJsLibFunctions.add(prop);
        }
      }
    } catch (_) {}
  }

  /// 清除当前已加载的 jsLib 全局函数
  /// 借鉴 legado 的 scope 切换机制：切换书源时清除旧的 scope
  void _clearCurrentJsLib() {
    if (_currentJsLibFunctions.isEmpty || _jsRuntime == null) return;
    try {
      final deleteCode = _currentJsLibFunctions.map((fn) => 'try{delete globalThis.$fn}catch(e){}').join(';');
      _jsRuntime!.evaluate(deleteCode);
    } catch (_) {}
    _currentJsLibFunctions.clear();
    _currentJsLibSourceUrl = null;
  }

  /// 获取书源的 jsLib 代码
  String? getJsLib(String sourceUrl) => _jsLibCache[sourceUrl];

  /// 清除书源的 jsLib 缓存
  void clearJsLib(String sourceUrl) {
    _jsLibCache.remove(sourceUrl);
  }

  /// 清除 JS 侧 _javaCache（桥接预缓存结果）
  /// 防止调试多个书源/规则时 _javaCache 无限膨胀导致 QuickJS 堆 OOM
  void clearJavaCache() {
    if (_jsRuntime == null || !_initialized) return;
    if (!_nativeLibChecked) return; // native lib 未就绪 → 跳过，不崩溃
    try {
      evaluate('__clearCache()');
      _cachedKeys.clear();
      _bridgeCache.clear();
    } catch (e) {
      debugPrint('清除 _javaCache 失败: $e');
    }
  }

  Future<void> loadSharedScope(String sourceUrl, String? jsLib) async {
    if (jsLib == null || jsLib.trim().isEmpty) return;
    if (_sharedScopeVars.containsKey(sourceUrl)) return;

    final scopeVars = await SharedJsScope.instance.createScope(
      jsLib,
      (code) => evaluate(code),
    );
    _sharedScopeVars[sourceUrl] = scopeVars;
  }

  /// 获取书源的共享作用域变量
  Map<String, String>? getSharedScope(String sourceUrl) {
    return _sharedScopeVars[sourceUrl];
  }

  /// 清除书源的共享作用域
  void clearSharedScope(String sourceUrl) {
    _sharedScopeVars.remove(sourceUrl);
  }

  /// 预缓存桥接结果（用于同步模式的 java.ajax 等）
  /// 借鉴 legado 的 CacheManager 机制
  Future<void> preCacheBridgeResult(String method, String url, String result) async {
    final cacheKey = '${method}:${url}';
    final script = '__setCache(${jsonEncode(cacheKey)}, ${jsonEncode(result)});';
    evaluate(script);
    _cachedKeys.add(cacheKey);
  }

  /// 批量预缓存 HTTP 结果（在 processJsRule 前调用）
  /// 解决 QuickJS 同步模式下 java.ajax() 无法异步请求的问题
  Future<void> preCacheHttpResults(Map<String, String> urlResults) async {
    final entries = urlResults.entries.map((e) {
      _cachedKeys.add(e.key);
      return '__setCache(${jsonEncode(e.key)}, ${jsonEncode(e.value)});';
    }).join('\n');
    if (entries.isNotEmpty) {
      evaluate(entries);
    }
  }

  /// 批量预缓存加密结果
  Future<void> preCacheCryptoResults(Map<String, String> cryptoResults) async {
    final entries = cryptoResults.entries.map((e) {
      _cachedKeys.add(e.key);
      return '__setCache(${jsonEncode(e.key)}, ${jsonEncode(e.value)});';
    }).join('\n');
    if (entries.isNotEmpty) {
      evaluate(entries);
    }
  }

  /// 预缓存桥接调用（核心方法）
  /// 在执行 JS 代码前，扫描代码中的 java.ajax/get/post/aesEncode/md5Encode 等调用
  /// 通过 NativeChannel 预获取结果，写入 _javaCache
  /// 借鉴 legado 的 preCacheHttpResults 机制，但自动扫描而非手动传入
  /// 优化：快速预检，无桥接调用时直接跳过
  static final _bridgeCallPattern = RegExp(
    r'\bjava\.(ajax|get|post|head|connect|aesEncode|aesDecode|md5Encode|sha1Encode|sha256Encode|hmacSHA256|base64Encode|base64Decode|webView|webViewGetSource|webViewGetOverrideUrl|startBrowserAwait|getVerificationCode|downloadFile|cacheFile|readFile|readTxtFile|writeFile|deleteFile|getTxtInFolder|importScript|unzipFile|un7zFile|unrarFile|unArchiveFile|getZipStringContent|getRarStringContent|get7zStringContent|startBrowser|openUrl|openVideoPlayer|getWebViewUA|androidId|randomUUID)\b|\bCryptoJS\b|\bfetch\s*\(',
  );

  /// 扫描 java.webView/getSource/getOverrideUrl 调用，提取字面量参数
  /// 参数顺序：webView(html, url, js, cacheFirst), webViewGetSource(html, url, js, sourceRegex, ...), webViewGetOverrideUrl(html, url, js, overrideUrlRegex, ...)
  /// startBrowserAwait(url, title, ...), getVerificationCode(imageUrl)
  static final _webViewCallPattern = RegExp(
    r"""java\.(webView|webViewGetSource|webViewGetOverrideUrl|startBrowserAwait|getVerificationCode)\s*\(\s*([^)]*)\)""",
    multiLine: true,
  );

  /// 扫描 java.downloadFile/cacheFile 调用，提取 URL 字面量
  static final _downloadCallPattern = RegExp(
    r"""java\.(downloadFile|cacheFile)\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );

  /// 扫描文件操作调用：readFile/readTxtFile/writeFile/deleteFile/getTxtInFolder/importScript
  /// 参数为字面量路径
  static final _fileCallPattern = RegExp(
    r"""java\.(readFile|readTxtFile|writeFile|deleteFile|getTxtInFolder|importScript)\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );

  /// 扫描压缩包操作：unzipFile/un7zFile/unrarFile/unArchiveFile(path, [password])
  /// getZipStringContent/getRarStringContent/get7zStringContent(url, path, [charset], [password])
  static final _archiveCallPattern = RegExp(
    r"""java\.(unzipFile|un7zFile|unrarFile|unArchiveFile|getZipStringContent|getRarStringContent|get7zStringContent)\s*\(\s*([^)]*)\)""",
    multiLine: true,
  );

  /// 扫描 URL 启动调用：startBrowser/openUrl/openVideoPlayer/getWebViewUA
  static final _urlLaunchPattern = RegExp(
    r"""java\.(startBrowser|openUrl|openVideoPlayer)\s*\(\s*["']([^"']+)["']""",
    multiLine: true,
  );

  Future<void> _preCacheBridgeCalls(String jsCode, {Map<String, dynamic>? env}) async {
    if (_jsRuntime == null) return;
    // 快速预检：无桥接调用时直接跳过，避免不必要的正则扫描
    if (!_bridgeCallPattern.hasMatch(jsCode)) return;

    final baseUrl = env?['baseUrl'] as String? ?? '';
    final httpUrls = <String>{};

    // 0. 预缓存设备信息 & WebView UA & 配置（同步可计算，直接写入 _javaCache）
    try {
      final deviceInfo = await NativeChannel.instance.getDeviceInfo();
      if (deviceInfo != null) {
        await preCacheHttpResults({
          'webview_ua': _defaultWebViewUA(deviceInfo),
          'device_info': jsonEncode(deviceInfo),
        });
      } else {
        await preCacheHttpResults({
          'webview_ua': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        });
      }
    } catch (_) {}

    // 1. 扫描字面量 URL: java.ajax("url"), java.get("url"), java.post("url"), fetch("url")
    for (final match in _literalPattern.allMatches(jsCode)) {
      final url = match.group(1);
      if (url != null && url.isNotEmpty) {
        // 处理模板变量 {{key}}, {{page}} 等
        var resolvedUrl = url;
        if (env != null) {
          resolvedUrl = _resolveTemplateVars(url, env);
        }
        final absoluteUrl = _resolveUrl(resolvedUrl, baseUrl);
        if (absoluteUrl.isNotEmpty && absoluteUrl.startsWith('http')) {
          httpUrls.add(absoluteUrl);
        }
      }
    }

    // 1.5 [legado URL 选项兼容] 扫描 java.ajax("url,{\"method\":\"POST\",...}") 等调用
    // 解析 URL 选项，按 method 分类预缓存（GET 加入 httpUrls，POST 单独预缓存）
    final urlOptionPostEntries = <String, String>{}; // url -> body
    final urlOptionPostHeaders = <String, Map<String, String>>{}; // url -> headers
    final urlOptionGetUrls = <String>{}; // 额外的 GET URL
    final urlOptionGetHeaders = <String, Map<String, String>>{}; // url -> headers
    for (final match in _urlOptionCallPattern.allMatches(jsCode)) {
      final quote = match.group(1) ?? '"';
      final rawStr = match.group(2) ?? '';
      if (rawStr.isEmpty || !rawStr.contains(',{')) continue;
      // 反转义字符串（处理 \" \' \\ 等）
      final unescaped = _unescapeJsString(rawStr, quote);
      // 处理模板变量 {{key}}, {{page}} 等
      var resolvedStr = unescaped;
      if (env != null) {
        resolvedStr = _resolveTemplateVars(unescaped, env);
      }
      // 用 AnalyzeUrl 解析 URL 选项
      try {
        final parsed = legado_url.AnalyzeUrl.parse(resolvedStr, baseUrl: baseUrl);
        final opt = parsed.option;
        if (opt == null || opt.method == null) continue;
        final method = opt.method!.toUpperCase();
        final absoluteUrl = parsed.url;
        if (absoluteUrl.isEmpty || !absoluteUrl.startsWith('http')) continue;

        if (method == 'POST') {
          final body = opt.body ?? '';
          urlOptionPostEntries[absoluteUrl] = body;
          if (opt.headers != null && opt.headers!.isNotEmpty) {
            urlOptionPostHeaders[absoluteUrl] = opt.headers!;
          }
        } else if (method == 'HEAD') {
          // HEAD 请求由后续 _headPattern 处理，这里跳过
        } else {
          // GET / PUT / DELETE 默认走 GET 缓存
          urlOptionGetUrls.add(absoluteUrl);
          if (opt.headers != null && opt.headers!.isNotEmpty) {
            urlOptionGetHeaders[absoluteUrl] = opt.headers!;
          }
        }
      } catch (_) {}
    }
    // URL 选项的 GET URL 加入 httpUrls 统一预缓存
    httpUrls.addAll(urlOptionGetUrls);

    // 2. 扫描变量拼接 URL: java.ajax(url), java.get(baseUrl + "/api"), fetch(variable)
    // 优化：合并所有变量表达式为单次 evaluate，避免逐个求值
    final varExprs = <String>[];
    for (final match in _varPattern.allMatches(jsCode)) {
      final expr = match.group(1)?.trim();
      if (expr == null || expr.isEmpty) continue;
      // 跳过字面量字符串（已被上面匹配）
      if (expr.startsWith('"') || expr.startsWith("'")) continue;
      varExprs.add(expr);
    }
    if (varExprs.isNotEmpty) {
      try {
        final varCode = <String>[];
        if (env != null) {
          for (final entry in env.entries) {
            if (entry.value is String) {
              varCode.add('var ${entry.key} = ${jsonEncode(entry.value)};');
            } else if (entry.value is num || entry.value is bool) {
              varCode.add('var ${entry.key} = ${entry.value};');
            }
          }
        }
        // 合并所有表达式为单次 evaluate，批量返回结果
        final exprJsonArr = jsonEncode(varExprs);
        final varCodeJsonArr = jsonEncode(varCode);
        final batchResult = evaluate('__batchEvalUrls($varCodeJsonArr, $exprJsonArr)');
        if (batchResult != null && batchResult.startsWith('[')) {
          try {
            final urls = jsonDecode(batchResult) as List;
            for (final url in urls) {
              if (url is String && url.isNotEmpty) httpUrls.add(url);
            }
          } catch (_) {}
        }
      } catch (_) {
        // 批量求值失败，跳过
      }
    }

    // 3. 扫描 URL 模板变量: fetch(`https://xxx/${key}`), java.ajax(`${baseUrl}/api`)
    for (final match in _templatePattern.allMatches(jsCode)) {
      var template = match.group(1);
      if (template == null) continue;
      // 替换 ${var} 为 env 中的值
      if (env != null) {
        template = template.replaceAllMapped(
          _templateVarPattern,
          (m) {
            final varName = m.group(1)?.trim() ?? '';
            final val = env[varName];
            if (val != null) return val.toString();
            // 尝试点号路径: source.bookSourceUrl
            final parts = varName.split('.');
            dynamic current = env;
            for (final part in parts) {
              if (current is Map) {
                current = current[part];
              } else {
                current = null;
                break;
              }
            }
            return current?.toString() ?? '';
          },
        );
      }
      final absoluteUrl = _resolveUrl(template, baseUrl);
      if (absoluteUrl.isNotEmpty && absoluteUrl.startsWith('http')) {
        httpUrls.add(absoluteUrl);
      }
    }

    // 4. 并发预缓存 HTTP 结果
    if (httpUrls.isNotEmpty) {
      AppLogger.instance.debug(LogCategory.js, '预缓存 ${httpUrls.length} 个HTTP请求');
      // 从 env 中获取自定义 headers（书源配置的 header 字段）
      final customHeaders = env?['headers'] as Map<String, String>?;
      final results = await _runWithConcurrency(() => httpUrls.map((url) async {
        try {
          // [legado URL 选项兼容] 合并 URL 选项 GET 请求的专属 headers
          // 修复：之前 GET 预缓存只用了 customHeaders，丢弃了 urlOptionGetHeaders
          // 导致 java.ajax("url,{\"headers\":{\"Referer\":\"...\"}}") 的 Referer 未传递
          final optHeaders = urlOptionGetHeaders[url];
          final mergedHeaders = <String, String>{};
          if (customHeaders != null) mergedHeaders.addAll(customHeaders);
          if (optHeaders != null) mergedHeaders.addAll(optHeaders);
          final effectiveHeaders = mergedHeaders.isNotEmpty ? mergedHeaders : null;

          // 网络请求统一走 PlatformBridge (Dio)，支持 HTTP/HTTPS
          final result = await PlatformBridge.instance.httpGet(url, headers: effectiveHeaders);
          if (result != null) {
            return MapEntry('http_get:$url', result);
          }
        } catch (e) {
          AppLogger.instance.warn(LogCategory.js, '预缓存HTTP失败: $url', detail: e.toString());
        }
        return null;
      }));
      final cacheEntries = <String, String>{};
      for (final entry in results) {
        if (entry != null) {
          cacheEntries[entry.key] = entry.value;
        }
      }
      if (cacheEntries.isNotEmpty) {
        await preCacheHttpResults(cacheEntries);
      }
    }

    // 5. 扫描 java.aesEncode/aesDecode 调用（已有纯 JS _AES 引擎，不再需要预缓存）
    // 6. 并发执行所有加密预缓存
    final cryptoResults = <String, String>{};
    await Future.wait([
      Future(() async {
        for (final match in _md5Pattern.allMatches(jsCode)) {
          final str = match.group(1);
          if (str != null) {
            final cacheKey = 'md5:$str';
            if (!_isCached(cacheKey)) {
              final result = nativeMd5(str);
              cryptoResults[cacheKey] = result;
            }
          }
        }
      }),
      Future(() async {
        for (final match in _sha1Pattern.allMatches(jsCode)) {
          final str = match.group(1);
          if (str != null) {
            final cacheKey = 'sha1:$str';
            if (!_isCached(cacheKey)) {
              final result = nativeSha1(str);
              if (result.isNotEmpty) cryptoResults[cacheKey] = result;
            }
          }
        }
      }),
      Future(() async {
        for (final match in _sha256Pattern.allMatches(jsCode)) {
          final str = match.group(1);
          if (str != null) {
            final cacheKey = 'sha256:$str';
            if (!_isCached(cacheKey)) {
              try {
                final result = nativeSha256(str);
                if (result.isNotEmpty) cryptoResults[cacheKey] = result;
              } catch (_) {}
            }
          }
        }
      }),
      Future(() async {
        for (final match in _hmacPattern.allMatches(jsCode)) {
          final data = match.group(1);
          final key = match.group(2);
          if (data != null && key != null) {
            final cacheKey = 'hmac_sha256:$data:$key';
            if (!_isCached(cacheKey)) {
              try {
                final result = nativeHmacSha256(data, key);
                if (result.isNotEmpty) cryptoResults[cacheKey] = result;
              } catch (_) {}
            }
          }
        }
      }),
    ]);

    if (cryptoResults.isNotEmpty) {
      await preCacheCryptoResults(cryptoResults);
    }

    // 6.4-6.6 并发执行 HTTP/POST/HEAD/Cookie 预缓存
    await Future.wait([
      Future(() async {
        // POST 请求预缓存
        final postUrls = <String, String>{}; // url -> body
        for (final match in _postPattern.allMatches(jsCode)) {
          final url = match.group(1);
          final body = match.group(2) ?? '';
          if (url != null && url.isNotEmpty) {
            var resolvedUrl = url;
            if (env != null) {
              resolvedUrl = _resolveTemplateVars(url, env);
            }
            final absoluteUrl = _resolveUrl(resolvedUrl, baseUrl);
            if (absoluteUrl.isNotEmpty && absoluteUrl.startsWith('http')) {
              postUrls[absoluteUrl] = body;
            }
          }
        }
        // [legado URL 选项兼容] 合并 URL 选项 POST 请求
        postUrls.addAll(urlOptionPostEntries);

        if (postUrls.isNotEmpty) {
          final customHeaders = env?['headers'] as Map<String, String>?;
          final postResults = await _runWithConcurrency(() => postUrls.entries.map((entry) async {
            try {
              // URL 选项 POST 请求可能有专属 headers
              final optHeaders = urlOptionPostHeaders[entry.key];
              final mergedHeaders = <String, String>{};
              if (customHeaders != null) mergedHeaders.addAll(customHeaders);
              if (optHeaders != null) mergedHeaders.addAll(optHeaders);
              final effectiveHeaders = mergedHeaders.isNotEmpty ? mergedHeaders : null;

              // 网络请求统一走 PlatformBridge (Dio)，支持 HTTP/HTTPS
              final result = await PlatformBridge.instance.httpPost(
                entry.key,
                body: entry.value,
                headers: effectiveHeaders,
              );
              if (result != null) {
                return MapEntry('http_post:${entry.key}', result);
              }
            } catch (e) {
              AppLogger.instance.warn(LogCategory.js, '预缓存POST失败: ${entry.key}', detail: e.toString());
            }
            return null;
          }));
          final postCacheEntries = <String, String>{};
          for (final entry in postResults) {
            if (entry != null) postCacheEntries[entry.key] = entry.value;
          }
          if (postCacheEntries.isNotEmpty) {
            await preCacheHttpResults(postCacheEntries);
          }
        }
      }),
      Future(() async {
        // HEAD 请求预缓存
        final headUrls = <String>{};
        for (final match in _headPattern.allMatches(jsCode)) {
          final url = match.group(1);
          if (url != null && url.isNotEmpty) {
            var resolvedUrl = url;
            if (env != null) {
              resolvedUrl = _resolveTemplateVars(url, env);
            }
            final absoluteUrl = _resolveUrl(resolvedUrl, baseUrl);
            if (absoluteUrl.isNotEmpty && absoluteUrl.startsWith('http')) {
              headUrls.add(absoluteUrl);
            }
          }
        }
        if (headUrls.isNotEmpty) {
          final customHeaders = env?['headers'] as Map<String, String>?;
          final headResults = await _runWithConcurrency(() => headUrls.map((url) async {
            try {
              final result = await PlatformBridge.instance.httpHead(url, headers: customHeaders);
              if (result != null) {
                // HEAD 请求返回 headers map，序列化为 JSON 字符串缓存
                return MapEntry('http_head:$url', jsonEncode(result));
              }
            } catch (e) {
              AppLogger.instance.warn(LogCategory.js, '预缓存HEAD失败: $url', detail: e.toString());
            }
            return null;
          }));
          final headCacheEntries = <String, String>{};
          for (final entry in headResults) {
            if (entry != null) headCacheEntries[entry.key] = entry.value;
          }
          if (headCacheEntries.isNotEmpty) {
            await preCacheHttpResults(headCacheEntries);
          }
        }
      }),
      Future(() async {
        // Cookie 预缓存
        final cookieUrls = <String>{};
        for (final match in _cookiePattern.allMatches(jsCode)) {
          final tag = match.group(1);
          if (tag != null && tag.isNotEmpty) {
            cookieUrls.add(tag);
          }
        }
        if (cookieUrls.isNotEmpty) {
          final cookieResults = await _runWithConcurrency(() => cookieUrls.map((tag) async {
            try {
              final result = await NativeChannel.instance.getCookie(tag);
              if (result != null) {
                return MapEntry('cookie:$tag', result);
              }
            } catch (e) {
              AppLogger.instance.warn(LogCategory.js, '预缓存Cookie失败: $tag', detail: e.toString());
            }
            return null;
          }));
          final cookieCacheEntries = <String, String>{};
          for (final entry in cookieResults) {
            if (entry != null) cookieCacheEntries[entry.key] = entry.value;
          }
          if (cookieCacheEntries.isNotEmpty) {
            await preCacheHttpResults(cookieCacheEntries);
          }
        }
      }),
    ]);

    // 6.5 预缓存 WebView 调用（接入 NativeChannel.executeWebViewJs）
    // 扫描 java.webView/webViewGetSource/webViewGetOverrideUrl/startBrowserAwait/getVerificationCode
    final webViewFutures = <Future<MapEntry<String, String>?>>[];
    for (final match in _webViewCallPattern.allMatches(jsCode)) {
      final method = match.group(1)!;
      final argsStr = match.group(2) ?? '';
      // 简单参数分割（不支持嵌套括号，但 Legado 书源基本是字面量）
      final args = _splitArgs(argsStr);
      if (args.isEmpty) continue;

      // 各方法对应不同的缓存 key
      String cacheKey;
      String? url, jsCode, sourceRegex, overrideRegex, html, imageUrl;
      switch (method) {
        case 'webView':
          // webView(html, url, js, cacheFirst)
          if (args.length < 2) continue;
          html = _stripQuotes(args[0]);
          url = _stripQuotes(args[1]);
          jsCode = args.length >= 3 ? _stripQuotes(args[2]) : '';
          cacheKey = 'webview:${url ?? ''}:${(html ?? '').length}';
          break;
        case 'webViewGetSource':
          // webViewGetSource(html, url, js, sourceRegex, cacheFirst, delayTime)
          if (args.length < 4) continue;
          html = _stripQuotes(args[0]);
          url = _stripQuotes(args[1]);
          jsCode = _stripQuotes(args[2]);
          sourceRegex = _stripQuotes(args[3]);
          cacheKey = 'webview_src:${url ?? ''}:${sourceRegex ?? ''}';
          break;
        case 'webViewGetOverrideUrl':
          // webViewGetOverrideUrl(html, url, js, overrideUrlRegex, cacheFirst, delayTime)
          if (args.length < 4) continue;
          html = _stripQuotes(args[0]);
          url = _stripQuotes(args[1]);
          jsCode = _stripQuotes(args[2]);
          overrideRegex = _stripQuotes(args[3]);
          cacheKey = 'webview_override:${url ?? ''}:${overrideRegex ?? ''}';
          break;
        case 'startBrowserAwait':
          // startBrowserAwait(url, title, refetchAfterSuccess, html)
          if (args.isEmpty) continue;
          url = _stripQuotes(args[0]);
          cacheKey = 'browser:${url ?? ''}';
          jsCode = ''; // 浏览器等待通常不需要 JS
          break;
        case 'getVerificationCode':
          // getVerificationCode(imageUrl)
          if (args.isEmpty) continue;
          imageUrl = _stripQuotes(args[0]);
          cacheKey = 'captcha:${imageUrl ?? ''}';
          url = imageUrl; // 复用 url 字段
          jsCode = '';
          break;
        default:
          continue;
      }

      if (url == null || url.isEmpty || !url.startsWith('http')) continue;

      webViewFutures.add(() async {
        try {
          final result = await NativeChannel.instance.executeWebViewJs(
            url: url!,
            jsCode: jsCode ?? 'document.documentElement.outerHTML',
            sourceRegex: sourceRegex,
            html: html,
            delayTime: 500, // 默认延迟 500ms 等 WebView 渲染
          );
          if (result != null && result.isNotEmpty) {
            return MapEntry(cacheKey, result);
          }
        } catch (_) {}
        return null;
      }());
    }
    if (webViewFutures.isNotEmpty) {
      final webResults = await Future.wait(webViewFutures);
      final webCacheEntries = <String, String>{};
      for (final entry in webResults) {
        if (entry != null) webCacheEntries[entry.key] = entry.value;
      }
      if (webCacheEntries.isNotEmpty) {
        await preCacheHttpResults(webCacheEntries);
      }
    }

    // 6.6 预缓存下载文件调用（接入 NativeChannel.httpDownload）
    final downloadFutures = <Future<MapEntry<String, String>?>>[];
    for (final match in _downloadCallPattern.allMatches(jsCode)) {
      final method = match.group(1)!;
      final url = match.group(2)!;
      if (!url.startsWith('http')) continue;
      final absoluteUrl = _resolveUrl(url, baseUrl);
      // 缓存 key 同 JS 侧 java.cacheFile/java.downloadFile 用的 key
      final cacheKey = method == 'cacheFile' ? 'cache_file:$absoluteUrl' : 'download_file:$absoluteUrl';
      // 保存路径：用 url md5 作为文件名
      var saveName = nativeMd5(absoluteUrl);
      if (saveName.isEmpty) saveName = absoluteUrl.hashCode.toString();
      final savePath = '/tmp/mr_$saveName';

      downloadFutures.add(() async {
        try {
          final result = await PlatformBridge.instance.httpDownload(absoluteUrl, savePath);
          if (result != null && result.isNotEmpty) {
            return MapEntry(cacheKey, result);
          }
        } catch (_) {}
        return null;
      }());
    }
    if (downloadFutures.isNotEmpty) {
      final dlResults = await Future.wait(downloadFutures);
      final dlCacheEntries = <String, String>{};
      for (final entry in dlResults) {
        if (entry != null) dlCacheEntries[entry.key] = entry.value;
      }
      if (dlCacheEntries.isNotEmpty) {
        await preCacheHttpResults(dlCacheEntries);
      }
    }

    // 6.7-6.9 并行预缓存：文件操作 / 压缩包 / URL 启动（彼此独立，并行执行）
    final parallelFutures = <Future<void>>[];

    // 6.7 预缓存文件操作（接入 dart:io + path_provider）
    // 扫描 java.readFile/readTxtFile/writeFile/deleteFile/getTxtInFolder/importScript
    if (_fileCallPattern.hasMatch(jsCode)) {
      parallelFutures.add(() async {
        final fileCacheEntries = <String, String>{};
        // 获取应用文档目录作为相对路径根
        Directory? docDir;
        try {
          docDir = await getApplicationDocumentsDirectory();
        } catch (_) {}
        final docPath = docDir?.path ?? '/tmp';

        // 每个 match 独立 I/O，并发执行
        final matchFutures = <Future<MapEntry<String, String>?>>[];
        for (final match in _fileCallPattern.allMatches(jsCode)) {
          final method = match.group(1)!;
          final path = match.group(2)!;
          // 解析路径：绝对路径直接用，相对路径相对于 docPath
          final absPath = (path.startsWith('/') ||
                  RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path))
              ? path
              : '$docPath/$path';
          final cacheKey = 'file_$method:$path';

          matchFutures.add(() async {
            try {
              switch (method) {
                case 'readFile':
                case 'readTxtFile':
                  final file = File(absPath);
                  if (await file.exists()) {
                    return MapEntry(cacheKey, await file.readAsString());
                  }
                  break;
                case 'writeFile':
                  // writeFile(path, content) - content 在 JS 端是动态的，这里只标记文件可写
                  final file = File(absPath);
                  await file.create(recursive: true);
                  return MapEntry(cacheKey, 'true');
                case 'deleteFile':
                  final file = File(absPath);
                  if (await file.exists()) {
                    await file.delete();
                    return MapEntry(cacheKey, 'true');
                  }
                  return MapEntry(cacheKey, 'false');
                case 'getTxtInFolder':
                  final dir = Directory(absPath);
                  if (await dir.exists()) {
                    final buffer = StringBuffer();
                    await for (final entity in dir.list()) {
                      if (entity is File &&
                          entity.path.toLowerCase().endsWith('.txt')) {
                        try {
                          buffer.writeln(await entity.readAsString());
                        } catch (_) {}
                      }
                    }
                    return MapEntry(cacheKey, buffer.toString());
                  }
                  break;
                case 'importScript':
                  final file = File(absPath);
                  if (await file.exists()) {
                    return MapEntry(cacheKey, await file.readAsString());
                  }
                  break;
              }
            } catch (_) {}
            return null;
          }());
        }
        final results = await Future.wait(matchFutures);
        for (final entry in results) {
          if (entry != null) fileCacheEntries[entry.key] = entry.value;
        }
        if (fileCacheEntries.isNotEmpty) {
          await preCacheHttpResults(fileCacheEntries);
        }
      }());
    }

    // 6.8 预缓存压缩包操作（接入 archive 包，支持密码）
    // 扫描 java.unzipFile/un7zFile/unrarFile/unArchiveFile/getZipStringContent 等
    if (_archiveCallPattern.hasMatch(jsCode)) {
      parallelFutures.add(() async {
        final archiveCacheEntries = <String, String>{};
        Directory? tempDir;
        try {
          tempDir = await getTemporaryDirectory();
        } catch (_) {}
        final tempPath = tempDir?.path ?? '/tmp';

        // 每个 archive 操作独立，并发执行
        final matchFutures = <Future<MapEntry<String, String>?>>[];
        for (final match in _archiveCallPattern.allMatches(jsCode)) {
          final method = match.group(1)!;
          final argsStr = match.group(2) ?? '';
          final args = _splitArgs(argsStr);
          if (args.isEmpty) continue;

          matchFutures.add(() async {
            // 第一个参数可能是文件路径或 URL
            final firstArg = _stripQuotes(args[0]) ?? args[0];
            // 密码参数（unzipFile/unArchiveFile 的第 2 参数，getZipStringContent 的第 4 参数）
            String? password;
            if (method == 'unzipFile' || method == 'un7zFile' ||
                method == 'unrarFile' || method == 'unArchiveFile') {
              if (args.length >= 2) password = _stripQuotes(args[1]);
            } else if (method.contains('StringContent')) {
              // getZipStringContent(url, path, [charset], [password])
              if (args.length >= 4) {
                password = _stripQuotes(args[3]);
              } else if (args.length >= 3 && _looksLikePassword(args[2])) {
                password = _stripQuotes(args[2]);
              }
            }

            // 解析路径：本地文件或 URL（URL 时先下载到本地）
            String localPath;
            if (firstArg.startsWith('http://') || firstArg.startsWith('https://')) {
              // URL：先下载（如果尚未下载）
              var saveName = nativeMd5(firstArg);
              if (saveName.isEmpty) saveName = 'archive_${DateTime.now().millisecondsSinceEpoch}';
              localPath = '$tempPath/$saveName';
              try {
                await PlatformBridge.instance.httpDownload(firstArg, localPath);
              } catch (_) {
                return null;
              }
            } else if (firstArg.startsWith('/') ||
                RegExp(r'^[A-Za-z]:[\\/]').hasMatch(firstArg)) {
              localPath = firstArg;
            } else {
              localPath = '$tempPath/$firstArg';
            }

            // 内部路径（getZipStringContent 的第 2 参数）
            String? innerPath;
            if (method.contains('StringContent') && args.length >= 2) {
              innerPath = _stripQuotes(args[1]);
            }

            final cacheKey =
                'archive_$method:$firstArg:${innerPath ?? ''}:${password ?? ''}';

            try {
              final file = File(localPath);
              if (!await file.exists()) return null;
              final bytes = await file.readAsBytes();

              // 尝试 ZIP 解压（archive 3.x 仅支持 ZIP，RAR/7z 暂不支持，密码仅 ZIP 有效）
              archive.Archive? archiveObj;
              try {
                final zipDecoder = archive.ZipDecoder();
                if (password != null && password.isNotEmpty) {
                  archiveObj = zipDecoder.decodeBytes(bytes, password: password);
                } else {
                  archiveObj = zipDecoder.decodeBytes(bytes);
                }
              } catch (_) {
                return null;
              }

              switch (method) {
                case 'unzipFile':
                case 'un7zFile':
                case 'unrarFile':
                case 'unArchiveFile':
                  // 解压到临时目录
                  final extractDir =
                      '$tempPath/extracted_${DateTime.now().millisecondsSinceEpoch}';
                  final outDir = Directory(extractDir);
                  await outDir.create(recursive: true);
                  for (final archFile in archiveObj) {
                    if (!archFile.isFile) continue;
                    final outPath = '$extractDir/${archFile.name}';
                    final outFile = File(outPath);
                    await outFile.parent.create(recursive: true);
                    await outFile.writeAsBytes(archFile.content as List<int>);
                  }
                  return MapEntry(cacheKey, extractDir);
                case 'getZipStringContent':
                case 'getRarStringContent':
                case 'get7zStringContent':
                  if (innerPath == null || innerPath.isEmpty) return null;
                  for (final archFile in archiveObj) {
                    if (archFile.name == innerPath ||
                        archFile.name.endsWith('/$innerPath')) {
                      if (archFile.isFile) {
                        return MapEntry(
                          cacheKey,
                          utf8.decode(archFile.content as List<int>,
                              allowMalformed: true),
                        );
                      }
                      break;
                    }
                  }
                  break;
              }
            } catch (_) {}
            return null;
          }());
        }
        final results = await Future.wait(matchFutures);
        for (final entry in results) {
          if (entry != null) archiveCacheEntries[entry.key] = entry.value;
        }
        if (archiveCacheEntries.isNotEmpty) {
          await preCacheHttpResults(archiveCacheEntries);
        }
      }());
    }

    // 6.9 预缓存 URL 启动操作（接入 url_launcher）
    // 扫描 java.startBrowser/openUrl/openVideoPlayer，并行启动
    if (_urlLaunchPattern.hasMatch(jsCode)) {
      parallelFutures.add(() async {
        final launchFutures = <Future<void>>[];
        for (final match in _urlLaunchPattern.allMatches(jsCode)) {
          final url = match.group(2)!;
          launchFutures.add(() async {
            try {
              await url_launcher.launchUrl(
                Uri.parse(url),
                mode: url_launcher.LaunchMode.platformDefault,
              );
            } catch (_) {}
          }());
        }
        // 并发执行所有 launchUrl 调用
        await Future.wait(launchFutures);
      }());
    }

    // 并行执行 6.7/6.8/6.9
    if (parallelFutures.isNotEmpty) {
      await Future.wait(parallelFutures);
    }

    // 7. 预缓存 HTML 解析结果（使用 Dart 原生 html 包）

    // 收集已缓存的 HTTP 内容
    final knownHtml = <String, String>{};
    // 从 HTTP 缓存中获取内容
    for (final url in httpUrls) {
      final httpCacheKey = 'http_get:$url';
      final cached = evaluate('__getCache(${jsonEncode(httpCacheKey)})');
      if (cached != null && cached.isNotEmpty && cached != 'undefined' && cached.length > 50) {
        knownHtml[httpCacheKey] = cached;
      }
    }

    for (final match in _htmlParsePattern.allMatches(jsCode)) {
      final method = match.group(1) ?? match.group(2);
      final firstArg = match.group(3)?.trim() ?? '';
      final secondArg = match.group(4)?.trim();
      final thirdArg = match.group(5)?.trim(); // java.jsoup.getAttr 的 attr 参数

      String? htmlContent;
      String? selector;
      String? attrName;

      // 判断方法类型
      final isJsoupMethod = method == 'select' || method == 'selectFirst' || method == 'getAttr';

      if (isJsoupMethod) {
        // java.jsoup.select(html, selector) / java.jsoup.getAttr(html, selector, attr)
        // firstArg = html来源, secondArg = selector, thirdArg = attr
        if (firstArg == 'result' || firstArg == 'content' || firstArg == 'src' || firstArg == 'html') {
          for (final entry in knownHtml.entries) {
            htmlContent = entry.value;
            break;
          }
        } else if (firstArg.startsWith('"') || firstArg.startsWith("'")) {
          try { htmlContent = jsonDecode(firstArg) as String; } catch (_) {}
        } else {
          // 变量名（如 item）- 跳过，运行时处理
          continue;
        }
        // 解析选择器
        if (secondArg != null) {
          if (secondArg.startsWith('"') || secondArg.startsWith("'")) {
            try { selector = jsonDecode(secondArg); } catch (_) { selector = secondArg; }
          } else {
            selector = secondArg;
          }
        }
        // 解析属性名
        if (thirdArg != null && method == 'getAttr') {
          if (thirdArg.startsWith('"') || thirdArg.startsWith("'")) {
            try { attrName = jsonDecode(thirdArg); } catch (_) { attrName = thirdArg; }
          } else {
            attrName = thirdArg;
          }
        }
      } else {
        // 原有逻辑：_JsoupLite.selectFirst/selectAll, java.getString/getElement/getElements
        if (firstArg == 'result' || firstArg == 'content' || firstArg == 'src') {
          // 内容来自 result 变量 - 从 HTTP 缓存获取
          for (final entry in knownHtml.entries) {
            htmlContent = entry.value;
            break;
          }
        } else if (firstArg.startsWith('"') || firstArg.startsWith("'")) {
          // 字面量字符串内容
          try {
            htmlContent = jsonDecode(firstArg) as String;
          } catch (_) {}
        } else {
          // 变量名 - 尝试从 QuickJS 求值
          try {
            final evalResult = evaluate('__evalVar(${jsonEncode(firstArg)})');
            if (evalResult != null && evalResult.isNotEmpty && evalResult.length > 50) {
              htmlContent = evalResult;
            }
          } catch (_) {}
        }

        // 解析选择器
        if (secondArg != null) {
          if (secondArg.startsWith('"') || secondArg.startsWith("'")) {
            try {
              selector = jsonDecode(secondArg);
            } catch (_) {
              selector = secondArg;
            }
          } else {
            selector = secondArg;
          }
          // 清理选择器前缀
          if (selector?.startsWith('@@') == true) selector = selector!.substring(2);
          if (selector?.startsWith('@css:') == true) selector = selector!.substring(5);
        } else if (method == 'getString' || method == 'getElement' || method == 'getElements') {
          // 单参数模式：firstArg 是选择器，内容来自 result
          var sel = firstArg;
          if (sel.startsWith('"') || sel.startsWith("'")) {
            try {
              sel = jsonDecode(sel);
            } catch (_) {}
          }
          if (sel.startsWith('@@')) sel = sel.substring(2);
          if (sel.startsWith('@css:')) sel = sel.substring(5);
          selector = sel;
          // 单参数模式需要从 HTTP 缓存获取内容
          if (htmlContent == null) {
            for (final entry in knownHtml.entries) {
              htmlContent = entry.value;
              break;
            }
          }
        }
      }

      if (htmlContent == null || htmlContent.isEmpty || selector == null || selector.isEmpty) continue;

      // 使用 Dart 原生 html 包解析
      final parsed = _nativeJsoupParse(htmlContent, selector);

      // 计算与 JS 侧 _hashStr 等价的 hash
      final htmlHash = _computeJsHash(htmlContent);

      // 缓存结果到 JS 侧 _javaCache
      final sfKey = 'jsoup_sf:$selector:$htmlHash';
      final saKey = 'jsoup_sa:$selector:$htmlHash';

      if (!_isCached(sfKey)) {
        evaluate('__setCache(${jsonEncode(sfKey)}, ${jsonEncode(parsed['first'])});');
        _cachedKeys.add(sfKey);
      }
      if (!_isCached(saKey)) {
        evaluate('__setCache(${jsonEncode(saKey)}, ${jsonEncode(parsed['all'])});');
        _cachedKeys.add(saKey);
      }
      // 缓存 text/href/src 供 java.getString 快速访问
      final textKey = 'jsoup_text:$selector:$htmlHash';
      final hrefKey = 'jsoup_href:$selector:$htmlHash';
      if (parsed['text'] != null && !_isCached(textKey)) {
        evaluate('__setCache(${jsonEncode(textKey)}, ${jsonEncode(parsed['text'])});');
        _cachedKeys.add(textKey);
      }
      if (parsed['href'] != null && (parsed['href'] as String).isNotEmpty && !_isCached(hrefKey)) {
        evaluate('__setCache(${jsonEncode(hrefKey)}, ${jsonEncode(parsed['href'])});');
        _cachedKeys.add(hrefKey);
      }
      // 缓存 java.jsoup.getAttr 结果
      if (attrName != null && attrName.isNotEmpty) {
        final gaKey = 'jsoup_ga:$selector:$attrName:$htmlHash';
        if (!_isCached(gaKey)) {
          // 从解析结果中提取属性值
          String? attrValue;
          try {
            final doc = html_parser.parse(htmlContent);
            final elements = doc.querySelectorAll(selector);
            if (elements.isNotEmpty) {
              attrValue = elements.first.attributes[attrName] ?? '';
            }
          } catch (_) {}
          evaluate('__setCache(${jsonEncode(gaKey)}, ${jsonEncode(attrValue ?? '')});');
          _cachedKeys.add(gaKey);
        }
      }
    }
  }

  /// 替换模板变量 {{key}}, {{page}} 等
  String _resolveTemplateVars(String url, Map<String, dynamic> env) {
    return url.replaceAllMapped(
      _cacheVarPattern,
      (match) {
        final varName = match.group(1) ?? '';
        final val = env[varName];
        if (val != null) return val.toString();
        // 尝试点号路径
        final parts = varName.split('.');
        dynamic current = env;
        for (final part in parts) {
          if (current is Map) {
            current = current[part];
          } else {
            current = null;
            break;
          }
        }
        return current?.toString() ?? match.group(0)!;
      },
    );
  }

  /// 使用 Dart 原生 html 包解析 HTML（替代 JS 侧正则版 _JsoupLite）
  Map<String, dynamic> _nativeJsoupParse(String html, String selector) {
    try {
      final doc = html_parser.parse(html);
      final elements = doc.querySelectorAll(selector);
      if (elements.isEmpty) {
        return {'first': '', 'all': <String>[], 'attr': ''};
      }
      final firstEl = elements.first;
      final firstHtml = firstEl.outerHtml;
      final allHtml = elements.map((e) => e.outerHtml).toList();
      final firstText = firstEl.text.trim();
      final firstHref = firstEl.attributes['href'] ?? '';
      final firstSrc = firstEl.attributes['src'] ?? '';
      return {
        'first': firstHtml,
        'all': allHtml,
        'text': firstText,
        'href': firstHref,
        'src': firstSrc,
        'count': elements.length,
      };
    } catch (e) {
      return {'first': '', 'all': <String>[], 'attr': ''};
    }
  }

  /// 计算 JS 侧 _hashStr 等价的 hash 值
  int _computeJsHash(String s) {
    int h = 0;
    for (int i = 0; i < s.length; i++) {
      h = ((h << 5) - h + s.codeUnitAt(i)) & 0xFFFFFFFF;
      if (h > 0x7FFFFFFF) h = h - 0x100000000;
    }
    return h;
  }

  /// 检查缓存键是否已存在
  bool _isCached(String key) {
    return _cachedKeys.contains(key);
  }

  /// 并发受限的批量执行器：限制同时运行的 Future 数量，防止 OOM
  /// 书源 JS 若含大量 java.ajax() 调用，无限制并发会导致响应体同时驻留内存
  static const int _maxConcurrentRequests = 4;
  Future<List<T?>> _runWithConcurrency<T>(
    Iterable<Future<T?>> Function() futureBuilder,
  ) async {
    final futures = futureBuilder().toList();
    if (futures.isEmpty) return [];
    final results = <T?>[];
    for (var i = 0; i < futures.length; i += _maxConcurrentRequests) {
      final batch = futures.sublist(
        i,
        (i + _maxConcurrentRequests > futures.length)
            ? futures.length
            : i + _maxConcurrentRequests,
      );
      results.addAll(await Future.wait(batch));
    }
    return results;
  }

  /// 解析相对URL
  /// 不能用 Uri.resolve，它会对 % 进行二次编码，破坏已编码的 URL 参数
  String _resolveUrl(String url, String baseUrl) {
    return legado_url.AnalyzeUrl.resolve(baseUrl, url);
  }

  /// [legado URL 选项兼容] 反转义 JS 字符串字面量
  /// 处理 \" \' \\ \n \r \t 等转义序列
  String _unescapeJsString(String raw, String quote) {
    if (raw.isEmpty) return raw;
    // 双引号字符串：用 jsonDecode 安全反转义
    if (quote == '"') {
      try {
        final decoded = jsonDecode('"$raw"');
        if (decoded is String) return decoded;
      } catch (_) {
        // fallback 到手动反转义
      }
    }
    // 单引号字符串或 fallback：手动反转义
    final result = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final ch = raw[i];
      if (ch == '\\' && i + 1 < raw.length) {
        final next = raw[i + 1];
        switch (next) {
          case 'n':
            result.write('\n');
            break;
          case 'r':
            result.write('\r');
            break;
          case 't':
            result.write('\t');
            break;
          case '\\':
            result.write('\\');
            break;
          case '"':
            result.write('"');
            break;
          case "'":
            result.write("'");
            break;
          case '/':
            result.write('/');
            break;
          case 'b':
            result.write('\b');
            break;
          case 'f':
            result.write('\f');
            break;
          default:
            // 未知转义，保留原样
            result.write(ch);
            result.write(next);
        }
        i += 2;
      } else {
        result.write(ch);
        i++;
      }
    }
    return result.toString();
  }

  /// 分割 JS 函数调用的参数字符串（简化版，不支持嵌套括号/字符串内逗号）
  /// 用于 WebView 调用参数提取，Legado 书源基本是字面量参数
  List<String> _splitArgs(String argsStr) {
    if (argsStr.isEmpty) return [];
    final result = <String>[];
    final current = StringBuffer();
    var inSingle = false, inDouble = false, depth = 0;
    for (var i = 0; i < argsStr.length; i++) {
      final c = argsStr[i];
      if (c == '\\' && i + 1 < argsStr.length) {
        current.write(c);
        current.write(argsStr[++i]);
        continue;
      }
      if (c == "'" && !inDouble) inSingle = !inSingle;
      if (c == '"' && !inSingle) inDouble = !inDouble;
      if (!inSingle && !inDouble) {
        if (c == '(' || c == '[' || c == '{') depth++;
        if (c == ')' || c == ']' || c == '}') depth--;
        if (c == ',' && depth == 0) {
          result.add(current.toString().trim());
          current.clear();
          continue;
        }
      }
      current.write(c);
    }
    if (current.isNotEmpty) result.add(current.toString().trim());
    return result;
  }

  /// 去除字符串两端的引号
  String? _stripQuotes(String? s) {
    if (s == null) return null;
    s = s.trim();
    if (s.length >= 2 && ((s.startsWith("'") && s.endsWith("'")) ||
        (s.startsWith('"') && s.endsWith('"')))) {
      // 尝试 JSON 解码字面量
      try {
        return jsonDecode(s) as String;
      } catch (_) {
        return s.substring(1, s.length - 1);
      }
    }
    return s.isEmpty ? null : s;
  }

  /// 判断参数字符串是否像是密码（而非 charset）
  /// charset 通常是 utf-8/gbk/gb2312/ascii/iso-8859-1 等，不以此开头的视为密码
  bool _looksLikePassword(String? s) {
    if (s == null) return false;
    final lower = s.toLowerCase();
    final charsets = ['utf', 'gb', 'iso', 'ascii', 'latin', 'unicode', 'utf-8', 'gbk', 'gb2312', 'big5'];
    for (final cs in charsets) {
      if (lower.startsWith(cs)) return false;
    }
    return true;
  }

  /// 根据 deviceInfo 生成默认 WebView UA
  String _defaultWebViewUA(Map<String, dynamic> deviceInfo) {
    final model = deviceInfo['model']?.toString() ?? 'unknown';
    final release = deviceInfo['version'] is Map
        ? (deviceInfo['version']['release']?.toString() ?? '14')
        : '14';
    // Mozilla/5.0 (Linux; Android 14; <model>) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36
    return 'Mozilla/5.0 (Linux; Android $release; $model) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  }

  // ===== 脚本编译缓存（借鉴 legado 的 scriptCache）=====

  /// 带缓存的脚本执行
  /// 相同代码只编译一次，后续直接返回缓存结果
  /// 注意：由于 QuickJS 不支持 CompiledScript，这里缓存的是代码解析结果
  dynamic evaluateWithCache(String script) {
    final cacheKey = _md5Hash(script);

    if (_scriptCache.containsKey(cacheKey)) {
      return _scriptCache[cacheKey];
    }

    // 限制缓存大小
    if (_scriptCache.length >= _maxScriptCacheSize) {
      _scriptCache.remove(_scriptCache.keys.first);
    }

    final result = evaluate(script);
    if (result != null) {
      _scriptCache[cacheKey] = result;
    }
    return result;
  }

  /// 清除脚本缓存
  void clearScriptCache() {
    _scriptCache.clear();
  }

  /// MD5 哈希（用于缓存 key）
  String _md5Hash(String input) {
    // 简单哈希，避免引入 crypto 依赖
    var hash = 0;
    for (var i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash + input.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  /// 释放资源
  void dispose() {
    _jsRuntime?.dispose();
    _jsRuntime = null;
    _initialized = false;
    _installedPackages.clear();
    _moduleCache.clear();
    _bridgeCache.clear();
    _scriptCache.clear();
    _sharedScopeVars.clear();
    _cachedKeys.clear();
  }
}
