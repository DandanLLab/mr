import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';

import '../app_logger.dart';
import 'js_engine_types.dart';

/// JS 引擎（基于 flutter_js / QuickJS）
///
/// 职责：
/// 1. 初始化 flutter_js 引擎
/// 2. 从 assets/js_polyfill/ 加载 4 个 JS polyfill 文件注入引擎
/// 3. 对外暴露 evaluate / executeSync / processJsRule / batchEvaluate
/// 4. 管理引擎生命周期（init/dispose）
/// 5. 异常捕获和日志
///
/// 不再负责网络请求（预缓存逻辑已移除，由 web_book.dart 用 Dio 协调）。
class JsEngine {
  static final JsEngine instance = JsEngine._();
  JsEngine._();

  JavascriptRuntime? _runtime;
  bool _initialized = false;
  bool _evalBusy = false;

  // ===== 缓存 =====
  final Map<String, String> _bridgeCache = {};
  final Map<String, String> _jsLibCache = {};
  String? _currentJsLibSourceUrl;
  final List<String> _currentJsLibFunctions = [];
  String? _cachedSourceJson;
  String? _cachedSourceKey;
  final Set<String> _cachedKeys = {};

  // ===== 正则常量 =====
  static final _returnRegex = RegExp(r'\breturn\b');
  static final _jsTagRegex = RegExp(r'<js>([\s\S]*?)</js>', caseSensitive: false);
  static final _jsPrefixRegex = RegExp(r'^@js:', caseSensitive: false);
  static final _engineTagRegex = RegExp(r'^<js>|</js>$', caseSensitive: false);
  static final _funcNamePattern = RegExp(r'function\s+(\w+)\s*\(');
  static final _varFuncPattern = RegExp(r'var\s+(\w+)\s*=\s*function');
  static final _thisFuncPattern = RegExp(r'this\.(\w+)\s*=\s*function');

  bool get isAvailable => _initialized && _runtime != null;

  // ===== 初始化 =====

  /// 初始化 JS 引擎：创建 flutter_js runtime + 加载 polyfill
  Future<bool> init() async {
    if (_initialized && _runtime != null) return true;

    try {
      _runtime = getJavascriptRuntime();

      // 从 assets 加载 4 个 polyfill 文件并注入
      await _loadPolyfills();

      // 验证注入是否成功
      final verify = evaluate(
        'typeof java !== "undefined" && typeof CryptoJS !== "undefined" && typeof _javaCache !== "undefined" && typeof _AES !== "undefined"',
      );
      if (verify != 'true') {
        debugPrint('JsEngine init: polyfill 验证失败');
        _disposeRuntime();
        return false;
      }

      _initialized = true;
      debugPrint('JsEngine init: 成功（flutter_js + QuickJS）');
      return true;
    } catch (e, st) {
      debugPrint('JsEngine init failed: $e\n$st');
      _disposeRuntime();
      return false;
    }
  }

  /// 从 assets/js_polyfill/ 加载 4 个 polyfill 文件
  Future<void> _loadPolyfills() async {
    const files = [
      'assets/js_polyfill/node-polyfill.js',
      'assets/js_polyfill/crypto-js.js',
      'assets/js_polyfill/jsoup-lite.js',
      'assets/js_polyfill/java-bridge.js',
    ];
    for (final path in files) {
      try {
        final code = await rootBundle.loadString(path);
        final result = _runtime!.evaluate(code);
        if (result.isError) {
          debugPrint('JsEngine: 加载 $path 失败: ${result.stringResult}');
        }
      } catch (e) {
        debugPrint('JsEngine: 加载 $path 异常: $e');
      }
    }
  }

  void _disposeRuntime() {
    try {
      _runtime?.dispose();
    } catch (_) {}
    _runtime = null;
    _initialized = false;
  }

  // ===== 基础执行 =====

  /// 同步执行 JS 代码，返回字符串结果
  String? evaluate(String script) {
    if (_runtime == null) return null;
    if (_evalBusy) {
      debugPrint('⚠️ evaluate 跳过：JS引擎正忙');
      return null;
    }
    _evalBusy = true;
    try {
      final result = _runtime!.evaluate(script);
      _flushConsoleLogs();
      if (result.isError) {
        AppLogger.instance.logJsError('QuickJS', result.stringResult);
        return null;
      }
      return result.stringResult;
    } catch (e) {
      AppLogger.instance.logJsError('QuickJS', e.toString());
      return null;
    } finally {
      _evalBusy = false;
    }
  }

