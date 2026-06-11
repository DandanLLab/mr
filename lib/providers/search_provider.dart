import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import '../services/source_engine/source_engine.dart';
import '../services/storage_service.dart';

typedef BookSourceSearcher = Future<List<Map<String, dynamic>>> Function(
  BookSource source,
  String keyword,
);

class SearchProvider extends ChangeNotifier {
  SearchProvider({
    int maxConcurrentSearches = 5,
    BookSourceSearcher? searcher,
    List<BookSource> initialSources = const [],
  })  : _maxConcurrentSearches =
            maxConcurrentSearches > 0 ? maxConcurrentSearches : 1,
        _searcher = searcher ?? _searchSource,
        _bookSources = List.of(initialSources),
        _selectedSourceUrls =
            initialSources.map((source) => source.bookSourceUrl).toSet();

  final int _maxConcurrentSearches;
  final BookSourceSearcher _searcher;

  List<BookSource> _bookSources;
  Set<String> _selectedSourceUrls;
  final List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = false;
  String? _error;
  List<String> _searchHistory = [];
  String _currentKeyword = '';
  int _searchGeneration = 0;

  List<BookSource> get bookSources => _bookSources;
  Set<String> get selectedSourceUrls => _selectedSourceUrls;
  List<BookSource> get selectedSources => _bookSources
      .where((source) => _selectedSourceUrls.contains(source.bookSourceUrl))
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
          (source) =>
              source.enabled &&
              source.searchUrl != null &&
              source.searchUrl!.isNotEmpty,
        )
        .toList();

    if (_selectedSourceUrls.isEmpty && _bookSources.isNotEmpty) {
      _selectedSourceUrls =
          _bookSources.take(5).map((source) => source.bookSourceUrl).toSet();
    }

    notifyListeners();
  }

  Future<void> loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _searchHistory = prefs.getStringList('searchHistory') ?? [];
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
    _selectedSourceUrls =
        _bookSources.map((source) => source.bookSourceUrl).toSet();
    notifyListeners();
  }

  void deselectAllSources() {
    _selectedSourceUrls.clear();
    notifyListeners();
  }

  Future<void> search(String keyword, {bool precisionSearch = false}) async {
    if (keyword.isEmpty) return;

    final generation = ++_searchGeneration;
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
      unawaited(_saveSearchHistory());
    }

    final sources = selectedSources;
    if (sources.isEmpty) {
      _isLoading = false;
      _error = '请先选择书源';
      notifyListeners();
      return;
    }

    var nextSourceIndex = 0;

    Future<void> worker() async {
      while (generation == _searchGeneration) {
        final sourceIndex = nextSourceIndex++;
        if (sourceIndex >= sources.length) return;
        final source = sources[sourceIndex];

        try {
          final results = await _searcher(source, keyword)
              .timeout(const Duration(seconds: 20));
          if (generation != _searchGeneration) return;

          for (final result in results) {
            result['sourceUrl'] = source.bookSourceUrl;
            result['sourceName'] = source.bookSourceName;
          }
          
          // 精准搜索：只保留完全匹配的结果
          if (precisionSearch) {
            final filtered = results.where((r) {
              final name = r['name']?.toString().toLowerCase() ?? '';
              return name.contains(keyword.toLowerCase());
            }).toList();
            _searchResults.addAll(filtered);
          } else {
            _searchResults.addAll(results);
          }
          notifyListeners();
        } catch (e) {
          debugPrint('搜索书源 ${source.bookSourceName} 失败: $e');
        }
      }
    }

    final workerCount = sources.length < _maxConcurrentSearches
        ? sources.length
        : _maxConcurrentSearches;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    if (generation != _searchGeneration) return;

    _isLoading = false;
    notifyListeners();
  }

  static Future<List<Map<String, dynamic>>> _searchSource(
    BookSource source,
    String keyword,
  ) {
    return WebBook(source).searchBook(keyword);
  }

  void clearResults() {
    _searchGeneration++;
    _searchResults.clear();
    _currentKeyword = '';
    _isLoading = false;
    _error = null;
    notifyListeners();
  }

  void stopSearch() {
    _searchGeneration++;
    _isLoading = false;
    notifyListeners();
  }

  void clearHistory() {
    _searchHistory.clear();
    unawaited(_saveSearchHistory());
    notifyListeners();
  }

  void removeFromHistory(String keyword) {
    _searchHistory.remove(keyword);
    unawaited(_saveSearchHistory());
    notifyListeners();
  }
}
