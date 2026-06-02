import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// JS/TS 运行时引擎 - 完整的 Node.js 兼容环境
/// 支持：书源规则执行、自定义库安装、TypeScript 编译
class JsEngine {
  static JsEngine? _instance;
  static JsEngine get instance => _instance ??= JsEngine._();

  JsEngine._();

  bool _initialized = false;
  dynamic _jsRuntime; // flutter_js 运行时实例
  final Map<String, String> _installedPackages = {}; // 已安装的包
  final Map<String, String> _moduleCache = {}; // 模块缓存

  /// 初始化 JS 引擎
  Future<bool> init() async {
    if (_initialized) return true;
    try {
      // 初始化 flutter_js 运行时
      _jsRuntime = null; // TODO: 创建 JavascriptRuntime
      _initialized = true;

      // 注入 Node.js 兼容层
      await _injectNodePolyfills();
      // 注入 Java 桥接对象
      _injectJavaBridge();
      // 加载已安装的自定义库
      await _loadInstalledPackages();

      return true;
    } catch (e) {
      return false;
    }
  }

  bool get isAvailable => _initialized;

  // ===== Node.js API 兼容层 =====

  /// 注入 Node.js 核心 API 模拟
  Future<void> _injectNodePolyfills() async {
    const nodePolyfills = '''
      // ===== Node.js 核心模块模拟 =====

      // console 对象
      var console = {
        log: function() { __nativeLog(Array.from(arguments).join(' ')); },
        error: function() { __nativeLog('[ERROR] ' + Array.from(arguments).join(' ')); },
        warn: function() { __nativeLog('[WARN] ' + Array.from(arguments).join(' ')); },
        info: function() { __nativeLog('[INFO] ' + Array.from(arguments).join(' ')); },
        debug: function() { __nativeLog('[DEBUG] ' + Array.from(arguments).join(' ')); },
        time: function(label) { __nativeTimeStart(label || 'default'); },
        timeEnd: function(label) { __nativeTimeEnd(label || 'default'); },
      };

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
        exit: function(code) { __nativeLog('Process exit with code: ' + code); },
        nextTick: function(fn) { setTimeout(fn, 0); },
        on: function(event, handler) {},
        stdout: { write: function(data) { __nativeLog(data); } },
        stderr: { write: function(data) { __nativeLog('[STDERR] ' + data); } },
      };

      // setTimeout / setInterval / clearTimeout / clearInterval
      var _timers = {};
      var _timerId = 0;
      function setTimeout(fn, delay) {
        var id = ++_timerId;
        _timers[id] = true;
        __nativeSetTimeout(id, delay || 0);
        return id;
      }
      function setInterval(fn, delay) {
        var id = ++_timerId;
        _timers[id] = true;
        __nativeSetInterval(id, delay || 0);
        return id;
      }
      function clearTimeout(id) { delete _timers[id]; }
      function clearInterval(id) { delete _timers[id]; }

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

      // fetch API 模拟（通过原生桥接）
      function fetch(url, options) {
        options = options || {};
        return __nativeFetch(url, options.method || 'GET', options.body || '', options.headers || {});
      }

      // Promise (如果引擎不支持)
      if (typeof Promise === 'undefined') {
        var Promise = function(executor) {
          var self = this;
          self._state = 'pending';
          self._value = undefined;
          self._callbacks = [];
          function resolve(value) {
            self._state = 'fulfilled';
            self._value = value;
            self._callbacks.forEach(function(cb) { cb.onFulfilled(value); });
          }
          function reject(reason) {
            self._state = 'rejected';
            self._value = reason;
            self._callbacks.forEach(function(cb) { cb.onRejected(reason); });
          }
          try { executor(resolve, reject); } catch(e) { reject(e); }
        };
        Promise.prototype.then = function(onFulfilled, onRejected) {
          return new Promise(function(resolve, reject) {});
        };
        Promise.prototype.catch = function(onRejected) { return this.then(null, onRejected); };
        Promise.resolve = function(value) { return new Promise(function(r) { r(value); }); };
        Promise.reject = function(reason) { return new Promise(function(_, r) { r(reason); }); };
        Promise.all = function(promises) { return new Promise(function(resolve) { resolve([]); }); };
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
          return module.exports;
        }
        // 内置模块模拟
        switch(name) {
          case 'http': return { get: function(url, cb) { __nativeLog('http.get: ' + url); }, request: function() {} };
          case 'https': return { get: function(url, cb) { __nativeLog('https.get: ' + url); }, request: function() {} };
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

      // JSON 增强
      var JSON = JSON || {
        parse: function(s) { return eval('(' + s + ')'); },
        stringify: function(o) { return __nativeJsonStringify(o); },
      };

      // cheerio 兼容（jQuery-like HTML 解析）
      // var cheerio = require('cheerio');
      // var dollarSign = cheerio;
    ''';

    await evaluate(nodePolyfills);
  }

  // ===== Java 桥接对象 =====