  /// 批量 JS 执行（轻量路径，跳过变量注入和追踪）
  Future<String?> batchEvaluate(String script) async {
    if (_runtime == null) return null;
    try {
      final result = _runtime!.evaluate(script);
      _flushConsoleLogs();
      if (result.isError) {
        AppLogger.instance.logJsError('batchEvaluate', result.stringResult);
        return null;
      }
      return result.stringResult;
    } catch (e) {
      AppLogger.instance.logJsError('batchEvaluate', e.toString());
      return null;
    }
  }

  /// 同步执行 JS 代码（用于 AnalyzeRule 规则解析）
  ///
  /// [jsCode] JS 代码（可含 <js></js> 标签或 @js: 前缀）
  /// [content] 传入 JS 的 result 变量值
  /// [baseUrl] 传入 JS 的 baseUrl 变量
  /// [variables] 额外变量注入
  dynamic executeSync(
    String jsCode,
    dynamic content, {
    String? baseUrl,
    JsEngineType? sourceEngine,
    Map<String, dynamic>? variables,
    String? ruleStep,
  }) {
    if (!_initialized || _runtime == null) return null;
    if (_evalBusy) {
      debugPrint('⚠️ executeSync 跳过：JS引擎正忙');
      return null;
    }

    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final code = _stripJsPrefix(extracted);

    AppLogger.instance.incrementQuickjsCount();
    AppLogger.instance.logJsExecute('QuickJS', code);

    _evalBusy = true;
    try {
      final contentStr = serializeForJs(content);
      final wrappedCode = _wrapJsCode(code);

      // 构建变量注入
      final coreVars = {'result', 'baseUrl', 'content', 'src'};
      final varInjections = <String>[];
      final globalVarInjections = <String>[];
      if (variables != null) {
        for (final entry in variables.entries) {
          if (!coreVars.contains(entry.key)) {
            final encoded = jsonEncode(entry.value);
            varInjections.add('var ${entry.key} = $encoded;');
            globalVarInjections.add('globalThis.${entry.key} = $encoded;');
          }
        }
      }
      final varCode = varInjections.join('\n');
      final globalVarCode = globalVarInjections.join('\n');

      final wrappedScript = '''
        (function() {
          var result = $contentStr;
          var baseUrl = ${jsonEncode(baseUrl ?? '')};
          var content = result;
          var src = $contentStr;
          $varCode
          globalThis.result = result;
          globalThis.baseUrl = baseUrl;
          globalThis.src = src;
          $globalVarCode
          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
            if (__returnValue instanceof Uint8Array) return JSON.stringify(Array.from(__returnValue));
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';

      final evalResult = _runtime!.evaluate(wrappedScript);
      _flushConsoleLogs();

      if (evalResult.isError) {
        AppLogger.instance.logJsError('QuickJS',
            _buildErrorDetail(evalResult.stringResult, content));
        return null;
      }
      return _parseJsResult(evalResult.stringResult);
    } catch (e) {
      AppLogger.instance.logJsError('QuickJS', e.toString());
      return null;
    } finally {
      _evalBusy = false;
    }
  }

  /// 异步执行 JS 规则（用于 web_book / analyze_rule）
  ///
  /// 不再执行 _preCacheBridgeCalls 预缓存——JS 规则里的网络请求由 web_book.dart 用 Dio 协调。
  Future<String?> processJsRule(
    String content,
    String jsCode, {
    String? baseUrl,
    JsEngineType? sourceEngine,
    Map<String, dynamic>? env,
    dynamic dynamicContent,
  }) async {
    if (!_initialized || _runtime == null) {
      await init();
      if (!_initialized || _runtime == null) return null;
    }

    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final code = _stripJsPrefix(extracted);

    AppLogger.instance.incrementQuickjsCount();
    AppLogger.instance.logJsExecute('QuickJS', code);

    // 合并 env
    final mergedEnv = <String, dynamic>{'baseUrl': baseUrl ?? ''};
    if (env != null) {
      mergedEnv.addAll(env);
      if (!mergedEnv.containsKey('baseUrl')) mergedEnv['baseUrl'] = baseUrl ?? '';
    }

    final actualResult = dynamicContent ?? content;

    // 等待引擎空闲
    while (_evalBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _evalBusy = true;
    try {
      return _executeRule(code, result: actualResult, env: mergedEnv);
    } finally {
      _evalBusy = false;
    }
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
    if (!_initialized || _runtime == null) {
      await init();
      if (!_initialized || _runtime == null) return null;
    }

    final extracted = _extractJsCode(jsCode) ?? jsCode;
    final code = _stripJsPrefix(extracted);
    final wrappedCode = _wrapJsCode(code);

    while (_evalBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _evalBusy = true;
    try {
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
          globalThis.result = result;
          globalThis.baseUrl = baseUrl;
          globalThis.book = book;
          globalThis.chapter = chapter;
          globalThis.source = source;
          globalThis.cookie = cookie;
          var __returnValue = (function() { $wrappedCode })();
          if (typeof __returnValue === 'object' && __returnValue !== null) {
            if (__returnValue instanceof Uint8Array) return JSON.stringify(Array.from(__returnValue));
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';
      await Future<void>.delayed(Duration.zero);
      final evalResult = _runtime!.evaluate(wrappedScript);
      _flushConsoleLogs();
      if (evalResult.isError) {
        AppLogger.instance.logJsError('QuickJS',
            _buildErrorDetail(evalResult.stringResult, content,
                sourceMap: source));
        return null;
      }
      return evalResult.stringResult;
    } catch (e) {
      AppLogger.instance.logJsError('QuickJS', e.toString());
      return null;
    } finally {
      _evalBusy = false;
    }
  }

  /// 执行书源规则（统一入口）
  Future<String?> evaluateBookRule(
    String ruleCode, {
    dynamic result,
    Map<String, dynamic>? env,
    JsEngineType? sourceEngine,
  }) async {
    final code = _stripJsPrefix(_extractJsCode(ruleCode) ?? ruleCode);

    while (_evalBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    _evalBusy = true;
    try {
      return _executeRule(code, result: result, env: env);
    } finally {
      _evalBusy = false;
    }
  }

  /// 核心规则执行（构建 wrappedScript + evaluate）
  String? _executeRule(
    String jsCode, {
    dynamic result,
    Map<String, dynamic>? env,
  }) {
    if (!_initialized || _runtime == null) return null;

    try {
      final wrappedCode = _wrapJsCode(jsCode);
      final resultStr = serializeForJs(result);

      // 构建额外变量注入
      final coreVars = {'result', 'baseUrl', 'content', 'src', 'book', 'chapter', 'source', 'cookie', 'title'};
      final varInjections = <String>[];
      final globalVarInjections = <String>[];
      if (env != null) {
        for (final entry in env.entries) {
          if (!coreVars.contains(entry.key)) {
            final encoded = jsonEncode(entry.value);
            varInjections.add('var ${entry.key} = $encoded;');
            globalVarInjections.add('globalThis.${entry.key} = $encoded;');
          }
        }
      }
      final varCode = varInjections.join('\n');
      final globalVarCode = globalVarInjections.join('\n');

      final wrappedScript = '''
        (function() {
          var result = $resultStr;
          var baseUrl = ${jsonEncode(env?['baseUrl'] ?? '')};
          var book = ${jsonEncode(env?['book'] ?? {})};
          var chapter = ${jsonEncode(env?['chapter'] ?? {})};
          var source = ${getCachedSourceJson(env?['source'] as Map<String, dynamic>?)};
          var cookie = ${jsonEncode(env?['cookie'] ?? {})};
          var title = ${jsonEncode(env?['chapter']?['title'] ?? '')};
          var src = result;
          $varCode
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
            if (__returnValue instanceof Uint8Array) return JSON.stringify(Array.from(__returnValue));
            return JSON.stringify(__returnValue);
          }
          return __returnValue;
        })();
      ''';

      final evalResult = _runtime!.evaluate(wrappedScript);
      _flushConsoleLogs();

      if (evalResult.isError) {
        final src = env?['source'];
        AppLogger.instance.logJsError('QuickJS',
            _buildErrorDetail(evalResult.stringResult, result,
                sourceMap: src is Map<String, dynamic> ? src : null));
        return null;
      }
      final strResult = evalResult.stringResult;
      if (strResult == 'undefined') return '';
      if (strResult == 'null') return null;
      return strResult;
    } catch (e) {
      AppLogger.instance.logJsError('QuickJS', e.toString());
      return null;
    }
  }

  /// 构建 JS 错误上下文：错误信息 + 书源名 + 输入值预览
  /// 用于定位"响应内容不对"类问题（如 LZString 解压失败、JSON 字段缺失、
  /// 返回 HTML 错误页等）——看到输入预览就能判断是响应问题还是规则问题
  String _buildErrorDetail(String errorMsg, dynamic inputValue,
      {Map<String, dynamic>? sourceMap}) {
    final buffer = StringBuffer(errorMsg);
    // 书源名
    final name = sourceMap?['bookSourceName'];
    if (name is String && name.isNotEmpty) {
      buffer.write('\n[书源] $name');
    }
    // 输入值预览（前 200 字符，压缩空白方便单行显示）
    if (inputValue != null) {
      buffer.write(
          '\n[输入] (${inputValue.runtimeType}) ${_previewValue(inputValue)}');
    }
    return buffer.toString();
  }

  /// 预览值：截取前 [maxLen] 字符，压缩空白方便单行显示
  String _previewValue(dynamic value, [int maxLen = 200]) {
    String str;
    if (value is String) {
      str = value;
    } else {
      try {
        str = jsonEncode(value);
      } catch (_) {
        str = '$value';
      }
    }
    str = str.replaceAll(RegExp(r'\s+'), ' ');
    if (str.length > maxLen) {
      return '${str.substring(0, maxLen)}... (${str.length} chars)';
    }
    return str;
  }

  // ===== jsLib 管理 =====

  /// 加载书源的 jsLib 到全局作用域
  void loadJsLib(String sourceUrl, String jsLib) {
    if (jsLib.trim().isEmpty) return;
    _jsLibCache[sourceUrl] = jsLib;
    if (_currentJsLibSourceUrl == sourceUrl) return;

    // 切换书源：先清除旧的 jsLib 全局函数
    _clearCurrentJsLib();

    // 提取函数名
    _extractFunctionNames(jsLib);

    // 执行 jsLib
    try {
      _runtime?.evaluate(jsLib);
      _currentJsLibSourceUrl = sourceUrl;
    } catch (e) {
      debugPrint('JsEngine.loadJsLib error: $e');
    }
  }

  void _clearCurrentJsLib() {
    if (_currentJsLibFunctions.isNotEmpty && _runtime != null) {
      try {
        final delCode = _currentJsLibFunctions.map((fn) => 'delete globalThis.$fn').join(';');
        _runtime!.evaluate(delCode);
      } catch (_) {}
    }
    _currentJsLibFunctions.clear();
    _currentJsLibSourceUrl = null;
  }

  void _extractFunctionNames(String jsLib) {
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

  // ===== 缓存管理 =====

  /// 清除 JS 侧 _javaCache
  void clearJavaCache() {
    if (_runtime == null || !_initialized) return;
    try {
      evaluate('_javaCache = {};');
      _cachedKeys.clear();
      _bridgeCache.clear();
    } catch (e) {
      debugPrint('JsEngine.clearJavaCache error: $e');
    }
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

  /// 获取缓存的 source JSON 字符串（同一书源复用）
  String getCachedSourceJson(Map<String, dynamic>? sourceMap) {
    if (sourceMap == null || sourceMap.isEmpty) return '{}';
    final key = sourceMap['bookSourceUrl'] as String? ?? '';
    if (key == _cachedSourceKey && _cachedSourceJson != null) {
      return _cachedSourceJson!;
    }
    final encoded = jsonEncode(sourceMap);
    _cachedSourceJson = encoded;
    _cachedSourceKey = key;
    return encoded;
  }

  // ===== 工具方法 =====

  /// URL 编码（GBK 等非 UTF-8 编码回退到 UTF-8）
  String urlEncodeNative(String input, String charset) {
    // flutter_js 无 C FFI，非 UTF-8 编码回退到 Uri.encodeComponent
    return Uri.encodeComponent(input);
  }

  /// URL 解码
  String urlDecodeNative(String input) {
    return Uri.decodeComponent(input);
  }

  /// HTML 查询提取（通过 JS 引擎的 _JsoupLite）
  String htmlQueryExtractNative(String html, String selector, String attr, bool listMode) {
    if (!_initialized || _runtime == null) return '';
    try {
      final htmlEnc = jsonEncode(html);
      final selEnc = jsonEncode(selector);
      if (listMode) {
        if (attr == '@text' || attr == '@text()') {
          return evaluate('JSON.stringify(_JsoupLite.selectAll($htmlEnc, $selEnc))') ?? '[]';
        } else if (attr == '@outerHtml') {
          return evaluate('JSON.stringify(_JsoupLite.selectAll($htmlEnc, $selEnc))') ?? '[]';
        }
        return evaluate('JSON.stringify(_JsoupLite.selectAll($htmlEnc, $selEnc))') ?? '[]';
      } else {
        if (attr == '@text' || attr == '@text()') {
          return evaluate('_JsoupLite.selectFirst($htmlEnc, $selEnc)') ?? '';
        }
        return evaluate('_JsoupLite.selectFirst($htmlEnc, $selEnc)') ?? '';
      }
    } catch (_) {
      return '';
    }
  }

  /// HTML 反转义
  String unescapeHtmlNative(String input) {
    if (!_initialized || _runtime == null) return input;
    try {
      final result = evaluate('${jsonEncode(input)}.replace(/&amp;/g,"&").replace(/&lt;/g,"<").replace(/&gt;/g,">").replace(/&quot;/g,\x27"\x27).replace(/&#39;/g,"\\x27").replace(/&nbsp;/g," ")');
      return result?.toString() ?? input;
    } catch (_) {
      return input;
    }
  }

  /// 序列化 content 为 JS 表达式（用于嵌入 JS 脚本）
  static String serializeForJs(dynamic content) {
    if (content is List || content is Map) {
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

  // ===== 私有辅助 =====

  /// 包裹 JS 代码，确保最后一个表达式的值被返回
  String _wrapJsCode(String code) {
    final trimmed = code.trim();
    if (trimmed.contains(_returnRegex)) return trimmed;
    final lines = trimmed.split('\n');
    if (lines.length == 1) return 'return $trimmed';
    final lastLine = lines.last.trim();
    if (lastLine.isEmpty) return trimmed;
    return 'return eval(${jsonEncode(trimmed)})';
  }

  /// 从规则字符串中提取 JS 代码
  String? _extractJsCode(String rule) {
    final jsTagMatch = _jsTagRegex.firstMatch(rule);
    if (jsTagMatch != null) return jsTagMatch.group(1)?.trim();
    if (_jsPrefixRegex.hasMatch(rule)) {
      return rule.replaceFirst(_jsPrefixRegex, '').trim();
    }
    return null;
  }

  /// 剥离 @js: 前缀和 <js></js> 标签
  String _stripJsPrefix(String code) {
    var result = code;
    if (_jsPrefixRegex.hasMatch(result)) {
      result = result.replaceFirst(_jsPrefixRegex, '').trim();
    }
    if (result.startsWith('<js>')) {
      result = result.replaceAll(_engineTagRegex, '').trim();
    }
    return result;
  }

  /// 解析 JS 结果字符串为 Dart 类型
  dynamic _parseJsResult(String result) {
    if (result == 'undefined') return '';
    if (result == 'null') return null;
    if (result == 'true') return true;
    if (result == 'false') return false;
    final numVal = num.tryParse(result);
    if (numVal != null) return numVal;
    if (result.startsWith('{') || result.startsWith('[') || result.startsWith('"')) {
      try {
        return jsonDecode(result);
      } catch (_) {}
    }
    return result;
  }

  /// 提取 JS console 日志并同步到 AppLogger
  void _flushConsoleLogs() {
    if (_runtime == null) return;
    try {
      // 合并获取+清空为一次 evaluate，减少 Dart↔JS FFI 往返开销
      final logsResult = _runtime!.evaluate('console._getAndClearLogs()');
      if (logsResult.isError) return;
      final logsStr = logsResult.stringResult;
      if (logsStr == 'undefined' || logsStr == '[]') return;
      try {
        final logs = jsonDecode(logsStr);
        if (logs is List) {
          for (final log in logs) {
            if (log is Map) {
              final level = log['level'] as String? ?? 'log';
              final msg = log['msg'] as String? ?? '';
              if (level == 'error') {
                AppLogger.instance.logJsError('QuickJS', msg);
              } else if (level == 'warn') {
                AppLogger.instance.warn(LogCategory.js, '[JS] $msg');
              } else {
                // console.log/info/debug/trace → info 级别
                // 打印内容不管成功失败都输出，info 确保日志 tab 默认可见
                AppLogger.instance.info(LogCategory.js, '[JS] $msg');
              }
            }
          }
        }
      } catch (_) {}
    } catch (_) {}
  }

  /// 释放资源
  void dispose() {
    _disposeRuntime();
    _bridgeCache.clear();
    _jsLibCache.clear();
    _cachedKeys.clear();
    _currentJsLibFunctions.clear();
    _cachedSourceJson = null;
    _cachedSourceKey = null;
  }
}
