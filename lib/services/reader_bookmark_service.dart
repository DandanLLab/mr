import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../services/storage_service.dart';

/// 书签数据模型
class Bookmark {
  final String id;
  final String bookUrl;
  final int chapterIndex;
  final String chapterTitle;
  final String content;
  final String? note;
  final DateTime createdAt;

  Bookmark({
    required this.id,
    required this.bookUrl,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.content,
    this.note,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'bookUrl': bookUrl,
    'chapterIndex': chapterIndex,
    'chapterTitle': chapterTitle,
    'content': content,
    'note': note,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id'] ?? '',
    bookUrl: json['bookUrl'] ?? '',
    chapterIndex: json['chapterIndex'] ?? 0,
    chapterTitle: json['chapterTitle'] ?? '',
    content: json['content'] ?? '',
    note: json['note'],
    createdAt: json['createdAt'] != null 
        ? DateTime.parse(json['createdAt']) 
        : DateTime.now(),
  );
}

/// 阅读器书签服务
/// 管理书签的增删改查
class ReaderBookmarkService {
  static const String _bookmarkKeyPrefix = 'bookmark_';

  ReaderBookmarkService();

  /// 获取指定书籍的所有书签
  Future<List<Bookmark>> list(String bookUrl) async {
    try {
      final key = '$_bookmarkKeyPrefix$bookUrl';
      final data = StorageService.instance.getCachedData(key);
      if (data == null || data is! String || data.isEmpty) return [];
      
      final decoded = jsonDecode(data) as List;
      return decoded
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    } catch (e) {
      debugPrint('[ReaderBookmark] list failed: $e');
      return [];
    }
  }

  /// 添加书签
  Future<Bookmark?> add({
    required String bookUrl,
    required int chapterIndex,
    required String chapterTitle,
    required String content,
    String? note,
  }) async {
    try {
      final bookmark = Bookmark(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        content: content.length > 100 ? content.substring(0, 100) : content,
        note: note,
        createdAt: DateTime.now(),
      );

      final bookmarks = await list(bookUrl);
      bookmarks.add(bookmark);
      
      final key = '$_bookmarkKeyPrefix$bookUrl';
      await StorageService.instance.cacheData(key, jsonEncode(
        bookmarks.map((b) => b.toJson()).toList(),
      ));
      
      return bookmark;
    } catch (e) {
      debugPrint('[ReaderBookmark] add failed: $e');
      return null;
    }
  }

  /// 删除书签
  Future<void> remove({
    required String bookUrl,
    required String bookmarkId,
  }) async {
    try {
      final bookmarks = await list(bookUrl);
      bookmarks.removeWhere((b) => b.id == bookmarkId);
      
      final key = '$_bookmarkKeyPrefix$bookUrl';
      await StorageService.instance.cacheData(key, jsonEncode(
        bookmarks.map((b) => b.toJson()).toList(),
      ));
    } catch (e) {
      debugPrint('[ReaderBookmark] remove failed: $e');
    }
  }

  /// 检查当前章节是否有书签
  Future<bool> hasBookmarkForChapter(String bookUrl, int chapterIndex) async {
    final bookmarks = await list(bookUrl);
    return bookmarks.any((b) => b.chapterIndex == chapterIndex);
  }
}