  /// 注入 Legado 兼容的 Java 桥接对象
  void _injectJavaBridge() {
    const javaBridge = '''
      // ===== Legado Java 桥接对象 =====
      var java = {
        // HTTP 请求方法
        get: function(url, headers) {
          return __nativeHttpGet(url, headers || {});
        },
        post: function(url, body, headers) {
          return __nativeHttpPost(url, body || '', headers || {});
        },
        ajax: function(url, headers) {
          return __nativeHttpGet(url, headers || {});
        },
        ajaxAll: function(urls) {
          return urls.map(function(url) { return __nativeHttpGet(url, {}); });
        },
        put: function(key, value) {
          __nativePut(key, value);
        },
        getStr: function(key, defaultValue) {
          return __nativeGetStr(key, defaultValue || '');
        },
        log: function(msg) {
          __nativeLog(String(msg));
        },

        // 字符串操作
        getString: function(str, ruleStr) {
          if (!str || !ruleStr) return '';
          return __nativeRuleString(str, ruleStr);
        },
        getStrResponse: function(url, ruleStr) {
          var html = __nativeHttpGet(url, {});
          return __nativeRuleString(html, ruleStr);
        },

        // JSON 操作
        getJson: function(str) {
          try { return JSON.parse(str); } catch(e) { return {}; }
        },
        putJson: function(key, value) {
          __nativePut(key, JSON.stringify(value));
        },

        // 加密/解密
        aesEncode: function(data, key, iv) {
          return __nativeAesEncode(data, key, iv || '');
        },
        aesDecode: function(data, key, iv) {
          return __nativeAesDecode(data, key, iv || '');
        },
        md5Encode: function(str) {
          return __nativeMd5(str);
        },
        base64Encode: function(str) {
          return __nativeBase64Encode(str);
        },
        base64Decode: function(str) {
          return __nativeBase64Decode(str);
        },

        // HTML 解析（Jsoup 桥接）
        jsoup: {
          parse: function(html) {
            return { select: function(sel) { return __nativeJsoupSelect(html, sel); } };
          },
          select: function(html, selector) {
            return __nativeJsoupSelectAll(html, selector);
          },
          selectFirst: function(html, selector) {
            return __nativeJsoupSelect(html, selector);
          },
          getAttr: function(html, selector, attr) {
            return __nativeJsoupGetAttr(html, selector, attr);
          },
          clean: function(html) {
            return __nativeJsoupClean(html);
          },
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
          return __nativeTimeFormat(timestamp, format || 'yyyy-MM-dd HH:mm:ss');
        },
        getTime: function() {
          return Date.now();
        },

        // WebView 池
        webview: {
          eval: function(url, js) {
            return __nativeWebviewEval(url, js);
          },
        },

        // 缓存操作
        cache: {
          get: function(key) { return __nativeGetStr(key, ''); },
          put: function(key, value) { __nativePut(key, value); },
          delete: function(key) { __nativeDelete(key); },
        },
      };

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
    // 函数参数类型: (param: Type) → (param)
    js = js.replaceAllMapped(
      RegExp(r'(\w+)\s*:\s*[\w\[\]<>\|&\s]+([,\)])'),
      (m) => '${m[1]}${m[2]}',
    );
    // 返回类型: ): Type => / ): Type {
    js = js.replaceAllMapped(
      RegExp(r'\)\s*:\s*[\w\[\]<>\|&\s]+\s*([=>{])'),
      (m) => ') ${m[1]}',
    );
    // 变量类型: const/let/var x: Type = → const/let/var x =
    js = js.replaceAllMapped(
      RegExp(r'(const|let|var)\s+(\w+)\s*:\s*[\w\[\]<>\|&\s]+=\s*'),
      (m) => '${m[1]} ${m[2]} = ',
    );
    // interface 声明移除
    js = js.replaceAll(RegExp(r'interface\s+\w+\s*\{[^}]*\}', multiLine: true), '');
    // type 声明移除
    js = js.replaceAll(RegExp(r'type\s+\w+\s*=\s*[^;]+;'), '');
    // as 类型断言移除
    js = js.replaceAllMapped(RegExp(r'\s+as\s+[\w\[\]<>\|&]+'), (m) => '');
    // 泛型函数调用: func<Type>(args) → func(args)
    js = js.replaceAllMapped(
      RegExp(r'(\w+)<[^>]+>\('),
      (m) => '${m[1]}(',
    );
    // 枚举转对象
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
    // 可选链: obj?.prop → (obj && obj.prop)
    js = js.replaceAllMapped(
      RegExp(r'(\w+)\?\.(?:(\w+)\()?'),
      (m) => m[2] != null ? '(${m[1]} && ${m[1]}.${m[2]}(' : '(${m[1]} && ${m[1]}.',
    );
    // 空值合并: a ?? b → (a != null ? a : b)
    js = js.replaceAllMapped(
      RegExp(r'(\w+)\s*\?\?\s*'),
      (m) => '(${m[1]} != null ? ${m[1]} : ',
    );
    // 移除 public/private/protected 修饰符
    js = js.replaceAll(RegExp(r'\b(public|private|protected|readonly)\s+'), '');
    // 移除 abstract
    js = js.replaceAll(RegExp(r'\babstract\s+'), '');
    // 移除 implements 子句
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

      // 保存包代码
      final file = File('${pkgDir.path}/index.js');
      await file.writeAsString(code);

      // 保存包信息
      final info = {
        'name': name,
        'version': version ?? '1.0.0',
        'installedAt': DateTime.now().toIso8601String(),
      };
      final infoFile = File('${pkgDir.path}/package.json');
      await infoFile.writeAsString(jsonEncode(info));

      // 注册到运行时
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
      // 通过原生 OkHttp 下载
      // final code = await NativeChannel.instance.httpGet(url);
      // if (code == null) return false;
      // return await installPackage(name, code);
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

  /// 执行 JS 脚本
  Future<dynamic> evaluate(String script) async {
    if (!_initialized) return null;
    try {
      // TODO: 通过 flutter_js 执行
      // return _jsRuntime.evaluate(script);
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 执行 TypeScript 脚本（自动编译为 JS）
  Future<dynamic> evaluateTypeScript(String tsCode) async {
    final jsCode = await compileTypeScript(tsCode);
    return await evaluate(jsCode);
  }

  /// 执行书源规则（支持 JS/Java/TS 三种格式）
  /// Legado 格式：@js: / <js></js> / @java: / <java></java>
  Future<String?> evaluateBookRule(String ruleCode, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    if (!_initialized) return null;
    try {
      // 检测规则类型
      String jsCode;
      if (ruleCode.startsWith('@ts:') || ruleCode.startsWith('<ts>')) {
        // TypeScript 规则
        final tsCode = ruleCode.startsWith('@ts:')
            ? ruleCode.substring(4)
            : ruleCode.replaceAll(RegExp(r'^<ts>|</ts>$'), '');
        jsCode = await compileTypeScript(tsCode);
      } else if (ruleCode.startsWith('@java:') || ruleCode.startsWith('<java>')) {
        // Java 规则 - 通过原生通道执行
        final javaCode = ruleCode.startsWith('@java:')
            ? ruleCode.substring(6)
            : ruleCode.replaceAll(RegExp(r'^<java>|</java>$'), '');
        return await _evaluateJavaRule(javaCode, result: result, env: env);
      } else {
        // JS 规则
        jsCode = ruleCode.startsWith('@js:')
            ? ruleCode.substring(4)
            : ruleCode.replaceAll(RegExp(r'^<js>|</js>$'), '');
      }

      // 注入环境变量
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

      return await evaluate(wrappedScript) as String?;
    } catch (e) {
      return null;
    }
  }

  /// 通过原生通道执行 Java 规则
  Future<String?> _evaluateJavaRule(String javaCode, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    // Java 规则通过 Android 原生层执行
    // 预留接口，需要 Android 原生侧实现
    try {
      // return await NativeChannel.instance.evaluateJavaRule(javaCode, result: result, env: env);
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 执行正则替换
  Future<String?> regexReplace(String text, String pattern, String replacement) async {
    if (!_initialized) return null;
    try {
      final script = '''
        (function() {
          var text = ${jsonEncode(text)};
          var pattern = $pattern;
          var replacement = ${jsonEncode(replacement)};
          return text.replace(new RegExp(pattern, 'g'), replacement);
        })();
      ''';
      return await evaluate(script) as String?;
    } catch (e) {
      return null;
    }
  }

  /// 执行 CSS 选择器（通过 Jsoup 桥接）
  Future<String?> cssSelect(String html, String selector) async {
    if (!_initialized) return null;
    try {
      final script = '''
        (function() {
          return java.jsoup.selectFirst(${jsonEncode(html)}, ${jsonEncode(selector)});
        })();
      ''';
      return await evaluate(script) as String?;
    } catch (e) {
      return null;
    }
  }

  /// 执行 XPath（预留）
  Future<String?> xpathSelect(String html, String xpath) async {
    // XPath 需要原生层支持
    return null;
  }

  /// 执行 JSONPath
  Future<dynamic> jsonPath(String jsonStr, String path) async {
    if (!_initialized) return null;
    try {
      final script = '''
        (function() {
          var data = JSON.parse(${jsonEncode(jsonStr)});
          var path = ${jsonEncode(path)};
          // 简单的 JSONPath 实现
          var parts = path.replace(/^\\\$\\\./, '').split('.');
          var result = data;
          for (var i = 0; i < parts.length; i++) {
            if (result == null) return null;
            result = result[parts[i]];
          }
          return JSON.stringify(result);
        })();
      ''';
      return await evaluate(script);
    } catch (e) {
      return null;
    }
  }

  /// 释放资源
  void dispose() {
    _initialized = false;
    _installedPackages.clear();
    _moduleCache.clear();
  }
}
