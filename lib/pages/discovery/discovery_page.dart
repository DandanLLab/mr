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

  String _searchQuery = '';
  String _sortMode = 'manual'; // manual / name / url / time / respond
  bool _sortAscending = true;
  // 当前选中的分组（参考 legado_max ExploreViewModel: searchView query "group:xxx"）
  String? _selectedGroup;

  // 当前展开的书源 URL（参考 legado_max ExploreAdapter.expandedSourceUrl）
  String? _expandedSourceUrl;

  // 性能优化：缓存过滤结果和分类解析结果
  List<BookSource> _cachedFilteredSources = [];
  List<BookSource> _lastBookSources = [];
  String _lastSearchQuery = '';
  String _lastSortMode = 'manual';
  bool _lastSortAscending = true;
  String? _lastSelectedGroup;
  final Map<String, List<ExploreCategory>> _cachedCategories = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 参考 legado_max: ExploreFragment 现代模式
    final colorScheme = Theme.of(context).colorScheme;
    final onSurfaceColor = colorScheme.onSurface;
    final secondaryTextColor = colorScheme.onSurface.withValues(alpha: 0.6);
    // 参考订阅页：顶栏使用 primary 背景，按明暗自适应前景色
    final primaryColor = colorScheme.primary;
    final appBarForeground =
        ThemeData.estimateBrightnessForColor(primaryColor) == Brightness.dark
            ? Colors.white
            : Colors.black;

    return Scaffold(
      body: Column(
        children: [
          // 顶栏（参考 legado_max fragment_explore.xml: TitleBar 标题"发现" + 搜索框 + 排序/分组菜单）
          _buildTopBar(colorScheme, onSurfaceColor, secondaryTextColor, primaryColor, appBarForeground),
          // 内容区：可展开的书源列表（参考 legado_max item_find_book）
          Expanded(
            child: _buildContentArea(colorScheme),
          ),
        ],
      ),
    );
  }

  /// 顶栏（参考 legado_max TitleBar: 标题"发现" + 搜索框 + 排序菜单 + 分组菜单）
  Widget _buildTopBar(
    ColorScheme colorScheme,
    Color onSurfaceColor,
    Color secondaryTextColor,
    Color primaryColor,
    Color appBarForeground,
  ) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
        left: DesignTokens.spacingLg,
        right: DesignTokens.spacingSm,
        bottom: DesignTokens.spacingSm,
      ),
      color: primaryColor,
      child: SizedBox(
        height: DesignTokens.tagBarHeight,
        child: Row(
          children: [
            // 标题"发现"（参考 legado_max fragment_explore.xml app:title="@string/discovery"）
            Text(
              '发现',
              style: TextStyle(
                fontSize: DesignTokens.fontTitle,
                fontWeight: FontWeight.w600,
                color: appBarForeground,
              ),
            ),
            const SizedBox(width: DesignTokens.spacingMd),
            // 搜索框（参考 legado_max view_search.xml）
            Expanded(
              child: Center(
                child: Container(
                  // 搜索框高度 30（参考 legado_max view_search.xml layout_height=30dp）
                  height: 30,
                  decoration: BoxDecoration(
                    color: appBarForeground.withValues(alpha: 0.15),
                    borderRadius:
                        BorderRadius.circular(DesignTokens.panelRadius),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 3.0),
                  child: TextField(
                    controller: _searchController,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      hintText: '筛选发现书源',
                      hintStyle: TextStyle(
                          fontSize: DesignTokens.fontSummary,
                          color: appBarForeground.withValues(alpha: 0.7)),
                      prefixIcon: Icon(Icons.search,
                          size: 18, color: appBarForeground.withValues(alpha: 0.7)),
                      prefixIconConstraints: const BoxConstraints(
                          minWidth: 28, minHeight: 28),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(Icons.clear,
                                  size: 16, color: appBarForeground.withValues(alpha: 0.7)),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _searchQuery = '';
                                  _expandedSourceUrl = null;
                                });
                              },
                            )
                          : null,
                      border: InputBorder.none,
                      isCollapsed: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: TextStyle(
                        fontSize: DesignTokens.fontSummary,
                        color: appBarForeground),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: DesignTokens.spacingXs),
            // 分组菜单（参考 legado_max main_explore.xml menu_group 子菜单）
            _buildGroupMenu(colorScheme, onSurfaceColor, appBarForeground),
            // 排序按钮（参考 legado_max main_explore.xml action_sort 子菜单）
            PopupMenuButton<String>(
              icon: Icon(Icons.sort, size: 20, color: appBarForeground),
              tooltip: '排序',
              offset: const Offset(0, DesignTokens.topBarHeight),
              onSelected: (value) {
                setState(() {
                  if (value == 'desc') {
                    _sortAscending = !_sortAscending;
                  } else {
                    _sortMode = value;
                    _sortAscending = true;
                  }
                  _expandedSourceUrl = null;
                });
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'desc',
                  child: Row(
                    children: [
                      Icon(
                        _sortAscending
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 18,
                        color: onSurfaceColor,
                      ),
                      const SizedBox(width: DesignTokens.spacingSm),
                      Text(_sortAscending ? '升序' : '降序',
                          style: TextStyle(color: onSurfaceColor)),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                _sortMenuItem('manual', '手动排序', onSurfaceColor),
                _sortMenuItem('name', '按名称', onSurfaceColor),
                _sortMenuItem('url', '按 URL', onSurfaceColor),
                _sortMenuItem('time', '按更新时间', onSurfaceColor),
                _sortMenuItem('respond', '按响应时间', onSurfaceColor),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 分组菜单（参考 legado_max ExploreFragment: groupsMenu 动态书源分组）
  Widget _buildGroupMenu(ColorScheme colorScheme, Color onSurfaceColor, Color triggerColor) {
    return Consumer<DiscoveryProvider>(
      builder: (context, provider, child) {
        final groups = _extractGroups(provider.bookSources);
        return PopupMenuButton<String>(
          icon: Icon(Icons.category_outlined, size: 20, color: triggerColor),
          tooltip: '分组',
          offset: const Offset(0, DesignTokens.topBarHeight),
          onSelected: (value) {
            setState(() {
              _selectedGroup = value == '__all__' ? null : value;
              _expandedSourceUrl = null;
            });
          },
          itemBuilder: (context) {
            final items = <PopupMenuEntry<String>>[
              PopupMenuItem(
                value: '__all__',
                child: Row(
                  children: [
                    Icon(
                      _selectedGroup == null
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 18,
                      color: onSurfaceColor,
                    ),
                    const SizedBox(width: DesignTokens.spacingSm),
                    Text('全部',
                        style: TextStyle(color: onSurfaceColor)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
            ];
            for (final group in groups) {
              items.add(PopupMenuItem(
                value: group,
                child: Row(
                  children: [
                    Icon(
                      _selectedGroup == group
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 18,
                      color: onSurfaceColor,
                    ),
                    const SizedBox(width: DesignTokens.spacingSm),
                    Text(group, style: TextStyle(color: onSurfaceColor)),
                  ],
                ),
              ));
            }
            return items;
          },
        );
      },
    );
  }

  /// 从书源列表提取分组（参考 legado_max BookSourceDao.dealGroups: 拆分逗号分隔的分组）
  List<String> _extractGroups(List<BookSource> sources) {
    final groupSet = <String>{};
    for (final source in sources) {
      final group = source.bookSourceGroup;
      if (group == null || group.trim().isEmpty) continue;
      for (final part in group.split(RegExp(r'[;；,，]'))) {
        final trimmed = part.trim();
        if (trimmed.isNotEmpty) groupSet.add(trimmed);
      }
    }
    return groupSet.toList()..sort();
  }

  PopupMenuItem<String> _sortMenuItem(
    String value,
    String label,
    Color onSurfaceColor,
  ) {
    final isSelected = _sortMode == value;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(
            isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 18,
            color: onSurfaceColor,
          ),
          const SizedBox(width: DesignTokens.spacingSm),
          Text(label, style: TextStyle(color: onSurfaceColor)),
        ],
      ),
    );
  }

  /// 内容区：可展开的书源列表（参考 legado_max ExploreAdapter）
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

        return ListView.builder(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + DesignTokens.spacingLg,
          ),
          itemCount: sources.length,
          itemBuilder: (context, index) {
            final source = sources[index];
            final isExpanded = _expandedSourceUrl == source.bookSourceUrl;
            return _buildSourceItem(source, isExpanded, colorScheme);
          },
        );
      },
    );
  }

  /// 书源项（参考 legado_max item_find_book.xml: 标题行 + 可展开分类区）
  Widget _buildSourceItem(
    BookSource source,
    bool isExpanded,
    ColorScheme colorScheme,
  ) {
    final categories = _getCategories(source);
    return Column(
      children: [
        // 标题行
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              setState(() {
                _expandedSourceUrl =
                    isExpanded ? null : source.bookSourceUrl;
              });
            },
            onLongPress: () => _showSourceOptions(source),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.spacingLg,
                vertical: DesignTokens.spacingMd,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      source.bookSourceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: DesignTokens.fontBody,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  // 展开/折叠箭头（参考 legado_max iv_status）
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 20,
                    color: colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 展开时显示分类标签（参考 legado_max flexbox）
        if (isExpanded)
          _buildCategoryWrap(source, categories, colorScheme),
        // 分隔线
        Divider(
          height: 1,
          thickness: DesignTokens.dividerHeight,
          color: DesignTokens.dividerColor(context),
        ),
      ],
    );
  }

  /// 分类标签区（参考 legado_max FlexboxLayout: Wrap 布局）
  Widget _buildCategoryWrap(
    BookSource source,
    List<ExploreCategory> categories,
    ColorScheme colorScheme,
  ) {
    if (categories.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          DesignTokens.spacingLg,
          DesignTokens.spacingSm,
          DesignTokens.spacingLg,
          DesignTokens.spacingMd,
        ),
        child: Text(
          '该书源暂无分类',
          style: TextStyle(
            fontSize: DesignTokens.fontSummary,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DesignTokens.spacingLg,
        DesignTokens.spacingSm,
        DesignTokens.spacingLg,
        DesignTokens.spacingMd,
      ),
      child: Wrap(
        spacing: DesignTokens.spacingSm,
        runSpacing: DesignTokens.spacingSm,
        children: categories.map((category) {
          return _buildCategoryChip(source, category, colorScheme);
        }).toList(),
      ),
    );
  }

  Widget _buildCategoryChip(
    BookSource source,
    ExploreCategory category,
    ColorScheme colorScheme,
  ) {
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
      child: InkWell(
        onTap: () => _openExplore(source, category),
        borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.tagItemPaddingHorizontal,
            vertical: DesignTokens.spacingXs,
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

  /// 获取过滤后的书源列表（带缓存，避免每次 build 重复计算）
  List<BookSource> _getFilteredSources(List<BookSource> sources) {
    if (_searchQuery == _lastSearchQuery &&
        _sortMode == _lastSortMode &&
        _sortAscending == _lastSortAscending &&
        _selectedGroup == _lastSelectedGroup &&
        identical(sources, _lastBookSources)) {
      return _cachedFilteredSources;
    }
    _lastSearchQuery = _searchQuery;
    _lastSortMode = _sortMode;
    _lastSortAscending = _sortAscending;
    _lastSelectedGroup = _selectedGroup;
    _lastBookSources = sources;
    _cachedFilteredSources = _filterSources(sources);
    _cachedCategories.clear();
    return _cachedFilteredSources;
  }

  /// 获取分类列表（带缓存，按书源 URL 缓存）
  List<ExploreCategory> _getCategories(BookSource source) {
    final key = source.bookSourceUrl;
    if (_cachedCategories.containsKey(key)) {
      return _cachedCategories[key]!;
    }
    final categories = _parseExploreKinds(source.exploreUrl);
    _cachedCategories[key] = categories;
    return categories;
  }

  List<BookSource> _filterSources(List<BookSource> sources) {
    var filtered = sources;
    // 分组过滤（参考 legado_max flowGroupExplore: bookSourceGroup 包含分组名）
    if (_selectedGroup != null) {
      final group = _selectedGroup!;
      filtered = filtered.where((s) {
        final g = s.bookSourceGroup;
        if (g == null || g.trim().isEmpty) return false;
        return g.split(RegExp(r'[;；,，]'))
            .map((e) => e.trim())
            .contains(group);
      }).toList();
    }
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered.where((s) {
        return s.bookSourceName.toLowerCase().contains(query) ||
            (s.bookSourceGroup?.toLowerCase().contains(query) ?? false);
      }).toList();
    }
    final sorted = List<BookSource>.of(filtered);
    int compare(BookSource a, BookSource b) {
      switch (_sortMode) {
        case 'name':
          return a.bookSourceName.compareTo(b.bookSourceName);
        case 'url':
          return a.bookSourceUrl.compareTo(b.bookSourceUrl);
        case 'time':
          return b.lastUpdateTime.compareTo(a.lastUpdateTime);
        case 'respond':
          return a.respondTime.compareTo(b.respondTime);
        case 'manual':
        default:
          return 0;
      }
    }

    if (_sortMode == 'manual') {
      // 手动排序按 customOrder，升序时正常顺序，降序时反转
      if (!_sortAscending) {
        return sorted.reversed.toList();
      }
      return sorted;
    }

    sorted.sort(compare);
    if (!_sortAscending) {
      return sorted.reversed.toList();
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

  /// 书源长按操作菜单（参考 legado_max explore_item.xml）
  /// 菜单项：编辑、置顶、登录(条件)、搜索、刷新、删除
  void _showSourceOptions(BookSource source) {
    final hasLoginUrl =
        source.loginUrl != null && source.loginUrl!.isNotEmpty;
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 编辑书源
              ListTile(
                leading: const Icon(Icons.edit_outlined),
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
              // 置顶
              ListTile(
                leading: const Icon(Icons.vertical_align_top),
                title: const Text('置顶'),
                onTap: () {
                  Navigator.pop(context);
                  context
                      .read<DiscoveryProvider>()
                      .pinSource(source.bookSourceUrl);
                },
              ),
              // 登录（仅当书源配置了 loginUrl 时显示，参考 legado_max menu_login）
              if (hasLoginUrl)
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text('登录'),
                  onTap: () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('登录功能开发中'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              // 搜索书籍
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
              // 刷新发现分类（参考 legado_max menu_refresh: 清除缓存重新加载）
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('刷新分类'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _cachedCategories.remove(source.bookSourceUrl);
                  });
                },
              ),
              // 删除
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
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
