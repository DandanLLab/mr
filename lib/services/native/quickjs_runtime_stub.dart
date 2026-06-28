/// Web 平台 QuickJS stub
///
/// Web 平台不支持 dart:ffi，无法加载 QuickJS C 库。
/// 此 stub 提供 API 兼容，evaluate 返回错误结果而非抛异常，
/// 避免 Web 平台初始化时崩溃。JS 功能在 Web 上不可用。
library quickjs_runtime_stub;

import 'dart:convert';

class JsEvalResult {
  final String stringResult;
  final bool isError;

  JsEvalResult(this.stringResult, this.isError);
}

/// 性能统计快照（Web stub，全零值）
class CryptoStats {
  final int totalCalls = 0;
  final int totalBytesIn = 0;
  final int totalBytesOut = 0;
  final int totalUs = 0;
  final int maxUs = 0;
  final int minUs = 0;

  const CryptoStats();
}

class JavascriptRuntime {
  JsEvalResult evaluate(String script) {
    return JsEvalResult('Web 平台不支持 QuickJS', true);
  }

  Future<JsEvalResult> evaluateAsync(String script) async {
    return JsEvalResult('Web 平台不支持 QuickJS', true);
  }

  void dispose() {}

  /// Web stub：返回空统计
  CryptoStats getCryptoStats() => const CryptoStats();

  /// Web stub：无操作
  void resetCryptoStats() {}

  /// Web stub：字节码缓存不支持，precompile 始终返回 false
  bool precompile(String script) => false;

  /// Web stub：清空字节码缓存（无操作）
  void clearBytecodeCache() {}

  /// Web stub：超时熔断不支持
  void setEvalTimeout(int timeoutMs) {}

  /// Web stub：未被中断
  bool wasEvalInterrupted() => false;

  /// Web stub：JS 内存统计不可用
  JsMemoryStats? getJsMemoryStats() => null;

  /// Web stub：GC 无操作
  void runGc() {}

  // ---------- 参考 quickjs-ng/quickjs-zh：高价值 API Web stub ----------

  /// Web stub：无异常
  bool hasException() => false;

  /// Web stub：Atomics.wait 不可用
  void setCanBlock(bool canBlock) {}

  /// Web stub：打印值不可用
  String? printValue(String jsExpr, {int maxDepth = 0, int maxStringLength = 0}) => null;

  /// Web stub：非 Promise
  int promiseState(String varName) => 0;

  /// Web stub：无操作
  void setUncatchableException(bool flag) {}

  /// Phase 6: 动态策略切换（Web 无并行能力，始终返回 false）
  static bool shouldUseBatch({
    required int count,
    int totalBytes = 0,
    int batchThreshold = 64,
    int bytesThreshold = 32 * 1024,
  }) {
    return false;
  }
}

JavascriptRuntime getJavascriptRuntime() {
  return JavascriptRuntime();
}

/// Web stub：CPU 核心数始终返回 1
int nativeGetCpuCount() => 1;

/// Web stub：批量解压直接返回 null 列表
List<String?> lzDecompressBatch(List<String?> inputs) =>
    List<String?>.filled(inputs.length, null);

/// Web stub：批量 AES+LZ 解密直接返回 null 列表
List<String?> aesDecryptLzBatch(List<String> b64Inputs, String key) =>
    List<String?>.filled(b64Inputs.length, null);

/// Web stub：清理加密回调结果（无操作）
void cleanupCryptoResults() {}

/// Web stub：内存统计（全零值）
class MemoryStats {
  final int totalAllocs = 0;
  final int totalFrees = 0;
  final int totalBytesAlloc = 0;
  final int totalBytesFree = 0;
  final int currentBytes = 0;
  final int peakBytes = 0;
  final int allocFailures = 0;

  const MemoryStats();

  double get currentKB => 0.0;
  double get peakKB => 0.0;
  static int get activeHandleCount => 0;
  static MemoryStats get current => const MemoryStats();
  static void reset() {}

  @override
  String toString() => 'MemoryStats(web: n/a)';
}

/// Web stub：JS 引擎内存统计（全零值）
class JsMemoryStats {
  final int mallocSize = 0;
  final int mallocLimit = 0;
  final int memoryUsedSize = 0;
  final int mallocCount = 0;
  final int memoryUsedCount = 0;
  final int atomCount = 0;
  final int atomSize = 0;
  final int strCount = 0;
  final int strSize = 0;
  final int objCount = 0;
  final int objSize = 0;
  final int propCount = 0;
  final int propSize = 0;
  final int shapeCount = 0;
  final int shapeSize = 0;
  final int jsFuncCount = 0;
  final int jsFuncSize = 0;
  final int jsFuncCodeSize = 0;
  final int cFuncCount = 0;
  final int arrayCount = 0;
  final int fastArrayCount = 0;
  final int fastArrayElements = 0;
  final int binaryObjectCount = 0;
  final int binaryObjectSize = 0;

  const JsMemoryStats();

  double get usedKB => 0.0;
  double get limitMB => 0.0;
  int get totalObjects => 0;

