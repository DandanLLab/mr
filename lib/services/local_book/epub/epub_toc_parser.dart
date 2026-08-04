/// EPUB 目录解析器
///
/// 对齐 lumina 项目的目录解析逻辑（epub_zip_parser.dart）：
/// - 三级回退：EPUB3 nav → EPUB2 NCX → spine 占位
/// - NCX 父子去重：parent href == first child href → parent 置空成 placeholder
///   （lumina _parseNavPoints line 580-583）
/// - NAV span placeholder：<li> 下是 <span> 而非 <a> → href 为 null → placeholder
///   （lumina _parseNavListItems line 670-672）
/// - 路径规范化：所有 href 统一用 EpubPath.normalize 去 `.`/`..`/首尾斜杠
///   保证 spine href 与 toc href 能精确匹配
library;

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:xml/xml.dart' as xml;

import 'epub_package.dart';
import 'epub_package_parser.dart';
import 'epub_path.dart';

/// 目录条目
///
/// 对齐 lumina TocItem：
/// - [href] 为空字符串表示 placeholder（卷标题/分隔符，无独立资源）
/// - [fragment] 为 null 表示无 anchor（指向文件顶部）
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
  /// 对齐 lumina _parseOpf line 229-281 的回退顺序
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
    // 3. spine 占位（对齐 lumina _parseSpineAsChapters）
    return pkg.spine
        .where((item) => item.linear)
        .map((item) => TocItem(
              title: 'Chapter ${item.index + 1}',
              href: item.href,
              fragment: null,
            ))
        .toList();
  }

  /// 解析 EPUB3 nav XHTML
  ///
  /// 对齐 lumina _parseNav：
  /// - 找 nav[epub:type~="toc"]，否则取第一个 nav
  /// - 三段式 namespace fallback：OPS namespace → epub:type 前缀 → 裸 type
  /// - 取 nav 下第一个 ol 递归解析
  static List<TocItem> _parseNav(EpubArchiveReader archive, String navHref) {
    final html = archive.readText(navHref);
    final doc = html_parser.parse(html);

    // 找 nav[epub:type~="toc"]，否则取第一个 nav
    // 对齐 lumina _containsWholeWord：用 \b 边界匹配，大小写不敏感
    html_dom.Element? nav;
    for (final n in doc.querySelectorAll('nav')) {
      final type = n.attributes['epub:type'] ??
          n.attributes['type'] ??
          '';
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
  ///
  /// 对齐 lumina _parseNavListItems：
  /// - <a> → 真实 href，解析相对路径
  /// - <span> → href 为空字符串（placeholder，卷标题/分隔符）
  /// - href="#" 特殊处理：指向 navPath 本身 + anchor='top'
  /// - 递归处理嵌套 ol
  static List<TocItem> _parseHtmlNavList(
    String baseHref,
    html_dom.Element ol,
  ) {
    final items = <TocItem>[];
    for (final li in ol.children) {
      if (li.localName != 'li') continue;

      // 找第一个 a 或 span（对齐 lumina anchorOrSpan 逻辑）
      html_dom.Element? anchorOrSpan;
      for (final child in li.children) {
        if (child.localName == 'a' || child.localName == 'span') {
          anchorOrSpan = child;
          break;
        }
      }
      if (anchorOrSpan == null) continue;

      final title = anchorOrSpan.text.trim();
      if (title.isEmpty) continue;

      // 对齐 lumina：只有 <a> 才有 href，<span> → href=null → placeholder
      final isAnchor = anchorOrSpan.localName == 'a';
      final hrefRaw = isAnchor ? (anchorOrSpan.attributes['href'] ?? '') : '';

      String href;
      String? fragment;
      if (!isAnchor || hrefRaw.trim().isEmpty) {
        // placeholder：span 或空 href → 空字符串（lumina 用 Href()..path=''..anchor='top'）
        href = '';
        fragment = null;
      } else if (hrefRaw.trim() == '#') {
        // 对齐 lumina：href="#" 指向 navPath 本身
        href = EpubPath.normalize(baseHref);
        fragment = null;
      } else {
        // 正常 href：解析相对路径 + 规范化
        final resolved = EpubPath.resolve(baseHref, hrefRaw);
        href = EpubPath.stripFragment(resolved);
        fragment = EpubPath.fragment(hrefRaw);
      }

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
        fragment: fragment,
        children: children,
      ));
    }
    return items;
  }

  /// 解析 EPUB2 NCX
  ///
  /// 对齐 lumina _parseNcx + _parseNavPoints
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
  ///
  /// 对齐 lumina _parseNavPoints：
  /// - <navLabel>/<text> → title
  /// - <content src="..."> → href，经 EpubPath.resolve 解析为绝对路径
  /// - 递归子 navPoint
  /// - **父子去重**：children.first.href == href → href 置空成 placeholder
  ///   （lumina line 580-583，处理「卷标题与第一章同文件」的情况）
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

    // 解析 href（对齐 lumina _resolveRelativePath + _resolveHref）
    String href;
    String? fragment;
    if (src.trim().isEmpty) {
      href = '';
      fragment = null;
    } else {
      final resolved = EpubPath.resolve(baseHref, src);
      href = EpubPath.stripFragment(resolved);
      fragment = EpubPath.fragment(src);
    }

    // 递归子 navPoint
    final children = <TocItem>[];
    for (final child in navPointChildren(navPoint)) {
      final item = _parseNavPoint(baseHref, child);
      if (item != null) children.add(item);
    }

    // 对齐 lumina 父子去重（line 580-583）：
    // 父节点 href == 第一个子节点 href → 父节点 href 置空成 placeholder
    // 场景：NCX 中「卷一」navPoint 的 content src 指向卷内第一章，
    //       卷一本身没有独立内容，应标记为卷标题（无独立资源）
    if (children.isNotEmpty && children.first.href == href && href.isNotEmpty) {
      href = '';
      fragment = null;
    }

    return TocItem(
      title: title,
      href: href,
      fragment: fragment,
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
