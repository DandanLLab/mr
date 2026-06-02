import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as html_dom;

class EpubChapter {
  final int index;
  final String title;
  final String? href;
  String? content;
  final String? startFragmentId;
  String? endFragmentId;
  String? nextUrl;
  final bool isVolume;

  EpubChapter({
    required this.index,
    required this.title,
    this.href,
    this.content,
    this.startFragmentId,
    this.endFragmentId,
    this.nextUrl,
    this.isVolume = false,
  });
}

class EpubBook {
  final String title;
  final String? author;
  final String? description;
  final String? coverPath;
  final List<EpubChapter> chapters;
  final String? language;

  const EpubBook({
    required this.title,
    this.author,
    this.description,
    this.coverPath,
    this.chapters = const [],
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
      List<EpubChapter> chapters = [];

      // 查找 NCX 目录
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

      // 查找 NAV 目录
      String? navHref;
      for (final item in manifest.values) {
        if (item.mediaType == 'application/xhtml+xml' &&
            (item.id.toLowerCase().contains('nav') ||
                item.href.toLowerCase().contains('nav'))) {
          navHref = item.href;
          break;
        }
      }

      // 优先尝试 NCX
      if (ncxHref != null) {
        final ncxPath = _resolveEpubPath(opfBasePath, ncxHref);
        final ncxData = files[ncxPath];
        if (ncxData != null) {
          chapters = _parseNcxToc(decodeBytes(ncxData), opfBasePath);
        }
      }

      // NCX 没有结果则尝试 NAV
      if (chapters.isEmpty && navHref != null) {
        final navPath = _resolveEpubPath(opfBasePath, navHref);
        final navData = files[navPath];
        if (navData != null) {
          chapters = _parseNavToc(decodeBytes(navData), opfBasePath);
        }
      }

      // 后备：使用 spine 条目
      if (chapters.isEmpty) {
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
            chapters.add(EpubChapter(
              index: index,
              title: index == 0 ? '封面' : '第$index章',
              href: href,
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

      // 设置 nextUrl
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

  /// 解析 NCX 格式目录
  static List<EpubChapter> _parseNcxToc(
      String ncxXml, String opfBasePath) {
    final chapters = <EpubChapter>[];
    try {
      final doc = html_parser.parse(ncxXml);
      final navMap = doc.querySelector('navMap');
      if (navMap == null) return chapters;

      void parseNavPoint(html_dom.Element navPoint, bool isTopLevel) {
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
        var href = src.split('#').first;
        href = _resolveEpubPath(opfBasePath, href);
        final startFragmentId = _extractFragmentId(src);

        // 检查子 navPoint
        final childNavPoints = <html_dom.Element>[];
        for (final e in navPoint.children) {
          if (_localName(e) == 'navpoint') {
            childNavPoints.add(e);
          }
        }

        if (chapters.isNotEmpty) {
          chapters.last.endFragmentId = startFragmentId;
        }

        chapters.add(EpubChapter(
          index: chapters.length,
          title: (title != null && title.isNotEmpty)
              ? title
              : '第${chapters.length + 1}章',
          href: href,
          startFragmentId: startFragmentId,
          isVolume: isTopLevel && childNavPoints.isNotEmpty,
        ));

        for (final child in childNavPoints) {
          parseNavPoint(child, false);
        }
      }

      for (final navPoint in navMap.children) {
        if (_localName(navPoint) == 'navpoint') {
          parseNavPoint(navPoint, true);
        }
      }
    } catch (e) {
      // 返回已解析的部分
    }
    return chapters;
  }

  /// 解析 NAV 格式目录
  static List<EpubChapter> _parseNavToc(
      String navXml, String opfBasePath) {
    final chapters = <EpubChapter>[];
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

      if (tocNav == null) return chapters;

      void parseOl(html_dom.Element ol, bool isTopLevel) {
        for (final li in ol.children) {
          if (_localName(li) != 'li') continue;

          // 查找直接子元素 <a>
          html_dom.Element? a;
          for (final child in li.children) {
            if (_localName(child) == 'a') {
              a = child;
              break;
            }
          }

          if (a != null) {
            final href = a.attributes['href'] ?? '';
            final title = a.text.trim();
            final startFragmentId = _extractFragmentId(href);
            final resolvedHref =
                _resolveEpubPath(opfBasePath, href.split('#').first);

            // 检查嵌套 <ol>
            html_dom.Element? nestedOl;
            for (final child in li.children) {
              if (_localName(child) == 'ol') {
                nestedOl = child;
                break;
              }
            }

            if (chapters.isNotEmpty) {
              chapters.last.endFragmentId = startFragmentId;
            }

            chapters.add(EpubChapter(
              index: chapters.length,
              title: title.isNotEmpty ? title : '第${chapters.length + 1}章',
              href: resolvedHref,
              startFragmentId: startFragmentId,
              isVolume: isTopLevel && nestedOl != null,
            ));

            if (nestedOl != null) {
              parseOl(nestedOl, false);
            }
          }
        }
      }

      final ol = tocNav.querySelector('ol');
      if (ol != null) {
        parseOl(ol, true);
      }
    } catch (e) {
      // 返回已解析的部分
    }
    return chapters;
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
