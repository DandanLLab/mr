import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/book_source.dart';
import '../../providers/discovery_provider.dart';
import '../../routes/app_routes.dart';

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
  final Set<String> _expandedSources = {};
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 参考 legado-main: 根据实际 primary 颜色明暗决定标题文字颜色
    final primaryColor = Theme.of(context).colorScheme.primary;
    final appBarForeground = ThemeData.estimateBrightnessForColor(primaryColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Scaffold(
      body: Column(
        children: [
          // 参考原版：TitleBar (AppBarLayout) - 搜索框和标题栏在同一行
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top,
            ),
            color: Theme.of(context).colorScheme.primary,
            child: Column(
              children: [
                // Toolbar + 搜索框在同一行（不显示标题文字）
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      // 搜索框（参考原版：高度30dp）
                      Expanded(
                        child: SizedBox(
                          height: 32,
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: '搜索书源',
                              hintStyle: const TextStyle(fontSize: 13),
                              prefixIcon: Icon(Icons.search, size: 16, color: appBarForeground.withValues(alpha: 0.7)),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: Icon(Icons.clear, size: 16, color: appBarForeground.withValues(alpha: 0.7)),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() {
                                          _searchQuery = '';
                                        });
                                      },
                                    )
                                  : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                              isDense: true,
                            ),
                            style: TextStyle(fontSize: 13, color: appBarForeground),
                            onChanged: (value) {
                              setState(() {
                                _searchQuery = value;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 收藏分组
                      IconButton(
                        icon: Icon(Icons.folder_outlined, size: 20, color: appBarForeground),
                        tooltip: '收藏分组',
                        onPressed: () {},
                      ),
                      // 排序按钮
                      PopupMenuButton<String>(
                        icon: Icon(Icons.sort, size: 20, color: appBarForeground),
                        tooltip: '排序',
                        offset: const Offset(0, 48),
                        onSelected: (value) {},
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'manual',
                            child: Text('手动排序', style: TextStyle(color: appBarForeground)),
                          ),
                          PopupMenuItem(
                            value: 'name',
                            child: Text('按名称', style: TextStyle(color: appBarForeground)),
                          ),
                          PopupMenuItem(
                            value: 'url',
                            child: Text('按URL', style: TextStyle(color: appBarForeground)),
                          ),
                          PopupMenuItem(
                            value: 'time',
                            child: Text('按更新时间', style: TextStyle(color: appBarForeground)),
                          ),
                          PopupMenuItem(
                            value: 'respond',
                            child: Text('按响应时间', style: TextStyle(color: appBarForeground)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 书源列表
          Expanded(
            child: _buildSourceList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBarWithActions() {
    // 参考原版设计：搜索框和分组按钮在同一行
    return Container(
      height: 48,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          // 分组按钮
          PopupMenuButton<String>(
            icon: const Icon(Icons.folder_outlined, size: 20),
            tooltip: '分组',
            offset: const Offset(0, 48), // 向下偏移，避免遮挡
            onSelected: (value) {
              if (value.startsWith('group:')) {
                _searchController.text = value;
                setState(() {
                  _searchQuery = value;
                });
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: '',
                child: Text('全部'),
              ),
            ],
          ),
          // 搜索框
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索书源',
                hintStyle: const TextStyle(fontSize: 14),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    // 参考原版设计：紧凑的搜索框（高度30dp）
    return Container(
      height: 40,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索书源',
          hintStyle: const TextStyle(fontSize: 14),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                    });
                  },
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          isDense: true,
        ),
        style: const TextStyle(fontSize: 14),
        onChanged: (value) {
          setState(() {
            _searchQuery = value;
          });
        },
      ),
    );
  }

  Widget _buildSourceList() {
    return Consumer<DiscoveryProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        final sources = _filterSources(provider.bookSources);

        if (sources.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.explore_outlined,
                  size: 64,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  _searchQuery.isEmpty ? '暂无发现内容' : '未找到匹配的书源',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_searchQuery.isEmpty) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      Navigator.pushNamed(context, AppRoutes.profile);
                    },
                    child: const Text('去导入书源'),
                  ),
                ],
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: provider.loadBookSources,
          child: ListView.builder(
            cacheExtent: 500,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: sources.length,
            itemBuilder: (context, index) {
              final source = sources[index];
              return _buildSourceItem(source, index);
            },
          ),
        );
      },
    );
  }

  List<BookSource> _filterSources(List<BookSource> sources) {
    if (_searchQuery.isEmpty) return sources;
    final query = _searchQuery.toLowerCase();
    return sources.where((s) {
      return s.bookSourceName.toLowerCase().contains(query) ||
          (s.bookSourceGroup?.toLowerCase().contains(query) ?? false);
    }).toList();
  }

  Widget _buildSourceItem(BookSource source, int index) {
    final isExpanded = _expandedSources.contains(source.bookSourceUrl);
    final exploreKinds = _parseExploreKinds(source.exploreUrl);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行 - 参考原版简洁设计
          InkWell(
            onTap: () => _toggleExpand(source.bookSourceUrl),
            onLongPress: () => _showSourceOptions(source),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      source.bookSourceName,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 15,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  // 展开/折叠箭头
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // 展开后的分类标签
          if (isExpanded && exploreKinds.isNotEmpty)
            _buildExploreKinds(source, exploreKinds),
        ],
      ),
    );
  }

  void _toggleExpand(String sourceUrl) {
    setState(() {
      if (_expandedSources.contains(sourceUrl)) {
        _expandedSources.remove(sourceUrl);
      } else {
        _expandedSources.add(sourceUrl);
      }
    });
  }

  List<Map<String, String>> _parseExploreKinds(String? exploreUrl) {
    if (exploreUrl == null || exploreUrl.isEmpty) return [];

    final kinds = <Map<String, String>>[];

    final lines = exploreUrl.split('\n');
    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      final parts = line.split('::');
      if (parts.length >= 2) {
        final title = parts[0].trim();
        final url = parts[1].trim();
        kinds.add({'title': title, 'url': url});
      } else if (parts.length == 1) {
        final item = parts[0].trim();
        if (item.contains('&&')) {
          final subParts = item.split('&&');
          for (final subPart in subParts) {
            final kv = subPart.split('@');
            if (kv.length >= 2) {
              kinds.add({'title': kv[0].trim(), 'url': kv[1].trim()});
            }
          }
        } else {
          final kv = item.split('@');
          if (kv.length >= 2) {
            kinds.add({'title': kv[0].trim(), 'url': kv[1].trim()});
          }
        }
      }
    }

    return kinds;
  }

  Widget _buildExploreKinds(
    BookSource source,
    List<Map<String, String>> kinds,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: kinds.map((kind) {
          return Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: () => _openExplore(source, kind),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(
                  kind['title'] ?? '',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _openExplore(BookSource source, Map<String, String> kind) {
    Navigator.pushNamed(
      context,
      AppRoutes.exploreShow,
      arguments: {
        'sourceUrl': source.bookSourceUrl,
        'sourceName': source.bookSourceName,
        'exploreName': kind['title'],
        'exploreUrl': kind['url'],
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
                },
              ),
              ListTile(
                leading: const Icon(Icons.push_pin),
                title: const Text('置顶'),
                onTap: () {
                  Navigator.pop(context);
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
