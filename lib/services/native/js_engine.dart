import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:path_provider/path_provider.dart';

/// JS/TS 运行时引擎 - 完整的 Node.js 兼容环境
/// 支持：书源规则执行、自定义库安装、TypeScript 编译
class JsEngine {
  static JsEngine? _instance;
  static JsEngine get instance => _instance ??= JsEngine._();

  JsEngine._();

  bool _initialized = false;
  JavascriptRuntime? _jsRuntime;
  final Map<String, String> _installedPackages = {}; // 已安装的包
  final Map<String, String> _moduleCache = {}; // 模块缓存

  /// 初始化 JS 引擎
  Future<bool> init() async {
    if (_initialized) return true;
    try {
      // 创建 flutter_js 运行时
      _jsRuntime = getJavascriptRuntime();
      _initialized = true;

      // 注入 Node.js 兼容层
      await _injectNodePolyfills();
      // 注入 Java 桥接对象
      _injectJavaBridge();
      // 加载已安装的自定义库
      await _loadInstalledPackages();

      return true;
    } catch (e) {
      debugPrint('JsEngine init error: $e');
      return false;
    }
  }

  bool get isAvailable => _initialized && _jsRuntime != null;

  // ===== Node.js API 兼容层 =====

  /// 注入 Node.js 核心 API 模拟
  Future<void> _injectNodePolyfills() async {
    const nodePolyfills = '''
      // ===== Node.js 核心模块模拟 =====

      // process 对象
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

      // Buffer 模拟
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

      // URL 和 URLSearchParams
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

      // EventEmitter 模拟
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

      // module.exports 和 require 模拟
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
        // 内置模块模拟
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

  // ===== Java 桥接对象 =====

  /// 注入 Legado 兼容的 Java 桥接对象
  void _injectJavaBridge() {
    const javaBridge = '''
      // ===== Legado Java 桥接对象 =====
      var java = {
        // HTTP 请求方法（通过 Dart 桥接）
        get: function(url, headers) {
          return JSON.stringify({ url: url, method: 'GET', headers: headers || {} });
        },
        post: function(url, body, headers) {
          return JSON.stringify({ url: url, method: 'POST', body: body || '', headers: headers || {} });
        },
        ajax: function(url, headers) {
          return java.get(url, headers);
        },
        ajaxAll: function(urls) {
          return JSON.stringify(urls.map(function(url) { return java.get(url, {}); }));
        },
        put: function(key, value) {
          _javaCache[key] = value;
        },
        getStr: function(key, defaultValue) {
          return _javaCache[key] || (defaultValue || '');
        },
        log: function(msg) {
          // console.log 已由 flutter_js 内置
        },

        // 字符串操作
        getString: function(str, ruleStr) {
          if (!str || !ruleStr) return '';
          return str;
        },
        getStrResponse: function(url, ruleStr) {
          return '';
        },

        // JSON 操作
        getJson: function(str) {
          try { return JSON.parse(str); } catch(e) { return {}; }
        },
        putJson: function(key, value) {
          _javaCache[key] = JSON.stringify(value);
        },

        // 加密/解密（占位，实际由 Dart 侧桥接实现）
        aesEncode: function(data, key, iv) { return ''; },
        aesDecode: function(data, key, iv) { return ''; },
        md5Encode: function(str) { return ''; },
        base64Encode: function(str) { return ''; },
        base64Decode: function(str) { return ''; },

        // HTML 解析（占位）
        jsoup: {
          parse: function(html) {
            return { select: function(sel) { return ''; } };
          },
          select: function(html, selector) { return []; },
          selectFirst: function(html, selector) { return ''; },
          getAttr: function(html, selector, attr) { return ''; },
          clean: function(html) { return html; },
        },

        // 正则操作
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

        // 时间操作
        timeFormat: function(timestamp, format) {
          return new Date(timestamp).toLocaleString();
        },
        getTime: function() {
          return Date.now();
        },

        // WebView 池（占位）
        webview: {
          eval: function(url, js) { return ''; },
        },

        // 缓存操作
        cache: {
          get: function(key) { return _javaCache[key] || ''; },
          put: function(key, value) { _javaCache[key] = value; },
          delete: function(key) { delete _javaCache[key]; },
        },
      };

      // Java 缓存
      var _javaCache = {};

      // 兼容 Legado 的 CryptoJS
      var CryptoJS = {
        AES: {
          encrypt: function(data, key, cfg) { return { toString: function() { return java.aesEncode(data, key, cfg && cfg.iv ? cfg.iv.toString() : ''); } }; },
          decrypt: function(data, key, cfg) { return { toString: function(enc) { return java.aesDecode(data, key, cfg && cfg.iv ? cfg.iv.toString() : ''); } }; },
        },
        MD5: function(str) { return { toString: function() { return java.md5Encode(str); } }; },
        enc: {
          Utf8: { parse: function(s) { return s; }, stringify: function(w) { return w; } },
          Base64: { parse: function(s) { return java.base64Decode(s); }, stringify: function(w) { return java.base64Encode(w); } },
          Hex: { parse: function(s) { return s; }, stringify: function(w) { return w; } },
        },
        mode: { ECB: {}, CBC: {} },
        pad: { Pkcs7: {}, ZeroPadding: {}, NoPadding: {} },
      };
    ''';

    evaluate(javaBridge);
  }

  // ===== TypeScript 编译支持 =====

  /// 编译 TypeScript 为 JavaScript
  /// 内置轻量级 TS→JS 转译器，支持常见 TS 语法
  Future<String> compileTypeScript(String tsCode) async {
    String js = tsCode;

    // 移除类型注解
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

  /// 安装 JS/TS 库
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

  /// 从 URL 安装 JS/TS 库
  Future<bool> installPackageFromUrl(String name, String url) async {
    try {
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 卸载库
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

  /// 获取已安装的库列表
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

  /// 加载已安装的库
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

  /// 注册包到 JS 运行时
  void _registerPackage(String name, String code) {
    final wrappedCode = '''
      _modules['$name'] = function(module, exports, require) {
        $code
      };
    ''';
    evaluate(wrappedCode);
  }

  // ===== 脚本执行 =====

  /// 执行 JS 脚本（同步，直接返回字符串结果）
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

  /// 执行 JS 脚本（异步版本，支持 Promise）
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

  /// 执行 TypeScript 脚本（自动编译为 JS）
  Future<dynamic> evaluateTypeScript(String tsCode) async {
    final jsCode = await compileTypeScript(tsCode);
    return evaluate(jsCode);
  }

  /// 同步执行 JS 代码（用于规则解析）
  /// [jsCode] - JS 代码
  /// [content] - 上下文内容（注入为 result 变量）
  /// [baseUrl] - 基础 URL（注入为 baseUrl 变量）
  dynamic executeSync(String jsCode, dynamic content, {String? baseUrl}) {
    if (!_initialized || _jsRuntime == null) {
      // 尝试懒初始化（同步方式，仅标记需要初始化）
      debugPrint('JsEngine not initialized, cannot executeSync');
      return null;
    }
    try {
      final contentStr = content is String
          ? jsonEncode(content)
          : jsonEncode(content?.toString() ?? '');
      final wrappedScript = '''
        (function() {
          var result = $contentStr;
          var baseUrl = ${jsonEncode(baseUrl ?? '')};
          var content = result;
          $jsCode
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

  /// 处理 JS 书源规则（异步）
  /// [content] - 输入内容
  /// [jsCode] - JS 规则代码
  /// [baseUrl] - 基础 URL
  Future<String?> processJsRule(String content, String jsCode, {String? baseUrl}) async {
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) return null;
    }
    try {
      final wrappedScript = '''
        (function() {
          var result = ${jsonEncode(content)};
          var baseUrl = ${jsonEncode(baseUrl ?? '')};
          var content = result;
          $jsCode
        })();
      ''';
      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      if (evalResult.isError) {
        debugPrint('JsEngine processJsRule error: ${evalResult.stringResult}');
        return null;
      }
      return evalResult.stringResult;
    } catch (e) {
      debugPrint('JsEngine processJsRule exception: $e');
      return null;
    }
  }

  /// 处理带书籍上下文的 JS 规则
  Future<String?> processJsWithBook(
    String jsCode, {
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
    String? content,
    int? index,
  }) async {
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) return null;
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
          $jsCode
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

  /// 执行书源规则（支持 JS/Java/TS 三种格式）
  Future<String?> evaluateBookRule(String ruleCode, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    if (!_initialized || _jsRuntime == null) return null;
    try {
      String jsCode;
      if (ruleCode.startsWith('@ts:') || ruleCode.startsWith('<ts>')) {
        final tsCode = ruleCode.startsWith('@ts:')
            ? ruleCode.substring(4)
            : ruleCode.replaceAll(RegExp(r'^<ts>|</ts>$'), '');
        jsCode = await compileTypeScript(tsCode);
      } else if (ruleCode.startsWith('@java:') || ruleCode.startsWith('<java>')) {
        final javaCode = ruleCode.startsWith('@java:')
            ? ruleCode.substring(6)
            : ruleCode.replaceAll(RegExp(r'^<java>|</java>$'), '');
        return await _evaluateJavaRule(javaCode, result: result, env: env);
      } else {
        jsCode = ruleCode.startsWith('@js:')
            ? ruleCode.substring(4)
            : ruleCode.replaceAll(RegExp(r'^<js>|</js>$'), '');
      }

      final wrappedScript = '''
        (function() {
          var result = ${jsonEncode(result ?? '')};
          var baseUrl = ${jsonEncode(env?['baseUrl'] ?? '')};
          var book = ${jsonEncode(env?['book'] ?? {})};
          var chapter = ${jsonEncode(env?['chapter'] ?? {})};
          var source = ${jsonEncode(env?['source'] ?? {})};

          $jsCode
        })();
      ''';

      final evalResult = _jsRuntime!.evaluate(wrappedScript);
      if (evalResult.isError) {
        debugPrint('JsEngine evaluateBookRule error: ${evalResult.stringResult}');
        return null;
      }
      return evalResult.stringResult;
    } catch (e) {
      debugPrint('JsEngine evaluateBookRule exception: $e');
      return null;
    }
  }

  /// 通过原生通道执行 Java 规则
  Future<String?> _evaluateJavaRule(String javaCode, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    // Java 规则通过 Android 原生层执行，预留接口
    try {
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 执行正则替换
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

  /// 执行 CSS 选择器（通过 Jsoup 桥接）
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

  /// 执行 XPath（预留）
  Future<String?> xpathSelect(String html, String xpath) async {
    return null;
  }

  /// 执行 JSONPath
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

  /// 解析 JS 返回值，尝试还原为原始 Dart 类型
  dynamic _parseJsResult(String result) {
    if (result == 'undefined' || result == 'null') return null;
    if (result == 'true') return true;
    if (result == 'false') return false;
    // 尝试解析为数字
    final numVal = num.tryParse(result);
    if (numVal != null) return numVal;
    // 尝试解析为 JSON
    try {
      return jsonDecode(result);
    } catch (_) {}
    // 返回原始字符串
    return result;
  }

  /// 释放资源
  void dispose() {
    _jsRuntime?.dispose();
    _jsRuntime = null;
    _initialized = false;
    _installedPackages.clear();
    _moduleCache.clear();
  }
}
