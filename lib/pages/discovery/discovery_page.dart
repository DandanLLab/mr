import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/book_source.dart';
import '../../providers/discovery_provider.dart';
import '../../routes/app_routes.dart';
import '../../utils/design_tokens.dart';

/// 发现页分类数据结构（页面内定义，避免创建新文件）
class ExploreCategory {
  final String title;
  final String url;
  final List<ExploreCategory> children;

  const ExploreCategory({
    required this.title,
    required this.url,
    this.children = const [],
  });
}

class DiscoveryPage extends StatefulWidget {
  const DiscoveryPage({super.key});

  @override
  State<DiscoveryPage> createState() => _DiscoveryPageState();
}

class _DiscoveryPageState extends State<DiscoveryPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _sourceTagController = ScrollController();
  final ScrollController _categoryTagController = ScrollController();

  String _searchQuery = '';
  int _selectedSourceIndex = -1;
  int _selectedCategoryIndex = -1;
  String _sortMode = 'manual'; // manual / name / url / time / respond

  // 性能优化：缓存过滤结果和分类解析结果
  List<BookSource> _cachedFilteredSources = [];
  List<BookSource> _lastBookSources = [];
  String _lastSearchQuery = '';
  String _lastSortMode = 'manual';
  final Map<int, List<ExploreCategory>> _cachedCategories = {};

  @override
  void dispose() {
    _searchController.dispose();
    _sourceTagController.dispose();
    _categoryTagController.dispose();
    super.dispose();
  }

  /// 标签选中后自动居中
  void _scrollTagToCenter(ScrollController controller, int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      const itemWidth = DesignTokens.tagItemMaxWidth;
      final offset = index * itemWidth -
          controller.position.viewportDimension / 2 +
          itemWidth / 2;
      controller.animateTo(
        offset.clamp(0.0, controller.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _selectSource(int index) {
    setState(() {
      _selectedSourceIndex = index;
      _selectedCategoryIndex = -1;
    });
    _scrollTagToCenter(_sourceTagController, index);
  }

  void _selectCategory(int index) {
    setState(() {
      _selectedCategoryIndex = index;
    });
    _scrollTagToCenter(_categoryTagController, index);

    final provider = context.read<DiscoveryProvider>();
    final sources = _getFilteredSources(provider.bookSources);
    if (_selectedSourceIndex < 0 ||
        _selectedSourceIndex >= sources.length) {
      return;
    }
    final source = sources[_selectedSourceIndex];
    final categories = _getCategories(_selectedSourceIndex, source);
    if (index < 0 || index >= categories.length) return;
    _openExplore(source, categories[index]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 参考 legado-rimchars: ExploreFragment 现代模式
    // 顶栏使用 surface 背景，搜索框使用圆角胶囊样式
    final colorScheme = Theme.of(context).colorScheme;
    final onSurfaceColor = colorScheme.onSurface;
    final secondaryTextColor = colorScheme.onSurface.withValues(alpha: 0.6);

    return Scaffold(
      body: Column(
        children: [
          // 现代浮动顶栏（参考 MainTopBarView）
          _buildTopBar(colorScheme, onSurfaceColor, secondaryTextColor),
          // 一级标签栏（书源选择器）
          _buildPrimaryTagBar(colorScheme),
          // 二级标签栏（分类选择器）
          if (_selectedSourceIndex >= 0) _buildSecondaryTagBar(colorScheme),
          // 内容区
          Expanded(
            child: _buildContentArea(colorScheme),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(
    ColorScheme colorScheme,
    Color onSurfaceColor,
    Color secondaryTextColor,
  ) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
        left: DesignTokens.spacingLg,
        right: DesignTokens.spacingSm,
        bottom: DesignTokens.spacingSm,
      ),
      color: colorScheme.surface,
      child: SizedBox(
        height: DesignTokens.tagBarHeight,
        child: Row(
          children: [
            // 搜索框（参考 RoundedTagBarView 样式）
            Expanded(
              child: Container(
                height: DesignTokens.tagBarHeight,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius:
                      BorderRadius.circular(DesignTokens.panelRadius),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 3.0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索书源',
                    hintStyle: TextStyle(
                        fontSize: DesignTokens.fontSummary,
                        color: secondaryTextColor),
                    prefixIcon: Icon(Icons.search,
                        size: 18, color: secondaryTextColor),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: Icon(Icons.clear,
                                size: 16, color: secondaryTextColor),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                                _selectedSourceIndex = -1;
                                _selectedCategoryIndex = -1;
                              });
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: DesignTokens.spacingSm, vertical: 0),
                    isDense: true,
                  ),
                  style: TextStyle(
                      fontSize: DesignTokens.fontSummary,
                      color: onSurfaceColor),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                      _selectedSourceIndex = -1;
                      _selectedCategoryIndex = -1;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(width: DesignTokens.spacingXs),
            // 收藏分组
            IconButton(
              icon: Icon(Icons.folder_outlined,
                  size: 20, color: onSurfaceColor),
              tooltip: '收藏分组',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('收藏分组功能开发中'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            // 排序按钮
            PopupMenuButton<String>(
              icon: Icon(Icons.sort, size: 20, color: onSurfaceColor),
              tooltip: '排序',
              offset: const Offset(0, DesignTokens.topBarHeight),
              onSelected: (value) {
                setState(() {
                  _sortMode = value;
                  _selectedSourceIndex = -1;
                  _selectedCategoryIndex = -1;
                });
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'manual',
                  child: Text('手动排序',
                      style: TextStyle(color: onSurfaceColor)),
                ),
                PopupMenuItem(
                  value: 'name',
                  child: Text('按名称',
                      style: TextStyle(color: onSurfaceColor)),
                ),
                PopupMenuItem(
                  value: 'url',
                  child: Text('按URL',
                      style: TextStyle(color: onSurfaceColor)),
                ),
                PopupMenuItem(
                  value: 'time',
                  child: Text('按更新时间',
                      style: TextStyle(color: onSurfaceColor)),
                ),
                PopupMenuItem(
                  value: 'respond',
                  child: Text('按响应时间',
                      style: TextStyle(color: onSurfaceColor)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 一级标签栏（书源选择器）- RoundedTagBarView 风格
  Widget _buildPrimaryTagBar(ColorScheme colorScheme) {
    return Consumer<DiscoveryProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return const SizedBox.shrink();
        }
        final sources = _getFilteredSources(provider.bookSources);
        if (sources.isEmpty) return const SizedBox.shrink();

        return Container(
          height: DesignTokens.tagBarHeight,
          margin: const EdgeInsets.fromLTRB(
            DesignTokens.spacingLg,
            DesignTokens.spacingSm,
            DesignTokens.spacingLg,
            0,
          ),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
          ),
          child: ListView.builder(
            controller: _sourceTagController,
            scrollDirection: Axis.horizontal,
            itemExtent: DesignTokens.tagItemMaxWidth,
            padding: const EdgeInsets.symmetric(
              vertical: (DesignTokens.tagBarHeight - DesignTokens.tagHeight) / 2,
            ),
            itemCount: sources.length,
            itemBuilder: (context, index) {
              final isSelected = index == _selectedSourceIndex;
              return _buildTagItem(
                sources[index].bookSourceName,
                isSelected,
                colorScheme,
                onTap: () => _selectSource(index),
                onLongPress: () => _showSourceOptions(sources[index]),
              );
            },
          ),
        );
      },
    );
  }

  /// 二级标签栏（分类选择器）
  Widget _buildSecondaryTagBar(ColorScheme colorScheme) {
    return Consumer<DiscoveryProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return const SizedBox.shrink();
        }
        final sources = _getFilteredSources(provider.bookSources);
        if (_selectedSourceIndex < 0 ||
            _selectedSourceIndex >= sources.length) {
          return const SizedBox.shrink();
        }
        final source = sources[_selectedSourceIndex];
        final categories = _getCategories(_selectedSourceIndex, source);
        if (categories.isEmpty) return const SizedBox.shrink();

        return Container(
          height: DesignTokens.tagBarHeight,
          margin: const EdgeInsets.fromLTRB(
            DesignTokens.spacingLg,
            DesignTokens.spacingSm,
            DesignTokens.spacingLg,
            0,
          ),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
          ),
          child: ListView.builder(
            controller: _categoryTagController,
            scrollDirection: Axis.horizontal,
            itemExtent: DesignTokens.tagItemMaxWidth,
            padding: const EdgeInsets.symmetric(
              vertical: (DesignTokens.tagBarHeight - DesignTokens.tagHeight) / 2,
            ),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final isSelected = index == _selectedCategoryIndex;
              return _buildTagItem(
                categories[index].title,
                isSelected,
                colorScheme,
                onTap: () => _selectCategory(index),
              );
            },
          ),
        );
      },
    );
  }

  /// 标签项构建（RoundedTagBarView 风格）
  Widget _buildTagItem(
    String label,
    bool isSelected,
    ColorScheme colorScheme, {
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return Container(
      height: DesignTokens.tagHeight,
      margin: const EdgeInsets.symmetric(horizontal: 2.0),
      constraints: const BoxConstraints(
        minWidth: DesignTokens.tagItemMinWidth,
        maxWidth: DesignTokens.tagItemMaxWidth,
      ),
      child: Material(
        color: isSelected ? colorScheme.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: DesignTokens.tagItemPaddingHorizontal,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: DesignTokens.fontBody,
                fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                color: isSelected
                    ? colorScheme.secondary
                    : colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 内容区
  Widget _buildContentArea(ColorScheme colorScheme) {
    return Consumer<DiscoveryProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        final sources = _getFilteredSources(provider.bookSources);

        if (sources.isEmpty) {
          return _buildEmptyState(
            icon: Icons.explore_outlined,
            message: _searchQuery.isEmpty ? '暂无发现内容' : '未找到匹配的书源',
            colorScheme: colorScheme,
            actionText: _searchQuery.isEmpty ? '去导入书源' : null,
            onAction: _searchQuery.isEmpty
                ? () => Navigator.pushNamed(context, AppRoutes.profile)
                : null,
          );
        }

        if (_selectedSourceIndex < 0 ||
            _selectedSourceIndex >= sources.length) {
          return _buildEmptyState(
            icon: Icons.touch_app_outlined,
            message: '选择书源开始发现',
            colorScheme: colorScheme,
          );
        }

        final source = sources[_selectedSourceIndex];
        final categories = _getCategories(_selectedSourceIndex, source);

        if (categories.isEmpty) {
          return _buildEmptyState(
            icon: Icons.category_outlined,
            message: '该书源暂无分类',
            colorScheme: colorScheme,
          );
        }

        // 已选中书源，显示所有分类卡片（Wrap 布局）
        return _buildCategoryCards(source, categories, colorScheme);
      },
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String message,
    required ColorScheme colorScheme,
    String? actionText,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: DesignTokens.emptyIconSize,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: DesignTokens.spacingLg),
          Text(
            message,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          if (actionText != null && onAction != null) ...[
            const SizedBox(height: DesignTokens.spacingSm),
            TextButton(
              onPressed: onAction,
              child: Text(actionText),
            ),
          ],
        ],
      ),
    );
  }

  /// 分类卡片（Wrap 布局）
  Widget _buildCategoryCards(
    BookSource source,
    List<ExploreCategory> categories,
    ColorScheme colorScheme,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(DesignTokens.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${source.bookSourceName} 的分类',
            style: TextStyle(
              fontSize: DesignTokens.fontSubtitle,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: DesignTokens.spacingLg),
          Wrap(
            spacing: DesignTokens.spacingSm,
            runSpacing: DesignTokens.spacingSm,
            children: categories.map((category) {
              return _buildCategoryCard(source, category, colorScheme);
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryCard(
    BookSource source,
    ExploreCategory category,
    ColorScheme colorScheme,
  ) {
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
      child: InkWell(
        onTap: () => _openExplore(source, category),
        borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: DesignTokens.spacingSm,
          ),
          child: Text(
            category.title,
            style: TextStyle(
              fontSize: DesignTokens.fontBody,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  /// 获取过滤后的书源列表（带缓存，避免每次 build 重复计算）
  List<BookSource> _getFilteredSources(List<BookSource> sources) {
    if (_searchQuery == _lastSearchQuery &&
        _sortMode == _lastSortMode &&
        identical(sources, _lastBookSources)) {
      return _cachedFilteredSources;
    }
    _lastSearchQuery = _searchQuery;
    _lastSortMode = _sortMode;
    _lastBookSources = sources;
    _cachedFilteredSources = _filterSources(sources);
    _cachedCategories.clear();
    return _cachedFilteredSources;
  }

  /// 获取分类列表（带缓存，按书源索引缓存）
  List<ExploreCategory> _getCategories(
    int sourceIndex,
    BookSource source,
  ) {
    if (_cachedCategories.containsKey(sourceIndex)) {
      return _cachedCategories[sourceIndex]!;
    }
    final categories = _parseExploreKinds(source.exploreUrl);
    _cachedCategories[sourceIndex] = categories;
    return categories;
  }

  List<BookSource> _filterSources(List<BookSource> sources) {
    var filtered = sources;
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((s) {
        return s.bookSourceName.toLowerCase().contains(query) ||
            (s.bookSourceGroup?.toLowerCase().contains(query) ?? false);
      }).toList();
    }
    final sorted = List<BookSource>.of(filtered);
    switch (_sortMode) {
      case 'name':
        sorted.sort((a, b) =>
            a.bookSourceName.compareTo(b.bookSourceName));
      case 'url':
        sorted.sort((a, b) =>
            a.bookSourceUrl.compareTo(b.bookSourceUrl));
      case 'time':
        sorted.sort((a, b) =>
            b.lastUpdateTime.compareTo(a.lastUpdateTime));
      case 'respond':
        sorted.sort((a, b) =>
            a.respondTime.compareTo(b.respondTime));
      case 'manual':
      default:
        break;
    }
    return sorted;
  }

  /// 解析 exploreUrl 为分类列表
  /// 支持以下格式：
  /// - `分类名称::url`（标准格式）
  /// - `分类名称@url`
  /// - `分类名称::url&&分类名称2::url2`（多分类格式）
  /// - JSON 格式的 exploreUrl
  List<ExploreCategory> _parseExploreKinds(String? exploreUrl) {
    if (exploreUrl == null || exploreUrl.isEmpty) return [];

    final categories = <ExploreCategory>[];

    // 尝试 JSON 格式
    try {
      final decoded = jsonDecode(exploreUrl);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final title = item['title']?.toString() ?? '';
            final url = item['url']?.toString() ?? '';
            if (title.isNotEmpty && url.isNotEmpty) {
              categories.add(ExploreCategory(title: title, url: url));
            }
          }
        }
        return categories;
      } else if (decoded is Map) {
        decoded.forEach((key, value) {
          if (value is List) {
            final children = <ExploreCategory>[];
            for (final child in value) {
              if (child is Map) {
                final cTitle = child['title']?.toString() ?? '';
                final cUrl = child['url']?.toString() ?? '';
                if (cTitle.isNotEmpty && cUrl.isNotEmpty) {
                  children.add(ExploreCategory(title: cTitle, url: cUrl));
                }
              }
            }
            categories.add(ExploreCategory(
              title: key.toString(),
              url: '',
              children: children,
            ));
          } else if (value is String) {
            categories.add(ExploreCategory(title: key.toString(), url: value));
          }
        });
        return categories;
      }
    } catch (_) {
      // 不是 JSON，继续用文本格式解析
    }

    // 文本格式解析
    final lines = exploreUrl.split('\n');
    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      // 处理 && 分隔的多分类
      final segments = line.split('&&');
      for (final segment in segments) {
        final trimmed = segment.trim();
        if (trimmed.isEmpty) continue;

        // 支持 :: 格式
        if (trimmed.contains('::')) {
          final parts = trimmed.split('::');
          if (parts.length >= 2) {
            categories.add(ExploreCategory(
              title: parts[0].trim(),
              url: parts.sublist(1).join('::').trim(),
            ));
          }
        }
        // 支持 @ 格式
        else if (trimmed.contains('@')) {
          final parts = trimmed.split('@');
          if (parts.length >= 2) {
            categories.add(ExploreCategory(
              title: parts[0].trim(),
              url: parts.sublist(1).join('@').trim(),
            ));
          }
        }
      }
    }

    return categories;
  }

  void _openExplore(BookSource source, ExploreCategory category) {
    Navigator.pushNamed(
      context,
      AppRoutes.exploreShow,
      arguments: {
        'sourceUrl': source.bookSourceUrl,
        'sourceName': source.bookSourceName,
        'exploreName': category.title,
        'exploreUrl': category.url,
      },
    );
  }

  void _showSourceOptions(BookSource source) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('搜索书籍'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(
                    context,
                    AppRoutes.search,
                    arguments: {'sourceUrl': source.bookSourceUrl},
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('编辑书源'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(
                    context,
                    AppRoutes.bookSourceEdit,
                    arguments: {'sourceUrl': source.bookSourceUrl},
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.push_pin),
                title: const Text('置顶'),
                onTap: () {
                  Navigator.pop(context);
                  context
                      .read<DiscoveryProvider>()
                      .pinSource(source.bookSourceUrl);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '删除',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(source);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmDelete(BookSource source) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认删除'),
          content: Text('确定要删除书源 "${source.bookSourceName}" 吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                context.read<DiscoveryProvider>().deleteSource(source.bookSourceUrl);
              },
              child: Text(
                '删除',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
