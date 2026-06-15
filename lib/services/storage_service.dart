import 'dart:convert';
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
  int _initRetries = 0;

  bool get isInitialized => _initialized;
  String? get initError => _initError;

  Future<void> init() async {
    try {
      // 确保 Hive 已初始化
      if (!Hive.isBoxOpen('settings')) {
        _settingsBox = await Hive.openBox('settings');
      } else {
        _settingsBox = Hive.box('settings');
      }
      if (!Hive.isBoxOpen('bookshelf')) {
        _bookshelfBox = await Hive.openBox('bookshelf');
      } else {
        _bookshelfBox = Hive.box('bookshelf');
      }
      if (!Hive.isBoxOpen('cache')) {
        _cacheBox = await Hive.openBox('cache');
      } else {
        _cacheBox = Hive.box('cache');
      }
      if (!Hive.isBoxOpen('bookSource')) {
        _bookSourceBox = await Hive.openBox('bookSource');
      } else {
        _bookSourceBox = Hive.box('bookSource');
      }
      _initialized = true;
      _initError = null;
      _initRetries = 0;
      debugPrint('✅ StorageService 初始化成功');
    } catch (e) {
      _initError = e.toString();
      debugPrint('❌ StorageService 初始化失败: $e');
      // 尝试恢复：删除损坏的数据库文件并重新初始化
      _initRetries++;
      if (_initRetries <= 2) {
        try {
          await _recoverCorruptedBoxes();
          // 重新尝试打开
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
  }

  /// 尝试恢复损坏的 Hive Box
  Future<void> _recoverCorruptedBoxes() async {
    try {
      // 先关闭所有可能损坏的 Box
      await _safeCloseBox('settings');
      await _safeCloseBox('bookshelf');
      await _safeCloseBox('cache');
      await _safeCloseBox('bookSource');

      // 删除损坏的文件
      try {
        final dir = await getApplicationDocumentsDirectory();
        final hiveDir = Directory('${dir.path}/hive');
        if (hiveDir.existsSync()) {
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
        debugPrint('⚠️ 清理Hive目录失败: $e');
        // 尝试使用 Hive 默认路径
        try {
          await Hive.deleteBoxFromDisk('settings');
          await Hive.deleteBoxFromDisk('bookshelf');
          await Hive.deleteBoxFromDisk('cache');
          await Hive.deleteBoxFromDisk('bookSource');
          debugPrint('🗑️ 通过 Hive API 删除损坏的 Box');
        } catch (e2) {
          debugPrint('⚠️ Hive API 删除也失败: $e2');
        }
      }
    } catch (e) {
      debugPrint('⚠️ 恢复Hive数据时出错: $e');
    }
  }

  Future<void> _safeCloseBox(String name) async {
    try {
      if (Hive.isBoxOpen(name)) {
        await Hive.box(name).close();
      }
    } catch (_) {}
  }

  /// 确保已初始化，未初始化则尝试初始化
  Future<bool> _ensureInitialized() async {
    if (_initialized && _bookSourceBox != null) return true;
    debugPrint('⚠️ StorageService: 未初始化或Box为null，尝试初始化...');
    try {
      await init();
      return _initialized && _bookSourceBox != null;
    } catch (e) {
      debugPrint('❌ StorageService 初始化失败: $e');
      return false;
    }
  }

  /// 确保指定Box可用，不可用则重新打开
  Future<Box?> _ensureBox(String name, Box? currentBox) async {
    if (currentBox != null && currentBox.isOpen) return currentBox;
    try {
      if (Hive.isBoxOpen(name)) {
        return Hive.box(name);
      }
      return await Hive.openBox(name);
    } catch (e) {
      debugPrint('❌ 打开 $name Box失败: $e');
      // 尝试删除后重建
      try {
        await Hive.deleteBoxFromDisk(name);
        return await Hive.openBox(name);
      } catch (e2) {
        debugPrint('❌ 重建 $name Box也失败: $e2');
        return null;
      }
    }
  }

  Future<void> setSetting(String key, dynamic value) async {
    _settingsBox = await _ensureBox('settings', _settingsBox);
    await _settingsBox?.put(key, value);
  }

  dynamic getSetting(String key, {dynamic defaultValue}) {
    if (_settingsBox == null || !_settingsBox!.isOpen) {
      debugPrint('⚠️ StorageService: settings Box不可用，尝试异步恢复');
      _ensureBox('settings', _settingsBox).then((box) => _settingsBox = box);
      return defaultValue;
    }
    return _settingsBox!.get(key, defaultValue: defaultValue);
  }

  Future<void> addToBookshelf(Map<String, dynamic> bookData) async {
    final bookUrl =
        bookData['bookUrl'] as String? ?? bookData['id'] as String? ?? '';
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    if (_bookshelfBox == null) return;
    await _bookshelfBox!.put(bookUrl, bookData);
  }

  Future<void> removeFromBookshelf(String bookUrl) async {
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    await _bookshelfBox?.delete(bookUrl);
  }

  List<Map<String, dynamic>> getAllBooks() {
    if (_bookshelfBox == null || !_bookshelfBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookshelf Box不可用，尝试异步恢复');
      _ensureBox('bookshelf', _bookshelfBox).then((box) => _bookshelfBox = box);
      return [];
    }
    return _bookshelfBox!.values
        .where((e) => e is Map)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Map<String, dynamic>? getBook(String bookUrl) {
    if (_bookshelfBox == null || !_bookshelfBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookshelf Box不可用，尝试异步恢复');
      _ensureBox('bookshelf', _bookshelfBox).then((box) => _bookshelfBox = box);
      return null;
    }
    final data = _bookshelfBox!.get(bookUrl);
    if (data == null) return null;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    debugPrint('⚠️ StorageService: bookshelf 数据类型异常: ${data.runtimeType}');
    return null;
  }

  Future<void> updateBookProgress(
    String bookUrl,
    int durChapterIndex,
    String durChapterTitle,
    int durChapterPos,
  ) async {
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    final rawBook = _bookshelfBox?.get(bookUrl);
    final book = rawBook is Map ? Map<String, dynamic>.from(rawBook) : null;
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
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    if (_bookshelfBox == null) return;
    await _bookshelfBox!.put(bookUrl, data);
  }

  Future<void> saveBookSource(Map<String, dynamic> sourceData) async {
    final sourceUrl = sourceData['bookSourceUrl'] as String? ?? '';
    if (sourceUrl.isEmpty) {
      debugPrint('⚠️ StorageService: 书源URL为空，跳过保存');
      return;
    }

    // 确保 Box 可用
    _bookSourceBox = await _ensureBox('bookSource', _bookSourceBox);
    if (_bookSourceBox == null) {
      // 最后一次尝试：完全重新初始化
      final ok = await _ensureInitialized();
      if (!ok) {
        throw Exception('StorageService: 初始化失败，无法保存书源。请重启应用后重试。');
      }
    }

    try {
      await _bookSourceBox!.put(sourceUrl, sourceData);
      await _bookSourceBox!.flush();
      debugPrint('✅ 书源保存成功: $sourceUrl');
    } catch (e) {
      debugPrint('❌ 书源写入失败: $e');
      // 尝试重建 Box
      try {
        await Hive.deleteBoxFromDisk('bookSource');
        _bookSourceBox = await Hive.openBox('bookSource');
        await _bookSourceBox!.put(sourceUrl, sourceData);
        await _bookSourceBox!.flush();
        debugPrint('✅ 书源重建后保存成功: $sourceUrl');
      } catch (e2) {
        throw Exception('StorageService: 书源保存失败: $e2');
      }
    }
  }

  Future<void> saveBookSources(List<Map<String, dynamic>> sources) async {
    for (final source in sources) {
      await saveBookSource(source);
    }
  }

  List<Map<String, dynamic>> getAllBookSources() {
    if (_bookSourceBox == null || !_bookSourceBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookSource Box不可用，尝试异步恢复');
      _ensureBox(
        'bookSource',
        _bookSourceBox,
      ).then((box) => _bookSourceBox = box);
      return [];
    }
    return _bookSourceBox!.values
        .where((e) => e is Map)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Map<String, dynamic>? getBookSource(String sourceUrl) {
    if (_bookSourceBox == null || !_bookSourceBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookSource Box不可用，尝试异步恢复');
      _ensureBox(
        'bookSource',
        _bookSourceBox,
      ).then((box) => _bookSourceBox = box);
      return null;
    }
    final data = _bookSourceBox!.get(sourceUrl);
    if (data == null) return null;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    debugPrint('⚠️ StorageService: bookSource 数据类型异常: ${data.runtimeType}');
    return null;
  }

  Future<void> deleteBookSource(String sourceUrl) async {
    _bookSourceBox = await _ensureBox('bookSource', _bookSourceBox);
    await _bookSourceBox?.delete(sourceUrl);
  }

  Future<void> clearBookSources() async {
    _bookSourceBox = await _ensureBox('bookSource', _bookSourceBox);
    await _bookSourceBox?.clear();
  }

  Future<void> cacheData(String key, dynamic data) async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    await _cacheBox?.put(key, data);
  }

  dynamic getCachedData(String key) {
    if (_cacheBox == null || !_cacheBox!.isOpen) {
      _ensureBox('cache', _cacheBox).then((box) => _cacheBox = box);
      return null;
    }
    return _cacheBox!.get(key);
  }

  Future<dynamic> getCachedDataAsync(String key) async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    return _cacheBox?.get(key);
  }

  Future<void> clearCache() async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    await _cacheBox?.clear();
  }

  Future<void> saveReaderConfig(Map<String, dynamic> config) async {
    _settingsBox = await _ensureBox('settings', _settingsBox);
    await _settingsBox?.put('readerConfig', config);
  }

  Map<String, dynamic>? getReaderConfig() {
    if (_settingsBox == null || !_settingsBox!.isOpen) {
      _ensureBox('settings', _settingsBox).then((box) => _settingsBox = box);
      return null;
    }
    final data = _settingsBox!.get('readerConfig');
    if (data == null) return null;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    debugPrint('⚠️ StorageService: readerConfig 数据类型异常: ${data.runtimeType}');
    return null;
  }

  Future<void> saveLegadoUrl(String url) async {
    _settingsBox = await _ensureBox('settings', _settingsBox);
    await _settingsBox?.put('legadoUrl', url);
  }

  String? getLegadoUrl() {
    if (_settingsBox == null || !_settingsBox!.isOpen) {
      _ensureBox('settings', _settingsBox).then((box) => _settingsBox = box);
      return null;
    }
    return _settingsBox!.get('legadoUrl');
  }

  // 高亮相关方法
  Future<void> saveHighlight(Map<String, dynamic> highlightData) async {
    final id = highlightData['id'] as String? ?? '';
    _cacheBox = await _ensureBox('cache', _cacheBox);
    await _cacheBox?.put('highlight_$id', highlightData);
  }

  Future<void> deleteHighlight(String id) async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    await _cacheBox?.delete('highlight_$id');
  }

  List<Map<String, dynamic>> getChapterHighlights(
    String bookUrl,
    int chapterIndex,
  ) {
    if (_cacheBox == null || !_cacheBox!.isOpen) {
      _ensureBox('cache', _cacheBox).then((box) => _cacheBox = box);
      return [];
    }
    return _cacheBox!.values
        .where((e) {
          if (e is! Map) return false;
          return e['bookUrl'] == bookUrl && e['chapterIndex'] == chapterIndex;
        })
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  List<Map<String, dynamic>> getAllHighlights(String bookUrl) {
    if (_cacheBox == null || !_cacheBox!.isOpen) {
      _ensureBox('cache', _cacheBox).then((box) => _cacheBox = box);
      return [];
    }
    return _cacheBox!.values
        .where((e) {
          if (e is! Map) return false;
          return e['bookUrl'] == bookUrl;
        })
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // 高亮规则相关方法
  Future<void> saveHighlightRule(Map<String, dynamic> ruleData) async {
    final id = ruleData['id'] as String? ?? '';
    _settingsBox = await _ensureBox('settings', _settingsBox);
    await _settingsBox?.put('highlightRule_$id', ruleData);
  }

  Future<void> deleteHighlightRule(String id) async {
    await _settingsBox?.delete('highlightRule_$id');
  }

  List<Map<String, dynamic>> getAllHighlightRules() {
    if (_settingsBox == null) return [];
    return _settingsBox!.values
        .where((e) {
          if (e is! Map) return false;
          return e.containsKey('pattern');
        })
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
