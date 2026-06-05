import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

class StorageService {
  static final StorageService instance = StorageService._internal();
  StorageService._internal();

  Box? _settingsBox;
  Box? _bookshelfBox;
  Box? _cacheBox;
  Box? _bookSourceBox;

  bool _initialized = false;
  String? _initError;

  bool get isInitialized => _initialized;
  String? get initError => _initError;

  Future<void> init() async {
    try {
      _settingsBox = await Hive.openBox('settings');
      _bookshelfBox = await Hive.openBox('bookshelf');
      _cacheBox = await Hive.openBox('cache');
      _bookSourceBox = await Hive.openBox('bookSource');
      _initialized = true;
      _initError = null;
      debugPrint('✅ StorageService 初始化成功');
    } catch (e) {
      _initError = e.toString();
      debugPrint('❌ StorageService 初始化失败: $e');
      // 尝试恢复：删除损坏的数据库文件并重新初始化
      try {
        await _recoverCorruptedBoxes();
        _settingsBox = await Hive.openBox('settings');
        _bookshelfBox = await Hive.openBox('bookshelf');
        _cacheBox = await Hive.openBox('cache');
        _bookSourceBox = await Hive.openBox('bookSource');
        _initialized = true;
        _initError = null;
        debugPrint('✅ StorageService 恢复初始化成功');
      } catch (recoveryError) {
        _initError = recoveryError.toString();
        debugPrint('❌ StorageService 恢复初始化也失败: $recoveryError');
      }
    }
  }

