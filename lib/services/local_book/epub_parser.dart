import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;
import 'package:xml/xml.dart' as xml;

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

  /// 预解析好的富 HTML 内容（导入时一次性生成，阅读时直接返回）
  ///
  /// 格式：`[[EPUB_CSS]]<style>...</style>[[/EPUB_CSS]][[EPUB_BODY]]<p>...</p>[[/EPUB_BODY]]`
  /// 由 `EpubParser.parseFromBytes` 在导入时预生成，包含：
  /// - EPUB 全部 CSS（合并所有 .css 文件）
  /// - 章节正文 HTML（保留所有 HTML5 标签）
  /// - 图片转 base64 data URI 内嵌
  /// 阅读器 WebView 直接渲染此内容，无需现场解压 ZIP 和处理资源。
  String? richContent;

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
    this.richContent,
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
        richContent: node.richContent,
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

  /// EPUB 解压到本地的根目录路径（绝对路径）
  ///
  /// 导入时由 LocalBookService 把 EPUB ZIP 解压到应用文档目录，
  /// 此字段存储解压根目录（如 `/data/.../epub_extract/<bookId>/`）。
  /// 预解析时把 CSS/HTML 中的相对资源路径转为指向此目录的绝对路径，
  /// WebView 通过 `file://` baseUrl 直接访问原始资源文件，无需 base64 编码。
  ///
  /// 优势：
  /// - 内存占用极低（不内嵌 64MB 视频 / 10.8MB 字体 base64）
  /// - 资源按需加载（WebView 懒加载图片/字体）
  /// - 系统磁盘缓存复用
  final String extractedBasePath;

  /// EPUB 合并后的 CSS（资源路径已转为 file:// 绝对路径）
  ///
  /// 在 `EpubParser.parseFromBytes` 时一次性生成，所有章节共享。
  /// 由 `LocalBookService._getEpubContent` 拼接到 `richContent` 前面。
  final String inlinedCss;

  const EpubBook({
    required this.title,
    this.author,
    this.description,
    this.coverPath,
    this.chapters = const [],
    this.tocTree = const [],
    this.spineCount = 0,
    this.language,
    this.extractedBasePath = '',
    this.inlinedCss = '',
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
  ///
  /// [extractedBasePath] EPUB 解压到本地的根目录绝对路径。
  /// 提供此参数后，CSS/HTML 中的相对资源路径会转为指向此目录的绝对路径，
  /// WebView 通过 `file://` baseUrl 直接访问原始文件，无需 base64 编码。
  /// 若为空字符串，则回退到 base64 内嵌模式（用于测试或无解压场景）。
  static EpubBook parseFromBytes(Uint8List bytes, {String extractedBasePath = ''}) {
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

      // 5-6. 用 xml 包解析 manifest 和 spine
      //
      // 注意：必须用 xml 包解析 OPF，不能用 html_parser。
      // OPF 是 XML 文件，<item .../> 和 <itemref .../> 是自闭合标签。
      // html_parser 是 HTML5 解析器，不认识 XML 自闭合写法
      // （HTML5 中只有 void 元素如 <img/> 才自闭合），
      // 会把 <itemref idref="ch1"/> 当作 <itemref idref="ch1"> 开始标签，
      // 后续 <itemref> 会被嵌套在第一个 itemref 内部，导致只解析出 1 项。
      // xml 包能正确解析 XML 自闭合标签。
      final manifest = <String, ManifestItem>{};
      final spine = <String>[];
      String? tocId;

      try {
        final xmlDoc = xml.XmlDocument.parse(decodeBytes(opfData));

        // 5. 解析 manifest
        xml.XmlElement? xmlManifest;
        for (final el in xmlDoc.findAllElements('manifest')) {
          xmlManifest = el;
          break;
        }
        if (xmlManifest != null) {
          for (final child in xmlManifest.findElements('item')) {
            final id = child.getAttribute('id') ?? '';
            final href = child.getAttribute('href') ?? '';
            final mediaType = child.getAttribute('media-type') ?? '';
            final properties = child.getAttribute('properties');
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
        debugPrint('[EPUB诊断-OPF] manifest解析: ${manifest.length} 项');

        // 6. 解析 spine
        xml.XmlElement? xmlSpine;
        for (final el in xmlDoc.findAllElements('spine')) {
          xmlSpine = el;
          break;
        }
        if (xmlSpine != null) {
          tocId = xmlSpine.getAttribute('toc');
          for (final child in xmlSpine.findElements('itemref')) {
            final idref = child.getAttribute('idref');
            if (idref != null) {
              spine.add(idref);
            }
          }
        }
        debugPrint('[EPUB诊断-OPF] spine解析: ${spine.length} 项, tocId=$tocId');
      } catch (e) {
        debugPrint('[EPUB诊断-OPF] xml包解析异常: $e');
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
              (_containsWholeWord(item.properties, 'cover-image') ||
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
      debugPrint('[EPUB诊断] opfBasePath=$opfBasePath');
      debugPrint('[EPUB诊断] spine数量=${spine.length} items=${spine.join(",")}');
      debugPrint('[EPUB诊断] manifest数量=${manifest.length}');
      debugPrint('[EPUB诊断] spineIndexByHref=$spineIndexByHref');
      debugPrint('[EPUB诊断] files路径列表=${files.keys.toList()}');

      // 8.2 查找 NAV 目录（EPUB 3，properties='nav' 优先，参考 legado findTableOfContentsResource）
      String? navHref;
      String? ncxHref;
      // 优先：manifest 中 properties 整词匹配 'nav' 的项（EPUB 3 标准）
      // 用整词匹配避免误判 'nav-map'/'nav-reference' 等含 nav 子串的属性
      // 参考 lumina `_containsWholeWord(properties, 'nav')`
      for (final item in manifest.values) {
        if (_containsWholeWord(item.properties, 'nav') &&
            item.mediaType == 'application/xhtml+xml') {
          navHref = item.href;
          debugPrint('[EPUB诊断] properties=nav 找到NAV: id=${item.id} href=$navHref');
          break;
        }
      }
      // 8.3 查找 NCX 目录（EPUB 2）
      if (tocId != null && manifest.containsKey(tocId)) {
        final tocItem = manifest[tocId]!;
        debugPrint('[EPUB诊断] spine.toc指向 tocId=$tocId href=${tocItem.href} mediaType=${tocItem.mediaType}');
        if (tocItem.mediaType.contains('ncx') ||
            tocItem.href.endsWith('.ncx')) {
          ncxHref = tocItem.href;
        } else if (navHref == null &&
            (tocItem.mediaType == 'application/xhtml+xml' ||
                tocItem.href.endsWith('.xhtml') ||
                tocItem.href.endsWith('.html'))) {
          // spine.toc 指向 xhtml 但不是 .ncx：可能是 EPUB 3 的 nav
          navHref = tocItem.href;
          debugPrint('[EPUB诊断] spine.toc指向xhtml，作为NAV: $navHref');
        }
      }
      if (ncxHref == null) {
        for (final item in manifest.values) {
          if (item.mediaType == 'application/x-dtbncx+xml' ||
              item.href.endsWith('.ncx')) {
            ncxHref = item.href;
            debugPrint('[EPUB诊断] 全量扫描找到NCX: $ncxHref');
            break;
          }
        }
      }
      // NAV 兜底：通过 id/href 名字含 nav 查找
      if (navHref == null) {
        for (final item in manifest.values) {
          if (item.mediaType == 'application/xhtml+xml' &&
              (item.id.toLowerCase().contains('nav') ||
                  item.href.toLowerCase().contains('nav'))) {
            navHref = item.href;
            debugPrint('[EPUB诊断] 名字兜底找到NAV: id=${item.id} href=$navHref');
            break;
          }
        }
      }
      debugPrint('[EPUB诊断] 最终ncxHref=$ncxHref navHref=$navHref');

      // 8.4 优先尝试 NAV（EPUB 3）→ NCX（EPUB 2）→ spine 兜底
      // 参考 legado：EPUB 3 优先用 nav，EPUB 2 用 ncx
      List<EpubChapter> tocTree = [];
      List<EpubChapter> chapters;

      if (navHref != null) {
        final navPath = _resolveEpubPath(opfBasePath, navHref);
        final navData = files[navPath];
        debugPrint('[EPUB诊断] NAV解析: navPath=$navPath 数据存在=${navData != null}');
        if (navData != null) {
          // 关键：baseDir 用 NAV 文件自身所在目录，而非 OPF 目录
          // NAV 文件可能在子目录（如 OEBPS/nav.xhtml），其内部相对路径
          // 是相对 NAV 文件目录解析的，用 OPF 目录会解析错误
          // 参考 lumina `navDir`
          final navDir = navPath.contains('/')
              ? navPath.substring(0, navPath.lastIndexOf('/'))
              : '';
          tocTree = _parseNavToc(
            decodeBytes(navData),
            navDir,
            spineIndexByHref,
          );
          debugPrint('[EPUB诊断] NAV解析结果: tocTree节点数=${tocTree.length}');
        }
      }

      if (tocTree.isEmpty && ncxHref != null) {
        final ncxPath = _resolveEpubPath(opfBasePath, ncxHref);
        final ncxData = files[ncxPath];
        debugPrint('[EPUB诊断] NCX解析: ncxPath=$ncxPath 数据存在=${ncxData != null}');
        if (ncxData != null) {
          // 关键：baseDir 用 NCX 文件自身所在目录，而非 OPF 目录
          // 同 NAV，NCX 文件可能在子目录，其 src 是相对 NCX 文件目录解析的
          // 参考 lumina `ncxDir`
          final ncxDir = ncxPath.contains('/')
              ? ncxPath.substring(0, ncxPath.lastIndexOf('/'))
              : '';
          tocTree = _parseNcxToc(
            decodeBytes(ncxData),
            ncxDir,
            spineIndexByHref,
          );
          debugPrint('[EPUB诊断] NCX解析结果: tocTree节点数=${tocTree.length}');
        }
      }

      if (tocTree.isNotEmpty) {
        // NCX/NAV 解析成功：扁平化得到 chapters
        chapters = EpubChapter.flatten(tocTree);
        debugPrint('[EPUB诊断] flatten后chapters数量=${chapters.length}');
        if (chapters.isNotEmpty) {
          debugPrint('[EPUB诊断] 第1章: title=${chapters[0].title} href=${chapters[0].href} spineIndex=${chapters[0].spineIndex} depth=${chapters[0].depth}');
        }
      } else {
        // 后备：使用 spine 条目直接构造扁平 chapters（无嵌套）
        debugPrint('[EPUB诊断] NCX/NAV都失败，用spine兜底');
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
        debugPrint('[EPUB诊断] spine兜底chapters数量=${chapters.length}');
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

      // 9.5 预解析所有章节的富 HTML 内容（导入时一次性完成）
      //
      // 把图片转 base64 data URI、合并所有 CSS、包裹成
      // [[EPUB_CSS]]...[[/EPUB_CSS]][[EPUB_BODY]]...[[/EPUB_BODY]] 格式。
      // 阅读时 _getEpubContent 直接返回 richContent，无需现场解压 ZIP。
      //
      // 优势：
      // - 导入时一次性完成所有重活，阅读时 O(1) 查询
      // - 避免每次翻页都解压 ZIP 和遍历文件
      // - CSS 只合并一次，所有章节共享
      // 预解析所有章节的富 HTML 内容（导入时一次性完成）
      //
      // 把所有资源（字体、CSS 中的 url()、图片、视频、SVG image）转 base64 data URI，
      // 让 WebView 无需任何资源拦截即可完整渲染 EPUB 排版。
      //
      // 关键点：
      // - CSS 中 @font-face url(../Fonts/xxx.ttf) → data URI（字体生效）
      // - CSS 中 background-image: url(../Images/xxx.jpg) → data URI（背景图生效）
      // - body 中 <img src="../Images/xxx.jpg"> → data URI
      // - body 中 <source src="../Video/xxx.mp4"> → data URI（视频）
      // - body 中 <image xlink:href="../Images/xxx.jpg"> → data URI（SVG）
      // - 所有 CSS 合并为一份，所有章节共享（字体和背景图只内嵌一次）
      final rawCss = _collectAllCss(files);
      // 改写 EPUB CSS 中的 body/html 全局选择器为 #reader-content-a
      // 避免 body{padding} 等样式破坏 reader 布局（reader body 包含 #reader-root）
      final epubCss = _rewriteCssSelectorsForReader(rawCss);
      // CSS 资源路径处理：
      // - extractedBasePath 非空（推荐）：url() 转为指向解压目录的绝对路径，
      //   WebView 通过 file:// baseUrl 直接访问原始文件，内存占用极低
      // - extractedBasePath 为空（回退）：url() 转 base64 data URI，内存占用高
      final inlinedCss = extractedBasePath.isNotEmpty
          ? _rewriteCssUrlsToPath(epubCss, extractedBasePath, 'OEBPS/Styles/')
          : _inlineUrlsInCss(epubCss, files, 'OEBPS/Styles/');
      debugPrint('[EPUB诊断] CSS处理完成，大小: ${inlinedCss.length} 字符 '
          '(模式: ${extractedBasePath.isNotEmpty ? "路径转换" : "base64内嵌"})');

      for (final chapter in chapters) {
        if (chapter.content == null) continue;
        try {
          // 1. 提取 body HTML + body 属性（class/style/bgcolor）
          //    body 属性包含章节级背景设置（如 .video-bg 背景图、bgcolor 背景色），
          //    必须保留并应用到 reader 内容容器，否则背景样式丢失
          final (bodyHtml, bodyAttrs) = extractBodyWithAttrs(
            chapter.content!,
            chapter.startFragmentId,
            chapter.endFragmentId,
          );

          // 2. 计算章节文件路径（用于解析相对图片路径）
          final chapterHref = chapter.href ?? '';
          final chapterPath = chapterHref.split('#').first;
          String? chapterBasePath;
          if (chapterPath.contains('/')) {
            chapterBasePath =
                chapterPath.substring(0, chapterPath.lastIndexOf('/') + 1);
          }

          // 3. 处理 body 中的所有资源引用：
          // - extractedBasePath 非空：转绝对路径（推荐，内存低）
          // - extractedBasePath 为空：转 base64 data URI（回退）
          final String richBody;
          final String inlinedBodyAttrs;
          if (extractedBasePath.isNotEmpty) {
            richBody = _rewriteHtmlResourcesToPath(
              bodyHtml, extractedBasePath, chapterBasePath,
            );
            inlinedBodyAttrs = _rewriteStyleUrlsToPath(
              bodyAttrs, extractedBasePath, chapterBasePath,
            );
          } else {
            var rb = _inlineImagesInHtml(bodyHtml, files, chapterBasePath);
            rb = _inlineVideoSources(rb, files, chapterBasePath);
            rb = _inlineSvgImages(rb, files, chapterBasePath);
            richBody = rb;
            inlinedBodyAttrs =
                _inlineStyleUrls(bodyAttrs, files, chapterBasePath);
          }

          // 4. 用 wrapper div 包裹 body 内容，把 body 的 class/style 应用到 div
          //    这样 CSS 中 .video-bg / .volume-bg 等选择器才能生效
          //    加 epub-chapter-bg 标记 class，让 reader 兜底 CSS 能精确匹配
          //    背景容器，设置 min-height 让背景填满整页
          //    智能合并 class：若 bodyAttrs 已有 class，追加 epub-chapter-bg；
          //    否则单独加 class="epub-chapter-bg"
          final wrapperAttrs = inlinedBodyAttrs.isEmpty
              ? ''
              : (inlinedBodyAttrs.contains('class="')
                  ? inlinedBodyAttrs.replaceAllMapped(
                      RegExp(r'class="([^"]*)"'),
                      (m) => 'class="epub-chapter-bg ${m.group(1)}"',
                    )
                  : 'class="epub-chapter-bg" $inlinedBodyAttrs');
          final wrapperStart = '<div $wrapperAttrs>';
          const wrapperEnd = '</div>';
          final wrappedBody = '$wrapperStart$richBody$wrapperEnd';

          // 5. richContent 只包含 body HTML（不含 CSS）
          //    CSS 由 LocalBookService._getEpubContent 在返回时拼接，
          //    避免每个章节都复制一份大 CSS
          chapter.richContent = '[[EPUB_BODY]]$wrappedBody[[/EPUB_BODY]]';
        } catch (e) {
          // 单章节预解析失败：退化为纯文本，不影响其他章节
          debugPrint('[EPUB诊断] 章节${chapter.index}预解析失败: $e');
          chapter.richContent =
              '[[EPUB_BODY]]${extractTextFromHtml(chapter.content!)}[[/EPUB_BODY]]';
        }
      }
      debugPrint('[EPUB诊断] 预解析完成，${chapters.length} 章已生成 richContent');

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
        extractedBasePath: extractedBasePath,
        inlinedCss: inlinedCss,
      );
    } catch (e, st) {
      debugPrint('[EPUB诊断] parseFromBytes异常: $e');
      debugPrint('[EPUB诊断] 异常堆栈: $st');
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

  /// 整词匹配 properties 中的某个属性值
  ///
  /// EPUB 3 的 manifest item properties 是空格分隔的属性列表，
  /// 例如 "nav cover-image" 或 "svg remote-resources"。
  /// 用 `contains('nav')` 会误判 `nav-map` 等含 nav 子串的属性，
  /// 必须用 `\bnav\b` 整词匹配。
  /// 参考 lumina `_containsWholeWord`。
  static bool _containsWholeWord(String? value, String word) {
    if (value == null || value.trim().isEmpty) return false;
    final pattern = RegExp(
      '\\b${RegExp.escape(word)}\\b',
      caseSensitive: false,
    );
    return pattern.hasMatch(value);
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
  ///
  /// [baseDir]：NCX 文件自身所在目录（EPUB ZIP 内绝对路径的目录部分），
  /// 用于解析 NCX 内 `content src` 的相对路径。
  /// 注意不是 OPF 目录——NCX 文件可能在子目录（如 `OEBPS/toc/toc.ncx`），
  /// 其 src 是相对 NCX 文件目录解析的。参考 lumina `ncxDir`。
  static List<EpubChapter> _parseNcxToc(
    String ncxXml,
    String baseDir,
    Map<String, int> spineIndexByHref,
  ) {
    try {
      // NCX 是 XML 文档（带命名空间 http://www.daisy.org/z3986/2005/ncx/），
      // 必须用 xml 包解析（html_parser 对 XML 声明+DOCTYPE+命名空间支持差）
      final doc = xml.XmlDocument.parse(ncxXml);
      // 查找 navMap（NCX 根元素下的目录容器）
      // 用 findAllElements 忽略命名空间前缀，按 localName 查找
      xml.XmlElement? navMap;
      for (final el in doc.findAllElements('navMap')) {
        navMap = el;
        break;
      }
      debugPrint('[EPUB诊断-NCX] navMap存在=${navMap != null} baseDir=$baseDir');
      if (navMap == null) {
        final preview = ncxXml.length > 500 ? ncxXml.substring(0, 500) : ncxXml;
        debugPrint('[EPUB诊断-NCX] navMap=null, NCX原文预览: $preview');
        return [];
      }

      EpubChapter parseNavPoint(xml.XmlElement navPoint, int depth) {
        // navLabel > text
        String title = '未命名章节';
        for (final labelEl in navPoint.findElements('navLabel')) {
          for (final textEl in labelEl.findElements('text')) {
            final t = textEl.innerText.trim();
            if (t.isNotEmpty) {
              title = t;
              break;
            }
          }
          break;
        }

        // content src
        String src = '';
        for (final contentEl in navPoint.findElements('content')) {
          src = contentEl.getAttribute('src') ?? '';
          break;
        }
        final rawHref = src.split('#').first;
        final href = rawHref.isEmpty ? null : _resolveEpubPath(baseDir, rawHref);
        final anchor = _extractFragmentId(src);

        // 递归子 navPoint
        final children = <EpubChapter>[];
        for (final child in navPoint.findElements('navPoint')) {
          children.add(parseNavPoint(child, depth + 1));
        }

        final spineIdx = href != null && href.isNotEmpty
            ? (spineIndexByHref[href] ?? -1)
            : -1;

        return EpubChapter(
          index: -1,
          title: title,
          href: href,
          anchor: anchor,
          startFragmentId: anchor,
          isVolume: depth == 0 && children.isNotEmpty,
          spineIndex: spineIdx,
          depth: depth,
          parentId: -1,
          children: children,
        );
      }

      final tree = <EpubChapter>[];
      final topNavPoints = navMap.findElements('navPoint').toList();
      debugPrint('[EPUB诊断-NCX] 顶层navPoint数量=${topNavPoints.length}');
      for (final navPoint in topNavPoints) {
        tree.add(parseNavPoint(navPoint, 0));
      }
      debugPrint('[EPUB诊断-NCX] 解析完成tree节点数=${tree.length}');
      return tree;
    } catch (e, st) {
      debugPrint('[EPUB诊断-NCX] 解析异常: $e');
      debugPrint('[EPUB诊断-NCX] 异常堆栈: $st');
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
  ///
  /// [baseDir]：NAV 文件自身所在目录（EPUB ZIP 内绝对路径的目录部分），
  /// 用于解析 NAV 内 `<a href>` 的相对路径。
  /// 注意不是 OPF 目录——NAV 文件可能在子目录（如 `OEBPS/nav.xhtml`），
  /// 其 href 是相对 NAV 文件目录解析的。参考 lumina `navDir`。
  static List<EpubChapter> _parseNavToc(
    String navXml,
    String baseDir,
    Map<String, int> spineIndexByHref,
  ) {
    try {
      // NAV 是 XHTML（EPUB 3），用 xml 包解析以保留命名空间属性 epub:type
      final doc = xml.XmlDocument.parse(navXml);

      // 查找 TOC nav 元素
      // epub:type 是 EPUB 3 的命名空间属性（namespace: http://www.idpf.org/2007/ops）
      // 三层 fallback 顺序参考 lumina：
      //   1. 命名空间属性 type（XML 解析后 epub:type 会变成带 namespace 的 type）
      //   2. 普通属性 epub:type（部分文档未声明命名空间时的兜底）
      //   3. 普通属性 type（极少见兜底）
      // 然后用整词匹配 'toc'，避免误判 'toc-brief'/'toc-full' 等含 toc 子串的类型
      xml.XmlElement? tocNav;
      final allNavs = doc.findAllElements('nav').toList();
      debugPrint('[EPUB诊断-NAV] 文档中nav数量=${allNavs.length} baseDir=$baseDir');
      for (final nav in allNavs) {
        final epubType = nav.getAttribute(
              'type',
              namespaceUri: 'http://www.idpf.org/2007/ops',
            ) ??
            nav.getAttribute('epub:type') ??
            nav.getAttribute('type') ??
            '';
        debugPrint('[EPUB诊断-NAV] nav: epub:type=$epubType');
        if (_containsWholeWord(epubType, 'toc')) {
          tocNav = nav;
          break;
        }
      }
      // 兜底：取第一个 nav
      if (tocNav == null && allNavs.isNotEmpty) {
        tocNav = allNavs.first;
        debugPrint('[EPUB诊断-NAV] 无epub:type=toc，兜底用第一个nav');
      }
      debugPrint('[EPUB诊断-NAV] tocNav存在=${tocNav != null}');

      if (tocNav == null) {
        final preview = navXml.length > 500 ? navXml.substring(0, 500) : navXml;
        debugPrint('[EPUB诊断-NAV] 无nav，原文预览: $preview');
        return [];
      }

      EpubChapter parseLi(xml.XmlElement li, int depth) {
        // 查找直接子元素 <a>
        String title = '未命名章节';
        String? href;
        String? anchor;
        for (final a in li.findElements('a')) {
          final t = a.innerText.trim();
          if (t.isNotEmpty) title = t;
          final rawHref = a.getAttribute('href') ?? '';
          final rawPath = rawHref.split('#').first;
          href = rawPath.isEmpty ? null : _resolveEpubPath(baseDir, rawPath);
          anchor = _extractFragmentId(rawHref);
          break;
        }

        // 嵌套 <ol>（li > ol > li*）
        final children = <EpubChapter>[];
        for (final nestedOl in li.findElements('ol')) {
          for (final childLi in nestedOl.findElements('li')) {
            children.add(parseLi(childLi, depth + 1));
          }
        }

        final spineIdx = href != null && href.isNotEmpty
            ? (spineIndexByHref[href] ?? -1)
            : -1;

        return EpubChapter(
          index: -1,
          title: title,
          href: href,
          anchor: anchor,
          startFragmentId: anchor,
          isVolume: depth == 0 && children.isNotEmpty,
          spineIndex: spineIdx,
          depth: depth,
          parentId: -1,
          children: children,
        );
      }

      final tree = <EpubChapter>[];
      // 找 tocNav 下的第一个 ol
      xml.XmlElement? ol;
      for (final olEl in tocNav.findElements('ol')) {
        ol = olEl;
        break;
      }
      debugPrint('[EPUB诊断-NAV] 顶层ol存在=${ol != null}');
      if (ol != null) {
        final liList = ol.findElements('li').toList();
        debugPrint('[EPUB诊断-NAV] 顶层li数量=${liList.length}');
        for (final li in liList) {
          tree.add(parseLi(li, 0));
        }
      }
      debugPrint('[EPUB诊断-NAV] 解析完成tree节点数=${tree.length}');
      return tree;
    } catch (e, st) {
      debugPrint('[EPUB诊断-NAV] 解析异常: $e');
      debugPrint('[EPUB诊断-NAV] 异常堆栈: $st');
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

  /// 把 HTML 中的 `<img src="...">` 替换为 base64 data URI
  ///
  /// [files] EPUB ZIP 内文件映射（path -> bytes）
  /// [chapterBasePath] 章节文件所在目录（用于解析相对路径，带末尾 `/`）
  ///
  /// 用于导入时预解析，把 EPUB 内部图片转成 data URI 内嵌到 HTML 里，
  /// 让 WebView 无需再拦截资源请求加载图片。
  static String _inlineImagesInHtml(
    String html,
    Map<String, List<int>> files,
    String? chapterBasePath,
  ) {
    return html.replaceAllMapped(
      RegExp(r'<img\b([^>]*?)src="([^"]+)"([^>]*)>', caseSensitive: false),
      (match) {
        final before = match.group(1) ?? '';
        final src = match.group(2) ?? '';
        final after = match.group(3) ?? '';

        // 已经是 data URI 或 http(s) 链接：不动
        if (src.startsWith('data:') || src.startsWith('http')) {
          return match.group(0)!;
        }

        // 解析相对路径到 EPUB ZIP 内的绝对路径
        final imgPath = _resolveEpubImagePath(src, chapterBasePath);
        final imgBytes = files[imgPath];
        if (imgBytes == null) {
          // 找不到图片：保留原 src（可能是 epub cover-image 等特殊情况）
          return match.group(0)!;
        }

        final mediaType = inferMediaType(imgPath);
        final dataUri = encodeBytesAsDataUri(
          Uint8List.fromList(imgBytes),
          mediaType,
        );
        return '<img$before src="$dataUri"$after>';
      },
    );
  }

  /// 解析 EPUB 内部图片相对路径到 ZIP 内绝对路径
  static String _resolveEpubImagePath(String src, String? chapterBasePath) {
    final path = src.split('#').first;
    if (path.startsWith('/')) return path.substring(1);
    if (chapterBasePath == null || chapterBasePath.isEmpty) return path;
    try {
      final base = Uri.parse(chapterBasePath);
      return base.resolve(path).toString();
    } catch (_) {
      return path;
    }
  }

  /// 把 CSS 中所有 `url(...)` 引用替换为 base64 data URI
  ///
  /// 处理 @font-face、background-image 等 CSS 资源引用。
  /// - [css] 原始 CSS 文本（可能来自多个 .css 文件合并）
  /// - [files] EPUB ZIP 内文件映射
  /// - [cssBasePath] CSS 文件所在目录（用于解析相对路径，如 'OEBPS/Styles/'）
  ///
  /// 注意：CSS 中 url() 路径是相对于 CSS 文件自身的位置，
  /// 不是相对于引用 CSS 的 xhtml 文件。
  /// 多个 CSS 文件合并后，统一用第一个 CSS 文件的目录作为基准
  /// （绝大多数 EPUB 所有 CSS 都在同一目录下）。
  static String _inlineUrlsInCss(
    String css,
    Map<String, List<int>> files,
    String cssBasePath,
  ) {
    return css.replaceAllMapped(
      RegExp(r'''url\(\s*(['"]?)([^'")]+)\1\s*\)''', caseSensitive: false),
      (match) {
        final quote = match.group(1) ?? '';
        final url = match.group(2) ?? '';

        // 已经是 data URI 或 http(s) 链接：不动
        if (url.startsWith('data:') || url.startsWith('http')) {
          return match.group(0)!;
        }

        // 移除查询字符串和锚点
        final cleanUrl = url.split('?').first.split('#').first;
        if (cleanUrl.isEmpty) return match.group(0)!;

        // 解析相对路径到 EPUB ZIP 内的绝对路径
        final resourcePath = _resolveEpubImagePath(cleanUrl, cssBasePath);
        final resourceBytes = files[resourcePath];
        if (resourceBytes == null) {
          // 找不到资源：保留原 url（避免破坏 CSS 语法）
          return match.group(0)!;
        }

        final mediaType = inferMediaType(resourcePath);
        final dataUri = encodeBytesAsDataUri(
          Uint8List.fromList(resourceBytes),
          mediaType,
        );
        return 'url($quote$dataUri$quote)';
      },
    );
  }

  /// 把 CSS 中所有 `url(...)` 引用替换为 file:// 绝对路径
  ///
  /// 与 `_inlineUrlsInCss` 对应，但不做 base64 编码，只把相对路径转为
  /// 指向解压目录的绝对路径，WebView 通过 file:// baseUrl 直接访问原始文件。
  ///
  /// - [css] 原始 CSS 文本
  /// - [extractedBasePath] EPUB 解压根目录绝对路径
  /// - [cssBasePath] CSS 文件在 EPUB 内的目录（如 'OEBPS/Styles/'）
  static String _rewriteCssUrlsToPath(
    String css,
    String extractedBasePath,
    String cssBasePath,
  ) {
    if (extractedBasePath.isEmpty) return css;
    return css.replaceAllMapped(
      RegExp(r'''url\(\s*(['"]?)([^'")]+)\1\s*\)''', caseSensitive: false),
      (match) {
        final quote = match.group(1) ?? '';
        final url = match.group(2) ?? '';

        if (url.startsWith('data:') || url.startsWith('http') ||
            url.startsWith('file://')) {
          return match.group(0)!;
        }

        final cleanUrl = url.split('?').first.split('#').first;
        if (cleanUrl.isEmpty) return match.group(0)!;

        // 解析 EPUB 内绝对路径 → 本地文件系统绝对路径
        final epubPath = _resolveEpubImagePath(cleanUrl, cssBasePath);
        final localPath = _joinPath(extractedBasePath, epubPath);
        return 'url($quote$localPath$quote)';
      },
    );
  }

  /// 把 inline style 属性中的 `url(...)` 替换为 file:// 绝对路径
  static String _rewriteStyleUrlsToPath(
    String attrs,
    String extractedBasePath,
    String? chapterBasePath,
  ) {
    if (attrs.isEmpty || extractedBasePath.isEmpty) return attrs;
    return attrs.replaceAllMapped(
      RegExp(r'style="([^"]*)"'),
      (match) {
        final style = match.group(1) ?? '';
        if (!style.toLowerCase().contains('url(')) return match.group(0)!;
        final rewritten = _rewriteCssUrlsToPath(
          style,
          extractedBasePath,
          chapterBasePath ?? '',
        );
        return 'style="$rewritten"';
      },
    );
  }

  /// 把 HTML 中 `<img src>` / `<source src>` / `<video poster>` /
  /// `<image xlink:href>` 替换为指向解压目录的绝对路径
  static String _rewriteHtmlResourcesToPath(
    String html,
    String extractedBasePath,
    String? chapterBasePath,
  ) {
    if (extractedBasePath.isEmpty) return html;

    String rewriteSrc(String src) {
      if (src.startsWith('data:') || src.startsWith('http') ||
          src.startsWith('file://')) {
        return src;
      }
      final clean = src.split('?').first.split('#').first;
      if (clean.isEmpty) return src;
      final epubPath = _resolveEpubImagePath(clean, chapterBasePath);
      return _joinPath(extractedBasePath, epubPath);
    }

    // <img src>
    var result = html.replaceAllMapped(
      RegExp(r'<img\b([^>]*?)src="([^"]+)"([^>]*)>', caseSensitive: false),
      (m) => '<img${m.group(1)}src="${rewriteSrc(m.group(2) ?? "")}"${m.group(3)}>',
    );
    // <source src>
    result = result.replaceAllMapped(
      RegExp(r'<source\b([^>]*?)src="([^"]+)"([^>]*)>', caseSensitive: false),
      (m) => '<source${m.group(1)}src="${rewriteSrc(m.group(2) ?? "")}"${m.group(3)}>',
    );
    // <video poster>
    result = result.replaceAllMapped(
      RegExp(r'<video\b([^>]*?)\bposter="([^"]+)"([^>]*)>', caseSensitive: false),
      (m) => '<video${m.group(1)}poster="${rewriteSrc(m.group(2) ?? "")}"${m.group(3)}>',
    );
    // <image xlink:href>
    result = result.replaceAllMapped(
      RegExp(r'<image\b([^>]*?)xlink:href="([^"]+)"([^>]*)>', caseSensitive: false),
      (m) => '<image${m.group(1)}xlink:href="${rewriteSrc(m.group(2) ?? "")}"${m.group(3)}>',
    );
    return result;
  }

  /// 拼接解压根目录和 EPUB 内路径，生成 WebView 可访问的绝对路径
  ///
  /// 返回 Unix 风格路径（正斜杠），因为 HTML/CSS 中的 URL 始终用正斜杠。
  /// WebView 会通过 baseUrl 解析相对路径，所以这里返回不带 file:// 前缀的
  /// 绝对路径即可（baseUrl 为 file:// 时，相对/绝对路径都会按文件系统解析）。
  static String _joinPath(String base, String relative) {
    final cleanBase = base.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final cleanRelative = relative.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    return '$cleanBase/$cleanRelative';
  }

  /// 把 inline style 属性中的 `url(...)` 引用替换为 base64 data URI
  ///
  /// 用于处理 `<body style="background: url(../Images/001.jpg) ...">` 这种
  /// 章节级 inline 背景图。body 的 style 属性提取后需要单独处理 url()，
  /// 否则背景图无法在 reader 内显示。
  ///
  /// - [attrs] body 的属性字符串（如 `class="x" style="background:url(...)"`）
  /// - [files] EPUB ZIP 内文件映射
  /// - [chapterBasePath] 章节文件所在目录（用于解析相对路径）
  static String _inlineStyleUrls(
    String attrs,
    Map<String, List<int>> files,
    String? chapterBasePath,
  ) {
    if (attrs.isEmpty) return attrs;
    // 仅处理 style="..." 内部的 url()，其他属性不动
    return attrs.replaceAllMapped(
      RegExp(r'style="([^"]*)"'),
      (match) {
        final style = match.group(1) ?? '';
        if (!style.toLowerCase().contains('url(')) return match.group(0)!;
        final inlinedStyle = _inlineUrlsInCss(style, files, chapterBasePath ?? '');
        return 'style="$inlinedStyle"';
      },
    );
  }

  /// 把 HTML 中视频/音频资源引用替换为 base64 data URI
  ///
  /// 处理两种资源：
  /// - `<source src="...">` 标签（视频/音频源文件，如 mp4/webm/ogg）
  /// - `<video poster="...">` 属性（视频封面图，EPUB 中常见如 wqx.jpg）
  ///
  /// 必须处理 poster 属性，否则 video.xhtml 的封面图会丢失，
  /// 导致视频区域在加载前显示空白。
  ///
  /// 大视频文件（> 10MB）不内嵌，保留原始路径避免内存爆炸
  /// （诡秘之主 wqx.mp4 = 64MB，base64 后 85MB 会 OOM）
  static String _inlineVideoSources(
    String html,
    Map<String, List<int>> files,
    String? chapterBasePath,
  ) {
    /// 单个资源内嵌大小上限（10MB），超过则跳过
    /// 视频/大字体等大文件内嵌会导致内存爆炸
    const maxInlineSize = 10 * 1024 * 1024;

    // 1. 处理 <source src="...">
    var result = html.replaceAllMapped(
      RegExp(r'<source\b([^>]*?)src="([^"]+)"([^>]*)>', caseSensitive: false),
      (match) {
        final before = match.group(1) ?? '';
        final src = match.group(2) ?? '';
        final after = match.group(3) ?? '';

        if (src.startsWith('data:') || src.startsWith('http')) {
          return match.group(0)!;
        }

        final resourcePath = _resolveEpubImagePath(src, chapterBasePath);
        final resourceBytes = files[resourcePath];
        if (resourceBytes == null) return match.group(0)!;
        // 大视频文件不内嵌，避免 OOM
        if (resourceBytes.length > maxInlineSize) return match.group(0)!;

        final mediaType = inferMediaType(resourcePath);
        final dataUri = encodeBytesAsDataUri(
          Uint8List.fromList(resourceBytes),
          mediaType,
        );
        return '<source$before src="$dataUri"$after>';
      },
    );

    // 2. 处理 <video poster="...">
    result = result.replaceAllMapped(
      RegExp(r'<video\b([^>]*?)\bposter="([^"]+)"([^>]*)>', caseSensitive: false),
      (match) {
        final before = match.group(1) ?? '';
        final poster = match.group(2) ?? '';
        final after = match.group(3) ?? '';

        if (poster.startsWith('data:') || poster.startsWith('http')) {
          return match.group(0)!;
        }

        final resourcePath = _resolveEpubImagePath(poster, chapterBasePath);
        final resourceBytes = files[resourcePath];
        if (resourceBytes == null) return match.group(0)!;
        // poster 是图片，通常不大，但仍检查大小
        if (resourceBytes.length > maxInlineSize) return match.group(0)!;

        final mediaType = inferMediaType(resourcePath);
        final dataUri = encodeBytesAsDataUri(
          Uint8List.fromList(resourceBytes),
          mediaType,
        );
        return '<video$before poster="$dataUri"$after>';
      },
    );

    return result;
  }

  /// 把 SVG 中 `<image xlink:href="...">` 替换为 base64 data URI
  ///
  /// EPUB 封面常用 SVG image 标签引用图片：
  /// `<image xlink:href="../Images/cover.jpg" .../>`
  static String _inlineSvgImages(
    String html,
    Map<String, List<int>> files,
    String? chapterBasePath,
  ) {
    return html.replaceAllMapped(
      RegExp(
        r'<image\b([^>]*?)xlink:href="([^"]+)"([^>]*)>',
        caseSensitive: false,
      ),
      (match) {
        final before = match.group(1) ?? '';
        final href = match.group(2) ?? '';
        final after = match.group(3) ?? '';

        if (href.startsWith('data:') || href.startsWith('http')) {
          return match.group(0)!;
        }

        final resourcePath = _resolveEpubImagePath(href, chapterBasePath);
        final resourceBytes = files[resourcePath];
        if (resourceBytes == null) return match.group(0)!;

        final mediaType = inferMediaType(resourcePath);
        final dataUri = encodeBytesAsDataUri(
          Uint8List.fromList(resourceBytes),
          mediaType,
        );
        return '<image$before xlink:href="$dataUri"$after>';
      },
    );
  }

  /// 合并 EPUB 内所有 CSS 文件内容
  ///
  /// 从 ZIP 中查找所有 .css 文件，合并内容返回。
  /// 不区分 manifest 引用关系，简单合并所有 CSS
  /// （EPUB CSS 通常互相独立，合并不会有副作用）。
  /// 在导入时调用一次，所有章节共享同一份 CSS。
  static String _collectAllCss(Map<String, List<int>> files) {
    final cssBuffer = StringBuffer();
    for (final entry in files.entries) {
      final path = entry.key;
      if (path.toLowerCase().endsWith('.css')) {
        final content = decodeBytes(entry.value);
        if (content.isNotEmpty) {
          cssBuffer.writeln('/* === $path === */');
          cssBuffer.writeln(content);
          cssBuffer.writeln();
        }
      }
    }
    return cssBuffer.toString();
  }

  /// 把 EPUB CSS 中的全局选择器改写为 reader 内容容器选择器
  ///
  /// EPUB CSS 中的 `body`/`html` 选择器在 reader 中会作用于整个 `<body>`
  /// （包含 `#reader-root` 布局容器），破坏阅读器布局。例如：
  /// - `body { padding: 0.5em }` → 给整个 reader body 加 padding，内容偏移
  /// - `html { ... }` → 影响 reader html 元素
  ///
  /// 改写规则：
  /// - `body` → `#reader-content-a`（EPUB body 内容实际放入此容器）
  /// - `html` → `#reader-content-a`（同上，html 级样式降级到容器）
  /// - `html body` / `body html` → `#reader-content-a`
  /// - 其他选择器不动
  ///
  /// 注意：仅改写顶层选择器（逗号分隔的选择器组中的每一个），不动组合器
  /// 后代选择器（如 `body p` → `#reader-content-a p`）。
  static String _rewriteCssSelectorsForReader(String css) {
    // 按大括号分块处理每条规则
    final result = StringBuffer();
    var i = 0;
    while (i < css.length) {
      // 找下一个选择器+声明块
      final braceStart = css.indexOf('{', i);
      if (braceStart == -1) {
        result.write(css.substring(i));
        break;
      }
      final braceEnd = css.indexOf('}', braceStart);
      if (braceEnd == -1) {
        result.write(css.substring(i));
        break;
      }

      // 注释块原样保留
      final selectorPart = css.substring(i, braceStart);
      if (selectorPart.contains('/*')) {
        // 找注释结束
        final commentEnd = selectorPart.lastIndexOf('*/');
        if (commentEnd != -1) {
          result.write(selectorPart.substring(0, commentEnd + 2));
          // 处理注释后的选择器
          final afterComment = selectorPart.substring(commentEnd + 2);
          result.write(_rewriteSelectorGroup(afterComment));
        } else {
          // 注释未闭合，原样输出
          result.write(selectorPart);
        }
      } else {
        result.write(_rewriteSelectorGroup(selectorPart));
      }

      // 声明块原样输出
      result.write(css.substring(braceStart, braceEnd + 1));
      i = braceEnd + 1;
    }
    return result.toString();
  }

  /// 改写选择器组（逗号分隔的多个选择器）
  static String _rewriteSelectorGroup(String selectorGroup) {
    // 按逗号分割，但避免匹配属性选择器中的逗号（如 [attr="a,b"]）
    // 简单处理：EPUB CSS 极少有复杂选择器，按顶层逗号分割即可
    final selectors = selectorGroup.split(',');
    final rewritten = <String>[];
    for (final sel in selectors) {
      rewritten.add(_rewriteSingleSelector(sel.trim()));
    }
    return rewritten.join(', ');
  }

  /// 改写单个选择器
  static String _rewriteSingleSelector(String selector) {
    if (selector.isEmpty) return selector;
    // 精确匹配 body / html，或以 body/html 开头的后代选择器
    // body { ... } → #reader-content-a { ... }
    // body p { ... } → #reader-content-a p { ... }
    // html body { ... } → #reader-content-a { ... }
    var s = selector;
    // html body → #reader-content-a
    s = s.replaceAllMapped(
      RegExp(r'^\s*html\s+body\b'),
      (m) => '#reader-content-a${m.group(0)!.substring(m.group(0)!.indexOf('body') + 4)}',
    );
    // body html → #reader-content-a
    s = s.replaceAllMapped(
      RegExp(r'^\s*body\s+html\b'),
      (m) => '#reader-content-a',
    );
    // body → #reader-content-a（独立或后代选择器开头）
    s = s.replaceFirst(RegExp(r'^\s*body\b'), '#reader-content-a');
    // html → #reader-content-a（独立或后代选择器开头）
    s = s.replaceFirst(RegExp(r'^\s*html\b'), '#reader-content-a');
    return s;
  }


  /// 从 EPUB 章节 HTML 中提取 body 内部的 HTML（保留所有 HTML5 标签）。
  ///
  /// 用于富 HTML 渲染：完整保留 EPUB 章节的 HTML5 结构，包括
  /// `<p>/<h1>/<img>/<blockquote>/<ul>/<table>/<svg>/<section>/<article>` 等
  /// 所有标签，让阅读器 WebView 原生渲染 EPUB 排版。
  ///
  /// 不过滤任何标签——HTML5 标准允许 body 内出现 `<style>/<script>` 等，
  /// EPUB 章节可能内联 `<style>` 控制本章节排版，必须保留。
  /// `<script>` 由 WebView 沙盒自行决定是否执行（本地 EPUB 无 XSS 风险）。
  ///
  /// 步骤：
  /// 1. 用 html 包（HTML5 解析器）解析，提取 body 元素
  /// 2. 若没有 body（片段 HTML），返回原始内容
  /// 3. 若有 startFragmentId，截取从该 id 开始的内容
  /// 4. 返回 body innerHTML
  static String extractBodyContent(
    String html, {
    String? startFragmentId,
    String? endFragmentId,
  }) {
    return extractBodyWithAttrs(html, startFragmentId, endFragmentId).$1;
  }

  /// 提取 body innerHTML 及 body 的 class/style/bgcolor 属性
  ///
  /// EPUB 章节的 `<body>` 常带 class/style/bgcolor 设置章节级背景：
  /// - `<body class="video-bg">` → CSS 类（.video-bg 设 background-image）
  /// - `<body class="volume-bg">` → CSS 类（.volume-bg 设 background-color）
  /// - `<body bgcolor="#000">` → HTML4 背景色属性
  /// - `<body style="background: url(../Images/001.jpg) ...">` → inline 背景图
  ///
  /// 这些属性需要在 reader 内保留，否则章节背景样式会丢失。
  /// 返回 (innerHtml, bodyAttrs)，bodyAttrs 是合并后的属性字符串（如
  /// `class="video-bg" style="background-color:#000"`），供外层 wrapper div 使用。
  static (String, String) extractBodyWithAttrs(
    String html,
    String? startFragmentId,
    String? endFragmentId,
  ) {
    try {
      final doc = html_parser.parse(html);
      final body = doc.body;

      // 保留所有 HTML5 标签，包括 <style>/<script>/<svg>/<link> 等
      // EPUB 章节内联的 <style> 是本章节排版的一部分，必须保留
      final String content = body != null ? body.innerHtml : html;

      // 提取 body 的 class / style / bgcolor 属性
      String bodyAttrs = '';
      if (body != null) {
        final parts = <String>[];
        final classAttr = body.attributes['class'];
        if (classAttr != null && classAttr.isNotEmpty) {
          parts.add('class="$classAttr"');
        }
        final styleAttr = body.attributes['style'];
        if (styleAttr != null && styleAttr.isNotEmpty) {
          parts.add('style="$styleAttr"');
        }
        // bgcolor 是 HTML4 属性，转为 inline style 的 background-color
        final bgcolorAttr = body.attributes['bgcolor'];
        if (bgcolorAttr != null && bgcolorAttr.isNotEmpty) {
          if (styleAttr != null && styleAttr.isNotEmpty) {
            // 已有 style：追加 background-color（bgcolor 优先级低，放在前面）
            parts.removeLast();
            parts.add('style="background-color:$bgcolorAttr;$styleAttr"');
          } else {
            parts.add('style="background-color:$bgcolorAttr"');
          }
        }
        bodyAttrs = parts.join(' ');
      }

      // 应用 fragment 切片（NCX/NAV 的 startFragmentId/endFragmentId）
      final String sliced;
      if (startFragmentId != null || endFragmentId != null) {
        sliced = _sliceByFragment(content, startFragmentId, endFragmentId).trim();
      } else {
        sliced = content.trim();
      }

      return (sliced, bodyAttrs);
    } catch (_) {
      return (html, '');
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
