/// EPUB 目录解析器
///
/// 移植自 JRead/Legado 的 EpubTocParser.kt
///
/// 三级回退：
/// 1. EPUB3 nav（XHTML <nav epub:type="toc">）
/// 2. EPUB2 NCX（navMap/navPoint）
/// 3. spine 占位章节
library;

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:xml/xml.dart' as xml;

import 'epub_package.dart';
import 'epub_package_parser.dart';
import 'epub_path.dart';

/// 目录条目
class TocItem {
  final String title;
  final String href;
  final String? fragment;
  final List<TocItem> children;

  const TocItem({
    required this.title,
    required this.href,
    this.fragment,
    this.children = const [],
  });
}

/// EPUB 目录解析器
class EpubTocParser {
  /// 解析目录
  ///
  /// 三级回退：EPUB3 nav → EPUB2 NCX → spine 占位
  static List<TocItem> parse(EpubArchiveReader archive, EpubPackage pkg) {
    // 1. EPUB3 nav
    if (pkg.navHref != null) {
      final items = _parseNav(archive, pkg.navHref!);
      if (items.isNotEmpty) return items;
    }
    // 2. EPUB2 NCX
    if (pkg.ncxHref != null) {
      final items = _parseNcx(archive, pkg.ncxHref!);
      if (items.isNotEmpty) return items;
    }
    // 3. spine 占位
    return pkg.spine
        .map((item) => TocItem(title: 'Chapter ${item.index + 1}', href: item.href))
        .toList();
  }

  /// 解析 EPUB3 nav XHTML
  static List<TocItem> _parseNav(EpubArchiveReader archive, String navHref) {
    final html = archive.readText(navHref);
    final doc = html_parser.parse(html);

    // 找 nav[epub:type~="toc"]，否则取第一个 nav
    html_dom.Element? nav;
    for (final n in doc.querySelectorAll('nav')) {
      final type = n.attributes['epub:type'] ?? n.attributes['type'] ?? '';
      if (type == 'toc' || type.split(RegExp(r'\s+')).contains('toc')) {
        nav = n;
        break;
      }
    }
    nav ??= doc.querySelector('nav');
    if (nav == null) return [];

    // 取 nav 下第一个 ol
    html_dom.Element? rootOl;
    for (final child in nav.children) {
      if (child.localName == 'ol') {
        rootOl = child;
        break;
      }
    }
    if (rootOl == null) return [];

    return _parseHtmlNavList(navHref, rootOl);
  }

  /// 递归解析 HTML nav 的 ol 列表
  static List<TocItem> _parseHtmlNavList(
    String baseHref,
    html_dom.Element ol,
  ) {
    final items = <TocItem>[];
    for (final li in ol.children) {
      if (li.localName != 'li') continue;

      // 找第一个 a 或 span
      html_dom.Element? anchor;
      for (final child in li.children) {
        if (child.localName == 'a' || child.localName == 'span') {
          anchor = child;
          break;
        }
      }
      if (anchor == null) continue;

      final title = anchor.text.trim();
      if (title.isEmpty) continue;

      final hrefRaw = anchor.attributes['href'] ?? '';
      // 占位符判定：href 为空 / 仅 "#" / 仅 "#fragment"（纯 fragment 无路径）
      // 这些都是卷标题占位符，不应 resolve 成 nav 文件本身路径
      // 对齐 lumina：span 无 href 或 href="#" 作为卷头标记，href 留空
      final isPlaceholder = hrefRaw.trim().isEmpty ||
          hrefRaw.trim() == '#' ||
          hrefRaw.trim().startsWith('#');
      final href = isPlaceholder ? '' : EpubPath.resolve(baseHref, hrefRaw);

      // 递归处理嵌套 ol
      List<TocItem> children = [];
      for (final child in li.children) {
        if (child.localName == 'ol') {
          children = _parseHtmlNavList(baseHref, child);
          break;
        }
      }

      items.add(TocItem(
        title: title,
        href: href,
        fragment: EpubPath.fragment(hrefRaw),
        children: children,
      ));
    }
    return items;
  }

  /// 解析 EPUB2 NCX
  static List<TocItem> _parseNcx(EpubArchiveReader archive, String ncxHref) {
    final xmlStr = archive.readText(ncxHref);
    final doc = xml.XmlDocument.parse(xmlStr);

    // 找 navMap
    xml.XmlElement? navMap;
    for (final el in doc.descendants) {
      if (el is xml.XmlElement && el.localName == 'navMap') {
        navMap = el;
        break;
      }
    }
    if (navMap == null) return [];

    final items = <TocItem>[];
    for (final navPoint in navPointChildren(navMap)) {
      final item = _parseNavPoint(ncxHref, navPoint);
      if (item != null) items.add(item);
    }
    return items;
  }

  /// 递归解析 NCX navPoint
  static TocItem? _parseNavPoint(
    String baseHref,
    xml.XmlElement navPoint,
  ) {
    // 找 <text> 子元素
    String? title;
    for (final el in navPoint.children) {
      if (el is xml.XmlElement && el.localName == 'text') {
        final text = el.innerText.trim();
        if (text.isNotEmpty) {
          title = text;
          break;
        }
      }
    }
    if (title == null) return null;

    // 找 <content src="...">
    String src = '';
    for (final el in navPoint.children) {
      if (el is xml.XmlElement && el.localName == 'content') {
        src = el.getAttribute('src') ?? '';
        break;
      }
    }
    // 占位符判定：src 为空 / 仅 "#" / 仅 "#fragment"（纯 fragment 无路径）
    // 对齐 lumina：NCX 中无 content src 或 src="#" 作为卷头标记，href 留空
    final isPlaceholder = src.trim().isEmpty ||
        src.trim() == '#' ||
        src.trim().startsWith('#');

    // 递归子 navPoint
    final children = <TocItem>[];
    for (final child in navPointChildren(navPoint)) {
      final item = _parseNavPoint(baseHref, child);
      if (item != null) children.add(item);
    }

    return TocItem(
      title: title,
      href: isPlaceholder ? '' : EpubPath.resolve(baseHref, src),
      fragment: isPlaceholder ? null : EpubPath.fragment(src),
      children: children,
    );
  }

  /// 获取元素的 navPoint 子元素（忽略命名空间）
  static List<xml.XmlElement> navPointChildren(xml.XmlElement parent) {
    return parent.children
        .whereType<xml.XmlElement>()
        .where((el) => el.localName == 'navPoint')
        .toList();
  }
}
