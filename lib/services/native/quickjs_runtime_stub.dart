/// Web 平台 QuickJS stub
///
/// Web 平台不支持 dart:ffi，无法加载 QuickJS C 库。
/// 此 stub 提供 API 兼容，evaluate 返回错误结果而非抛异常，
/// 避免 Web 平台初始化时崩溃。JS 功能在 Web 上不可用。
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

/// Web stub：URL 解码（Dart Uri.decodeQueryComponent 实现）
String nativeUrlDecode(String input) => Uri.decodeQueryComponent(input);

/// Web stub：HTML 解析 + CSS 查询（返回空结果，Web 端回退到 Dart html 包）
String nativeHtmlQueryExtract(String html, String selector, String attr, bool listMode) {
  return listMode ? '[]' : '';
}
