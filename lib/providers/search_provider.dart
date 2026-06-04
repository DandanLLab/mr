import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book_source.dart';
import '../services/storage_service.dart';
import '../services/source_engine/source_engine.dart';

class SearchProvider extends ChangeNotifier {
  List<BookSource> _bookSources = [];
  Set<String> _selectedSourceUrls = {};
  List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = false;
  String? _error;
  List<String> _searchHistory = [];
  String _currentKeyword = '';

  List<BookSource> get bookSources => _bookSources;
  Set<String> get selectedSourceUrls => _selectedSourceUrls;
  List<BookSource> get selectedSources => _bookSources
      .where((s) => _selectedSourceUrls.contains(s.bookSourceUrl))
      .toList();
  List<Map<String, dynamic>> get searchResults => _searchResults;
  bool get isLoading => _isLoading;
  String? get error => _error;
  List<String> get searchHistory => _searchHistory;
  String get currentKeyword => _currentKeyword;

  Future<void> loadBookSources() async {
    final sourcesData = StorageService.instance.getAllBookSources();
    _bookSources = [];
    for (final data in sourcesData) {
      try {
        _bookSources.add(BookSource.fromJson(data));
      } catch (e) {
        debugPrint('跳过无效书源 ${data['bookSourceUrl'] ?? ''}: $e');
      }
    }

    _bookSources = _bookSources
        .where(
            (s) => s.enabled && s.searchUrl != null && s.searchUrl!.isNotEmpty)
        .toList();

    if (_selectedSourceUrls.isEmpty && _bookSources.isNotEmpty) {
      _selectedSourceUrls =
          _bookSources.take(5).map((s) => s.bookSourceUrl).toSet();
    }

    notifyListeners();
  }

  Future<void> loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getStringList('searchHistory') ?? [];
      _searchHistory = history;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('searchHistory', _searchHistory);
    } catch (_) {}
  }

  void toggleSourceSelection(String sourceUrl) {
    if (_selectedSourceUrls.contains(sourceUrl)) {
      _selectedSourceUrls.remove(sourceUrl);
    } else {
      _selectedSourceUrls.add(sourceUrl);
    }
    notifyListeners();
  }

  void selectAllSources() {
    _selectedSourceUrls = _bookSources.map((s) => s.bookSourceUrl).toSet();
    notifyListeners();
  }

  void deselectAllSources() {
    _selectedSourceUrls.clear();
    notifyListeners();
  }

  Future<void> search(String keyword) async {
    if (keyword.isEmpty) return;

    _currentKeyword = keyword;
    _isLoading = true;
    _error = null;
    _searchResults.clear();
    notifyListeners();

    if (!_searchHistory.contains(keyword)) {
      _searchHistory.insert(0, keyword);
      if (_searchHistory.length > 20) {
        _searchHistory.removeLast();
      }
      await _saveSearchHistory();
    }

    final sources = selectedSources;
    if (sources.isEmpty) {
      _isLoading = false;
      _error = '请先选择书源';
      notifyListeners();
      return;
    }

    final allResults = <Map<String, dynamic>>[];

    for (final source in sources) {
      try {
        final webBook = WebBook(source);
        final results = await webBook.searchBook(keyword);

        for (final result in results) {
          result['sourceUrl'] = source.bookSourceUrl;
          result['sourceName'] = source.bookSourceName;
          allResults.add(result);
        }
      } catch (e) {
        debugPrint('搜索书源 ${source.bookSourceName} 失败: $e');
      }
    }

    _searchResults = allResults;
    _isLoading = false;
    notifyListeners();
  }

  void clearResults() {
    _searchResults.clear();
    _currentKeyword = '';
    _error = null;
    notifyListeners();
  }

  void clearHistory() {
    _searchHistory.clear();
    _saveSearchHistory();
    notifyListeners();
  }

  void removeFromHistory(String keyword) {
    _searchHistory.remove(keyword);
    _saveSearchHistory();
    notifyListeners();
  }
}
