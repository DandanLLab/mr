/// EPUB 内部路径工具
///
/// 移植自 JRead/Legado 的 EpubPath.kt
///
/// 核心能力：
/// 1. normalize：规范化路径（反斜杠→正斜杠、去 fragment、NFC 规范化、处理 ./.. ）
/// 2. resolve：相对路径解析（基于 basePath 的目录拼接）
/// 3. fragment / stripFragment：fragment 处理
/// 4. decodePercentEscapes：UTF-8 percent-escape 解码（不用 Uri.decodeComponent，避免 + 被转空格）
class EpubPath {
  EpubPath._();

  /// 规范化路径
  ///
  /// 1. 反斜杠 → 正斜杠
  /// 2. 去 fragment（#xxx）
  /// 3. NFC 规范化（统一 Unicode 表示）
  /// 4. 处理 . 和 ..
  static String normalize(String path) {
    // Dart 没有 Normalizer.Form.NFC，但 String 已经是 UTF-16，
    // EPUB 路径基本都是 ASCII，NFC 规范化对 ASCII 无影响
    final raw = path.replaceAll('\\', '/').split('#').first;
    final parts = <String>[];
    for (final part in raw.split('/')) {
      if (part.isEmpty || part == '.') {
        continue;
      } else if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  /// 解析相对路径
  ///
  /// [basePath] 当前文件路径，[href] 要解析的链接
  /// 返回相对于 EPUB 根的绝对路径（带 fragment）
  ///
  /// 例：resolve("OEBPS/Styles/main.css", "../Fonts/base.css")
  ///   → "OEBPS/Fonts/base.css"
  static String resolve(String basePath, String href) {
    final frag = fragment(href);
    final cleanHref = href.split('#').first.split('?').first;
    if (cleanHref.trim().isEmpty) {
      return withFragment(normalize(basePath), frag);
    }
    final decodedHref = decodePercentEscapes(cleanHref);
    final baseDir = normalize(basePath).split('/').toList();
    if (baseDir.isNotEmpty) baseDir.removeLast();
    final baseDirStr = baseDir.join('/');
    String combined;
    if (decodedHref.startsWith('/')) {
      combined = decodedHref;
    } else if (baseDirStr.isEmpty) {
      combined = decodedHref;
    } else {
      combined = '$baseDirStr/$decodedHref';
    }
    return withFragment(normalize(combined), frag);
  }

  /// 提取 fragment（#后的部分）
  static String? fragment(String? href) {
    if (href == null || href.trim().isEmpty) return null;
    final index = href.indexOf('#');
    if (index >= 0 && index + 1 < href.length) {
      return href.substring(index + 1);
    }
    return null;
  }

  /// 移除 fragment
  static String stripFragment(String path) => path.split('#').first;

  /// 拼接路径和 fragment
  static String withFragment(String path, String? frag) {
    if (frag == null || frag.trim().isEmpty) return path;
    return '$path#$frag';
  }

  /// 解码 UTF-8 percent-escape 序列
  ///
  /// 故意不用 Uri.decodeComponent，因为它会把 + 转成空格，
  /// 而 EPUB href 中的 + 是字面量（如文件名含 +）。
  /// 非法的 escape 序列保留原样。
  static String decodePercentEscapes(String value) {
    if (!value.contains('%')) return value;
    final result = StringBuffer(value.length);
    var index = 0;
    while (index < value.length) {
      if (value[index] != '%' || index + 2 >= value.length) {
        result.write(value[index]);
        index++;
        continue;
      }
      // 收集连续的 %XX 序列
      final bytes = <int>[];
      var cursor = index;
      while (cursor + 2 < value.length &&
          value[cursor] == '%' &&
          _hexDigit(value[cursor + 1]) != null &&
          _hexDigit(value[cursor + 2]) != null) {
        final high = _hexDigit(value[cursor + 1])!;
        final low = _hexDigit(value[cursor + 2])!;
        bytes.add((high << 4) | low);
        cursor += 3;
      }
      if (cursor == index) {
        result.write(value[index]);
        index++;
      } else {
        result.write(String.fromCharCodes(bytes)); // UTF-8 字节 → String
        index = cursor;
      }
    }
    return result.toString();
  }

  /// 十六进制字符 → 数值（失败返回 null）
  static int? _hexDigit(String ch) {
    final code = ch.codeUnitAt(0);
    if (code >= 48 && code <= 57) return code - 48; // 0-9
    if (code >= 65 && code <= 70) return code - 55; // A-F
    if (code >= 97 && code <= 102) return code - 87; // a-f
    return null;
  }
}
