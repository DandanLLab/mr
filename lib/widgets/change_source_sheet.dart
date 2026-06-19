import 'package:flutter/material.dart';

import '../../models/book_source.dart';
import '../../services/source_engine/web_book.dart';
import '../../services/storage_service.dart';

/// 换源弹窗组件
/// 可在详情页和阅读器中使用
class ChangeSourceSheet extends StatefulWidget {
  final String bookName;
  final String bookAuthor;
  final String? currentSourceUrl;
  final String? currentSourceName;
  final Function(String sourceUrl, String sourceName, Map<String, dynamic> bookData) onSourceSelected;

  const ChangeSourceSheet({
    super.key,
    required this.bookName,
    required this.bookAuthor,
    this.currentSourceUrl,
    this.currentSourceName,
    required this.onSourceSelected,
  });

  /// 显示换源弹窗
  static void show({
    required BuildContext context,
    required String bookName,
    required String bookAuthor,
    String? currentSourceUrl,
    String? currentSourceName,
    required Function(String sourceUrl, String sourceName, Map<String, dynamic> bookData) onSourceSelected,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => ChangeSourceSheet(
        bookName: bookName,
        bookAuthor: bookAuthor,
        currentSourceUrl: currentSourceUrl,
        currentSourceName: currentSourceName,
        onSourceSelected: onSourceSelected,
      ),
    );
  }

  @override
  State<ChangeSourceSheet> createState() => _ChangeSourceSheetState();
}

class _ChangeSourceSheetState extends State<ChangeSourceSheet> {
  final List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchSources();
  }

  Future<void> _searchSources() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // 获取所有启用的书源
      final sourcesData = StorageService.instance.getAllBookSources();
      final sources = <BookSource>[];
      
      for (final data in sourcesData) {
        try {
          final source = BookSource.fromJson(data);
          if (source.enabled && source.searchUrl != null && source.searchUrl!.isNotEmpty) {
            sources.add(source);
          }
        } catch (e) {
          debugPrint('跳过无效书源: $e');
        }
      }

      if (sources.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = '没有可用的书源';
        });
        return;
      }

      // 使用书名+作者搜索
      final keyword = '${widget.bookName} ${widget.bookAuthor}'.trim();
      
      // 并发搜索所有书源
      final futures = <Future<void>>[];
      final results = <Map<String, dynamic>>[];
      
      for (final source in sources) {
        futures.add(() async {
          try {
            final searchResult = await WebBook(source).searchBook(keyword)
                .timeout(const Duration(seconds: 15));
            
            for (final book in searchResult) {
              // 检查是否匹配（书名相似）
              final bookName = (book['name'] as String?)?.trim() ?? '';
              if (_isNameMatch(widget.bookName, bookName)) {
                book['sourceUrl'] = source.bookSourceUrl;
                book['sourceName'] = source.bookSourceName;
                book['searchTime'] = DateTime.now().millisecondsSinceEpoch;
                results.add(book);
              }
            }
          } catch (e) {
            debugPrint('搜索书源 ${source.bookSourceName} 失败: $e');
          }
        }());
      }

      await Future.wait(futures);

      // 按书源名排序，当前书源排第一
      results.sort((a, b) {
        final aUrl = a['sourceUrl'] as String?;
        final bUrl = b['sourceUrl'] as String?;
        
        if (aUrl == widget.currentSourceUrl) return -1;
        if (bUrl == widget.currentSourceUrl) return 1;
        
        return (a['sourceName'] as String? ?? '').compareTo(b['sourceName'] as String? ?? '');
      });

      setState(() {
        _searchResults.clear();
        _searchResults.addAll(results);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = '搜索失败: $e';
      });
    }
  }

  bool _isNameMatch(String name1, String name2) {
    // 简单的名称匹配检查
    final n1 = name1.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final n2 = name2.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    
    // 完全匹配
    if (n1 == n2) return true;
    
    // 包含关系
    if (n1.contains(n2) || n2.contains(n1)) return true;
    
    // 相似度检查（至少80%相似）
    if (n1.length > 0 && n2.length > 0) {
      final longer = n1.length > n2.length ? n1 : n2;
      final shorter = n1.length > n2.length ? n2 : n1;
      int matchCount = 0;
      for (int i = 0; i < shorter.length; i++) {
        if (longer.contains(shorter[i])) matchCount++;
      }
      if (matchCount / shorter.length > 0.8) return true;
    }
    
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('换源', style: Theme.of(context).textTheme.titleLarge),
                      Text(
                        '${widget.bookName} - ${widget.bookAuthor}',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: _searchSources,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _buildContent(scrollController),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ScrollController scrollController) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在搜索书源...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _searchSources,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48),
            SizedBox(height: 16),
            Text('未找到匹配的书源'),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final result = _searchResults[index];
        final sourceUrl = result['sourceUrl'] as String?;
        final sourceName = result['sourceName'] as String? ?? '未知';
        final bookName = result['name'] as String? ?? '';
        final author = result['author'] as String? ?? '';
        final lastChapter = result['lastChapter'] as String? ?? '';
        final isCurrentSource = sourceUrl == widget.currentSourceUrl;

        return ListTile(
          leading: Icon(
            Icons.source,
            color: isCurrentSource ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  sourceName,
                  style: TextStyle(
                    fontWeight: isCurrentSource ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              if (isCurrentSource)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '当前',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (bookName.isNotEmpty && bookName != widget.bookName)
                Text('书名: $bookName', style: const TextStyle(fontSize: 12)),
              if (author.isNotEmpty && author != widget.bookAuthor)
                Text('作者: $author', style: const TextStyle(fontSize: 12)),
              if (lastChapter.isNotEmpty)
                Text('最新: $lastChapter', style: const TextStyle(fontSize: 12)),
            ],
          ),
          trailing: isCurrentSource
              ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: isCurrentSource
              ? null
              : () {
                  Navigator.pop(context);
                  widget.onSourceSelected(sourceUrl!, sourceName, result);
                },
        );
      },
    );
  }
}