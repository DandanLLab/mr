import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:synchronized/synchronized.dart';

/// EPUB 虚拟域名资源服务
///
/// 参考 Readium Kotlin-toolkit 的 WebViewServer 设计：
/// - 用虚拟域名 https://mr-epub-package/ 服务 EPUB 内部资源
/// - shouldInterceptRequest 拦截请求，按需从 zip 读取
/// - 支持多级相对路径自动解析
/// - 支持 Range 请求（音频/视频分片）
///
/// 双轨并行：保留现有 file:// + extractedBasePath 作为 fallback，
/// 本服务作为可选模式叠加，未注册或资源未命中时返回 null 让 WebView 走默认。
class EpubResourceServer {
  /// 虚拟域名 host（服务 EPUB 内部资源）
  static const String packageHost = 'mr-epub-package';

  /// 虚拟域名 baseUrl，所有 EPUB 资源 URL 均以此为前缀
  static const String packageBaseUrl = 'https://mr-epub-package/';

  /// 单例
  static final EpubResourceServer instance = EpubResourceServer._();
  EpubResourceServer._();

  /// bookId -> Archive 缓存（EPUB 文件解压后的 zip 结构）
  ///
  /// Archive 对象不是线程安全的，读取时通过 [_archiveLock] 串行化。
  final Map<String, Archive> _archives = <String, Archive>{};

  /// 当前活跃的 bookId
  ///
  /// URL 路径不含 bookId（只有一个虚拟 host），handleRequest 时
  /// 用此字段定位要读取的 Archive。ReaderWebView 切换章节时调用
  /// [setActiveBook] 更新。
  String? _activeBookId;

  /// Archive 读取互斥锁（Archive 非线程安全）
  final Lock _archiveLock = Lock();

