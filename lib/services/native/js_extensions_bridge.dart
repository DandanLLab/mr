import 'package:flutter/foundation.dart';
import '../app_logger.dart';
import 'platform_channel.dart';
import 'quickjs_runtime.dart' show
  nativeMd5,
  nativeAesDecrypt, nativeAesEncrypt,
  nativeBase64Encode, nativeBase64Decode,
  nativeHtmlQueryExtract,
  nativeHttpGet, nativeHttpPost;

/// JsExtensions 桥接层
/// 借鉴 legado 的 JsExtensions 接口设计
/// 将 JS 中的 java.* 调用桥接到 Dart 侧的 C 原生 FFI（优先）或 NativeChannel
///
/// 双轨并行策略：
/// - 加密/哈希/编码/HTML 解析 → C FFI（同步，零 MethodChannel 开销）
/// - HTTP 请求/存储/系统调用 → NativeChannel（MethodChannel）
class JsExtensionsBridge {
  JsExtensionsBridge._();
  static final JsExtensionsBridge instance = JsExtensionsBridge._();

  // ===== HTTP 请求 =====

  /// 异步 HTTP GET，返回响应体字符串
  /// 对应 legado 的 java.ajax(url)
  Future<String?> ajax(String url, {Map<String, String>? headers, int? timeoutMs}) async {
    try {
      if (kIsWeb) return null;
      if (!url.startsWith('http://')) return null;
      final hdr = headers?.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
      final r = nativeHttpGet(url, headers: hdr, timeoutMs: timeoutMs ?? 10000);
      return r?['body'] as String?;
    } catch (e) {
      AppLogger.instance.logJsError('JsExtensions', 'ajax失败: $e');
      return null;
    }
  }

  /// 并发 HTTP 请求
  /// 对应 legado 的 java.ajaxAll(urlList)
  Future<List<String?>> ajaxAll(List<String> urls, {Map<String, String>? headers}) async {
    final results = <String?>[];
    // 并发执行
    final futures = urls.map((url) => ajax(url, headers: headers));
    results.addAll(await Future.wait(futures));
    return results;
  }

  /// HTTP GET 请求（Jsoup 方式，支持重定向拦截）
  /// 对应 legado 的 java.get(url, headers)
  Future<String?> get(String url, {Map<String, String>? headers, int? timeoutMs}) async {
    return ajax(url, headers: headers, timeoutMs: timeoutMs);
  }

  /// HTTP POST 请求
  /// 对应 legado 的 java.post(url, body, headers)
  Future<String?> post(String url, {String? body, Map<String, String>? headers, int? timeoutMs}) async {
    try {
      if (kIsWeb) return null;
      if (!url.startsWith('http://')) return null;
      final hdr = headers?.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
      final r = nativeHttpPost(url, body ?? '', headers: hdr, timeoutMs: timeoutMs ?? 10000);
      return r?['body'] as String?;
    } catch (e) {
      AppLogger.instance.logJsError('JsExtensions', 'post失败: $e');
      return null;
    }
  }

  // ===== 加解密 =====

  /// AES 加密
  /// 对应 legado 的 java.aesEncode(data, key, iv)
  /// 同步调用 C 原生 FFI，零 MethodChannel 开销
  Future<String?> aesEncode(String data, String key, {String? iv}) async {
    try {
      if (kIsWeb) return null;
      // C 原生 AES-CBC-PKCS7 加密，同步返回 base64
      return nativeAesEncrypt(data, key, iv ?? '');
    } catch (e) {
      AppLogger.instance.logJsError('JsExtensions', 'aesEncode失败: $e');
      return null;
    }
  }

  /// AES 解密
  /// 对应 legado 的 java.aesDecode(data, key, iv)
  /// 同步调用 C 原生 FFI，零 MethodChannel 开销
  Future<String?> aesDecode(String data, String key, {String? iv}) async {
    try {
      if (kIsWeb) return null;
      // C 原生 AES-CBC-PKCS7 解密，同步返回明文
      return nativeAesDecrypt(data, key, iv ?? '');
    } catch (e) {
      AppLogger.instance.logJsError('JsExtensions', 'aesDecode失败: $e');
      return null;
    }
  }

  /// MD5 哈希
  /// 对应 legado 的 java.md5Encode(str)
  /// 同步调用 C 原生 FFI，零 MethodChannel 开销
  Future<String?> md5Encode(String str) async {
    try {
      if (kIsWeb) return null;
      return nativeMd5(str);
    } catch (e) {
      return null;
    }
  }