  /// 尝试恢复损坏的 Hive Box
  Future<void> _recoverCorruptedBoxes() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final hiveDir = Directory('${dir.path}/hive');
      if (hiveDir.existsSync()) {
        // 删除可能损坏的 Hive 文件
        for (final file in hiveDir.listSync()) {
          if (file is File && file.path.endsWith('.hive')) {
            try {
              await file.delete();
              debugPrint('🗑️ 删除损坏的 Hive 文件: ${file.path}');
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ 恢复Hive数据时出错: $e');
    }
  }

  /// 确保已初始化，未初始化则尝试初始化
  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    debugPrint('⚠️ StorageService: 未初始化，尝试初始化...');
    try {
      await init();
      return _initialized;
    } catch (e) {
      debugPrint('❌ StorageService 初始化失败: $e');
      return false;
    }
  }

  Future<void> setSetting(String key, dynamic value) async {
    await _settingsBox?.put(key, value);
  }

  dynamic getSetting(String key, {dynamic defaultValue}) {
    return _settingsBox?.get(key, defaultValue: defaultValue);
  }

  Future<void> addToBookshelf(Map<String, dynamic> bookData) async {
    final bookUrl =
        bookData['bookUrl'] as String? ?? bookData['id'] as String? ?? '';
    if (_bookshelfBox == null) {
      try {
        _bookshelfBox = await Hive.openBox('bookshelf');
      } catch (e) {
        debugPrint('❌ 打开bookshelf Box失败: $e');
        return;
      }
    }
    await _bookshelfBox!.put(bookUrl, bookData);
  }

  Future<void> removeFromBookshelf(String bookUrl) async {
    await _bookshelfBox?.delete(bookUrl);
  }

  List<Map<String, dynamic>> getAllBooks() {
    if (_bookshelfBox == null) return [];
    return _bookshelfBox!.values
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Map<String, dynamic>? getBook(String bookUrl) {
    final data = _bookshelfBox?.get(bookUrl);
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  Future<void> updateBookProgress(String bookUrl, int durChapterIndex,
      String durChapterTitle, int durChapterPos) async {
    final book = _bookshelfBox?.get(bookUrl);
    if (book != null) {
      book['durChapterIndex'] = durChapterIndex;
      book['durChapterTitle'] = durChapterTitle;
      book['durChapterPos'] = durChapterPos;
      book['durChapterTime'] = DateTime.now().toIso8601String();
      await _bookshelfBox?.put(bookUrl, book);
    }
  }

  Future<void> saveBook(dynamic book) async {
    Map<String, dynamic> data;
    if (book is Map<String, dynamic>) {
      data = book;
    } else {
      data = (book as dynamic).toJson() as Map<String, dynamic>;
    }
    final bookUrl = data['bookUrl'] as String? ?? '';
    if (_bookshelfBox == null) {
      try {
        _bookshelfBox = await Hive.openBox('bookshelf');
      } catch (e) {
        debugPrint('❌ 打开bookshelf Box失败: $e');
        return;
      }
    }
    await _bookshelfBox!.put(bookUrl, data);
  }

  Future<void> saveBookSource(Map<String, dynamic> sourceData) async {
    final sourceUrl = sourceData['bookSourceUrl'] as String? ?? '';
    if (sourceUrl.isEmpty) return;

    if (!_initialized) {
      final ok = await _ensureInitialized();
      if (!ok) {
        throw Exception('StorageService: 初始化失败，无法保存书源');
      }
    }

    if (_bookSourceBox == null) {
      // 尝试重新打开 Box
      try {
        _bookSourceBox = await Hive.openBox('bookSource');
      } catch (e) {
        throw Exception('StorageService: _bookSourceBox 初始化失败: $e');
      }
    }
    await _bookSourceBox!.put(sourceUrl, sourceData);
    await _bookSourceBox!.flush();
  }

  Future<void> saveBookSources(List<Map<String, dynamic>> sources) async {
    for (final source in sources) {
      await saveBookSource(source);
    }
  }

  List<Map<String, dynamic>> getAllBookSources() {
    if (_bookSourceBox == null) return [];
    return _bookSourceBox!.values
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Map<String, dynamic>? getBookSource(String sourceUrl) {
    if (_bookSourceBox == null) {
      debugPrint('⚠️ StorageService: _bookSourceBox 未初始化，无法获取书源');
      return null;
    }
    final data = _bookSourceBox!.get(sourceUrl);
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  Future<void> deleteBookSource(String sourceUrl) async {
    await _bookSourceBox?.delete(sourceUrl);
  }

  Future<void> clearBookSources() async {
    await _bookSourceBox?.clear();
  }

  Future<void> cacheData(String key, dynamic data) async {
    await _cacheBox?.put(key, data);
  }

  dynamic getCachedData(String key) {
    return _cacheBox?.get(key);
  }

  Future<void> clearCache() async {
    await _cacheBox?.clear();
  }

  Future<void> saveReaderConfig(Map<String, dynamic> config) async {
    await _settingsBox?.put('readerConfig', config);
  }

  Map<String, dynamic>? getReaderConfig() {
    final data = _settingsBox?.get('readerConfig');
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  Future<void> saveLegadoUrl(String url) async {
    await _settingsBox?.put('legadoUrl', url);
  }

  String? getLegadoUrl() {
    return _settingsBox?.get('legadoUrl');
  }

  // 高亮相关方法
  Future<void> saveHighlight(Map<String, dynamic> highlightData) async {
    final id = highlightData['id'] as String? ?? '';
    await _cacheBox?.put('highlight_$id', highlightData);
  }

  Future<void> deleteHighlight(String id) async {
    await _cacheBox?.delete('highlight_$id');
  }

  List<Map<String, dynamic>> getChapterHighlights(
      String bookUrl, int chapterIndex) {
    if (_cacheBox == null) return [];
    return _cacheBox!.values
        .where((e) {
          final map = e as Map?;
          if (map == null) return false;
          return map['bookUrl'] == bookUrl &&
              map['chapterIndex'] == chapterIndex;
        })
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  List<Map<String, dynamic>> getAllHighlights(String bookUrl) {
    if (_cacheBox == null) return [];
    return _cacheBox!.values
        .where((e) {
          final map = e as Map?;
          if (map == null) return false;
          return map['bookUrl'] == bookUrl;
        })
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // 高亮规则相关方法
  Future<void> saveHighlightRule(Map<String, dynamic> ruleData) async {
    final id = ruleData['id'] as String? ?? '';
    await _settingsBox?.put('highlightRule_$id', ruleData);
  }

  Future<void> deleteHighlightRule(String id) async {
    await _settingsBox?.delete('highlightRule_$id');
  }

  List<Map<String, dynamic>> getAllHighlightRules() {
    if (_settingsBox == null) return [];
    return _settingsBox!.values
        .where((e) {
          final key = e as Map?;
          return key != null && key.containsKey('pattern');
        })
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
