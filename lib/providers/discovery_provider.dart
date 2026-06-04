import 'package:flutter/material.dart';
import '../models/book_source.dart';
import '../services/book_source_locator.dart';
import '../services/storage_service.dart';

enum DiscoveryCategory { recommend, novel, comic, video, audio }

class DiscoveryProvider extends ChangeNotifier {
  DiscoveryCategory _currentCategory = DiscoveryCategory.recommend;
  List<BookSource> _bookSources = [];
  Set<String> _selectedSourceIds = {};
  bool _isLoading = false;
  List<dynamic> _content = [];
  String? _currentGroupId;

  DiscoveryCategory get currentCategory => _currentCategory;
  List<BookSource> get bookSources => _bookSources;
  List<BookSource> get enabledSources =>
      _bookSources.where((s) => s.enabled).toList();
  Set<String> get selectedSourceIds => _selectedSourceIds;
  bool get isLoading => _isLoading;
  List<dynamic> get content => _content;
  String? get currentGroupId => _currentGroupId;

  List<BookSource> locateBookSources(String bookUrl) {
    return BookSourceLocator.locate(bookUrl, _bookSources);
  }

  BookSource? locateBookSource(String bookUrl) {
    return BookSourceLocator.locateFirst(bookUrl, _bookSources);
  }

  void setCategory(DiscoveryCategory category) {
    _currentCategory = category;
    notifyListeners();
  }

  void setGroup(String? groupId) {
    _currentGroupId = groupId;
    notifyListeners();
  }

  Future<void> loadBookSources() async {
    _isLoading = true;
    notifyListeners();

    try {
      final sourcesData = StorageService.instance.getAllBookSources();
      _bookSources = [];
      for (final data in sourcesData) {
        try {
          _bookSources.add(BookSource.fromJson(data));
        } catch (e) {
          debugPrint('跳过无效书源 ${data['bookSourceUrl'] ?? ''}: $e');
        }
      }
      _bookSources.sort((a, b) {
        if (a.customOrder != b.customOrder) {
          return a.customOrder.compareTo(b.customOrder);
        }
        return a.bookSourceName.compareTo(b.bookSourceName);
      });
    } catch (e) {
      debugPrint('加载书源失败: $e');
      _bookSources = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> deleteSource(String sourceUrl) async {
    await StorageService.instance.deleteBookSource(sourceUrl);
    _bookSources.removeWhere((s) => s.bookSourceUrl == sourceUrl);
    notifyListeners();
  }

  Future<void> toggleSourceEnabled(String sourceUrl) async {
    final index = _bookSources.indexWhere((s) => s.bookSourceUrl == sourceUrl);
    if (index != -1) {
      final source = _bookSources[index];
      _bookSources[index] = source.copyWith(enabled: !source.enabled);
      await StorageService.instance
          .saveBookSource(_bookSources[index].toJson());
      notifyListeners();
    }
  }

  void toggleSourceSelection(String sourceId) {
    if (_selectedSourceIds.contains(sourceId)) {
      _selectedSourceIds.remove(sourceId);
    } else {
      _selectedSourceIds.add(sourceId);
    }
    notifyListeners();
  }

  Future<void> loadContent() async {
    _isLoading = true;
    notifyListeners();

    try {
      await Future.delayed(const Duration(seconds: 1));
      _content = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    await loadBookSources();
  }
}
