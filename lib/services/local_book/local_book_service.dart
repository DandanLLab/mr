import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../services/storage_service.dart';
import 'epub_parser.dart';
import 'txt_parser.dart';

enum LocalBookType { txt, epub, pdf, unsupported }

class LocalBookService {
  static final LocalBookService instance = LocalBookService._internal();
  LocalBookService._internal();

  final Map<String, EpubBook> _epubCache = {};
  final Map<String, List<TxtChapter>> _txtChapterCache = {};
  final Map<String, String> _contentCache = {};
  final Map<String, Uint8List> _epubBytesCache = {};

  static LocalBookType detectBookType(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'txt':
        return LocalBookType.txt;
      case 'epub':
        return LocalBookType.epub;
      case 'pdf':
        return LocalBookType.pdf;
      default:
        return LocalBookType.unsupported;
    }
  }

  static bool isSupported(String filePath) {
    return detectBookType(filePath) != LocalBookType.unsupported;
  }

  static List<String> get supportedExtensions => ['txt', 'epub'];

  Future<List<Book>> scanDirectory(String directoryPath) async {
    final books = <Book>[];
    final dir = Directory(directoryPath);

    if (!await dir.exists()) return books;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final filePath = entity.path;
        if (isSupported(filePath)) {
          try {
            final bytes = await entity.readAsBytes();
            final book = createBookFromFile(filePath, bytes: bytes);
            books.add(book);
          } catch (e) {
            continue;
          }
        }
      }
    }

    return books;
  }

  Future<Book?> importFile(String filePath) async {
    if (!isSupported(filePath)) return null;

    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      return createBookFromFile(filePath, bytes: bytes);
    } catch (e) {
      return null;
    }
  }

  Book createBookFromFile(String filePath, {Uint8List? bytes}) {
    final bookType = detectBookType(filePath);
    final fileName = filePath.split('/').last.split('\\').last;
    final (name, author) = TxtParser.extractNameAndAuthor(fileName);

    String? coverPath;
    String? description;

    if (bookType == LocalBookType.epub && bytes != null) {
      _epubBytesCache[filePath] = bytes;
      final epubBook = _parseEpubData(bytes);
      if (epubBook != null) {
        _epubCache[filePath] = epubBook;
        return Book(
          bookUrl: filePath,
          name: epubBook.title.isNotEmpty ? epubBook.title : name,
          author: epubBook.author ?? author ?? '',
          coverUrl: epubBook.coverPath ?? '',
          intro: epubBook.description ?? '',
          mediaType: MediaType.novel,
          originType: BookOriginType.local,
          canUpdate: false,
          addedTime: DateTime.now(),
        );
      }
    }

    // For TXT files, extract intro from content
    if (bookType == LocalBookType.txt && bytes != null) {
      final content = TxtParser.decodeBytes(bytes);
      final extractedIntro = TxtParser.extractIntro(content);
      return Book(
        bookUrl: filePath,
        name: name,
        author: author ?? '',
        coverUrl: coverPath ?? '',
        intro: extractedIntro,
        mediaType: MediaType.novel,
        originType: BookOriginType.local,
        canUpdate: false,
        addedTime: DateTime.now(),
      );
    }

    return Book(
      bookUrl: filePath,
      name: name,
      author: author ?? '',
      coverUrl: coverPath ?? '',
      intro: description ?? '',
      mediaType: MediaType.novel,
      originType: BookOriginType.local,
      canUpdate: false,
      addedTime: DateTime.now(),
    );
  }

  Future<List<Chapter>> getChapterList(Book book) async {
    final bookType = detectBookType(book.bookUrl);

    switch (bookType) {
      case LocalBookType.txt:
        return _getTxtChapterList(book);
      case LocalBookType.epub:
        return _getEpubChapterList(book);
      case LocalBookType.pdf:
      case LocalBookType.unsupported:
        return [];
    }
  }

  Future<String?> getContent(Book book, Chapter chapter) async {
    final cacheKey = '${book.bookUrl}_${chapter.index}';
    if (_contentCache.containsKey(cacheKey)) {
      return _contentCache[cacheKey];
    }

    final bookType = detectBookType(book.bookUrl);
    String? content;

    switch (bookType) {
      case LocalBookType.txt:
        content = await _getTxtContent(book, chapter);
        break;
      case LocalBookType.epub:
        content = await _getEpubContent(book, chapter);
        break;
      case LocalBookType.pdf:
      case LocalBookType.unsupported:
        content = null;
    }

    if (content != null) {
      _contentCache[cacheKey] = content;
      if (_contentCache.length > 100) {
        _contentCache.remove(_contentCache.keys.first);
      }
    }

    return content;
  }

  /// Convenience method that loads book data and chapter list together,
  /// ensuring the file is read and parsed if needed.
  Future<(Book, List<Chapter>)> getBookAndChapters(Book book) async {
    final chapters = await getChapterList(book);
    return (book, chapters);
  }

  /// Returns the total word count for a book by reading the file and counting characters.
  Future<int> getWordCount(Book book) async {
    final bookType = detectBookType(book.bookUrl);

    switch (bookType) {
      case LocalBookType.txt:
        return _getTxtWordCount(book);
      case LocalBookType.epub:
        return _getEpubWordCount(book);
      case LocalBookType.pdf:
      case LocalBookType.unsupported:
        return 0;
    }
  }

  Future<List<Chapter>> _getTxtChapterList(Book book) async {
    if (_txtChapterCache.containsKey(book.bookUrl)) {
      return _txtChapterCache[book.bookUrl]!.asMap().entries.map((entry) {
        return Chapter(
          id: '${book.bookUrl}_${entry.key}',
          bookId: book.bookUrl,
          title: entry.value.title,
          index: entry.value.index,
          wordCount: entry.value.wordCount,
        );
      }).toList();
    }

    // Cache miss: read the file from disk, parse, cache, and return
    try {
      final file = File(book.bookUrl);
      if (!await file.exists()) return [];

      final bytes = await file.readAsBytes();
      final content = TxtParser.decodeBytes(bytes);
      final fileName = book.bookUrl.split('/').last.split('\\').last;
      final customRules = TxtParser.loadCustomRules();
      final txtChapters = TxtParser.parse(
        content,
        fileName: fileName,
        customRules: customRules.isNotEmpty ? customRules : null,
      );

      if (txtChapters.isEmpty) return [];

      _txtChapterCache[book.bookUrl] = txtChapters;

      // Auto-extract intro if the book has no intro
      if (book.intro.isEmpty) {
        final extractedIntro = TxtParser.extractIntro(content);
        if (extractedIntro.isNotEmpty) {
          final updatedBook = book.copyWith(intro: extractedIntro);
          await StorageService.instance.saveBook(updatedBook);
        }
      }

      return txtChapters.asMap().entries.map((entry) {
        return Chapter(
          id: '${book.bookUrl}_${entry.key}',
          bookId: book.bookUrl,
          title: entry.value.title,
          index: entry.value.index,
          wordCount: entry.value.wordCount,
        );
      }).toList();
    } catch (e) {
      return [];
    }
  }

  void cacheTxtChapters(String bookUrl, List<TxtChapter> chapters) {
    _txtChapterCache[bookUrl] = chapters;
  }

  Future<String?> _getTxtContent(Book book, Chapter chapter) async {
    var chapters = _txtChapterCache[book.bookUrl];
    // Fallback: ensure chapters are loaded by reading and parsing the file
    if (chapters == null) {
      await _getTxtChapterList(book);
      chapters = _txtChapterCache[book.bookUrl];
    }
    if (chapters == null || chapter.index < 0 || chapter.index >= chapters.length) return null;
    return chapters[chapter.index].content;
  }

  Future<List<Chapter>> _getEpubChapterList(Book book) async {
    var epubBook = _epubCache[book.bookUrl];

    // Fallback: read EPUB from disk if not cached
    if (epubBook == null) {
      try {
        final file = File(book.bookUrl);
        if (!await file.exists()) return [];

        final bytes = await file.readAsBytes();
        _epubBytesCache[book.bookUrl] = bytes;
        epubBook = _parseEpubData(bytes);
        if (epubBook != null) {
          _epubCache[book.bookUrl] = epubBook;
        }
      } catch (e) {
        return [];
      }
    }

    if (epubBook == null) return [];

    return epubBook.chapters.map((epubChapter) {
      return Chapter(
        id: '${book.bookUrl}_${epubChapter.index}',
        bookId: book.bookUrl,
        title: epubChapter.title,
        index: epubChapter.index,
        url: epubChapter.href,
        isVolume: epubChapter.isVolume,
        spineIndex: epubChapter.spineIndex,
        depth: epubChapter.depth,
        parentId: epubChapter.parentId,
      );
    }).toList();
  }

  Future<String?> _getEpubContent(Book book, Chapter chapter) async {
    var epubBook = _epubCache[book.bookUrl];

    // Fallback: ensure epub data is loaded by reading from disk
    if (epubBook == null) {
      try {
        final file = File(book.bookUrl);
        if (!await file.exists()) return null;

        final bytes = await file.readAsBytes();
        _epubBytesCache[book.bookUrl] = bytes;
        epubBook = _parseEpubData(bytes);
        if (epubBook != null) {
          _epubCache[book.bookUrl] = epubBook;
        }
      } catch (e) {
        return null;
      }
    }

    if (epubBook == null) return null;
    if (chapter.index < 0 || chapter.index >= epubBook.chapters.length) return null;

    final epubChapter = epubBook.chapters[chapter.index];
    if (epubChapter.content == null) return null;

    // 富 HTML 渲染：保留 EPUB 原始标签结构（<p>/<h1>/<img>/<blockquote> 等），
    // 把图片转 base64 data URI 内嵌，合并 EPUB 自带 CSS。
    // 返回格式：[[EPUB_CSS]]...[[/EPUB_CSS]][[EPUB_BODY]]...[[/EPUB_BODY]]
    // 由 ReaderHtmlTemplate 解析后分别注入 <style> 和正文区域。
    return _buildEpubRichContent(book, epubChapter);
  }

  /// 构建 EPUB 富 HTML 内容（带排版 + 内嵌图片 + CSS）
  ///
  /// 返回特殊包裹格式，让 ReaderHtmlTemplate 能区分 EPUB CSS 和 body HTML：
  /// [[EPUB_CSS]]<style>...</style>[[/EPUB_CSS]][[EPUB_BODY]]<p>...</p>[[/EPUB_BODY]]
  Future<String> _buildEpubRichContent(
    Book book,
    EpubChapter epubChapter,
  ) async {
    final bytes = await _ensureEpubBytes(book);
    if (bytes == null) {
      // 后备：无法读 ZIP 时退化为纯文本
      return EpubParser.extractTextFromHtml(epubChapter.content!);
    }

    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = <String, List<int>>{};
      for (final file in archive) {
        if (file.isFile) {
          final name = file.name.replaceAll('\\', '/');
          final data = file.content;
          if (data is List<int>) files[name] = data;
        }
      }

      // 1. 提取 body HTML（保留标签结构 + fragment 切片）
      final bodyHtml = EpubParser.extractBodyContent(
        epubChapter.content!,
        startFragmentId: epubChapter.startFragmentId,
        endFragmentId: epubChapter.endFragmentId,
      );

      // 2. 计算章节文件路径（用于解析相对图片路径）
      final chapterHref = epubChapter.href ?? '';
      final chapterPath = chapterHref.split('#').first;
      String? chapterBasePath;
      if (chapterPath.contains('/')) {
        chapterBasePath = chapterPath.substring(0, chapterPath.lastIndexOf('/') + 1);
      }

      // 3. 把 body 中的 <img src="..."> 转成 base64 data URI
      final richBody = _inlineImagesInHtml(bodyHtml, files, chapterBasePath);

      // 4. 合并 EPUB CSS（从 manifest 中收集所有 .css 文件）
      final epubCss = _collectEpubCss(files, epubChapter);

      // 5. 包裹成特殊格式返回
      final cssBlock = epubCss.isNotEmpty
          ? '[[EPUB_CSS]]<style>$epubCss</style>[[/EPUB_CSS]]'
          : '';
      return '$cssBlock[[EPUB_BODY]]$richBody[[/EPUB_BODY]]';
    } catch (_) {
      // 出错时退化为纯文本
      return EpubParser.extractTextFromHtml(epubChapter.content!);
    }
  }

  /// 把 HTML 中的 <img src="..."> 替换为 base64 data URI
  ///
  /// [files] EPUB ZIP 内文件映射（path -> bytes）
  /// [chapterBasePath] 章节文件所在目录（用于解析相对路径）
  String _inlineImagesInHtml(
    String html,
    Map<String, List<int>> files,
    String? chapterBasePath,
  ) {
    // 匹配 <img ... src="..." ...>
    return html.replaceAllMapped(
      RegExp(r'<img\b([^>]*?)src="([^"]+)"([^>]*)>', caseSensitive: false),
      (match) {
        final before = match.group(1) ?? '';
        var src = match.group(2) ?? '';
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

        final mediaType = EpubParser.inferMediaType(imgPath);
        final dataUri = EpubParser.encodeBytesAsDataUri(
          Uint8List.fromList(imgBytes),
          mediaType,
        );
        return '<img$before src="$dataUri"$after>';
      },
    );
  }

  /// 解析 EPUB 内部图片相对路径到 ZIP 内绝对路径
  String _resolveEpubImagePath(String src, String? chapterBasePath) {
    var path = src.split('#').first;
    if (path.startsWith('/')) return path.substring(1);
    if (chapterBasePath == null || chapterBasePath.isEmpty) return path;
    try {
      final base = Uri.parse(chapterBasePath);
      return base.resolve(path).toString();
    } catch (_) {
      return path;
    }
  }

  /// 收集 EPUB 所有 CSS 文件内容并合并
  ///
  /// 从 EPUB ZIP 中查找所有 .css 文件，合并内容返回。
  /// 注：这里不区分 manifest 引用关系，简单合并所有 CSS
  /// （EPUB CSS 通常互相独立，合并不会有副作用）
  String _collectEpubCss(
    Map<String, List<int>> files,
    EpubChapter epubChapter,
  ) {
    final cssBuffer = StringBuffer();
    for (final entry in files.entries) {
      final path = entry.key;
      if (path.toLowerCase().endsWith('.css')) {
        final content = EpubParser.decodeBytes(entry.value);
        if (content.isNotEmpty) {
          cssBuffer.writeln('/* === $path === */');
          cssBuffer.writeln(content);
          cssBuffer.writeln();
        }
      }
    }
    return cssBuffer.toString();
  }

  /// Returns the raw HTML content of an EPUB chapter (not stripped by extractTextFromHtml).
  /// This is needed so the reader can render EPUB content with flutter_html.
  Future<String?> getEpubHtmlContent(Book book, Chapter chapter) async {
    var epubBook = _epubCache[book.bookUrl];

    // Fallback: ensure epub data is loaded by reading from disk
    if (epubBook == null) {
      try {
        final file = File(book.bookUrl);
        if (!await file.exists()) return null;

        final bytes = await file.readAsBytes();
        _epubBytesCache[book.bookUrl] = bytes;
        epubBook = _parseEpubData(bytes);
        if (epubBook != null) {
          _epubCache[book.bookUrl] = epubBook;
        }
      } catch (e) {
        return null;
      }
    }

    if (epubBook == null) return null;
    if (chapter.index < 0 || chapter.index >= epubBook.chapters.length) return null;

    return epubBook.chapters[chapter.index].content;
  }

  /// 获取 EPUB 章节的 HTML 内容，合并所有 CSS，处理图片路径为本地文件路径，
  /// 返回完整的 HTML 文档（包含 CSS 和资源引用）。
  Future<String?> getEpubContentWithStyle(Book book, Chapter chapter) async {
    final bytes = await _ensureEpubBytes(book);
    if (bytes == null) return null;

    var epubBook = _epubCache[book.bookUrl];

    // Fallback: ensure epub data is loaded
    if (epubBook == null) {
      epubBook = _parseEpubData(bytes);
      if (epubBook != null) {
        _epubCache[book.bookUrl] = epubBook;
      }
    }

    if (epubBook == null) return null;
    if (chapter.index < 0 || chapter.index >= epubBook.chapters.length) return null;

    final epubChapter = epubBook.chapters[chapter.index];
    if (epubChapter.content == null) return null;

    // 解析 EPUB ZIP 以获取 CSS 和字体信息
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

      // 读取 OPF 路径
      final containerData = files['META-INF/container.xml'];
      if (containerData == null) return epubChapter.content;

      final containerDoc = html_parser.parse(EpubParser.decodeBytes(containerData));
      String? opfPath;
      for (final el in containerDoc.querySelectorAll('rootfile')) {
        final mediaType = el.attributes['media-type'];
        if (mediaType == null || mediaType == 'application/oebps-package+xml') {
          opfPath = el.attributes['full-path'];
          break;
        }
      }
      if (opfPath == null) return epubChapter.content;

      final opfData = files[opfPath];
      if (opfData == null) return epubChapter.content;

      final opfDoc = html_parser.parse(EpubParser.decodeBytes(opfData));
      final opfBasePath = opfPath.contains('/')
          ? opfPath.substring(0, opfPath.lastIndexOf('/'))
          : '';

      // 解析 manifest
      final manifestElement = opfDoc.querySelector('manifest');
      final manifest = <String, ManifestItem>{};
      if (manifestElement != null) {
        for (final child in manifestElement.children) {
          final local = (child.localName ?? '').toLowerCase();
          if (local == 'item') {
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

      // 获取所有 CSS 内容
      final allCss = EpubParser.getAllCss(files, opfBasePath, manifest);

      // 获取所有字体路径
      final fontPaths = EpubParser.getAllFonts(opfBasePath, manifest);

      // 计算章节的 basePath（用于解析相对路径）
      final chapterHref = epubChapter.href;
      String? basePath;
      if (chapterHref != null) {
        final chapterPath = chapterHref.split('#').first;
        if (chapterPath.contains('/')) {
          basePath = chapterPath.substring(0, chapterPath.lastIndexOf('/') + 1);
        }
      }

      // 使用 extractHtmlWithResources 处理
      return EpubParser.extractHtmlWithResources(
        epubChapter.content!,
        basePath: basePath,
        allCss: allCss,
        fontPaths: fontPaths,
      );
    } catch (e) {
      // 出错时返回原始内容
      return epubChapter.content;
    }
  }

  /// Returns image bytes from within the EPUB ZIP file.
  /// The imagePath is relative to the EPUB root.
  Future<Uint8List?> getEpubImage(Book book, String imagePath) async {
    return _getEpubFileBytes(book, imagePath);
  }

  /// Returns CSS content from within the EPUB ZIP file.
  Future<Map<String, String>?> getEpubCss(Book book, String cssPath) async {
    final bytes = await _ensureEpubBytes(book);
    if (bytes == null) return null;

    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final normalizedPath = cssPath.replaceAll('\\', '/');
      for (final file in archive) {
        if (file.isFile) {
          final name = file.name.replaceAll('\\', '/');
          if (name == normalizedPath) {
            final data = file.content;
            final content = data is List<int> ? String.fromCharCodes(data) : null;
            if (content != null) {
              return {cssPath: content};
            }
          }
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /// Returns a list of font file paths embedded in the EPUB.
  Future<List<String>> getEpubFontList(Book book) async {
    final bytes = await _ensureEpubBytes(book);
    if (bytes == null) return [];

    final fontExtensions = {'.ttf', '.otf', '.woff', '.woff2'};
    final fontPaths = <String>[];

    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        if (file.isFile) {
          final name = file.name.replaceAll('\\', '/');
          final ext = name.split('.').last.toLowerCase();
          if (fontExtensions.contains('.$ext')) {
            fontPaths.add(name);
          }
        }
      }
    } catch (e) {
      return [];
    }
    return fontPaths;
  }

  /// Returns font file bytes from within the EPUB ZIP file.
  Future<Uint8List?> getEpubFont(Book book, String fontPath) async {
    return _getEpubFileBytes(book, fontPath);
  }

  /// Internal helper: get raw bytes of any file inside the EPUB ZIP.
  Future<Uint8List?> _getEpubFileBytes(Book book, String path) async {
    final bytes = await _ensureEpubBytes(book);
    if (bytes == null) return null;

    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final normalizedPath = path.replaceAll('\\', '/');
      for (final file in archive) {
        if (file.isFile) {
          final name = file.name.replaceAll('\\', '/');
          if (name == normalizedPath) {
            final data = file.content;
            if (data is List<int>) {
              return Uint8List.fromList(data);
            }
          }
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /// Ensure EPUB raw bytes are cached. Read from disk if not.
  Future<Uint8List?> _ensureEpubBytes(Book book) async {
    var bytes = _epubBytesCache[book.bookUrl];
    if (bytes != null) return bytes;

    try {
      final file = File(book.bookUrl);
      if (!await file.exists()) return null;

      bytes = await file.readAsBytes();
      _epubBytesCache[book.bookUrl] = bytes;

      // Also parse and cache the EpubBook if not already cached
      if (!_epubCache.containsKey(book.bookUrl)) {
        final epubBook = _parseEpubData(bytes);
        if (epubBook != null) {
          _epubCache[book.bookUrl] = epubBook;
        }
      }

      return bytes;
    } catch (e) {
      return null;
    }
  }

  Future<int> _getTxtWordCount(Book book) async {
    try {
      final chapters = _txtChapterCache[book.bookUrl];
      if (chapters != null) {
        return chapters.fold<int>(0, (sum, ch) => sum + ch.content.length);
      }

      final file = File(book.bookUrl);
      if (!await file.exists()) return 0;

      final bytes = await file.readAsBytes();
      final content = TxtParser.decodeBytes(bytes);
      return content.length;
    } catch (e) {
      return 0;
    }
  }

  Future<int> _getEpubWordCount(Book book) async {
    try {
      var epubBook = _epubCache[book.bookUrl];
      if (epubBook == null) {
        final file = File(book.bookUrl);
        if (!await file.exists()) return 0;

        final bytes = await file.readAsBytes();
        _epubBytesCache[book.bookUrl] = bytes;
        epubBook = _parseEpubData(bytes);
        if (epubBook != null) {
          _epubCache[book.bookUrl] = epubBook;
        }
      }

      if (epubBook == null) return 0;

      int count = 0;
      for (final chapter in epubBook.chapters) {
        if (chapter.content != null) {
          final text = EpubParser.extractTextFromHtml(chapter.content!);
          count += text.length;
        }
      }
      return count;
    } catch (e) {
      return 0;
    }
  }

  EpubBook? _parseEpubData(Uint8List bytes) {
    try {
      final epubBook = EpubParser.parseFromBytes(bytes);
      if (epubBook.title != '未知书名' || epubBook.chapters.isNotEmpty) {
        return epubBook;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  void cacheEpubData(String bookUrl, EpubBook data) {
    _epubCache[bookUrl] = data;
  }

  /// 获取 EPUB 的 spine 项总数（用于 spine 精确进度计算）
  ///
  /// 返回 0 表示非 EPUB 或未加载。阅读器 UI 可据此判断是否显示 spine 进度：
  /// ```
  /// final spineCount = LocalBookService.instance.getEpubSpineCount(book);
  /// if (spineCount > 0) {
  ///   final curSpine = chapters[currentIndex].spineIndex;
  ///   final progress = spineCount > 1 ? curSpine / (spineCount - 1) : 0;
  /// }
  /// ```
  int getEpubSpineCount(Book book) {
    final epubBook = _epubCache[book.bookUrl];
    return epubBook?.spineCount ?? 0;
  }

  void clearCache({String? bookUrl}) {
    if (bookUrl != null) {
      _epubCache.remove(bookUrl);
      _txtChapterCache.remove(bookUrl);
      _epubBytesCache.remove(bookUrl);
      _contentCache.removeWhere((key, _) => key.startsWith(bookUrl));
    } else {
      _epubCache.clear();
      _txtChapterCache.clear();
      _epubBytesCache.clear();
      _contentCache.clear();
    }
  }

  static String formatWordCount(int count) {
    if (count < 1000) return '$count';
    if (count < 10000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '${(count / 10000).toStringAsFixed(1)}万';
  }
}
