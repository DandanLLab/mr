import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../services/storage_service.dart';
import 'epub_parser.dart';
import 'txt_parser.dart';

enum LocalBookType { txt, epub, pdf, unsupported }

/// 导入日志级别（参考 lumina ProgressLogType）
enum ImportLogLevel { info, warning, error, success }

/// 导入日志条目（参考 lumina ProgressLog）
class ImportLogEntry {
  final String message;
  final ImportLogLevel level;
  final DateTime timestamp;

  ImportLogEntry({
    required this.message,
    required this.level,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// 导入进度控制器
///
/// 用 StreamController 向 UI 实时推送导入日志，
/// UI 通过 [stream] 订阅日志，在进度对话框中实时显示。
/// 参考 lumina 的 Stream<ProgressLog> 设计。
class ImportProgressController {
  final StreamController<ImportLogEntry> _controller =
      StreamController<ImportLogEntry>.broadcast();

  Stream<ImportLogEntry> get stream => _controller.stream;

  void add(ImportLogEntry entry) {
    if (!_controller.isClosed) {
      _controller.add(entry);
    }
  }

  void close() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  bool get isClosed => _controller.isClosed;
}

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

  /// 导入进度日志条目
  ///
  /// 参考 lumina ProgressLog 设计，用于导入时向 UI 实时反馈解析过程
  static void _log(
    ImportProgressController? controller,
    String message, {
    ImportLogLevel level = ImportLogLevel.info,
  }) {
    debugPrint('[EPUB导入] $message');
    controller?.add(ImportLogEntry(message: message, level: level));
  }

  /// 带进度回调的导入方法（参考 lumina importPipelineStream）
  ///
  /// [controller] 进度控制器，导入过程中实时推送日志条目到 UI
  /// - 读取文件 → 解析 EPUB → 预生成富 HTML → 返回 Book
  /// - 全程通过 controller 推送进度日志，UI 可订阅显示
  Future<Book?> importFileWithProgress(
    String filePath, {
    ImportProgressController? controller,
  }) async {
    final fileName = filePath.split('/').last.split('\\').last;

    _log(controller, '开始处理: $fileName');

    if (!isSupported(filePath)) {
      _log(controller, '不支持的文件类型: $fileName', level: ImportLogLevel.error);
      return null;
    }

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _log(controller, '文件不存在: $filePath', level: ImportLogLevel.error);
        return null;
      }

      _log(controller, '读取文件: $fileName');
      final bytes = await file.readAsBytes();
      _log(controller, '文件大小: ${(bytes.length / 1024).toStringAsFixed(1)} KB');

      final bookType = detectBookType(filePath);
      if (bookType == LocalBookType.epub) {
        _log(controller, '解析 EPUB 结构...');
        _epubBytesCache[filePath] = bytes;
        final epubBook = _parseEpubData(bytes);
        if (epubBook == null) {
          _log(controller, 'EPUB 解析失败', level: ImportLogLevel.error);
          return null;
        }
        _epubCache[filePath] = epubBook;

        _log(
          controller,
          '解析完成: 《${epubBook.title}》'
          '（${epubBook.chapters.length} 章，'
          '${epubBook.spineCount} spine 项）',
          level: ImportLogLevel.success,
        );

        if (epubBook.chapters.isEmpty) {
          _log(controller, '警告：章节列表为空', level: ImportLogLevel.warning);
        }

        final (_, author) = TxtParser.extractNameAndAuthor(fileName);
        return Book(
          bookUrl: filePath,
          name: epubBook.title.isNotEmpty ? epubBook.title : fileName,
          author: epubBook.author ?? author ?? '',
          coverUrl: epubBook.coverPath ?? '',
          intro: epubBook.description ?? '',
          mediaType: MediaType.novel,
          originType: BookOriginType.local,
          canUpdate: false,
          addedTime: DateTime.now(),
        );
      }

      // TXT 等其他类型：走原流程
      _log(controller, '创建书籍元数据...');
      final book = createBookFromFile(filePath, bytes: bytes);
      _log(controller, '导入成功: 《${book.name}》', level: ImportLogLevel.success);
      return book;
    } catch (e, st) {
      _log(controller, '导入异常: $e', level: ImportLogLevel.error);
      debugPrint('[EPUB导入] 异常堆栈: $st');
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

    // 直接返回导入时预解析好的富 HTML 内容
    // richContent 只包含 body HTML（[[EPUB_BODY]]...[[/EPUB_BODY]]），
    // CSS 由 EpubBook.inlinedCss 书籍级单份存储，返回时拼接避免每章节重复 14MB CSS
    if (epubChapter.richContent != null) {
      // 拼接 CSS + body：CSS 只有一份（含字体 base64），body 每章节独立
      final cssBlock = epubBook.inlinedCss.isNotEmpty
          ? '[[EPUB_CSS]]<style>${epubBook.inlinedCss}</style>[[/EPUB_CSS]]'
          : '';
      return '$cssBlock${epubChapter.richContent}';
    }

    // 后备：richContent 为空（理论上不应发生，parseFromBytes 总会生成）
    // 退化为纯文本
    if (epubChapter.content == null) return null;
    return EpubParser.extractTextFromHtml(epubChapter.content!);
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
      debugPrint('[EPUB导入] 解析返回空（title=未知书名 且 chapters 为空）');
      return null;
    } catch (e, st) {
      debugPrint('[EPUB导入] 解析异常: $e');
      debugPrint('[EPUB导入] 异常堆栈: $st');
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
