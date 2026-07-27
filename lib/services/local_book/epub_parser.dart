import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

/// EPUB 图片资源（被 LocalBookService 用来把 EPUB 内部图片转 data URI）
class EpubResource {
  final String path;
  final String mediaType;
  final Uint8List bytes;

  const EpubResource({
    required this.path,
    required this.mediaType,
    required this.bytes,
  });
}

class EpubChapter {
  /// 扁平列表中的序号（DFS 遍历顺序，用于阅读器按 index 切换章节）
  final int index;
  final String title;

  /// 章节文件路径（已解析为 EPUB ZIP 内绝对路径，不含锚点）
  /// 例如 "OEBPS/Text/chapter1.xhtml"
  final String? href;

  /// 章节原始 HTML 内容（从 EPUB ZIP 中读取）
  String? content;

  /// 章节起始锚点（NCX/NAV 中 href 的 # 后部分）
  /// 与 [anchor] 同义，保留是为了向后兼容
  final String? startFragmentId;

  /// 章节结束锚点（下一个章节的 startFragmentId）
  String? endFragmentId;

  /// 下一章节的 href（用于阅读器翻页预加载）
  String? nextUrl;

  /// 是否为卷头（顶层且有子节点，用于目录折叠展示）
  final bool isVolume;

  // ===== 树状目录支持字段 =====
  // 参考 lumina TocItem 设计，支持多级嵌套目录
  // 现有 UI 仍用扁平 chapters + isVolume 展示，这些字段为未来树状 UI 铺路

  /// 章节内锚点（从 href 中分离的 # 后部分）
  /// 例如 href="chap1.xhtml#section2" → anchor="section2"
  /// 等同于 startFragmentId，但语义更清晰
  final String? anchor;

  /// 对应 OPF spine 的顺序索引（-1 表示无对应，例如纯分组节点）
  /// 用于精确计算阅读进度（按 spine 项数计算总进度）
  final int spineIndex;

  /// 嵌套层级（0=顶层，1=第一层子节点，2=第二层...）
  /// 用于树状目录缩进展示
  final int depth;

  /// 父节点 index（-1=顶层，否则为父节点在扁平列表中的 index）
  final int parentId;

  /// 子节点列表（树状目录结构）
  /// 扁平 chapters 中此字段为空，仅 tocTree 中的节点有 children
  final List<EpubChapter> children;

  EpubChapter({
    required this.index,
    required this.title,
    this.href,
    this.content,
    this.startFragmentId,
    this.endFragmentId,
    this.nextUrl,
    this.isVolume = false,
    this.anchor,
    this.spineIndex = -1,
    this.depth = 0,
    this.parentId = -1,
    this.children = const [],
  });

  /// 把树状目录扁平化为列表（DFS 遍历顺序）
  ///
  /// 用于把 tocTree 转换为 chapters（阅读器按 index 切换）。
  /// 扁平化过程中同步填充每个节点的 [index]（DFS 序号）和 [parentId]
  /// （父节点在扁平列表中的 index，顶层为 -1）。
  ///
  /// 注意：返回的是新构造的节点列表（原 tree 中节点保持不变），
  /// 但 children 引用仍指向原 tocTree 的子节点，方便需要树状遍历的场景。
  /// UI 展示扁平列表时通常用 parentId 重建树。
  static List<EpubChapter> flatten(List<EpubChapter> tree) {
    final result = <EpubChapter>[];

    void walk(EpubChapter node, int parentId) {
      final index = result.length;
      // 重建节点填充 index 和 parentId（其他字段保留原值）
      final newNode = EpubChapter(
        index: index,
        title: node.title,
        href: node.href,
        content: node.content,
        startFragmentId: node.startFragmentId,
        endFragmentId: node.endFragmentId,
        nextUrl: node.nextUrl,
        isVolume: node.isVolume,
        anchor: node.anchor,
        spineIndex: node.spineIndex,
        depth: node.depth,
        parentId: parentId,
        children: node.children,
      );
      result.add(newNode);
      for (final child in node.children) {
        walk(child, index);
      }
    }

    for (final item in tree) {
      walk(item, -1);
    }
    return result;
  }
}

class EpubBook {
  final String title;
  final String? author;
  final String? description;
  final String? coverPath;

  /// 扁平章节列表（DFS 遍历顺序，阅读器按 index 切换章节用）
  final List<EpubChapter> chapters;

  /// 树状目录结构（保留原始嵌套层级，目录页展示用）
  /// chapters 是此树扁平化后的结果
  final List<EpubChapter> tocTree;

  /// OPF spine 项总数（用于 spine 精确进度计算）
  /// progress = 当前 chapter.spineIndex / (spineCount - 1)
  final int spineCount;

  final String? language;

  const EpubBook({
    required this.title,
    this.author,
    this.description,
    this.coverPath,
    this.chapters = const [],
    this.tocTree = const [],
    this.spineCount = 0,
    this.language,
  });
}

class ManifestItem {
  final String id;
  final String href;
  final String mediaType;
  final String? properties;

  const ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    this.properties,
  });
}