  /// 注册一本书的 zip 字节流
  ///
  /// [bookId] 书籍唯一标识（建议用 bookUrl 的 hash）
  /// [bytes] EPUB 文件原始字节
  /// 返回此书的虚拟 baseUrl（统一为 [packageBaseUrl]）。
  String registerBook(String bookId, Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      _archives[bookId] = archive;
      debugPrint('[EpubResourceServer] 注册书籍: $bookId，'
          '${archive.numberOfFiles()} 个文件');
    } catch (e) {
      debugPrint('[EpubResourceServer] 注册书籍失败: $bookId，$e');
    }
    return packageBaseUrl;
  }

  /// 注销一本书
  void unregisterBook(String bookId) {
    _archives.remove(bookId);
    if (_activeBookId == bookId) {
      _activeBookId = null;
    }
  }

  /// 设置当前活跃的 bookId
  ///
  /// ReaderWebView 切换章节或打开新书时调用。handleRequest 会读取此 bookId
  /// 对应的 Archive。
  void setActiveBook(String bookId) {
    _activeBookId = bookId;
  }

  /// 拦截请求，返回 WebResourceResponse 或 null
  ///
  /// 供 InAppWebView 的 shouldInterceptRequest 回调调用：
  /// ```dart
  /// shouldInterceptRequest: (controller, request) {
  ///   return EpubResourceServer.instance.handleRequest(request);
  /// },
  /// ```
  /// 返回 null 表示非虚拟域名请求或资源不存在，让 WebView 走默认（fallback）。
  Future<WebResourceResponse?> handleRequest(WebResourceRequest request) async {
    final url = request.url.toString();
    final epubPath = urlToEpubPath(url);
    if (epubPath == null) return null;

    final bookId = _activeBookId;
    if (bookId == null) return null;

    return _archiveLock.synchronized(() {
      try {
        final archive = _archives[bookId];
        if (archive == null) return null;

        // 路径匹配：先精确匹配，再大小写不敏感兜底
        // EPUB 内文件路径大小写敏感性因生产工具而异（Windows 工具常忽略大小写，
        // macOS/Linux 工具严格区分），双策略兼顾两种情况
        final normalizedPath = epubPath.replaceAll('\\', '/');
        final lower = normalizedPath.toLowerCase();
        ArchiveFile? file;
        ArchiveFile? caseInsensitiveMatch;
        for (final f in archive) {
          if (!f.isFile) continue;
          final name = f.name.replaceAll('\\', '/');
          if (name == normalizedPath) {
            file = f;
            break;
          }
          if (caseInsensitiveMatch == null && name.toLowerCase() == lower) {
            caseInsensitiveMatch = f;
          }
        }
        file ??= caseInsensitiveMatch;
        if (file == null) {
          debugPrint('[EpubResourceServer] 资源不存在: $epubPath');
          return null;
        }

        final Uint8List fullBytes;
        final content = file.content;
        if (content is Uint8List) {
          fullBytes = content;
        } else if (content is List<int>) {
          fullBytes = Uint8List.fromList(content);
        } else {
          debugPrint('[EpubResourceServer] 未知 content 类型: '
              '${content.runtimeType}');
          return null;
        }

        final contentType = _inferMimeType(epubPath);
        final headers = <String, String>{
          'Access-Control-Allow-Origin': '*',
          'Accept-Ranges': 'bytes',
        };

        // Range 请求处理（音频/视频分片必备）
        final rangeHeader = _getHeader(request.headers, 'Range');
        if (rangeHeader != null && rangeHeader.isNotEmpty) {
          final range = _parseRange(rangeHeader, fullBytes.length);
          if (range != null) {
            final start = range[0];
            final end = range[1]; // 含 end
            final slice = fullBytes.sublist(start, end + 1);
            headers['Content-Range'] = 'bytes $start-$end/${fullBytes.length}';
            return WebResourceResponse(
              contentType: contentType,
              contentEncoding: 'utf-8',
              data: slice,
              headers: headers,
              statusCode: 206,
              reasonPhrase: 'Partial Content',
            );
          }
        }

        return WebResourceResponse(
          contentType: contentType,
          contentEncoding: 'utf-8',
          data: fullBytes,
          headers: headers,
          statusCode: 200,
          reasonPhrase: 'OK',
        );
      } catch (e) {
        debugPrint('[EpubResourceServer] 处理请求异常: $url，$e');
        return null;
      }
    });
  }

  /// 把 EPUB 内部路径转为虚拟 URL
  ///
  /// [epubPath] 如 "OEBPS/Images/cover.jpg"
  /// [bookId] 书籍标识（当前只有一个虚拟 host，此参数保留以备多 host 扩展）
  /// 返回 "https://mr-epub-package/OEBPS/Images/cover.jpg"
  String epubPathToUrl(String epubPath, String bookId) {
    final clean = epubPath.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    return '$packageBaseUrl$clean';
  }

  /// 把虚拟 URL 转回 EPUB 内部路径
  ///
  /// [url] 如 "https://mr-epub-package/OEBPS/Images/cover.jpg"
  /// 返回 "OEBPS/Images/cover.jpg"；非虚拟域名返回 null
  String? urlToEpubPath(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.host != packageHost) return null;
      // Uri.path 已剥离 query 和 fragment
      var path = uri.path.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
      if (path.isEmpty) return null;
      // URL 解码（如 %20 → 空格），解码失败保留原值
      try {
        path = Uri.decodeComponent(path);
      } catch (_) {
        // 解码失败保留原值
      }
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 大小写不敏感获取 HTTP 头
  static String? _getHeader(Map<String, String>? headers, String name) {
    if (headers == null) return null;
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// 解析 Range 头
  ///
  /// 支持格式：
  /// - `bytes=0-499`（前 500 字节）
  /// - `bytes=500-`（500 到末尾）
  /// - `bytes=-500`（最后 500 字节）
  ///
  /// 返回 [start, end]（含 end），解析失败返回 null
  static List<int>? _parseRange(String rangeHeader, int total) {
    if (total <= 0) return null;
    final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
    if (match == null) return null;
    final startStr = match.group(1) ?? '';
    final endStr = match.group(2) ?? '';
    int start;
    int end;
    if (startStr.isEmpty && endStr.isNotEmpty) {
      // 后缀范围：最后 N 字节
      final n = int.tryParse(endStr);
      if (n == null || n <= 0) return null;
      start = total > n ? total - n : 0;
      end = total - 1;
    } else if (startStr.isNotEmpty) {
      start = int.tryParse(startStr) ?? -1;
      if (start < 0 || start >= total) return null;
      if (endStr.isEmpty) {
        end = total - 1;
      } else {
        end = int.tryParse(endStr) ?? -1;
        if (end < start) return null;
        if (end >= total) end = total - 1;
      }
    } else {
      return null;
    }
    return [start, end];
  }

  /// 根据文件扩展名推断 MIME 类型
  static String _inferMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'html':
      case 'htm':
      case 'xhtml':
        return 'text/html';
      case 'css':
        return 'text/css';
      case 'js':
        return 'application/javascript';
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
      case 'woff':
        return 'font/woff';
      case 'woff2':
        return 'font/woff2';
      case 'ttf':
        return 'font/ttf';
      case 'otf':
        return 'font/otf';
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
        return 'audio/mp4';
      case 'xml':
        return 'application/xml';
      case 'json':
        return 'application/json';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }
}