  /// Base64 编码
  /// 同步调用 C 原生 FFI，零 MethodChannel 开销
  Future<String?> base64Encode(String str) async {
    try {
      if (kIsWeb) return null;
      return nativeBase64Encode(str);
    } catch (e) {
      return null;
    }
  }

  /// Base64 解码
  /// 同步调用 C 原生 FFI，零 MethodChannel 开销
  Future<String?> base64Decode(String str) async {
    try {
      if (kIsWeb) return null;
      return nativeBase64Decode(str);
    } catch (e) {
      return null;
    }
  }

  // ===== Jsoup HTML 解析（切到 C 原生 HTML 引擎）=====

  /// CSS 选择器选择第一个元素
  /// 切到 C 原生 HTML 引擎（同步 FFI，零 MethodChannel 开销）
  Future<String?> jsoupSelectFirst(String html, String selector) async {
    try {
      if (kIsWeb) return null;
      // 原子调用：HTML 解析 + CSS 查询 + 文本提取
      return nativeHtmlQueryExtract(html, selector, '@text', false);
    } catch (e) {
      return null;
    }
  }

  /// CSS 选择器选择所有元素
  /// 切到 C 原生 HTML 引擎（同步 FFI，零 MethodChannel 开销）
  Future<List<String>?> jsoupSelectAll(String html, String selector) async {
    try {
      if (kIsWeb) return null;
      final json = nativeHtmlQueryExtract(html, selector, '@text', true);
      if (json.isEmpty || json == '[]') return [];
      // 简易 JSON 解析（只支持纯文本数组）
      return json
          .replaceAll('[', '')
          .replaceAll(']', '')
          .split(',')
          .map((s) => s.trim().replaceAll('"', ''))
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (e) {
      return null;
    }
  }

  /// 获取元素属性
  /// 切到 C 原生 HTML 引擎（同步 FFI，零 MethodChannel 开销）
  Future<String?> jsoupGetAttr(String html, String selector, String attr) async {
    try {
      if (kIsWeb) return null;
      return nativeHtmlQueryExtract(html, selector, attr, false);
    } catch (e) {
      return null;
    }
  }

  /// 清理 HTML
  /// 切到 C 原生 HTML 引擎（同步 FFI，零 MethodChannel 开销）
  Future<String?> jsoupClean(String html) async {
    try {
      if (kIsWeb) return null;
      // C 原生：提取 body 内部文本（移除 script/style 标签）
      return nativeHtmlQueryExtract(html, 'body', '@html', false);
    } catch (e) {
      return null;
    }
  }

  // ===== 数据持久化 =====

  /// 存储键值对
  Future<bool> putData(String key, String value) async {
    try {
      if (kIsWeb) return false;
      return await NativeChannel.instance.putData(key, value);
    } catch (e) {
      return false;
    }
  }

  /// 读取键值对
  Future<String?> getData(String key, {String defaultValue = ''}) async {
    try {
      if (kIsWeb) return defaultValue;
      return await NativeChannel.instance.getData(key, defaultValue: defaultValue);
    } catch (e) {
      return defaultValue;
    }
  }

  /// 删除键值对
  Future<bool> deleteData(String key) async {
    try {
      if (kIsWeb) return false;
      return await NativeChannel.instance.deleteData(key);
    } catch (e) {
      return false;
    }
  }

  // ===== 工具方法 =====

  /// 时间格式化
  String timeFormat(int timestamp, {String format = 'yyyy-MM-dd HH:mm:ss'}) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return date.toIso8601String();
  }

  /// 获取当前时间戳
  int getTime() {
    return DateTime.now().millisecondsSinceEpoch;
  }

  /// URI 编码
  String encodeURI(String str) {
    return Uri.encodeFull(str);
  }

  /// Hex 编码
  String hexEncode(String str) {
    return str.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Hex 解码
  String hexDecode(String hex) {
    final result = StringBuffer();
    for (var i = 0; i < hex.length; i += 2) {
      final code = int.parse(hex.substring(i, i + 2), radix: 16);
      result.writeCharCode(code);
    }
    return result.toString();
  }

  // ===== 安全沙箱 =====

  /// 检查 URL 是否安全（防止 SSRF 攻击）
  bool isUrlSafe(String url) {
    final blocked = ['127.0.0.1', 'localhost', '0.0.0.0', '::1', '169.254.'];
    for (final pattern in blocked) {
      if (url.contains(pattern)) return false;
    }
    return true;
  }

  /// 检查文件路径是否安全（防止路径遍历攻击）
  bool isPathSafe(String path) {
    return !path.contains('..') && !path.startsWith('/');
  }
}
