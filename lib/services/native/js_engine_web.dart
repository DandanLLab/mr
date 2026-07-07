import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'js_engine_types.dart';

/// JS 引擎 Web 桩（Web 平台不支持 flutter_js / QuickJS）
///
/// 所有方法返回空值或默认值，不执行实际 JS 代码。
/// Web 平台的 JS 执行应通过浏览器 JS 引擎或 CORS 代理处理。
class JsEngine {
  static final JsEngine instance = JsEngine._();
  JsEngine._();

  bool _initialized = false;

  // ===== 缓存（保留接口兼容，实际不使用）=====
  final Map<String, String> _bridgeCache = {};
  final Map<String, String> _jsLibCache = {};
  String? _cachedSourceJson;
  String? _cachedSourceKey;
  final Set<String> _cachedKeys = {};

  bool get isAvailable => _initialized;

  // ===== 初始化 =====

  /// Web 平台初始化：标记为已初始化但不创建引擎
  Future<bool> init() async {
    debugPrint('JsEngine Web stub: init（不支持 JS 执行）');
    _initialized = true;
    return true;
  }

  // ===== 基础执行（全部返回空值）=====

  dynamic evaluate(String script) {
    debugPrint('JsEngine Web stub: evaluate 不支持');
    return null;
  }

  Future<String?> batchEvaluate(String script) async {
    debugPrint('JsEngine Web stub: batchEvaluate 不支持');
    return null;
  }

  dynamic executeSync(
    String jsCode,
    dynamic content, {
    String? baseUrl,
    JsEngineType? sourceEngine,
    Map<String, dynamic>? variables,
    String? ruleStep,
  }) {
    debugPrint('JsEngine Web stub: executeSync 不支持');
    return null;
  }

  Future<String?> processJsRule(
    String content,
    String jsCode, {
    String? baseUrl,
    JsEngineType? sourceEngine,
    Map<String, dynamic>? env,
    dynamic dynamicContent,
  }) async {
    debugPrint('JsEngine Web stub: processJsRule 不支持');
    return null;
  }

  Future<String?> processJsWithBook(
    String jsCode, {
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
    Map<String, dynamic>? source,
    String? content,
    int? index,
    JsEngineType? sourceEngine,
  }) async {
    debugPrint('JsEngine Web stub: processJsWithBook 不支持');
    return null;
  }

  Future<String?> evaluateBookRule(
    String ruleCode, {
    dynamic result,
    Map<String, dynamic>? env,
    JsEngineType? sourceEngine,
  }) async {
    debugPrint('JsEngine Web stub: evaluateBookRule 不支持');
    return null;
  }

  // ===== jsLib 管理 =====

  void loadJsLib(String sourceUrl, String jsLib) {
    _jsLibCache[sourceUrl] = jsLib;
  }

  String? getJsLib(String sourceUrl) => _jsLibCache[sourceUrl];

  void clearJsLib(String sourceUrl) {
    _jsLibCache.remove(sourceUrl);
  }

  // ===== 缓存管理 =====

  void clearJavaCache() {
    _cachedKeys.clear();
    _bridgeCache.clear();
  }

  String bridgeGet(String key) => _bridgeCache[key] ?? '';

  void bridgePut(String key, String value) {
    _bridgeCache[key] = value;
  }

  void bridgeDelete(String key) {
    _bridgeCache.remove(key);
  }

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

  String urlEncodeNative(String input, String charset) {
    return Uri.encodeComponent(input);
  }

  String urlDecodeNative(String input) {
    return Uri.decodeComponent(input);
  }

  String htmlQueryExtractNative(String html, String selector, String attr, bool listMode) {
    return listMode ? '[]' : '';
  }

  String unescapeHtmlNative(String input) {
    return input;
  }

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

  void dispose() {
    _bridgeCache.clear();
    _jsLibCache.clear();
    _cachedKeys.clear();
    _cachedSourceJson = null;
    _cachedSourceKey = null;
    _initialized = false;
  }
}
