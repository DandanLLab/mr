/// EPUB 出版商样式内联器
///
/// 移植自 JRead/Legado 的 EpubPublisherStyles.kt
///
/// 把章节 HTML 中 <link rel="stylesheet"> 引用的 CSS 内联到 <style> 标签：
/// 1. 递归展开 @import（防环、防炸）
/// 2. 重写 url() 为 https://epub.local/{path} 虚拟 host
/// 3. 翻译多看扩展（duokan-text-indent → text-indent, duokan-bleed → margin）
///
/// 解决 WebView 在链接 CSS 就绪前就完成加载的时序问题。
library;

import 'epub_package_parser.dart';
import 'epub_path.dart';

/// EPUB 出版商样式内联器
class EpubPublisherStyles {
  EpubPublisherStyles._();

  static const int _maxImportDepth = 6;
  static const int _maxStyleSheets = 32;
  static const int _maxSingleCssBytes = 2 * 1024 * 1024; // 2 MiB
  static const int _maxTotalCssBytes = 8 * 1024 * 1024; // 8 MiB

  /// <link> 标签正则
  static final RegExp _linkRegex = RegExp(
    r'<link\b[^>]*>',
    caseSensitive: false,
    dotAll: true,
  );

  /// @import 正则（支持 url("...") / "..." / '...' 三种语法）
  static final RegExp _importRegex = RegExp(
    r'''@import\s+(?:url\(\s*(?:"([^"]+)"|'([^']+)'|([^)\s]+))\s*\)|"([^"]+)"|'([^']+)')[^;]*;''',
    caseSensitive: false,
    dotAll: true,
  );

  /// url() 正则
  static final RegExp _urlRegex = RegExp(
    r'''url\(\s*(["']?)(.*?)\1\s*\)''',
    caseSensitive: false,
    dotAll: true,
  );

  /// duokan-text-indent 正则
  static final RegExp _duokanTextIndentRegex = RegExp(
    r'\bduokan-text-indent\s*:\s*([^;}{]+)\s*;',
    caseSensitive: false,
  );

  /// duokan-bleed 正则
  static final RegExp _duokanBleedRegex = RegExp(
    r'\bduokan-bleed\s*:\s*([a-z]+)\s*;',
    caseSensitive: false,
  );

  /// 内联出版商 CSS
  ///
  /// [archive] EPUB 归档读取器
  /// [chapterHref] 当前章节的 EPUB 内部路径
  /// [html] 章节原始 HTML
  /// 返回内联了 CSS 的 HTML
  static String inline(
    EpubArchiveReader archive,
    String chapterHref,
    String html,
  ) {
    if (html.trim().isEmpty) return html;

    var totalBytes = 0;
    var sheetCount = 0;
    final visited = <String>{};

    return html.replaceAllMapped(_linkRegex, (match) {
      final tag = match.group(0)!;
      if (!_isStylesheetLink(tag)) return tag;

      final href = (_attribute(tag, 'href') ?? '').trim();
      if (href.isEmpty || _isExternalOrData(href)) return tag;

      final cssHref =
          EpubPath.stripFragment(EpubPath.resolve(chapterHref, href));

      final css = _loadCss(
        archive: archive,
        cssHref: cssHref,
        depth: 0,
        visited: visited,
        consume: (bytes) {
          if (sheetCount >= _maxStyleSheets ||
              totalBytes + bytes > _maxTotalCssBytes) {
            return false;
          }
          sheetCount++;
          totalBytes += bytes;
          return true;
        },
      );

      if (css == null) return tag;

      // 转义内部 </style 防止提前闭合
      final escaped = css.replaceAll(
        RegExp(r'</style', caseSensitive: false),
        '<\\/style',
      );
      return '<style data-epub-publisher-css="${_escapeAttribute(cssHref)}">\n'
          '$escaped\n</style>';
    });
  }

