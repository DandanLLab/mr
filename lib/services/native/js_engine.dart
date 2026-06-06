import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
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
      // 借鉴 legado 的 JsExtensions.ajax，同步模式从缓存取，无缓存返回空
      function fetch(input, init) {
        var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
        var method = (init && init.method) || 'GET';
        var headers = (init && init.headers) || {};
        var body = (init && init.body) || null;
        var cacheKey = method.toUpperCase() === 'POST' ? 'http_post:' + url : 'http_get:' + url;
        if (_javaCache[cacheKey] !== undefined) {
          var cachedText = _javaCache[cacheKey];
          return {
            ok: true,
            status: 200,
            statusText: 'OK',
            url: url,
            headers: {},
            text: function() { return Promise.resolve(cachedText); },
            json: function() { try { return Promise.resolve(JSON.parse(cachedText)); } catch(e) { return Promise.reject(e); } },
            html: function() { return cachedText; },
          };
        }
        return {
          ok: false,
          status: 0,
          statusText: 'No cache',
          url: url,
          headers: {},
          text: function() { return Promise.resolve(''); },
          json: function() { return Promise.reject(new Error('No cache')); },
          html: function() { return ''; },
        };
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
        var cacheKey = this._method === 'POST' ? 'http_post:' + this._url : 'http_get:' + this._url;
        var cachedText = _javaCache[cacheKey] || '';
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

  // ===== Java 桥接对象（QuickJS 侧）=====

  void _injectJavaBridge() {
    // 注意：不能使用 const，因为字符串中包含 $ 符号（JS 正则替换引用 $&）
    final javaBridge = '''
      // ===== Legado Java 桥接对象（QuickJS 侧）=====
      // 借鉴 legado 的 JsExtensions 接口，通过 Dart 侧 NativeChannel 桥接
      // 核心策略：同步模式从 _javaCache 取缓存值，异步模式由 Dart 端预缓存

      var _javaCache = {};

      // ===== 内置 HTML 解析器（不依赖 java.jsoup，避免递归自调用）=====
      // 使用 DOMParser 风格的简易解析，用于 java.jsoup.selectFirst/selectAll/getAttr
      var _JsoupLite = {
        _parse: function(html) {
          // 利用 QuickJS 的 E4X 或 innerHTML 方式解析
          // 这里用正则+字符串匹配实现简易 CSS 选择器
          return html;
        },
        selectFirst: function(html, selector) {
          // 尝试从缓存获取
          var cacheKey = 'jsoup_sf:' + selector + ':' + (html || '').length;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          // 简易实现：用正则匹配常见选择器
          try {
            var result = _JsoupLite._selectImpl(html, selector, true);
            _javaCache[cacheKey] = result;
            return result;
          } catch(e) { return ''; }
        },
        selectAll: function(html, selector) {
          var cacheKey = 'jsoup_sa:' + selector + ':' + (html || '').length;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          try {
            var result = _JsoupLite._selectImpl(html, selector, false);
            _javaCache[cacheKey] = result;
            return result;
          } catch(e) { return []; }
        },
        getAttr: function(html, selector, attr) {
          var cacheKey = 'jsoup_ga:' + selector + ':' + attr + ':' + (html || '').length;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          try {
            // 先找元素，再提取属性
            var el = _JsoupLite._selectImpl(html, selector, true);
            if (!el) return '';
            // 从元素中提取属性
            var attrPattern = new RegExp(attr + '=["\\']([^"\\']*)["\\']', 'i');
            var m = (typeof el === 'string' ? el : '').match(attrPattern);
            var result = m ? m[1] : '';
            _javaCache[cacheKey] = result;
            return result;
          } catch(e) { return ''; }
        },
        _selectImpl: function(html, selector, firstOnly) {
          if (!html || !selector) return firstOnly ? '' : [];
          var sel = selector.trim();

          // 多选择器: sel1, sel2, sel3
          if (sel.indexOf(',') > 0) {
            var parts = sel.split(',');
            var allResults = [];
            for (var i = 0; i < parts.length; i++) {
              var subResults = _JsoupLite._selectImpl(html, parts[i].trim(), false);
              if (subResults && subResults.length) allResults = allResults.concat(subResults);
              if (firstOnly && allResults.length > 0) return allResults[0];
            }
            return firstOnly ? '' : allResults;
          }

          // 子选择器: parent > child
          var childSelMatch = sel.match(/^(.+?)\\s*>\\s*(.+)\$/);
          if (childSelMatch) {
            var parentResults = _JsoupLite._selectImpl(html, childSelMatch[1].trim(), false);
            if (!parentResults || parentResults.length === 0) return firstOnly ? '' : [];
            var childResults = [];
            for (var pi = 0; pi < parentResults.length; pi++) {
              var innerHtml = parentResults[pi];
              // 提取直接子标签
              var innerContent = _getInnerHtml(innerHtml);
              if (innerContent) {
                var found = _JsoupLite._selectImpl(innerContent, childSelMatch[2].trim(), false);
                if (found && found.length) childResults = childResults.concat(found);
              }
              if (firstOnly && childResults.length > 0) return childResults[0];
            }
            return firstOnly ? '' : childResults;
          }

          // 后代选择器: div p (空格分隔，2段)
          if (sel.indexOf(' ') > 0 && !sel.startsWith(' ')) {
            var spaceParts = sel.split(/\\s+/);
            if (spaceParts.length === 2) {
              var parentResults2 = _JsoupLite._selectImpl(html, spaceParts[0], false);
              if (!parentResults2 || parentResults2.length === 0) return firstOnly ? '' : [];
              var childResults2 = [];
              for (var pi2 = 0; pi2 < parentResults2.length; pi2++) {
                var inner2 = _getInnerHtml(parentResults2[pi2]);
                if (inner2) {
                  var found2 = _JsoupLite._selectImpl(inner2, spaceParts[1], false);
                  if (found2 && found2.length) childResults2 = childResults2.concat(found2);
                }
                if (firstOnly && childResults2.length > 0) return childResults2[0];
              }
              return firstOnly ? '' : childResults2;
            }
            // 多层后代选择器：递归
            if (spaceParts.length > 2) {
              var firstPart = spaceParts[0];
              var restPart = spaceParts.slice(1).join(' ');
              var topResults = _JsoupLite._selectImpl(html, firstPart, false);
              if (!topResults || topResults.length === 0) return firstOnly ? '' : [];
              var deepResults = [];
              for (var di = 0; di < topResults.length; di++) {
                var deepInner = _getInnerHtml(topResults[di]);
                if (deepInner) {
                  var deepFound = _JsoupLite._selectImpl(deepInner, restPart, false);
                  if (deepFound && deepFound.length) deepResults = deepResults.concat(deepFound);
                }
                if (firstOnly && deepResults.length > 0) return deepResults[0];
              }
              return firstOnly ? '' : deepResults;
            }
          }

          // 伪类选择器处理: :first-child, :last-child, :nth-child(n), :not(selector)
          var pseudoMatch = sel.match(/^(.+?):(first-child|last-child|nth-child\\(([^)]+)\\)|not\\(([^)]+)\\))\$/);
          if (pseudoMatch) {
            var baseSel = pseudoMatch[1].trim() || '*';
            var pseudoType = pseudoMatch[2];
            var baseElements = _JsoupLite._selectImpl(html, baseSel, false);
            if (!baseElements || baseElements.length === 0) return firstOnly ? '' : [];
            var filtered = [];
            if (pseudoType === 'first-child') {
              filtered = baseElements.length > 0 ? [baseElements[0]] : [];
            } else if (pseudoType === 'last-child') {
              filtered = baseElements.length > 0 ? [baseElements[baseElements.length - 1]] : [];
            } else if (pseudoType.indexOf('nth-child') === 0) {
              var nthArg = pseudoMatch[3];
              var idx = parseInt(nthArg);
              if (!isNaN(idx) && idx > 0 && idx <= baseElements.length) {
                filtered = [baseElements[idx - 1]];
              }
            } else if (pseudoType.indexOf('not') === 0) {
              var notSel = pseudoMatch[4];
              var notElements = _JsoupLite._selectImpl(html, notSel, false) || [];
              for (var ni = 0; ni < baseElements.length; ni++) {
                if (notElements.indexOf(baseElements[ni]) < 0) filtered.push(baseElements[ni]);
              }
            }
            return firstOnly ? (filtered.length > 0 ? filtered[0] : '') : filtered;
          }

          // 通配符: *
          if (sel === '*') {
            var allTags = [];
            var tagRe = /<([a-zA-Z][a-zA-Z0-9]*)[^>]*>/g;
            var tm;
            while ((tm = tagRe.exec(html)) !== null) {
              var fullEl = _extractFullElement(html, tm.index, tm[1]);
              if (fullEl) allTags.push(fullEl);
              if (firstOnly && allTags.length > 0) return allTags[0];
            }
            return firstOnly ? '' : allTags;
          }

          // ID 选择器: #myId
          if (sel.startsWith('#')) {
            var id = sel.substring(1);
            var idPattern = new RegExp('id=["\\']' + _escRe(id) + '["\\']', 'i');
            var tagMatch = html.match(new RegExp('<([a-zA-Z][a-zA-Z0-9]*)[^>]*' + idPattern.source + '[^>]*>([\\\\s\\\\S]*?)<\\\\/\\\\1>', 'i'));
            if (tagMatch) return firstOnly ? tagMatch[0] : [tagMatch[0]];
            return firstOnly ? '' : [];
          }

          // 多 class 选择器: .class1.class2
          if (sel.startsWith('.') && sel.indexOf('.', 1) > 0) {
            var classes = sel.substring(1).split('.');
            var multiClsPattern = 'class=["\\'][^"\\']*';
            for (var ci = 0; ci < classes.length; ci++) {
              multiClsPattern += '\\\\b' + _escRe(classes[ci]) + '\\\\b[^"\\']*';
            }
            multiClsPattern += '["\\']';
            var mClsMatches = _findAllTags(html, new RegExp(multiClsPattern, 'i'), firstOnly);
            return firstOnly ? (mClsMatches.length > 0 ? mClsMatches[0] : '') : mClsMatches;
          }

          // 单 class 选择器: .myClass
          if (sel.startsWith('.')) {
            var cls = sel.substring(1);
            var clsPattern = new RegExp('class=["\\'][^"\\']*\\\\b' + _escRe(cls) + '\\\\b[^"\\']*["\\']', 'i');
            var matches = _findAllTags(html, clsPattern, firstOnly);
            return firstOnly ? (matches.length > 0 ? matches[0] : '') : matches;
          }

          // tag.class1.class2 多class组合
          var tagMultiClsMatch = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)((?:\\.[a-zA-Z_-][a-zA-Z0-9_-]*)+)\$/);
          if (tagMultiClsMatch) {
            var mTag = tagMultiClsMatch[1];
            var mClsList = tagMultiClsMatch[2].substring(1).split('.');
            var mClsPat = '<' + mTag + '[^>]*class=["\\'][^"\\']*';
            for (var mci = 0; mci < mClsList.length; mci++) {
              mClsPat += '\\\\b' + _escRe(mClsList[mci]) + '\\\\b[^"\\']*';
            }
            mClsPat += '["\\'][^>]*>';
            var mClsResults = _findAllTags(html, new RegExp(mClsPat, 'i'), firstOnly);
            return firstOnly ? (mClsResults.length > 0 ? mClsResults[0] : '') : mClsResults;
          }

          // tag#id 组合选择器: div#myId
          var tagIdMatch = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)#([a-zA-Z_-][a-zA-Z0-9_-]*)\$/);
          if (tagIdMatch) {
            var tag2 = tagIdMatch[1];
            var id2 = tagIdMatch[2];
            var combinedPattern2 = new RegExp('<' + tag2 + '[^>]*id=["\\']' + _escRe(id2) + '["\\'][^>]*>', 'i');
            var matches3 = _findAllTags(html, combinedPattern2, firstOnly);
            return firstOnly ? (matches3.length > 0 ? matches3[0] : '') : matches3;
          }

          // 属性选择器: tag[attr=value], [attr=value], tag[attr~=value], tag[attr^=value], tag[attr\$=value], tag[attr*=value]
          var attrSelMatch = sel.match(/^(?:([a-zA-Z][a-zA-Z0-9]*))?\\[([^~^\\\\\$*=]+)([~^\\\\\$*]?)=?["\\']?([^"\\'\\]]*)["\\']?\\]\$/);
          if (attrSelMatch) {
            var tag3 = attrSelMatch[1] || '[a-zA-Z][a-zA-Z0-9]*';
            var attrName = attrSelMatch[2];
            var attrOp = attrSelMatch[3];
            var attrVal = attrSelMatch[4];
            var attrPat;
            if (!attrOp && !attrVal) {
              // [attr] - 属性存在即可
              attrPat = new RegExp('<' + tag3 + '[^>]*' + _escRe(attrName) + '=["\\'][^"\\']*["\\'][^>]*>', 'i');
            } else if (attrOp === '~' && attrVal) {
              // [attr~=value] - 空格分隔的值列表中包含
              attrPat = new RegExp('<' + tag3 + '[^>]*' + _escRe(attrName) + '=["\\'][^"\\']*\\\\b' + _escRe(attrVal) + '\\\\b[^"\\']*["\\'][^>]*>', 'i');
            } else if (attrOp === '^' && attrVal) {
              // [attr^=value] - 以value开头
              attrPat = new RegExp('<' + tag3 + '[^>]*' + _escRe(attrName) + '=["\\']' + _escRe(attrVal) + '[^"\\']*["\\'][^>]*>', 'i');
            } else if (attrOp === '\$' && attrVal) {
              // [attr\$=value] - 以value结尾
              attrPat = new RegExp('<' + tag3 + '[^>]*' + _escRe(attrName) + '=["\\'][^"\\']*' + _escRe(attrVal) + '["\\'][^>]*>', 'i');
            } else if (attrOp === '*' && attrVal) {
              // [attr*=value] - 包含value
              attrPat = new RegExp('<' + tag3 + '[^>]*' + _escRe(attrName) + '=["\\'][^"\\']*' + _escRe(attrVal) + '[^"\\']*["\\'][^>]*>', 'i');
            } else if (attrVal) {
              // [attr=value] - 精确匹配
              attrPat = new RegExp('<' + tag3 + '[^>]*' + _escRe(attrName) + '=["\\']' + _escRe(attrVal) + '["\\'][^>]*>', 'i');
            } else {
              attrPat = new RegExp('<' + tag3 + '[^>]*' + _escRe(attrName) + '=["\\'][^"\\']*["\\'][^>]*>', 'i');
            }
            var matches4 = _findAllTags(html, attrPat, firstOnly);
            return firstOnly ? (matches4.length > 0 ? matches4[0] : '') : matches4;
          }

          // 纯 tag 选择器
          var tagOnly = sel.match(/^[a-zA-Z][a-zA-Z0-9]*\$/);
          if (tagOnly) {
            var tagPattern = new RegExp('<' + sel + '[^>]*>([\\\\s\\\\S]*?)<\\\\/' + sel + '>', 'gi');
            if (firstOnly) {
              var m = tagPattern.exec(html);
              return m ? m[0] : '';
            }
            var results = [];
            var m2;
            while ((m2 = tagPattern.exec(html)) !== null) {
              results.push(m2[0]);
            }
            return results;
          }

          // 通用：无法识别的选择器
          return firstOnly ? '' : [];
        }
      };

      function _escRe(str) {
        return str.replace(/[.*+?^\${}()|[\\]\\\\]/g, '\\\\\$&');
      }

      // 提取元素的内部HTML内容
      function _getInnerHtml(element) {
        if (!element || typeof element !== 'string') return '';
        // 去掉最外层标签，返回内部内容
        var openTagEnd = element.indexOf('>');
        if (openTagEnd < 0) return '';
        var tagMatch = element.substring(0, openTagEnd + 1).match(/^<([a-zA-Z][a-zA-Z0-9]*)/);
        if (!tagMatch) return element;
        var tagName = tagMatch[1];
        var closeTag = '</' + tagName + '>';
        if (element.endsWith(closeTag)) {
          return element.substring(openTagEnd + 1, element.length - closeTag.length);
        }
        return element.substring(openTagEnd + 1);
      }

      // 从指定位置提取完整元素（含嵌套）
      function _extractFullElement(html, startIndex, tagName) {
        var depth = 0;
        var pos = startIndex;
        var openRe = new RegExp('<' + tagName + '[\\\\s>/]', 'gi');
        var closeRe = new RegExp('<\\\\/' + tagName + '>', 'gi');
        openRe.lastIndex = startIndex;
        closeRe.lastIndex = startIndex;
        var endPos = html.length;
        // 简易方式：找到匹配的关闭标签
        var closeMatch = html.indexOf('</' + tagName + '>', startIndex);
        if (closeMatch >= 0) {
          return html.substring(startIndex, closeMatch + tagName.length + 3);
        }
        // 自闭合标签
        var selfClose = html.indexOf('/>', startIndex);
        if (selfClose >= 0 && selfClose < (closeMatch < 0 ? endPos : closeMatch)) {
          return html.substring(startIndex, selfClose + 2);
        }
        return html.substring(startIndex, startIndex + html.substring(startIndex).indexOf('>') + 1);
      }

      function _findAllTags(html, attrPattern, firstOnly) {
        var results = [];
        var tagPattern = /<([a-zA-Z][a-zA-Z0-9]*)[^>]*>/g;
        var m;
        while ((m = tagPattern.exec(html)) !== null) {
          if (attrPattern.test(m[0])) {
            // 找到匹配的开始标签，尝试提取完整元素
            var tagName = m[1];
            var fullEl = _extractFullElement(html, m.index, tagName);
            results.push(fullEl);
            if (firstOnly) break;
          }
        }
        return results;
      }

      var java = {
        // ===== HTTP 请求方法（核心，借鉴 legado JsExtensions.ajax）=====
        get: function(url, headers) {
          var cacheKey = 'http_get:' + url;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        post: function(url, body, headers) {
          var cacheKey = 'http_post:' + url;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        ajax: function(url, headers) {
          return java.get(url, headers);
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
          if (!str || !ruleStr) return str || '';
          // 借鉴 legado 的 JsExtensions.getString：支持 CSS/正则/JSON 规则
          if (ruleStr.startsWith('@css:') || ruleStr.startsWith('@CSS:')) {
            return _JsoupLite.selectFirst(str, ruleStr.substring(5));
          }
          if (ruleStr.startsWith('@json:') || ruleStr.startsWith('@JSON:')) {
            try {
              var data = JSON.parse(str);
              var path = ruleStr.substring(6).trim().replace(/^\\\$\\./, '');
              var parts = path.split('.');
              var result = data;
              for (var i = 0; i < parts.length; i++) {
                if (result == null) return '';
                result = result[parts[i]];
              }
              return result != null ? String(result) : '';
            } catch(e) { return ''; }
          }
          // 正则规则
          if (ruleStr.startsWith('@regex:') || ruleStr.startsWith('@Regex:')) {
            try {
              var pattern = ruleStr.substring(7);
              var m = str.match(new RegExp(pattern));
              return m ? (m[1] || m[0]) : '';
            } catch(e) { return ''; }
          }
          return str;
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

        // ===== 加密/解密（桥接到 NativeChannel，同步模式从缓存取）=====
        aesEncode: function(data, key, iv) {
          var cacheKey = 'aes_enc:' + data + ':' + key + ':' + (iv || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        aesDecode: function(data, key, iv) {
          var cacheKey = 'aes_dec:' + data + ':' + key + ':' + (iv || '');
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        md5Encode: function(str) {
          var cacheKey = 'md5:' + str;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        sha1Encode: function(str) {
          var cacheKey = 'sha1:' + str;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        sha256Encode: function(str) {
          var cacheKey = 'sha256:' + str;
          if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
          return '';
        },
        hmacSHA256: function(data, key) {
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
            return html.replace(/<script[^>]*>[\\\\s\\\\S]*?<\\\\/script>/gi, '')
                       .replace(/<style[^>]*>[\\\\s\\\\S]*?<\\\\/style>/gi, '')
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

        // ===== 元素操作（借鉴 legado JsExtensions）=====
        getElements: function(html, rule) {
          if (!html || !rule) return [];
          return _JsoupLite.selectAll(html, rule);
        },
        getElement: function(html, rule) {
          if (!html || !rule) return '';
          return _JsoupLite.selectFirst(html, rule);
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
  dynamic executeSync(String jsCode, dynamic content, {String? baseUrl, JsEngineType? sourceEngine, Map<String, dynamic>? variables}) {
    // 先提取 JS 代码（去掉 <js></js> 标签或 @js: 前缀）
    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final resolved = resolveEngine(extracted, sourceEngine: sourceEngine);

    if (resolved.engine == JsEngineType.rhino) {
      // Rhino 不支持同步调用（MethodChannel 是异步的），降级到 QuickJS
      debugPrint('JsEngine: Rhino 不支持同步执行，降级到 QuickJS: ${jsCode.substring(0, jsCode.length > 50 ? 50 : jsCode.length)}...');
    }

    return _executeQuickJSSync(resolved.code, content, baseUrl: baseUrl, variables: variables);
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
          var src = result;
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
        return null;
      }
      return _parseJsResult(evalResult.stringResult);
    } catch (e) {
      debugPrint('JsEngine executeSync exception: $e');
      AppLogger.instance.logJsError('QuickJS', e.toString());
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
  Future<String?> processJsRule(String content, String jsCode, {String? baseUrl, JsEngineType? sourceEngine, Map<String, dynamic>? env}) async {
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

    if (resolved.engine == JsEngineType.rhino) {
      return _executeRhinoRule(resolved.code, result: content, env: mergedEnv);
    }

    // 借鉴 legado 的 preCache 机制：在执行 JS 前，预缓存 java.ajax/get/post 的结果
    try {
      await _preCacheBridgeCalls(resolved.code, env: mergedEnv);
    } catch (e) {
      AppLogger.instance.warn(LogCategory.js, '预缓存桥接调用失败，继续执行JS', detail: e.toString());
    }

    return _executeQuickJSRule(resolved.code, result: content, env: mergedEnv, variables: _extractVariables(mergedEnv));
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
    String? result,
    Map<String, dynamic>? env,
    Map<String, dynamic>? variables,
  }) async {
    if (!_initialized || _jsRuntime == null) {
      await init();
      if (!_initialized || _jsRuntime == null) return null;
    }
    try {
      // 断点1：记录原始JS代码
      AppLogger.instance.debug(LogCategory.js, '[QuickJS] 开始执行',
        detail: jsCode.length > 300 ? '${jsCode.substring(0, 300)}...' : jsCode);

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

      final wrappedScript = '''
        (function() {
          var result = ${jsonEncode(result ?? '')};
          var baseUrl = ${jsonEncode(env?['baseUrl'] ?? '')};
          var book = ${jsonEncode(env?['book'] ?? {})};
          var chapter = ${jsonEncode(env?['chapter'] ?? {})};
          var source = ${jsonEncode(env?['source'] ?? {})};
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
      AppLogger.instance.debug(LogCategory.js, '[QuickJS] 执行完成',
        detail: 'isError=${evalResult.isError}, result=${evalResult.stringResult.length > 200 ? "${evalResult.stringResult.substring(0, 200)}..." : evalResult.stringResult}');

      if (evalResult.isError) {
        debugPrint('JsEngine QuickJS error: ${evalResult.stringResult}');
        AppLogger.instance.logJsError('QuickJS', evalResult.stringResult);
        // QuickJS 失败 → 降级到 Rust 引擎
        return fallbackToRustEngine(jsCode, result: result, env: env);
      }
      final strResult = evalResult.stringResult;
      // undefined → 返回空字符串而不是 null（书源规则可能不需要返回值）
      if (strResult == 'undefined') return '';
      // null → 返回 Dart null，避免 "null" 字符串被当作有效结果
      if (strResult == 'null') return null;
      return strResult;
    } catch (e) {
      debugPrint('JsEngine QuickJS exception: $e');
      AppLogger.instance.logJsError('QuickJS', e.toString());
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
    if (!_initialized || _jsRuntime == null) return;

    final baseUrl = env?['baseUrl'] as String? ?? '';

    // 1. 扫描 java.ajax/get/post 调用中的 URL
    final httpPattern = RegExp(
      r"""java\.(?:ajax|get|post)\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    final httpUrls = <String>{};
    for (final match in httpPattern.allMatches(jsCode)) {
      final url = match.group(1);
      if (url != null && url.isNotEmpty) {
        // 处理相对URL
        final absoluteUrl = _resolveUrl(url, baseUrl);
        httpUrls.add(absoluteUrl);
      }
    }

    // 2. 扫描 fetch() 调用中的 URL
    final fetchPattern = RegExp(
      r"""fetch\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
    for (final match in fetchPattern.allMatches(jsCode)) {
      final url = match.group(1);
      if (url != null && url.isNotEmpty) {
        final absoluteUrl = _resolveUrl(url, baseUrl);
        httpUrls.add(absoluteUrl);
      }
    }

    // 3. 并发预缓存 HTTP 结果
    if (httpUrls.isNotEmpty) {
      AppLogger.instance.debug(LogCategory.js, '预缓存 ${httpUrls.length} 个HTTP请求');
      final futures = httpUrls.map((url) async {
        try {
          final result = await NativeChannel.instance.httpGet(url);
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

    // 4. 扫描 java.aesEncode/aesDecode 调用
    final aesPattern = RegExp(
      r"""java\.aes(?:En|De)code\s*\(\s*["']([^"']+)["']\s*,\s*["']([^"']+)["']""",
      multiLine: true,
    );
    final cryptoResults = <String, String>{};
    for (final match in aesPattern.allMatches(jsCode)) {
      final data = match.group(1);
      final key = match.group(2);
      if (data != null && key != null) {
        // AES 加密
        final encKey = 'aes_enc:$data:$key:';
        if (!_isCached(encKey)) {
          final result = await NativeChannel.instance.aesEncrypt(data, key);
          if (result != null) cryptoResults[encKey] = result;
        }
        // AES 解密
        final decKey = 'aes_dec:$data:$key:';
        if (!_isCached(decKey)) {
          final result = await NativeChannel.instance.aesDecrypt(data, key);
          if (result != null) cryptoResults[decKey] = result;
        }
      }
    }

    // 5. 扫描 java.md5Encode 调用
    final md5Pattern = RegExp(
      r"""java\.md5Encode\s*\(\s*["']([^"']+)["']""",
      multiLine: true,
    );
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

    if (cryptoResults.isNotEmpty) {
      await preCacheCryptoResults(cryptoResults);
    }

    // 6. 扫描 java.webview.eval 调用
    final webviewPattern = RegExp(
      r"""java\.webview\.eval\s*\(\s*["']([^"']+)["']\s*,\s*["']([^"']+)["']""",
      multiLine: true,
    );
    for (final match in webviewPattern.allMatches(jsCode)) {
      final url = match.group(1);
      final js = match.group(2);
      if (url != null && js != null) {
        final cacheKey = 'webview:$url:${js.length}';
        if (!_isCached(cacheKey)) {
          final result = await NativeChannel.instance.executeWebViewJs(
            url: url,
            jsCode: js,
          );
          if (result != null) {
            evaluate('_javaCache["$cacheKey"] = ${jsonEncode(result)};');
          }
        }
      }
    }
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