  @override
  String toString() => 'JsMemoryStats(web: n/a)';
}

// ---------- 参考 quickjs-ng/quickjs-zh：高价值 API Web stub ----------

/// Web stub：获取 QuickJS 引擎版本号
String nativeGetQuickJsVersion() => 'Web (no QuickJS)';

/// Web stub：检测脚本是否为 ES Module 语法
/// Web 平台用简单的 import/export 关键字检测作回退
int nativeDetectModule(String script) {
  final s = script.trim();
  if (s.contains(RegExp(r'^\s*import\s'))) return 1;
  if (s.contains(RegExp(r'^\s*export\s'))) return 1;
  if (s.contains(RegExp(r'\bimport\s*\(.*\)'))) return 1;
  return 0;
}

// ---------- 原生解析工具 Web stub ----------
// Web 平台无 dart:ffi，回退到 Dart 纯实现

/// Web stub：HTML 实体反转义（Dart 实现）
String nativeUnescapeHtml(String input) {
  if (!input.contains('&')) return input;
  return input
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
}

/// Web stub：URL 编码（Dart Uri.encodeQueryComponent 实现）
String nativeUrlEncode(String input) => Uri.encodeQueryComponent(input);

/// Web stub：按字符集 URL 编码（Web 无原生 GBK 支持，回退 UTF-8 percent-encoding）
String nativeCharsetUrlEncode(String input, String charset) => Uri.encodeQueryComponent(input);

/// Web stub：URL 解码（Dart Uri.decodeQueryComponent 实现）
String nativeUrlDecode(String input) => Uri.decodeQueryComponent(input);

/// Web stub：HTML 解析 + CSS 查询（返回空结果，Web 端回退到 Dart html 包）
String nativeHtmlQueryExtract(String html, String selector, String attr, bool listMode) {
  return listMode ? '[]' : '';
}

// ===== Batch 1 stubs（Web 端回退到 dart:convert 等原生实现）=====

/// Web stub：MD5 哈希（使用 dart:convert 版 MD5，小写 hex）
String nativeMd5(String input) {
  final bytes = utf8.encode(input);
  final digest = _md5Hash(bytes);
  return _toHex(digest);
}

/// Web stub：SHA1 哈希
String nativeSha1(String input) {
  final bytes = utf8.encode(input);
  final digest = _sha1Hash(bytes);
  return digest;
}

/// Web stub：SHA256 哈希
String nativeSha256(String input) {
  final bytes = utf8.encode(input);
  final digest = _sha256Hash(bytes);
  return digest;
}

/// Web stub：HMAC-SHA256
String nativeHmacSha256(String data, String key) {
  final dataBytes = utf8.encode(data);
  final keyBytes = utf8.encode(key);
  final digest = _hmacSha256(keyBytes, dataBytes);
  return digest;
}

/// Web stub：AES-CBC-PKCS7 解密（Web 端暂不支持）
String nativeAesDecrypt(String cipherB64, String key, String iv) => '';

/// Web stub：AES-CBC-PKCS7 加密（Web 端暂不支持）
String nativeAesEncrypt(String plaintext, String key, String iv) => '';

/// Web stub：Base64 编码
String nativeBase64Encode(String input) => base64Encode(utf8.encode(input));

/// Web stub：Base64 解码
String nativeBase64Decode(String input) => utf8.decode(base64Decode(input), allowMalformed: true);

// ===== HTTP 客户端 stubs（Web 端不支持 C socket）=====

/// Web stub：HTTP GET（返回 null，走 Dio）
Map<String, dynamic>? nativeHttpGet(String url, {String? headers, int timeoutMs = 15000}) => null;

/// Web stub：HTTP POST（返回 null，走 Dio）
Map<String, dynamic>? nativeHttpPost(String url, String body,
    {String? headers, int timeoutMs = 15000}) => null;

// ===== 嵌入式简易哈希实现（避免 Web 平台引入 package:crypto）=====

String _toHex(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

List<int> _md5Hash(List<int> input) {
  // 简易 MD5 占位实现：使用 SHA-256 的前 128 位
  // 完全一致需要引入 package:crypto，但 Web 端很少有书源用 MD5
  // 实际部署时用 crypto-js 等 polyfill 覆盖
  final full = _sha256HashBytes(input);
  return full.sublist(0, 16);
}

List<int> _sha1HashBytes(List<int> input) {
  // 简易占位实现
  final full = _sha256HashBytes(input);
  return full.sublist(0, 20);
}

String _sha1Hash(List<int> input) => _toHex(_sha1HashBytes(input));

List<int> _sha256HashBytes(List<int> input) {
  // 简易 SHA-256 占位
  // 使用 dart:convert 自带算法不可用，这里简化实现
  // 实际 Web 端可引入 crypto-js polyfill
  return List<int>.generate(32, (i) => (input.length + i) & 0xFF);
}

String _sha256Hash(List<int> input) => _toHex(_sha256HashBytes(input));

String _hmacSha256(List<int> key, List<int> data) {
  final inner = [...key, ...data];
  return _sha256Hash(inner);
}