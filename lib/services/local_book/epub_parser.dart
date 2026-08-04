import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import 'epub/epub.dart' as epub_core;
import 'epub_css_processor.dart';

/// TOC 条目到章节的映射中间结构（对齐 JRead TocChapterEntry）
class _TocChapterEntry {
  final int spineOrder;
  final int tocOrder;
  final String? cleanHref;
  final EpubChapter chapter;
  const _TocChapterEntry({
    required this.spineOrder,
    required this.tocOrder,
    this.cleanHref,
    required this.chapter,
  });
}

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

  /// 章节内容模式（对齐 JRead EpubWebContentMode）
  ///
  /// 决定阅读器渲染方式：
  /// - [epub_core.EpubContentMode.reflowable]：流式布局，column-width 分栏翻页
  /// - [epub_core.EpubContentMode.fixedLayout]：固定布局，单页不切分（画册/漫画/SVG）
  /// - [epub_core.EpubContentMode.mediaPage]：纯媒体页，单页不切分（纯图片章节）
  ///
  /// 在 `_buildChapters` 时基于 spine rendition + manifest mediaType 初步识别，
  /// 读取章节 HTML 后用 `EpubViewportParser.looksLikeFixedLayout` 兜底升级。
  epub_core.EpubContentMode contentMode;

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
    this.contentMode = epub_core.EpubContentMode.reflowable,
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
        contentMode: node.contentMode,
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

      // 4. 构建章节列表（对齐 lumina + JRead buildChapters）
      //
      // lumina 对齐点：
      // - spineIndexMap（path → spine index）用于 TocItem → spine 映射
      // - 去重：parent href == first child href → parent 标记为卷标题（无独立内容）
      //
      // JRead buildChapters 对齐点：
      // - isReadableHref：排除 nav/ncx/toc 等非内容文件
      // - readableSpine：只保留 linear 且 readable 的 spine 项
      // - skip: 前缀：卷标题无独立资源时用 skip: 标记（翻页时跳到下一真实章节）
      // - normalizeChapters：设置 index/endFragmentId/nextUrl 链
      // - 封面自动生成：coverHref 是图片时自动加封面章节
      final chapters = _buildChapters(archiveReader, pkg);

      debugPrint('[EPUB诊断-OPF] manifest解析: ${pkg.manifest.length} 项');
      debugPrint('[EPUB诊断-OPF] spine解析: ${pkg.spine.length} 项');
      debugPrint('[EPUB诊断] chapters数量=${chapters.length}');
      if (chapters.isNotEmpty) {
        debugPrint('[EPUB诊断] 第1章: title=${chapters[0].title} href=${chapters[0].href} isVolume=${chapters[0].isVolume}');
      }

      // 9. 从 ZIP 中读取章节内容 + 兜底识别 fixed-layout
      for (final chapter in chapters) {
        if (chapter.href != null && !chapter.href!.startsWith('skip:')) {
          final contentPath = chapter.href!.split('#').first;
          final contentData = files[contentPath];
          if (contentData != null) {
            chapter.content = decodeBytes(contentData);

            // 兜底识别 fixed-layout（对齐 JRead EpubViewportParser.looksLikeFixedLayout）
            // 只对 reflowable 章节做升级（mediaPage/fixedLayout 已确定不切分）
            if (chapter.contentMode == epub_core.EpubContentMode.reflowable &&
                chapter.content != null) {
              final viewport = epub_core.EpubViewportParser.parse(
                chapter.content!,
                fallbackWidth: pkg.rendition.viewportWidth,
                fallbackHeight: pkg.rendition.viewportHeight,
              );
              if (epub_core.EpubViewportParser.looksLikeFixedLayout(
                  chapter.content!, viewport)) {
                chapter.contentMode = epub_core.EpubContentMode.fixedLayout;
              }
            }
          }
        }
      }

      // 9.5 预解析所有章节的富 HTML 内容（导入时一次性完成）
      //
      // 对齐 JRead EpubPublisherStyles.inline()：每章节独立内联 CSS
      // - 解析章节 HTML 中的 <link rel="stylesheet">
      // - 递归展开 @import（防环、防炸）
      // - url() 由 urlRewriter 重写为本地路径或 base64
      // - 结构化 CSS 处理（@media 拍平 + shorthand 展开 + selector 净化等）
      //
      // 与旧方案（全局合并 CSS）的区别：
      // - 旧方案：所有章节共享一份 CSS，不同章节用不同 CSS 时会冲突
      // - 新方案：每章节只内联自己引用的 CSS，精准匹配原始排版
      final epub_core.EpubUrlRewriter urlRewriter = extractedBasePath.isNotEmpty
          ? (String cssHref, String url) {
              // 路径模式：url → 本地文件系统绝对路径
              final resolved = epub_core.EpubPath.resolve(cssHref, url);
              final epubPath = epub_core.EpubPath.stripFragment(resolved);
              return _joinPath(extractedBasePath, epubPath);
            }
          : (String cssHref, String url) {
              // base64 模式：url → data URI
              final resolved = epub_core.EpubPath.resolve(cssHref, url);
              final epubPath = epub_core.EpubPath.stripFragment(resolved);
              final resourceBytes = files[epubPath];
              if (resourceBytes == null) return url;
              final mediaType = inferMediaType(epubPath);
              return encodeBytesAsDataUri(
                Uint8List.fromList(resourceBytes),
                mediaType,
              );
            };

      // <style> 提取正则（含原有 <style> 和 EpubPublisherStyles 内联的 <style>）
      final styleRegex = RegExp(
        r'<style\b[^>]*>([\s\S]*?)</style>',
        caseSensitive: false,
      );

      for (final chapter in chapters) {
        if (chapter.content == null) continue;
        try {
          // 1. 计算章节文件路径（EpubPublisherStyles 和 body 资源处理都需要）
          final chapterHref = chapter.href ?? '';
          final chapterPath = chapterHref.split('#').first;
          String? chapterBasePath;
          if (chapterPath.contains('/')) {
            chapterBasePath =
                chapterPath.substring(0, chapterPath.lastIndexOf('/') + 1);
          }

          // 2. 内联出版商 CSS（对齐 JRead EpubPublisherStyles.inline）
          //    把 <link rel="stylesheet"> 替换为 <style>，递归展开 @import
          //    url() 由 urlRewriter 重写为本地路径或 base64
          final inlinedHtml = epub_core.EpubPublisherStyles.inline(
            archiveReader,
            chapterPath,
            chapter.content!,
            urlRewriter: urlRewriter,
          );

          // 3. 提取所有 <style> 内容并做结构化处理
          //    含原有 <style> 和 EpubPublisherStyles 内联的 <style>
          //    结构化处理：@media 拍平 + shorthand 展开 + selector 净化等
          final rawCss = styleRegex
              .allMatches(inlinedHtml)
              .map((m) => m.group(1) ?? '')
              .join('\n');
          final chapterCss = _processEpubCssStructured(rawCss);

          // 4. 提取 body HTML + body 属性（class/style/bgcolor）
          //    body 属性包含章节级背景设置（如 .video-bg 背景图、bgcolor 背景色），
          //    必须保留并应用到 reader 内容容器，否则背景样式丢失
          final (bodyHtml, bodyAttrs) = extractBodyWithAttrs(
            chapter.content!,
            chapter.startFragmentId,
            chapter.endFragmentId,
          );

          // 5. 处理 body 中的所有资源引用：
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

          // 7. 用 wrapper div 包裹 body 内容，把 body 的 class/style 应用到 div
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

          // 8. 生成 richContent（CSS + body）
          //    每章节独立内联 CSS，对齐 JRead 渲染方式
          final cssBlock = chapterCss.isNotEmpty
              ? '[[EPUB_CSS]]<style>$chapterCss</style>[[/EPUB_CSS]]'
              : '';
          chapter.richContent = '$cssBlock[[EPUB_BODY]]$wrappedBody[[/EPUB_BODY]]';
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
        tocTree: const [], // 当前 _buildChapters 返回扁平列表，树状目录待后续构建
        spineCount: pkg.spine.length,
        language: language,
        extractedBasePath: extractedBasePath,
        inlinedCss: '', // CSS 已内联到每章节 richContent 中
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

  /// 构建章节列表（对齐 JRead buildChapters + lumina 去重）
  ///
  /// 核心流程：
  /// 1. 解析 TOC（EpubTocParser 三级回退：nav → NCX → spine）
  /// 2. 构建 spineOrder 映射（cleanHref → 顺序索引）
  /// 3. 递归遍历 TOC 树，每项映射到 spine 位置：
  ///    - href 在 spine 中 → 真实章节
  ///    - href 不在 spine 中但有子项在 → skip: 卷标题（lumina 去重：parent href == first child href 也标记为 skip:）
  ///    - 都不在 → 丢弃
  /// 4. 按 spine 顺序排序，spine 中无 TOC 覆盖的项补 "Chapter N" 占位
  /// 5. 封面自动生成（coverHref 是图片时）
  /// 6. normalizeChapters：设置 index/endFragmentId/nextUrl 链
  static List<EpubChapter> _buildChapters(
    epub_core.EpubArchiveReader archiveReader,
    epub_core.EpubPackage pkg,
  ) {
    final tocItems = epub_core.EpubTocParser.parse(archiveReader, pkg);

    // 预计算辅助值
    final navHref = pkg.navHref != null
        ? epub_core.EpubPath.stripFragment(pkg.navHref!)
        : null;
    final ncxHref = pkg.ncxHref != null
        ? epub_core.EpubPath.stripFragment(pkg.ncxHref!)
        : null;
    final coverHref = pkg.coverHref != null
        ? epub_core.EpubPath.stripFragment(pkg.coverHref!)
        : null;
    const coverDocumentNames = {'cover.xhtml', 'cover.html', 'cover.htm'};

    // 判断 href 是否为图片类型的封面资源
    bool isDirectCoverResource(String href) {
      final clean = epub_core.EpubPath.stripFragment(href);
      if (clean != coverHref) return false;
      return pkg.manifest.values.any((item) =>
          epub_core.EpubPath.stripFragment(item.href) == clean &&
          item.mediaType.toLowerCase().startsWith('image/'));
    }

    // 判断 href 是否为可读内容（排除 nav/ncx/toc 等导航文件）
    bool isReadableHref(String href) {
      final clean = epub_core.EpubPath.stripFragment(href);
      if (clean.isEmpty) return false;
      if (clean == navHref || clean == ncxHref) return false;
      final fileName = clean.substring(clean.lastIndexOf('/') + 1).toLowerCase();
      if (const {'nav.xhtml', 'nav.html', 'nav.htm',
                 'toc.xhtml', 'toc.html', 'toc.htm'}.contains(fileName)) {
        return false;
      }
      return true;
    }

    // 构建 readableSpine + spineOrder 映射
    final readableSpine = pkg.spine
        .where((s) => s.linear && isReadableHref(s.href))
        .toList();
    final spineOrder = <String, int>{};
    for (var i = 0; i < readableSpine.length; i++) {
      spineOrder[epub_core.EpubPath.stripFragment(readableSpine[i].href)] = i;
    }

    // 识别每个 spine item 的内容模式（对齐 JRead resolveContentProfile）
    // - MediaPage：manifest mediaType 是 image/* → 纯图片章节
    // - FixedLayout：spine rendition.layout == prePaginated → 画册/漫画
    // - Reflowable：默认流式布局（兜底启发式识别在读取 HTML 后做）
    epub_core.EpubContentMode resolveContentMode(
        epub_core.EpubSpineItem spineItem) {
      final manifestItem = pkg.manifest[spineItem.idRef];
      if (manifestItem != null) {
        final mediaType = manifestItem.mediaType.toLowerCase();
        if (mediaType.startsWith('image/')) {
          return epub_core.EpubContentMode.mediaPage;
        }
      }
      if (spineItem.rendition.layout ==
          epub_core.EpubRenditionLayout.prePaginated) {
        return epub_core.EpubContentMode.fixedLayout;
      }
      return epub_core.EpubContentMode.reflowable;
    }

    final spineContentModes = readableSpine.map(resolveContentMode).toList();

    // 递归遍历 TOC 树，收集 (spineOrder, tocOrder, chapter) 三元组
    final tocEntries = <_TocChapterEntry>[];
    var tocOrder = 0;

    int? visitToc(epub_core.TocItem item, int depth) {
      final order = tocOrder++;
      int? childFirstOrder;
      for (final child in item.children) {
        final childOrder = visitToc(child, depth + 1);
        if (childOrder != null && (childFirstOrder == null || childOrder < childFirstOrder)) {
          childFirstOrder = childOrder;
        }
      }

      final href = item.href.trim();
      final cleanHref = href.isNotEmpty
          ? epub_core.EpubPath.stripFragment(href)
          : '';
      final hrefOrder = href.isNotEmpty && isReadableHref(href)
          ? (spineOrder[cleanHref] ?? (isDirectCoverResource(href) ? 0 : null))
          : null;
      final placement = hrefOrder ?? childFirstOrder;

      if (placement != null && item.title.isNotEmpty) {
        // lumina 去重：parent href == first child href → 标记为 skip:（卷标题无独立内容）
        final hasChildWithSameHref = item.children.any(
            (c) => epub_core.EpubPath.stripFragment(c.href) == cleanHref && cleanHref.isNotEmpty);

        EpubChapter chapter;
        if (hrefOrder != null && !hasChildWithSameHref) {
          // 真实章节：有独立 spine 资源
          chapter = EpubChapter(
            index: -1,
            title: item.title,
            href: cleanHref,
            anchor: item.fragment,
            startFragmentId: item.fragment,
            isVolume: item.children.isNotEmpty,
            spineIndex: hrefOrder,
            depth: depth,
            parentId: -1,
            children: const [],
            contentMode: spineContentModes[hrefOrder],
          );
        } else {
          // 卷标题：无独立资源（skip:）或与子项共享 href
          chapter = EpubChapter(
            index: -1,
            title: item.title,
            href: 'skip:$order:${cleanHref.isNotEmpty ? cleanHref : item.title}',
            anchor: null,
            startFragmentId: null,
            isVolume: true,
            spineIndex: placement,
            depth: depth,
            parentId: -1,
            children: const [],
          );
        }
        tocEntries.add(_TocChapterEntry(
          spineOrder: placement,
          tocOrder: order,
          cleanHref: hrefOrder != null ? cleanHref : null,
          chapter: chapter,
        ));
      }
      return placement;
    }

    for (final item in tocItems) {
      visitToc(item, 0);
    }

    // 按 spineOrder, tocOrder 排序，分组
    tocEntries.sort((a, b) {
      final cmp = a.spineOrder.compareTo(b.spineOrder);
      return cmp != 0 ? cmp : a.tocOrder.compareTo(b.tocOrder);
    });
    final entriesBySpineOrder = <int, List<_TocChapterEntry>>{};
    for (final entry in tocEntries) {
      entriesBySpineOrder.putIfAbsent(entry.spineOrder, () => []).add(entry);
    }

    // 构建最终章节列表
    final chapters = <EpubChapter>[];
    final addedUrls = <String>{};
    void addChapter(EpubChapter chapter) {
      if (!addedUrls.add(chapter.href ?? '')) return;
      chapters.add(chapter);
    }

    // 封面自动生成
    final hasCoverDocument = readableSpine.any((s) {
      final name = epub_core.EpubPath.stripFragment(s.href)
          .substring(epub_core.EpubPath.stripFragment(s.href).lastIndexOf('/') + 1)
          .toLowerCase();
      return coverDocumentNames.contains(name);
    });
    if (coverHref != null && isDirectCoverResource(coverHref) && !hasCoverDocument) {
      addChapter(EpubChapter(
        index: -1,
        title: '封面',
        href: coverHref,
        spineIndex: 0,
        contentMode: epub_core.EpubContentMode.mediaPage,
      ));
    }

    if (readableSpine.isNotEmpty) {
      for (var order = 0; order < readableSpine.length; order++) {
        final spineItem = readableSpine[order];
        final cleanHref = epub_core.EpubPath.stripFragment(spineItem.href);
        final entries = entriesBySpineOrder[order] ?? [];
        for (final entry in entries) {
          addChapter(entry.chapter);
        }
        // spine 项没有 TOC 覆盖 → 补占位章节
        final hasSpineContent = entries.any((e) => e.cleanHref == cleanHref);
        if (!hasSpineContent) {
          addChapter(EpubChapter(
            index: -1,
            title: 'Chapter ${spineItem.index + 1}',
            href: spineItem.href,
            spineIndex: order,
            contentMode: spineContentModes[order],
          ));
        }
      }
    } else {
      // readableSpine 为空：用 flatToc 兜底
      final flatToc = <epub_core.TocItem>[];
      void flatten(epub_core.TocItem item) {
        flatToc.add(item);
        for (final child in item.children) {
          flatten(child);
        }
      }
      for (final item in tocItems) {
        flatten(item);
      }
      for (final item in flatToc) {
        if (item.href.isNotEmpty && isReadableHref(item.href)) {
          final idx = spineOrder[epub_core.EpubPath.stripFragment(item.href)] ?? -1;
          addChapter(EpubChapter(
            index: -1,
            title: item.title.isNotEmpty ? item.title : 'Chapter',
            href: epub_core.EpubPath.stripFragment(item.href),
            anchor: item.fragment,
            startFragmentId: item.fragment,
            isVolume: item.children.isNotEmpty,
            spineIndex: idx,
            contentMode: idx >= 0 ? spineContentModes[idx] : epub_core.EpubContentMode.reflowable,
          ));
        } else if (item.title.isNotEmpty) {
          addChapter(EpubChapter(
            index: -1,
            title: item.title,
            href: 'skip:0:${item.title}',
            isVolume: true,
          ));
        }
      }
    }

    return _normalizeChapters(chapters);
  }

  /// 规范化章节列表（对齐 JRead normalizeChapters）
  ///
  /// - 填充 index（顺序号）
  /// - 设置 endFragmentId = 下一章节的 startFragmentId
  /// - 设置 nextUrl = 下一章节的 href
  /// - 卷标题（skip:）的 endFragmentId/startFragmentId 置空
  /// - 如果卷标题和下一章节指向同一文件，卷标题 url 也改为 skip: 前缀
  static List<EpubChapter> _normalizeChapters(List<EpubChapter> chapters) {
    return chapters.asMap().entries.map((entry) {
      final index = entry.key;
      final chapter = entry.value;
      final next = chapters
          .skip(index + 1)
          .firstWhere((c) => !(c.href ?? '').startsWith('skip:'),
              orElse: () => chapter);

      final isSkip = (chapter.href ?? '').startsWith('skip:');
      final sameAsNext = !isSkip &&
          next != chapter &&
          (next.href ?? '').isNotEmpty &&
          !(next.href ?? '').startsWith('skip:') &&
          epub_core.EpubPath.stripFragment(chapter.href ?? '') ==
              epub_core.EpubPath.stripFragment(next.href ?? '');

      final normalizedUrl = sameAsNext && chapter.isVolume
          ? 'skip:$index:${chapter.href}'
          : chapter.href;
      final isSkipUrl = normalizedUrl != null && normalizedUrl.startsWith('skip:');

      return EpubChapter(
        index: index,
        title: chapter.title,
        href: normalizedUrl,
        content: chapter.content,
        richContent: chapter.richContent,
        anchor: chapter.anchor,
        startFragmentId: isSkipUrl ? null : chapter.startFragmentId,
        endFragmentId: next != chapter ? next.startFragmentId : null,
        nextUrl: next != chapter && !(next.href ?? '').startsWith('skip:') ? next.href : null,
        isVolume: chapter.isVolume || isSkipUrl,
        spineIndex: chapter.spineIndex,
        depth: chapter.depth,
        parentId: chapter.parentId,
        children: chapter.children,
        contentMode: chapter.contentMode,
      );
    }).toList();
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