class EpubParser {
  /// 从原始字节解析EPUB文件，提取所有元数据和章节内容
  static EpubBook parseFromBytes(Uint8List bytes) {
    try {
      // 1. 解码ZIP
      final archive = ZipDecoder().decodeBytes(bytes);

      // 构建文件映射：归一化路径 -> 内容字节
      final files = <String, List<int>>{};
      for (final file in archive) {
        if (file.isFile) {
          final normalizedName = file.name.replaceAll('\\', '/');
          final data = file.content;
          if (data is List<int>) {
            files[normalizedName] = data;
          }
        }
      }

      // 2. 读取 container.xml 找到 OPF 路径
      final containerData = files['META-INF/container.xml'];
      if (containerData == null) {
        return const EpubBook(title: '未知书名');
      }

      final containerDoc =
          html_parser.parse(decodeBytes(containerData));
      String? opfPath;
      final rootfileElements = containerDoc.querySelectorAll('rootfile');
      for (final el in rootfileElements) {
        final mediaType = el.attributes['media-type'];
        if (mediaType == null ||
            mediaType == 'application/oebps-package+xml') {
          opfPath = el.attributes['full-path'];
          break;
        }
      }

      if (opfPath == null || opfPath.isEmpty) {
        return const EpubBook(title: '未知书名');
      }

      // 3. 读取 OPF 文件
      final opfData = files[opfPath];
      if (opfData == null) {
        return const EpubBook(title: '未知书名');
      }

      final opfDoc = html_parser.parse(decodeBytes(opfData));

      // OPF 基础目录，用于解析相对路径
      final opfBasePath = opfPath.contains('/')
          ? opfPath.substring(0, opfPath.lastIndexOf('/'))
          : '';

      // 4. 解析 metadata
      final metadataElement = opfDoc.querySelector('metadata');

      String title = '未知书名';
      String? author;
      String? description;
      String? language;
      String? coverId;

      if (metadataElement != null) {
        title = _getDcText(metadataElement, 'title') ?? '未知书名';
        author = _getDcText(metadataElement, 'creator');
        description = _getDcText(metadataElement, 'description');
        language = _getDcText(metadataElement, 'language');

        // 查找 cover meta
        for (final child in metadataElement.children) {
          if (_localName(child) == 'meta' && child.attributes['name'] == 'cover') {
            coverId = child.attributes['content'];
            break;
          }
        }
      }

      // 5. 解析 manifest
      final manifestElement = opfDoc.querySelector('manifest');
      final manifest = <String, ManifestItem>{};

      if (manifestElement != null) {
        for (final child in manifestElement.children) {
          if (_localName(child) == 'item') {
            final id = child.attributes['id'] ?? '';
            final href = child.attributes['href'] ?? '';
            final mediaType = child.attributes['media-type'] ?? '';
            final properties = child.attributes['properties'];
            if (id.isNotEmpty && href.isNotEmpty) {
              manifest[id] = ManifestItem(
                id: id,
                href: href,
                mediaType: mediaType,
                properties: properties,
              );
            }
          }
        }
      }

      // 6. 解析 spine
      final spineElement = opfDoc.querySelector('spine');
      final spine = <String>[];
      String? tocId;

      if (spineElement != null) {
        tocId = spineElement.attributes['toc'];
        for (final child in spineElement.children) {
          if (_localName(child) == 'itemref') {
            final idref = child.attributes['idref'];
            if (idref != null) {
              spine.add(idref);
            }
          }
        }
      }

      // 7. 查找封面路径
      String? coverPath;
      if (coverId != null && manifest.containsKey(coverId)) {
        coverPath = _resolveEpubPath(opfBasePath, manifest[coverId]!.href);
      }
      // 后备：通过 properties 或 id 查找封面
      if (coverPath == null) {
        for (final item in manifest.values) {
          if (item.mediaType.startsWith('image/') &&
              (item.properties?.contains('cover-image') == true ||
                  item.id.toLowerCase().contains('cover'))) {
            coverPath = _resolveEpubPath(opfBasePath, item.href);
            break;
          }
        }
      }

      // 8. 解析目录
      //
      // 整体流程：
      // 1) 构建 spineIndexByHref 映射：EPUB 绝对路径 → spine 顺序索引
      //    用于后续给 EpubChapter.spineIndex 字段填充
      // 2) 优先尝试 NCX（EPUB 2）→ 失败则尝试 NAV（EPUB 3）→ 失败用 spine 兜底
      // 3) NCX/NAV 返回的是树状结构（tocTree），通过 EpubChapter.flatten 扁平化为 chapters
      // 4) spine 兜底直接构造扁平 chapters（无嵌套，tocTree 为空）

      // 8.1 构建 spineIndexByHref 映射
      final spineIndexByHref = <String, int>{};
      for (int i = 0; i < spine.length; i++) {
        final idref = spine[i];
        if (manifest.containsKey(idref)) {
          final item = manifest[idref]!;
          final resolvedHref = _resolveEpubPath(opfBasePath, item.href);
          spineIndexByHref[resolvedHref] = i;
        }
      }

      // 8.2 查找 NCX 目录
      String? ncxHref;
      if (tocId != null && manifest.containsKey(tocId)) {
        final tocItem = manifest[tocId]!;
        if (tocItem.mediaType.contains('ncx') ||
            tocItem.href.endsWith('.ncx')) {
          ncxHref = tocItem.href;
        }
      }
      if (ncxHref == null) {
        for (final item in manifest.values) {
          if (item.mediaType == 'application/x-dtbncx+xml' ||
              item.href.endsWith('.ncx')) {
            ncxHref = item.href;
            break;
          }
        }
      }

      // 8.3 查找 NAV 目录
      String? navHref;
      for (final item in manifest.values) {
        if (item.mediaType == 'application/xhtml+xml' &&
            (item.id.toLowerCase().contains('nav') ||
                item.href.toLowerCase().contains('nav'))) {
          navHref = item.href;
          break;
        }
      }

      // 8.4 优先尝试 NCX → NAV → spine 兜底
      List<EpubChapter> tocTree = [];
      List<EpubChapter> chapters;

      if (ncxHref != null) {
        final ncxPath = _resolveEpubPath(opfBasePath, ncxHref);
        final ncxData = files[ncxPath];
        if (ncxData != null) {
          tocTree = _parseNcxToc(
            decodeBytes(ncxData),
            opfBasePath,
            spineIndexByHref,
          );
        }
      }

      if (tocTree.isEmpty && navHref != null) {
        final navPath = _resolveEpubPath(opfBasePath, navHref);
        final navData = files[navPath];
        if (navData != null) {
          tocTree = _parseNavToc(
            decodeBytes(navData),
            opfBasePath,
            spineIndexByHref,
          );
        }
      }

      if (tocTree.isNotEmpty) {
        // NCX/NAV 解析成功：扁平化得到 chapters
        chapters = EpubChapter.flatten(tocTree);
      } else {
        // 后备：使用 spine 条目直接构造扁平 chapters（无嵌套）
        chapters = [];
        for (final idref in spine) {
          if (manifest.containsKey(idref)) {
            final item = manifest[idref]!;
            // 跳过非内容条目
            if (item.href.toLowerCase().contains('toc') ||
                item.href.toLowerCase().contains('nav')) {
              continue;
            }
            final href = _resolveEpubPath(opfBasePath, item.href);
            final index = chapters.length;
            final spineIdx = spineIndexByHref[href] ?? -1;
            chapters.add(EpubChapter(
              index: index,
              title: index == 0 ? '封面' : '第$index章',
              href: href,
              spineIndex: spineIdx,
            ));
          }
        }
      }

      // 9. 从 ZIP 中读取章节内容
      for (final chapter in chapters) {
        if (chapter.href != null) {
          final contentPath = chapter.href!.split('#').first;
          final contentData = files[contentPath];
          if (contentData != null) {
            chapter.content = decodeBytes(contentData);
          }
        }
      }

      // 10. 设置 endFragmentId 和 nextUrl（基于扁平 chapters 顺序）
      // - endFragmentId：当前章节的结束锚点 = 下一章节的 startFragmentId
      //   （同一 xhtml 文件内多个 anchor 切片时用于界定章节边界）
      // - nextUrl：下一章节的 href（阅读器翻页预加载用）
      for (int i = 0; i < chapters.length - 1; i++) {
        chapters[i].endFragmentId = chapters[i + 1].startFragmentId;
        chapters[i].nextUrl = chapters[i + 1].href;
      }

      return EpubBook(
        title: title,
        author: author,
        description: description,
        coverPath: coverPath,
        chapters: chapters,
        tocTree: tocTree,
        spineCount: spine.length,
        language: language,
      );
    } catch (e) {
      return const EpubBook(title: '未知书名');
    }
  }

