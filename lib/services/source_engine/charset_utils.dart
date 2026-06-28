import 'dart:convert';
import 'dart:typed_data';
import '../native/js_engine.dart';

/// 编码工具函数库
///
/// 提供 HTTP 请求链路的全流程编码支持：
/// - [urlEncode]：按指定字符集对字符串进行 URL 编码（GBK/UTF-8 等）
/// - [decodeResponse]：按指定字符集解码 HTTP 响应字节流
/// - [detectCharsetFromHeaders]：从 Content-Type 头提取 charset
/// - [detectCharsetFromHtml]：从 HTML meta 标签检测 charset
///
/// 编码转换统一走 C 原生层（quickjs charset_conv.c），
/// 通过 JS 引擎桥接调用，Android/iOS/Web 通用。
class CharsetUtils {
  /// URL-encode 字符串，使用指定字符集
  ///
  /// 例如中文 "搜索" 用 GBK 编码会被转为 %CB%D1%CB%F7，
  /// 用 UTF-8 编码则转为 %E6%90%9C%E7%B4%A2。
  ///
  /// [str] 待编码字符串
  /// [charset] 字符集名称，如 "GBK", "UTF-8", "GB2312"。为空或 "UTF-8" 时使用 [Uri.encodeComponent]
  /// 返回 percent-encoded 字符串
  static String urlEncode(String str, String charset) {
    if (str.isEmpty) return str;
    final cs = charset.trim().toLowerCase();
    if (cs.isEmpty || cs == 'utf-8' || cs == 'utf8') {
      return Uri.encodeComponent(str);
    }
    // 通过 C 原生层进行 GBK/GB2312/GB18030/Big5 编码
    // JsEngine.urlEncodeNative 调用 quickjs charset_url_encode
    try {
      final result = JsEngine.instance.urlEncodeNative(str, charset.trim());
      if (result.isNotEmpty) return result;
    } catch (_) {}
    // 原生不可用时回退 UTF-8
    return Uri.encodeComponent(str);
  }

  /// 从 HTTP 响应头中检测字符集
  ///
  /// 优先解析 [Content-Type: text/html; charset=GBK] 中的 charset 值。
  /// 支持 key 大小写不敏感。
  static String? detectCharsetFromHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return null;
    // 大小写不敏感查找 content-type
    final contentType = headers.entries
        .firstWhere(
          (e) => e.key.toLowerCase() == 'content-type',
          orElse: () => const MapEntry('', ''),
        )
        .value;
    if (contentType.isEmpty) return null;
    final charsetMatch = RegExp(
      r"""charset\s*=\s*([^;\s"']+)""",
      caseSensitive: false,
    ).firstMatch(contentType);
    if (charsetMatch == null) return null;
    return charsetMatch.group(1);
  }

  /// 从 HTML 文档中检测字符集
  ///
  /// 按优先级检测：
  /// 1. `<meta charset="xxx">`（HTML5 写法）
  /// 2. `<meta http-equiv="Content-Type" content="...charset=xxx">`
  ///
  /// [html] HTML 文档字符串（可能是已用 UTF-8 解码的，我们只在表面做正则匹配）
  /// 返回检测到的 charset 名称，未检测到时返回 null
  static String? detectCharsetFromHtml(String html) {
    if (html.isEmpty) return null;
    // 1. HTML5: <meta charset="xxx"> / <meta charset=xxx>
    final metaMatch = RegExp(
      r"""<meta[^>]+charset\s*=\s*["']?\s*([^"'\s>/]+)""",
      caseSensitive: false,
    ).firstMatch(html);
    if (metaMatch == null) return null;
    final cs = metaMatch.group(1)!.trim();
    if (cs.isNotEmpty) return cs;
    // 2. HTML4/XHTML: <meta http-equiv="Content-Type" content="text/html; charset=xxx">
    final httpEquivMatch = RegExp(
      r"""<meta[^>]+http-equiv\s*=\s*["']?\s*Content-Type\s*["']?[^>]+"""
      r"""content\s*=\s*["'][^"']*charset\s*=\s*([^"'\s>]+)""",
      caseSensitive: false,
    ).firstMatch(html);
    if (httpEquivMatch == null) return null;
    return httpEquivMatch.group(1);
  }

  /// 将字节数组按指定字符集解码为字符串
  ///
  /// Dart 原生支持的编码：utf-8, latin-1, ascii
  /// 其他编码（GBK/GB2312/GB18030/Big5/Shift_JIS 等）统一回退到 latin-1 解码 + UTF-8 容错
  /// （latin-1 保证不丢字节，每个字节映射到 U+0000~U+00FF）
  ///
  /// 真正的非 UTF-8 解码建议走原生通道（Android OkHttp 自动处理）。
  static String decodeResponse(Uint8List bytes, String? charset) {
    final cs = charset?.trim().toLowerCase() ?? '';
    try {
      if (cs.isEmpty || cs == 'utf-8' || cs == 'utf8') {
        return utf8.decode(bytes, allowMalformed: true);
      }
      if (cs == 'latin-1' || cs == 'latin1' || cs == 'iso-8859-1') {
        return latin1.decode(bytes);
      }
      if (cs == 'ascii') {
        return ascii.decode(bytes);
      }
      // 不支持的编码（gbk/gb2312/big5 等）：用 latin-1 兜底保证不丢数据
      // 调用方应在收到响应后，用 detectCharsetFromHtml 二次检测并重新解码
      return latin1.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 从 URL 路径/扩展名推断编码（扩展用，暂不实现）
  /// 预留用于 "根据 URL 模板信息注册对应编码"
  static String? detectCharsetFromUrl(String url) {
    // TODO: 某些书源在 URL 中包含编码信息
    return null;
  }
}