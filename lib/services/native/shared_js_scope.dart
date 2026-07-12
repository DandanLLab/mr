import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:io';
import '../app_logger.dart';
import 'quickjs_runtime.dart' show nativeHttpGet;

/// 共享 JS 作用域管理器
/// 借鉴 legado 的 SharedJsScope 设计，为每个书源创建隔离的 JS scope
/// 支持 jsLib 预加载、LRU 缓存、磁盘缓存
class SharedJsScope {
  SharedJsScope._();
  static final SharedJsScope instance = SharedJsScope._();

  /// LRU 缓存：jsLib MD5 → 预加载的变量Map
  final Map<String, Map<String, String>> _scopeCache = {};

  /// 磁盘缓存目录
  static const int _maxCacheSize = 16;

  /// 获取书源的共享作用域变量
  /// 返回 jsLib 预加载后定义的全局变量Map
  Map<String, String>? getScope(String? jsLib) {
    if (jsLib == null || jsLib.trim().isEmpty) return null;

    final key = _md5(jsLib);

    // 检查 LRU 缓存
    if (_scopeCache.containsKey(key)) {
      // 移到末尾（LRU）
      final cached = _scopeCache.remove(key)!;
      _scopeCache[key] = cached;
      return cached;
    }

    return null;
  }

  /// 创建并缓存书源的共享作用域
  /// [jsLib] 可以是纯JS代码字符串，也可以是 JSON Map（如 {"name": "url_or_code"}）
  /// [evaluateJs] 用于执行JS代码的回调函数
  Future<Map<String, String>> createScope(
    String jsLib,
    Future<String?> Function(String code) evaluateJs,
  ) async {
    if (jsLib.trim().isEmpty) return {};

    final key = _md5(jsLib);

    // 检查缓存
    final cached = getScope(jsLib);
    if (cached != null) return cached;

    // 限制缓存大小
    if (_scopeCache.length >= _maxCacheSize) {
      _scopeCache.remove(_scopeCache.keys.first);
    }

    final scopeVars = <String, String>{};

    try {
      // 判断 jsLib 格式：JSON Map 还是纯 JS 代码
      if (jsLib.trim().startsWith('{')) {
        // JSON Map 格式：{"name": "url_or_code", ...}
        try {
          final jsMap = jsonDecode(jsLib) as Map<String, dynamic>;
          for (final entry in jsMap.entries) {
            final value = entry.value.toString();
            if (_isAbsUrl(value)) {
              // URL 类型：先查磁盘缓存，没有则下载
              final jsCode = await _loadJsFromUrl(value);
              if (jsCode != null) {
                final result = await evaluateJs(jsCode);
                if (result != null) {
                  scopeVars[entry.key] = result;
                }
              }
            } else {
              // 纯 JS 代码
              final result = await evaluateJs(value);
              if (result != null) {
                scopeVars[entry.key] = result;
              }
            }
          }
        } catch (e) {
          // JSON 解析失败，当作纯 JS 代码
          final result = await evaluateJs(jsLib);
          if (result != null) {
            scopeVars['_jsLib'] = result;
          }
        }
      } else {
        // 纯 JS 代码字符串
        final result = await evaluateJs(jsLib);
        if (result != null) {
          scopeVars['_jsLib'] = result;
        }
      }
    } catch (e) {
      AppLogger.instance.logJsError('SharedJsScope', '创建scope失败: $e');
    }

    _scopeCache[key] = scopeVars;
    return scopeVars;
  }

  /// 移除指定 jsLib 的缓存
  void remove(String? jsLib) {
    if (jsLib == null) return;
    _scopeCache.remove(_md5(jsLib));
  }

  /// 清除所有缓存
  void clear() {
    _scopeCache.clear();
  }

  /// 从 URL 加载 JS 代码（带磁盘缓存）
  Future<String?> _loadJsFromUrl(String url) async {
    try {
      final cacheKey = _md5(url);

      // 先查磁盘缓存
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/js_lib_cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }

      final cacheFile = File('${cacheDir.path}/$cacheKey.js');
      if (await cacheFile.exists()) {
        return await cacheFile.readAsString();
      }

      // 下载 JS 文件
      String? jsCode;
      if (!kIsWeb && url.startsWith('http://')) {
        final r = nativeHttpGet(url, timeoutMs: 15000);
        jsCode = r?['body'] as String?;
      }

      if (jsCode == null) {
        AppLogger.instance.logJsError('SharedJsScope', '下载jsLib失败: $url');
        return null;
      }

      // 写入磁盘缓存
      await cacheFile.writeAsString(jsCode);
      return jsCode;
    } catch (e) {
      AppLogger.instance.logJsError('SharedJsScope', '加载jsLib URL失败: $e');
      return null;
    }
  }

  /// 判断是否为绝对 URL
  bool _isAbsUrl(String str) {
    return str.startsWith('http://') || str.startsWith('https://');
  }

  /// MD5 哈希
  String _md5(String input) {
    return md5.convert(utf8.encode(input)).toString();
  }
}
