import 'package:flutter/material.dart';

class ExploreShowProvider extends ChangeNotifier {
  List<Map<String, dynamic>> _books = [];
  bool _isLoading = false;
  String? _error;

  List<Map<String, dynamic>> get books => _books;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> loadExploreBooks(String sourceUrl, String exploreUrl) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await Future.delayed(const Duration(seconds: 1));
      _books = [];
    } catch (e) {
      _error = e.toString();
      debugPrint('加载发现内容失败: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (_isLoading) return;
  }

  void clear() {
    _books = [];
    _error = null;
    notifyListeners();
  }
}
