import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'quickjs_runtime_stub.dart'
    if (dart.library.io) 'quickjs_runtime.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart' as archive;
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import 'package:synchronized/synchronized.dart';
import '../app_logger.dart';
import '../crash_log_service.dart';
import 'platform_channel.dart';
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
  static final _returnRegex = RegExp(r'\breturn\b');
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
    // iOS 静态链接进 Runner 可执行文件，符号编译期绑定，无 .so 文件也无 checkNativeLib
    // handler，故 iOS 直接信任，否则 MissingPluginException 会导致引擎启动失败。
    if (Platform.isAndroid) {
      try {
        _nativeLibChecked = await NativeChannel.instance.checkNativeLib('quickjs_c_bridge');
      } catch (_) {
        _nativeLibChecked = false;
      }
      // native lib 未就绪 → 跳过所有 FFI 调用，避免 SIGSEGV
      if (!_nativeLibChecked) return false;
    } else {
      // iOS / 其他平台：静态链接，无需检查
      _nativeLibChecked = true;
    }

    // [覆盖安装闪退修复] 快路径：_initialized 为真直接信任，零 FFI 调用
    // 不做 evaluate() 健康检查，避免 SIGSEGV 裸奔（FFI 段错误 Dart catch 不住）
    if (_initialized && _jsRuntime != null) return true;

    if (_initialized) return true;
    try {
      _jsRuntime = getJavascriptRuntime();
      // P2: 设置默认 JS 执行超时 5 秒，防止死循环卡死 App
      _jsRuntime!.setEvalTimeout(5000);
      // 先标记运行时可用，再注入 polyfills
      // 注意：_initialized 在所有注入完成后才设为 true
      await _injectNodePolyfills();
      _injectJavaBridge();
      await _loadInstalledPackages();

      // 验证注入是否成功
      final verifyResult = evaluate('typeof java !== "undefined" && typeof CryptoJS !== "undefined" && typeof _javaCache !== "undefined" && typeof _AES !== "undefined"');
      if (verifyResult != 'true') {
        // 尝试重新注入
        _injectJavaBridge();
        final retryResult = evaluate('typeof java !== "undefined" && typeof _AES !== "undefined"');
        if (retryResult != 'true') {
          return false;
        }
      }

      _initialized = true;
      return true;
    } catch (e, st) {
      // FFI lookup 失败（QuickJS 符号未链接到二进制）会在此抛出 ArgumentError
      // 之前被静默吞掉，现在打印日志便于诊断
      debugPrint('JsEngine init failed: $e\n$st');
      return false;
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



  // ===== Node.js API 兼容层 =====

  Future<void> _injectNodePolyfills() async {
    const nodePolyfills = '''
      // ===== Node.js 核心模块模拟 =====

      var process = {
        env: {},
        argv: [],
        version: 'v18.17.0',
        versions: { node: '18.17.0', v8: '10.2.154.4' },
        platform: 'android',
        arch: 'arm64',
        pid: 1,
        cwd: function() { return '/'; },
        exit: function(code) {},
        nextTick: function(fn) { setTimeout(fn, 0); },
        on: function(event, handler) {},
        stdout: { write: function(data) {} },
        stderr: { write: function(data) {} },
      };

      var Buffer = {
        from: function(data, encoding) {
          if (typeof data === 'string') {
            return { toString: function() { return data; }, length: data.length };
          }
          return { length: data ? data.length : 0 };
        },
        isBuffer: function(obj) { return false; },
        concat: function(list) { return Buffer.from(list.join('')); },
      };

      // ===== URL/URLSearchParams 完整实现 =====
      function URL(url, base) {
        if (!(this instanceof URL)) return new URL(url, base);
        var input = url || '';
        // 处理 base URL
        if (base) {
          var baseParsed = new URL(base);
          if (input.startsWith('/') || input.startsWith('./') || input.startsWith('../')) {
            input = baseParsed.origin + input;
          } else if (!input.startsWith('http')) {
            input = baseParsed.origin + '/' + input;
          }
        }
        this.href = input;
        // 解析 protocol
        var protoMatch = input.match(/^(https?:)\\/\\//i);
        this.protocol = protoMatch ? protoMatch[1] : '';
        // 解析 host (hostname:port)
        var hostMatch = input.match(/^https?:\\/\\/([^/\\?#]+)/i);
        this.host = hostMatch ? hostMatch[1] : '';
        // 解析 hostname 和 port
        if (this.host) {
          var parts = this.host.split(':');
          this.hostname = parts[0];
          this.port = parts.length > 1 ? parts[1] : '';
        } else {
          this.hostname = '';
          this.port = '';
        }
        this.origin = this.protocol ? this.protocol + '//' + this.host : '';
        // 解析 pathname, search, hash
        var pathPart = hostMatch ? input.substring(hostMatch.index + hostMatch[0].length) : input;
        var hashIdx = pathPart.indexOf('#');
        var hashPart = '';
        if (hashIdx >= 0) {
          hashPart = pathPart.substring(hashIdx);
          pathPart = pathPart.substring(0, hashIdx);
        }
        var searchIdx = pathPart.indexOf('?');
        if (searchIdx >= 0) {
          this.search = pathPart.substring(searchIdx);
          this.pathname = pathPart.substring(0, searchIdx) || '/';
        } else {
          this.search = '';
          this.pathname = pathPart || '/';
        }
        this.hash = hashPart;
        this.toString = function() { return this.href; };
      }
      function URLSearchParams(init) {
        if (!(this instanceof URLSearchParams)) return new URLSearchParams(init);
        this._params = [];
        if (typeof init === 'string') {
          var str = init.startsWith('?') ? init.substring(1) : init;
          if (str) {
            var pairs = str.split('&');
            for (var i = 0; i < pairs.length; i++) {
              var eq = pairs[i].indexOf('=');
              if (eq >= 0) {
                this._params.push([decodeURIComponent(pairs[i].substring(0, eq)), decodeURIComponent(pairs[i].substring(eq + 1))]);
              } else if (pairs[i]) {
                this._params.push([decodeURIComponent(pairs[i]), '']);
              }
            }
          }
        }
        this.get = function(name) {
          for (var i = 0; i < this._params.length; i++) {
            if (this._params[i][0] === name) return this._params[i][1];
          }
          return null;
        };
        this.getAll = function(name) {
          var results = [];
          for (var i = 0; i < this._params.length; i++) {
            if (this._params[i][0] === name) results.push(this._params[i][1]);
          }
          return results;
        };
        this.set = function(name, value) {
          var found = false;
          for (var i = 0; i < this._params.length; i++) {
            if (this._params[i][0] === name) {
              if (!found) { this._params[i][1] = value; found = true; }
              else { this._params.splice(i, 1); i--; }
            }
          }
          if (!found) this._params.push([name, value]);
        };
        this.has = function(name) {
          for (var i = 0; i < this._params.length; i++) {
            if (this._params[i][0] === name) return true;
          }
          return false;
        };
        this.delete = function(name) {
          for (var i = 0; i < this._params.length; i++) {
            if (this._params[i][0] === name) { this._params.splice(i, 1); i--; }
          }
        };
        this.append = function(name, value) { this._params.push([name, value]); };
        this.toString = function() {
          return this._params.map(function(p) {
            return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
          }).join('&');
        };
        this.keys = function() { return this._params.map(function(p) { return p[0]; }); };
        this.values = function() { return this._params.map(function(p) { return p[1]; }); };
        this.entries = function() { return this._params.map(function(p) { return [p[0], p[1]]; }); };
        this.forEach = function(fn) { for (var i = 0; i < this._params.length; i++) fn(this._params[i][1], this._params[i][0]); };
      }

      function EventEmitter() {
        this._events = {};
      }
      EventEmitter.prototype.on = function(event, handler) {
        if (!this._events[event]) this._events[event] = [];
        this._events[event].push(handler);
        return this;
      };
      EventEmitter.prototype.emit = function(event) {
        var args = Array.from(arguments).slice(1);
        (this._events[event] || []).forEach(function(handler) { handler.apply(null, args); });
        return this;
      };
      EventEmitter.prototype.off = function(event, handler) {
        if (this._events[event]) {
          this._events[event] = this._events[event].filter(function(h) { return h !== handler; });
        }
        return this;
      };
      EventEmitter.prototype.once = function(event, handler) {
        var self = this;
        var wrapper = function() {
          handler.apply(null, arguments);
          self.off(event, wrapper);
        };
        return this.on(event, wrapper);
      };

      var _modules = {};
      var _moduleCache = {};
      function require(name) {
        if (_moduleCache[name]) return _moduleCache[name];
        if (_modules[name]) {
          var module = { exports: {} };
          _modules[name](module, module.exports, require);
          _moduleCache[name] = module.exports;
          return _moduleCache[name];
        }
        switch(name) {
          case 'http': return { get: function(url, cb) {}, request: function() {} };
          case 'https': return { get: function(url, cb) {}, request: function() {} };
          case 'fs': return { readFileSync: function(path) { return ''; }, writeFileSync: function(path, data) {} };
          case 'path': return { join: function() { return Array.from(arguments).join('/'); }, resolve: function() { return '/'; }, basename: function(p) { return p.split('/').pop(); }, dirname: function(p) { return p.split('/').slice(0, -1).join('/'); } };
          case 'crypto': return { createHash: function(algo) { return { update: function(d) { return this; }, digest: function(enc) { return ''; } }; }, randomBytes: function(n) { return []; } };
          case 'url': return { parse: function(u) { return new URL(u); }, format: function(u) { return u.href || u; } };
          case 'querystring': return { parse: function(q) { var r = {}; q.split('&').forEach(function(p) { var kv = p.split('='); r[kv[0]] = kv[1]; }); return r; }, stringify: function(o) { return Object.keys(o).map(function(k) { return k + '=' + o[k]; }).join('&'); } };
          case 'events': return { EventEmitter: EventEmitter };
          case 'stream': return { Readable: function() {}, Writable: function() {}, Transform: function() {} };
          case 'util': return { promisify: function(fn) { return fn; }, inherits: function() {}, inspect: function(obj) { return JSON.stringify(obj); } };
          case 'cheerio': return { load: function(html) { return function(sel) { return { text: function() { return ''; }, attr: function(a) { return ''; }, find: function(s) { return this; }, each: function(fn) {} }; }; } };
          default: throw new Error('Module not found: ' + name);
        }
      }

      // ===== fetch() 全局函数 =====
      // 借鉴 legado 的 JsExtensions.ajax：直接返回 HTML 字符串（同步模式）
      // legado 书源中 fetch(url) 期望直接得到 HTML，不是 Response 对象
      function fetch(input, init) {
        var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
        var method = (init && init.method) || 'GET';
        // 自动拼接 baseUrl
        var fullUrl = url;
        if (url && !url.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
          fullUrl = baseUrl.replace(/\\/+\$/, '') + '/' + url.replace(/^\\/+/, '');
        }
        var cacheKey = method.toUpperCase() === 'POST' ? 'http_post:' + fullUrl : 'http_get:' + fullUrl;
        if (_javaCache[cacheKey] !== undefined) {
          return _javaCache[cacheKey];
        }
        // fallback: 尝试原始 url
        if (fullUrl !== url) {
          var origKey = method.toUpperCase() === 'POST' ? 'http_post:' + url : 'http_get:' + url;
          if (_javaCache[origKey] !== undefined) return _javaCache[origKey];
        }
        return '';
      }

      // ===== XMLHttpRequest 简易实现 =====
      // 同步模式：从缓存取结果；异步模式：回调触发但数据仍来自缓存
      function XMLHttpRequest() {
        this.readyState = 0;
        this.status = 0;
        this.statusText = '';
        this.responseText = '';
        this.responseXML = null;
        this.response = '';
        this.responseType = '';
        this.timeout = 0;
        this.withCredentials = false;
        this._method = 'GET';
        this._url = '';
        this._headers = {};
        this._async = true;
        this.onreadystatechange = null;
        this.onload = null;
        this.onerror = null;
        this.onabort = null;
        this.ontimeout = null;
        this.onprogress = null;
      }
      XMLHttpRequest.prototype.open = function(method, url, async) {
        this._method = method.toUpperCase();
        this._url = url;
        this._async = async !== false;
        this.readyState = 1;
      };
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        this._headers[name] = value;
      };
      XMLHttpRequest.prototype.send = function(body) {
        var self = this;
        var url = this._url;
        // 自动拼接 baseUrl
        if (url && !url.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
          url = baseUrl.replace(/\\/+\$/, '') + '/' + url.replace(/^\\/+/, '');
        }
        var cacheKey = this._method === 'POST' ? 'http_post:' + url : 'http_get:' + url;
        var cachedText = _javaCache[cacheKey] || '';
        // fallback: 尝试原始 url
        if (!cachedText && url !== this._url) {
          var origKey = this._method === 'POST' ? 'http_post:' + this._url : 'http_get:' + this._url;
          cachedText = _javaCache[origKey] || '';
        }
        this.readyState = 2;
        if (this.onreadystatechange) this.onreadystatechange();
        this.readyState = 3;
        if (this.onreadystatechange) this.onreadystatechange();
        this.status = cachedText ? 200 : 0;
        this.statusText = cachedText ? 'OK' : 'No cache';
        this.responseText = cachedText;
        this.response = cachedText;
        this.readyState = 4;
        if (this.onreadystatechange) this.onreadystatechange();
        if (cachedText && this.onload) this.onload();
        else if (!cachedText && this.onerror) this.onerror();
      };
      XMLHttpRequest.prototype.abort = function() {
        this.readyState = 0;
        if (this.onabort) this.onabort();
      };
      XMLHttpRequest.prototype.getResponseHeader = function(name) { return null; };
      XMLHttpRequest.prototype.getAllResponseHeaders = function() { return ''; };

      // ===== setTimeout / setInterval =====
      // QuickJS 可能不支持，提供 polyfill
      if (typeof setTimeout === 'undefined') {
        var _timerId = 0;
        var _timers = {};
        globalThis.setTimeout = function(fn, delay) { var id = ++_timerId; fn(); return id; };
        globalThis.setInterval = function(fn, delay) { var id = ++_timerId; fn(); return id; };
        globalThis.clearTimeout = function(id) { delete _timers[id]; };
        globalThis.clearInterval = function(id) { delete _timers[id]; };
      }

      // ===== console 增强 =====
      // 借鉴 legado：所有 console 输出同步到调试页面
      // 注意：总是覆盖 console，因为 QuickJS 可能已有内置 console 但没有 _getLogs
      var _consoleLogs = [];
      var _logSeq = 0;
      function _jsLog(msg, level) {
        level = level || 'log';
        _logSeq++;
        _consoleLogs.push({
          seq: _logSeq,
          ts: Date.now(),
          level: level,
          msg: typeof msg === 'string' ? msg : (msg && msg.toString ? msg.toString() : String(msg))
        });
        // 不限制日志数组长度（用户要求保留完整日志）
      }
      globalThis.console = {
        log: function() { _jsLog(Array.from(arguments).join(' '), 'log'); },
        warn: function() { _jsLog(Array.from(arguments).join(' '), 'warn'); },
        error: function() { _jsLog(Array.from(arguments).join(' '), 'error'); },
        info: function() { _jsLog(Array.from(arguments).join(' '), 'info'); },
        debug: function() { _jsLog(Array.from(arguments).join(' '), 'debug'); },
        trace: function() { _jsLog(Array.from(arguments).join(' '), 'trace'); },
        dir: function(obj) { _jsLog(JSON.stringify(obj, null, 2), 'log'); },
        table: function(data) { _jsLog(JSON.stringify(data, null, 2), 'log'); },
        time: function(label) { _consoleLogs._timers = _consoleLogs._timers || {}; _consoleLogs._timers[label] = Date.now(); },
        timeEnd: function(label) {
          _consoleLogs._timers = _consoleLogs._timers || {};
          if (_consoleLogs._timers[label]) {
            var ms = Date.now() - _consoleLogs._timers[label];
            _jsLog(label + ': ' + ms + 'ms', 'info');
            delete _consoleLogs._timers[label];
          }
        },
        count: function(label) {
          _consoleLogs._counts = _consoleLogs._counts || {};
          _consoleLogs._counts[label] = (_consoleLogs._counts[label] || 0) + 1;
          _jsLog(label + ': ' + _consoleLogs._counts[label], 'info');
        },
        assert: function(condition) {
          if (!condition) {
            _jsLog(Array.from(arguments).slice(1).join(' ') || 'Assertion failed', 'error');
          }
        },
        clear: function() { _consoleLogs.length = 0; },
        _getLogs: function() { return _consoleLogs; },
        _clearLogs: function() { _consoleLogs.length = 0; _logSeq = 0; },
        _logSeq: function() { return _logSeq; },
      };
      // 暴露 _jsLog 为全局，供内部调用
      globalThis._jsLog = _jsLog;

      // ===== btoa/atob 全局函数 =====
      // Phase 4-b: 优先走 C 原生 __nativeBase64，消除纯 JS 逐字节循环与中间字符串分配
      // __nativeBase64.decode/encode 与浏览器 atob/btoa 语义一致（binary string, code point 0-255）
      if (typeof __nativeBase64 !== 'undefined' && __nativeBase64 &&
          __nativeBase64.decode && __nativeBase64.encode) {
        // 直接引用 C 原生函数，零 JS 包装层开销
        globalThis.atob = __nativeBase64.decode;
        globalThis.btoa = __nativeBase64.encode;
      } else if (typeof btoa === 'undefined') {
        // 回退：纯 JS 实现（仅当 C 原生不可用时，例如非 Android 平台或旧版本）
        var _b64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
        globalThis.btoa = function(str) {
          var output = '';
          for (var i = 0; i < str.length; i += 3) {
            var byte1 = str.charCodeAt(i);
            var byte2 = i + 1 < str.length ? str.charCodeAt(i + 1) : 0;
            var byte3 = i + 2 < str.length ? str.charCodeAt(i + 2) : 0;
            var enc1 = byte1 >> 2;
            var enc2 = ((byte1 & 3) << 4) | (byte2 >> 4);
            var enc3 = ((byte2 & 15) << 2) | (byte3 >> 6);
            var enc4 = byte3 & 63;
            if (i + 1 >= str.length) { enc3 = enc4 = 64; }
            else if (i + 2 >= str.length) { enc4 = 64; }
            output += _b64Chars.charAt(enc1) + _b64Chars.charAt(enc2) + _b64Chars.charAt(enc3) + _b64Chars.charAt(enc4);
          }
          return output;
        };
        globalThis.atob = function(str) {
          var output = '';
          for (var i = 0; i < str.length; i += 4) {
            var enc1 = _b64Chars.indexOf(str.charAt(i));
            var enc2 = _b64Chars.indexOf(str.charAt(i + 1));
            var enc3 = _b64Chars.indexOf(str.charAt(i + 2));
            var enc4 = _b64Chars.indexOf(str.charAt(i + 3));
            var chr1 = (enc1 << 2) | (enc2 >> 4);
            var chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
            var chr3 = ((enc3 & 3) << 6) | enc4;
            output += String.fromCharCode(chr1);
            if (enc3 !== 64) output += String.fromCharCode(chr2);
            if (enc4 !== 64) output += String.fromCharCode(chr3);
          }
          return output;
        };
      }

      // ===== LZString 兼容层 =====
      // 书源规则常引用 LZString.decompressFromBase64，注入全局对象避免 ReferenceError
      // decompressFromBase64 优先走 C 原生 __nativeLz（Phase 1 加速），无原生时回退纯 JS
      if (typeof LZString === 'undefined') {
        var _lzKeyStr = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
        var _lzBase64ToStr = function(input) {
          var output = "";
          var ol = 0;
          var chr1, chr2, chr3;
          var enc1, enc2, enc3, enc4;
          var i = 0;
          input = input.replace(/[^A-Za-z0-9\+\/\=]/g, "");
          while (i < input.length) {
            enc1 = _lzKeyStr.indexOf(input.charAt(i++));
            enc2 = _lzKeyStr.indexOf(input.charAt(i++));
            enc3 = _lzKeyStr.indexOf(input.charAt(i++));
            enc4 = _lzKeyStr.indexOf(input.charAt(i++));
            chr1 = (enc1 << 2) | (enc2 >> 4);
            chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
            chr3 = ((enc3 & 3) << 6) | enc4;
            if (ol % 2 === 0) {
              output += String.fromCharCode((252 >> 2) | (chr1 & 3));
              output += String.fromCharCode((chr1 & 240) >> 4 | (chr2 & 15) << 4);
              output += String.fromCharCode((chr2 & 192) >> 6 | (chr3 & 63));
            } else {
              output += String.fromCharCode((252 >> 2) | (chr1 & 3) | (chr2 & 15) << 4);
              output += String.fromCharCode((chr1 & 192) >> 6 | (chr2 & 63));
            }
            ol += 3;
          }
          return output;
        };
        var _lzDecompress = function(compressed) {
          if (compressed == null) return "";
          if (compressed == "") return null;
          var dictionary = [];
          var enlargeIn = 4;
          var dictSize = 4;
          var numBits = 3;
          var entry = "";
          var result = "";
          var i, w, bits, resb, maxpower, power, c, data = { val: compressed.charAt(0), position: 32768, index: 1 };
          for (i = 0; i < 3; i += 1) dictionary[i] = i;
          bits = 0;
          maxpower = Math.pow(2, 2);
          power = 1;
          while (power != maxpower) {
            resb = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
            bits |= (resb > 0 ? 1 : 0) * power;
            power <<= 1;
          }
          switch (bits) {
            case 0:
              bits = 0; maxpower = Math.pow(2, 8); power = 1;
              while (power != maxpower) {
                resb = data.val & data.position; data.position >>= 1;
                if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
                bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
              }
              c = String.fromCharCode(bits);
              break;
            case 1:
              bits = 0; maxpower = Math.pow(2, 16); power = 1;
              while (power != maxpower) {
                resb = data.val & data.position; data.position >>= 1;
                if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
                bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
              }
              c = String.fromCharCode(bits);
              break;
            case 2: return "";
          }
          dictionary[3] = c; dictSize = 3; entry = c; result += c;
          while (true) {
            if (data.index > compressed.length) return "";
            bits = 0; maxpower = Math.pow(2, numBits); power = 1;
            while (power != maxpower) {
              resb = data.val & data.position; data.position >>= 1;
              if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
              bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
            }
            switch (c = bits) {
              case 0:
                bits = 0; maxpower = Math.pow(2, 8); power = 1;
                while (power != maxpower) {
                  resb = data.val & data.position; data.position >>= 1;
                  if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
                  bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
                }
                dictionary[dictSize++] = String.fromCharCode(bits);
                c = dictSize - 1; enlargeIn--; break;
              case 1:
                bits = 0; maxpower = Math.pow(2, 16); power = 1;
                while (power != maxpower) {
                  resb = data.val & data.position; data.position >>= 1;
                  if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
                  bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
                }
                dictionary[dictSize++] = String.fromCharCode(bits);
                c = dictSize - 1; enlargeIn--; break;
              case 2: return result;
            }
            if (enlargeIn == 0) { enlargeIn = Math.pow(2, numBits); numBits++; }
            if (dictionary[c]) { w = dictionary[c]; }
            else {
              if (c === dictSize) { w = entry + entry.charAt(0); }
              else { return null; }
            }
            result += w;
            dictionary[dictSize++] = entry + w.charAt(0);
            entry = w;
            enlargeIn--;
            if (enlargeIn == 0) { enlargeIn = Math.pow(2, numBits); numBits++; }
          }
        };
        globalThis.LZString = {
          // 优先走 C 原生（Phase 1 加速），无原生时回退纯 JS
          decompressFromBase64: function(str) {
            if (typeof __nativeLz !== 'undefined' && __nativeLz && __nativeLz.decompressFromBase64) {
              return __nativeLz.decompressFromBase64(str);
            }
            return _lzDecompress(_lzBase64ToStr(str));
          },
          decompress: function(str) {
            if (str == null) return "";
            if (str == "") return null;
            return _lzDecompress(str);
          },
          // 压缩方法暂不支持（书源规则极少使用，遇到再补）
          compressToBase64: function(str) {
            throw new Error('LZString.compressToBase64 not supported');
          },
          compress: function(str) {
            throw new Error('LZString.compress not supported');
          },
        };
      }
    ''';

    evaluate(nodePolyfills);
  }

  // ===== 纯 JS AES 引擎（QuickJS 同步可用，不依赖 Dart 桥接）=====

  void _injectAesEngine() {
    // 分步注入 AES 引擎，避免单次 evaluate 代码过大导致失败

    // Step 1: S-Box 和基础函数
    const aesStep1 = '''
      var _AES_SBOX = [0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16];
      var _AES_INV_SBOX = [0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d];
      var _AES_RCON = [0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36];
      function _aesXtime(a) { return (a & 0x80) ? ((a << 1) ^ 0x1b) : (a << 1); }
      function _aesMul(a, b) { var r = 0; for (var i = 0; i < 8; i++) { if (b & 1) r ^= a; a = _aesXtime(a); b >>= 1; } return r & 0xff; }
      function _aesSubBytes(s) { for (var i = 0; i < 16; i++) s[i] = _AES_SBOX[s[i]]; }
      function _aesInvSubBytes(s) { for (var i = 0; i < 16; i++) s[i] = _AES_INV_SBOX[s[i]]; }
      function _aesShiftRows(s) { var t=s[1];s[1]=s[5];s[5]=s[9];s[9]=s[13];s[13]=t;t=s[2];s[2]=s[10];s[10]=t;t=s[6];s[6]=s[14];s[14]=t;t=s[15];s[15]=s[11];s[11]=s[7];s[7]=s[3];s[3]=t; }
      function _aesInvShiftRows(s) { var t=s[13];s[13]=s[9];s[9]=s[5];s[5]=s[1];s[1]=t;t=s[2];s[2]=s[10];s[10]=t;t=s[6];s[6]=s[14];s[14]=t;t=s[3];s[3]=s[7];s[7]=s[11];s[11]=s[15];s[15]=t; }
      function _aesMixColumns(s) { for (var i=0;i<4;i++) { var a=s[i*4],b=s[i*4+1],c=s[i*4+2],d=s[i*4+3]; s[i*4]=_aesMul(2,a)^_aesMul(3,b)^c^d; s[i*4+1]=a^_aesMul(2,b)^_aesMul(3,c)^d; s[i*4+2]=a^b^_aesMul(2,c)^_aesMul(3,d); s[i*4+3]=_aesMul(3,a)^b^c^_aesMul(2,d); } }
      function _aesInvMixColumns(s) { for (var i=0;i<4;i++) { var a=s[i*4],b=s[i*4+1],c=s[i*4+2],d=s[i*4+3]; s[i*4]=_aesMul(0x0e,a)^_aesMul(0x0b,b)^_aesMul(0x0d,c)^_aesMul(0x09,d); s[i*4+1]=_aesMul(0x09,a)^_aesMul(0x0e,b)^_aesMul(0x0b,c)^_aesMul(0x0d,d); s[i*4+2]=_aesMul(0x0d,a)^_aesMul(0x09,b)^_aesMul(0x0e,c)^_aesMul(0x0b,d); s[i*4+3]=_aesMul(0x0b,a)^_aesMul(0x0d,b)^_aesMul(0x09,c)^_aesMul(0x0e,d); } }
      function _aesAddRoundKey(s, rk) { for (var i = 0; i < 16; i++) s[i] ^= rk[i]; }
    ''';

    // Step 2: Key expansion + encrypt/decrypt blocks
    const aesStep2 = '''
      function _aesKeyExpansion(key) {
        var nk = key.length / 4, nr = nk + 6;
        var w = new Array(4 * (nr + 1));
        for (var i = 0; i < nk; i++) { w[i*4]=key[i*4]; w[i*4+1]=key[i*4+1]; w[i*4+2]=key[i*4+2]; w[i*4+3]=key[i*4+3]; }
        for (var i = nk; i < 4*(nr+1); i++) {
          var t = [w[(i-1)*4], w[(i-1)*4+1], w[(i-1)*4+2], w[(i-1)*4+3]];
          if (i % nk === 0) { var tmp=t[0]; t[0]=_AES_SBOX[t[1]]^_AES_RCON[i/nk]; t[1]=_AES_SBOX[t[2]]; t[2]=_AES_SBOX[t[3]]; t[3]=_AES_SBOX[tmp]; }
          else if (nk > 6 && i % nk === 4) { t[0]=_AES_SBOX[t[0]]; t[1]=_AES_SBOX[t[1]]; t[2]=_AES_SBOX[t[2]]; t[3]=_AES_SBOX[t[3]]; }
          w[i*4]=w[(i-nk)*4]^t[0]; w[i*4+1]=w[(i-nk)*4+1]^t[1]; w[i*4+2]=w[(i-nk)*4+2]^t[2]; w[i*4+3]=w[(i-nk)*4+3]^t[3];
        }
        return w;
      }
      function _aesEncryptBlock(block, w, nr) {
        var s = block.slice(); _aesAddRoundKey(s, w.slice(0, 16));
        for (var r = 1; r < nr; r++) { _aesSubBytes(s); _aesShiftRows(s); _aesMixColumns(s); _aesAddRoundKey(s, w.slice(r*16, r*16+16)); }
        _aesSubBytes(s); _aesShiftRows(s); _aesAddRoundKey(s, w.slice(nr*16, nr*16+16));
        return s;
      }
      function _aesDecryptBlock(block, w, nr) {
        var s = block.slice(); _aesAddRoundKey(s, w.slice(nr*16, nr*16+16));
        for (var r = nr-1; r > 0; r--) { _aesInvShiftRows(s); _aesInvSubBytes(s); _aesAddRoundKey(s, w.slice(r*16, r*16+16)); _aesInvMixColumns(s); }
        _aesInvShiftRows(s); _aesInvSubBytes(s); _aesAddRoundKey(s, w.slice(0, 16));
        return s;
      }
      function _aesPkcs7Pad(data) { var pad = 16 - (data.length % 16); var r = data.slice(); for (var i = 0; i < pad; i++) r.push(pad); return r; }
      function _aesPkcs7Unpad(data) { if (data.length === 0) return data; var pad = data[data.length - 1]; if (pad < 1 || pad > 16) return data; for (var i = data.length - pad; i < data.length; i++) { if (data[i] !== pad) return data; } return data.slice(0, data.length - pad); }
    ''';

    // Step 3: UTF-8/Base64 conversion + _AES public API
    const aesStep3 = '''
      function _aesUtf8ToBytes(str) {
        var bytes = [];
        for (var i = 0; i < str.length; i++) {
          var c = str.charCodeAt(i);
          if (c < 0x80) bytes.push(c);
          else if (c < 0x800) { bytes.push(0xc0|(c>>6)); bytes.push(0x80|(c&0x3f)); }
          else if (c >= 0xd800 && c <= 0xdbff) { var hi=c,lo=str.charCodeAt(++i); var cp=((hi-0xd800)<<10)+(lo-0xdc00)+0x10000; bytes.push(0xf0|(cp>>18)); bytes.push(0x80|((cp>>12)&0x3f)); bytes.push(0x80|((cp>>6)&0x3f)); bytes.push(0x80|(cp&0x3f)); }
          else { bytes.push(0xe0|(c>>12)); bytes.push(0x80|((c>>6)&0x3f)); bytes.push(0x80|(c&0x3f)); }
        }
        return bytes;
      }
      function _aesBytesToUtf8(bytes) {
        var str = '';
        for (var i = 0; i < bytes.length; i++) {
          var c = bytes[i];
          if (c < 0x80) str += String.fromCharCode(c);
          else if (c >= 0xf0) { str += String.fromCharCode(((c&0x07)<<18)|((bytes[++i]&0x3f)<<12)|((bytes[++i]&0x3f)<<6)|(bytes[++i]&0x3f)); }
          else if (c >= 0xe0) { str += String.fromCharCode(((c&0x0f)<<12)|((bytes[++i]&0x3f)<<6)|(bytes[++i]&0x3f)); }
          else { str += String.fromCharCode(((c&0x1f)<<6)|(bytes[++i]&0x3f)); }
        }
        return str;
      }
      var _AES_B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      function _aesBytesToBase64(bytes) {
        var r = '';
        for (var i = 0; i < bytes.length; i += 3) {
          var b1=bytes[i], b2=i+1<bytes.length?bytes[i+1]:0, b3=i+2<bytes.length?bytes[i+2]:0;
          r += _AES_B64[b1>>2] + _AES_B64[((b1&3)<<4)|(b2>>4)] + (i+1<bytes.length?_AES_B64[((b2&15)<<2)|(b3>>6)]:'=') + (i+2<bytes.length?_AES_B64[b3&63]:'=');
        }
        return r;
      }
      function _aesBase64ToBytes(b64) {
        b64 = b64.replace(/[^A-Za-z0-9+/]/g, '');
        var bytes = [];
        for (var i = 0; i < b64.length; i += 4) {
          var b1=_AES_B64.indexOf(b64[i]), b2=_AES_B64.indexOf(b64[i+1]), b3=b64[i+2]==='='?0:_AES_B64.indexOf(b64[i+2]), b4=b64[i+3]==='='?0:_AES_B64.indexOf(b64[i+3]);
          bytes.push((b1<<2)|(b2>>4)); if (b64[i+2]!=='=') bytes.push(((b2&15)<<4)|(b3>>2)); if (b64[i+3]!=='=') bytes.push(((b3&3)<<6)|b4);
        }
        return bytes;
      }
      function _aesParseKey(val) {
        if (!val) return [];
        if (typeof val === 'object' && val.words && Array.isArray(val.words)) {
          var bytes = [];
          for (var i = 0; i < val.words.length; i++) { bytes.push((val.words[i]>>24)&0xff, (val.words[i]>>16)&0xff, (val.words[i]>>8)&0xff, val.words[i]&0xff); }
          return val.sigBytes !== undefined ? bytes.slice(0, val.sigBytes) : bytes;
        }
        if (typeof val === 'string') return _aesUtf8ToBytes(val);
        if (Array.isArray(val)) return val;
        if (typeof val === 'number') return [val];
        return [];
      }
    ''';

    // Step 4: _AES public API
    const aesStep4 = '''
      var _AES = {
        encrypt: function(data, key, iv, mode) {
          mode = mode || 'CBC';
          var kb = _aesParseKey(key), ivb = iv ? _aesParseKey(iv) : [];
          var db = (typeof data === 'string') ? _aesUtf8ToBytes(data) : data;
          var nr = kb.length/4 + 6, w = _aesKeyExpansion(kb), padded = _aesPkcs7Pad(db), encrypted = [];
          if (mode === 'ECB') { for (var i=0;i<padded.length;i+=16) { encrypted=encrypted.concat(_aesEncryptBlock(padded.slice(i,i+16),w,nr)); } }
          else { var prev=ivb.length>=16?ivb.slice(0,16):new Array(16).fill(0); for (var i=0;i<padded.length;i+=16) { var block=padded.slice(i,i+16); for (var j=0;j<16;j++) block[j]^=prev[j]; var enc=_aesEncryptBlock(block,w,nr); encrypted=encrypted.concat(enc); prev=enc; } }
          return _aesBytesToBase64(encrypted);
        },
        decrypt: function(data, key, iv, mode) {
          mode = mode || 'CBC';
          var kb = _aesParseKey(key), ivb = iv ? _aesParseKey(iv) : [];
          var db = (typeof data === 'string') ? _aesBase64ToBytes(data) : data;
          var nr = kb.length/4 + 6, w = _aesKeyExpansion(kb), decrypted = [];
          if (mode === 'ECB') { for (var i=0;i<db.length;i+=16) { decrypted=decrypted.concat(_aesDecryptBlock(db.slice(i,i+16),w,nr)); } }
          else { var prev=ivb.length>=16?ivb.slice(0,16):new Array(16).fill(0); for (var i=0;i<db.length;i+=16) { var block=db.slice(i,i+16); var dec=_aesDecryptBlock(block,w,nr); for (var j=0;j<16;j++) dec[j]^=prev[j]; decrypted=decrypted.concat(dec); prev=block; } }
          return _aesBytesToUtf8(_aesPkcs7Unpad(decrypted));
        },
        utf8Parse: function(str) {
          var bytes = _aesUtf8ToBytes(str), words = [];
          for (var i = 0; i < bytes.length; i += 4) { words.push(((bytes[i]||0)<<24)|((bytes[i+1]||0)<<16)|((bytes[i+2]||0)<<8)|(bytes[i+3]||0)); }
          return { words: words, sigBytes: bytes.length };
        },
        base64Parse: function(str) {
          var bytes = _aesBase64ToBytes(str), words = [];
          for (var i = 0; i < bytes.length; i += 4) { words.push(((bytes[i]||0)<<24)|((bytes[i+1]||0)<<16)|((bytes[i+2]||0)<<8)|(bytes[i+3]||0)); }
          return { words: words, sigBytes: bytes.length };
        },
      };
    ''';

    // 分步注入，每步独立 try-catch
    try {
      evaluate(aesStep1);
      evaluate(aesStep2);
      evaluate(aesStep3);
      evaluate(aesStep4);
      final aesCheck = evaluate('typeof _AES !== "undefined"');
      if (aesCheck == 'true') {
        // _AES 引擎注入成功
      } else {
        _injectAesFallback();
      }
    } catch (e) {
      _injectAesFallback();
    }
  }

  /// AES 引擎注入失败时的简化 fallback
  void _injectAesFallback() {
    evaluate('var _AES = { encrypt: function(d,k,iv,m) { return ""; }, decrypt: function(d,k,iv,m) { return ""; }, utf8Parse: function(s) { return s; }, base64Parse: function(s) { return s; } };');
  }

  /// 注入纯 JS MD5 引擎
  void _injectMd5Engine() {
    const md5Code = '''
      var _MD5 = (function() {
        function safeAdd(x, y) { var l = (x & 0xFFFF) + (y & 0xFFFF), m = (x >> 16) + (y >> 16) + (l >> 16); return (m << 16) | (l & 0xFFFF); }
        function bitRotateLeft(n, c) { return (n << c) | (n >>> (32 - c)); }
        function md5cmn(q, a, b, x, s, t) { return safeAdd(bitRotateLeft(safeAdd(safeAdd(a, q), safeAdd(x, t)), s), b); }
        function md5ff(a, b, c, d, x, s, t) { return md5cmn((b & c) | ((~b) & d), a, b, x, s, t); }
        function md5gg(a, b, c, d, x, s, t) { return md5cmn((b & d) | (c & (~d)), a, b, x, s, t); }
        function md5hh(a, b, c, d, x, s, t) { return md5cmn(b ^ c ^ d, a, b, x, s, t); }
        function md5ii(a, b, c, d, x, s, t) { return md5cmn(c ^ (b | (~d)), a, b, x, s, t); }
        function binlMD5(x, len) {
          x[len >> 5] |= 0x80 << (len % 32);
          x[(((len + 64) >>> 9) << 4) + 14] = len;
          var a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
          for (var i = 0; i < x.length; i += 16) {
            var oa = a, ob = b, oc = c, od = d;
            a=md5ff(a,b,c,d,x[i],7,-680876936); d=md5ff(d,a,b,c,x[i+1],12,-389564586); c=md5ff(c,d,a,b,x[i+2],17,606105819); b=md5ff(b,c,d,a,x[i+3],22,-1044525330);
            a=md5ff(a,b,c,d,x[i+4],7,-176418897); d=md5ff(d,a,b,c,x[i+5],12,1200080426); c=md5ff(c,d,a,b,x[i+6],17,-1473231341); b=md5ff(b,c,d,a,x[i+7],22,-45705983);
            a=md5ff(a,b,c,d,x[i+8],7,1770035416); d=md5ff(d,a,b,c,x[i+9],12,-1958414417); c=md5ff(c,d,a,b,x[i+10],17,-42063); b=md5ff(b,c,d,a,x[i+11],22,-1990404162);
            a=md5ff(a,b,c,d,x[i+12],7,1804603682); d=md5ff(d,a,b,c,x[i+13],12,-40341101); c=md5ff(c,d,a,b,x[i+14],17,-1502002290); b=md5ff(b,c,d,a,x[i+15],22,1236535329);
            a=md5gg(a,b,c,d,x[i+1],5,-165796510); d=md5gg(d,a,b,c,x[i+6],9,-1069501632); c=md5gg(c,d,a,b,x[i+11],14,643717713); b=md5gg(b,c,d,a,x[i],20,-373897302);
            a=md5gg(a,b,c,d,x[i+5],5,-701558691); d=md5gg(d,a,b,c,x[i+10],9,38016083); c=md5gg(c,d,a,b,x[i+15],14,-660478335); b=md5gg(b,c,d,a,x[i+4],20,-405537848);
            a=md5gg(a,b,c,d,x[i+9],5,568446438); d=md5gg(d,a,b,c,x[i+14],9,-1019803690); c=md5gg(c,d,a,b,x[i+3],14,-187363961); b=md5gg(b,c,d,a,x[i+8],20,1163531501);
            a=md5gg(a,b,c,d,x[i+13],5,-1444681467); d=md5gg(d,a,b,c,x[i+2],9,-51403784); c=md5gg(c,d,a,b,x[i+7],14,1735328473); b=md5gg(b,c,d,a,x[i+12],20,-1926607734);
            a=md5hh(a,b,c,d,x[i+5],4,-378558); d=md5hh(d,a,b,c,x[i+8],11,-2022574463); c=md5hh(c,d,a,b,x[i+11],16,1839030562); b=md5hh(b,c,d,a,x[i+14],23,-35309556);
            a=md5hh(a,b,c,d,x[i+1],4,-1530992060); d=md5hh(d,a,b,c,x[i+4],11,1272893353); c=md5hh(c,d,a,b,x[i+7],16,-155497632); b=md5hh(b,c,d,a,x[i+10],23,-1094730640);
            a=md5hh(a,b,c,d,x[i+13],4,681279174); d=md5hh(d,a,b,c,x[i],11,-358537222); c=md5hh(c,d,a,b,x[i+3],16,-722521979); b=md5hh(b,c,d,a,x[i+6],23,76029189);
            a=md5hh(a,b,c,d,x[i+9],4,-640364487); d=md5hh(d,a,b,c,x[i+12],11,-421815835); c=md5hh(c,d,a,b,x[i+15],16,530742520); b=md5hh(b,c,d,a,x[i+2],23,-995338651);
            a=md5ii(a,b,c,d,x[i],6,-198630844); d=md5ii(d,a,b,c,x[i+7],10,1126891415); c=md5ii(c,d,a,b,x[i+14],15,-1416354905); b=md5ii(b,c,d,a,x[i+5],21,-57434055);
            a=md5ii(a,b,c,d,x[i+12],6,1700485571); d=md5ii(d,a,b,c,x[i+3],10,-1894986606); c=md5ii(c,d,a,b,x[i+10],15,-1051523); b=md5ii(b,c,d,a,x[i+1],21,-2054922799);
            a=md5ii(a,b,c,d,x[i+8],6,1873313359); d=md5ii(d,a,b,c,x[i+15],10,-30611744); c=md5ii(c,d,a,b,x[i+6],15,-1560198380); b=md5ii(b,c,d,a,x[i+13],21,1309151649);
            a=md5ii(a,b,c,d,x[i+4],6,-145523070); d=md5ii(d,a,b,c,x[i+11],10,-1120210379); c=md5ii(c,d,a,b,x[i+2],15,718787259); b=md5ii(b,c,d,a,x[i+9],21,-343485551);
            a=safeAdd(a,oa); b=safeAdd(b,ob); c=safeAdd(c,oc); d=safeAdd(d,od);
          }
          return [a, b, c, d];
        }
        function binl2rstr(input) {
          var output = '';
          for (var i = 0; i < input.length * 32; i += 8) output += String.fromCharCode((input[i >> 5] >>> (i % 32)) & 0xFF);
          return output;
        }
        function rstr2binl(input) {
          var output = [];
          for (var i = 0; i < input.length * 8; i += 32) output[i >> 5] = 0;
          for (var i = 0; i < input.length * 8; i += 8) output[i >> 5] |= (input.charCodeAt(i / 8) & 0xFF) << (i % 32);
          return output;
        }
        function rstrMD5(s) { return binl2rstr(binlMD5(rstr2binl(s), s.length * 8)); }
        function rstr2hex(input) {
          var hexTab = '0123456789abcdef', output = '';
          for (var i = 0; i < input.length; i++) {
            var x = input.charCodeAt(i);
            output += hexTab.charAt((x >>> 4) & 0x0F) + hexTab.charAt(x & 0x0F);
          }
          return output;
        }
        function str2rstrUTF8(input) {
          return unescape(encodeURIComponent(input));
        }
        return function(str) { return rstr2hex(rstrMD5(str2rstrUTF8(str))); };
      })();
    ''';
    try {
      evaluate(md5Code);
      final check = evaluate('typeof _MD5 !== "undefined"');
      if (check == 'true') {
        // _MD5 引擎注入成功
      } else {
      }
    } catch (e) {
    }
  }

  /// 注入纯 JS SHA1/SHA256/HMAC-SHA256 引擎
  void _injectShaEngine() {
    const shaCode = '''
      var _SHA1 = (function() {
        function rotateLeft(n, c) { return (n << c) | (n >>> (32 - c)); }
        function utf8Encode(str) { return unescape(encodeURIComponent(str)); }
        function str2binb(str) {
          var bin = [], mask = (1 << 8) - 1;
          for (var i = 0; i < str.length * 8; i += 8)
            bin[i >> 5] |= (str.charCodeAt(i / 8) & mask) << (24 - i % 32);
          return bin;
        }
        function binb2hex(binarray) {
          var hexTab = '0123456789abcdef', str = '';
          for (var i = 0; i < binarray.length * 4; i++) {
            str += hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8 + 4)) & 0xF) +
                   hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8)) & 0xF);
          }
          return str;
        }
        function sha1Core(x, len) {
          x[len >> 5] |= 0x80 << (24 - len % 32);
          x[((len + 64 >> 9) << 4) + 15] = len;
          var w = [], a = 1732584193, b = -271733879, c = -1732584194, d = 271733878, e = -1009589776;
          for (var i = 0; i < x.length; i += 16) {
            var oa = a, ob = b, oc = c, od = d, oe = e;
            for (var j = 0; j < 80; j++) {
              if (j < 16) w[j] = x[i + j];
              else w[j] = rotateLeft(w[j-3] ^ w[j-8] ^ w[j-14] ^ w[j-16], 1);
              var t = rotateLeft(a, 5) + ((j < 20) ? (b & c | ~b & d) + 1518500249 :
                      (j < 40) ? (b ^ c ^ d) + 1859775393 :
                      (j < 60) ? (b & c | b & d | c & d) - 1894007588 :
                                 (b ^ c ^ d) - 899497514) + e + w[j];
              e = d; d = c; c = rotateLeft(b, 30); b = a; a = t;
            }
            a += oa; b += ob; c += oc; d += od; e += oe;
          }
          return [a, b, c, d, e];
        }
        return function(str) {
          var s = utf8Encode(str);
          return binb2hex(sha1Core(str2binb(s), s.length * 8));
        };
      })();

      var _SHA256 = (function() {
        var K = [
          0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
          0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
          0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
          0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
          0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
          0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
          0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
          0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
        ];
        function rightRotate(n, c) { return (n >>> c) | (n << (32 - c)); }
        function utf8Encode(str) { return unescape(encodeURIComponent(str)); }
        function str2binb(str) {
          var bin = [], mask = (1 << 8) - 1;
          for (var i = 0; i < str.length * 8; i += 8)
            bin[i >> 5] |= (str.charCodeAt(i / 8) & mask) << (24 - i % 32);
          return bin;
        }
        function binb2hex(binarray) {
          var hexTab = '0123456789abcdef', str = '';
          for (var i = 0; i < binarray.length * 4; i++) {
            str += hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8 + 4)) & 0xF) +
                   hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8)) & 0xF);
          }
          return str;
        }
        return function(str) {
          var s = utf8Encode(str);
          var M = str2binb(s), l = s.length * 8;
          M[l >> 5] |= 0x80 << (24 - l % 32);
          M[((l + 64 >> 9) << 4) + 15] = l;
          var H0 = 0x6a09e667, H1 = 0xbb67ae85, H2 = 0x3c6ef372, H3 = 0xa54ff53a;
          var H4 = 0x510e527f, H5 = 0x9b05688c, H6 = 0x1f83d9ab, H7 = 0x5be0cd19;
          for (var i = 0; i < M.length; i += 16) {
            var a=H0,b=H1,c=H2,d=H3,e=H4,f=H5,g=H6,h=H7;
            var W = [];
            for (var t = 0; t < 64; t++) {
              if (t < 16) W[t] = M[i + t];
              else {
                var s0 = rightRotate(W[t-15],7) ^ rightRotate(W[t-15],18) ^ (W[t-15] >>> 3);
                var s1 = rightRotate(W[t-2],17) ^ rightRotate(W[t-2],19) ^ (W[t-2] >>> 10);
                W[t] = (W[t-16] + s0 + W[t-7] + s1) | 0;
              }
              var ch = (e & f) ^ (~e & g);
              var maj = (a & b) ^ (a & c) ^ (b & c);
              var S0 = rightRotate(a,2) ^ rightRotate(a,13) ^ rightRotate(a,22);
              var S1 = rightRotate(e,6) ^ rightRotate(e,11) ^ rightRotate(e,25);
              var T1 = (h + S1 + ch + K[t] + W[t]) | 0;
              var T2 = (S0 + maj) | 0;
              h=g; g=f; f=e; e=(d+T1)|0; d=c; c=b; b=a; a=(T1+T2)|0;
            }
            H0=(H0+a)|0; H1=(H1+b)|0; H2=(H2+c)|0; H3=(H3+d)|0;
            H4=(H4+e)|0; H5=(H5+f)|0; H6=(H6+g)|0; H7=(H7+h)|0;
          }
          return binb2hex([H0,H1,H2,H3,H4,H5,H6,H7]);
        };
      })();

      var _HMACSHA256 = (function() {
        return function(data, key) {
          var sha256 = _SHA256;
          var blocksize = 64;
          var kStr = unescape(encodeURIComponent(key));
          var dStr = unescape(encodeURIComponent(data));
          if (kStr.length > blocksize) kStr = sha256(key);
          while (kStr.length < blocksize) kStr += '\\x00';
          var oKeyPad = '', iKeyPad = '';
          for (var i = 0; i < blocksize; i++) {
            oKeyPad += String.fromCharCode(kStr.charCodeAt(i) ^ 0x5c);
            iKeyPad += String.fromCharCode(kStr.charCodeAt(i) ^ 0x36);
          }
          var innerHash = sha256(iKeyPad + dStr);
          return sha256(oKeyPad + hexStr2Str(innerHash));
        };
        function hexStr2Str(hex) {
          var str = '';
          for (var i = 0; i < hex.length; i += 2)
            str += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
          return str;
        }
      })();
    ''';
    try {
      evaluate(shaCode);
      final check = evaluate('typeof _SHA1 !== "undefined" && typeof _SHA256 !== "undefined" && typeof _HMACSHA256 !== "undefined"');
      if (check == 'true') {
        // SHA 引擎注入成功
      } else {
      }
    } catch (e) {
    }
  }

  // ===== Java 桥接对象（QuickJS 侧）=====

  void _injectJavaBridge() {
    // 拆分注入：先注入基础变量，再注入 AES 引擎，再注入 java 对象，最后注入 CryptoJS
    // 每步独立 try-catch，避免一步失败导致全部丢失

    // 1. 注入 _javaCache 基础变量
    try {
      evaluate('if (typeof _javaCache === "undefined") var _javaCache = {};');
    } catch (e) {
      try { evaluate('var _javaCache = {};'); } catch (_) {}
    }

    // 2. 注入纯 JS AES 引擎（不依赖 Dart 桥接，QuickJS 同步可用）
    _injectAesEngine();

    // 2.5 注入纯 JS MD5 引擎
    _injectMd5Engine();

    // 2.6 注入纯 JS SHA1/SHA256/HMAC-SHA256 引擎
    _injectShaEngine();
    // 注意：不能使用 const，因为字符串中包含 $ 符号（JS 正则替换引用 $&）
    // _JsoupLite 使用 raw string 避免JS正则中的$被Dart解析为插值
    final jsoupLiteCode = r"""
      var _JsoupLite = {
        _voidElements: ['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'],
        // 自动关闭：遇到同标签时自动关闭前一个（HTML5 隐式关闭规则）
        _autoCloseTags: ['option','optgroup','li','tr','td','th','dt','dd','p','rt','rp'],
        _debug: false,
        _log: function(msg) { if (_JsoupLite._debug) console.log('[JsoupLite] ' + msg); },
        _hashStr: function(s) {
          var h = 0;
          for (var i = 0; i < s.length; i++) {
            h = ((h << 5) - h + s.charCodeAt(i)) | 0;
          }
          return h;
        },
        _cacheKey: function(prefix, selector, html) {
          return prefix + ':' + selector + ':' + _JsoupLite._hashStr(html || '');
        },
        // 栈式 HTML 解析器，正确处理 void 元素和文本
        _parseHtml: function(html) {
          if (!html) return [];
          var nodes = [];
          var tagRe = /<([\/!]?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^>]*?)?)(\/?)>/g;
          var lastIdx = 0;
          var stack = [];
          var m;
          while ((m = tagRe.exec(html)) !== null) {
            // 文本节点
            if (m.index > lastIdx) {
              var txt = html.substring(lastIdx, m.index);
              if (stack.length > 0) {
                stack[stack.length - 1].childNodes.push({type: 'text', text: txt});
              }
            }
            lastIdx = m.index + m[0].length;
            var isClose = m[1] === '/';
            var tagName = m[2].toLowerCase();
            var attrStr = m[3] || '';
            var isSelfClose = m[4] === '/';
            // 跳过注释和 <!DOCTYPE>
            if (m[1] === '!' || tagName === '!doctype') continue;
            if (isClose) {
              // 弹栈，找到匹配的开标签
              var found = -1;
              for (var si = stack.length - 1; si >= 0; si--) {
                if (stack[si].tag === tagName) { found = si; break; }
              }
              if (found >= 0) {
                // 先把 found 之上的未关闭子元素归入 found 的 childNodes
                // （例如 </ul> 关闭时，栈上未关闭的 <li> 应成为 <ul> 的子节点）
                while (stack.length > found + 1) {
                  var orphan = stack.pop();
                  stack[found].childNodes.push(orphan);
                }
                var closed = stack.pop(); // 取出匹配的父元素
                if (stack.length > 0) {
                  stack[stack.length - 1].childNodes.push(closed);
                } else {
                  nodes.push(closed);
                }
              }
              continue;
            }
            // 解析属性
            var attrs = {};
            var attrRe = /([a-zA-Z_][\w-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|(\S+)))?/g;
            var am;
            while ((am = attrRe.exec(attrStr)) !== null) {
              attrs[am[1].toLowerCase()] = am[2] !== undefined ? am[2] : (am[3] !== undefined ? am[3] : (am[4] !== undefined ? am[4] : ''));
            }
            var node = {tag: tagName, attrs: attrs, childNodes: [], parent: stack.length > 0 ? stack[stack.length - 1] : null};
            // void 元素或自闭合标签不入栈
            if (isSelfClose || _JsoupLite._voidElements.indexOf(tagName) >= 0) {
              if (stack.length > 0) {
                stack[stack.length - 1].childNodes.push(node);
              } else {
                nodes.push(node);
              }
            } else {
              // HTML5 隐式关闭：遇到同类标签时自动关闭前一个
              // 例如：<option>A<option>B → <option>A</option><option>B
              if (_JsoupLite._autoCloseTags.indexOf(tagName) >= 0) {
                for (var si = stack.length - 1; si >= 0; si--) {
                  if (stack[si].tag === tagName) {
                    // 先把 si 之上的未关闭子元素归入 si 的 childNodes
                    while (stack.length > si + 1) {
                      var orphan = stack.pop();
                      stack[si].childNodes.push(orphan);
                    }
                    var closed = stack.pop();
                    if (stack.length > 0) {
                      stack[stack.length - 1].childNodes.push(closed);
                    } else {
                      nodes.push(closed);
                    }
                    break;
                  }
                }
              }
              stack.push(node);
            }
          }
          // 处理栈中剩余节点
          while (stack.length > 0) {
            var remaining = stack.pop();
            if (stack.length > 0) {
              stack[stack.length - 1].childNodes.push(remaining);
            } else {
              nodes.push(remaining);
            }
          }
          return nodes;
        },
        // 获取元素子节点（不含文本节点）
        _elementChildren: function(node) {
          if (!node || !node.childNodes) return [];
          return node.childNodes.filter(function(c) { return c.tag; });
        },
        // 获取文本内容（递归）
        _getText: function(node) {
          if (!node) return '';
          if (node.type === 'text') return node.text || '';
          if (!node.childNodes) return '';
          var text = '';
          for (var i = 0; i < node.childNodes.length; i++) {
            text += _JsoupLite._getText(node.childNodes[i]);
          }
          return text;
        },
        // 获取 outerHtml（递归重建）
        _getOuterHtml: function(node) {
          if (!node) return '';
          if (node.type === 'text') return node.text || '';
          var html = '<' + node.tag;
          for (var key in node.attrs) {
            html += ' ' + key + '="' + (node.attrs[key] || '').replace(/"/g, '&quot;') + '"';
          }
          html += '>';
          if (_JsoupLite._voidElements.indexOf(node.tag) >= 0) return html;
          for (var i = 0; i < node.childNodes.length; i++) {
            html += _JsoupLite._getOuterHtml(node.childNodes[i]);
          }
          html += '</' + node.tag + '>';
          return html;
        },
        // 拆分选择器中的伪类
        _splitPseudo: function(sel) {
          var m = sel.match(/^(.+?):(nth-child|nth-of-type)\((.+)\)$/);
          if (m) return {base: m[1], pseudo: m[2], expr: m[3]};
          return {base: sel, pseudo: null, expr: null};
        },
        // 匹配基础选择器（不含伪类）
        _matchesBase: function(node, selector) {
          if (!node || !node.tag) return false;
          var sel = selector.trim();
          // 空选择器匹配任何元素（用于 getAttr/selectFirst 从根元素自身取值）
          if (!sel) return true;
          // #id
          if (sel.startsWith('#') && sel.indexOf('.') < 0 && sel.indexOf('[') < 0) {
            return node.attrs['id'] === sel.substring(1);
          }
          // [attr$=val] 裸属性选择器
          var bareAttr = sel.match(/^\[([a-zA-Z_][\w-]*)([$^*]?=)["']?([^"'\]]*)["']?\]$/);
          if (bareAttr) {
            var val = node.attrs[bareAttr[1].toLowerCase()] || '';
            var op = bareAttr[2], bv = bareAttr[3];
            if (op === '=') return val === bv;
            if (op === '$=') return val.endsWith(bv);
            if (op === '^=') return val.startsWith(bv);
            if (op === '*=') return val.indexOf(bv) >= 0;
            return false;
          }
          // tag[attr$=val]
          var tagAttr = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)\[([a-zA-Z_][\w-]*)([$^*]?=)["']?([^"'\]]*)["']?\]$/);
          if (tagAttr) {
            if (node.tag !== tagAttr[1].toLowerCase()) return false;
            var av = node.attrs[tagAttr[2].toLowerCase()] || '';
            var aop = tagAttr[3], aval = tagAttr[4];
            if (aop === '=') return av === aval;
            if (aop === '$=') return av.endsWith(aval);
            if (aop === '^=') return av.startsWith(aval);
            if (aop === '*=') return av.indexOf(aval) >= 0;
            return false;
          }
          // tag.class
          var tagCls = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)\.([a-zA-Z_-][\w-]*)$/);
          if (tagCls) {
            if (node.tag !== tagCls[1].toLowerCase()) return false;
            var nc = (node.attrs['class'] || '').split(/\s+/);
            return nc.indexOf(tagCls[2]) >= 0;
          }
          // tag#id
          var tagId = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)#([a-zA-Z_-][\w-]*)$/);
          if (tagId) {
            return node.tag === tagId[1].toLowerCase() && node.attrs['id'] === tagId[2];
          }
          // .class（支持多类 .c1.c2）
          if (sel.startsWith('.')) {
            var classes = sel.substring(1).split('.');
            var nodeClasses = (node.attrs['class'] || '').split(/\s+/);
            for (var i = 0; i < classes.length; i++) {
              if (classes[i] && nodeClasses.indexOf(classes[i]) < 0) return false;
            }
            return true;
          }
          // 纯 tag
          if (/^[a-zA-Z][a-zA-Z0-9]*$/.test(sel)) {
            return node.tag === sel.toLowerCase();
          }
          return false;
        },
        // 解析 nth-child 表达式
        _resolveNth: function(expr, idx) {
          expr = expr.trim().replace(/\s+/g, '');
          if (expr === String(idx)) return true;
          if (expr === 'odd') return idx % 2 === 1;
          if (expr === 'even') return idx % 2 === 0;
          var m = expr.match(/^(-?\d*)n([+-]\d+)?$/);
          if (m) {
            var a = m[1] === '' ? 1 : (m[1] === '-' ? -1 : parseInt(m[1]));
            var b = m[2] ? parseInt(m[2]) : 0;
            if (a === 0) return idx === b;
            var n = (idx - b) / a;
            return n >= 0 && n === Math.floor(n);
          }
          return false;
        },
        // 核心查询：在节点树中查找匹配选择器的所有元素
        _queryAll: function(nodes, selector, depth) {
          depth = depth || 0;
          if (depth > 30 || !nodes) return [];
          var results = [];

          // 处理逗号分隔的多选择器
          if (selector.indexOf(',') >= 0 && selector.indexOf('(') < 0) {
            var sels = selector.split(',');
            for (var si = 0; si < sels.length; si++) {
              var r = _JsoupLite._queryAll(nodes, sels[si].trim(), depth + 1);
              for (var ri = 0; ri < r.length; ri++) {
                if (results.indexOf(r[ri]) < 0) results.push(r[ri]);
              }
            }
            return results;
          }

          // 处理子选择器 (> combinator)
          if (selector.indexOf(' > ') >= 0) {
            var childParts = selector.split(/\s*>\s*/);
            // 关键修复：第一步用后代搜索（_queryAll 递归查找），不是只看直接子元素
            // 例如 ".row:nth-child(2) > .col-12" 中 .row 可能嵌套在 html>body>div 下
            var current = _JsoupLite._queryAll(nodes, childParts[0].trim(), depth + 1);
            // 后续步骤：在匹配元素的直接子元素中查找
            for (var cp = 1; cp < childParts.length; cp++) {
              var partSel = childParts[cp].trim();
              var next = [];
              for (var ci = 0; ci < current.length; ci++) {
                var elChildren = _JsoupLite._elementChildren(current[ci]);
                var matched = _JsoupLite._filterBySelector(elChildren, partSel, current[ci]);
                next = next.concat(matched);
              }
              current = next;
            }
            return current;
          }

          // 处理后代选择器 (空格分隔)
          var parts = selector.split(/\s+/);
          if (parts.length > 1) {
            var cur = nodes;
            for (var pi = 0; pi < parts.length; pi++) {
              var pSel = parts[pi].trim();
              if (!pSel) continue;
              var found = _JsoupLite._queryAll(cur, pSel, depth + 1);
              if (pi < parts.length - 1) {
                // 收集所有后代
                var desc = [];
                for (var fi = 0; fi < found.length; fi++) {
                  _JsoupLite._collectAllElements(found[fi], desc);
                }
                cur = desc;
              } else {
                cur = found;
              }
            }
            return cur;
          }

          // 单一选择器：深度优先遍历
          var sp = _JsoupLite._splitPseudo(selector);
          for (var ni = 0; ni < nodes.length; ni++) {
            var node = nodes[ni];
            if (!node.tag) continue;
            if (_JsoupLite._matchesBase(node, sp.base)) {
              if (sp.pseudo) {
                var parent = node.parent;
                if (parent) {
                  var siblings = _JsoupLite._elementChildren(parent);
                  if (sp.pseudo === 'nth-child') {
                    // CSS 规范：:nth-child 计数所有兄弟元素，不只是匹配基础选择器的
                    var pos = 0;
                    for (var si2 = 0; si2 < siblings.length; si2++) {
                      pos++;
                      if (siblings[si2] === node) {
                        if (_JsoupLite._resolveNth(sp.expr, pos)) results.push(node);
                        break;
                      }
                    }
                  } else if (sp.pseudo === 'nth-of-type') {
                    // :nth-of-type 计数同类型（同标签名）的兄弟元素
                    var pos2 = 0;
                    for (var si3 = 0; si3 < siblings.length; si3++) {
                      if (siblings[si3].tag === node.tag) {
                        pos2++;
                        if (siblings[si3] === node) {
                          if (_JsoupLite._resolveNth(sp.expr, pos2)) results.push(node);
                          break;
                        }
                      }
                    }
                  }
                } else {
                  results.push(node);
                }
              } else {
                results.push(node);
              }
            }
            // 递归搜索子节点
            var childResults = _JsoupLite._queryAll(_JsoupLite._elementChildren(node), selector, depth + 1);
            results = results.concat(childResults);
          }
          return results;
        },
        // 在同级元素中按选择器过滤（含伪类）
        _filterBySelector: function(elements, selector, parent) {
          var sp = _JsoupLite._splitPseudo(selector);
          var matched = [];
          if (sp.pseudo === 'nth-child') {
            // CSS 规范：:nth-child 计数所有兄弟元素
            var pos = 0;
            for (var i = 0; i < elements.length; i++) {
              pos++;
              if (_JsoupLite._matchesBase(elements[i], sp.base)) {
                if (_JsoupLite._resolveNth(sp.expr, pos)) {
                  matched.push(elements[i]);
                }
              }
            }
          } else if (sp.pseudo === 'nth-of-type') {
            // :nth-of-type 计数同类型（同标签名）的兄弟元素
            var typePos = {};
            for (var j = 0; j < elements.length; j++) {
              var tag = elements[j].tag || '';
              if (!typePos[tag]) typePos[tag] = 0;
              typePos[tag]++;
              if (_JsoupLite._matchesBase(elements[j], sp.base)) {
                if (_JsoupLite._resolveNth(sp.expr, typePos[tag])) {
                  matched.push(elements[j]);
                }
              }
            }
          } else {
            for (var k = 0; k < elements.length; k++) {
              if (_JsoupLite._matchesBase(elements[k], sp.base)) {
                matched.push(elements[k]);
              }
            }
          }
          return matched;
        },
        // 收集节点下所有元素（深度优先）
        _collectAllElements: function(node, arr) {
          if (!node || !node.childNodes) return;
          var children = _JsoupLite._elementChildren(node);
          for (var i = 0; i < children.length; i++) {
            arr.push(children[i]);
            _JsoupLite._collectAllElements(children[i], arr);
          }
        },
        // ===== 公共 API =====
        selectFirst: function(html, selector) {
          var key = _JsoupLite._cacheKey('jsoup_sf', selector, html);
          if (_javaCache[key] !== undefined) return _javaCache[key];
          var nodes = _JsoupLite._parseHtml(html);
          var found = _JsoupLite._queryAll(nodes, selector, 0);
          var result = found.length > 0 ? _JsoupLite._getText(found[0]) : '';
          return result;
        },
        selectAll: function(html, selector) {
          var key = _JsoupLite._cacheKey('jsoup_sa', selector, html);
          if (_javaCache[key] !== undefined) return _javaCache[key];
          var nodes = _JsoupLite._parseHtml(html);
          var found = _JsoupLite._queryAll(nodes, selector, 0);
          var result = found.map(function(n) { return _JsoupLite._getOuterHtml(n); });
          return result;
        },
        getAttr: function(html, selector, attr) {
          var key = _JsoupLite._cacheKey('jsoup_ga', selector + ':' + attr, html);
          if (_javaCache[key] !== undefined) return _javaCache[key];
          var nodes = _JsoupLite._parseHtml(html);
          var found = _JsoupLite._queryAll(nodes, selector, 0);
          var result = found.length > 0 ? (found[0].attrs[attr] || '') : '';
          return result;
        }
      };
    """;

    final helperCode = """
      // ===== Legado Java 桥接对象（QuickJS 侧）=====
      // 借鉴 legado 的 JsExtensions 接口，通过 Dart 侧 NativeChannel 桥接
      // 核心策略：同步模式从 _javaCache 取缓存值，异步模式由 Dart 端预缓存
      // _javaCache 已在前面注入，这里不再重复声明

      // ===== _JsoupLite 已在 jsoupLiteCode 中注入 =====

      var java = {
        // ===== HTTP 请求方法（核心，对齐 legado JsExtensions）=====
        // 辅助：构建 StrResponse 对象（对齐 legado 的 StrResponse）
        // legado 书源经常用 java.connect(url).body / .url / .headerMap
        _buildResponse: function(body, url, headers) {
          return {
            body: body || '',
            url: url || '',
            headerMap: headers || {},
            html: body || '',
            toString: function() { return this.body; },
            getHeader: function(name) { return this.headerMap[name] || ''; }
          };
        },
        get: function(url, headers) {
          var fullUrl = url;
          if (url && !url.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
            fullUrl = baseUrl.replace(/\\/+\$/, '') + '/' + url.replace(/^\\/+/, '');
          }
          var cacheKey = 'http_get:' + fullUrl;
          if (_javaCache[cacheKey] !== undefined) {
            var cached = _javaCache[cacheKey];
            if (typeof cached === 'object' && cached !== null && 'body' in cached) return cached;
            return java._buildResponse(cached, fullUrl, {});
          }
          if (fullUrl !== url) {
            var origKey = 'http_get:' + url;
            if (_javaCache[origKey] !== undefined) {
              var origCached = _javaCache[origKey];
              if (typeof origCached === 'object' && origCached !== null && 'body' in origCached) return origCached;
              return java._buildResponse(origCached, url, {});
            }
          }
          return java._buildResponse('', fullUrl, {});
        },
        post: function(url, body, headers) {
          var fullUrl = url;
          if (url && !url.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
            fullUrl = baseUrl.replace(/\\/+\$/, '') + '/' + url.replace(/^\\/+/, '');
          }
          var cacheKey = 'http_post:' + fullUrl;
          if (_javaCache[cacheKey] !== undefined) {
            var cached = _javaCache[cacheKey];
            if (typeof cached === 'object' && cached !== null && 'body' in cached) return cached;
            return java._buildResponse(cached, fullUrl, {});
          }
          if (fullUrl !== url) {
            var origKey = 'http_post:' + url;
            if (_javaCache[origKey] !== undefined) {
              var origCached = _javaCache[origKey];
              if (typeof origCached === 'object' && origCached !== null && 'body' in origCached) return origCached;
              return java._buildResponse(origCached, url, {});
            }
          }
          return java._buildResponse('', fullUrl, {});
        },
        // legado: ajax 返回 body 字符串（不是 Response 对象）
        ajax: function(url, headers) {
          var resp = java.get(url, headers);
          return (typeof resp === 'object' && resp !== null && 'body' in resp) ? resp.body : String(resp || '');
        },
        ajaxAll: function(urls) {
          if (!urls || !urls.length) return [];
          var results = [];
          for (var i = 0; i < urls.length; i++) {
            results.push(java.ajax(urls[i]));
          }
          return results;
        },
        // java.ajaxTestAll(urlList, timeout) / ajaxTestAll(urlList, timeout, skipRateLimit) — 批量测试 URL
        // 假声明：返回空结果数组，QuickJS 同步无法并发测试
        ajaxTestAll: function(urlList, timeout, skipRateLimit) {
          if (!urlList || !urlList.length) return [];
          var results = [];
          for (var i = 0; i < urlList.length; i++) {
            results.push({ url: urlList[i], body: java.ajax(urlList[i]), code: 200 });
          }
          return results;
        },

        // ===== 变量存取（借鉴 legado 的 CacheManager）=====
        put: function(key, value) {
          _javaCache[key] = typeof value === 'object' ? JSON.stringify(value) : String(value);
        },
        getStr: function(key, defaultValue) {
          return _javaCache[key] || (defaultValue || '');
        },
        getString: function(str, ruleStr) {
          // 借鉴 legado：单参数模式 java.getString(ruleStr)
          // 此时 str 是规则字符串，内容来自 result 变量
          // 双参数模式 java.getString(content, ruleStr)
          // 此时 str 是内容，ruleStr 是规则
          var content, rule;
          if (ruleStr === undefined || ruleStr === null) {
            // 单参数模式：str 是规则，内容来自 result
            rule = str;
            content = (typeof result !== 'undefined') ? result : '';
          } else {
            // 双参数模式
            content = str;
            rule = ruleStr;
          }

          if (!rule) return content || '';

          // @@ 前缀：去掉 @@ 后作为默认 CSS 规则
          if (rule.indexOf('@@') === 0) {
            rule = rule.substring(2);
          }

          // 借鉴 legado 的 JsExtensions.getString：支持 CSS/正则/JSON 规则
          if (rule.startsWith('@css:') || rule.startsWith('@CSS:')) {
            var cssSel = rule.substring(5);
            // 尝试从缓存获取 text
            var textKey = 'jsoup_text:' + cssSel + ':' + _JsoupLite._hashStr(content || '');
            if (_javaCache[textKey] !== undefined) return _javaCache[textKey];
            // 尝试从缓存获取 href
            var hrefKey = 'jsoup_href:' + cssSel + ':' + _JsoupLite._hashStr(content || '');
            if (_javaCache[hrefKey] !== undefined) return _javaCache[hrefKey];
            return _JsoupLite.selectFirst(content, cssSel);
          }
          if (rule.startsWith('@json:') || rule.startsWith('@JSON:')) {
            try {
              var data = (typeof content === 'string') ? JSON.parse(content) : content;
              var path = rule.substring(6).trim().replace(/^\$\./, '');
              var parts = path.split('.');
              var r = data;
              for (var i = 0; i < parts.length; i++) {
                if (r == null) return '';
                r = r[parts[i]];
              }
              return r != null ? String(r) : '';
            } catch(e) { return ''; }
          }
          // 正则规则
          if (rule.startsWith('@regex:') || rule.startsWith('@Regex:')) {
            try {
              var pattern = rule.substring(7);
              var m = String(content).match(new RegExp(pattern));
              return m ? (m[1] || m[0]) : '';
            } catch(e) { return ''; }
          }
          // 默认：CSS 选择器规则（legado 的 Default 模式）
          // 支持 #id、.class、tag、tag@attr、tag@sub@attr 等格式
          try {
            // 尝试从缓存获取 text
            var textKey2 = 'jsoup_text:' + rule + ':' + _JsoupLite._hashStr(content || '');
            if (_javaCache[textKey2] !== undefined) return _javaCache[textKey2];
            // 尝试从缓存获取 href
            var hrefKey2 = 'jsoup_href:' + rule + ':' + _JsoupLite._hashStr(content || '');
            if (_javaCache[hrefKey2] !== undefined) return _javaCache[hrefKey2];
            return _JsoupLite.selectFirst(content, rule);
          } catch(e) {}

          return String(content);
        },
        getStrResponse: function(url, ruleStr) {
          var html = java.ajax(url);
          if (ruleStr) return java.getString(html, ruleStr);
          return html;
        },
        getJson: function(str) {
          try { return JSON.parse(str); } catch(e) { return {}; }
        },
        putJson: function(key, value) {
          _javaCache[key] = JSON.stringify(value);
        },

        // ===== 加密/解密（优先走 CryptoJS.AES → __nativeCrypto C 原生）=====
        aesEncode: function(data, key, iv) {
          var cacheKey = 'aes_enc:' + data + ':' + key + ':' + (iv || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          try {
            var result;
            if (typeof CryptoJS !== 'undefined' && CryptoJS.AES) {
              // 走 CryptoJS.AES → __nativeCrypto.aesEncryptNative（C 原生，零 Dart 回调）
              var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
              result = CryptoJS.AES.encrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString();
            } else {
              // 回退：纯 JS _AES 引擎
              var mode = iv ? 'CBC' : 'ECB';
              result = _AES.encrypt(data, key, iv, mode);
            }
            _javaCache[cacheKey] = result;
            return result;
          } catch(e) { _jsLog('AES encrypt failed: ' + e, 'error'); return ''; }
        },
        aesDecode: function(data, key, iv) {
          var cacheKey = 'aes_dec:' + data + ':' + key + ':' + (iv || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          try {
            var result;
            // Phase 5: 全 C 直通（base64 → C 层一站式解码+解密 → ArrayBuffer → UTF-8 字符串）
            // 零 CryptoJS 包装层，零 JS UTF-8 parse/stringify
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto.aesDecryptFromBase64) {
              var plainU8 = iv
                ? __nativeCrypto.aesDecryptFromBase64(data, key, iv)
                : __nativeCrypto.aesDecryptFromBase64ECB(data, key);
              if (plainU8 && plainU8.byteLength > 0) {
                result = _u8ToStr(plainU8);
                if (result && result.length > 0) {
                  _javaCache[cacheKey] = result;
                  return result;
                }
              }
            }
            // 回退：走 CryptoJS.C 原生路径或纯 JS
            if (typeof CryptoJS !== 'undefined' && CryptoJS.AES) {
              var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
              result = CryptoJS.AES.decrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString(CryptoJS.enc.Utf8);
            } else {
              var mode = iv ? 'CBC' : 'ECB';
              result = _AES.decrypt(data, key, iv, mode);
            }
            _javaCache[cacheKey] = result;
            return result;
          } catch(e) { _jsLog('AES decrypt failed: ' + e, 'error'); return ''; }
        },
        // 全 C 直通 AES 解密：base64 密文 → Uint8Array（零 CryptoJS 包装层）
        // 用于图片解密等需要原始字节而不是字符串的场景
        aesDecodeBytes: function(data, key, iv) {
          try {
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto.aesDecryptFromBase64) {
              if (iv) {
                return __nativeCrypto.aesDecryptFromBase64(data, key, iv);
              } else {
                return __nativeCrypto.aesDecryptFromBase64ECB(data, key);
              }
            }
            // 回退：走标准 aesDecode 后转 bytes
            var s = java.aesDecode(data, key, iv);
            return _strToU8(s);
          } catch(e) { return new Uint8Array(0); }
        },
        md5Encode: function(str) {
          // 优先使用纯 JS _MD5 引擎，fallback 到缓存
          if (typeof _MD5 !== 'undefined') return _MD5(str);
          var cacheKey = 'md5:' + str;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        sha1Encode: function(str) {
          if (typeof _SHA1 !== 'undefined') return _SHA1(str);
          var cacheKey = 'sha1:' + str;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        sha256Encode: function(str) {
          if (typeof _SHA256 !== 'undefined') return _SHA256(str);
          var cacheKey = 'sha256:' + str;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        hmacSHA256: function(data, key) {
          if (typeof _HMACSHA256 !== 'undefined') return _HMACSHA256(data, key);
          var cacheKey = 'hmac_sha256:' + data + ':' + key;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.base64Encode(str) / base64Encode(str, flags) — Base64 编码
        // 假声明：兼容 Legado 多重载，flags 暂忽略（NO_WRAP/URL_SAFE 等统一标准 Base64）
        base64Encode: function(str, flags) {
          try {
            if (typeof btoa === 'function') return btoa(unescape(encodeURIComponent(str)));
          } catch(e) {}
          return '';
        },
        // java.base64Decode(str) / base64Decode(str, charset|flags) — Base64 解码
        // 假声明：兼容 Legado 多重载，charset 按 UTF-8，flags 忽略
        base64Decode: function(str, arg2) {
          try {
            if (typeof atob === 'function') return decodeURIComponent(escape(atob(str)));
          } catch(e) {}
          return '';
        },
        // java.hexDecodeToByteArray(hex) — Hex 解码为 ByteArray
        hexDecodeToByteArray: function(hex) {
          var s = java.hexDecodeToString(hex);
          return s ? java.strToBytes(s) : [];
        },

        // ===== HTML 解析（使用内置 _JsoupLite，不再递归自调用）=====
        jsoup: {
          parse: function(html) {
            return {
              html: html,
              select: function(sel) { return _JsoupLite.selectAll(html, sel); },
              selectFirst: function(sel) { return _JsoupLite.selectFirst(html, sel); },
              text: function() {
                // 简易去标签提取文本
                return (html || '').replace(/<[^>]+>/g, '').trim();
              },
            };
          },
          select: function(html, selector) {
            // 返回 HTML 元素数组（outerHtml），以便后续对每个元素做子查询
            return _JsoupLite.selectAll(html, selector);
          },
          selectFirst: function(html, selector) {
            var result = _JsoupLite.selectFirst(html, selector);
            // 返回文本内容（兼容 legado 行为：selectFirst 提取首个元素的文本）
            return result ? result.replace(/<[^>]+>/g, '').trim() : '';
          },
          getAttr: function(html, selector, attr) { return _JsoupLite.getAttr(html, selector, attr); },
          clean: function(html) {
            if (!html) return '';
            return html.replace(/<script[^>]*>[\\s\\S]*?<\\/script>/gi, '')
                       .replace(/<style[^>]*>[\\s\\S]*?<\\/style>/gi, '')
                       .replace(/<[^>]+>/g, '')
                       .replace(/&nbsp;/g, ' ')
                       .replace(/&amp;/g, '&')
                       .replace(/&lt;/g, '<')
                       .replace(/&gt;/g, '>')
                       .replace(/&quot;/g, '"')
                       .trim();
          },
        },

        // ===== 正则操作（QuickJS 原生支持）=====
        regex: {
          match: function(str, pattern) {
            try { var m = str.match(new RegExp(pattern)); return m ? m[0] : ''; } catch(e) { return ''; }
          },
          matchAll: function(str, pattern) {
            try { var results = []; var r = new RegExp(pattern, 'g'); var m; while(m = r.exec(str)) { results.push(m[0]); } return results; } catch(e) { return []; }
          },
          replace: function(str, pattern, replacement) {
            try { return str.replace(new RegExp(pattern, 'g'), replacement); } catch(e) { return str; }
          },
          test: function(str, pattern) {
            try { return new RegExp(pattern).test(str); } catch(e) { return false; }
          },
        },

        // ===== 时间/编码工具 =====
        timeFormat: function(timestamp, format) {
          var d = new Date(timestamp);
          if (!format) return d.toLocaleString();
          // 支持 yyyy-MM-dd HH:mm:ss 格式
          return format
            .replace(/yyyy/g, d.getFullYear())
            .replace(/MM/g, (d.getMonth() + 1).toString().padStart(2, '0'))
            .replace(/dd/g, d.getDate().toString().padStart(2, '0'))
            .replace(/HH/g, d.getHours().toString().padStart(2, '0'))
            .replace(/mm/g, d.getMinutes().toString().padStart(2, '0'))
            .replace(/ss/g, d.getSeconds().toString().padStart(2, '0'));
        },
        timeFormatUTC: function(timestamp, format, offset) {
          var d = new Date(timestamp);
          if (offset) {
            d = new Date(d.getTime() + offset * 3600000);
          }
          var year = d.getUTCFullYear().toString();
          return format
            .replace(/yyyy/g, year)
            .replace(/yy/g, year.slice(-2))
            .replace(/MM/g, (d.getUTCMonth() + 1).toString().padStart(2, '0'))
            .replace(/dd/g, d.getUTCDate().toString().padStart(2, '0'))
            .replace(/HH/g, d.getUTCHours().toString().padStart(2, '0'))
            .replace(/mm/g, d.getUTCMinutes().toString().padStart(2, '0'))
            .replace(/ss/g, d.getUTCSeconds().toString().padStart(2, '0'));
        },
        getTime: function() {
          return Date.now();
        },
        // java.encodeURI(str) / encodeURI(str, enc) — URL 编码
        // 假声明：兼容 Legado 多重载，enc 指定字符集，暂按 UTF-8 处理
        encodeURI: function(str, enc) {
          return encodeURIComponent(str);
        },
        hexEncodeToString: function(str) {
          var hex = '';
          for (var i = 0; i < str.length; i++) {
            hex += str.charCodeAt(i).toString(16).padStart(2, '0');
          }
          return hex;
        },
        hexDecodeToString: function(hex) {
          var str = '';
          for (var i = 0; i < hex.length; i += 2) {
            str += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
          }
          return str;
        },

        // ===== WebView（桥接到 NativeChannel，同步模式从缓存取）=====
        webview: {
          eval: function(url, js) {
            var cacheKey = 'webview:' + url + ':' + (js || '').length;
            if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
            return '';
          },
        },

        // legado 兼容：java.webView(html, url, js, cacheFirst)
        // 在 legado 中，java.webView 用于执行包含 JS 的 HTML 并获取渲染结果
        // QuickJS 同步模式下无法真正渲染 WebView，尝试从缓存获取
        // 假声明：兼容 Legado 4 参签名 webView(html, url, js, cacheFirst)
        webView: function(html, url, js, cacheFirst) {
          // 兼容旧签名 webView(htmlOrJs, baseUrl, extra)
          var htmlOrJs = html, baseUrl = url, extra = js;
          var cacheKey = 'webview:' + (baseUrl || '') + ':' + (htmlOrJs || '').length;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          // fallback: 如果 htmlOrJs 包含 <script>，尝试直接执行其中的 JS
          try {
            if (typeof htmlOrJs === 'string' && htmlOrJs.indexOf('<script') >= 0) {
              var scripts = htmlOrJs.match(/<script[^>]*>([\\s\\S]*?)<\\/script>/gi);
              if (scripts && scripts.length > 0) {
                var lastResult = '';
                for (var i = 0; i < scripts.length; i++) {
                  var code = scripts[i].replace(/<script[^>]*>/i, '').replace(/<\\/script>/i, '');
                  if (code.trim()) lastResult = String(eval(code));
                }
                return lastResult;
              }
            }
          } catch(e) {}
          return '';
        },
        // java.webViewGetSource(html, url, js, sourceRegex, cacheFirst, delayTime) — 抓取 WebView 加载的资源 URL
        // 假声明：QuickJS 无 WebView，从缓存取
        webViewGetSource: function(html, url, js, sourceRegex, cacheFirst, delayTime) {
          var cacheKey = 'webview_src:' + (url || '') + ':' + (sourceRegex || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.webViewGetOverrideUrl(html, url, js, overrideUrlRegex, cacheFirst, delayTime) — 抓取 WebView 跳转 URL
        // 假声明：QuickJS 无 WebView，从缓存取
        webViewGetOverrideUrl: function(html, url, js, overrideUrlRegex, cacheFirst, delayTime) {
          var cacheKey = 'webview_override:' + (url || '') + ':' + (overrideUrlRegex || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.openVideoPlayer(url, title, isFloat) — 打开视频播放器
        // 假声明：QuickJS 无播放器，空操作
        openVideoPlayer: function(url, title, isFloat) {
          // 走 url_launcher 预缓存触发（在 _preCacheBridgeCalls 6.9 中处理）
        },

        // ===== 缓存管理 =====
        cache: {
          get: function(key) { return _javaCache[key] || ''; },
          put: function(key, value) { _javaCache[key] = value; },
          delete: function(key) { delete _javaCache[key]; },
        },

        // ===== 日志 =====
        log: function(msg) {
          console.log('[JavaBridge] ' + msg);
        },

        // ===== 网络（对齐 legado JsExtensions）=====
        // java.connect(urlStr, header) — 完整 HTTP 请求，返回 response body
        connect: function(urlStr, header, callTimeout) {
          // 兼容 legado：connect 返回 body 字符串
          var fullUrl = urlStr;
          if (urlStr && !urlStr.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
            fullUrl = baseUrl.replace(/\\/+\\\$/, '') + '/' + urlStr.replace(/^\\/+/, '');
          }
          var cacheKey = 'http_connect:' + fullUrl;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          // fallback: 尝试 get 缓存
          return java.get(fullUrl, header);
        },
        // java.head(urlStr, headers) — HEAD 请求（同步模式无法真正执行，从缓存取）
        head: function(urlStr, headers, timeout) {
          var cacheKey = 'http_head:' + urlStr;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.getCookie(tag) / java.getCookie(tag, key) — Cookie 管理
        // Dart 侧预缓存写入 'cookie:tag'（完整 cookie 字符串），JS 端按需解析 key
        getCookie: function(tag, key) {
          var cacheKey = 'cookie:' + tag;
          if (_javaCache[cacheKey] === undefined) return '';
          var cookieStr = _javaCache[cacheKey];
          if (!key) return cookieStr;
          // 带 key：从 cookie 字符串解析特定 key 的值
          var match = cookieStr.match(new RegExp('(?:^|;\\s*)' + key + '=([^;]+)'));
          return match ? match[1] : '';
        },
        // java.startBrowser(url, title, html) — 打开浏览器（移动端专用，QuickJS 空操作）
        // 假声明：兼容 Legado 3 参签名，html 参数暂忽略
        startBrowser: function(url, title, html) {},
        // java.startBrowserAwait(url, title) — 等待浏览器结果
        startBrowserAwait: function(url, title, refetchAfterSuccess, html) {
          var cacheKey = 'browser:' + url;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.getVerificationCode(imageUrl) — 验证码识别
        getVerificationCode: function(imageUrl) {
          var cacheKey = 'captcha:' + imageUrl;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },

        // 注：字体反爬（queryTTF/queryBase64TTF/replaceFont）已移除
        // Legado 自带的字体反爬功能使用频率低，QuickJS 无 TTF 解析能力
        // 书源若需字体反爬可自行用 JS 实现

        // ===== 编解码（对齐 legado JsEncodeUtils）=====
        // java.md5Encode16(str) — 16 位 MD5
        md5Encode16: function(str) {
          var full = java.md5Encode(str);
          return full.length >= 32 ? full.substring(8, 24) : '';
        },
        // java.digestHex(data, algorithm) — 通用摘要算法
        digestHex: function(data, algorithm) {
          var cacheKey = 'digest:' + algorithm + ':' + data;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          // fallback: algorithm 小写匹配
          var algo = (algorithm || '').toLowerCase();
          if (algo.indexOf('md5') >= 0) return java.md5Encode(data);
          if (algo.indexOf('sha-1') >= 0 || algo.indexOf('sha1') >= 0) return java.sha1Encode(data);
          if (algo.indexOf('sha-256') >= 0 || algo.indexOf('sha256') >= 0) return java.sha256Encode(data);
          return '';
        },
        // java.digestBase64Str(data, algorithm) — 摘要算法返回 Base64
        digestBase64Str: function(data, algorithm) {
          var hex = java.digestHex(data, algorithm);
          if (!hex) return '';
          try { return java.base64Encode(java.hexDecodeToString(hex)); } catch(e) { return ''; }
        },
        // java.HMacHex(data, algorithm, key) — HMAC 摘要
        HMacHex: function(data, algorithm, key) {
          var cacheKey = 'hmac:' + algorithm + ':' + data + ':' + key;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          var algo = (algorithm || '').toLowerCase();
          if (algo.indexOf('sha256') >= 0 || algo.indexOf('hmacsha256') >= 0) return java.hmacSHA256(data, key);
          return '';
        },
        // java.HMacBase64Str(data, algorithm, key) — HMAC 返回 Base64
        HMacBase64Str: function(data, algorithm, key) {
          var hex = java.HMacHex(data, algorithm, key);
          if (!hex) return '';
          try { return java.base64Encode(java.hexDecodeToString(hex)); } catch(e) { return ''; }
        },
        // java.HMacBase64(data, algorithm, key) — Legado 实际命名（等同 HMacBase64Str）
        // 假声明：作为别名导出，避免书源里调用 HMacBase64 报 undefined
        HMacBase64: function(data, algorithm, key) { return java.HMacBase64Str(data, algorithm, key); },
        // java.strToBytes(str) / java.strToBytes(str, charset) — 字符串转字节数组
        strToBytes: function(str, charset) {
          var bytes = [];
          for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i);
            if (c < 128) { bytes.push(c); }
            else if (c < 2048) { bytes.push(192 | (c >> 6), 128 | (c & 63)); }
            else { bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63)); }
          }
          return bytes;
        },
        // java.bytesToStr(bytes) / java.bytesToStr(bytes, charset) — 字节数组转字符串
        bytesToStr: function(bytes, charset) {
          if (!bytes || !bytes.length) return '';
          var str = '';
          for (var i = 0; i < bytes.length; i++) {
            str += String.fromCharCode(bytes[i] & 0xFF);
          }
          try { return decodeURIComponent(escape(str)); } catch(e) { return str; }
        },
        // java.base64DecodeToByteArray(str) — Base64 解码为字节数组
        base64DecodeToByteArray: function(str) {
          var decoded = java.base64Decode(str);
          if (!decoded) return [];
          return java.strToBytes(decoded);
        },

        // ===== 文本处理（对齐 legado JsExtensions）=====
        // java.htmlFormat(str) — HTML 格式化（去标签、解码实体）
        htmlFormat: function(str) {
          if (!str) return '';
          return str.replace(/<p[^>]*>/gi, '\\n')
                    .replace(/<br[^>]*\\/?>/gi, '\\n')
                    .replace(/<[^>]+>/g, '')
                    .replace(/&nbsp;/g, ' ')
                    .replace(/&amp;/g, '&')
                    .replace(/&lt;/g, '<')
                    .replace(/&gt;/g, '>')
                    .replace(/&quot;/g, '"')
                    .replace(/&#39;/g, "'")
                    .replace(/\\n{3,}/g, '\\n\\n')
                    .trim();
        },
        // java.t2s(text) — 繁体转简体（简易映射，常用字覆盖）
        t2s: function(text) {
          var cacheKey = 't2s:' + text;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          // 简易映射：常用繁简对照表
          var map = {'書':'书','學':'学','網':'网','開':'开','關':'关','無':'无','說':'说','對':'对','來':'来','們':'们','時':'时','國':'国','會':'会','長':'长','點':'点','機':'机','動':'动','現':'现','經':'经','過':'过','運':'运','種':'种','問':'问','區':'区','場':'场','體':'体','電':'电','話':'话','視':'视','語':'语','讀':'读','設':'设','請':'请','產':'产','務':'务','歷':'历','達':'达','還':'还','進':'进','開':'开','邊':'边','東':'东','車':'车','頭':'头','見':'见','風':'风','龍':'龙','萬':'万','與':'与','爾':'尔','樂':'乐','醫':'医','藥':'药','農':'农','礦':'矿','鐵':'铁','銀':'银','錢':'钱','門':'门','間':'间','聽':'听','聲':'声','膽':'胆','腦':'脑','臉':'脸','節':'节','歲':'岁','幾':'几','買':'买','賣':'卖','貴':'贵','費':'费','資':'资','質':'质','轉':'转','軟':'软','較':'较','輯':'辑','輸':'输','轄':'辖','辦':'办','辯':'辩','證':'证','識':'识','議':'议','護':'护','讚':'赞','豐':'丰','財':'财','貧':'贫','貪':'贪','責':'责','賴':'赖','贈':'赠','贊':'赞','贏':'赢','躍':'跃','車':'车','軌':'轨','載':'载','輔':'辅','輕':'轻','輪':'轮','輯':'辑','輸':'输','轄':'辖','轉':'转','轟':'轰','辭':'辞','辯':'辩','農':'农','迴':'回','週':'周','進':'进','運':'运','過':'过','達':'达','遲':'迟','還':'还','邊':'边','郵':'邮','鄉':'乡','醫':'医','鐘':'钟','鐵':'铁','鑒':'鉴','長':'长','門':'门','關':'关','陸':'陆','陽':'阳','險':'险','隨':'随','隱':'隐','隸':'隶','雙':'双','雜':'杂','雞':'鸡','離':'离','難':'难','雲':'云','電':'电','震':'震','霧':'雾','露':'露','靈':'灵','靜':'静','面':'面','革':'革','靴':'靴','鞋':'鞋','韓':'韩','音':'音','韻':'韵','頁':'页','頃':'顷','項':'项','須':'须','頌':'颂','預':'预','頑':'顽','頒':'颁','頓':'顿','頗':'颇','領':'领','頜':'颌','頤':'颐','頭':'头','頻':'频','顆':'颗','題':'题','額':'额','顏':'颜','願':'愿','顛':'颠','類':'类','顧':'顾','顯':'显','風':'风','颯':'飒','颱':'台','颳':'刮','飄':'飘','飛':'飞','食':'食','飯':'饭','飲':'饮','飼':'饲','飽':'饱','飾':'饰','餃':'饺','餅':'饼','餌':'饵','餐':'餐','餘':'余','餞':'饯','餡':'馅','館':'馆','饋':'馈','饑':'饥','饒':'饶','饗':'飨','首':'首','香':'香','馬':'马','馱':'驮','馴':'驯','駕':'驾','駐':'驻','駕':'驾','駛':'驶','駝':'驼','駭':'骇','騎':'骑','騙':'骗','騰':'腾','驕':'骄','驗':'验','驚':'惊','驛':'驿','骨':'骨','體':'体','高':'高','髮':'发','鬥':'斗','鬧':'闹','鬱':'郁','鬼':'鬼','魁':'魁','魂':'魂','魏':'魏','魚':'鱼','魯':'鲁','鮑':'鲍','鮮':'鲜','鯉':'鲤','鯊':'鲨','鯨':'鲸','鳥':'鸟','鳳':'凤','鳴':'鸣','鴉':'鸦','鴻':'鸿','鵑':'鹃','鵝':'鹅','鵬':'鹏','鶴':'鹤','鷗':'鸥','鷹':'鹰','鷺':'鹭','鹽':'盐','麗':'丽','麥':'麦','麻':'麻','黃':'黄','黌':'黉','黎':'黎','黏':'黏','黑':'黑','點':'点','黨':'党','鼓':'鼓','鼠':'鼠','鼻':'鼻','齊':'齐','齋':'斋','齒':'齿','齡':'龄','龍':'龙','龐':'庞','龔':'龚','龜':'龟'};
          var result = text;
          for (var k in map) {
            result = result.replace(new RegExp(k, 'g'), map[k]);
          }
          _javaCache[cacheKey] = result;
          return result;
        },
        // java.s2t(text) — 简体转繁体（简易映射）
        s2t: function(text) {
          var cacheKey = 's2t:' + text;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          var map = {'书':'書','学':'學','网':'網','开':'開','关':'關','无':'無','说':'說','对':'對','来':'來','们':'們','时':'時','国':'國','会':'會','长':'長','点':'點','机':'機','动':'動','现':'現','经':'經','过':'過','运':'運','种':'種','问':'問','区':'區','场':'場','体':'體','电':'電','话':'話','视':'視','语':'語','读':'讀','设':'設','请':'請','产':'產','务':'務','历':'歷','达':'達','还':'還','进':'進','边':'邊','东':'東','车':'車','头':'頭','见':'見','风':'風','龙':'龍','万':'萬','与':'與','尔':'爾','乐':'樂','医':'醫','药':'藥','农':'農','矿':'礦','铁':'鐵','银':'銀','钱':'錢','门':'門','间':'間','听':'聽','声':'聲','脑':'腦','脸':'臉','节':'節','岁':'歲','几':'幾','买':'買','卖':'賣','贵':'貴','费':'費','资':'資','质':'質','转':'轉','软':'軟','较':'較','辑':'輯','输':'輸','办':'辦','证':'證','识':'識','议':'議','护':'護','赞':'讚','丰':'豐','财':'財','贫':'貧','责':'責','赠':'贈','赢':'贏','跃':'躍','轨':'軌','载':'載','轻':'輕','轮':'輪','迟':'遲','邮':'郵','乡':'鄉','钟':'鐘','陆':'陸','阳':'陽','险':'險','随':'隨','隐':'隱','双':'雙','杂':'雜','鸡':'雞','离':'離','难':'難','云':'雲','静':'靜','灵':'靈','韵':'韻','页':'頁','须':'須','预':'預','顿':'頓','领':'領','频':'頻','题':'題','额':'額','颜':'顏','愿':'願','类':'類','显':'顯','飞':'飛','饭':'飯','饮':'飲','馆':'館','马':'馬','驾':'駕','骑':'騎','骗':'騙','惊':'驚','验':'驗','鱼':'魚','鸟':'鳥','鸣':'鳴','鹤':'鶴','盐':'鹽','丽':'麗','麦':'麥','齿':'齒','龄':'齡','龟':'龜'};
          var result = text;
          for (var k in map) {
            result = result.replace(new RegExp(k, 'g'), map[k]);
          }
          _javaCache[cacheKey] = result;
          return result;
        },
        // java.toNumChapter(s) — 章节号标准化（"第一百二十章" → "120"）
        toNumChapter: function(s) {
          if (!s) return '';
          var numMap = {'零':0,'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9,'十':10,'百':100,'千':1000,'万':10000};
          // 尝试提取阿拉伯数字
          var m = s.match(/(\\d+)/);
          if (m) return m[1];
          // 中文数字转换
          var result = 0, current = 0;
          for (var i = 0; i < s.length; i++) {
            var ch = s[i];
            if (numMap[ch] !== undefined) {
              var val = numMap[ch];
              if (val >= 10) {
                current = current === 0 ? val : current * val;
                if (val >= 10000) { result = (result + current) * val; current = 0; }
                else if (val >= 1000) { result += current; current = 0; }
              } else {
                current = val;
              }
            }
          }
          return String(result + current);
        },

        // ===== 工具方法（对齐 legado JsExtensions）=====
        // java.toast(msg) — 显示 Toast
        toast: function(msg) { console.log('[Toast] ' + msg); },
        // java.longToast(msg) — 长时间 Toast
        longToast: function(msg) { console.log('[LongToast] ' + msg); },
        // java.getWebViewUA() — 获取 WebView UA
        getWebViewUA: function() {
          var cacheKey = 'webview_ua';
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
        },
        // java.randomUUID() — 生成 UUID
        randomUUID: function() {
          return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
            var r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
          });
        },
        // java.androidId() — Android 设备 ID
        androidId: function() {
          var cacheKey = 'android_id';
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return java.randomUUID().replace(/-/g, '').substring(0, 16);
        },
        // java.cacheFile(url, saveTime) — 缓存文件到本地
        // 走原生 NativeChannel.httpDownload 桥接，结果在 _javaCache['cache_file:url']
        cacheFile: function(url, saveTime) {
          var cacheKey = 'cache_file:' + url;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.downloadFile(url) / downloadFile(content, url) — 下载文件返回路径
        // 走原生 NativeChannel.httpDownload 桥接，结果在 _javaCache['download_file:url']
        downloadFile: function(urlOrContent, url) {
          // 兼容旧签名 downloadFile(content, url)
          var u = url === undefined ? urlOrContent : url;
          var cacheKey = 'download_file:' + u;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          // fallback：返回占位路径
          return '/tmp/' + java.md5Encode(u).substring(0, 16);
        },
        // java.getFile(path) — 获取 File 对象
        // 假声明：QuickJS 无 File 概念，返回占位对象
        getFile: function(path) {
          return { path: path, exists: function() { return false; }, readText: function() { return ''; } };
        },
        // java.importScript(path) — 导入脚本（走 dart:io 预缓存）
        importScript: function(path) {
          var cacheKey = 'file_importScript:' + path;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.readFile(path) / java.readTxtFile(path, charset) — 读取文件
        // 走 dart:io 预缓存桥接，结果在 _javaCache['file_readFile:path']
        readFile: function(path) {
          var cacheKey = 'file_readFile:' + path;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        readTxtFile: function(path, charset) {
          var cacheKey = 'file_readTxtFile:' + path;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.deleteFile(path) — 删除文件
        // 走 dart:io 预缓存桥接，结果在 _javaCache['file_deleteFile:path']
        deleteFile: function(path) {
          var cacheKey = 'file_deleteFile:' + path;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey] === 'true';
          return false;
        },
        // java.writeFile(path, content) — 写文件（预缓存标记可写）
        writeFile: function(path, content) {
          var cacheKey = 'file_writeFile:' + path;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey] === 'true';
          return false;
        },
        // java.unzipFile(path, password) / un7zFile / unrarFile / unArchiveFile — 解压
        // 走 archive 包预缓存桥接，支持密码参数
        unzipFile: function(path, password) {
          var cacheKey = 'archive_unzipFile:' + path + '::' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        un7zFile: function(path, password) {
          var cacheKey = 'archive_un7zFile:' + path + '::' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        unrarFile: function(path, password) {
          var cacheKey = 'archive_unrarFile:' + path + '::' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        unArchiveFile: function(path, password) {
          var cacheKey = 'archive_unArchiveFile:' + path + '::' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.getTxtInFolder(path) — 读取文件夹下所有 txt
        // 走 dart:io 预缓存桥接，结果在 _javaCache['file_getTxtInFolder:path']
        getTxtInFolder: function(path) {
          var cacheKey = 'file_getTxtInFolder:' + path;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.getZipStringContent / getRarStringContent / get7zStringContent — 压缩包内文件读取
        // 走 archive 包预缓存桥接，支持密码参数（第 4 位）
        getZipStringContent: function(url, path, charset, password) {
          var cacheKey = 'archive_getZipStringContent:' + url + ':' + (path || '') + ':' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        getRarStringContent: function(url, path, charset, password) {
          var cacheKey = 'archive_getRarStringContent:' + url + ':' + (path || '') + ':' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        get7zStringContent: function(url, path, charset, password) {
          var cacheKey = 'archive_get7zStringContent:' + url + ':' + (path || '') + ':' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        getZipByteArrayContent: function(url, path, password) {
          // ByteArray 在 JS 中近似为字符串
          var cacheKey = 'archive_getZipStringContent:' + url + ':' + (path || '') + ':' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        getRarByteArrayContent: function(url, path, password) {
          var cacheKey = 'archive_getRarStringContent:' + url + ':' + (path || '') + ':' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        get7zByteArrayContent: function(url, path, password) {
          var cacheKey = 'archive_get7zStringContent:' + url + ':' + (path || '') + ':' + (password || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.openUrl(url, mimeType) — 打开 URL（走 url_launcher 预缓存）
        openUrl: function(url, mimeType) {},
        // java.getReadBookConfig() — 获取阅读配置（JSON 字符串）
        // 走 Dart Provider 预缓存桥接，结果在 _javaCache['read_book_config']
        getReadBookConfig: function() {
          var cacheKey = 'read_book_config';
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '{}';
        },
        // java.getReadBookConfigMap() — 获取阅读配置（Map 版）
        getReadBookConfigMap: function() {
          var cacheKey = 'read_book_config';
          if (_javaCache[cacheKey] !== undefined) {
            try { return JSON.parse(_javaCache[cacheKey]); } catch(_) {}
          }
          return {};
        },
        // java.getThemeMode() — 获取主题模式
        // 走 Dart Provider 预缓存桥接，结果在 _javaCache['theme_mode']
        getThemeMode: function() {
          var cacheKey = 'theme_mode';
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return 'light';
        },
        // java.getThemeConfig() — 获取主题配置（JSON 字符串）
        getThemeConfig: function() {
          var cacheKey = 'theme_config';
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '{}';
        },
        // java.getThemeConfigMap() — 获取主题配置（Map 版）
        getThemeConfigMap: function() {
          var cacheKey = 'theme_config';
          if (_javaCache[cacheKey] !== undefined) {
            try { return JSON.parse(_javaCache[cacheKey]); } catch(_) {}
          }
          return {};
        },
        // java.getSource() — 获取当前书源对象
        // 走 Dart Provider 预缓存桥接，结果在 _javaCache['source']
        getSource: function() {
          var cacheKey = 'source';
          if (_javaCache[cacheKey] !== undefined) {
            try { return JSON.parse(_javaCache[cacheKey]); } catch(_) {}
          }
          return {};
        },
        // java.getTag() — 获取书源标签
        getTag: function() {
          var cacheKey = 'tag';
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.logType(any) — 打印类型信息（调试用）
        logType: function(any) {
          console.log('[logType] ' + typeof any + ': ' + (any === null ? 'null' : String(any).substring(0, 100)));
        },
        // java.toURL(urlStr) — 创建 URL 对象
        toURL: function(urlStr, base) {
          try {
            // 简易 URL 解析
            var u = urlStr;
            if (base && !urlStr.startsWith('http')) {
              u = base.replace(/\\/+\\\$/, '') + '/' + urlStr.replace(/^\\/+/, '');
            }
            var m = u.match(/^(https?:)\\/\\/([^:/]+)(:\\d+)?(\\/[^?#]*)?(\\?[^?#]*)?(#.*)?\$/);
            return {
              protocol: m ? m[1] : '',
              host: m ? m[2] : '',
              port: m && m[3] ? m[3].substring(1) : '',
              pathname: m && m[4] ? m[4] : '/',
              search: m && m[5] ? m[5] : '',
              hash: m && m[6] ? m[6] : '',
              href: u,
              toString: function() { return u; }
            };
          } catch(e) { return { href: urlStr, toString: function() { return urlStr; } }; }
        },

        // ===== AES/DES 完整参数版（对齐 legado JsEncodeUtils）=====
        // java.aesEncodeToString(data, key, transformation, iv) — AES 加密返回字符串
        aesEncodeToString: function(data, key, transformation, iv) {
          return java.aesEncode(data, key, iv);
        },
        // java.aesEncodeToBase64String(data, key, transformation, iv) — AES 加密返回 Base64
        aesEncodeToBase64String: function(data, key, transformation, iv) {
          var result = java.aesEncode(data, key, iv);
          return result ? java.base64Encode(result) : '';
        },
        // java.aesDecodeToString(str, key, transformation, iv) — AES 解密
        aesDecodeToString: function(str, key, transformation, iv) {
          return java.aesDecode(str, key, iv);
        },
        // java.aesBase64DecodeToString(str, key, transformation, iv) — AES Base64 解密
        aesBase64DecodeToString: function(str, key, transformation, iv) {
          var decoded = java.base64Decode(str);
          return decoded ? java.aesDecode(decoded, key, iv) : '';
        },
        // java.createSymmetricCrypto(transformation, key, iv) — 创建对称加密器
        // 假声明：对齐 Hutool SymmetricCrypto 接口
        // 让书源里 cipher.decryptStr(data) / cipher.encryptStr(data) / cipher.encryptHex(data) 等调用
        // 以为自己跑在 Rhino+Android 上，实则跑在 QuickJS 上
        createSymmetricCrypto: function(transformation, key, iv) {
          var keyStr = typeof key === 'string' ? key : (key ? String(key) : '');
          var ivStr = typeof iv === 'string' ? iv : (iv ? String(iv) : '');
          // DES/3DES/PBE 等暂降级为 AES（实际书源极少用真 DES，多为占位）
          var algo = typeof transformation === 'string' ? transformation : 'AES/CBC/PKCS5Padding';

          // Base64 字符串 ↔ Hex 字符串互转（Hutool 内置，这里假声明）
          function _b64ToHex(b64) {
            try {
              var raw = java.base64Decode(b64); // UTF-8 字符串
              var hex = '';
              for (var i = 0; i < raw.length; i++) {
                var c = raw.charCodeAt(i) & 0xff;
                hex += (c < 16 ? '0' : '') + c.toString(16);
              }
              return hex;
            } catch (e) { return ''; }
          }
          function _hexToB64(hex) {
            try {
              var raw = '';
              for (var i = 0; i + 1 < hex.length; i += 2) {
                raw += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
              }
              return java.base64Encode(raw);
            } catch (e) { return ''; }
          }

          var crypto = {
            // 加密为字符串（默认输出 Base64，对齐 Hutool encryptStr 默认行为）
            encryptStr: function(data, charset) { return java.aesEncode(data, keyStr, ivStr); },
            // 解密字符串（输入 Base64，输出 UTF-8 明文，对齐 Hutool decryptStr）
            decryptStr: function(data, charset) { return java.aesDecode(data, keyStr, ivStr); },
            // 加密为 Base64
            encryptBase64: function(data) { return java.aesEncodeToBase64String(data, keyStr, '', ivStr); },
            // 解密 Base64
            decryptBase64: function(data) { return java.aesBase64DecodeToString(data, keyStr, '', ivStr); },
            // 加密为 Hex
            encryptHex: function(data) {
              var b64 = java.aesEncodeToBase64String(data, keyStr, '', ivStr);
              return b64 ? _b64ToHex(b64) : '';
            },
            // 解密 Hex
            decryptHex: function(hex) {
              var b64 = _hexToB64(hex);
              return b64 ? java.aesBase64DecodeToString(b64, keyStr, '', ivStr) : '';
            },
            // 加密为字节数组（QuickJS 无 ByteArray，用 Base64 字符串近似）
            encrypt: function(data) { return java.aesEncode(data, keyStr, ivStr); },
            // 解密字节数组
            decrypt: function(data) { return java.aesDecode(data, keyStr, ivStr); },
            // 链式设置 IV（对齐 Hutool setIv，返回自身）
            setIv: function(newIv) {
              ivStr = typeof newIv === 'string' ? newIv : String(newIv || '');
              return crypto;
            }
          };
          return crypto;
        },
        // java.desEncodeToString / desDecodeToString — DES 兼容（简化为 AES）
        desEncodeToString: function(data, key, transformation, iv) {
          return java.aesEncode(data, key, iv);
        },
        desDecodeToString: function(data, key, transformation, iv) {
          return java.aesDecode(data, key, iv);
        },
        desEncodeToBase64String: function(data, key, transformation, iv) {
          return java.aesEncodeToBase64String(data, key, '', iv);
        },
        desBase64DecodeToString: function(data, key, transformation, iv) {
          return java.aesBase64DecodeToString(data, key, '', iv);
        },
        // java.tripleDES* — 3DES 兼容（简化为 AES）
        tripleDESEncodeBase64Str: function(data, key, mode, padding, iv) {
          return java.aesEncodeToBase64String(data, key, '', iv);
        },
        tripleDESDecodeArgsBase64Str: function(data, key, mode, padding, iv) {
          return java.aesBase64DecodeToString(data, key, '', iv);
        },
        // 假声明：补全 Legado 缺失的 3DES 重载
        // java.tripleDESDecodeStr(data, key, mode, padding, iv) — 3DES 不带 Base64 解密
        tripleDESDecodeStr: function(data, key, mode, padding, iv) {
          return java.aesDecode(data, key, iv);
        },
        // java.tripleDESEncodeArgsBase64Str(data, key, mode, padding, iv) — 3DES 带 Base64 加密
        tripleDESEncodeArgsBase64Str: function(data, key, mode, padding, iv) {
          return java.aesEncodeToBase64String(data, key, '', iv);
        },
        // java.createAsymmetricCrypto(transformation) — 创建非对称加密器
        // 假声明：QuickJS 无 RSA/ECC 实现，返回空操作对象
        createAsymmetricCrypto: function(transformation) {
          return {
            encrypt: function(data) { return ''; },
            decrypt: function(data) { return ''; },
            encryptStr: function(data) { return ''; },
            decryptStr: function(data) { return ''; },
            encryptBase64: function(data) { return ''; },
            decryptBase64: function(data) { return ''; }
          };
        },
        // java.createSign(algorithm) — 创建签名器
        // 假声明：返回空签名器
        createSign: function(algorithm) {
          return {
            sign: function(data) { return ''; },
            verify: function(data, sig) { return false; },
            signBase64: function(data) { return ''; },
            verifyBase64: function(data, sig) { return false; }
          };
        },
        // ===== AES 参数版（对齐 legado JsEncodeUtils 的 Args/ByteArray 重载）=====
        // 假声明：mode/padding 暂忽略，统一按 AES/CBC/PKCS5Padding 处理
        // java.aesEncodeArgsBase64Str(data, key, mode, padding, iv) — AES 参数化加密（web 端兼容）
        aesEncodeArgsBase64Str: function(data, key, mode, padding, iv) {
          return java.aesEncodeToBase64String(data, key, '', iv);
        },
        // java.aesDecodeArgsBase64Str(data, key, mode, padding, iv) — AES 参数化解密
        aesDecodeArgsBase64Str: function(data, key, mode, padding, iv) {
          return java.aesBase64DecodeToString(data, key, '', iv);
        },
        // java.aesDecodeToByteArray(str, key, transformation, iv) — AES 解密返回 ByteArray
        aesDecodeToByteArray: function(str, key, transformation, iv) {
          var result = java.aesDecode(str, key, iv);
          return result ? java.strToBytes(result) : [];
        },
        // java.aesEncodeToByteArray(data, key, transformation, iv) — AES 加密返回 ByteArray
        aesEncodeToByteArray: function(data, key, transformation, iv) {
          var result = java.aesEncode(data, key, iv);
          return result ? java.strToBytes(result) : [];
        },
        // java.aesBase64DecodeToByteArray(str, key, transformation, iv) — AES Base64 解密返回 ByteArray
        aesBase64DecodeToByteArray: function(str, key, transformation, iv) {
          var result = java.aesBase64DecodeToString(str, key, transformation, iv);
          return result ? java.strToBytes(result) : [];
        },
        // java.aesEncodeToBase64ByteArray(data, key, transformation, iv) — AES 加密 Base64 返回 ByteArray
        aesEncodeToBase64ByteArray: function(data, key, transformation, iv) {
          var result = java.aesEncodeToBase64String(data, key, transformation, iv);
          return result ? java.strToBytes(result) : [];
        },

        // ===== 元素操作（借鉴 legado JsExtensions）=====
        getElements: function(html, rule) {
          // 借鉴 legado：单参数模式 html 是规则，内容来自 result
          var content, r;
          if (rule === undefined || rule === null) {
            r = html;
            content = (typeof result !== 'undefined') ? result : '';
          } else {
            content = html;
            r = rule;
          }
          if (!r) return [];
          if (r.indexOf('@@') === 0) r = r.substring(2);
          return _JsoupLite.selectAll(content, r);
        },
        getElement: function(html, rule) {
          // 借鉴 legado：单参数模式 html 是规则，内容来自 result
          var content, r;
          if (rule === undefined || rule === null) {
            r = html;
            content = (typeof result !== 'undefined') ? result : '';
          } else {
            content = html;
            r = rule;
          }
          if (!r) return '';
          if (r.indexOf('@@') === 0) r = r.substring(2);
          return _JsoupLite.selectFirst(content, r);
        },
      };

      // ===== 兼容 Legado 的 CryptoJS（桥接到 NativeChannel）=====
      var CryptoJS = {
        AES: {
          encrypt: function(data, key, cfg) {
            var keyStr = typeof key === 'string' ? key : (key.toString ? key.toString() : '');
            var iv = cfg && cfg.iv ? (typeof cfg.iv === 'string' ? cfg.iv : (cfg.iv.toString ? cfg.iv.toString() : '')) : '';
            var mode = cfg && cfg.mode ? 'ECB' : 'CBC';
            var result = java.aesEncode(data, keyStr, iv);
            return { toString: function() { return result; }, ciphertext: { toString: function(enc) { return result; } } };
          },
          decrypt: function(data, key, cfg) {
            var keyStr = typeof key === 'string' ? key : (key.toString ? key.toString() : '');
            var iv = cfg && cfg.iv ? (typeof cfg.iv === 'string' ? cfg.iv : (cfg.iv.toString ? cfg.iv.toString() : '')) : '';
            var result = java.aesDecode(data, keyStr, iv);
            return { toString: function(enc) { return result; } };
          },
        },
        MD5: function(str) { return { toString: function() { return java.md5Encode(str); } }; },
        SHA1: function(str) { return { toString: function() { return java.sha1Encode(str); } }; },
        SHA256: function(str) { return { toString: function() { return java.sha256Encode(str); } }; },
        HmacSHA256: function(data, key) { return { toString: function() { return java.hmacSHA256(data, key); } }; },
        enc: {
          Utf8: { parse: function(s) { return s; }, stringify: function(w) { return w; } },
          Base64: { parse: function(s) { return java.base64Decode(s) || ''; }, stringify: function(w) { return java.base64Encode(w) || ''; } },
          Hex: { parse: function(s) { return java.hexDecodeToString(s); }, stringify: function(w) { return java.hexEncodeToString(w); } },
          Latin1: { parse: function(s) { return s; }, stringify: function(w) { return w; } },
        },
        mode: { ECB: {}, CBC: {} },
        pad: { Pkcs7: {}, ZeroPadding: {}, NoPadding: {}, Iso97971: {} },
        lib: {
          WordArray: {
            create: function(words, sigBytes) {
              return { words: words || [], sigBytes: sigBytes || 0, toString: function() { return (words || []).join(''); } };
            }
          }
        },
        algo: {},
      };
    """;

    // 3. 注入 HTML 解析辅助函数 + java 对象
    try {
      evaluate(jsoupLiteCode);
      evaluate(helperCode);
    } catch (e) {
    }

    // 4. 验证 java 对象是否注入成功
    final javaCheck = evaluate('typeof java !== "undefined"');
    if (javaCheck != 'true') {
      // 简化版：只注入核心方法
      evaluate('''
        var java = {
          get: function(url) { var cacheKey = 'http_get:' + url; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
          post: function(url, body) { var cacheKey = 'http_post:' + url; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
          ajax: function(url) { return java.get(url); },
          put: function(key, value) { _javaCache[key] = typeof value === 'object' ? JSON.stringify(value) : String(value); },
          getStr: function(key, def) { return _javaCache[key] || (def || ''); },
          log: function(msg) { console.log('[JavaBridge] ' + msg); },
          aesEncode: function(data, key, iv) {
            try {
              var mode = iv ? 'CBC' : 'ECB';
              if (typeof CryptoJS !== 'undefined' && CryptoJS.AES) {
                var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
                return CryptoJS.AES.encrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString();
              }
              return _AES.encrypt(data, key, iv, mode);
            } catch(e) { return ''; }
          },
          aesDecode: function(data, key, iv) {
            try {
              var mode = iv ? 'CBC' : 'ECB';
              // Phase 5: 全 C 直通（base64 字符串 → C 层一站式解码+解密 → ArrayBuffer → UTF-8）
              if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto.aesDecryptFromBase64) {
                var plainU8 = iv
                  ? __nativeCrypto.aesDecryptFromBase64(data, key, iv)
                  : __nativeCrypto.aesDecryptFromBase64ECB(data, key);
                if (plainU8 && plainU8.byteLength > 0) {
                  var r = _u8ToStr(plainU8);
                  if (r && r.length > 0) return r;
                }
              }
              // 回退到 CryptoJS 路径（优先走 C 原生）
              if (typeof CryptoJS !== 'undefined' && CryptoJS.AES) {
                var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
                return CryptoJS.AES.decrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString(CryptoJS.enc.Utf8);
              }
              return _AES.decrypt(data, key, iv, mode);
            } catch(e) { _jsLog('AES decrypt failed: ' + e, 'error'); return ''; }
          },
          aesDecodeBytes: function(data, key, iv) {
            try {
              if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto.aesDecryptFromBase64) {
                if (iv) return __nativeCrypto.aesDecryptFromBase64(data, key, iv);
                return __nativeCrypto.aesDecryptFromBase64ECB(data, key);
              }
              var s = java.aesDecode(data, key, iv);
              return _strToU8(s);
            } catch(e) { return new Uint8Array(0); }
          },
          md5Encode: function(str) { var k = 'md5:' + str; if (_javaCache[k] !== undefined) return _javaCache[k]; return ''; },
          base64Encode: function(str) { try { return btoa(unescape(encodeURIComponent(str))); } catch(e) { return ''; } },
          base64Decode: function(str) { try { return decodeURIComponent(escape(atob(str))); } catch(e) { return ''; } },
        };
      ''');
    }

    // 3.5 将 java 挂到 globalThis，让 jsLib 全局函数（如 search()）也能访问
    // 同时注册快捷全局方法，省略 java. / java.jsoup. 前缀
    try {
      evaluate('''
        globalThis.java = java;
        // jsoup 快捷方法
        globalThis.select = function(html, selector) { return java.jsoup.select(html, selector); };
        globalThis.selectFirst = function(html, selector) { return java.jsoup.selectFirst(html, selector); };
        globalThis.getAttr = function(html, selector, attr) { return java.jsoup.getAttr(html, selector, attr); };
        globalThis.clean = function(html) { return java.jsoup.clean(html); };
        // java 快捷方法
        globalThis.getString = function(content, rule) { return java.getString(content, rule); };
        globalThis.put = function(key, value) { return java.put(key, value); };
        globalThis.getStr = function(key, def) { return java.getStr(key, def); };
        globalThis.base64Encode = function(str) { return java.base64Encode(str); };
        globalThis.base64Decode = function(str) { return java.base64Decode(str); };
        globalThis.md5Encode = function(str) { return java.md5Encode(str); };
        globalThis.sha256Encode = function(str) { return java.sha256Encode ? java.sha256Encode(str) : ''; };
        globalThis.aesEncode = function(data, key, iv) { return java.aesEncode(data, key, iv); };
        globalThis.aesDecode = function(data, key, iv) { return java.aesDecode(data, key, iv); };
        globalThis.getWebViewUA = function() { return java.getWebViewUA(); };
        globalThis.ajax = function(url, opt) { return java.ajax(url, opt); };
        globalThis.timeFormatUTC = function(ts, fmt, offset) { return java.timeFormatUTC(ts, fmt, offset); };

        // ===== 自动挂载所有 java 方法到 globalThis（对齐 Legado 行为）=====
        // Legado 中 JsExtensions 是接口实现，Rhino 直接把这些方法挂到全局
        // 书源可以直接写 getCookie() / readFile() 而不用 java.getCookie() / java.readFile()
        // 这里遍历 java 对象所有 function 类型的属性，自动挂载到 globalThis
        // 跳过子对象（jsoup/regex/webview/cache）和已显式挂载的方法
        (function() {
          var _alreadyMounted = {
            getString: true, put: true, getStr: true,
            base64Encode: true, base64Decode: true,
            md5Encode: true, sha256Encode: true,
            aesEncode: true, aesDecode: true,
            getWebViewUA: true, ajax: true, timeFormatUTC: true
          };
          Object.keys(java).forEach(function(k) {
            // 跳过子对象、已挂载的、私有方法（_开头）
            if (_alreadyMounted[k] || k.charAt(0) === '_') return;
            try {
              if (typeof java[k] === 'function' && typeof globalThis[k] === 'undefined') {
                globalThis[k] = function() {
                  // 用 apply 保证 this 指向 java 对象（访问内部 _javaCache 等）
                  return java[k].apply(java, arguments);
                };
              }
            } catch (e) {}
          });
        })();
      ''');
    } catch (_) {}

    // 4. 注入 CryptoJS（优先走原生 __nativeCrypto，失败回退纯 JS _AES 引擎）
    // 自动路径选择：数据 < 1KB 走字符串路径，>= 1KB 走 ArrayBuffer 零拷贝路径
    final cryptoCode = '''
      // 辅助：字符串转 Uint8Array（UTF-8 编码）
      function _strToU8(s) {
        var u8 = new Uint8Array(s.length * 4);
        var n = 0;
        for (var i = 0; i < s.length; i++) {
          var c = s.charCodeAt(i);
          if (c < 0x80) { u8[n++] = c; }
          else if (c < 0x800) { u8[n++] = 0xC0 | (c >> 6); u8[n++] = 0x80 | (c & 0x3F); }
          else { u8[n++] = 0xE0 | (c >> 12); u8[n++] = 0x80 | ((c >> 6) & 0x3F); u8[n++] = 0x80 | (c & 0x3F); }
        }
        return u8.subarray(0, n);
      }
      // 辅助：Uint8Array 转字符串（C 原生，零 JS 循环）
      function _u8ToStr(u8) {
        return __nativeBase64.uint8ToStr(u8);
      }
      // 辅助：base64 转 Uint8Array（C 原生，零 JS 循环）
      function _b64ToU8(b64) {
        return __nativeBase64.decodeToBytes(b64);
      }
      // 辅助：Uint8Array 转 base64（C 原生，零 JS 循环）
      function _u8ToB64(u8) {
        return __nativeBase64.b64FromBytes(u8);
      }
      // 辅助：Uint8Array 转 hex 字符串（小写）
      function _u8ToHex(u8) {
        var hex = '';
        for (var i = 0; i < u8.length; i++) {
          var b = u8[i];
          hex += (b < 16 ? '0' : '') + b.toString(16);
        }
        return hex;
      }
      // 辅助：自动选择路径阈值（1KB）
      var _CRYPTO_BINARY_THRESHOLD = 1024;

      var CryptoJS = {
        AES: {
          encrypt: function(data, key, cfg) {
            var iv = cfg && cfg.iv ? cfg.iv : null;
            var mode = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'ECB' : 'CBC';

            // Phase 5: 全 C 直通加密路径（明文字符串 → C 层加密 → base64 密文字符串）
            // 消除 _strToU8 → aesEncryptNative → _u8ToB64 的来回复制，一次 C 调用完成
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto &&
                __nativeCrypto.aesEncryptFromBase64) {
              try {
                var dataStr = typeof data === 'string' ? data :
                    (data && data.toString ? data.toString() : String(data));
                var dataB64 = java.base64Encode(dataStr);
                var keyStr = CryptoJS.enc.Utf8.stringify(key);
                var ivStr = iv ? CryptoJS.enc.Utf8.stringify(iv) : '';
                var ctB64;
                if (mode === 'CBC' && iv) {
                  ctB64 = __nativeCrypto.aesEncryptFromBase64(dataB64, keyStr, ivStr);
                } else if (mode === 'ECB') {
                  ctB64 = __nativeCrypto.aesEncryptFromBase64ECB(dataB64, keyStr);
                } else {
                  throw new Error('unsupported mode: ' + mode);
                }
                if (ctB64 && ctB64.length > 0) {
                  return {
                    toString: function() { return ctB64; },
                    ciphertext: { toString: function(enc) { return ctB64; } }
                  };
                }
              } catch (e) {}
            }

            // 优先走 C 原生 AES 加密（ArrayBuffer 模式，零 Dart 回调）
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto &&
                __nativeCrypto.aesEncryptNative) {
              try {
                var dataStr;
                if (typeof data === 'string') {
                  dataStr = data;
                } else if (data && data.toString) {
                  dataStr = data.toString();
                } else {
                  dataStr = String(data);
                }
                var keyStr = CryptoJS.enc.Utf8.stringify(key);
                var dataU8 = _strToU8(dataStr);
                var keyU8 = _strToU8(keyStr);
                if (mode === 'CBC' && iv) {
                  var ivStr = CryptoJS.enc.Utf8.stringify(iv);
                  var ivU8 = _strToU8(ivStr);
                  var cipherU8 = __nativeCrypto.aesEncryptNative(dataU8, keyU8, ivU8);
                  var resultB64 = _u8ToB64(cipherU8);
                  return {
                    toString: function() { return resultB64; },
                    ciphertext: { toString: function(enc) { return resultB64; } }
                  };
                } else if (mode === 'ECB') {
                  var cipherU8 = __nativeCrypto.aesEncryptNativeECB(dataU8, keyU8);
                  var resultB64 = _u8ToB64(cipherU8);
                  return {
                    toString: function() { return resultB64; },
                    ciphertext: { toString: function(enc) { return resultB64; } }
                  };
                }
              } catch (e) {
                // C 原生失败，回退到 Dart 回调或纯 JS
              }
            }

            // 回退：Dart 回调路径
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto &&
                __nativeCrypto.aesEncrypt && mode === 'CBC') {
              try {
                var dataStr;
                if (typeof data === 'string') {
                  dataStr = data;
                } else if (data && data.toString) {
                  dataStr = data.toString();
                } else {
                  dataStr = String(data);
                }
                var keyStr = CryptoJS.enc.Utf8.stringify(key);
                var ivStr = iv ? CryptoJS.enc.Utf8.stringify(iv) : '';
                var nativeResult = __nativeCrypto.aesEncrypt(dataStr, keyStr, ivStr);
                if (nativeResult !== null && nativeResult !== undefined) {
                  return {
                    toString: function() { return nativeResult; },
                    ciphertext: { toString: function(enc) { return nativeResult; } }
                  };
                }
              } catch (e) {}
            }

            // 最终回退：纯 JS _AES 引擎
            var result = _AES.encrypt(data, key, iv, mode);
            return { toString: function() { return result; }, ciphertext: { toString: function(enc) { return result; } } };
          },
          decrypt: function(data, key, cfg) {
            var iv = cfg && cfg.iv ? cfg.iv : null;
            var mode = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'ECB' : 'CBC';

            // Phase 5: 全 C 直通路径（base64 字符串 → C 层一站式解码+解密 → ArrayBuffer → UTF-8）
            // 消除 _b64ToU8 → aesDecryptNative → _u8ToStr 的来回复制，一次 C 调用完成
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto &&
                __nativeCrypto.aesDecryptFromBase64) {
              try {
                var dataB64;
                if (typeof data === 'string') {
                  dataB64 = data;
                } else if (data && data.ciphertext && typeof data.ciphertext.toString === 'function') {
                  dataB64 = data.ciphertext.toString(CryptoJS.enc.Base64);
                } else {
                  dataB64 = String(data);
                }
                var keyStr = CryptoJS.enc.Utf8.stringify(key);
                var ivStr = iv ? CryptoJS.enc.Utf8.stringify(iv) : '';
                var plainU8;
                if (mode === 'CBC' && iv) {
                  plainU8 = __nativeCrypto.aesDecryptFromBase64(dataB64, keyStr, ivStr);
                } else if (mode === 'ECB') {
                  plainU8 = __nativeCrypto.aesDecryptFromBase64ECB(dataB64, keyStr);
                } else {
                  throw new Error('unsupported mode: ' + mode);
                }
                if (plainU8 && plainU8.byteLength > 0) {
                  var nativeResult = _u8ToStr(plainU8);
                  if (nativeResult !== null && nativeResult !== undefined) {
                    return {
                      toString: function(enc) {
                        if (enc === CryptoJS.enc.Base64) {
                          return java.base64Encode(nativeResult) || '';
                        }
                        return nativeResult;
                      }
                    };
                  }
                }
              } catch (e) {}
            }

            // 优先走 C 原生 AES 解密（零 Dart 回调）
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto &&
                __nativeCrypto.aesDecryptNative) {
              try {
                // 提取 base64 密文
                var dataB64;
                if (typeof data === 'string') {
                  dataB64 = data;
                } else if (data && data.ciphertext && typeof data.ciphertext.toString === 'function') {
                  dataB64 = data.ciphertext.toString(CryptoJS.enc.Base64);
                } else {
                  dataB64 = String(data);
                }

                var keyStr = CryptoJS.enc.Utf8.stringify(key);
                var cipherU8 = _b64ToU8(dataB64);
                var keyU8 = _strToU8(keyStr);
                var plainU8;
                if (mode === 'CBC' && iv) {
                  var ivStr = CryptoJS.enc.Utf8.stringify(iv);
                  var ivU8 = _strToU8(ivStr);
                  plainU8 = __nativeCrypto.aesDecryptNative(cipherU8, keyU8, ivU8);
                } else if (mode === 'ECB') {
                  plainU8 = __nativeCrypto.aesDecryptNativeECB(cipherU8, keyU8);
                } else {
                  throw new Error('unsupported mode: ' + mode);
                }
                var nativeResult = _u8ToStr(plainU8);
                if (nativeResult !== null && nativeResult !== undefined) {
                  return {
                    toString: function(enc) {
                      if (enc === CryptoJS.enc.Base64) {
                        return java.base64Encode(nativeResult) || '';
                      }
                      return nativeResult;
                    }
                  };
                }
              } catch (e) {
                // C 原生失败，回退到 Dart 回调或纯 JS
              }
            }

            // 回退：Dart 回调路径
            if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto &&
                __nativeCrypto.aesDecrypt && mode === 'CBC') {
              try {
                var dataB64;
                if (typeof data === 'string') {
                  dataB64 = data;
                } else if (data && data.ciphertext && typeof data.ciphertext.toString === 'function') {
                  dataB64 = data.ciphertext.toString(CryptoJS.enc.Base64);
                } else {
                  dataB64 = String(data);
                }
                var keyStr = CryptoJS.enc.Utf8.stringify(key);
                var ivStr = iv ? CryptoJS.enc.Utf8.stringify(iv) : '';
                var nativeResult = __nativeCrypto.aesDecrypt(dataB64, keyStr, ivStr);
                if (nativeResult !== null && nativeResult !== undefined) {
                  return {
                    toString: function(enc) {
                      if (enc === CryptoJS.enc.Base64) {
                        return java.base64Encode(nativeResult) || '';
                      }
                      return nativeResult;
                    }
                  };
                }
              } catch (e) {}
            }

            // 最终回退：纯 JS _AES 引擎
            var result = _AES.decrypt(data, key, iv, mode);
            return { toString: function(enc) { return result; } };
          },
        },
        MD5: function(str) {
          // 优先走 C 原生实现（零 Dart 回调）
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.md5Native) {
            try {
              var u8 = _strToU8(str);
              var r8 = __nativeCrypto.md5Native(u8);
              var r = _u8ToHex(r8);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          // 回退到 Dart 回调
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.md5) {
            try {
              var r = __nativeCrypto.md5(str);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          return { toString: function() { return java.md5Encode(str); } };
        },
        SHA1: function(str) {
          // 优先走 C 原生实现
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.sha1Native) {
            try {
              var u8 = _strToU8(str);
              var r8 = __nativeCrypto.sha1Native(u8);
              var r = _u8ToHex(r8);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.sha1) {
            try {
              var r = __nativeCrypto.sha1(str);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          return { toString: function() { return java.sha1Encode ? java.sha1Encode(str) : ''; } };
        },
        SHA256: function(str) {
          // 优先走 C 原生实现
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.sha256Native) {
            try {
              var u8 = _strToU8(str);
              var r8 = __nativeCrypto.sha256Native(u8);
              var r = _u8ToHex(r8);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.sha256) {
            try {
              var r = __nativeCrypto.sha256(str);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          return { toString: function() { return java.sha256Encode ? java.sha256Encode(str) : ''; } };
        },
        HmacSHA256: function(data, key) {
          var keyStr = (typeof key === 'string') ? key : CryptoJS.enc.Utf8.stringify(key);
          // 优先走 C 原生实现
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.hmacSHA256Native) {
            try {
              var dataU8 = _strToU8(data);
              var keyU8 = _strToU8(keyStr);
              var r8 = __nativeCrypto.hmacSHA256Native(dataU8, keyU8);
              var r = _u8ToHex(r8);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto && __nativeCrypto.hmacSHA256) {
            try {
              var r = __nativeCrypto.hmacSHA256(data, keyStr);
              if (r) return { toString: function() { return r; } };
            } catch (e) {}
          }
          return { toString: function() { return java.hmacSHA256 ? java.hmacSHA256(data, key) : ''; } };
        },
        enc: {
          Utf8: {
            parse: function(s) { return _AES.utf8Parse(s); },
            stringify: function(w) {
              if (typeof w === 'string') return w;
              if (w && w.words) {
                var bytes = [];
                for (var i = 0; i < w.sigBytes; i++) {
                  var wi = Math.floor(i/4);
                  bytes.push((w.words[wi] >> (24 - (i%4)*8)) & 0xff);
                }
                var s = '';
                for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
                return decodeURIComponent(escape(s));
              }
              return String(w);
            }
          },
          Base64: {
            parse: function(s) { return _AES.base64Parse(s); },
            stringify: function(w) {
              if (typeof w === 'string') return java.base64Encode(w) || '';
              if (w && w.words) {
                var bytes = [];
                for (var i = 0; i < w.sigBytes; i++) {
                  var wi = Math.floor(i/4);
                  bytes.push((w.words[wi] >> (24 - (i%4)*8)) & 0xff);
                }
                return java.base64Encode(String.fromCharCode.apply(null, bytes)) || '';
              }
              return java.base64Encode(String(w)) || '';
            }
          },
          Hex: {
            parse: function(s) {
              var bytes = [];
              for (var i = 0; i < s.length; i += 2) bytes.push(parseInt(s.substr(i, 2), 16));
              var words = [];
              for (var i = 0; i < bytes.length; i += 4) {
                words.push(((bytes[i]||0)<<24)|((bytes[i+1]||0)<<16)|((bytes[i+2]||0)<<8)|(bytes[i+3]||0));
              }
              return { words: words, sigBytes: bytes.length };
            },
            stringify: function(w) {
              if (typeof w === 'string') return w;
              if (w && w.words) {
                var hex = '';
                for (var i = 0; i < w.sigBytes; i++) {
                  var wi = Math.floor(i/4);
                  hex += ('0' + ((w.words[wi] >> (24 - (i%4)*8)) & 0xff).toString(16)).slice(-2);
                }
                return hex;
              }
              return String(w);
            }
          },
          Latin1: { parse: function(s) { return s; }, stringify: function(w) { return typeof w === 'string' ? w : String(w); } },
        },
        mode: { ECB: {}, CBC: {} },
        pad: { Pkcs7: {}, ZeroPadding: {}, NoPadding: {}, Iso97971: {} },
        lib: {
          WordArray: {
            create: function(words, sigBytes) {
              return { words: words || [], sigBytes: sigBytes !== undefined ? sigBytes : (words ? words.length * 4 : 0), toString: function() { return (words || []).join(''); } };
            }
          }
        },
        algo: {},
      };

      // ===== globalThis.crypto 自动降级封装 =====
      // 对业务透明：内部先探测原生函数是否存在，否则自动 fallback 到 CryptoJS
      // JS 开发者无需手动写 try { __nativeCrypto.xxx } catch { CryptoJS.xxx }
      globalThis.crypto = {
        // 哈希算法：返回 hex 字符串
        md5: function(data) {
          try { return CryptoJS.MD5(data).toString(); }
          catch (e) { return ''; }
        },
        sha1: function(data) {
          try { return CryptoJS.SHA1(data).toString(); }
          catch (e) { return ''; }
        },
        sha256: function(data) {
          try { return CryptoJS.SHA256(data).toString(); }
          catch (e) { return ''; }
        },
        hmacSHA256: function(data, key) {
          try { return CryptoJS.HmacSHA256(data, key).toString(); }
          catch (e) { return ''; }
        },
        // AES 加解密：返回 base64 字符串 / 明文字符串
        aesEncrypt: function(data, key, iv) {
          try {
            var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv) } : null;
            return CryptoJS.AES.encrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString();
          } catch (e) { return ''; }
        },
        aesDecrypt: function(data, key, iv) {
          try {
            var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv) } : null;
            return CryptoJS.AES.decrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString(CryptoJS.enc.Utf8);
          } catch (e) { return ''; }
        },
        // 兼容 Web Crypto API（简化版）
        getRandomValues: function(typedArray) {
          for (var i = 0; i < typedArray.length; i++) {
            typedArray[i] = Math.floor(Math.random() * 256);
          }
          return typedArray;
        },
      };
    ''';
    try {
      evaluate(cryptoCode);
    } catch (e) {
    }

    // 5. 最终验证
    evaluate('typeof java !== "undefined" && typeof CryptoJS !== "undefined" && typeof _javaCache !== "undefined" && typeof _AES !== "undefined"');
  }

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
  void _logExecutionTrace(String script, int elapsedMs, bool isError, String? resultOrErr) {
    if (!kDebugMode) return;
    // 日志出锁设计：锁内只记录关键信息，字符串构建移到 AppLogger 中异步处理
    // 避免锁内在 debugPrint 上停留
    AppLogger.instance.debug(LogCategory.js, '[JS eval ${elapsedMs}ms ${isError ? "ERROR" : "OK"}] ${script.length > 80 ? "${script.substring(0, 80)}..." : script}',
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

  /// QuickJS 同步执行
  /// 支持并发防护 _evalBusy：如果 processJsRule 正持有锁，快速返回 null 避免 QuickJS 崩溃
  dynamic _executeQuickJSSync(String jsCode, dynamic content, {String? baseUrl, Map<String, dynamic>? variables}) {
    if (!_initialized || _jsRuntime == null) {
      return null;
    }

    // 并发防护：_evalBusy=true 表示 processJsRule 正通过 _evalLock 占用 QuickJS
    // 同步路径无法等待锁释放，直接返回 null，调用方（analyze_rule）收到 null 自动兜底
    if (_evalBusy) {
      _lastEvalError = 'JS引擎正忙（processJsRule 占用中），跳过同步执行';
      debugPrint('⚠️ $_lastEvalError');
      AppLogger.instance.warn(LogCategory.parse, _lastEvalError!);
      return null;
    }

    _evalBusy = true;
    try {
      // content 序列化：List/Map 直接 jsonEncode，String 也 jsonEncode（加引号转义），其他 toString
      final contentStr = serializeForJs(content);

      // 自动补 return：如果 JS 代码不以 return 结尾，自动包裹使其返回最后一个表达式的值
      final wrappedCode = _wrapJsCode(jsCode);

      // 构建变量注入代码（排除核心变量，避免覆盖 result/baseUrl/content）
      final coreVars = {'result', 'baseUrl', 'content', 'src'};
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
          var content = result;
          var src = ${variables?.containsKey('src') == true ? jsonEncode(variables!['src']?.toString() ?? '') : contentStr};
          $sharedVarsCode
          $varCode

          // 同步关键变量到 globalThis，让 jsLib 全局函数也能访问
          globalThis.result = result;
          globalThis.baseUrl = baseUrl;
          globalThis.src = src;
          $globalVarCode

          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
            // Uint8Array 转普通数组再 JSON（Legado ByteArray 契约）
            if (__returnValue instanceof Uint8Array) {
              return JSON.stringify(Array.from(__returnValue));
            }
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';
      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      _flushConsoleLogs();
      if (evalResult.isError) {
        AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
        // 追踪树：记录错误（由 executeSync 的 finally 统一 pop，这里只暂存错误信息）
        _lastEvalError = evalResult.stringResult;
        return null;
      }
      final parsed = _parseJsResult(evalResult.stringResult);
      // 同步执行完成日志（info 级别，Release 模式可见）
      AppLogger.instance.logJsStep('QuickJS', '同步执行完成',
        detail: 'resultType=${parsed?.runtimeType}, resultLen=${parsed?.toString().length ?? 0}, isError=${evalResult.isError}');
      return parsed;
    } catch (e) {
      AppLogger.instance.logJsError('QuickJS', e.toString());
      _lastEvalError = e.toString();
      // 引擎级错误（OOM/段错误兜底）记录到崩溃日志
      unawaited(CrashLogService.instance.logJsEngineError('QuickJS.eval', e.toString()));
      return null;
    } finally {
      _evalBusy = false;
    }
  }

  /// 包裹 JS 代码，确保最后一个表达式的值被返回
  /// 如果代码已经包含 return 语句，直接使用
  /// 如果没有 return，在代码末尾添加 return 语句
  String _wrapJsCode(String code) {
    final trimmed = code.trim();

    // 已经有 return 语句 → 直接使用
    if (trimmed.contains(_returnRegex)) {
      return trimmed;
    }

    // 单行代码：直接 return
    final lines = trimmed.split('\n');
    if (lines.length == 1) {
      return 'return $trimmed';
    }

    // 多行代码：需要判断最后一行是否是独立表达式
    final lastLine = lines.last.trim();

    if (lastLine.isEmpty) {
      return trimmed;
    }

    // 借鉴 legado：多行代码用 eval 包裹，确保最后一个表达式的值被返回
    // 这样可以处理跨行表达式（如 JSON.stringify({...})）
    // eval 在 IIFE 内部执行，最后一个表达式的值就是 eval 的返回值
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

    // 借鉴 legado 的 preCache 机制：在执行 JS 前，预缓存 java.ajax/get/post 的结果
    try {
      await _preCacheBridgeCalls(resolved.code, env: mergedEnv);
    } catch (e) {
      AppLogger.instance.warn(LogCategory.js, '预缓存桥接调用失败，继续执行JS', detail: e.toString());
    }

    // 输出 processJsRule 入参信息（info 级别，Release 模式可见）
    AppLogger.instance.logJsInput('QuickJS',
      actualResult is String ? actualResult : actualResult?.toString(),
      tag: 'processJsRule');
    AppLogger.instance.logJsStep('QuickJS', '[processJsRule] 入参',
      detail: 'result type=${actualResult.runtimeType}, len=${actualResult is String ? actualResult.length : (actualResult is List ? actualResult.length : '?')}, baseUrl=$baseUrl');

    // 让出事件循环，避免长时间 JS 执行阻塞 UI 刷新
    await Future(() {});

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
          var content = result;
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
            // Uint8Array 转普通数组再 JSON（Legado ByteArray 契约）
            if (__returnValue instanceof Uint8Array) {
              return JSON.stringify(Array.from(__returnValue));
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
  static const _coreEnvVars = {'result', 'baseUrl', 'content', 'src', 'book', 'chapter', 'source', 'cookie', 'title'};

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
      final coreVars = {'result', 'baseUrl', 'content', 'src', 'book', 'chapter', 'source', 'cookie', 'title'};
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
            var _data = ${jsonEncode(env?['source'] ?? {})};
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
            // Uint8Array 转普通数组再 JSON（Legado ByteArray 契约）
            if (__returnValue instanceof Uint8Array) {
              return JSON.stringify(Array.from(__returnValue));
            }
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';
      // 先 yield 让出事件循环，避免长时间 JS 执行阻塞 UI 刷新
      await Future(() {});
      final evalResult = _jsRuntime!.evaluate(wrappedScript);

      // 提取 console 缓存的日志，同步到 AppLogger（借鉴 legado 的调试输出机制）
      _flushConsoleLogs();

      // 断点3：记录执行结果
      final evalResultStr = evalResult.stringResult;
      final resultShort = evalResultStr;
      // 异步执行完成日志（info 级别，Release 模式可见）
      AppLogger.instance.logJsStep('QuickJS', '[QuickJS] 异步执行完成',
        detail: 'isError=${evalResult.isError}, result=$resultShort');

      if (evalResult.isError) {
        AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
        // 追踪树：记录错误
        if (traceNode != null) {
          JsTracer.instance.pop(
            outputPreview: resultShort,
            outputType: 'error',
            error: resultShort,
          );
        }
        // 输出执行树到日志（info 级别）
        _logCurrentTraceTree();
        return null;
      }
      final strResult = evalResult.stringResult;
      // 追踪树：记录成功输出
      if (traceNode != null) {
        JsTracer.instance.pop(
          outputPreview: strResult,
          outputType: 'String',
        );
      }
      // 输出完整执行结果到日志链路（info 级别）
      AppLogger.instance.logJsOutput('QuickJS', strResult, outputType: 'String', tag: 'async');
      // 输出执行树到日志（info 级别）
      _logCurrentTraceTree();
      // undefined → 返回空字符串而不是 null（书源规则可能不需要返回值）
      if (strResult == 'undefined') return '';
      // null → 返回 Dart null，避免 "null" 字符串被当作有效结果
      if (strResult == 'null') return null;
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
  void _flushConsoleLogs() {
    if (!_initialized || _jsRuntime == null) return;
    // Release 模式跳过日志提取（性能优化）
    if (kReleaseMode) return;
    // 防递归：内部调用 evaluate 时不再次触发 _flushConsoleLogs
    if (_isFlushingLogs) return;
    _isFlushingLogs = true;
    try {
      // 单次 evaluate：检查+获取+清除日志
      final result = evaluate('''(function(){
  var logs = [];
  if(typeof __consoleLogs !== "undefined" && __consoleLogs.length > 0){
    logs = __consoleLogs.slice();
    __consoleLogs.length = 0;
  } else if(typeof console !== "undefined" && typeof console._getLogs === "function"){
    logs = console._getLogs();
    if(console._clearLogs) console._clearLogs();
  } else if(typeof console === "undefined" || typeof console._getLogs !== "function"){
    return "NEED_REINJECT";
  }
  return JSON.stringify(logs);
})()''');
      if (result == null || result == 'undefined' || result == '[]' || result.isEmpty) return;
      if (result == 'NEED_REINJECT') {
        // 重新注入 console
        evaluate('var __consoleLogs = []; globalThis.console = { log: function() { var msg = Array.from(arguments).join(" "); __consoleLogs.push({level:"log", msg:msg}); }, warn: function() { var msg = Array.from(arguments).join(" "); __consoleLogs.push({level:"warn", msg:msg}); }, error: function() { var msg = Array.from(arguments).join(" "); __consoleLogs.push({level:"error", msg:msg}); }, info: function() { var msg = Array.from(arguments).join(" "); __consoleLogs.push({level:"info", msg:msg}); }, debug: function() { var msg = Array.from(arguments).join(" "); __consoleLogs.push({level:"debug", msg:msg}); } };');
        return;
      }
      if (!result.startsWith('[')) return;
      final logs = jsonDecode(result) as List;
      for (final log in logs) {
        if (log is! Map) continue;
        final level = log['level'] as String? ?? 'log';
        final msg = log['msg']?.toString() ?? '';
        if (msg.isEmpty) continue;
        switch (level) {
          case 'error':
            AppLogger.instance.error(LogCategory.js, msg);
          case 'warn':
            AppLogger.instance.warn(LogCategory.js, msg);
          case 'info':
            AppLogger.instance.info(LogCategory.js, msg);
          case 'debug':
            AppLogger.instance.debug(LogCategory.js, msg);
          default:
            AppLogger.instance.info(LogCategory.js, msg);
        }
      }
    } catch (_) {} finally {
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
      // Uint8List → JS new Uint8Array([...])，匹配 Legado ByteArray 契约
      if (content is Uint8List) {
        return 'new Uint8Array([${content.join(',')}])';
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
      final script = '''
        (function() {
          var text = ${jsonEncode(text)};
          var pattern = $pattern;
          var replacement = ${jsonEncode(replacement)};
          return text.replace(new RegExp(pattern, 'g'), replacement);
        })();
      ''';
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
      final script = '''
        (function() {
          return java.jsoup.selectFirst(${jsonEncode(html)}, ${jsonEncode(selector)});
        })();
      ''';
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
      final script = '''
        (function() {
          var data = JSON.parse(${jsonEncode(jsonStr)});
          var path = ${jsonEncode(path)};
          var parts = path.replace(/^\\\$\\\./, '').split('.');
          var result = data;
          for (var i = 0; i < parts.length; i++) {
            if (result == null) return null;
            result = result[parts[i]];
          }
          return JSON.stringify(result);
        })();
      ''';
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
    if (jsLib.trim().isEmpty) return;

    // 缓存 jsLib 代码
    _jsLibCache[sourceUrl] = jsLib;

    // 如果当前已加载的就是同一个书源，不需要重新加载
    if (_currentJsLibSourceUrl == sourceUrl) return;

    // 切换书源：先清除旧的 jsLib 全局函数
    _clearCurrentJsLib();

    // 提取 jsLib 中定义的函数名（用于后续清除）
    _extractFunctionNames(jsLib);

    // 把 jsLib eval 到全局作用域（等价于 legado 的 RhinoScriptEngine.eval(jsLib, scope)）
    try {
      _jsRuntime?.evaluate(jsLib);
      _currentJsLibSourceUrl = sourceUrl;
    } catch (e) {
    }
  }

  /// 清除当前已加载的 jsLib 全局函数
  /// 借鉴 legado 的 scope 切换机制：切换书源时清除旧的 scope
  void _clearCurrentJsLib() {
    if (_currentJsLibFunctions.isEmpty || _jsRuntime == null) return;
    try {
      final deleteCode = _currentJsLibFunctions.map((fn) => 'try{delete globalThis.$fn}catch(e){}').join(';');
      _jsRuntime!.evaluate(deleteCode);
    } catch (e) {
    }
    _currentJsLibFunctions.clear();
    _currentJsLibSourceUrl = null;
  }

  /// 提取 JS 代码中定义的函数名
  /// 匹配 function xxx() 和 var/const/let/this.xxx = function/()=> 模式
  static final _funcNamePattern = RegExp(r'function\s+(\w+)\s*\(');
  static final _varFuncPattern = RegExp(r'(?:var|const|let)\s+(\w+)\s*=\s*(?:function|\(|[^(]*=>)');
  static final _thisFuncPattern = RegExp(r'this\.(\w+)\s*=\s*(?:function|\(|[^(]*=>)');

  void _extractFunctionNames(String jsLib) {
    _currentJsLibFunctions.clear();
    for (final m in _funcNamePattern.allMatches(jsLib)) {
      _currentJsLibFunctions.add(m.group(1)!);
    }
    for (final m in _varFuncPattern.allMatches(jsLib)) {
      _currentJsLibFunctions.add(m.group(1)!);
    }
    for (final m in _thisFuncPattern.allMatches(jsLib)) {
      _currentJsLibFunctions.add(m.group(1)!);
    }
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
      evaluate('_javaCache = {};');
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
    final script = '_javaCache["$cacheKey"] = ${jsonEncode(result)};';
    evaluate(script);
    _cachedKeys.add(cacheKey);
  }

  /// 批量预缓存 HTTP 结果（在 processJsRule 前调用）
  /// 解决 QuickJS 同步模式下 java.ajax() 无法异步请求的问题
  Future<void> preCacheHttpResults(Map<String, String> urlResults) async {
    final entries = urlResults.entries.map((e) {
      _cachedKeys.add(e.key);
      return '_javaCache["${e.key}"] = ${jsonEncode(e.value)};';
    }).join('\n');
    if (entries.isNotEmpty) {
      evaluate(entries);
    }
  }

  /// 批量预缓存加密结果
  Future<void> preCacheCryptoResults(Map<String, String> cryptoResults) async {
    final entries = cryptoResults.entries.map((e) {
      _cachedKeys.add(e.key);
      return '_javaCache["${e.key}"] = ${jsonEncode(e.value)};';
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
        final exprCases = <String>[];
        for (var i = 0; i < varExprs.length; i++) {
          exprCases.add('try { var __u$i = String(${varExprs[i]}); if(__u$i.startsWith("http")) __results.push(__u$i); } catch(e) {}');
        }
        final evalScript = '${varCode.join('\n')} var __results = []; ${exprCases.join('\n')}; JSON.stringify(__results);';
        final batchResult = evaluate(evalScript);
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
          String? result;
          if (url.startsWith('http://')) {
            final r = nativeHttpGet(url,
                headers: customHeaders?.entries.map((e) => '${e.key}: ${e.value}').join('\r\n'));
            result = r?['body'] as String?;
          } else {
            result = await NativeChannel.instance.httpGet(url, headers: customHeaders);
          }
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
        if (postUrls.isNotEmpty) {
          final customHeaders = env?['headers'] as Map<String, String>?;
          final postResults = await _runWithConcurrency(() => postUrls.entries.map((entry) async {
            try {
              String? result;
              if (entry.key.startsWith('http://')) {
                final hdr = customHeaders?.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
                final r = nativeHttpPost(entry.key, entry.value, headers: hdr);
                result = r?['body'] as String?;
              } else {
                result = await NativeChannel.instance.httpPost(
                  entry.key,
                  body: entry.value,
                  headers: customHeaders,
                );
              }
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
              final result = await NativeChannel.instance.httpHead(url, headers: customHeaders);
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
          final result = await NativeChannel.instance.httpDownload(absoluteUrl, savePath);
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
                await NativeChannel.instance.httpDownload(firstArg, localPath);
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
      final cached = evaluate('_javaCache[${jsonEncode(httpCacheKey)}]');
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
            final evalResult = evaluate('(function(){ try { var __v = $firstArg; return (typeof __v === "string" && __v.length > 50) ? __v : ""; } catch(e) { return ""; } })()');
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
        evaluate('_javaCache[${jsonEncode(sfKey)}] = ${jsonEncode(parsed['first'])};');
        _cachedKeys.add(sfKey);
      }
      if (!_isCached(saKey)) {
        evaluate('_javaCache[${jsonEncode(saKey)}] = ${jsonEncode(parsed['all'])};');
        _cachedKeys.add(saKey);
      }
      // 缓存 text/href/src 供 java.getString 快速访问
      final textKey = 'jsoup_text:$selector:$htmlHash';
      final hrefKey = 'jsoup_href:$selector:$htmlHash';
      if (parsed['text'] != null && !_isCached(textKey)) {
        evaluate('_javaCache[${jsonEncode(textKey)}] = ${jsonEncode(parsed['text'])};');
        _cachedKeys.add(textKey);
      }
      if (parsed['href'] != null && (parsed['href'] as String).isNotEmpty && !_isCached(hrefKey)) {
        evaluate('_javaCache[${jsonEncode(hrefKey)}] = ${jsonEncode(parsed['href'])};');
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
          evaluate('_javaCache[${jsonEncode(gaKey)}] = ${jsonEncode(attrValue ?? '')};');
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
  String _resolveUrl(String url, String baseUrl) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    if (baseUrl.isEmpty) return url;
    try {
      return Uri.parse(baseUrl).resolve(url).toString();
    } catch (_) {
      return url;
    }
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
