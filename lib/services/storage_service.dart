import 'package:hive_flutter/hive_flutter.dart';
import '../models/book.dart';
import '../models/highlight.dart';

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
    final bookUrl = bookData['bookUrl'] as String? ?? bookData['id'] as String? ?? '';
    await _bookshelfBox.put(bookUrl, bookData);
  }

  Future<void> saveBook(Book book) async {
    await _bookshelfBox.put(book.bookUrl, book.toJson());
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

  Future<void> updateBookProgress(String bookUrl, int durChapterIndex, String durChapterTitle, int durChapterPos) async {
    final book = _bookshelfBox.get(bookUrl);
    if (book != null) {
      book['durChapterIndex'] = durChapterIndex;
      book['durChapterTitle'] = durChapterTitle;
      book['durChapterPos'] = durChapterPos;
      book['durChapterTime'] = DateTime.now().toIso8601String();
      await _bookshelfBox.put(bookUrl, book);
    }
  }

  Future<void> saveBookSource(Map<String, dynamic> sourceData) async {
    final sourceUrl = sourceData['bookSourceUrl'] as String? ?? '';
    if (sourceUrl.isNotEmpty) {
      await _bookSourceBox.put(sourceUrl, sourceData);
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

  // ==================== Highlight CRUD ====================

  Future<void> saveHighlight(Highlight highlight) async {
    final key = 'highlight_${highlight.bookUrl}_${highlight.id}';
    await _cacheBox.put(key, highlight.toJson());
  }

  Future<void> deleteHighlight(String bookUrl, String id) async {
    final key = 'highlight_${bookUrl}_$id';
    await _cacheBox.delete(key);
  }

  List<Highlight> getHighlights(String bookUrl) {
    final prefix = 'highlight_${bookUrl}_';
    return _cacheBox.keys
        .where((key) => key is String && key.startsWith(prefix))
        .map((key) {
      final data = _cacheBox.get(key);
      if (data == null) return null;
      return Highlight.fromJson(Map<String, dynamic>.from(data));
    }).whereType<Highlight>().toList();
  }

  List<Highlight> getChapterHighlights(String bookUrl, int chapterIndex) {
    return getHighlights(bookUrl)
        .where((h) => h.chapterIndex == chapterIndex)
        .toList();
  }

  Future<void> updateHighlightNote(String bookUrl, String id, String note) async {
    final key = 'highlight_${bookUrl}_$id';
    final data = _cacheBox.get(key);
    if (data != null) {
      final json = Map<String, dynamic>.from(data);
      json['note'] = note;
      json['updatedAt'] = DateTime.now().toIso8601String();
      await _cacheBox.put(key, json);
    }
  }

  // ==================== HighlightRule CRUD ====================

  static const String _highlightRulePrefix = 'highlight_rule_';

  Future<void> saveHighlightRule(HighlightRule rule) async {
    final key = '$_highlightRulePrefix${rule.id}';
    await _cacheBox.put(key, rule.toJson());
  }

  Future<void> deleteHighlightRule(String id) async {
    final key = '$_highlightRulePrefix$id';
    await _cacheBox.delete(key);
  }

  List<HighlightRule> getHighlightRules() {
    return _cacheBox.keys
        .where((key) => key is String && key.startsWith(_highlightRulePrefix))
        .map((key) {
      final data = _cacheBox.get(key);
      if (data == null) return null;
      return HighlightRule.fromJson(Map<String, dynamic>.from(data));
    }).whereType<HighlightRule>().toList()
      ..sort((a, b) => a.serialNumber.compareTo(b.serialNumber));
  }

  List<HighlightRule> getEnabledHighlightRules() {
    return getHighlightRules().where((r) => r.enabled).toList();
  }

  Future<void> initBuiltInHighlightRules() async {
    final builtIn = HighlightRule.builtInRules();
    for (final rule in builtIn) {
      final key = '$_highlightRulePrefix${rule.id}';
      if (_cacheBox.get(key) == null) {
        await _cacheBox.put(key, rule.toJson());
      }
    }
  }
}