  /// 递归加载 CSS（展开 @import）
  static String? _loadCss({
    required EpubArchiveReader archive,
    required String cssHref,
    required int depth,
    required Set<String> visited,
    required bool Function(int bytes) consume,
  }) {
    final normalized = EpubPath.normalize(cssHref);
    if (normalized.isEmpty ||
        depth > _maxImportDepth ||
        visited.contains(normalized)) {
      return null;
    }
    visited.add(normalized);
    if (!archive.exists(normalized)) return null;

    final bytes = archive.readBytes(normalized);
    if (bytes.length > _maxSingleCssBytes) return null;
    if (!consume(bytes.length)) return null;

    var css = String.fromCharCodes(bytes);

    // 递归展开 @import
    css = css.replaceAllMapped(_importRegex, (match) {
      // 取第一个非空的捕获组（url("...") / "..." / '...' 三种语法）
      final importHref = match.groups([1, 2, 3, 4, 5])
          .firstWhere((g) => g != null && g.isNotEmpty, orElse: () => null)
          ?.trim()
          .trim();
      if (importHref == null || importHref.isEmpty || _isExternalOrData(importHref)) {
        return match.group(0)!;
      }
      final resolved = EpubPath.stripFragment(
        EpubPath.resolve(normalized, importHref),
      );
      final imported = _loadCss(
        archive: archive,
        cssHref: resolved,
        depth: depth + 1,
        visited: visited,
        consume: consume,
      );
      if (imported == null) return '';
      return '/* EPUB @import $resolved */\n$imported';
    });

    return _rewriteDuokanExtensions(_rewriteResourceUrls(normalized, css));
  }

  /// 重写 url() 为 https://epub.local/{path}
  static String _rewriteResourceUrls(String cssHref, String css) {
    return css.replaceAllMapped(_urlRegex, (match) {
      final raw = (match.group(2) ?? '').trim();
      if (raw.isEmpty || raw.startsWith('#') || _isExternalOrData(raw)) {
        return match.group(0)!;
      }
      final resolved = EpubPath.resolve(cssHref, raw);
      final path = EpubPath.stripFragment(resolved);
      final frag = EpubPath.fragment(resolved);
      final absolute = StringBuffer('https://epub.local/')
        ..write(_encodeArchivePath(path));
      if (frag != null && frag.isNotEmpty) {
        absolute.write('#');
        absolute.write(_encodeFragment(frag));
      }
      return 'url("$absolute")';
    });
  }

  /// 翻译多看扩展
  static String _rewriteDuokanExtensions(String css) {
    // duokan-text-indent:X → text-indent:X
    var result = css.replaceAllMapped(_duokanTextIndentRegex, (match) {
      return 'text-indent:${match.group(1)};';
    });

    // duokan-bleed:{left|right|top|bottom} → margin + width
    result = result.replaceAllMapped(_duokanBleedRegex, (match) {
      final value = (match.group(1) ?? '').toLowerCase();
      final buf = StringBuffer('--moting-duokan-bleed:$value;');
      if (value.contains('left')) {
        buf.write('margin-left:calc(-1 * var(--moting-reader-padding-left, 0px));');
      }
      if (value.contains('right')) {
        buf.write('margin-right:calc(-1 * var(--moting-reader-padding-right, 0px));');
      }
      if (value.contains('top')) {
        buf.write('margin-top:calc(-1 * var(--moting-reader-padding-top, 0px));');
      }
      if (value.contains('bottom')) {
        buf.write('margin-bottom:calc(-1 * var(--moting-reader-padding-bottom, 0px));');
      }
      if (value.contains('left') || value.contains('right')) {
        buf.write('width:calc(100% + var(--moting-reader-padding-left, 0px) + '
            'var(--moting-reader-padding-right, 0px));');
      }
      return buf.toString();
    });

    return result;
  }

  /// 判断 <link> 是否为 stylesheet
  static bool _isStylesheetLink(String tag) {
    final rel = _attribute(tag, 'rel')?.toLowerCase() ?? '';
    return rel.split(RegExp(r'\s+')).any((s) => s == 'stylesheet');
  }

  /// 从 HTML 标签字符串中提取属性值
  static String? _attribute(String tag, String name) {
    final pattern = RegExp(
      r'(?is)\b' + RegExp.escape(name) + r"""\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))""",
    );
    final match = pattern.firstMatch(tag);
    if (match == null) return null;
    return match.groups([1, 2, 3]).firstWhere((g) => g != null && g.isNotEmpty, orElse: () => null);
  }

  /// 判断是否为外部 URL 或 data: URI
  static bool _isExternalOrData(String value) {
    final clean = value.trim().toLowerCase();
    return clean.startsWith('data:') ||
        clean.startsWith('http:') ||
        clean.startsWith('https:') ||
        clean.startsWith('//');
  }

  /// 转义属性值
  static String _escapeAttribute(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  /// 编码归档路径为 URL path
  static String _encodeArchivePath(String value) {
    // 简单编码：空格 → %20，其他保持原样
    // URI 类会处理大部分编码，但这里保持与 Kotlin 版一致
    return value.replaceAll(' ', '%20');
  }

  /// 编码 fragment
  static String _encodeFragment(String value) {
    return value.replaceAll(' ', '%20');
  }
}
