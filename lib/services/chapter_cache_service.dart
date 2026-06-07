import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/chapter.dart';

/// 章节缓存服务
/// 缓存目录结构: {cacheDir}/book_cache/{bookFolderName}/{chapterFileName}
class ChapterCacheService {
  static final ChapterCacheService instance = ChapterCacheService._internal();
  ChapterCacheService._internal();

  static const String _cacheFolderName = 'book_cache';
  String? _cachePath;

  /// 初始化缓存目录
  Future<void> init() async {
    if (_cachePath != null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _cachePath = '${dir.path}$_cacheFolderName';
      final cacheDir = Directory(_cachePath!);
      if (!cacheDir.existsSync()) {
        cacheDir.createSync(recursive: true);
      }
      debugPrint('✅ ChapterCacheService 初始化成功: $_cachePath');
    } catch (e) {
      debugPrint('❌ ChapterCacheService 初始化失败: $e');
    }
  }

  /// 获取书籍缓存文件夹名
  /// 格式: 书名前9字符(去掉特殊字符) + bookUrl的16位MD5
  String getBookFolderName(Book book) {
    final name = book.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    final prefix = name.length > 9 ? name.substring(0, 9) : name;
    final md5Hash = md5.convert(utf8.encode(book.bookUrl)).toString().substring(0, 16);
    return '$prefix$md5Hash';
  }

  /// 获取章节缓存文件名
  /// 格式: {index:05d}-{titleMD5}.{suffix}
  String getChapterFileName(Chapter chapter, {String suffix = 'nb'}) {
    final titleMd5 = md5.convert(utf8.encode(chapter.title)).toString().substring(0, 8);
    return '${chapter.index.toString().padLeft(5, '0')}-$titleMd5.$suffix';
  }

  /// 获取书籍缓存目录
  Future<Directory> _getBookCacheDir(Book book) async {
    await init();
    final folderName = getBookFolderName(book);
    final dir = Directory('$_cachePath/$folderName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 保存章节内容到缓存
  Future<void> saveChapterContent(Book book, Chapter chapter, String content) async {
    if (content.isEmpty) return;
    try {
      final dir = await _getBookCacheDir(book);
      final fileName = getChapterFileName(chapter);
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(content, encoding: utf8);
      debugPrint('✅ 缓存章节: ${chapter.title} -> $fileName');
    } catch (e) {
      debugPrint('❌ 缓存章节失败: ${chapter.title} - $e');
    }
  }

  /// 保存漫画章节图片列表到缓存
  Future<void> saveComicChapterContent(Book book, Chapter chapter, List<String> imageUrls) async {
    if (imageUrls.isEmpty) return;
    try {
      final dir = await _getBookCacheDir(book);
      final fileName = getChapterFileName(chapter, suffix: 'cb');
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(jsonEncode(imageUrls), encoding: utf8);
      debugPrint('✅ 缓存漫画章节: ${chapter.title} -> $fileName');
    } catch (e) {
      debugPrint('❌ 缓存漫画章节失败: ${chapter.title} - $e');
    }
  }

  /// 读取缓存的章节内容
  Future<String?> readChapterContent(Book book, Chapter chapter) async {
    try {
      final dir = await _getBookCacheDir(book);
      final fileName = getChapterFileName(chapter);
      final file = File('${dir.path}/$fileName');
      if (file.existsSync()) {
        return await file.readAsString(encoding: utf8);
      }
    } catch (e) {
      debugPrint('❌ 读取缓存失败: ${chapter.title} - $e');
    }
    return null;
  }

  /// 读取缓存的漫画章节图片列表
  Future<List<String>?> readComicChapterContent(Book book, Chapter chapter) async {
    try {
      final dir = await _getBookCacheDir(book);
      final fileName = getChapterFileName(chapter, suffix: 'cb');
      final file = File('${dir.path}/$fileName');
      if (file.existsSync()) {
        final content = await file.readAsString(encoding: utf8);
        final List<dynamic> urls = jsonDecode(content);
        return urls.cast<String>();
      }
    } catch (e) {
      debugPrint('❌ 读取漫画缓存失败: ${chapter.title} - $e');
    }
    return null;
  }

  /// 检查章节是否已缓存
  Future<bool> hasChapterCache(Book book, Chapter chapter, {bool isComic = false}) async {
    try {
      final dir = await _getBookCacheDir(book);
      final fileName = getChapterFileName(chapter, suffix: isComic ? 'cb' : 'nb');
      final file = File('${dir.path}/$fileName');
      return file.existsSync();
    } catch (e) {
      return false;
    }
  }

  /// 获取书籍已缓存的章节文件名列表
  Future<Set<String>> getChapterCacheFiles(Book book, {bool isComic = false}) async {
    final files = <String>{};
    try {
      final dir = await _getBookCacheDir(book);
      if (dir.existsSync()) {
        final suffix = isComic ? 'cb' : 'nb';
        for (final entity in dir.listSync()) {
          if (entity is File && entity.path.endsWith('.$suffix')) {
            files.add(entity.uri.pathSegments.last);
          }
        }
      }
    } catch (e) {
      debugPrint('❌ 获取缓存文件列表失败: $e');
    }
    return files;
  }

  /// 删除章节缓存
  Future<void> deleteChapterCache(Book book, Chapter chapter, {bool isComic = false}) async {
    try {
      final dir = await _getBookCacheDir(book);
      final fileName = getChapterFileName(chapter, suffix: isComic ? 'cb' : 'nb');
      final file = File('${dir.path}/$fileName');
      if (file.existsSync()) {
        await file.delete();
        debugPrint('🗑️ 删除缓存: $fileName');
      }
    } catch (e) {
      debugPrint('❌ 删除缓存失败: $e');
    }
  }

  /// 清除书籍所有缓存
  Future<void> clearBookCache(Book book) async {
    try {
      final dir = await _getBookCacheDir(book);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
        debugPrint('🗑️ 清除书籍缓存: ${book.name}');
      }
    } catch (e) {
      debugPrint('❌ 清除书籍缓存失败: $e');
    }
  }

  /// 清除所有缓存
  Future<void> clearAllCache() async {
    try {
      if (_cachePath == null) await init();
      final cacheDir = Directory(_cachePath!);
      if (cacheDir.existsSync()) {
        await cacheDir.delete(recursive: true);
        await cacheDir.create(recursive: true);
        debugPrint('🗑️ 清除所有缓存');
      }
    } catch (e) {
      debugPrint('❌ 清除所有缓存失败: $e');
    }
  }

  /// 获取缓存大小
  Future<int> getCacheSize() async {
    try {
      if (_cachePath == null) await init();
      final cacheDir = Directory(_cachePath!);
      if (!cacheDir.existsSync()) return 0;
      int size = 0;
      for (final entity in cacheDir.listSync(recursive: true)) {
        if (entity is File) {
          size += entity.lengthSync();
        }
      }
      return size;
    } catch (e) {
      return 0;
    }
  }

  /// 格式化缓存大小
  String formatCacheSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
}
