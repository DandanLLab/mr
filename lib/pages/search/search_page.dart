import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../providers/search_provider.dart';
import '../../providers/app_provider.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../routes/app_routes.dart';
import '../../services/cover_config_service.dart';
import '../../services/app_logger.dart';
import '../../utils/design_tokens.dart';

class SearchPage extends StatefulWidget {
  final String? initialKeyword;
  final String? sourceUrl;

  const SearchPage({super.key, this.initialKeyword, this.sourceUrl});

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

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<SearchProvider>();
      // 清空上次搜索结果
      provider.clearResults();
      await provider.loadBookSources();
      // 限定单书源搜索（来自发现页/书源编辑页的"搜索书籍"入口）
      if (widget.sourceUrl != null && widget.sourceUrl!.isNotEmpty) {
        provider.selectSingleSource(widget.sourceUrl!);
      } else {
        provider.restoreMultiSourceSelectionAfterSingleSourceRoute();
      }
      await provider.loadSearchHistory();
      if (!mounted) return;
      if (_searchController.text.trim().isNotEmpty) {
        _performSearch();
      }
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
        : DesignTokens.searchRadius;
    return Scaffold(
      body: Consumer<SearchProvider>(
        builder: (context, provider, child) {
          final secondaryTextColor = Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.68);
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
                      height: DesignTokens.topBarHeight,
                      child: Row(
                        children: [
                          // 返回按钮
                          IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () => Navigator.pop(context),
                          ),
                          // 搜索框（参考原版：高度32dp）
                          Expanded(
                            child: SizedBox(
                              height: 32,
                              child: TextField(
                                controller: _searchController,
                                focusNode: _focusNode,
                                decoration: InputDecoration(
                                  hintText: '搜索书籍、漫画、视频...',
                                  hintStyle: const TextStyle(fontSize: 13),
                                  prefixIcon: const Icon(
                                    Icons.search,
                                    size: DesignTokens.listItemIconSize * 0.67,
                                  ),
                                  suffixIcon: _searchController.text.isNotEmpty
                                      ? IconButton(
                                          icon: const Icon(
                                            Icons.clear,
                                            size:
                                                DesignTokens.listItemIconSize *
                                                0.67,
                                          ),
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
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.surface.withValues(
                                          alpha:
                                              appProvider.currentLayoutAlpha /
                                              100,
                                        )
                                      : null,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: DesignTokens.spacingSm,
                                    vertical: 0,
                                  ),
                                  isDense: true,
                                ),
                                style: const TextStyle(fontSize: 13),
                                onSubmitted: (_) => _performSearch(),
                              ),
                            ),
                          ),
                          const SizedBox(width: DesignTokens.spacingXs),
                          // 更多菜单（参考原版）
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            tooltip: '更多选项',
                            offset: const Offset(0, 48),
                            onSelected: (value) =>
                                _handleMenuSelection(value, provider),
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
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
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
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
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
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
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
              if (_showSearchProgress &&
                  provider.searchResults.isNotEmpty &&
                  provider.isLoading)
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: DesignTokens.spacingSm,
                  ),
                  child: Text(
                    '结果 ${provider.searchResults.length}',
                    style: TextStyle(
                      fontSize: DesignTokens.fontSummary,
                      color: secondaryTextColor,
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
          if (!provider.isLoading) {
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
            size: DesignTokens.emptyIconSize,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: DesignTokens.spacingLg),
          Text(
            provider.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: DesignTokens.spacingLg),
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
              padding: const EdgeInsets.all(DesignTokens.spacingLg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('搜索历史', style: Theme.of(context).textTheme.titleMedium),
                  TextButton(
                    onPressed: () => provider.clearHistory(),
                    child: const Text('清空'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.spacingLg,
              ),
              child: Wrap(
                spacing: DesignTokens.spacingSm,
                runSpacing: DesignTokens.spacingSm,
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
          const SizedBox(height: DesignTokens.spacingXxl),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.search,
                  size: DesignTokens.emptyIconSize,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: DesignTokens.spacingLg),
                Text(
                  '输入关键词搜索',
                  style: TextStyle(
                    fontSize: DesignTokens.fontTitle,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (provider.bookSources.isEmpty) ...[
                  const SizedBox(height: DesignTokens.spacingLg),
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
      padding: const EdgeInsets.symmetric(vertical: DesignTokens.spacingSm),
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
    final scheme = Theme.of(context).colorScheme;
    final secondaryTextColor = scheme.onSurface.withValues(alpha: 0.68);
    final chapterTextColor = scheme.brightness == Brightness.dark
        ? scheme.onSurface.withValues(alpha: 0.9)
        : scheme.primary;

    return RepaintBoundary(
      child: InkWell(
        onTap: () => _openDetail(result),
        child: Padding(
          padding: const EdgeInsets.all(DesignTokens.spacingSm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面（参考原版：80x110）
              ClipRRect(
                borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: DesignTokens.emptyIconSize,
                  height: 110.0,
                  child: _buildSearchCoverImage(
                    coverUrl,
                    bookName: result['name']?.toString(),
                    bookAuthor: author,
                    sourceUrl: result['sourceUrl']?.toString(),
                  ),
                ),
              ),
              const SizedBox(width: DesignTokens.spacingSm),
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
                        fontSize: DesignTokens.fontSubtitle,
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
                        fontSize: DesignTokens.fontCaption,
                        color: secondaryTextColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // 分类标签
                    if (tags.isNotEmpty)
                      Wrap(
                        spacing: DesignTokens.spacingXs,
                        runSpacing: 2,
                        children: tags.take(3).map((tag) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: DesignTokens.spacingXs,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.brightness == Brightness.dark
                                  ? scheme.surfaceContainerHighest
                                  : scheme.primaryContainer.withValues(
                                      alpha: 0.3,
                                    ),
                              borderRadius: BorderRadius.circular(
                                DesignTokens.actionRadius,
                              ),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: DesignTokens.fontCaption,
                                color: scheme.brightness == Brightness.dark
                                    ? scheme.onSurface
                                    : scheme.primary,
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
                        fontSize: DesignTokens.fontCaption,
                        color: lastChapter.isEmpty
                            ? secondaryTextColor
                            : chapterTextColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // 简介（参考原版：12sp）
                    Text(
                      intro.isEmpty ? '暂无简介' : intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: DesignTokens.fontCaption,
                        height: 1.3,
                        color: secondaryTextColor,
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
                          fontSize: DesignTokens.fontCaption,
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
      padding: const EdgeInsets.all(DesignTokens.spacingMd),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.58,
        crossAxisSpacing: DesignTokens.spacingMd,
        mainAxisSpacing: DesignTokens.spacingMd,
      ),
      itemCount: provider.searchResults.length,
      itemBuilder: (context, index) {
        final result = provider.searchResults[index];
        return RepaintBoundary(child: _buildGridResultItem(result));
      },
    );
  }

  Widget _buildGridResultItem(Map<String, dynamic> result) {
    // 参考原版布局优化
    final coverUrl = result['coverUrl']?.toString() ?? '';
    final lastChapter = result['lastChapter']?.toString().trim() ?? '';
    final author = result['author']?.toString().trim() ?? '未知作者';
    final sourceName = result['sourceName']?.toString().trim() ?? '';
    final scheme = Theme.of(context).colorScheme;
    final secondaryTextColor = scheme.onSurface.withValues(alpha: 0.68);
    final chapterTextColor = scheme.brightness == Brightness.dark
        ? scheme.onSurface.withValues(alpha: 0.9)
        : scheme.primary;

    return GestureDetector(
      onTap: () => _openDetail(result),
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
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
                sourceUrl: result['sourceUrl']?.toString(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(DesignTokens.spacingXs + 2),
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
                      fontSize: DesignTokens.fontCaption,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // 作者
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: DesignTokens.fontCaption,
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
                      fontSize: DesignTokens.fontCaption,
                      color: lastChapter.isEmpty
                          ? secondaryTextColor
                          : chapterTextColor,
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
                        fontSize: DesignTokens.fontCaption,
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
  ///
  /// [sourceUrl] 书源 URL，用于查找书源并提取防盗链请求头（Referer 等）
  Widget _buildSearchCoverImage(
    String coverUrl, {
    String? bookName,
    String? bookAuthor,
    String? sourceUrl,
  }) {
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
        httpHeaders: _buildCoverHeaders(sourceUrl),
        fit: BoxFit.cover,
        memCacheWidth: memCacheWidth,
        maxWidthDiskCache: maxWidthDiskCache,
        placeholder: (_, __) =>
            _coverPlaceholder(bookName: bookName, bookAuthor: bookAuthor),
        errorWidget: (_, __, ___) =>
            _coverPlaceholder(bookName: bookName, bookAuthor: bookAuthor),
      );
    }

    return _coverPlaceholder(bookName: bookName, bookAuthor: bookAuthor);
  }

  /// 根据书源 URL 构建封面图请求头
  ///
  /// 很多书源网站有防盗链机制，加载封面图时必须带 Referer 和 User-Agent，
  /// 否则返回 403 Forbidden。这里从书源的 header 字段提取请求头，
  /// 并自动补充 Referer（书源 URL）和默认 User-Agent。
  Map<String, String> _buildCoverHeaders(String? sourceUrl) {
    final headers = <String, String>{};
    if (sourceUrl == null || sourceUrl.isEmpty) return headers;

    // 从 SearchProvider 查找对应书源
    final source = context
        .read<SearchProvider>()
        .bookSources
        .where((s) => s.bookSourceUrl == sourceUrl)
        .firstOrNull;
    if (source == null) return headers;

    // 解析书源的 header 字段（可能是 JSON 格式或 Key: Value 按行格式）
    final headerStr = source.header;
    if (headerStr != null && headerStr.isNotEmpty) {
      try {
        final decoded = json.decode(headerStr);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            final val = value.toString();
            if (val.isNotEmpty) {
              headers[key.toString()] = val;
            }
          });
        }
      } catch (_) {
        // 非 JSON 格式，按行解析 Key: Value
        for (final line in headerStr.split('\n')) {
          final parts = line.split(':');
          if (parts.length >= 2) {
            final key = parts[0].trim();
            final val = parts.sublist(1).join(':').trim();
            if (key.isNotEmpty && val.isNotEmpty) {
              headers[key] = val;
            }
          }
        }
      }
    }

    // 补充 Referer（使用书源 URL 作为来源页，绕过防盗链）
    headers.putIfAbsent('Referer', () => _extractBaseUrl(sourceUrl));

    // 补充默认 User-Agent
    headers.putIfAbsent(
      'User-Agent',
      () =>
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    );

    return headers;
  }

  /// 从完整 URL 中提取根 URL（scheme://host），用作 Referer
  String _extractBaseUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        return '${uri.scheme}://${uri.host}';
      }
    } catch (_) {}
    return url;
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
      'mediaType': result['mediaType'] ?? _mediaTypeForResult(result).index,
      'originType': result['originType'] ?? BookOriginType.online.index,
      'addedTime': DateTime.now().toIso8601String(),
    };
    Navigator.pushNamed(
      context,
      AppRoutes.detail,
      arguments: {'bookUrl': result['bookUrl'], 'bookData': bookData},
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
    // 收起键盘
    FocusScope.of(context).unfocus();
    context.read<SearchProvider>().search(
      keyword,
      precisionSearch: _precisionSearch,
    );
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
    // 按分组聚合书源
    final Map<String, List<BookSource>> groupedSources = {};
    for (final source in provider.bookSources) {
      final group = source.bookSourceGroup ?? '默认分组';
      groupedSources.putIfAbsent(group, () => []).add(source);
    }

    // 记录展开状态
    final expandedGroups = <String>{};

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final allSelected =
                provider.selectedSourceUrls.length ==
                provider.bookSources.length;
            return AlertDialog(
              title: Row(
                children: [
                  const Text('选择搜索范围'),
                  const Spacer(),
                  Text(
                    '${provider.selectedSourceUrls.length}/${provider.bookSources.length}',
                    style: TextStyle(
                      fontSize: DesignTokens.fontSummary,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: ListView(
                  children: [
                    // 全部书源
                    ListTile(
                      leading: Icon(
                        allSelected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: allSelected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: const Text('全部书源'),
                      onTap: () {
                        if (allSelected) {
                          provider.deselectAllSources();
                        } else {
                          provider.selectAllSources();
                        }
                        setDialogState(() {});
                      },
                    ),
                    const Divider(),
                    // 按分组展示
                    ...groupedSources.entries.map((entry) {
                      final group = entry.key;
                      final sources = entry.value;
                      final selectedInGroup = sources
                          .where(
                            (s) => provider.selectedSourceUrls.contains(
                              s.bookSourceUrl,
                            ),
                          )
                          .length;
                      final allInGroupSelected =
                          selectedInGroup == sources.length;
                      final isExpanded = expandedGroups.contains(group);

                      return Column(
                        children: [
                          ListTile(
                            leading: IconButton(
                              icon: Icon(
                                isExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                              onPressed: () {
                                setDialogState(() {
                                  if (isExpanded) {
                                    expandedGroups.remove(group);
                                  } else {
                                    expandedGroups.add(group);
                                  }
                                });
                              },
                            ),
                            title: Text(group),
                            subtitle: Text(
                              '$selectedInGroup / ${sources.length}',
                              style: TextStyle(
                                fontSize: DesignTokens.fontCaption,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 仅搜此组按钮
                                TextButton(
                                  onPressed: () {
                                    provider.selectGroupSources(group);
                                    setDialogState(() {});
                                  },
                                  child: const Text(
                                    '仅搜此组',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                                Checkbox(
                                  value: allInGroupSelected,
                                  onChanged: (checked) {
                                    provider.toggleGroupSelection(group);
                                    setDialogState(() {});
                                  },
                                ),
                              ],
                            ),
                            onTap: () {
                              setDialogState(() {
                                if (isExpanded) {
                                  expandedGroups.remove(group);
                                } else {
                                  expandedGroups.add(group);
                                }
                              });
                            },
                          ),
                          if (isExpanded)
                            ...sources.map((source) {
                              final isSelected = provider.selectedSourceUrls
                                  .contains(source.bookSourceUrl);
                              return Padding(
                                padding: const EdgeInsets.only(left: 32),
                                child: ListTile(
                                  leading: Icon(
                                    _buildSourceTypeIcon(source).icon,
                                    size: DesignTokens.listItemIconSize * 0.67,
                                    color: isSelected
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                  title: Text(
                                    source.bookSourceName,
                                    style: TextStyle(
                                      fontSize: DesignTokens.fontBody,
                                    ),
                                  ),
                                  trailing: Checkbox(
                                    value: isSelected,
                                    onChanged: (checked) {
                                      provider.toggleSourceSelection(
                                        source.bookSourceUrl,
                                      );
                                      setDialogState(() {});
                                    },
                                  ),
                                  onTap: () {
                                    provider.toggleSourceSelection(
                                      source.bookSourceUrl,
                                    );
                                    setDialogState(() {});
                                  },
                                ),
                              );
                            }),
                        ],
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    provider.deselectAllSources();
                    setDialogState(() {});
                  },
                  child: const Text('清空'),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    // 选中书源后，如果有当前关键词，自动开始并发搜索
                    if (provider.currentKeyword.isNotEmpty &&
                        provider.selectedSourceUrls.isNotEmpty) {
                      provider.search(provider.currentKeyword);
                    }
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showLogDialog() {
    // 从 AppLogger 获取最近的日志（含 debugPrint 捕获的日志）
    final logs = AppLogger.instance.getLogs(minLevel: LogLevel.warning);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              const Text('搜索日志'),
              const Spacer(),
              Text(
                '${logs.length} 条',
                style: TextStyle(
                  fontSize: DesignTokens.fontCaption,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: logs.isEmpty
                ? const Center(child: Text('暂无日志'))
                : ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final entry = logs[logs.length - 1 - index];
                      final timeStr =
                          '${entry.time.hour.toString().padLeft(2, '0')}:'
                          '${entry.time.minute.toString().padLeft(2, '0')}:'
                          '${entry.time.second.toString().padLeft(2, '0')}';
                      final levelIcon = entry.level == LogLevel.error
                          ? '🔴'
                          : entry.level == LogLevel.warning
                          ? '🟡'
                          : '🔵';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: RichText(
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          text: TextSpan(
                            style: DefaultTextStyle.of(context).style.copyWith(
                              fontSize: DesignTokens.fontCaption,
                            ),
                            children: [
                              TextSpan(
                                text: '$timeStr $levelIcon ',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              TextSpan(
                                text: '[${entry.category.label}] ',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              TextSpan(text: entry.message),
                            ],
                          ),
                        ),
                      );
                    },
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
                  padding: const EdgeInsets.all(DesignTokens.spacingLg),
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
                              const SizedBox(height: DesignTokens.spacingLg),
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  Navigator.pushNamed(
                                    context,
                                    AppRoutes.profile,
                                  );
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
                                  source.bookSourceUrl,
                                );
                              },
                              title: Text(source.bookSourceName),
                              subtitle: Text(
                                source.bookSourceGroup ?? '默认分组',
                                style: TextStyle(
                                  fontSize: DesignTokens.fontCaption,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
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
    return Icon(icon, size: DesignTokens.listItemIconSize);
  }
}

extension on Widget {
  IconData? get icon => null;
}
