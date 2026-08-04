import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import 'epub/epub.dart' as epub_core;
import 'epub_css_processor.dart';

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

      // 2. 用 EpubPackageParser 解析 OPF（一次性获取 metadata/manifest/spine/rendition/navHref/ncxHref/coverHref）
      //
      // 替换旧的手动 container.xml → OPF → metadata/manifest/spine 解析逻辑。
      // EpubPackageParser 内部用 xml 包正确处理 XML 自闭合标签和命名空间，
      // 避免 html_parser 把 <itemref .../> 当作开始标签导致只解析出 1 项的问题。
      final archiveReader = _MapArchiveReader(files);
      final epub_core.EpubPackage pkg;
      try {
        pkg = epub_core.EpubPackageParser.parse(archiveReader);
      } catch (e) {
        debugPrint('[EPUB诊断-OPF] EpubPackageParser 解析失败: $e');
        return const EpubBook(title: '未知书名');
      }

      // 3. 提取元数据（title/author/description/language 来自 EpubPackage.metadata）
      final title = pkg.metadata.title ?? '未知书名';
      final author = pkg.metadata.creator;
      final description = pkg.metadata.description;
      final language = pkg.metadata.language;
      // OPF 内封面路径（EpubPackageParser 已综合 EPUB3 properties=cover-image
      // 和 EPUB2 <meta name="cover"> 两种来源）
      final coverPath = pkg.coverHref;
      // OPF 基础目录（保留供旧有 _collectAllCss 等逻辑使用，EpubPackageParser
      // 内部已用 EpubPath.resolve 把 manifest href 解析为绝对路径）
      final opfBasePath = pkg.opfPath.contains('/')
          ? pkg.opfPath.substring(0, pkg.opfPath.lastIndexOf('/'))
          : '';

      // 4. 构建 spineIndexByHref 映射：EPUB 绝对路径 → spine 顺序索引
      //
      // EpubPackage.spine 中每个 EpubSpineItem.href 已是 EPUB 绝对路径
      // （EpubPackageParser 解析时用 EpubPath.resolve(opfPath, item.href) 得到），
      // 可直接建立 href → index 映射，供后续 EpubChapter.spineIndex 反查。
      final spineIndexByHref = <String, int>{};
      for (int i = 0; i < pkg.spine.length; i++) {
        final href = pkg.spine[i].href;
        if (href.isNotEmpty) {
          spineIndexByHref[href] = i;
        }
      }

      debugPrint('[EPUB诊断-OPF] manifest解析: ${pkg.manifest.length} 项');
      debugPrint('[EPUB诊断-OPF] spine解析: ${pkg.spine.length} 项');
      debugPrint('[EPUB诊断] opfBasePath=$opfBasePath');
      debugPrint(
          '[EPUB诊断] spine数量=${pkg.spine.length} '
          'items=${pkg.spine.map((s) => s.idRef).join(",")}');
      debugPrint('[EPUB诊断] manifest数量=${pkg.manifest.length}');
      debugPrint('[EPUB诊断] spineIndexByHref=$spineIndexByHref');
      debugPrint('[EPUB诊断] files路径列表=${files.keys.toList()}');
      debugPrint('[EPUB诊断] 最终ncxHref=${pkg.ncxHref} navHref=${pkg.navHref}');

      // 5. 解析目录（用 EpubTocParser 替换旧的手动 NAV/NCX 解析）
      //
      // EpubTocParser 三级回退：
      // 1) EPUB3 nav（pkg.navHref）
      // 2) EPUB2 NCX（pkg.ncxHref）
      // 3) spine 占位
      //
      // 返回 List<TocItem> 树状结构，转换为 EpubChapter 树后扁平化得到 chapters。
      final tocItems = epub_core.EpubTocParser.parse(archiveReader, pkg);
      final tocTree = _convertTocItemsToChapters(tocItems, spineIndexByHref);

      List<EpubChapter> chapters;
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
        for (final spineItem in pkg.spine) {
          final href = spineItem.href;
          if (href.isEmpty) continue;
          // 跳过非内容条目（toc/nav 文件）
          final lowerHref = href.toLowerCase();
          if (lowerHref.contains('toc') || lowerHref.contains('nav')) {
            continue;
          }
          final index = chapters.length;
          final spineIdx = spineIndexByHref[href] ?? -1;
          chapters.add(EpubChapter(
            index: index,
            title: index == 0 ? '封面' : '第$index章',
            href: href,
            spineIndex: spineIdx,
          ));
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
      // 1. 结构化 CSS 处理（移植自 JRead/Legado EpubCss.kt）
      //    - @media/@supports 拍平
      //    - 选择器净化（剥离 :hover 等不支持伪类，命名空间归一化）
      //    - shorthand 展开（font/margin/padding/border/background 等）
      //    - supportedProperties 白名单过滤
      //    - body/html 选择器改写为 #reader-content-a
      //    - reader 特有值改写（百分比 margin→calc、固定宽度→响应式等）
      //    一次性完成，避免旧方案多次正则扫描的遗漏
      final epubCss = _processEpubCssStructured(rawCss);
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
        spineCount: pkg.spine.length,
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
  ///
  /// 用 EpubPackageParser 解析 OPF 获取 coverHref（已综合 EPUB3 properties=cover-image
  /// 和 EPUB2 <meta name="cover"> 两种来源），再从 ZIP 中读取对应文件字节。
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

      final archiveReader = _MapArchiveReader(files);
      final epub_core.EpubPackage pkg;
      try {
        pkg = epub_core.EpubPackageParser.parse(archiveReader);
      } catch (_) {
        return null;
      }

      final coverHref = pkg.coverHref;
      if (coverHref == null || coverHref.isEmpty) return null;

      final coverData = archiveReader.readBytes(coverHref);
      return Uint8List.fromList(coverData);
    } catch (e) {
      return null;
    }
  }

  /// 把 [epub_core.TocItem] 树转换为 [EpubChapter] 树
  ///
  /// 递归遍历 TocItem 列表，对每个节点：
  /// - 从 href 中剥离 fragment 作为 EpubChapter.href（spineIndexByHref 的 key
  ///   是不含 fragment 的 EPUB 绝对路径）
  /// - fragment 作为 anchor/startFragmentId
  /// - 通过 spineIndexByHref 反查 OPF spine 顺序索引填充 spineIndex
  /// - depth 记录嵌套层级（0=顶层）
  /// - isVolume：顶层且有子节点（卷头标记）
  /// - index/parentId 保持 -1，由 [EpubChapter.flatten] 填充
  ///
  /// 注意：TocItem.href 是 EpubPath.resolve 后的路径，含 fragment，
  /// 必须用 [epub_core.EpubPath.stripFragment] 剥离后再赋给 EpubChapter.href。
  static List<EpubChapter> _convertTocItemsToChapters(
    List<epub_core.TocItem> items,
    Map<String, int> spineIndexByHref, {
    int depth = 0,
  }) {
    final result = <EpubChapter>[];
    for (final item in items) {
      // TocItem.href 可能含 fragment，剥离后用于 spineIndex 查找和 EpubChapter.href
      final hrefNoFrag = item.href.isEmpty
          ? null
          : epub_core.EpubPath.stripFragment(item.href);
      final anchor = item.fragment;
      final spineIdx = hrefNoFrag != null && hrefNoFrag.isNotEmpty
          ? (spineIndexByHref[hrefNoFrag] ?? -1)
          : -1;

      final children = _convertTocItemsToChapters(
        item.children,
        spineIndexByHref,
        depth: depth + 1,
      );

      result.add(EpubChapter(
        index: -1,
        title: item.title,
        href: hrefNoFrag,
        anchor: anchor,
        startFragmentId: anchor,
        isVolume: depth == 0 && children.isNotEmpty,
        spineIndex: spineIdx,
        depth: depth,
        parentId: -1,
        children: children,
      ));
    }
    return result;
  }

  /// 解析 EPUB 内部相对路径
  ///
  /// 仅供 [getAllCss]/[getAllFonts] 等保留的旧 API 使用：basePath 是 OPF
  /// 所在目录（不带文件名），relativePath 是 manifest 中的相对 href。
  /// 新代码请用 `epub_core.EpubPath.resolve`（basePath 是文件完整路径）。
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
  /// 收集 EPUB 内所有 CSS 并合并为一份
  ///
  /// 移植自 JRead/Legado EpubPublisherStyles.kt 的 @import 递归展开思路：
  /// - 简单拼接所有 .css 文件会导致 @import 重复加载或失效
  /// - 本方法对每个 CSS 文件递归展开 @import，把被引用的 CSS 内容内联进来
  /// - 防环：用 visited Set 跟踪已处理的 CSS 路径
  /// - 防炸：限制递归深度（MaxImportDepth = 6）
  ///
  /// @import 语法支持：
  /// - `@import url("other.css");`
  /// - `@import "other.css";`
  /// - `@import 'other.css';`
  static String _collectAllCss(Map<String, List<int>> files) {
    final cssBuffer = StringBuffer();
    final processedPaths = <String>{};

    for (final entry in files.entries) {
      final path = entry.key;
      if (path.toLowerCase().endsWith('.css')) {
        final content = decodeBytes(entry.value);
        if (content.isNotEmpty) {
          cssBuffer.writeln('/* === $path === */');
          // 递归展开 @import（防环、防炸）
          final expanded = _expandCssImports(content, path, files, processedPaths, 0);
          cssBuffer.writeln(expanded);
          cssBuffer.writeln();
        }
      }
    }
    return cssBuffer.toString();
  }

  /// 递归展开 CSS 中的 @import 语句
  ///
  /// 移植自 JRead/Legado EpubPublisherStyles.loadCss：
  /// - 匹配 `@import url("...")` / `@import "..."` / `@import '...'` 三种语法
  /// - 跳过外部 URL（http/https）和 data: URI
  /// - 解析相对路径为 EPUB ZIP 内绝对路径
  /// - 递归展开被引用的 CSS（深度限制 MaxImportDepth = 6）
  /// - visited Set 防止循环引用
  /// - 已处理的路径不重复展开（去重）
  static String _expandCssImports(
    String css,
    String cssPath,
    Map<String, List<int>> files,
    Set<String> visited,
    int depth,
  ) {
    if (depth > 6) return css; // MaxImportDepth = 6

    final normalizedPath = _normalizeEpubPath(cssPath);
    if (visited.contains(normalizedPath)) return '';
    visited.add(normalizedPath);

    // 匹配 @import 三种语法：@import url("..."); / @import "..."; / @import '...';
    final importRegex = RegExp(
      r"""@import\s+(?:url\(\s*)?["']([^"']+)["']\s*\)?\s*;""",
      caseSensitive: false,
    );

    return css.replaceAllMapped(importRegex, (match) {
      final importHref = match.group(1)!.trim();
      // 跳过外部 URL 和 data: URI
      if (_isExternalOrDataUrl(importHref)) {
        return match.group(0)!; // 保留原 @import
      }

      // 解析相对路径为 EPUB ZIP 内绝对路径
      final resolvedPath = _resolveEpubCssPath(cssPath, importHref);
      final normalizedResolved = _normalizeEpubPath(resolvedPath);

      // 查找被引用的 CSS 文件
      final cssBytes = files[normalizedResolved];
      if (cssBytes == null) {
        return ''; // 文件不存在，移除 @import
      }

      final importedContent = decodeBytes(cssBytes);
      if (importedContent.isEmpty) {
        return '';
      }

      // 递归展开被引用 CSS 中的 @import
      final recursivelyExpanded = _expandCssImports(
        importedContent,
        normalizedResolved,
        files,
        visited,
        depth + 1,
      );

      return '/* @import $importHref → $normalizedResolved */\n$recursivelyExpanded';
    });
  }

  /// 判断 URL 是否为外部链接或 data: URI
  static bool _isExternalOrDataUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('//') ||
        lower.startsWith('data:');
  }

  /// 规范化 EPUB ZIP 内路径（移除 ./ 和 ../，转为绝对路径）
  static String _normalizeEpubPath(String path) {
    // 移除 fragment（#xxx）
    final p = path.split('#').first;
    // 处理 ./ 和 ../
    final segments = <String>[];
    for (final seg in p.split('/')) {
      if (seg == '.' || seg.isEmpty) continue;
      if (seg == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(seg);
    }
    return segments.join('/');
  }

  /// 解析 EPUB 内 CSS 相对路径（基于当前 CSS 文件路径）
  ///
  /// 例：cssPath = "OEBPS/Styles/main.css", relativeHref = "../Fonts/base.css"
  /// → "OEBPS/Fonts/base.css"
  ///
  /// 与 [_resolveEpubPath] 的区别：本方法专为 CSS @import 设计，
  /// 简单基于目录拼接（CSS 路径都是相对当前文件目录的）。
  static String _resolveEpubCssPath(String cssPath, String relativeHref) {
    final baseDir = cssPath.contains('/')
        ? cssPath.substring(0, cssPath.lastIndexOf('/') + 1)
        : '';
    return baseDir + relativeHref;
  }

  /// 结构化处理 EPUB CSS（移植自 JRead/Legado EpubCss.kt 思路）
  ///
  /// 用 [EpubCssProcessor] 做结构化解析，一次性完成：
  /// 1. 移除注释、@page 规则
  /// 2. @media/@supports 拍平（嵌套规则展开为顶层）
  /// 3. 选择器净化（剥离 :hover 等不支持伪类、命名空间 `|` → `\:`）
  /// 4. shorthand 展开（font/margin/padding/border/background 等七类）
  /// 5. supportedProperties 白名单过滤
  /// 6. body/html 选择器改写为 #reader-content-a
  /// 7. #reader-content-a 布局属性剥离（padding/margin/width/height 等由 reader 框架控制）
  /// 8. reader 特有值改写（百分比 margin→calc、固定宽度→响应式、fixed→scroll 等）
  ///
  /// 与旧正则方案的区别：
  /// - 旧方案：多次正则扫描，margin: 45% auto 20% auto 只替换第一个百分比
  /// - 新方案：先展开 shorthand 为 margin-top/right/bottom/left，再逐属性改写，零遗漏
  static String _processEpubCssStructured(String css) {
    if (css.trim().isEmpty) return css;

    // 0. 预处理：移除 @page 规则（打印分页，reader 无效）
    final preprocessed = css.replaceAll(
      RegExp(r'@page\s*\{[^}]*\}', dotAll: true),
      '',
    );

    // 1-5. 结构化解析（@media 拍平 + 选择器净化 + shorthand 展开 + 白名单过滤）
    final rules = EpubCssProcessor.parseRules(preprocessed);

    // 6. body/html 选择器改写为 #reader-content-a
    // 7. #reader-content-a 布局属性剥离
    // 8. reader 特有值改写
    final processedRules = <EpubCssRule>[];
    for (final rule in rules) {
      final rewrittenSelector = _rewriteSelectorForReader(rule.selector);
      if (rewrittenSelector == null) continue;

      final isReaderContentA = rewrittenSelector.trim() == '#reader-content-a' ||
          rewrittenSelector.trim().startsWith('#reader-content-a ');

      final processedDecls = <EpubCssDeclaration>[];
      for (final decl in rule.declarations) {
        // #reader-content-a：剥离布局属性（padding/margin/width/height/overflow 等）
        // 这些属性由 reader 框架通过 CSS 变量控制，EPUB CSS 不应覆盖
        if (isReaderContentA && _isLayoutProperty(decl.name)) {
          continue;
        }

        // reader 特有值改写
        final rewrittenValue = _rewriteCssValueForReader(decl.name, decl.value);
        if (rewrittenValue == null) continue; // null 表示移除该声明

        processedDecls.add(decl.copyWith(value: rewrittenValue));
      }

      if (processedDecls.isNotEmpty) {
        processedRules.add(EpubCssRule(
          selector: rewrittenSelector,
          declarations: processedDecls,
          specificity: rule.specificity,
          order: rule.order,
        ));
      }
    }

    return EpubCssProcessor.serialize(processedRules);
  }

  /// 改写选择器：body/html → #reader-content-a
  ///
  /// 返回 null 表示该选择器应被丢弃（如净化后为空）。
  /// EpubCssProcessor 已做过伪类剥离和命名空间归一化，这里只做 body/html 替换。
  static String? _rewriteSelectorForReader(String selector) {
    var s = selector.trim();
    if (s.isEmpty) return null;

    // html body → #reader-content-a
    s = s.replaceAllMapped(
      RegExp(r'^html\s+body\b'),
      (m) => '#reader-content-a',
    );
    // body html → #reader-content-a
    s = s.replaceAllMapped(
      RegExp(r'^body\s+html\b'),
      (m) => '#reader-content-a',
    );
    // body → #reader-content-a（独立或后代选择器开头）
    s = s.replaceFirst(RegExp(r'^body\b'), '#reader-content-a');
    // html → #reader-content-a（独立或后代选择器开头）
    s = s.replaceFirst(RegExp(r'^html\b'), '#reader-content-a');

    return s.isEmpty ? null : s;
  }

  /// 判断是否为布局属性（#reader-content-a 需剥离）
  ///
  /// 这些属性会破坏 column 分栏布局：
  /// - padding/margin：让 column 内容区变窄，column-width 与 safe-width 不匹配
  /// - width/height：覆盖 absolute + top/bottom:0 撑满 stage 的布局
  /// - overflow：覆盖分栏裁剪逻辑
  /// - position/top/bottom/left/right：干扰 column 定位
  /// - float/clear/display：破坏文档流
  /// - flex/grid/columns：现代布局，与 column 分栏冲突
  static bool _isLayoutProperty(String name) {
    const layoutProps = {
      'padding', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
      'margin', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
      'width', 'height', 'max-width', 'max-height', 'min-width', 'min-height',
      'overflow', 'overflow-x', 'overflow-y',
      'position', 'top', 'bottom', 'left', 'right',
      'float', 'clear', 'display', 'box-sizing',
      'flex', 'flex-direction', 'flex-wrap', 'flex-grow', 'flex-shrink',
      'flex-basis', 'justify-content', 'align-items', 'align-content', 'align-self',
      'grid', 'grid-template', 'grid-template-columns', 'grid-template-rows',
      'grid-column', 'grid-row', 'gap', 'row-gap', 'column-gap',
      'column-width', 'column-count', 'column-fill', 'column-rule', 'columns',
    };
    return layoutProps.contains(name);
  }

  /// reader 特有的 CSS 值改写
  ///
  /// 对单个声明做值改写，返回 null 表示移除该声明。
  /// 这些改写是 reader column 分栏布局特有的适配，参考实现里没有。
  ///
  /// 改写规则（与旧 _rewriteCssValuesForReader 一致，但作用于结构化后的单条声明）：
  /// 1. 百分比 margin-top/bottom/padding-top/bottom → calc(var(--reader-safe-height) * N / 100)
  /// 2. background-attachment: fixed → scroll
  /// 3. 固定 px 宽度 → 响应式（>200px / <100px 都改为 auto）
  /// 4. position: absolute/fixed → static（relative 保留）
  /// 5. height: 100% / 100vh → auto
  /// 6. float: left/right → none
  /// 7. transform: translate(...) → 移除（保留 scale/rotate）
  /// 8. overflow: hidden → visible
  static String? _rewriteCssValueForReader(String name, String value) {
    final lowerValue = value.toLowerCase();

    // 1. 百分比 margin-top/bottom/padding-top/bottom → calc(safe-height)
    //    CSS 规范：百分比 margin-top/bottom 基于容器宽度，不是高度。
    //    EPUB 原作者假设"一页 = 一屏"，用 45% 做垂直居中（基于页面高度）。
    //    reader column 容器宽度 = 一栏宽度（窄），45% 算出来很小，垂直定位失效。
    //    修正：替换为 calc(var(--reader-safe-height) * N / 100)，还原垂直定位意图。
    if ((name == 'margin-top' || name == 'margin-bottom' ||
         name == 'padding-top' || name == 'padding-bottom') &&
        lowerValue.contains('%')) {
      return value.replaceAllMapped(
        RegExp(r'(\d+(?:\.\d+)?)\s*%'),
        (m) => 'calc(var(--reader-safe-height)*${m.group(1)}/100)',
      );
    }

    // 2. background-attachment: fixed → scroll
    //    column 分栏里 fixed 背景不跟随滚动，行为异常
    if (name == 'background-attachment' && lowerValue == 'fixed') {
      return 'scroll';
    }

    // 3. 固定 px 宽度 → 响应式
    //    - > 200px：大宽度（如 540px 视频），改为 auto（max-width:100% 由 reader 框架默认设置）
    //    - < 100px：窄宽度（如 35px 竖排标题），改为 auto 让文字横排
    //    - 100-200px：中等宽度，保留
    if (name == 'width') {
      final match = RegExp(r'^(\d+(?:\.\d+)?)px$').firstMatch(value.trim());
      if (match != null) {
        final px = double.tryParse(match.group(1) ?? '0') ?? 0;
        if (px > 200) {
          return 'auto';
        } else if (px < 100 && px > 0) {
          return 'auto';
        }
      }
    }

    // 4. position: absolute/fixed → static（relative 保留）
    //    EPUB 用绝对定位放装饰元素（假设单页），column 里会飘到错误栏
    if (name == 'position' && (lowerValue == 'absolute' || lowerValue == 'fixed')) {
      return 'static';
    }

    // 5. height: 100% / 100vh / 100svh / 100dvh / 100lvh → auto
    //    #reader-content-a 高度由 column 动态分栏，固定高度会破坏分栏
    if ((name == 'height' || name == 'max-height') &&
        RegExp(r'^100(%|vh|svh|dvh|lvh)$', caseSensitive: false).hasMatch(value.trim())) {
      return name == 'height' ? 'auto' : 'none';
    }

    // 6. float: left/right → none
    //    float 在 column 分栏里会跨栏错位
    if (name == 'float' && (lowerValue == 'left' || lowerValue == 'right')) {
      return 'none';
    }

    // 7. transform: translate(...) → 移除整个 transform
    //    保留 scale/rotate（不影响布局定位）
    if (name == 'transform' &&
        RegExp(r'^translate', caseSensitive: false).hasMatch(value.trim())) {
      return null; // 返回 null 移除该声明
    }

    // 8. overflow: hidden → visible（防裁剪分栏内容）
    if ((name == 'overflow' || name == 'overflow-x' || name == 'overflow-y') &&
        lowerValue == 'hidden') {
      return 'visible';
    }

    return value;
  }

  /// 提取 body innerHTML
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

/// 把 `Map<String, List<int>>`（ZIP 解压后的文件映射）适配为 [epub_core.EpubArchiveReader]
///
/// EpubPackageParser/EpubTocParser/EpubPublisherStyles 等新模块都基于
/// EpubArchiveReader 抽象接口工作，本适配器让旧的 Map 数据结构无需改造即可接入。
///
/// 路径匹配策略：先精确匹配，再大小写不敏感匹配。
/// EPUB 内文件路径大小写敏感性因生产工具而异（Windows 工具常忽略大小写，
/// macOS/Linux 工具严格区分），双策略兼顾两种情况。
class _MapArchiveReader implements epub_core.EpubArchiveReader {
  final Map<String, List<int>> _files;

  _MapArchiveReader(this._files);

  @override
  bool exists(String path) {
    if (_files.containsKey(path)) return true;
    final lower = path.toLowerCase();
    return _files.keys.any((k) => k.toLowerCase() == lower);
  }

  @override
  List<String> list() => _files.keys.toList();

  @override
  List<int> readBytes(String path) {
    // 先精确匹配
    final data = _files[path];
    if (data != null) return data;
    // 大小写不敏感匹配
    final lower = path.toLowerCase();
    for (final entry in _files.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    throw StateError('File not found: $path');
  }

  @override
  String readText(String path) {
    final bytes = readBytes(path);
    return EpubParser.decodeBytes(bytes);
  }
}
