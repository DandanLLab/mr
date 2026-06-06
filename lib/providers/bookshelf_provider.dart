import 'package:flutter/material.dart';
import '../models/book.dart';
import '../services/storage_service.dart';

enum SortType { recentRead, recentUpdate, nameAsc, addedTime }

class BookshelfProvider extends ChangeNotifier {
  List<Book> _books = [];
  List<Book> _filteredBooks = [];
  String? _currentGroupId;
  SortType _sortType = SortType.recentRead;
  bool _isGridView = true;
  final Set<String> _selectedBookIds = {};
  bool _isBatchMode = false;

  List<Book> get books => _filteredBooks;
  String? get currentGroupId => _currentGroupId;
  SortType get sortType => _sortType;
  bool get isGridView => _isGridView;
  Set<String> get selectedBookIds => _selectedBookIds;
  bool get isBatchMode => _isBatchMode;

  Future<void> loadBooks() async {
    final bookDataList = StorageService.instance.getAllBooks();
    _books = bookDataList.map((data) => Book.fromJson(data)).toList();
    _applyFilterAndSort();
    notifyListeners();
  }

  void _applyFilterAndSort() {
    var filtered = _books.where((book) {
      if (_currentGroupId == null) return true;
      return book.groupId == _currentGroupId;
    }).toList();

    switch (_sortType) {
      case SortType.recentRead:
        filtered.sort((a, b) {
          final aTime = a.durChapterTime ?? DateTime(1970);
          final bTime = b.durChapterTime ?? DateTime(1970);
          return bTime.compareTo(aTime);
        });
        break;
      case SortType.recentUpdate:
        filtered.sort((a, b) {
          final aTime = a.lastCheckTime ?? DateTime(1970);
          final bTime = b.lastCheckTime ?? DateTime(1970);
          return bTime.compareTo(aTime);
        });
        break;
      case SortType.nameAsc:
        filtered.sort((a, b) => a.name.compareTo(b.name));
        break;
      case SortType.addedTime:
        filtered.sort((a, b) => b.addedTime.compareTo(a.addedTime));
        break;
    }

    final topBooks = filtered.where((book) => book.isTop).toList();
    final normalBooks = filtered.where((book) => !book.isTop).toList();
    _filteredBooks = [...topBooks, ...normalBooks];
  }

  void setGroup(String? groupId) {
    _currentGroupId = groupId;
    _applyFilterAndSort();
    notifyListeners();
  }

  void setSortType(SortType type) {
    _sortType = type;
    _applyFilterAndSort();
    notifyListeners();
  }

  void toggleViewMode() {
    _isGridView = !_isGridView;
    notifyListeners();
  }

  Future<void> addToBookshelf(Book book) async {
    await StorageService.instance.addToBookshelf(book.toJson());
    _books.insert(0, book);
    _applyFilterAndSort();
    notifyListeners();
  }

  Future<void> removeFromBookshelf(String bookUrl) async {
    await StorageService.instance.removeFromBookshelf(bookUrl);
    _books.removeWhere((book) => book.bookUrl == bookUrl);
    _applyFilterAndSort();
    notifyListeners();
  }

  Future<void> toggleTop(String bookUrl) async {
    final index = _books.indexWhere((book) => book.bookUrl == bookUrl);
    if (index != -1) {
      _books[index] = _books[index].copyWith(isTop: !_books[index].isTop);
      await StorageService.instance.addToBookshelf(_books[index].toJson());
      _applyFilterAndSort();
      notifyListeners();
    }
  }

  Future<void> updateBookProgress(String bookUrl, {int? durChapterIndex, String? durChapterTitle, int? durChapterPos}) async {
    final index = _books.indexWhere((book) => book.bookUrl == bookUrl);
    if (index != -1) {
      _books[index] = _books[index].copyWith(
        durChapterIndex: durChapterIndex ?? _books[index].durChapterIndex,
        durChapterTitle: durChapterTitle ?? _books[index].durChapterTitle,
        durChapterPos: durChapterPos ?? _books[index].durChapterPos,
        durChapterTime: DateTime.now(),
      );
      await StorageService.instance.addToBookshelf(_books[index].toJson());
      _applyFilterAndSort();
      notifyListeners();
    }
  }

  void enterBatchMode() {
    _isBatchMode = true;
    _selectedBookIds.clear();
    notifyListeners();
  }

  void exitBatchMode() {
    _isBatchMode = false;
    _selectedBookIds.clear();
    notifyListeners();
  }

  void toggleBookSelection(String bookUrl) {
    if (_selectedBookIds.contains(bookUrl)) {
      _selectedBookIds.remove(bookUrl);
    } else {
      _selectedBookIds.add(bookUrl);
    }
    notifyListeners();
  }

  Future<void> moveBookToGroup(String bookUrl, String? groupId) async {
    final index = _books.indexWhere((book) => book.bookUrl == bookUrl);
    if (index != -1) {
      final json = _books[index].toJson();
      if (groupId != null) {
        json['groupId'] = groupId;
      } else {
        json.remove('groupId');
      }
      _books[index] = Book.fromJson(json);
      await StorageService.instance.addToBookshelf(_books[index].toJson());
      _applyFilterAndSort();
      notifyListeners();
    }
  }

  Future<void> batchRemove() async {
    for (final bookUrl in _selectedBookIds) {
      await removeFromBookshelf(bookUrl);
    }
    exitBatchMode();
  }
}
