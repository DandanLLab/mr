import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../providers/search_provider.dart';
import '../../providers/app_provider.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../routes/app_routes.dart';
import '../../services/cover_config_service.dart';

class SearchPage extends StatefulWidget {
  final String? initialKeyword;

  const SearchPage({super.key, this.initialKeyword});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isGridView = false;
  bool _precisionSearch = false;
  bool _showSearchProgress = true;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<SearchProvider>();
      // 清空上次搜索结果
      provider.clearResults();
      provider.loadBookSources();
      provider.loadSearchHistory();
    });

    if (widget.initialKeyword != null) {
      _searchController.text = widget.initialKeyword!;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appProvider = context.watch<AppProvider>();
    final searchRadius = appProvider.currentSearchFollow
        ? 10 * appProvider.currentCornerScale
        : 16.0;
    return Scaffold(
      body: Consumer<SearchProvider>(
        builder: (context, provider, child) {
          return Column(
            children: [
              // TitleBar + 搜索框（参考原版）
              Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top,
                ),
                color: Theme.of(context).colorScheme.surface,
                child: Column(
                  children: [
                    // 顶部栏：返回按钮 + 搜索框 + 搜索按钮
                    SizedBox(
                      height: 48,
                      child: Row(
                        children: [
                          // 返回按钮
                          IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () => Navigator.pop(context),
                          ),
                          // 搜索框（参考原版：高度30dp）
                          Expanded(
                            child: SizedBox(
                              height: 32,
                              child: TextField(
                                controller: _searchController,
                                focusNode: _focusNode,
                                decoration: InputDecoration(
                                  hintText: '搜索书籍、漫画、视频...',
                                  hintStyle: const TextStyle(fontSize: 13),
                                  prefixIcon: const Icon(Icons.search, size: 16),
                                  suffixIcon: _searchController.text.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(Icons.clear, size: 16),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () {
                                            _searchController.clear();
                                            provider.clearResults();
                                          },
                                        )
                                      : null,
                                   border: OutlineInputBorder(
                                     borderRadius: BorderRadius.circular(
                                       searchRadius,
                                     ),
                                   ),
                                   filled: appProvider.currentSearchFollow,
                                   fillColor: appProvider.currentSearchFollow
                                       ? Theme.of(context)
                                             .colorScheme
                                             .surface
                                             .withValues(
                                               alpha:
                                                   appProvider
                                                       .currentLayoutAlpha /
                                                   100,
                                             )
                                       : null,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                  isDense: true,
                                ),
                                style: const TextStyle(fontSize: 13),
                                onSubmitted: (_) => _performSearch(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // 更多菜单（参考原版）
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            tooltip: '更多选项',
                            offset: const Offset(0, 48),
                            onSelected: (value) => _handleMenuSelection(value, provider),
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                value: 'precision_search',
                                height: 40,
                                child: Row(
                                  children: [
                                    const Text('精准搜索'),
                                    const Spacer(),
                                    SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: Checkbox(
                                        value: _precisionSearch,
                                        onChanged: null,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'show_search_progress',
                                height: 40,
                                child: Row(
                                  children: [
                                    const Text('显示搜索进度'),
                                    const Spacer(),
                                    SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: Checkbox(
                                        value: _showSearchProgress,
                                        onChanged: null,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuItem(
                                value: 'grid_view',
                                height: 40,
                                child: Row(
                                  children: [
                                    const Text('网格视图'),
                                    const Spacer(),
                                    SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: Checkbox(
                                        value: _isGridView,
                                        onChanged: null,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const PopupMenuDivider(),
                              const PopupMenuItem(
                                value: 'source_manage',
                                height: 40,
                                child: Text('书源管理'),
                              ),
                              const PopupMenuItem(
                                value: 'search_scope',
                                height: 40,
                                child: Text('分组或书源'),
                              ),
                              const PopupMenuDivider(),
                              const PopupMenuItem(
                                value: 'log',
                                height: 40,
                                child: Text('日志'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // 搜索进度条
              if (provider.isLoading)
                const LinearProgressIndicator(minHeight: 2),
              // 搜索进度显示
              if (_showSearchProgress && provider.searchResults.isNotEmpty && provider.isLoading)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '结果 ${provider.searchResults.length}',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // 内容区域
              Expanded(
                child: provider.error != null
                    ? _buildErrorState(provider)
                    : provider.searchResults.isNotEmpty
                        ? _buildResultsView(provider)
                        : provider.isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : _buildEmptyState(provider),
              ),
            ],
          );
        },
      ),
      // 停止搜索按钮（参考原版 FloatingActionButton）
      floatingActionButton: Consumer<SearchProvider>(
        builder: (context, provider, child) {
          if (!provider.isLoading || provider.searchResults.isEmpty) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton.small(
            onPressed: () => provider.stopSearch(),
            child: const Icon(Icons.stop),
          );
        },
      ),
    );
  }

  Widget _buildResultsView(SearchProvider provider) {
    return Column(
      children: [
        // 过滤器栏
        _buildFilters(provider),
        // 结果列表
        Expanded(
          child: _isGridView
              ? _buildGridView(provider)
              : _buildListView(provider),
        ),
      ],
    );
  }

  Widget _buildFilters(SearchProvider provider) {
    // 过滤器栏已移除，功能整合到更多菜单
    return const SizedBox.shrink();
  }

  Widget _buildErrorState(SearchProvider provider) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            provider.error!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => _showSourceFilter(provider),
            child: const Text('选择书源'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(SearchProvider provider) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (provider.searchHistory.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '搜索历史',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextButton(
                    onPressed: () => provider.clearHistory(),
                    child: const Text('清空'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: provider.searchHistory.map((keyword) {
                  return InputChip(
                    label: Text(keyword),
                    onPressed: () {
                      _searchController.text = keyword;
                      _performSearch();
                    },
                    onDeleted: () => provider.removeFromHistory(keyword),
                  );
                }).toList(),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.search,
                  size: 80,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  '输入关键词搜索',
                  style: TextStyle(
                    fontSize: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (provider.bookSources.isEmpty) ...[
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pushNamed(context, AppRoutes.profile);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('导入书源'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListView(SearchProvider provider) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: provider.searchResults.length,
      itemBuilder: (context, index) {
        final result = provider.searchResults[index];
        return _buildListResultItem(result);
      },
    );
  }

  Widget _buildListResultItem(Map<String, dynamic> result) {
    // 参考原版布局：封面 80x110，书名16sp，作者/最新/简介12sp
    final coverUrl = result['coverUrl']?.toString() ?? '';
    final intro = result['intro']?.toString().trim() ?? '';
    final lastChapter = result['lastChapter']?.toString().trim() ?? '';
    final author = result['author']?.toString().trim() ?? '未知作者';
    final sourceName = result['sourceName']?.toString().trim() ?? '';
    final tags = _resultTags(result);

    return RepaintBoundary(
      child: InkWell(
      onTap: () => _openDetail(result),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面（参考原版：80x110）
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 80,
                height: 110,
                child: _buildSearchCoverImage(
                  coverUrl,
                  bookName: result['name']?.toString(),
                  bookAuthor: author,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 右侧信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 书名（参考原版：16sp）
                  Text(
                    result['name']?.toString() ?? '未知书名',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  // 作者（参考原版：12sp）
                  Text(
                    '作者：$author',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  // 分类标签
                  if (tags.isNotEmpty)
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: tags.take(3).map((tag) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            tag,
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  if (tags.isNotEmpty) const SizedBox(height: 3),
                  // 最新章节（参考原版：12sp）
                  Text(
                    lastChapter.isEmpty ? '暂无章节' : '最新：$lastChapter',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  // 简介（参考原版：12sp）
                  Text(
                    intro.isEmpty ? '暂无简介' : intro,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  // 书源名称
                  if (sourceName.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      sourceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildGridView(SearchProvider provider) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.58,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: provider.searchResults.length,
      itemBuilder: (context, index) {
        final result = provider.searchResults[index];
        return _buildGridResultItem(result);
      },
    );
  }

  Widget _buildGridResultItem(Map<String, dynamic> result) {
    // 参考原版布局优化
    final coverUrl = result['coverUrl']?.toString() ?? '';
    final lastChapter = result['lastChapter']?.toString().trim() ?? '';
    final author = result['author']?.toString().trim() ?? '未知作者';
    final sourceName = result['sourceName']?.toString().trim() ?? '';
    
    return GestureDetector(
      onTap: () => _openDetail(result),
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 封面
            Expanded(
              child: _buildSearchCoverImage(
                coverUrl,
                bookName: result['name']?.toString(),
                bookAuthor: author,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 书名
                  Text(
                    result['name'] ?? '未知书名',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // 作者
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // 最新章节
                  Text(
                    lastChapter.isEmpty ? '暂无章节' : lastChapter,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  // 书源
                  if (sourceName.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      sourceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder({String? bookName, String? bookAuthor}) {
    final coverConfig = CoverConfigService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (bookName != null && bookName.isNotEmpty) {
      return coverConfig.buildDefaultCoverPlaceholder(
        bookName: bookName,
        bookAuthor: bookAuthor,
        isDark: isDark,
      );
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.book, size: 36)),
    );
  }

  /// 构建搜索结果封面 - 接入封面配置
  Widget _buildSearchCoverImage(String coverUrl, {String? bookName, String? bookAuthor}) {
    final coverConfig = CoverConfigService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (coverConfig.useDefaultCover) {
      return coverConfig.buildDefaultCoverPlaceholder(
        bookName: bookName ?? '',
        bookAuthor: bookAuthor,
        isDark: isDark,
      );
    }

    if (coverUrl.isNotEmpty) {
      final memCacheWidth = coverConfig.loadCoverHighQuality ? null : 240;
      final maxWidthDiskCache = coverConfig.loadCoverHighQuality ? null : 320;
      return CachedNetworkImage(
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        memCacheWidth: memCacheWidth,
        maxWidthDiskCache: maxWidthDiskCache,
        placeholder: (_, __) => _coverPlaceholder(bookName: bookName, bookAuthor: bookAuthor),
        errorWidget: (_, __, ___) => _coverPlaceholder(bookName: bookName, bookAuthor: bookAuthor),
      );
    }

    return _coverPlaceholder(bookName: bookName, bookAuthor: bookAuthor);
  }

  List<String> _resultTags(Map<String, dynamic> result) {
    final rawTags = result['tags'];
    if (rawTags is List) {
      return rawTags
          .map((tag) => tag.toString().trim())
          .where((tag) => tag.isNotEmpty)
          .toList();
    }
    final kind = result['kind']?.toString() ?? '';
    return kind
        .split(RegExp(r'[,，/|·\s]+'))
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
  }

  void _openDetail(Map<String, dynamic> result) {
    final bookData = <String, dynamic>{
      ...result,
      'mediaType': _mediaTypeForResult(result).index,
      'originType': BookOriginType.online.index,
      'addedTime': DateTime.now().toIso8601String(),
    };
    Navigator.pushNamed(
      context,
      AppRoutes.detail,
      arguments: {
        'bookUrl': result['bookUrl'],
        'bookData': bookData,
      },
    );
  }

  MediaType _mediaTypeForResult(Map<String, dynamic> result) {
    final sourceUrl = result['sourceUrl']?.toString();
    final source = context
        .read<SearchProvider>()
        .bookSources
        .where((item) => item.bookSourceUrl == sourceUrl)
        .firstOrNull;
    switch (source?.bookSourceType) {
      case BookSourceType.image:
        return MediaType.comic;
      case BookSourceType.video:
        return MediaType.video;
      case BookSourceType.audio:
        return MediaType.audio;
      default:
        return MediaType.novel;
    }
  }

  void _performSearch() {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;
    context.read<SearchProvider>().search(keyword, precisionSearch: _precisionSearch);
  }

  void _handleMenuSelection(String value, SearchProvider provider) {
    switch (value) {
      case 'precision_search':
        setState(() {
          _precisionSearch = !_precisionSearch;
        });
        break;
      case 'show_search_progress':
        setState(() {
          _showSearchProgress = !_showSearchProgress;
        });
        break;
      case 'grid_view':
        setState(() {
          _isGridView = !_isGridView;
        });
        break;
      case 'source_manage':
        Navigator.pushNamed(context, AppRoutes.bookSourceManage);
        break;
      case 'search_scope':
        _showSearchScopeDialog(provider);
        break;
      case 'log':
        _showLogDialog();
        break;
    }
  }

  void _showSearchScopeDialog(SearchProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择搜索范围'),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: ListView(
              children: [
                ListTile(
                  title: const Text('全部书源'),
                  trailing: Radio<bool>(
                    value: true,
                    groupValue: provider.selectedSourceUrls.length == provider.bookSources.length,
                    onChanged: (_) {
                      provider.selectAllSources();
                      Navigator.pop(context);
                    },
                  ),
                  onTap: () {
                    provider.selectAllSources();
                    Navigator.pop(context);
                  },
                ),
                const Divider(),
                ...provider.bookSources.map((source) {
                  final isSelected = provider.selectedSourceUrls.contains(source.bookSourceUrl);
                  return ListTile(
                    title: Text(source.bookSourceName),
                    subtitle: Text(
                      source.bookSourceGroup ?? '默认分组',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Checkbox(
                      value: isSelected,
                      onChanged: (checked) {
                        provider.toggleSourceSelection(source.bookSourceUrl);
                      },
                    ),
                    onTap: () {
                      provider.toggleSourceSelection(source.bookSourceUrl);
                    },
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showLogDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('搜索日志'),
          content: const SizedBox(
            width: double.maxFinite,
            height: 300,
            child: Center(
              child: Text('暂无日志'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  void _showSourceFilter(SearchProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '选择书源 (${provider.bookSources.length})',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => provider.selectAllSources(),
                            child: const Text('全选'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('确定'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: provider.bookSources.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('暂无可用书源'),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  Navigator.pushNamed(
                                      context, AppRoutes.profile);
                                },
                                child: const Text('导入书源'),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: provider.bookSources.length,
                          itemBuilder: (context, index) {
                            final source = provider.bookSources[index];
                            final isSelected = provider.selectedSourceUrls
                                .contains(source.bookSourceUrl);
                            return CheckboxListTile(
                              value: isSelected,
                              onChanged: (checked) {
                                provider.toggleSourceSelection(
                                    source.bookSourceUrl);
                              },
                              title: Text(source.bookSourceName),
                              subtitle: Text(
                                source.bookSourceGroup ?? '默认分组',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                              secondary: _buildSourceTypeIcon(source),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSourceTypeIcon(BookSource source) {
    IconData icon;
    switch (source.bookSourceType) {
      case BookSourceType.text:
        icon = Icons.book;
        break;
      case BookSourceType.audio:
        icon = Icons.headphones;
        break;
      case BookSourceType.image:
        icon = Icons.image;
        break;
      case BookSourceType.video:
        icon = Icons.video_library;
        break;
      case BookSourceType.file:
        icon = Icons.folder;
        break;
    }
    return Icon(icon, size: 20);
  }
}
