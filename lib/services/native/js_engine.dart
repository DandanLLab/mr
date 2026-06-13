import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import '../app_logger.dart';
import 'platform_channel.dart';
import 'shared_js_scope.dart';

// ===== 分流引擎架构 =====

/// JS 引擎类型枚举
enum JsEngineType {
  /// QuickJS 引擎（flutter_js），原生支持 ES6+
  quickjs,

  /// Rhino 引擎（Android 原生），支持 Java 互操作
  rhino,
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
  final String engine;        // QuickJS / Rhino→QuickJS
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
      buf.writeln('$prefix│  input: ${inp.length > 100 ? '${inp.substring(0, 100)}...' : inp}');
    }
    if (outputPreview != null && outputPreview!.isNotEmpty) {
      final out = outputPreview!.replaceAll('\n', '\\n');
      buf.writeln('$prefix│  output($outputType): ${out.length > 100 ? '${out.substring(0, 100)}...' : out}');
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

  /// 是否启用追踪
  bool enabled = true;

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

/// JS/TS 运行时引擎 - 分流双引擎架构
///
/// 架构设计：
/// - QuickJS 引擎：处理 ES6+ 语法，作为默认引擎
/// - Rhino 引擎：处理 Java 互操作（通过 NativeChannel）
/// - 分流策略：显式声明 > 关键词自动识别 > 默认 QuickJS
/// - 桥接层：两个引擎共享缓存和变量
class JsEngine {
  static JsEngine? _instance;
  static JsEngine get instance => _instance ??= JsEngine._();

  JsEngine._();

  bool _initialized = false;
  JavascriptRuntime? _jsRuntime;
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

  /// 跨引擎共享缓存（QuickJS 和 Rhino 均可读写）
  final Map<String, String> _bridgeCache = {};

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
    if (_initialized && _jsRuntime != null) {
      // 验证全局对象是否仍然存在（防止运行时被意外重置）
      final check = evaluate('typeof java !== "undefined" && typeof CryptoJS !== "undefined" && typeof _javaCache !== "undefined" && typeof _AES !== "undefined"');
      if (check == 'true') return true;
      // 全局对象丢失，需要重新注入
      debugPrint('JsEngine: 全局对象丢失，重新注入 polyfills');
      _injectJavaBridge();
      final recheck = evaluate('typeof java !== "undefined"');
      if (recheck == 'true') return true;
      // 重新注入也失败，重建运行时
      debugPrint('JsEngine: 重新注入失败，重建运行时');
      _jsRuntime?.dispose();
      _jsRuntime = null;
      _initialized = false;
    }

    if (_initialized) return true;
    try {
      _jsRuntime = getJavascriptRuntime();
      // 先标记运行时可用，再注入 polyfills
      // 注意：_initialized 在所有注入完成后才设为 true
      await _injectNodePolyfills();
      _injectJavaBridge();
      await _loadInstalledPackages();

      // 验证注入是否成功
      final verifyResult = evaluate('typeof java !== "undefined" && typeof CryptoJS !== "undefined" && typeof _javaCache !== "undefined" && typeof _AES !== "undefined"');
      if (verifyResult != 'true') {
        debugPrint('JsEngine: 注入验证失败！java=${evaluate('typeof java')}, CryptoJS=${evaluate('typeof CryptoJS')}, _javaCache=${evaluate('typeof _javaCache')}, _AES=${evaluate('typeof _AES')}');
        // 尝试重新注入
        _injectJavaBridge();
        final retryResult = evaluate('typeof java !== "undefined" && typeof _AES !== "undefined"');
        if (retryResult != 'true') {
          debugPrint('JsEngine: 重新注入仍然失败，初始化失败');
          return false;
        }
      }

      _initialized = true;
      return true;
    } catch (e) {
      debugPrint('JsEngine init error: $e');
      return false;
    }
  }

  bool get isAvailable => _initialized && _jsRuntime != null;

  // ===== 分流策略 =====

  /// 解析规则代码，确定使用哪个引擎（公开，供 EngineDispatcher 调用）
  ///
  /// 优先级：
  /// 1. 显式前缀声明：@rhino: / @quickjs: / @java: / @ts: / @js:
  /// 2. 关键词自动识别（无显式声明时）
  /// 3. 书源级全局声明（sourceEngine 参数）
  /// 4. 默认 QuickJS
  _EngineResolveResult resolveEngine(String ruleCode, {JsEngineType? sourceEngine}) {
    // 1. 显式前缀声明
    if (ruleCode.startsWith('@rhino:') || ruleCode.startsWith('<rhino>')) {
      final code = ruleCode.startsWith('@rhino:')
          ? ruleCode.substring(7)
          : ruleCode.replaceAll(RegExp(r'^<rhino>|</rhino>$'), '');
      return _EngineResolveResult(JsEngineType.rhino, code);
    }

    if (ruleCode.startsWith('@quickjs:') || ruleCode.startsWith('<quickjs>')) {
      final code = ruleCode.startsWith('@quickjs:')
          ? ruleCode.substring(9)
          : ruleCode.replaceAll(RegExp(r'^<quickjs>|</quickjs>$'), '');
      return _EngineResolveResult(JsEngineType.quickjs, code);
    }

    if (ruleCode.startsWith('@java:') || ruleCode.startsWith('<java>')) {
      final code = ruleCode.startsWith('@java:')
          ? ruleCode.substring(6)
          : ruleCode.replaceAll(RegExp(r'^<java>|</java>$'), '');
      return _EngineResolveResult(JsEngineType.rhino, code);
    }

    if (ruleCode.startsWith('@ts:') || ruleCode.startsWith('<ts>')) {
      final code = ruleCode.startsWith('@ts:')
          ? ruleCode.substring(4)
          : ruleCode.replaceAll(RegExp(r'^<ts>|</ts>$'), '');
      // TS 编译后由 QuickJS 执行
      return _EngineResolveResult(JsEngineType.quickjs, code);
    }

    // 2. @js: 或 <js> 前缀 → 自动识别
    String code = ruleCode;
    if (ruleCode.startsWith('@js:')) {
      code = ruleCode.substring(4);
    } else if (ruleCode.startsWith('<js>')) {
      code = ruleCode.replaceAll(RegExp(r'^<js>|</js>$'), '');
    }

    // 自动识别引擎
    final autoDetected = _autoDetectEngine(code);

    // 3. 如果自动识别不出明确倾向，使用书源级声明
    if (autoDetected == null && sourceEngine != null) {
      return _EngineResolveResult(sourceEngine, code);
    }

    // 4. 默认 QuickJS
    return _EngineResolveResult(autoDetected ?? JsEngineType.quickjs, code);
  }

  /// 关键词自动识别引擎
  ///
  /// - 含 java. 前缀调用且无 ES6 特征 → Rhino
  /// - 含 ES6 特征（不管有无 java.*）→ QuickJS
  /// - 无法确定 → null（使用书源级声明或默认值）
  JsEngineType? _autoDetectEngine(String code) {
    final hasJavaCall = RegExp(r'\bjava\.').hasMatch(code);
    final hasES6 = RegExp(
      r'\bconst\b|\blet\b|=>|\basync\b|\bawait\b|\.\.\.|\bclass\b|\bimport\b|`[^`]*\$\{',
    ).hasMatch(code);

    if (hasES6) {
      // ES6 特征 → QuickJS（java.* 通过桥接调用）
      return JsEngineType.quickjs;
    }

    if (hasJavaCall && !hasES6) {
      // 纯 Java 互操作，无 ES6 → Rhino
      return JsEngineType.rhino;
    }

    // 无法确定，返回 null 让上层决定
    return null;
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
      globalThis.console = {
        log: function() { var msg = Array.from(arguments).join(' '); _consoleLogs.push({level:'log', msg:msg}); },
        warn: function() { var msg = Array.from(arguments).join(' '); _consoleLogs.push({level:'warn', msg:msg}); },
        error: function() { var msg = Array.from(arguments).join(' '); _consoleLogs.push({level:'error', msg:msg}); },
        info: function() { var msg = Array.from(arguments).join(' '); _consoleLogs.push({level:'info', msg:msg}); },
        debug: function() { var msg = Array.from(arguments).join(' '); _consoleLogs.push({level:'debug', msg:msg}); },
        dir: function(obj) { _consoleLogs.push({level:'log', msg: JSON.stringify(obj, null, 2)}); },
        table: function(data) { _consoleLogs.push({level:'log', msg: JSON.stringify(data, null, 2)}); },
        time: function(label) { _consoleLogs._timers = _consoleLogs._timers || {}; _consoleLogs._timers[label] = Date.now(); },
        timeEnd: function(label) { _consoleLogs._timers = _consoleLogs._timers || {}; if (_consoleLogs._timers[label]) { var ms = Date.now() - _consoleLogs._timers[label]; _consoleLogs.push({level:'info', msg: label + ': ' + ms + 'ms'}); delete _consoleLogs._timers[label]; } },
        count: function(label) { _consoleLogs._counts = _consoleLogs._counts || {}; _consoleLogs._counts[label] = (_consoleLogs._counts[label] || 0) + 1; _consoleLogs.push({level:'info', msg: label + ': ' + _consoleLogs._counts[label]}); },
        assert: function(condition) { if (!condition) { var msg = Array.from(arguments).slice(1).join(' ') || 'Assertion failed'; _consoleLogs.push({level:'error', msg: msg}); } },
        clear: function() { _consoleLogs.length = 0; },
        _getLogs: function() { return _consoleLogs; },
        _clearLogs: function() { _consoleLogs.length = 0; },
      };

      // ===== btoa/atob 全局函数 =====
      // Base64 编码/解码，QuickJS 原生可能不提供
      if (typeof btoa === 'undefined') {
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
        debugPrint('JsEngine: _AES 引擎注入成功');
      } else {
        debugPrint('JsEngine: _AES 引擎注入后验证失败');
        _injectAesFallback();
      }
    } catch (e) {
      debugPrint('JsEngine: _AES 引擎注入失败: $e，使用 fallback');
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
        debugPrint('JsEngine: _MD5 引擎注入成功');
      } else {
        debugPrint('JsEngine: _MD5 引擎注入后验证失败');
      }
    } catch (e) {
      debugPrint('JsEngine: _MD5 引擎注入失败: $e');
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
        debugPrint('JsEngine: SHA1/SHA256/HMAC-SHA256 引擎注入成功');
      } else {
        debugPrint('JsEngine: SHA 引擎注入后验证失败');
      }
    } catch (e) {
      debugPrint('JsEngine: SHA 引擎注入失败: $e');
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
      debugPrint('JsEngine: _javaCache 注入失败: $e');
      try { evaluate('var _javaCache = {};'); } catch (_) {}
    }

    // 2. 注入纯 JS AES 引擎（不依赖 Dart 桥接，QuickJS 同步可用）
    _injectAesEngine();

    // 2.5 注入纯 JS MD5 引擎
    _injectMd5Engine();

    // 2.6 注入纯 JS SHA1/SHA256/HMAC-SHA256 引擎
    _injectShaEngine();
    // 注意：不能使用 const，因为字符串中包含 $ 符号（JS 正则替换引用 $&）
    final helperCode = """
      // ===== Legado Java 桥接对象（QuickJS 侧）=====
      // 借鉴 legado 的 JsExtensions 接口，通过 Dart 侧 NativeChannel 桥接
      // 核心策略：同步模式从 _javaCache 取缓存值，异步模式由 Dart 端预缓存
      // _javaCache 已在前面注入，这里不再重复声明

      // ===== 内置 HTML 解析器（精简版：优先从 Dart 预缓存取结果，仅做最小正则兜底）=====
      // Dart 端通过 _nativeJsoupParse + _preCacheBridgeCalls 已将解析结果写入 _javaCache
      // JS 侧只需查缓存，未命中时用简单正则兜底
      var _JsoupLite = {
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
        selectFirst: function(html, selector) {
          var key = _JsoupLite._cacheKey('jsoup_sf', selector, html);
          if (_javaCache[key] !== undefined) return _javaCache[key];
          return _JsoupLite._fallback(html, selector, true);
        },
        selectAll: function(html, selector) {
          var key = _JsoupLite._cacheKey('jsoup_sa', selector, html);
          if (_javaCache[key] !== undefined) return _javaCache[key];
          return _JsoupLite._fallback(html, selector, false);
        },
        getAttr: function(html, selector, attr) {
          var key = _JsoupLite._cacheKey('jsoup_ga', selector + ':' + attr, html);
          if (_javaCache[key] !== undefined) return _javaCache[key];
          var el = _JsoupLite.selectFirst(html, selector);
          if (!el) return '';
          var m = (typeof el === 'string' ? el : '').match(new RegExp(attr + '=["\\']([^"\\']*)["\\']', 'i'));
          return m ? m[1] : '';
        },
        _fallback: function(html, selector, firstOnly) {
          if (!html || !selector) return firstOnly ? '' : [];
          var sel = selector.trim();
          // Simple .class
          if (sel.startsWith('.') && sel.indexOf(' ', 1) < 0 && sel.indexOf('>') < 0) {
            var cls = sel.substring(1);
            var re = new RegExp('<([a-zA-Z][a-zA-Z0-9]*)[^>]*class="[^"]*\\\\b' + cls.replace(/[.*+?^\${}()|[\\]\\\\]/g, '\\\\\$&') + '\\\\b[^"]*"[^>]*>([\\\\s\\\\S]*?)</\\\\1>', 'gi');
            if (firstOnly) { var m = re.exec(html); return m ? m[0] : ''; }
            var results = []; var m2; while ((m2 = re.exec(html)) !== null) results.push(m2[0]); return results;
          }
          // Simple tag
          if (/^[a-zA-Z][a-zA-Z0-9]*\$/.test(sel)) {
            var tagRe = new RegExp('<' + sel + '[^>]*>([\\\\s\\\\S]*?)</' + sel + '>', 'gi');
            if (firstOnly) { var m = tagRe.exec(html); return m ? m[0] : ''; }
            var results2 = []; var m3; while ((m3 = tagRe.exec(html)) !== null) results2.push(m3[0]); return results2;
          }
          // Simple #id
          if (sel.startsWith('#')) {
            var id = sel.substring(1);
            var idRe = new RegExp('<([a-zA-Z][a-zA-Z0-9]*)[^>]*id="' + id.replace(/[.*+?^\${}()|[\\]\\\\]/g, '\\\\\$&') + '"[^>]*>([\\\\s\\\\S]*?)</\\\\1>', 'i');
            var m4 = idRe.exec(html);
            if (firstOnly) return m4 ? m4[0] : '';
            return m4 ? [m4[0]] : [];
          }
          return firstOnly ? '' : [];
        }
      };

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

        // ===== 加密/解密（优先使用纯 JS _AES 引擎，fallback 到缓存）=====
        aesEncode: function(data, key, iv) {
          var cacheKey = 'aes_enc:' + data + ':' + key + ':' + (iv || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          try {
            var mode = iv ? 'CBC' : 'ECB';
            var result = _AES.encrypt(data, key, iv, mode);
            _javaCache[cacheKey] = result;
            return result;
          } catch(e) { return ''; }
        },
        aesDecode: function(data, key, iv) {
          var cacheKey = 'aes_dec:' + data + ':' + key + ':' + (iv || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          try {
            var mode = iv ? 'CBC' : 'ECB';
            var result = _AES.decrypt(data, key, iv, mode);
            _javaCache[cacheKey] = result;
            return result;
          } catch(e) { return ''; }
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
        base64Encode: function(str) {
          try {
            if (typeof btoa === 'function') return btoa(unescape(encodeURIComponent(str)));
          } catch(e) {}
          return '';
        },
        base64Decode: function(str) {
          try {
            if (typeof atob === 'function') return decodeURIComponent(escape(atob(str)));
          } catch(e) {}
          return '';
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
          select: function(html, selector) { return _JsoupLite.selectAll(html, selector); },
          selectFirst: function(html, selector) { return _JsoupLite.selectFirst(html, selector); },
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
        getTime: function() {
          return Date.now();
        },
        encodeURI: function(str) {
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

        // legado 兼容：java.webView(htmlOrJs, baseUrl, extra)
        // 在 legado 中，java.webView 用于执行包含 JS 的 HTML 并获取渲染结果
        // QuickJS 同步模式下无法真正渲染 WebView，尝试从缓存获取
        webView: function(htmlOrJs, baseUrl, extra) {
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
        getCookie: function(tag, key) {
          var cacheKey = 'cookie:' + tag + (key ? ':' + key : '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.startBrowser(url, title) — 打开浏览器（移动端专用，QuickJS 空操作）
        startBrowser: function(url, title) {},
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
        // java.cacheFile(url) — 缓存文件到本地
        cacheFile: function(url, saveTime) {
          var cacheKey = 'cache_file:' + url;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.importScript(path) — 导入脚本
        importScript: function(path) {
          var cacheKey = 'import_script:' + path;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        // java.readFile(path) / java.readTxtFile(path) — 读取文件
        readFile: function(path) { return ''; },
        readTxtFile: function(path, charset) { return ''; },
        // java.deleteFile(path) — 删除文件
        deleteFile: function(path) { return false; },
        // java.unzipFile(path) / java.un7zFile / java.unrarFile / java.unArchiveFile — 解压
        unzipFile: function(path) { return ''; },
        un7zFile: function(path) { return ''; },
        unrarFile: function(path) { return ''; },
        unArchiveFile: function(path) { return ''; },
        // java.getTxtInFolder(path) — 读取文件夹下所有 txt
        getTxtInFolder: function(path) { return ''; },
        // java.openUrl(url) — 打开 URL
        openUrl: function(url, mimeType) {},
        // java.getReadBookConfig() — 获取阅读配置
        getReadBookConfig: function() { return '{}'; },
        // java.getThemeMode() — 获取主题模式
        getThemeMode: function() { return 'light'; },
        // java.getThemeConfig() — 获取主题配置
        getThemeConfig: function() { return '{}'; },
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
        createSymmetricCrypto: function(transformation, key, iv) {
          // 简化实现：返回一个包含 encrypt/decrypt 方法的对象
          var keyStr = typeof key === 'string' ? key : (key ? String(key) : '');
          var ivStr = typeof iv === 'string' ? iv : (iv ? String(iv) : '');
          return {
            encrypt: function(data) { return java.aesEncode(data, keyStr, ivStr); },
            decrypt: function(data) { return java.aesDecode(data, keyStr, ivStr); },
            encryptBase64: function(data) { return java.aesEncodeToBase64String(data, keyStr, '', ivStr); },
            decryptBase64: function(data) { return java.aesBase64DecodeToString(data, keyStr, '', ivStr); }
          };
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
        // java.createAsymmetricCrypto(transformation) — 创建非对称加密器
        createAsymmetricCrypto: function(transformation) {
          return { encrypt: function(data) { return ''; }, decrypt: function(data) { return ''; } };
        },
        // java.createSign(algorithm) — 创建签名器
        createSign: function(algorithm) {
          return { sign: function(data) { return ''; }, verify: function(data, sig) { return false; } };
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
      evaluate(helperCode);
    } catch (e) {
      debugPrint('JsEngine: java 对象注入失败: $e');
    }

    // 4. 验证 java 对象是否注入成功
    final javaCheck = evaluate('typeof java !== "undefined"');
    if (javaCheck != 'true') {
      debugPrint('JsEngine: java 对象注入失败，尝试简化版注入');
      // 简化版：只注入核心方法
      evaluate('''
        var java = {
          get: function(url) { var cacheKey = 'http_get:' + url; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
          post: function(url, body) { var cacheKey = 'http_post:' + url; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
          ajax: function(url) { return java.get(url); },
          put: function(key, value) { _javaCache[key] = typeof value === 'object' ? JSON.stringify(value) : String(value); },
          getStr: function(key, def) { return _javaCache[key] || (def || ''); },
          log: function(msg) { console.log('[JavaBridge] ' + msg); },
          aesEncode: function(data, key, iv) { try { return _AES.encrypt(data, key, iv, iv ? 'CBC' : 'ECB'); } catch(e) { return ''; } },
          aesDecode: function(data, key, iv) { try { return _AES.decrypt(data, key, iv, iv ? 'CBC' : 'ECB'); } catch(e) { return ''; } },
          md5Encode: function(str) { var k = 'md5:' + str; if (_javaCache[k] !== undefined) return _javaCache[k]; return ''; },
          base64Encode: function(str) { try { return btoa(unescape(encodeURIComponent(str))); } catch(e) { return ''; } },
          base64Decode: function(str) { try { return decodeURIComponent(escape(atob(str))); } catch(e) { return ''; } },
        };
      ''');
    }

    // 4. 注入 CryptoJS（使用纯 JS _AES 引擎，支持 WordArray 格式）
    final cryptoCode = '''
      var CryptoJS = {
        AES: {
          encrypt: function(data, key, cfg) {
            var iv = cfg && cfg.iv ? cfg.iv : null;
            var mode = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'ECB' : 'CBC';
            var result = _AES.encrypt(data, key, iv, mode);
            return { toString: function() { return result; }, ciphertext: { toString: function(enc) { return result; } } };
          },
          decrypt: function(data, key, cfg) {
            var iv = cfg && cfg.iv ? cfg.iv : null;
            var mode = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'ECB' : 'CBC';
            var result = _AES.decrypt(data, key, iv, mode);
            return { toString: function(enc) { return result; } };
          },
        },
        MD5: function(str) { return { toString: function() { return java.md5Encode(str); } }; },
        SHA1: function(str) { return { toString: function() { return java.sha1Encode ? java.sha1Encode(str) : ''; } }; },
        SHA256: function(str) { return { toString: function() { return java.sha256Encode ? java.sha256Encode(str) : ''; } }; },
        HmacSHA256: function(data, key) { return { toString: function() { return java.hmacSHA256 ? java.hmacSHA256(data, key) : ''; } }; },
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
    ''';
    try {
      evaluate(cryptoCode);
    } catch (e) {
      debugPrint('JsEngine: CryptoJS 注入失败: $e');
    }

    // 5. 最终验证
    final finalCheck = evaluate('typeof java !== "undefined" && typeof CryptoJS !== "undefined" && typeof _javaCache !== "undefined" && typeof _AES !== "undefined"');
    if (finalCheck == 'true') {
      debugPrint('JsEngine: Java 桥接注入成功 (java, CryptoJS, _javaCache, _AES)');
    } else {
      debugPrint('JsEngine: Java 桥接注入部分失败！java=${evaluate('typeof java')}, CryptoJS=${evaluate('typeof CryptoJS')}, _javaCache=${evaluate('typeof _javaCache')}, _AES=${evaluate('typeof _AES')}');
    }
  }

  // ===== TypeScript 编译支持 =====

  Future<String> compileTypeScript(String tsCode) async {
    String js = tsCode;

    js = js.replaceAllMapped(
      RegExp(r'(\w+)\s*:\s*[\w\[\]<>\|&\s]+([,\)])'),
      (m) => '${m[1]}${m[2]}',
    );
    js = js.replaceAllMapped(
      RegExp(r'\)\s*:\s*[\w\[\]<>\|&\s]+\s*([=>{])'),
      (m) => ') ${m[1]}',
    );
    js = js.replaceAllMapped(
      RegExp(r'(const|let|var)\s+(\w+)\s*:\s*[\w\[\]<>\|&\s]+=\s*'),
      (m) => '${m[1]} ${m[2]} = ',
    );
    js = js.replaceAll(RegExp(r'interface\s+\w+\s*\{[^}]*\}', multiLine: true), '');
    js = js.replaceAll(RegExp(r'type\s+\w+\s*=\s*[^;]+;'), '');
    js = js.replaceAllMapped(RegExp(r'\s+as\s+[\w\[\]<>\|&]+'), (m) => '');
    js = js.replaceAllMapped(
      RegExp(r'(\w+)<[^>]+>\('),
      (m) => '${m[1]}(',
    );
    js = js.replaceAllMapped(
      RegExp(r'enum\s+(\w+)\s*\{([^}]+)\}'),
      (m) {
        final name = m[1];
        final body = m[2];
        final entries = body!.split(',').asMap().entries.map((e) {
          final trimmed = e.value.trim();
          if (trimmed.contains('=')) {
            return trimmed;
          }
          return '$trimmed = ${e.key}';
        }).join(', ');
        return 'var $name = { $entries };';
      },
    );
    js = js.replaceAllMapped(
      RegExp(r'(\w+)\?\.(?:(\w+)\()?'),
      (m) => m[2] != null ? '(${m[1]} && ${m[1]}.${m[2]}(' : '(${m[1]} && ${m[1]}.',
    );
    js = js.replaceAllMapped(
      RegExp(r'(\w+)\s*\?\?\s*'),
      (m) => '(${m[1]} != null ? ${m[1]} : ',
    );
    js = js.replaceAll(RegExp(r'\b(public|private|protected|readonly)\s+'), '');
    js = js.replaceAll(RegExp(r'\babstract\s+'), '');
    js = js.replaceAllMapped(RegExp(r'\s+implements\s+[\w,\s]+'), (m) => '');

    return js;
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
    try {
      final result = _jsRuntime!.evaluate(script);
      if (result.isError) {
        debugPrint('JsEngine evaluate error: ${result.stringResult}');
        return null;
      }
      return result.stringResult;
    } catch (e) {
      debugPrint('JsEngine evaluate exception: $e');
      return null;
    }
  }

  Future<dynamic> evaluateAsync(String script) async {
    if (!_initialized || _jsRuntime == null) return null;
    try {
      final result = await _jsRuntime!.evaluateAsync(script);
      if (result.isError) {
        debugPrint('JsEngine evaluateAsync error: ${result.stringResult}');
        return null;
      }
      return result.stringResult;
    } catch (e) {
      debugPrint('JsEngine evaluateAsync exception: $e');
      return null;
    }
  }

  Future<dynamic> evaluateTypeScript(String tsCode) async {
    final jsCode = await compileTypeScript(tsCode);
    return evaluate(jsCode);
  }

  /// 同步执行 JS 代码（用于 AnalyzeRule 规则解析）
  /// 默认走 QuickJS，如果代码含 java. 且无 ES6 特征，自动走 Rhino
  dynamic executeSync(String jsCode, dynamic content, {String? baseUrl, JsEngineType? sourceEngine, Map<String, dynamic>? variables, String? ruleStep}) {
    // 先提取 JS 代码（去掉 <js></js> 标签或 @js: 前缀）
    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final resolved = resolveEngine(extracted, sourceEngine: sourceEngine);

    final engineTag = resolved.engine == JsEngineType.rhino ? 'Rhino→QuickJS' : 'QuickJS';
    final codePreview = resolved.code.length > 200 ? '${resolved.code.substring(0, 200)}...' : resolved.code;
    final inputPreview = content?.toString();
    final inputShort = inputPreview != null && inputPreview.length > 200 ? '${inputPreview.substring(0, 200)}...' : inputPreview;

    AppLogger.instance.debug(LogCategory.js, '[$engineTag] 同步执行JS',
      detail: 'code=$codePreview, content=${content?.toString().length ?? 0}chars');

    // 追踪树：创建节点
    JsTraceNode? traceNode;
    if (JsTracer.instance.enabled) {
      final tracer = JsTracer.instance;
      if (tracer._stack.isEmpty) {
        traceNode = tracer.beginRoot('executeSync', engineTag, codePreview,
          inputPreview: inputShort, ruleStep: ruleStep);
      } else {
        traceNode = tracer.addChild('executeSync', engineTag, codePreview,
          inputPreview: inputShort, ruleStep: ruleStep);
      }
      tracer.push(traceNode);
    }

    if (resolved.engine == JsEngineType.rhino) {
      // Rhino 不支持同步调用（MethodChannel 是异步的），降级到 QuickJS
      debugPrint('JsEngine: Rhino 不支持同步执行，降级到 QuickJS: ${jsCode.substring(0, jsCode.length > 50 ? 50 : jsCode.length)}...');
    }

    final result = _executeQuickJSSync(resolved.code, content, baseUrl: baseUrl, variables: variables);

    // 追踪树：记录输出
    if (traceNode != null) {
      final outputStr = result?.toString();
      final outputShort = outputStr != null && outputStr.length > 200 ? '${outputStr.substring(0, 200)}...' : outputStr;
      JsTracer.instance.pop(
        outputPreview: outputShort,
        outputType: result?.runtimeType.toString(),
      );
    }

    return result;
  }

  /// QuickJS 同步执行
  dynamic _executeQuickJSSync(String jsCode, dynamic content, {String? baseUrl, Map<String, dynamic>? variables}) {
    if (!_initialized || _jsRuntime == null) {
      debugPrint('JsEngine not initialized, cannot executeSync');
      return null;
    }
    try {
      // content 序列化：List/Map 直接 jsonEncode，String 也 jsonEncode（加引号转义），其他 toString
      String contentStr;
      if (content is List || content is Map) {
        contentStr = jsonEncode(content);
      } else if (content is String) {
        contentStr = jsonEncode(content);
      } else {
        contentStr = jsonEncode(content?.toString() ?? '');
      }

      // 自动补 return：如果 JS 代码不以 return 结尾，自动包裹使其返回最后一个表达式的值
      final wrappedCode = _wrapJsCode(jsCode);

      // 构建变量注入代码（排除核心变量，避免覆盖 result/baseUrl/content）
      final coreVars = {'result', 'baseUrl', 'content', 'src'};
      final varInjections = <String>[];
      if (variables != null) {
        for (final entry in variables.entries) {
          if (!coreVars.contains(entry.key)) {
            varInjections.add('var ${entry.key} = ${jsonEncode(entry.value)};');
          }
        }
      }
      final varCode = varInjections.join('\n');

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
          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';
      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      _flushConsoleLogs();
      if (evalResult.isError) {
        debugPrint('JsEngine executeSync error: ${evalResult.stringResult}');
        AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
        // 追踪树：记录错误
        if (JsTracer.instance.enabled && JsTracer.instance._stack.isNotEmpty) {
          JsTracer.instance._stack.last.error = evalResult.stringResult.length > 200
            ? '${evalResult.stringResult.substring(0, 200)}...' : evalResult.stringResult;
        }
        return null;
      }
      final parsed = _parseJsResult(evalResult.stringResult);
      final resultPreview = parsed?.toString().length ?? 0;
      AppLogger.instance.debug(LogCategory.js, '[QuickJS] 同步执行完成',
        detail: 'resultType=${parsed?.runtimeType}, resultLen=$resultPreview, isError=${evalResult.isError}');
      return parsed;
    } catch (e) {
      debugPrint('JsEngine executeSync exception: $e');
      AppLogger.instance.logJsError('QuickJS', e.toString());
      // 追踪树：记录异常
      if (JsTracer.instance.enabled && JsTracer.instance._stack.isNotEmpty) {
        JsTracer.instance._stack.last.error = e.toString().length > 200
          ? '${e.toString().substring(0, 200)}...' : e.toString();
      }
      return null;
    }
  }

  /// 包裹 JS 代码，确保最后一个表达式的值被返回
  /// 如果代码已经包含 return 语句，直接使用
  /// 如果没有 return，在代码末尾添加 return 语句
  String _wrapJsCode(String code) {
    final trimmed = code.trim();

    // 已经有 return 语句 → 直接使用
    if (trimmed.contains(RegExp(r'\breturn\b'))) {
      return trimmed;
    }

    // 单行简单表达式（如变量名、函数调用、字符串等）
    // 将整个代码作为返回值
    final lines = trimmed.split('\n');
    final lastLine = lines.last.trim();

    // 如果最后一行是语句（以 ; 结尾或是块语句），需要用 eval 包裹
    // 否则直接 return
    if (lastLine.isEmpty) {
      return trimmed;
    }

    // 多行代码：最后一行作为返回值
    if (lines.length > 1) {
      final allButLast = lines.sublist(0, lines.length - 1).join('\n');
      return '$allButLast\nreturn $lastLine';
    }

    // 单行代码：直接 return
    return 'return $trimmed';
  }

  /// 从规则字符串中提取 JS 代码
  /// 支持：<js>code</js>、@js:code、@rhino:code、@quickjs:code
  String? _extractJsCode(String rule) {
    // <js>code</js> 格式
    final jsTagPattern = RegExp(r'<js>([\s\S]*?)</js>', caseSensitive: false);
    final jsTagMatch = jsTagPattern.firstMatch(rule);
    if (jsTagMatch != null) {
      return jsTagMatch.group(1)?.trim();
    }

    // @js:code、@rhino:code、@quickjs:code、@java:code、@ts:code 格式
    final prefixPattern = RegExp(r'^@(?:js|rhino|quickjs|java|ts):', caseSensitive: false);
    if (prefixPattern.hasMatch(rule)) {
      return rule.replaceFirst(prefixPattern, '').trim();
    }

    // {{expression}} 格式
    final templatePattern = RegExp(r'\{\{([\s\S]*?)\}\}');
    final templateMatch = templatePattern.firstMatch(rule);
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

    AppLogger.instance.logJsExecute(
      resolved.engine == JsEngineType.rhino ? 'Rhino' : 'QuickJS',
      resolved.code,
    );

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

    if (resolved.engine == JsEngineType.rhino) {
      return _executeRhinoRule(resolved.code, result: actualResult?.toString() ?? content, env: mergedEnv);
    }

    // 借鉴 legado 的 preCache 机制：在执行 JS 前，预缓存 java.ajax/get/post 的结果
    try {
      await _preCacheBridgeCalls(resolved.code, env: mergedEnv);
    } catch (e) {
      AppLogger.instance.warn(LogCategory.js, '预缓存桥接调用失败，继续执行JS', detail: e.toString());
    }

    return _executeQuickJSRule(resolved.code, result: actualResult, env: mergedEnv, variables: _extractVariables(mergedEnv));
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

    final env = <String, dynamic>{
      'book': book ?? {},
      'chapter': chapter ?? {},
      'source': source ?? {},
      'cookie': <String, String>{},
      'baseUrl': book?['bookUrl'] ?? '',
    };

    if (resolved.engine == JsEngineType.rhino) {
      return _executeRhinoRule(resolved.code, result: content, env: env);
    }

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
          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';
      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      _flushConsoleLogs();
      if (evalResult.isError) {
        debugPrint('JsEngine processJsWithBook error: ${evalResult.stringResult}');
        AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
        return null;
      }
      return evalResult.stringResult;
    } catch (e) {
      debugPrint('JsEngine processJsWithBook exception: $e');
      AppLogger.instance.logJsError('QuickJS', e.toString());
      return null;
    }
  }

  /// 执行书源规则（统一入口，支持分流）
  ///
  /// 规则前缀路由：
  /// - @rhino: / <rhino> → Rhino 引擎
  /// - @quickjs: / <quickjs> → QuickJS 引擎
  /// - @java: / <java> → Rhino 引擎（Java 互操作）
  /// - @ts: / <ts> → TS 编译后 QuickJS 执行
  /// - @js: / <js> → 自动识别引擎
  /// - 无前缀 → 自动识别引擎
  Future<String?> evaluateBookRule(String ruleCode, {
    String? result,
    Map<String, dynamic>? env,
    JsEngineType? sourceEngine,
  }) async {
    final resolved = resolveEngine(ruleCode, sourceEngine: sourceEngine);
    var code = resolved.code;

    // TS 需要先编译
    if (ruleCode.startsWith('@ts:') || ruleCode.startsWith('<ts>')) {
      code = await compileTypeScript(code);
    }

    if (resolved.engine == JsEngineType.rhino) {
      return _executeRhinoRule(code, result: result, env: env);
    }

    return _executeQuickJSRule(code, result: result, env: env);
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
      final codePreview = jsCode.length > 300 ? '${jsCode.substring(0, 300)}...' : jsCode;
      AppLogger.instance.debug(LogCategory.js, '[QuickJS] 开始异步执行',
        detail: codePreview);

      // 追踪树：创建节点
      if (JsTracer.instance.enabled) {
        final tracer = JsTracer.instance;
        final inputPreview = result != null && result.length > 200 ? '${result.substring(0, 200)}...' : result;
        if (tracer._stack.isEmpty) {
          traceNode = tracer.beginRoot('_executeQuickJSRule', 'QuickJS', codePreview,
            inputPreview: inputPreview, ruleStep: ruleStep);
        } else {
          traceNode = tracer.addChild('_executeQuickJSRule', 'QuickJS', codePreview,
            inputPreview: inputPreview, ruleStep: ruleStep);
        }
        tracer.push(traceNode);
      }

      // 自动补 return
      final wrappedCode = _wrapJsCode(jsCode);

      // 断点2：记录包装后的代码
      AppLogger.instance.debug(LogCategory.js, '[QuickJS] 代码包装完成',
        detail: wrappedCode.length > 200 ? '${wrappedCode.substring(0, 200)}...' : wrappedCode);

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
      if (variables != null) {
        for (final entry in variables.entries) {
          if (!coreVars.contains(entry.key)) {
            varInjections.add('var ${entry.key} = ${jsonEncode(entry.value)};');
          }
        }
      }
      final varCode = varInjections.join('\n');

      // jsLib 已通过 loadJsLib() 加载到全局作用域
      // 借鉴 legado：evalJS 时 bindings.prototype = sharedScope
      // QuickJS 等价：jsLib 函数在 globalThis 上，IIFE 内部自动可访问

      // 正确序列化 result：List/Map 直接 jsonEncode 生成 JS 数组/对象，
      // String 需要 jsonEncode 加引号转义，其他类型转字符串
      String resultStr;
      if (result is List || result is Map) {
        resultStr = jsonEncode(result);
      } else if (result is String) {
        resultStr = jsonEncode(result);
      } else {
        resultStr = jsonEncode(result?.toString() ?? '');
      }

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

          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';

      final evalResult = _jsRuntime!.evaluate(wrappedScript);

      // 提取 console 缓存的日志，同步到 AppLogger（借鉴 legado 的调试输出机制）
      _flushConsoleLogs();

      // 断点3：记录执行结果
      final evalResultStr = evalResult.stringResult;
      final resultShort = evalResultStr.length > 200 ? '${evalResultStr.substring(0, 200)}...' : evalResultStr;
      AppLogger.instance.debug(LogCategory.js, '[QuickJS] 异步执行完成',
        detail: 'isError=${evalResult.isError}, result=$resultShort');

      if (evalResult.isError) {
        debugPrint('JsEngine QuickJS error: ${evalResult.stringResult}');
        AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
        // 追踪树：记录错误
        if (traceNode != null) {
          JsTracer.instance.pop(
            outputPreview: resultShort,
            outputType: 'error',
            error: resultShort,
          );
        }
        // QuickJS 失败 → 降级到 Rust 引擎
        return fallbackToRustEngine(jsCode, result: result, env: env);
      }
      final strResult = evalResult.stringResult;
      // 追踪树：记录成功输出
      if (traceNode != null) {
        JsTracer.instance.pop(
          outputPreview: strResult.length > 200 ? '${strResult.substring(0, 200)}...' : strResult,
          outputType: 'String',
        );
      }
      // undefined → 返回空字符串而不是 null（书源规则可能不需要返回值）
      if (strResult == 'undefined') return '';
      // null → 返回 Dart null，避免 "null" 字符串被当作有效结果
      if (strResult == 'null') return null;
      return strResult;
    } catch (e) {
      debugPrint('JsEngine QuickJS exception: $e');
      AppLogger.instance.logJsError('QuickJS', e.toString());
      // 追踪树：记录异常
      if (traceNode != null) {
        JsTracer.instance.pop(
          outputType: 'exception',
          error: e.toString().length > 200 ? '${e.toString().substring(0, 200)}...' : e.toString(),
        );
      }
      // 即使异常也尝试提取 console 日志
      _flushConsoleLogs();
      // QuickJS 异常 → 降级到 Rust 引擎
      return fallbackToRustEngine(jsCode, result: result, env: env);
    }
  }

  /// 提取 QuickJS 中 console 缓存的日志，同步到 AppLogger
  /// 借鉴 legado 的调试输出机制：JS 中的 console.log/warn/error 输出到调试页面
  void _flushConsoleLogs() {
    if (!_initialized || _jsRuntime == null) return;
    try {
      // 先检查 console 是否存在且有 _getLogs 方法
      final checkResult = evaluate('typeof console !== "undefined" ? (typeof console._getLogs === "function" ? "has_getLogs" : "no_getLogs") : "no_console"');
      if (checkResult == 'no_console') {
        debugPrint('JsEngine: console 不存在，重新注入');
        // 重新注入 console
        evaluate('var _consoleLogs = []; globalThis.console = { log: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"log", msg:msg}); }, warn: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"warn", msg:msg}); }, error: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"error", msg:msg}); }, info: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"info", msg:msg}); }, debug: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"debug", msg:msg}); }, _getLogs: function() { return _consoleLogs; }, _clearLogs: function() { _consoleLogs.length = 0; } };');
        return; // 下次执行时再提取
      }
      if (checkResult == 'no_getLogs') {
        debugPrint('JsEngine: console 存在但没有 _getLogs，重新注入');
        evaluate('var _consoleLogs = []; globalThis.console = { log: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"log", msg:msg}); }, warn: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"warn", msg:msg}); }, error: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"error", msg:msg}); }, info: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"info", msg:msg}); }, debug: function() { var msg = Array.from(arguments).join(" "); _consoleLogs.push({level:"debug", msg:msg}); }, _getLogs: function() { return _consoleLogs; }, _clearLogs: function() { _consoleLogs.length = 0; } };');
        return;
      }

      final logsResult = evaluate('JSON.stringify(console._getLogs())');
      if (logsResult == null || logsResult == '[]' || logsResult == 'undefined') return;

      final logsJson = logsResult;
      if (!logsJson.startsWith('[')) return;

      final logs = jsonDecode(logsJson) as List;
      for (final log in logs) {
        if (log is! Map) continue;
        final level = log['level'] as String? ?? 'log';
        final msg = log['msg']?.toString() ?? '';
        if (msg.isEmpty) continue;

        switch (level) {
          case 'error':
            AppLogger.instance.error(LogCategory.js, msg);
            break;
          case 'warn':
            AppLogger.instance.warn(LogCategory.js, msg);
            break;
          case 'info':
            AppLogger.instance.info(LogCategory.js, msg);
            break;
          case 'debug':
            AppLogger.instance.debug(LogCategory.js, msg);
            break;
          default:
            AppLogger.instance.info(LogCategory.js, msg);
        }
      }

      // 清除已提取的日志
      evaluate('console._clearLogs()');
    } catch (e) {
      // 日志提取失败不影响主流程
      debugPrint('JsEngine: console日志提取失败: $e');
    }
  }

  // ===== Rust 引擎降级（通过 native-proxy API）=====

  /// QuickJS 执行失败时，降级到 Rust boa 引擎
  /// 通过 HTTP 调用 native-proxy 的 /api/js/* 接口
  Future<String?> fallbackToRustEngine(String jsCode, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    if (kIsWeb) return null;

    final apiPort = _rustApiPort;
    if (apiPort == 0) {
      debugPrint('JsEngine: Rust API 不可用，降级失败');
      return null;
    }

    try {
      debugPrint('JsEngine: QuickJS 失败，降级到 Rust 引擎 (port: $apiPort)');
      final client = HttpClient();
      final code = Uri.encodeComponent(jsCode);
      final resultStr = Uri.encodeComponent(result ?? '');
      final baseUrl = Uri.encodeComponent(env?['baseUrl'] ?? '');
      final bookJson = env?['book'] != null ? Uri.encodeComponent(jsonEncode(env!['book'])) : '';
      final chapterJson = env?['chapter'] != null ? Uri.encodeComponent(jsonEncode(env!['chapter'])) : '';

      final url = 'http://localhost:$apiPort/api/js/evaluateWithContext'
          '?code=$code'
          '&result=$resultStr'
          '&baseUrl=$baseUrl'
          '&content=$resultStr'
          '${bookJson.isNotEmpty ? '&book=$bookJson' : ''}'
          '${chapterJson.isNotEmpty ? '&chapter=$chapterJson' : ''}';

      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (body.isEmpty) return null;

      final json = jsonDecode(body) as Map<String, dynamic>;
      final apiResult = json['result'] as Map<String, dynamic>?;

      if (apiResult == null || apiResult['success'] != true) {
        debugPrint('JsEngine: Rust 引擎也失败了: ${apiResult?['result']}');
        return null;
      }

      return apiResult['result']?.toString();
    } catch (e) {
      debugPrint('JsEngine: Rust API 调用失败: $e');
      return null;
    }
  }

  /// Rust API 端口（由 cors-proxy.js 启动时通过 stderr 输出）
  int _rustApiPort = 0;

  /// 设置 Rust API 端口（供外部调用）
  void setRustApiPort(int port) {
    _rustApiPort = port;
  }

  // ===== Rhino 规则执行（通过 NativeChannel）=====

  Future<String?> _executeRhinoRule(String code, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    if (kIsWeb) return null;
    try {
      // 同步桥接缓存到 Rhino 环境
      final bindings = <String, dynamic>{
        'result': result ?? '',
        'baseUrl': env?['baseUrl'] ?? '',
        ...?env,
        '_bridgeCache': Map<String, String>.from(_bridgeCache),
      };

      // 判断走 evaluateJavaRule 还是 executeScript
      // 含 Legado 规则前缀 → evaluateJavaRule（支持 @css:/@text:/@attr: 等）
      // 纯 JS 代码 → executeScript（通用 Rhino 执行）
      final isLegadoRule = code.startsWith('@css:') ||
          code.startsWith('@text:') ||
          code.startsWith('@attr:') ||
          code.startsWith('java:');

      if (isLegadoRule) {
        return await NativeChannel.instance.evaluateJavaRule(
          code,
          result: result,
          env: bindings,
        );
      }

      return await NativeChannel.instance.executeScript(
        code,
        bindings: bindings,
      );
    } catch (e) {
      debugPrint('JsEngine Rhino error: $e');
      return null;
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
      final evalResult = _jsRuntime!.evaluate(script);
      if (evalResult.isError) return null;
      return evalResult.stringResult;
    } catch (e) {
      return null;
    }
  }

  Future<String?> cssSelect(String html, String selector) async {
    if (!_initialized || _jsRuntime == null) return null;
    try {
      final script = '''
        (function() {
          return java.jsoup.selectFirst(${jsonEncode(html)}, ${jsonEncode(selector)});
        })();
      ''';
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
    try {
      return jsonDecode(result);
    } catch (_) {}
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
      debugPrint('📚 已加载书源JS库到全局作用域: $sourceUrl (${_currentJsLibFunctions.length}个函数)');
    } catch (e) {
      debugPrint('❌ 加载书源JS库失败: $e');
    }
  }

  /// 清除当前已加载的 jsLib 全局函数
  /// 借鉴 legado 的 scope 切换机制：切换书源时清除旧的 scope
  void _clearCurrentJsLib() {
    if (_currentJsLibFunctions.isEmpty || _jsRuntime == null) return;
    try {
      final deleteCode = _currentJsLibFunctions.map((fn) => 'try{delete globalThis.$fn}catch(e){}').join(';');
      _jsRuntime!.evaluate(deleteCode);
      debugPrint('📚 已清除旧书源JS库: $_currentJsLibSourceUrl (${_currentJsLibFunctions.length}个函数)');
    } catch (e) {
      debugPrint('❌ 清除旧书源JS库失败: $e');
    }
    _currentJsLibFunctions.clear();
    _currentJsLibSourceUrl = null;
  }

  /// 提取 JS 代码中定义的函数名
  /// 匹配 function xxx() 和 var/const/let/this.xxx = function/()=> 模式
  void _extractFunctionNames(String jsLib) {
    _currentJsLibFunctions.clear();
    // 匹配 function xxx( 模式
    final funcPattern = RegExp(r'function\s+(\w+)\s*\(');
    for (final m in funcPattern.allMatches(jsLib)) {
      _currentJsLibFunctions.add(m.group(1)!);
    }
    // 匹配 var/const/let xxx = function / xxx = ()=> / xxx = (...) => 模式
    final varPattern = RegExp(r'(?:var|const|let)\s+(\w+)\s*=\s*(?:function|\(|[^(]*=>)');
    for (final m in varPattern.allMatches(jsLib)) {
      _currentJsLibFunctions.add(m.group(1)!);
    }
    // 匹配 this.xxx = function / this.xxx = ()=> 模式
    final thisPattern = RegExp(r'this\.(\w+)\s*=\s*(?:function|\(|[^(]*=>)');
    for (final m in thisPattern.allMatches(jsLib)) {
      _currentJsLibFunctions.add(m.group(1)!);
    }
  }

  /// 获取书源的 jsLib 代码
  String? getJsLib(String sourceUrl) => _jsLibCache[sourceUrl];

  /// 清除书源的 jsLib 缓存
  void clearJsLib(String sourceUrl) {
    _jsLibCache.remove(sourceUrl);
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
    final script = '_javaCache["${method}:${url}"] = ${jsonEncode(result)};';
    evaluate(script);
  }

  /// 批量预缓存 HTTP 结果（在 processJsRule 前调用）
  /// 解决 QuickJS 同步模式下 java.ajax() 无法异步请求的问题
  Future<void> preCacheHttpResults(Map<String, String> urlResults) async {
    final entries = urlResults.entries.map((e) =>
      '_javaCache["http_get:${e.key}"] = ${jsonEncode(e.value)};'
    ).join('\n');
    if (entries.isNotEmpty) {
      evaluate(entries);
    }
  }

  /// 批量预缓存加密结果
  Future<void> preCacheCryptoResults(Map<String, String> cryptoResults) async {
    final entries = cryptoResults.entries.map((e) =>
      '_javaCache["${e.key}"] = ${jsonEncode(e.value)};'
    ).join('\n');
    if (entries.isNotEmpty) {
      evaluate(entries);
    }
  }

  /// 预缓存桥接调用（核心方法）
  /// 在执行 JS 代码前，扫描代码中的 java.ajax/get/post/aesEncode/md5Encode 等调用
  /// 通过 NativeChannel 预获取结果，写入 _javaCache
  /// 借鉴 legado 的 preCacheHttpResults 机制，但自动扫描而非手动传入
  Future<void> _preCacheBridgeCalls(String jsCode, {Map<String, dynamic>? env}) async {
    if (_jsRuntime == null) return;

    final baseUrl = env?['baseUrl'] as String? ?? '';
    final httpUrls = <String>{};

    // 1. 扫描字面量 URL: java.ajax("url"), java.get("url"), java.post("url"), fetch("url")
    final literalPattern = RegExp(
      r"""(?:java\.(?:ajax|get|post)|fetch)\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    for (final match in literalPattern.allMatches(jsCode)) {
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
    // 先在 QuickJS 中求值变量，获取完整 URL
    final varPattern = RegExp(
      r"""(?:java\.(?:ajax|get|post)|fetch)\s*\(\s*([^"')\s][^)]*?)\s*\)""",
      multiLine: true,
    );
    for (final match in varPattern.allMatches(jsCode)) {
      final expr = match.group(1)?.trim();
      if (expr == null || expr.isEmpty) continue;
      // 跳过字面量字符串（已被上面匹配）
      if (expr.startsWith('"') || expr.startsWith("'")) continue;
      // 尝试在 QuickJS 中求值表达式
      try {
        // 注入 env 变量后求值
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
        final evalScript = '${varCode.join('\n')} (function() { try { var __url = String($expr); return __url; } catch(e) { return ""; } })()';
        final urlResult = evaluate(evalScript);
        if (urlResult != null && urlResult.isNotEmpty && urlResult.startsWith('http')) {
          httpUrls.add(urlResult);
        }
      } catch (_) {
        // 求值失败，跳过
      }
    }

    // 3. 扫描 URL 模板变量: fetch(`https://xxx/${key}`), java.ajax(`${baseUrl}/api`)
    final templatePattern = RegExp(r'`([^`]*\$\{[^}]+\}[^`]*)`');
    for (final match in templatePattern.allMatches(jsCode)) {
      var template = match.group(1);
      if (template == null) continue;
      // 替换 ${var} 为 env 中的值
      if (env != null) {
        template = template.replaceAllMapped(
          RegExp(r'\$\{([^}]+)\}'),
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
      final futures = httpUrls.map((url) async {
        try {
          final result = await NativeChannel.instance.httpGet(url, headers: customHeaders);
          if (result != null) {
            return MapEntry('http_get:$url', result);
          }
        } catch (e) {
          AppLogger.instance.warn(LogCategory.js, '预缓存HTTP失败: $url', detail: e.toString());
        }
        return null;
      });

      final results = await Future.wait(futures);
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
    // 6. 扫描 java.md5Encode 调用（已有纯 JS _MD5 引擎，但仍通过桥接预缓存加速）
    final md5Pattern = RegExp(
      r"""java\.md5Encode\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    final cryptoResults = <String, String>{};
    for (final match in md5Pattern.allMatches(jsCode)) {
      final str = match.group(1);
      if (str != null) {
        final cacheKey = 'md5:$str';
        if (!_isCached(cacheKey)) {
          final result = await NativeChannel.instance.md5(str);
          if (result != null) cryptoResults[cacheKey] = result;
        }
      }
    }

    // 6.1 扫描 java.sha1Encode 调用（已有纯 JS _SHA1 引擎，桥接预缓存作为加速）
    final sha1Pattern = RegExp(
      r"""java\.sha1Encode\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    for (final match in sha1Pattern.allMatches(jsCode)) {
      final str = match.group(1);
      if (str != null) {
        final cacheKey = 'sha1:$str';
        if (!_isCached(cacheKey)) {
          try {
            final result = await NativeChannel.instance.sha1(str);
            if (result != null) cryptoResults[cacheKey] = result;
          } catch (_) {}
        }
      }
    }

    // 6.2 扫描 java.sha256Encode 调用（已有纯 JS _SHA256 引擎，桥接预缓存作为加速）
    final sha256Pattern = RegExp(
      r"""java\.sha256Encode\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    for (final match in sha256Pattern.allMatches(jsCode)) {
      final str = match.group(1);
      if (str != null) {
        final cacheKey = 'sha256:$str';
        if (!_isCached(cacheKey)) {
          try {
            final result = await NativeChannel.instance.sha256(str);
            if (result != null) cryptoResults[cacheKey] = result;
          } catch (_) {}
        }
      }
    }

    // 6.3 扫描 java.hmacSHA256 调用（已有纯 JS _HMACSHA256 引擎，桥接预缓存作为加速）
    final hmacPattern = RegExp(
      r"""java\.hmacSHA256\s*\(\s*["']([^"']+)["']\s*,\s*["']([^"']+)["']""",
      multiLine: true,
    );
    for (final match in hmacPattern.allMatches(jsCode)) {
      final data = match.group(1);
      final key = match.group(2);
      if (data != null && key != null) {
        final cacheKey = 'hmac_sha256:$data:$key';
        if (!_isCached(cacheKey)) {
          try {
            final result = await NativeChannel.instance.hmacSHA256(data, key);
            if (result != null) cryptoResults[cacheKey] = result;
          } catch (_) {}
        }
      }
    }

    if (cryptoResults.isNotEmpty) {
      await preCacheCryptoResults(cryptoResults);
    }

    // 6.4 扫描 java.post 调用（POST 请求预缓存）
    final postPattern = RegExp(
      r"""java\.post\s*\(\s*["']([^"']+)["']\s*,\s*["']([^"']*)["']""",
      multiLine: true,
    );
    final postUrls = <String, String>{}; // url -> body
    for (final match in postPattern.allMatches(jsCode)) {
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
      AppLogger.instance.debug(LogCategory.js, '预缓存 ${postUrls.length} 个POST请求');
      final customHeaders = env?['headers'] as Map<String, String>?;
      final postFutures = postUrls.entries.map((entry) async {
        try {
          final result = await NativeChannel.instance.httpPost(
            entry.key,
            body: entry.value,
            headers: customHeaders,
          );
          if (result != null) {
            return MapEntry('http_post:${entry.key}', result);
          }
        } catch (e) {
          AppLogger.instance.warn(LogCategory.js, '预缓存POST失败: ${entry.key}', detail: e.toString());
        }
        return null;
      });
      final postResults = await Future.wait(postFutures);
      final postCacheEntries = <String, String>{};
      for (final entry in postResults) {
        if (entry != null) postCacheEntries[entry.key] = entry.value;
      }
      if (postCacheEntries.isNotEmpty) {
        await preCacheHttpResults(postCacheEntries);
      }
    }

    // 6.5 扫描 java.head 调用（HEAD 请求预缓存）
    final headPattern = RegExp(
      r"""java\.head\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    final headUrls = <String>{};
    for (final match in headPattern.allMatches(jsCode)) {
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
      AppLogger.instance.debug(LogCategory.js, '预缓存 ${headUrls.length} 个HEAD请求');
      final customHeaders = env?['headers'] as Map<String, String>?;
      final headFutures = headUrls.map((url) async {
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
      });
      final headResults = await Future.wait(headFutures);
      final headCacheEntries = <String, String>{};
      for (final entry in headResults) {
        if (entry != null) headCacheEntries[entry.key] = entry.value;
      }
      if (headCacheEntries.isNotEmpty) {
        await preCacheHttpResults(headCacheEntries);
      }
    }

    // 6.6 扫描 java.getCookie 调用（Cookie 预缓存）
    final cookiePattern = RegExp(
      r"""java\.getCookie\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    final cookieUrls = <String>{};
    for (final match in cookiePattern.allMatches(jsCode)) {
      final tag = match.group(1);
      if (tag != null && tag.isNotEmpty) {
        cookieUrls.add(tag);
      }
    }
    if (cookieUrls.isNotEmpty) {
      AppLogger.instance.debug(LogCategory.js, '预缓存 ${cookieUrls.length} 个Cookie请求');
      final cookieFutures = cookieUrls.map((tag) async {
        try {
          final result = await NativeChannel.instance.getCookie(tag);
          if (result != null) {
            return MapEntry('cookie:$tag', result);
          }
        } catch (e) {
          AppLogger.instance.warn(LogCategory.js, '预缓存Cookie失败: $tag', detail: e.toString());
        }
        return null;
      });
      final cookieResults = await Future.wait(cookieFutures);
      final cookieCacheEntries = <String, String>{};
      for (final entry in cookieResults) {
        if (entry != null) cookieCacheEntries[entry.key] = entry.value;
      }
      if (cookieCacheEntries.isNotEmpty) {
        await preCacheHttpResults(cookieCacheEntries);
      }
    }

    // 7. 预缓存 HTML 解析结果（使用 Dart 原生 html 包）
    final htmlParsePattern = RegExp(
      r'''(?:_JsoupLite\.(selectFirst|selectAll)|java\.(getString|getElement|getElements))\s*\(\s*([^,)]+)(?:\s*,\s*([^)]+))?\s*\)''',
      multiLine: true,
    );

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

    for (final match in htmlParsePattern.allMatches(jsCode)) {
      final method = match.group(1) ?? match.group(2);
      final firstArg = match.group(3)?.trim() ?? '';
      final secondArg = match.group(4)?.trim();

      String? htmlContent;
      String? selector;

      // 解析 HTML 内容来源
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
      }
      if (!_isCached(saKey)) {
        evaluate('_javaCache[${jsonEncode(saKey)}] = ${jsonEncode(parsed['all'])};');
      }
      // 缓存 text/href/src 供 java.getString 快速访问
      final textKey = 'jsoup_text:$selector:$htmlHash';
      final hrefKey = 'jsoup_href:$selector:$htmlHash';
      if (parsed['text'] != null && !_isCached(textKey)) {
        evaluate('_javaCache[${jsonEncode(textKey)}] = ${jsonEncode(parsed['text'])};');
      }
      if (parsed['href'] != null && (parsed['href'] as String).isNotEmpty && !_isCached(hrefKey)) {
        evaluate('_javaCache[${jsonEncode(hrefKey)}] = ${jsonEncode(parsed['href'])};');
      }
    }
  }

  /// 替换模板变量 {{key}}, {{page}} 等
  String _resolveTemplateVars(String url, Map<String, dynamic> env) {
    return url.replaceAllMapped(
      RegExp(r'\{\{(\w+)\}\}'),
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
    // 通过 JS 检查缓存
    final result = evaluate('_javaCache["$key"] !== undefined');
    return result == 'true';
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
  }
}
