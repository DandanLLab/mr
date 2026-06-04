import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:path_provider/path_provider.dart';
import '../app_logger.dart';
import 'platform_channel.dart';

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
    if (_initialized) return true;
    try {
      _jsRuntime = getJavascriptRuntime();
      _initialized = true;

      await _injectNodePolyfills();
      _injectJavaBridge();
      await _loadInstalledPackages();

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

      function URL(url, base) {
        this.href = url;
        this.origin = '';
        this.protocol = '';
        this.host = '';
        this.hostname = '';
        this.port = '';
        this.pathname = '';
        this.search = '';
        this.hash = '';
        this.toString = function() { return this.href; };
      }
      function URLSearchParams(init) {
        this._params = {};
        this.get = function(name) { return this._params[name] || null; };
        this.set = function(name, value) { this._params[name] = value; };
        this.has = function(name) { return name in this._params; };
        this.toString = function() { return ''; };
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
    ''';

    evaluate(nodePolyfills);
  }

  // ===== Java 桥接对象（QuickJS 侧）=====

  void _injectJavaBridge() {
    const javaBridge = '''
      // ===== Legado Java 桥接对象（QuickJS 侧）=====
      // HTTP/加密/Jsoup 等操作通过 Dart 侧 NativeChannel 桥接实现
      // 第一阶段：java.* 调用返回空值，第二阶段打通真正的桥接
      var java = {
        // HTTP 请求方法
        // 第二阶段将实现真正的 Dart → NativeChannel 桥接
        get: function(url, headers) {
          console.warn('[Bridge] java.get() is stub, awaiting bridge implementation');
          return '';
        },
        post: function(url, body, headers) {
          console.warn('[Bridge] java.post() is stub, awaiting bridge implementation');
          return '';
        },
        ajax: function(url, headers) {
          return java.get(url, headers);
        },
        ajaxAll: function(urls) {
          return '';
        },
        put: function(key, value) {
          _javaCache[key] = typeof value === 'object' ? JSON.stringify(value) : String(value);
        },
        getStr: function(key, defaultValue) {
          return _javaCache[key] || (defaultValue || '');
        },
        log: function(msg) {
          console.log('[JavaBridge] ' + msg);
        },

        getString: function(str, ruleStr) {
          if (!str || !ruleStr) return '';
          return str;
        },
        getStrResponse: function(url, ruleStr) {
          return '';
        },

        getJson: function(str) {
          try { return JSON.parse(str); } catch(e) { return {}; }
        },
        putJson: function(key, value) {
          _javaCache[key] = JSON.stringify(value);
        },

        // 加密/解密（占位，第二阶段通过 NativeChannel 实现）
        aesEncode: function(data, key, iv) { return ''; },
        aesDecode: function(data, key, iv) { return ''; },
        md5Encode: function(str) { return ''; },
        base64Encode: function(str) { return ''; },
        base64Decode: function(str) { return ''; },

        // HTML 解析（占位，第二阶段通过 NativeChannel Jsoup 实现）
        jsoup: {
          parse: function(html) {
            return { select: function(sel) { return ''; } };
          },
          select: function(html, selector) { return []; },
          selectFirst: function(html, selector) { return ''; },
          getAttr: function(html, selector, attr) { return ''; },
          clean: function(html) { return html; },
        },

        // 正则操作（QuickJS 原生支持，无需桥接）
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

        timeFormat: function(timestamp, format) {
          return new Date(timestamp).toLocaleString();
        },
        getTime: function() {
          return Date.now();
        },

        webview: {
          eval: function(url, js) { return ''; },
        },

        cache: {
          get: function(key) { return _javaCache[key] || ''; },
          put: function(key, value) { _javaCache[key] = value; },
          delete: function(key) { delete _javaCache[key]; },
        },
      };

      var _javaCache = {};

      // 兼容 Legado 的 CryptoJS
      var CryptoJS = {
        AES: {
          encrypt: function(data, key, cfg) { return { toString: function() { return ''; } }; },
          decrypt: function(data, key, cfg) { return { toString: function(enc) { return ''; } }; },
        },
        MD5: function(str) { return { toString: function() { return ''; } }; },
        enc: {
          Utf8: { parse: function(s) { return s; }, stringify: function(w) { return w; } },
          Base64: { parse: function(s) { return ''; }, stringify: function(w) { return ''; } },
          Hex: { parse: function(s) { return s; }, stringify: function(w) { return w; } },
        },
        mode: { ECB: {}, CBC: {} },
        pad: { Pkcs7: {}, ZeroPadding: {}, NoPadding: {} },
      };
    ''';

    evaluate(javaBridge);
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
    if (!_initialized || _jsRuntime == null) return null;
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
  dynamic executeSync(String jsCode, dynamic content, {String? baseUrl, JsEngineType? sourceEngine}) {
    // 先提取 JS 代码（去掉 <js></js> 标签或 @js: 前缀）
    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final resolved = resolveEngine(extracted, sourceEngine: sourceEngine);

    if (resolved.engine == JsEngineType.rhino) {
      // Rhino 不支持同步调用（MethodChannel 是异步的），降级到 QuickJS
      debugPrint('JsEngine: Rhino 不支持同步执行，降级到 QuickJS: ${jsCode.substring(0, jsCode.length > 50 ? 50 : jsCode.length)}...');
    }

    return _executeQuickJSSync(resolved.code, content, baseUrl: baseUrl);
  }

  /// QuickJS 同步执行
  dynamic _executeQuickJSSync(String jsCode, dynamic content, {String? baseUrl}) {
    if (!_initialized || _jsRuntime == null) {
      debugPrint('JsEngine not initialized, cannot executeSync');
      return null;
    }
    try {
      final contentStr = content is String
          ? jsonEncode(content)
          : jsonEncode(content?.toString() ?? '');

      // 自动补 return：如果 JS 代码不以 return 结尾，自动包裹使其返回最后一个表达式的值
      final wrappedCode = _wrapJsCode(jsCode);

      final wrappedScript = '''
        (function() {
          var result = $contentStr;
          var baseUrl = ${jsonEncode(baseUrl ?? '')};
          var content = result;
          $wrappedCode
        })();
      ''';
      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      if (evalResult.isError) {
        debugPrint('JsEngine executeSync error: ${evalResult.stringResult}');
        return null;
      }
      return _parseJsResult(evalResult.stringResult);
    } catch (e) {
      debugPrint('JsEngine executeSync exception: $e');
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
  Future<String?> processJsRule(String content, String jsCode, {String? baseUrl, JsEngineType? sourceEngine}) async {
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

    if (resolved.engine == JsEngineType.rhino) {
      return _executeRhinoRule(resolved.code, result: content, env: {'baseUrl': baseUrl ?? ''});
    }

    return _executeQuickJSRule(resolved.code, result: content, env: {'baseUrl': baseUrl ?? ''});
  }

  /// 处理带书籍上下文的 JS 规则
  Future<String?> processJsWithBook(
    String jsCode, {
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
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

    if (resolved.engine == JsEngineType.rhino) {
      return _executeRhinoRule(
        resolved.code,
        result: content,
        env: {
          'book': book ?? {},
          'chapter': chapter ?? {},
          'baseUrl': book?['bookUrl'] ?? '',
        },
      );
    }

    try {
      final wrappedScript = '''
        (function() {
          var result = ${jsonEncode(content ?? '')};
          var baseUrl = ${jsonEncode(book?['bookUrl'] ?? '')};
          var content = result;
          var book = ${jsonEncode(book ?? {})};
          var chapter = ${jsonEncode(chapter ?? {})};
          var index = ${jsonEncode(index ?? 0)};
          ${resolved.code}
        })();
      ''';
      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      if (evalResult.isError) {
        debugPrint('JsEngine processJsWithBook error: ${evalResult.stringResult}');
        return null;
      }
      return evalResult.stringResult;
    } catch (e) {
      debugPrint('JsEngine processJsWithBook exception: $e');
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

  Future<String?> _executeQuickJSRule(String jsCode, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) return null;
    }
    try {
      // 自动补 return
      final wrappedCode = _wrapJsCode(jsCode);

      final wrappedScript = '''
        (function() {
          var result = ${jsonEncode(result ?? '')};
          var baseUrl = ${jsonEncode(env?['baseUrl'] ?? '')};
          var book = ${jsonEncode(env?['book'] ?? {})};
          var chapter = ${jsonEncode(env?['chapter'] ?? {})};
          var source = ${jsonEncode(env?['source'] ?? {})};

          $wrappedCode
        })();
      ''';

      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      if (evalResult.isError) {
        debugPrint('JsEngine QuickJS error: ${evalResult.stringResult}');
        // QuickJS 失败 → 降级到 Rust 引擎
        return fallbackToRustEngine(jsCode, result: result, env: env);
      }
      final strResult = evalResult.stringResult;
      // undefined → 返回空字符串而不是 null（书源规则可能不需要返回值）
      if (strResult == 'undefined') return '';
      return strResult;
    } catch (e) {
      debugPrint('JsEngine QuickJS exception: $e');
      // QuickJS 异常 → 降级到 Rust 引擎
      return fallbackToRustEngine(jsCode, result: result, env: env);
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

  /// 释放资源
  void dispose() {
    _jsRuntime?.dispose();
    _jsRuntime = null;
    _initialized = false;
    _installedPackages.clear();
    _moduleCache.clear();
    _bridgeCache.clear();
  }
}
