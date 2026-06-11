import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  int _selectedGroupIndex = 0; // 保存当前选中的分组索引
  List<String> _customGroups = []; // 自定义分组

  List<Book> get books => _filteredBooks;
  String? get currentGroupId => _currentGroupId;
  SortType get sortType => _sortType;
  bool get isGridView => _isGridView;
  Set<String> get selectedBookIds => _selectedBookIds;
  bool get isBatchMode => _isBatchMode;
  int get selectedGroupIndex => _selectedGroupIndex;
  List<String> get customGroups => _customGroups;

  /// 加载自定义分组
  Future<void> loadCustomGroups() async {
    final prefs = await SharedPreferences.getInstance();
    _customGroups = prefs.getStringList('custom_groups') ?? [];
    notifyListeners();
  }

  /// 添加自定义分组
  Future<bool> addCustomGroup(String groupName) async {
    if (_customGroups.length >= 64) {
      return false; // 最多64个分组
    }
    if (groupName.isEmpty || _customGroups.contains(groupName)) {
      return false;
    }
    _customGroups.add(groupName);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_groups', _customGroups);
    notifyListeners();
    return true;
  }

  /// 删除自定义分组
  Future<void> removeCustomGroup(String groupName) async {
    _customGroups.remove(groupName);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_groups', _customGroups);
    notifyListeners();
  }

  /// 重命名自定义分组
  Future<bool> renameCustomGroup(String oldName, String newName) async {
    if (newName.isEmpty || (_customGroups.contains(newName) && newName != oldName)) {
      return false;
    }
    final index = _customGroups.indexOf(oldName);
    if (index == -1) return false;
    _customGroups[index] = newName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('custom_groups', _customGroups);
    notifyListeners();
    return true;
  }

  /// 获取动态分组列表（只显示有书籍的分组）
  List<String> getVisibleGroups() {
    final groups = <String>[];

    // 全部分组：始终显示（如果有书籍）
    if (_books.isNotEmpty) {
      groups.add('全部');
    }

    // 本地分组：有本地书籍且没有自定义分组时显示
    if (_books.any((book) =>
        book.originType == BookOriginType.local && book.groupId == null)) {
      groups.add('本地');
    }

    // 小说分组：有小说且没有自定义分组时显示
    if (_books.any((book) =>
        book.mediaType == MediaType.novel && book.groupId == null)) {
      groups.add('小说');
    }

    // 音频分组：有音频且没有自定义分组时显示
    if (_books.any((book) =>
        book.mediaType == MediaType.audio && book.groupId == null)) {
      groups.add('音频');
    }

    // 漫画分组：有漫画且没有自定义分组时显示
    if (_books.any((book) =>
        book.mediaType == MediaType.comic && book.groupId == null)) {
      groups.add('漫画');
    }

    // 视频分组：有视频且没有自定义分组时显示
    if (_books.any((book) =>
        book.mediaType == MediaType.video && book.groupId == null)) {
      groups.add('视频');
    }

    // 自定义分组：有对应书籍时显示
    for (final group in _customGroups) {
      if (_books.any((book) => book.groupId == group)) {
        groups.add(group);
      }
    }

    return groups;
  }

  /// 获取所有分组（用于分组管理）
  List<String> getAllGroups() {
    final groups = <String>['全部', '本地', '小说', '音频', '漫画', '视频'];
    groups.addAll(_customGroups);
    return groups;
  }

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

  void setSelectedGroupIndex(int index) {
    _selectedGroupIndex = index;
    notifyListeners();
  }

  /// 根据分组名称获取书籍列表（用于 PageView）
  List<Book> getBooksByGroup(String groupName) {
    List<Book> sourceBooks;

    if (groupName == '全部') {
      sourceBooks = _books;
    } else if (groupName == '本地') {
      // 本地分组：只显示没有自定义分组的本地书籍
      sourceBooks = _books.where((book) =>
        book.originType == BookOriginType.local && book.groupId == null
      ).toList();
    } else if (groupName == '小说') {
      // 小说分组：只显示没有自定义分组的小说
      sourceBooks = _books.where((book) =>
        book.mediaType == MediaType.novel && book.groupId == null
      ).toList();
    } else if (groupName == '音频') {
      // 音频分组：只显示没有自定义分组的音频
      sourceBooks = _books.where((book) =>
        book.mediaType == MediaType.audio && book.groupId == null
      ).toList();
    } else if (groupName == '漫画') {
      // 漫画分组：只显示没有自定义分组的漫画
      sourceBooks = _books.where((book) =>
        book.mediaType == MediaType.comic && book.groupId == null
      ).toList();
    } else if (groupName == '视频') {
      // 视频分组：只显示没有自定义分组的视频
      sourceBooks = _books.where((book) =>
        book.mediaType == MediaType.video && book.groupId == null
      ).toList();
    } else {
      // 自定义分组：显示该分组的书籍
      sourceBooks = _books.where((book) => book.groupId == groupName).toList();
    }

    switch (_sortType) {
      case SortType.recentRead:
        sourceBooks.sort((a, b) {
          final aTime = a.durChapterTime ?? DateTime(1970);
          final bTime = b.durChapterTime ?? DateTime(1970);
          return bTime.compareTo(aTime);
        });
        break;
      case SortType.recentUpdate:
        sourceBooks.sort((a, b) {
          final aTime = a.lastCheckTime ?? DateTime(1970);
          final bTime = b.lastCheckTime ?? DateTime(1970);
          return bTime.compareTo(aTime);
        });
        break;
      case SortType.nameAsc:
        sourceBooks.sort((a, b) => a.name.compareTo(b.name));
        break;
      case SortType.addedTime:
        sourceBooks.sort((a, b) => b.addedTime.compareTo(a.addedTime));
        break;
    }

    final topBooks = sourceBooks.where((book) => book.isTop).toList();
    final normalBooks = sourceBooks.where((book) => !book.isTop).toList();
    return [...topBooks, ...normalBooks];
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
