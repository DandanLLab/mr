/// EPUB @font-face 数据模型 + 解析器 + 字体目录
///
/// 移植自 JRead/Legado 的 EpubFontFace.kt + EpubFontFaceParser.kt + EpubFontCatalog.kt
///
/// 1. EpubFontFace / EpubFontSource / EpubFontStyle：数据模型
/// 2. EpubFontFaceParser：从 CSS 解析 @font-face 和 @import
/// 3. EpubFontCatalog：聚合整本书所有 @font-face（manifest CSS + 章节 link/style）
library;

import 'package:html/parser.dart' as html_parser;

import 'epub_package.dart';
import 'epub_package_parser.dart';
import 'epub_path.dart';

// ============ 数据模型 ============

/// @font-face 解析结果
class EpubFontFace {
  final String family;
  final List<EpubFontSource> sources;
  final int weightMin;
  final int weightMax;
  final EpubFontStyle style;

  const EpubFontFace({
    required this.family,
    required this.sources,
    this.weightMin = 400,
    this.weightMax = 400,
    this.style = EpubFontStyle.normal,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpubFontFace &&
          family == other.family &&
          _listEquals(sources, other.sources) &&
          weightMin == other.weightMin &&
          weightMax == other.weightMax &&
          style == other.style;

  @override
  int get hashCode => Object.hash(family, sources, weightMin, weightMax, style);

  static bool _listEquals(List<EpubFontSource> a, List<EpubFontSource> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 字体文件来源
class EpubFontSource {
  final String href;
  final String? format;

  const EpubFontSource({required this.href, this.format});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpubFontSource && href == other.href && format == other.format;

  @override
  int get hashCode => Object.hash(href, format);
}

/// 字体样式
enum EpubFontStyle { normal, italic, oblique }

// ============ @font-face 解析器 ============

/// 从 CSS 文本中解析 @font-face 和 @import
class EpubFontFaceParser {
  EpubFontFaceParser._();

  static final RegExp _cssCommentRegex = RegExp(r'/\*[\s\S]*?\*/');

  /// 解析 @font-face 块
  static List<EpubFontFace> parse(String cssHref, String css) {
    if (css.trim().isEmpty) return [];
    final cleanCss = css.replaceAll(_cssCommentRegex, '');
    final faces = <EpubFontFace>[];
    var index = 0;
    while (index < cleanCss.length) {
      final at = cleanCss.toLowerCase().indexOf('@font-face', index);
      if (at < 0) break;
      final blockStart = cleanCss.indexOf('{', at + '@font-face'.length);
      if (blockStart < 0) break;
      final blockEnd = _findMatchingBrace(cleanCss, blockStart);
      if (blockEnd < 0) break;
      final block = cleanCss.substring(blockStart + 1, blockEnd);
      final face = _parseBlock(cssHref, block);
      if (face != null) faces.add(face);
      index = blockEnd + 1;
    }
    return faces;
  }

  /// 解析 @import 列表（返回 EPUB 内部路径）
  static List<String> parseImports(String cssHref, String css) {
    if (css.trim().isEmpty) return [];
    final cleanCss = css.replaceAll(_cssCommentRegex, '');
    final imports = <String>[];
    var index = 0;
    while (index < cleanCss.length) {
      final at = cleanCss.toLowerCase().indexOf('@import', index);
      if (at < 0) break;
      final statementStart = at + '@import'.length;
      final statementEnd = _findStatementEnd(cleanCss, statementStart);
      final statement = cleanCss.substring(statementStart, statementEnd);
      final href = _extractImportUrl(statement);
      if (href != null &&
          !href.toLowerCase().startsWith('data:') &&
          !href.toLowerCase().startsWith('http://') &&
          !href.toLowerCase().startsWith('https://')) {
        imports.add(EpubPath.resolve(cssHref, href));
      }
      index = statementEnd < cleanCss.length ? statementEnd + 1 : cleanCss.length;
    }
    return imports;
  }

  static EpubFontFace? _parseBlock(String cssHref, String block) {
    final declarations = _parseDeclarations(block);
    final family = _cleanFontFamily(declarations['font-family']);
    if (family == null) return null;
    final sources = _parseSources(cssHref, declarations['src'] ?? '');
    if (sources.isEmpty) return null;
    return EpubFontFace(
      family: family,
      sources: sources,
      weightMin: _toWeightMin(declarations['font-weight']),
      weightMax: _toWeightMax(declarations['font-weight']),
      style: _toFontStyle(declarations['font-style']),
    );
  }

  /// 解析声明块为 { property: value } 映射
  static Map<String, String> _parseDeclarations(String block) {
    final result = <String, String>{};
    for (final decl in block.split(';')) {
      final colon = decl.indexOf(':');
      if (colon < 0) continue;
      final name = decl.substring(0, colon).trim().toLowerCase();
      final value = decl.substring(colon + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) {
        result[name] = value;
      }
    }
    return result;
  }

  static List<EpubFontSource> _parseSources(String cssHref, String srcValue) {
    return _splitCommaList(srcValue).map((source) {
      final href = _extractUrl(source);
      if (href == null) return null;
      final lower = href.toLowerCase();
      if (lower.startsWith('data:') ||
          lower.startsWith('http://') ||
          lower.startsWith('https://')) {
        return null;
      }
      return EpubFontSource(
        href: EpubPath.stripFragment(EpubPath.resolve(cssHref, href)),
        format: _extractFormat(source),
      );
    }).whereType<EpubFontSource>().toList();
  }

  static String? _extractUrl(String source) {
    final start = source.toLowerCase().indexOf('url(');
    if (start < 0) return null;
    String? quote;
    for (var i = start + 4; i < source.length; i++) {
      final ch = source[i];
      if (quote != null) {
        if (ch == quote && source[i - 1] != '\\') quote = null;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == ')') {
        final raw = source.substring(start + 4, i).trim();
        final unquoted = raw.replaceAll(RegExp(r"""^[\'"]|[\'"]$"""), '');
        if (unquoted.isEmpty || unquoted.toLowerCase() == 'none') return null;
        return unquoted;
      }
    }
    return null;
  }

  static String? _extractFormat(String source) {
    final start = source.toLowerCase().indexOf('format(');
    if (start < 0) return null;
    final end = source.indexOf(')', start + 7);
    if (end < 0) return null;
    final raw = source.substring(start + 7, end).trim();
    final unquoted = raw.replaceAll(RegExp(r"""^[\'"]|[\'"]$"""), '').toLowerCase();
    return unquoted.isNotEmpty ? unquoted : null;
  }

  static String? _extractImportUrl(String statement) {
    final url = _extractUrl(statement);
    if (url != null) return url;
    final clean = statement.trimLeft();
    if (clean.isEmpty) return null;
    final first = clean[0];
    if (first != "'" && first != '"') return null;
    for (var i = 1; i < clean.length; i++) {
      if (clean[i] == first && clean[i - 1] != '\\') {
        final raw = clean.substring(1, i).trim();
        if (raw.isEmpty || raw.toLowerCase() == 'none') return null;
        return raw;
      }
    }
    return null;
  }

  static int _toWeightMin(String? value) {
    final (min, _) = _toWeightRange(value);
    return min;
  }

  static int _toWeightMax(String? value) {
    final (_, max) = _toWeightRange(value);
    return max;
  }

  static (int, int) _toWeightRange(String? value) {
    final clean = value?.trim().toLowerCase();
    if (clean == null || clean.isEmpty) return (400, 400);
    if (clean == 'normal') return (400, 400);
    if (clean == 'bold') return (700, 700);
    final parts = _splitValueList(clean)
        .map((s) => int.tryParse(s))
        .where((n) => n != null && n >= 1 && n <= 1000)
        .cast<int>()
        .toList();
    if (parts.isEmpty) return (400, 400);
    if (parts.length == 1) return (parts[0], parts[0]);
    return (parts.reduce((a, b) => a < b ? a : b), parts.reduce((a, b) => a > b ? a : b));
  }

  static EpubFontStyle _toFontStyle(String? value) {
    final clean = value?.trim().toLowerCase() ?? '';
    if (clean.startsWith('italic')) return EpubFontStyle.italic;
    if (clean.startsWith('oblique')) return EpubFontStyle.oblique;
    return EpubFontStyle.normal;
  }

  static String? _cleanFontFamily(String? value) {
    if (value == null) return null;
    final parts = _splitCommaList(value);
    if (parts.isEmpty) return null;
    final first = parts.first.trim().replaceAll(RegExp(r"""^[\'"]|[\'"]$"""), '');
    return first.isNotEmpty ? first : null;
  }

  static int _findMatchingBrace(String text, int start) {
    var depth = 0;
    String? quote;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (quote != null) {
        if (ch == quote && text[i - 1] != '\\') quote = null;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static int _findStatementEnd(String text, int start) {
    String? quote;
    var parenDepth = 0;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (quote != null) {
        if (ch == quote && text[i - 1] != '\\') quote = null;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == '(') {
        parenDepth++;
      } else if (ch == ')') {
        if (parenDepth > 0) parenDepth--;
      } else if (ch == ';' && parenDepth == 0) {
        return i;
      }
    }
    return text.length;
  }

  static List<String> _splitCommaList(String value) {
    final result = <String>[];
    String? quote;
    var parenDepth = 0;
    var start = 0;
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (quote != null) {
        if (ch == quote && value[i - 1] != '\\') quote = null;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
      } else if (ch == '(') {
        parenDepth++;
      } else if (ch == ')') {
        if (parenDepth > 0) parenDepth--;
      } else if (ch == ',' && parenDepth == 0) {
        final part = value.substring(start, i).trim();
        if (part.isNotEmpty) result.add(part);
        start = i + 1;
      }
    }
    final last = value.substring(start).trim();
    if (last.isNotEmpty) result.add(last);
    return result;
  }

  static List<String> _splitValueList(String value) {
    // 按空白拆分（简化版，不考虑引号因为 font-weight 不会有引号）
    return value.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }
}

// ============ 字体目录聚合器 ============

/// 聚合整本书所有 @font-face
class EpubFontCatalog {
  EpubFontCatalog._();

  /// 从 EpubPackage 聚合所有 @font-face
  ///
  /// 双源聚合：
  /// 1. manifest 中所有 CSS item
  /// 2. 每个 spine item 的章节 HTML 中的 link/style
  /// 递归处理 @import
  static List<EpubFontFace> fromPackage(
    EpubArchiveReader archive,
    EpubPackage pkg,
  ) {
    final visitedCss = <String>{};
    final faces = <EpubFontFace>[];

    // 1. manifest 中的 CSS
    for (final item in pkg.manifest.values) {
      if (item.isCssItem) {
        faces.addAll(_collectLinkedCss(archive, item.href, visitedCss));
      }
    }

    // 2. 每个章节的 link/style
    for (final spineItem in pkg.spine) {
      faces.addAll(_collectChapterFaces(archive, spineItem.href, visitedCss));
    }

    // 去重
    return faces.toSet().toList();
  }

  static List<EpubFontFace> _collectChapterFaces(
    EpubArchiveReader archive,
    String chapterHref,
    Set<String> visitedCss,
  ) {
    final href = _toArchivePath(chapterHref);
    if (href.isEmpty) return [];

    String html;
    try {
      html = archive.readText(href);
    } catch (_) {
      return [];
    }
    if (html.trim().isEmpty) return [];

    final doc = html_parser.parse(html);
    final faces = <EpubFontFace>[];

    // link[href]
    for (final link in doc.querySelectorAll('link[href]')) {
      if (!_isStylesheetLink(link)) continue;
      final cssHref = link.attributes['href']?.trim() ?? '';
      if (cssHref.isEmpty) continue;
      faces.addAll(_collectLinkedCss(
        archive,
        EpubPath.resolve(href, cssHref),
        visitedCss,
      ));
    }

    // <style>
    for (final style in doc.querySelectorAll('style')) {
      final css = style.text.trim();
      if (css.isEmpty) continue;
      faces.addAll(_collectCss(archive, href, css, visitedCss));
    }

    return faces;
  }

  static List<EpubFontFace> _collectLinkedCss(
    EpubArchiveReader archive,
    String cssHref,
    Set<String> visitedCss,
  ) {
    final href = _toArchivePath(cssHref);
    if (href.isEmpty || visitedCss.contains(href)) return [];
    visitedCss.add(href);

    String css;
    try {
      css = archive.readText(href);
    } catch (_) {
      return [];
    }
    return _collectCss(archive, href, css, visitedCss);
  }

  static List<EpubFontFace> _collectCss(
    EpubArchiveReader archive,
    String cssHref,
    String css,
    Set<String> visitedCss,
  ) {
    if (css.trim().isEmpty) return [];
    final href = _toArchivePath(cssHref);
    final faces = <EpubFontFace>[];
    faces.addAll(EpubFontFaceParser.parse(href, css));
    for (final importHref in EpubFontFaceParser.parseImports(href, css)) {
      faces.addAll(_collectLinkedCss(archive, importHref, visitedCss));
    }
    return faces;
  }

  static bool _isStylesheetLink(dynamic el) {
    final rel = (el.attributes['rel'] ?? '').trim().toLowerCase();
    return rel.split(RegExp(r'\s+')).any((s) => s == 'stylesheet');
  }

  static String _toArchivePath(String href) {
    final qIndex = href.indexOf('?');
    final hIndex = href.indexOf('#');
    var end = href.length;
    if (qIndex >= 0 && qIndex < end) end = qIndex;
    if (hIndex >= 0 && hIndex < end) end = hIndex;
    return EpubPath.normalize(href.substring(0, end));
  }
}
