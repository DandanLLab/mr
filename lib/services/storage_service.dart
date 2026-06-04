import 'package:hive_flutter/hive_flutter.dart';

class StorageService {
  static final StorageService instance = StorageService._internal();
  StorageService._internal();

  late Box _settingsBox;
  late Box _bookshelfBox;
  late Box _cacheBox;
  late Box _bookSourceBox;

  Future<void> init() async {
    _settingsBox = await Hive.openBox('settings');
    _bookshelfBox = await Hive.openBox('bookshelf');
    _cacheBox = await Hive.openBox('cache');
    _bookSourceBox = await Hive.openBox('bookSource');
  }

  Future<void> setSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  dynamic getSetting(String key, {dynamic defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue);
  }

  Future<void> addToBookshelf(Map<String, dynamic> bookData) async {
    final bookUrl =
        bookData['bookUrl'] as String? ?? bookData['id'] as String? ?? '';
    await _bookshelfBox.put(bookUrl, bookData);
  }

  Future<void> removeFromBookshelf(String bookUrl) async {
    await _bookshelfBox.delete(bookUrl);
  }

  List<Map<String, dynamic>> getAllBooks() {
    return _bookshelfBox.values
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Map<String, dynamic>? getBook(String bookUrl) {
    final data = _bookshelfBox.get(bookUrl);
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  Future<void> updateBookProgress(String bookUrl, int durChapterIndex,
      String durChapterTitle, int durChapterPos) async {
    final book = _bookshelfBox.get(bookUrl);
    if (book != null) {
      book['durChapterIndex'] = durChapterIndex;
      book['durChapterTitle'] = durChapterTitle;
      book['durChapterPos'] = durChapterPos;
      book['durChapterTime'] = DateTime.now().toIso8601String();
      await _bookshelfBox.put(bookUrl, book);
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
    await _bookshelfBox.put(bookUrl, data);
  }

  Future<void> saveBookSource(Map<String, dynamic> sourceData) async {
    final sourceUrl = sourceData['bookSourceUrl'] as String? ?? '';
    if (sourceUrl.isNotEmpty) {
      await _bookSourceBox.put(sourceUrl, sourceData);
      await _bookSourceBox.flush();
    }
  }

  Future<void> saveBookSources(List<Map<String, dynamic>> sources) async {
    for (final source in sources) {
      await saveBookSource(source);
    }
  }

  List<Map<String, dynamic>> getAllBookSources() {
    return _bookSourceBox.values
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Map<String, dynamic>? getBookSource(String sourceUrl) {
    final data = _bookSourceBox.get(sourceUrl);
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  Future<void> deleteBookSource(String sourceUrl) async {
    await _bookSourceBox.delete(sourceUrl);
  }

  Future<void> clearBookSources() async {
    await _bookSourceBox.clear();
  }

  Future<void> cacheData(String key, dynamic data) async {
    await _cacheBox.put(key, data);
  }

  dynamic getCachedData(String key) {
    return _cacheBox.get(key);
  }

  Future<void> clearCache() async {
    await _cacheBox.clear();
  }

  Future<void> saveReaderConfig(Map<String, dynamic> config) async {
    await _settingsBox.put('readerConfig', config);
  }

  Map<String, dynamic>? getReaderConfig() {
    final data = _settingsBox.get('readerConfig');
    if (data == null) return null;
    return Map<String, dynamic>.from(data);
  }

  Future<void> saveLegadoUrl(String url) async {
    await _settingsBox.put('legadoUrl', url);
  }

  String? getLegadoUrl() {
    return _settingsBox.get('legadoUrl');
  }

  // 高亮相关方法
  Future<void> saveHighlight(Map<String, dynamic> highlightData) async {
    final id = highlightData['id'] as String? ?? '';
    await _cacheBox.put('highlight_$id', highlightData);
  }

  Future<void> deleteHighlight(String id) async {
    await _cacheBox.delete('highlight_$id');
  }

  List<Map<String, dynamic>> getChapterHighlights(
      String bookUrl, int chapterIndex) {
    return _cacheBox.values
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
    return _cacheBox.values
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
    await _settingsBox.put('highlightRule_$id', ruleData);
  }

  Future<void> deleteHighlightRule(String id) async {
    await _settingsBox.delete('highlightRule_$id');
  }

  List<Map<String, dynamic>> getAllHighlightRules() {
    return _settingsBox.values
        .where((e) {
          final key = e as Map?;
          return key != null && key.containsKey('pattern');
        })
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