  /// 从EPUB文件中获取封面图片字节
  static Uint8List? getCoverImage(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = <String, List<int>>{};
      for (final file in archive) {
        if (file.isFile) {
          final normalizedName = file.name.replaceAll('\\', '/');
          final data = file.content;
          if (data is List<int>) {
            files[normalizedName] = data;
          }
        }
      }

      // 查找 OPF 路径
      final containerData = files['META-INF/container.xml'];
      if (containerData == null) return null;

      final containerDoc =
          html_parser.parse(decodeBytes(containerData));
      String? opfPath;
      final rootfileElements = containerDoc.querySelectorAll('rootfile');
      for (final el in rootfileElements) {
        final mediaType = el.attributes['media-type'];
        if (mediaType == null ||
            mediaType == 'application/oebps-package+xml') {
          opfPath = el.attributes['full-path'];
          break;
        }
      }
      if (opfPath == null) return null;

      final opfData = files[opfPath];
      if (opfData == null) return null;

      final opfDoc = html_parser.parse(decodeBytes(opfData));
      final opfBasePath = opfPath.contains('/')
          ? opfPath.substring(0, opfPath.lastIndexOf('/'))
          : '';

      // 从 metadata 中查找 cover ID
      final metadataElement = opfDoc.querySelector('metadata');
      if (metadataElement == null) return null;

      String? coverId;
      for (final child in metadataElement.children) {
        if (_localName(child) == 'meta' &&
            child.attributes['name'] == 'cover') {
          coverId = child.attributes['content'];
          break;
        }
      }

      // 从 manifest 中查找封面路径
      String? coverHref;
      final manifestElement = opfDoc.querySelector('manifest');
      if (manifestElement != null) {
        // 优先通过 cover ID 查找
        if (coverId != null) {
          for (final child in manifestElement.children) {
            if (_localName(child) == 'item' &&
                child.attributes['id'] == coverId) {
              coverHref = child.attributes['href'];
              break;
            }
          }
        }

        // 后备：通过 properties 或 id 名称查找
        if (coverHref == null) {
          for (final child in manifestElement.children) {
            if (_localName(child) == 'item') {
              final id = child.attributes['id']?.toLowerCase() ?? '';
              final properties = child.attributes['properties'] ?? '';
              final mediaType = child.attributes['media-type'] ?? '';
              if (mediaType.startsWith('image/') &&
                  (id.contains('cover') ||
                      properties.contains('cover-image'))) {
                coverHref = child.attributes['href'];
                break;
              }
            }
          }
        }
      }

      if (coverHref == null) return null;

      final coverPath = _resolveEpubPath(opfBasePath, coverHref);
      final coverData = files[coverPath];
      if (coverData == null) return null;

      return Uint8List.fromList(coverData);
    } catch (e) {
      return null;
    }
  }

  /// 从 metadata 元素中获取 DC 命名空间的文本内容
  static String? _getDcText(html_dom.Element metadata, String tagName) {
    for (final child in metadata.children) {
      final local = _localName(child);
      // 兼容 <dc:title> 和 <title> 两种形式
      if (local == tagName || local == 'dc:$tagName') {
        final text = child.text.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  /// 获取元素的 localName（小写，空安全）
  static String _localName(html_dom.Element element) {
    return (element.localName ?? '').toLowerCase();
  }

  /// 解析 EPUB 内部相对路径
  static String _resolveEpubPath(String basePath, String relativePath) {
    if (relativePath.startsWith('/')) return relativePath.substring(1);
    if (basePath.isEmpty) return relativePath;
    final base = Uri.parse('$basePath/');
    return base.resolve(relativePath).toString();
  }

  /// 解码字节为字符串（优先 UTF-8，后备 Latin-1）
  static String decodeBytes(List<int> data) {
    try {
      return utf8.decode(data);
    } catch (_) {
      return String.fromCharCodes(data);
    }
  }

  /// 解析 NCX 格式目录为树状结构
  ///
  /// NCX 的 navMap > navPoint 是天然树状嵌套结构：
  /// ```
  /// <navMap>
  ///   <navPoint>
  ///     <navLabel><text>卷一</text></navLabel>
  ///     <content src="chapter1.xhtml"/>
  ///     <navPoint>  <!-- 嵌套子节点 -->
  ///       <navLabel><text>第一章</text></navLabel>
  ///       <content src="chapter1.xhtml#section1"/>
  ///     </navPoint>
  ///   </navPoint>
  /// </navMap>
  /// ```
  ///
  /// 返回 [List<EpubChapter>] 树状结构（顶层节点列表）。
  /// - [depth]：嵌套层级，0=顶层
  /// - [anchor]：从 href 中分离的 # 后部分
  /// - [spineIndex]：通过 [spineIndexByHref] 反查 OPF spine 顺序索引
  /// - [index]/[parentId]：保持 -1，由 [EpubChapter.flatten] 填充
  /// - [isVolume]：顶层且有子节点时为 true（卷头标记）
  ///
  /// [spineIndexByHref]：EPUB 绝对路径 → spine 索引的映射，
  /// 由 [parseFromBytes] 通过 OPF spine + manifest 预先构建。
  static List<EpubChapter> _parseNcxToc(
    String ncxXml,
    String opfBasePath,
    Map<String, int> spineIndexByHref,
  ) {
    try {
      final doc = html_parser.parse(ncxXml);
      final navMap = doc.querySelector('navMap');
      if (navMap == null) return [];

      EpubChapter parseNavPoint(html_dom.Element navPoint, int depth) {
        // 查找 navLabel > text
        String? title;
        html_dom.Element? navLabel;
        for (final e in navPoint.children) {
          if (_localName(e) == 'navlabel') {
            navLabel = e;
            break;
          }
        }
        if (navLabel != null) {
          for (final e in navLabel.children) {
            if (_localName(e) == 'text') {
              title = e.text.trim();
              break;
            }
          }
        }

        // 查找 content src
        html_dom.Element? contentEl;
        for (final e in navPoint.children) {
          if (_localName(e) == 'content') {
            contentEl = e;
            break;
          }
        }
        final src = contentEl?.attributes['src'] ?? '';
        final rawHref = src.split('#').first;
        final href = rawHref.isEmpty ? null : _resolveEpubPath(opfBasePath, rawHref);
        final anchor = _extractFragmentId(src);

        // 检查子 navPoint
        final childNavPoints = <html_dom.Element>[];
        for (final e in navPoint.children) {
          if (_localName(e) == 'navpoint') {
            childNavPoints.add(e);
          }
        }

        // 递归构建 children
        final children = childNavPoints
            .map((c) => parseNavPoint(c, depth + 1))
            .toList();

        // spineIndex 反查
        final spineIdx = href != null && href.isNotEmpty
            ? (spineIndexByHref[href] ?? -1)
            : -1;

        return EpubChapter(
          index: -1, // 由 flatten 填充
          title: (title != null && title.isNotEmpty)
              ? title
              : '未命名章节',
          href: href,
          anchor: anchor,
          startFragmentId: anchor,
          isVolume: depth == 0 && children.isNotEmpty,
          spineIndex: spineIdx,
          depth: depth,
          parentId: -1, // 由 flatten 填充
          children: children,
        );
      }

      final tree = <EpubChapter>[];
      for (final navPoint in navMap.children) {
        if (_localName(navPoint) == 'navpoint') {
          tree.add(parseNavPoint(navPoint, 0));
        }
      }
      return tree;
    } catch (e) {
      return [];
    }
  }

  /// 解析 NAV 格式目录为树状结构
  ///
  /// EPUB 3 的 NAV 目录是 HTML5 的 <nav epub:type="toc"> + 嵌套 <ol>/<li>：
  /// ```
  /// <nav epub:type="toc">
  ///   <ol>
  ///     <li>
  ///       <a href="chapter1.xhtml">卷一</a>
  ///       <ol>  <!-- 嵌套子列表 -->
  ///         <li><a href="chapter1.xhtml#sec1">第一章</a></li>
  ///       </ol>
  ///     </li>
  ///   </ol>
  /// </nav>
  /// ```
  ///
  /// 返回 [List<EpubChapter>] 树状结构（顶层节点列表）。
  /// 字段填充逻辑与 [_parseNcxToc] 一致：
  /// - [depth]：嵌套层级，0=顶层
  /// - [anchor]：从 href 中分离的 # 后部分
  /// - [spineIndex]：通过 [spineIndexByHref] 反查 OPF spine 顺序索引
  /// - [index]/[parentId]：保持 -1，由 [EpubChapter.flatten] 填充
  /// - [isVolume]：顶层且有子节点时为 true（卷头标记）
  static List<EpubChapter> _parseNavToc(
    String navXml,
    String opfBasePath,
    Map<String, int> spineIndexByHref,
  ) {
    try {
      final doc = html_parser.parse(navXml);

      // 查找 TOC nav 元素
      html_dom.Element? tocNav;
      for (final nav in doc.querySelectorAll('nav')) {
        final epubType =
            nav.attributes['epub:type'] ?? nav.attributes['type'] ?? '';
        if (epubType.contains('toc')) {
          tocNav = nav;
          break;
        }
      }
      tocNav ??= doc.querySelector('nav');

      if (tocNav == null) return [];

      EpubChapter parseLi(html_dom.Element li, int depth) {
        // 查找直接子元素 <a>
        html_dom.Element? a;
        for (final child in li.children) {
          if (_localName(child) == 'a') {
            a = child;
            break;
          }
        }

        String? title;
        String? href;
        String? anchor;
        if (a != null) {
          title = a.text.trim();
          final rawHref = a.attributes['href'] ?? '';
          final rawPath = rawHref.split('#').first;
          href = rawPath.isEmpty ? null : _resolveEpubPath(opfBasePath, rawPath);
          anchor = _extractFragmentId(rawHref);
        }

        // 检查嵌套 <ol>
        html_dom.Element? nestedOl;
        for (final child in li.children) {
          if (_localName(child) == 'ol') {
            nestedOl = child;
            break;
          }
        }

        // 递归构建 children
        final children = <EpubChapter>[];
        if (nestedOl != null) {
          for (final childLi in nestedOl.children) {
            if (_localName(childLi) == 'li') {
              children.add(parseLi(childLi, depth + 1));
            }
          }
        }

        // spineIndex 反查
        final spineIdx = href != null && href.isNotEmpty
            ? (spineIndexByHref[href] ?? -1)
            : -1;

        return EpubChapter(
          index: -1, // 由 flatten 填充
          title: (title != null && title.isNotEmpty)
              ? title
              : '未命名章节',
          href: href,
          anchor: anchor,
          startFragmentId: anchor,
          isVolume: depth == 0 && children.isNotEmpty,
          spineIndex: spineIdx,
          depth: depth,
          parentId: -1, // 由 flatten 填充
          children: children,
        );
      }

      final tree = <EpubChapter>[];
      final ol = tocNav.querySelector('ol');
      if (ol != null) {
        for (final li in ol.children) {
          if (_localName(li) == 'li') {
            tree.add(parseLi(li, 0));
          }
        }
      }
      return tree;
    } catch (e) {
      return [];
    }
  }

  // ===== 以下为原有方法，保持不变 =====

  static EpubBook parse(Map<String, dynamic> epubData) {
    final metadata = epubData['metadata'] as Map<String, dynamic>? ?? {};
    final spine = epubData['spine'] as List<dynamic>? ?? [];
    final manifest = epubData['manifest'] as Map<String, dynamic>? ?? {};
    final toc = epubData['toc'] as List<dynamic>? ?? [];

    final title = metadata['title'] as String? ?? '未知书名';
    final author = metadata['creator'] as String?;
    final description = metadata['description'] as String?;
    final language = metadata['language'] as String?;

    String? coverPath;
    final coverMeta = metadata['meta'] as List<dynamic>? ?? [];
    for (final meta in coverMeta) {
      if (meta is Map && meta['name'] == 'cover') {
        coverPath = meta['content'] as String?;
        break;
      }
    }

    final chapters = <EpubChapter>[];
    for (int i = 0; i < toc.length; i++) {
      final item = toc[i] as Map<String, dynamic>;
      final href = item['href'] as String?;
      final startFragmentId = _extractFragmentId(href);
      if (chapters.isNotEmpty) {
        chapters.last.endFragmentId = startFragmentId;
      }
      chapters.add(EpubChapter(
        index: i,
        title: item['title'] as String? ?? '第${i + 1}章',
        href: href?.split('#').first,
        startFragmentId: startFragmentId,
        isVolume: item['isVolume'] as bool? ?? false,
      ));
    }

    if (chapters.isEmpty) {
      for (int i = 0; i < spine.length; i++) {
        final idref = spine[i] as String?;
        if (idref != null && manifest.containsKey(idref)) {
          final item = manifest[idref] as Map<String, dynamic>;
          final href = item['href'] as String?;
          if (href != null && !href.contains('toc') && !href.contains('nav')) {
            final chapterIndex = chapters.length;
            chapters.add(EpubChapter(
              index: chapterIndex,
              title: chapterIndex == 0 ? '封面' : '第$chapterIndex章',
              href: href,
            ));
          }
        }
      }
    }

    for (int i = 0; i < chapters.length - 1; i++) {
      chapters[i].nextUrl = chapters[i + 1].href;
    }

    return EpubBook(
      title: title,
      author: author,
      description: description,
      coverPath: coverPath,
      chapters: chapters,
      language: language,
    );
  }

  static String? _extractFragmentId(String? href) {
    if (href == null) return null;
    final hashIndex = href.indexOf('#');
    if (hashIndex == -1) return null;
    return href.substring(hashIndex + 1);
  }

  static String extractTextFromHtml(String html) {
    var text = html;

    text = _removeTags(text, 'script');
    text = _removeTags(text, 'style');

    text = text.replaceAllMapped(
      RegExp(r'<svg[^>]*>[\s\S]*?</svg>', caseSensitive: false),
      (match) {
        final svg = match.group(0)!;
        final imgMatches = RegExp(r'<image[^>]+xlink:href="([^"]*)"', caseSensitive: false)
            .allMatches(svg);
        return imgMatches.map((m) => '[图片: ${m.group(1)}]').join('\n');
      },
    );

    text = text.replaceAllMapped(
      RegExp(r'<image[^>]+xlink:href="([^"]*)"', caseSensitive: false),
      (match) => '[图片: ${match.group(1)}]',
    );

    text = text.replaceAllMapped(
      RegExp(r'<img[^>]+src="([^"]*)"', caseSensitive: false),
      (match) => '[图片: ${match.group(1)}]',
    );

    text = text.replaceAllMapped(
      RegExp(r"<img[^>]+src='([^']*)'", caseSensitive: false),
      (match) => '[图片: ${match.group(1)}]',
    );

    text = text.replaceAll(RegExp(r'<br\s*/?\s*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</div>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</h[1-6]>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'</li>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</tr>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</blockquote>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</pre>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</dl>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</dt>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</dd>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</figure>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</figcaption>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</details>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</summary>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</article>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</section>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</aside>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</header>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</footer>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</main>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</nav>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</table>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</thead>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</tbody>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</tfoot>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</th>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</td>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</address>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</fieldset>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</legend>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</form>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</hr>', caseSensitive: false), '\n---\n');
    text = text.replaceAll(RegExp(r'<hr\s*/?\s*>', caseSensitive: false), '\n---\n');

    text = text.replaceAll(RegExp(r'<title[^>]*>[\s\S]*?</title>', caseSensitive: false), '');
    text = text.replaceAllMapped(
      RegExp(r'<[^>]+style="[^"]*display\s*:\s*none[^"]*"[^>]*>[\s\S]*?</[^>]+>', caseSensitive: false),
      (match) => '',
    );

    text = text.replaceAll(RegExp(r'<[^>]+>'), '');

    text = _decodeHtmlEntities(text);

    text = text.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.replaceAll(RegExp(r' {2,}'), ' ');

    return text.trim();
  }

  static String extractHtmlWithImages(String html, {String? basePath}) {
    var text = html;

    // 移除 <script> 标签
    text = _removeTags(text, 'script');
    // 可选移除 <style> 标签（保留内联CSS，移除外部样式块）
    text = _removeTags(text, 'style');
    text = text.replaceAll(RegExp(r'<title[^>]*>[\s\S]*?</title>', caseSensitive: false), '');

    // 处理 SVG 中的 <image xlink:href="..."> → <img src="...">
    text = text.replaceAllMapped(
      RegExp(r'<svg[^>]*>[\s\S]*?</svg>', caseSensitive: false),
      (match) {
        final svg = match.group(0)!;
        return svg.replaceAllMapped(
          RegExp(r'<image[^>]+xlink:href="([^"]*)"', caseSensitive: false),
          (m) {
            var src = m.group(1)!;
            if (basePath != null) src = _resolvePath(basePath, src);
            return '<img src="$src"';
          },
        );
      },
    );

    // 处理独立的 <image xlink:href="..."> → <img src="...">
    text = text.replaceAllMapped(
      RegExp(r'<image[^>]+xlink:href="([^"]*)"', caseSensitive: false),
      (match) {
        var src = match.group(1)!;
        if (basePath != null) src = _resolvePath(basePath, src);
        return '<img src="$src">';
      },
    );

    // 处理 <img src="..."> 路径
    text = text.replaceAllMapped(
      RegExp(r'<img[^>]+src="([^"]*)"', caseSensitive: false),
      (match) {
        var src = match.group(1)!;
        if (basePath != null) src = _resolvePath(basePath, src);
        return '<img src="$src"';
      },
    );

    text = text.replaceAll(RegExp(r'<br\s*/?\s*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</div>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</h[1-6]>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'</li>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</blockquote>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</pre>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</table>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</tr>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</hr>', caseSensitive: false), '\n---\n');
    text = text.replaceAll(RegExp(r'<hr\s*/?\s*>', caseSensitive: false), '\n---\n');

    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = _decodeHtmlEntities(text);
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return text.trim();
  }

  /// 提取 HTML 内容并处理内嵌资源（CSS、图片、字体），返回完整 HTML 文档
  /// [html] 原始 HTML 内容
  /// [basePath] 当前章节文件的路径，用于解析相对路径
  /// [allCss] 合并后的所有 CSS 内容
  /// [fontPaths] 字体文件路径列表
  static String extractHtmlWithResources(
    String html, {
    String? basePath,
    String allCss = '',
    List<String> fontPaths = const [],
  }) {
    var text = html;

    // 移除 <script> 标签
    text = _removeTags(text, 'script');
    // 移除 <title> 标签
    text = text.replaceAll(RegExp(r'<title[^>]*>[\s\S]*?</title>', caseSensitive: false), '');

    // 将 CSS 链接转为内联样式（移除 <link rel="stylesheet">，CSS 将统一注入）
    text = text.replaceAllMapped(
      RegExp(r'<link[^>]+rel=["\x27]stylesheet["\x27][^>]*>', caseSensitive: false),
      (match) => '',
    );
    text = text.replaceAllMapped(
      RegExp(r'<link[^>]+type=["\x27]text/css["\x27][^>]*>', caseSensitive: false),
      (match) => '',
    );

    // 处理 SVG 中的 <image xlink:href="..."> → <img src="...">
    text = text.replaceAllMapped(
      RegExp(r'<svg[^>]*>[\s\S]*?</svg>', caseSensitive: false),
      (match) {
        final svg = match.group(0)!;
        return svg.replaceAllMapped(
          RegExp(r'<image[^>]+xlink:href="([^"]*)"', caseSensitive: false),
          (m) {
            var src = m.group(1)!;
            if (basePath != null) src = _resolvePath(basePath, src);
            return '<img src="$src"';
          },
        );
      },
    );

    // 处理独立的 <image xlink:href="..."> → <img src="...">
    text = text.replaceAllMapped(
      RegExp(r'<image[^>]+xlink:href="([^"]*)"', caseSensitive: false),
      (match) {
        var src = match.group(1)!;
        if (basePath != null) src = _resolvePath(basePath, src);
        return '<img src="$src">';
      },
    );

    // 处理 <img src="..."> 路径
    text = text.replaceAllMapped(
      RegExp(r'<img([^>]+)src="([^"]*)"', caseSensitive: false),
      (match) {
        var src = match.group(2)!;
        if (basePath != null) src = _resolvePath(basePath, src);
        return '<img${match.group(1)}src="$src"';
      },
    );

    // 处理字体引用：替换 CSS 中的 @font-face url() 为本地路径
    var processedCss = allCss;
    for (final fontPath in fontPaths) {
      final fontName = fontPath.split('/').last;
      // 替换相对路径的字体引用为绝对路径
      processedCss = processedCss.replaceAllMapped(
        RegExp(r'url\(["\x27]?([^)"\x27]+\/)?' + RegExp.escape(fontName) + r'["\x27]?\)', caseSensitive: false),
        (match) => 'url("$fontPath")',
      );
    }

    // 构建完整 HTML 文档
    final cssBlock = processedCss.isNotEmpty ? '<style>$processedCss</style>' : '';

    // 如果已经有 <html> 或 <body> 标签，注入 CSS
    if (text.contains(RegExp(r'<html', caseSensitive: false))) {
      // 在 </head> 或 <body> 前注入 CSS
      if (text.contains(RegExp(r'</head>', caseSensitive: false))) {
        text = text.replaceFirst(
          RegExp(r'</head>', caseSensitive: false),
          '$cssBlock</head>',
        );
      } else if (text.contains(RegExp(r'<body', caseSensitive: false))) {
        text = text.replaceFirst(
          RegExp(r'<body', caseSensitive: false),
          '$cssBlock<body',
        );
      } else {
        text = '$cssBlock$text';
      }
    } else {
      // 没有完整 HTML 结构，包装一个
      text = '<!DOCTYPE html><html><head><meta charset="utf-8">$cssBlock</head><body>$text</body></html>';
    }

    return text;
  }

  /// 从 EPUB ZIP 文件中获取所有 CSS 文件内容并合并
  /// [files] ZIP 解压后的文件映射（归一化路径 -> 内容字节）
  /// [opfBasePath] OPF 文件所在目录
  /// [manifest] OPF manifest 条目映射
  static String getAllCss(
    Map<String, List<int>> files,
    String opfBasePath,
    Map<String, ManifestItem> manifest,
  ) {
    final cssBuffer = StringBuffer();

    for (final item in manifest.values) {
      if (item.mediaType == 'text/css' || item.href.toLowerCase().endsWith('.css')) {
        final cssPath = _resolveEpubPath(opfBasePath, item.href);
        final cssData = files[cssPath];
        if (cssData != null) {
          final content = decodeBytes(cssData);
          if (content.isNotEmpty) {
            cssBuffer.writeln('/* === ${item.href} === */');
            cssBuffer.writeln(content);
            cssBuffer.writeln();
          }
        }
      }
    }

    return cssBuffer.toString();
  }

  /// 从 EPUB manifest 中获取所有字体文件路径
  /// [opfBasePath] OPF 文件所在目录
  /// [manifest] OPF manifest 条目映射
  static List<String> getAllFonts(
    String opfBasePath,
    Map<String, ManifestItem> manifest,
  ) {
    final fontPaths = <String>[];
    final fontMediaTypes = [
      'font/ttf',
      'font/otf',
      'font/woff',
      'font/woff2',
      'application/x-font-ttf',
      'application/x-font-otf',
      'application/x-font-woff',
      'application/font-ttf',
      'application/font-otf',
      'application/font-woff',
      'application/font-woff2',
      'application/vnd.ms-opentype',
      'application/vnd.ms-fontobject',
    ];
    final fontExtensions = ['.ttf', '.otf', '.woff', '.woff2', '.eot'];

    for (final item in manifest.values) {
      final isFontMediaType = item.mediaType.contains('font') ||
          fontMediaTypes.contains(item.mediaType.toLowerCase());
      final isFontExtension = fontExtensions.any((ext) => item.href.toLowerCase().endsWith(ext));

      if (isFontMediaType || isFontExtension) {
        fontPaths.add(_resolveEpubPath(opfBasePath, item.href));
      }
    }

    return fontPaths;
  }

  static String extractFragment(String html, String? startId, String? endId) {
    if (startId == null && endId == null) return html;

    var result = html;

    if (startId != null) {
      final pattern = RegExp('id="${RegExp.escape(startId)}"', caseSensitive: false);
      final match = pattern.firstMatch(result);
      if (match != null) {
        result = result.substring(match.start);
      }
    }

    if (endId != null && endId != startId) {
      final pattern = RegExp('id="${RegExp.escape(endId)}"', caseSensitive: false);
      final match = pattern.firstMatch(result);
      if (match != null) {
        result = result.substring(0, match.start);
      }
    }

    return result;
  }

  /// 从 EPUB 章节 HTML 中提取 body 内部的 HTML（保留所有标签结构）。
  ///
  /// 用于富 HTML 渲染：保留 `<p>/<h1>/<img>/<blockquote>/<ul>/<table>` 等
  /// 标签，让阅读器 WebView 原生渲染 EPUB 排版。
  ///
  /// 步骤：
  /// 1. 用 html 包解析，提取 body 元素
  /// 2. 若没有 body（片段 HTML），返回清理后的原始内容
  /// 3. 移除 `<script>/<style>/<title>` 等不该出现在正文的标签
  /// 4. 若有 startFragmentId，截取从该 id 开始的内容
  /// 5. 返回 body innerHTML
  static String extractBodyContent(
    String html, {
    String? startFragmentId,
    String? endFragmentId,
  }) {
    try {
      final doc = html_parser.parse(html);
      html_dom.Element? body = doc.body;

      String content;
      if (body != null) {
        // 移除 script/style/title/link/meta 等非正文标签
        for (final tag in ['script', 'style', 'title', 'link', 'meta', 'noscript']) {
          body.querySelectorAll(tag).forEach((e) => e.remove());
        }
        content = body.innerHtml;
      } else {
        // 片段 HTML：直接清理
        var text = html;
        text = _removeTags(text, 'script');
        text = _removeTags(text, 'style');
        text = _removeTags(text, 'title');
        content = text;
      }

      // 应用 fragment 切片（NCX/NAV 的 startFragmentId/endFragmentId）
      if (startFragmentId != null || endFragmentId != null) {
        content = _sliceByFragment(content, startFragmentId, endFragmentId);
      }

      return content.trim();
    } catch (_) {
      return html;
    }
  }

  /// 按 fragment id 切片 HTML 内容
  static String _sliceByFragment(String html, String? startId, String? endId) {
    if (startId == null && endId == null) return html;
    var result = html;

    if (startId != null) {
      // 匹配 id="xxx" 或 id='xxx'
      final pattern = RegExp(
        'id=["\']${RegExp.escape(startId)}["\']',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(result);
      if (match != null) {
        result = result.substring(match.start);
      }
    }

    if (endId != null && endId != startId) {
      final pattern = RegExp(
        'id=["\']${RegExp.escape(endId)}["\']',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(result);
      if (match != null) {
        result = result.substring(0, match.start);
      }
    }

    return result;
  }

  /// 把字节编码为 data URI（用于内嵌图片/字体到 HTML）
  ///
  /// [mediaType] 例如 'image/jpeg'、'image/png'、'font/ttf'
  /// 返回 'data:image/jpeg;base64,...'
  static String encodeBytesAsDataUri(Uint8List bytes, String mediaType) {
    final b64 = base64Encode(bytes);
    return 'data:$mediaType;base64,$b64';
  }

  /// 根据文件扩展名推断 MIME 类型
  static String inferMediaType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'ttf':
        return 'font/ttf';
      case 'otf':
        return 'font/otf';
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'css':
        return 'text/css';
      default:
        return 'application/octet-stream';
    }
  }

  static String _removeTags(String html, String tagName) {
    return html.replaceAllMapped(
      RegExp('<$tagName[^>]*>[\\s\\S]*?</$tagName>', caseSensitive: false),
      (match) => '',
    );
  }

  static String _resolvePath(String basePath, String relativePath) {
    if (relativePath.startsWith('http') || relativePath.startsWith('data:')) {
      return relativePath;
    }
    try {
      final base = Uri.parse(basePath);
      return base.resolve(relativePath).toString();
    } catch (_) {
      return relativePath;
    }
  }

  static String _decodeHtmlEntities(String text) {
    final entityMap = <String, String>{
      '&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>',
      '&quot;': '"', '&apos;': "'", '&copy;': '©', '&reg;': '®',
      '&trade;': '™', '&mdash;': '—', '&ndash;': '–',
      '&lsquo;': '\u2018', '&rsquo;': '\u2019', '&ldquo;': '\u201C', '&rdquo;': '\u201D',
      '&hellip;': '…', '&middot;': '·', '&bull;': '•',
      '&laquo;': '«', '&raquo;': '»', '&times;': '×', '&divide;': '÷',
      '&deg;': '°', '&plusmn;': '±', '&para;': '¶', '&sect;': '§',
      '&euro;': '€', '&pound;': '£', '&yen;': '¥', '&cent;': '¢',
      '&larr;': '←', '&rarr;': '→', '&uarr;': '↑', '&darr;': '↓',
      '&hearts;': '♥', '&diams;': '♦', '&clubs;': '♣', '&spades;': '♠',
      '&ensp;': '\u2002', '&emsp;': '\u2003', '&thinsp;': '\u2009',
      '&zwnj;': '\u200C', '&zwj;': '\u200D', '&lrm;': '\u200E', '&rlm;': '\u200F',
      '&sbquo;': '\u201A', '&bdquo;': '\u201E',
      '&dagger;': '†', '&Dagger;': '‡', '&permil;': '‰',
      '&lsaquo;': '\u2039', '&rsaquo;': '\u203A',
      '&iexcl;': '¡', '&curren;': '¤', '&brvbar;': '¦', '&uml;': '¨',
      '&ordf;': 'ª', '&not;': '¬', '&shy;': '\u00AD',
      '&macr;': '¯', '&sup2;': '²', '&sup3;': '³', '&acute;': '´',
      '&micro;': 'µ', '&cedil;': '¸', '&sup1;': '¹', '&ordo;': 'º',
      '&frac14;': '¼', '&frac12;': '½', '&frac34;': '¾',
      '&iquest;': '¿', '&Agrave;': 'À', '&Aacute;': 'Á', '&Acirc;': 'Â',
      '&Atilde;': 'Ã', '&Auml;': 'Ä', '&Aring;': 'Å', '&AElig;': 'Æ',
      '&Ccedil;': 'Ç', '&Egrave;': 'È', '&Eacute;': 'É', '&Ecirc;': 'Ê',
      '&Euml;': 'Ë', '&Igrave;': 'Ì', '&Iacute;': 'Í', '&Icirc;': 'Î',
      '&Iuml;': 'Ï', '&ETH;': 'Ð', '&Ntilde;': 'Ñ', '&Ograve;': 'Ò',
      '&Oacute;': 'Ó', '&Ocirc;': 'Ô', '&Otilde;': 'Õ', '&Ouml;': 'Ö',
      '&Oslash;': 'Ø', '&Ugrave;': 'Ù', '&Uacute;': 'Ú', '&Ucirc;': 'Û',
      '&Uuml;': 'Ü', '&Yacute;': 'Ý', '&THORN;': 'Þ', '&szlig;': 'ß',
      '&agrave;': 'à', '&aacute;': 'á', '&acirc;': 'â', '&atilde;': 'ã',
      '&auml;': 'ä', '&aring;': 'å', '&aelig;': 'æ', '&ccedil;': 'ç',
      '&egrave;': 'è', '&eacute;': 'é', '&ecirc;': 'ê', '&euml;': 'ë',
      '&igrave;': 'ì', '&iacute;': 'í', '&icirc;': 'î', '&iuml;': 'ï',
      '&eth;': 'ð', '&ntilde;': 'ñ', '&ograve;': 'ò', '&oacute;': 'ó',
      '&ocirc;': 'ô', '&otilde;': 'õ', '&ouml;': 'ö', '&oslash;': 'ø',
      '&ugrave;': 'ù', '&uacute;': 'ú', '&ucirc;': 'û', '&uuml;': 'ü',
      '&yacute;': 'ý', '&thorn;': 'þ', '&yuml;': 'ÿ',
      '&OElig;': '\u0152', '&oelig;': '\u0153', '&Scaron;': '\u0160',
      '&scaron;': '\u0161', '&Yuml;': '\u0178', '&fnof;': '\u0192',
      '&circ;': '\u02C6', '&tilde;': '\u02DC',
      '&Alpha;': 'Α', '&Beta;': 'Β', '&Gamma;': 'Γ', '&Delta;': 'Δ',
      '&Epsilon;': 'Ε', '&Zeta;': 'Ζ', '&Eta;': 'Η', '&Theta;': 'Θ',
      '&Iota;': 'Ι', '&Kappa;': 'Κ', '&Lambda;': 'Λ', '&Mu;': 'Μ',
      '&Nu;': 'Ν', '&Xi;': 'Ξ', '&Omicron;': 'Ο', '&Pi;': 'Π',
      '&Rho;': 'Ρ', '&Sigma;': 'Σ', '&Tau;': 'Τ', '&Upsilon;': 'Υ',
      '&Phi;': 'Φ', '&Chi;': 'Χ', '&Psi;': 'Ψ', '&Omega;': 'Ω',
      '&alpha;': 'α', '&beta;': 'β', '&gamma;': 'γ', '&delta;': 'δ',
      '&epsilon;': 'ε', '&zeta;': 'ζ', '&eta;': 'η', '&theta;': 'θ',
      '&iota;': 'ι', '&kappa;': 'κ', '&lambda;': 'λ', '&mu;': 'μ',
      '&nu;': 'ν', '&xi;': 'ξ', '&omicron;': 'ο', '&pi;': 'π',
      '&rho;': 'ρ', '&sigmaf;': 'ς', '&sigma;': 'σ', '&tau;': 'τ',
      '&upsilon;': 'υ', '&phi;': 'φ', '&chi;': 'χ', '&psi;': 'ψ',
      '&omega;': 'ω', '&thetasym;': 'ϑ', '&upsih;': 'ϒ', '&piv;': 'ϖ',
    };
    for (final entry in entityMap.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }
    text = text.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) => String.fromCharCode(int.parse(match.group(1)!)),
    );
    text = text.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
    );
    text = text.replaceAllMapped(
      RegExp(r'&([a-zA-Z]+);'),
      (match) {
        final name = match.group(1)!;
        return entityMap['&$name;'] ?? match.group(0)!;
      },
    );
    return text;
  }
}
