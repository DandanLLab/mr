import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/app_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/local_book/local_book_service.dart';
import '../../services/cover_config_service.dart';

/// 书架布局类型
enum BookshelfLayout {
  list,        // 列表
  listCompact, // 紧凑列表
  grid2,       // 2列网格
  grid3,       // 3列网格
  grid4,       // 4列网格
  grid5,       // 5列网格
  grid6,       // 6列网格
}

/// 书架排序类型
enum BookshelfSort {
  byTime,      // 按阅读时间
  byName,      // 按书名
  byAuthor,    // 按作者
  byLatest,    // 按最新章节
  byAddTime,   // 按添加时间
  byManual,    // 手动排序
}

/// 书名显示方式
enum BookNameDisplay {
  show,        // 显示
  hide,        // 隐藏
  overlay,     // 覆盖在封面上
}

/// 分组样式
enum GroupStyle {
  none,        // 不分组
  byGroup,     // 按分组
}

class BookshelfPage extends StatefulWidget {
  final VoidCallback? onSwipeToNext;
  
  const BookshelfPage({super.key, this.onSwipeToNext});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late PageController _pageController;

  // 书架配置
  BookshelfLayout _layout = BookshelfLayout.list; // 默认列表模式
  BookshelfSort _sort = BookshelfSort.byTime;
  BookNameDisplay _bookNameDisplay = BookNameDisplay.show;
  GroupStyle _groupStyle = GroupStyle.byGroup;
  bool _showUnread = true;
  bool _showLastUpdateTime = true;
  bool _showBookName = true;
  bool _showWaitUpdate = true;
  bool _showFastScroller = false;
  int _gridColumnCount = 3;
  double _margin = 8.0;

  @override
  void initState() {
    super.initState();
    // 使用 provider 中保存的分组索引
    final provider = context.read<BookshelfProvider>();
    _pageController = PageController(initialPage: provider.selectedGroupIndex);
    _loadBookshelfConfig();
    // 加载自定义分组
    provider.loadCustomGroups();
  }

  Future<void> _loadBookshelfConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _layout = BookshelfLayout.values[prefs.getInt('bookshelf_layout') ?? 0];
      _sort = BookshelfSort.values[prefs.getInt('bookshelf_sort') ?? 0];
      _groupStyle = GroupStyle.values[prefs.getInt('bookshelf_groupStyle') ?? 1];
      _bookNameDisplay = BookNameDisplay.values[prefs.getInt('bookshelf_bookNameDisplay') ?? 0];
      _showUnread = prefs.getBool('bookshelf_showUnread') ?? true;
      _showLastUpdateTime = prefs.getBool('bookshelf_showLastUpdateTime') ?? true;
      _showWaitUpdate = prefs.getBool('bookshelf_showWaitUpdate') ?? true;
      _showFastScroller = prefs.getBool('bookshelf_showFastScroller') ?? false;
      _margin = prefs.getDouble('bookshelf_margin') ?? 8.0;
      _gridColumnCount = _getGridColumnCount(_layout);
    });
    // 加载封面配置
    await CoverConfigService.instance.reload();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 参考 legado-main: 根据实际 primary 颜色明暗决定标题文字颜色
    final primaryColor = Theme.of(context).colorScheme.primary;
    final appBarForeground = ThemeData.estimateBrightnessForColor(primaryColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Scaffold(
      body: Consumer<BookshelfProvider>(
        builder: (context, provider, child) {
          // 获取动态分组列表（只显示有书籍的分组）
          final groups = provider.getVisibleGroups();

          // 参考原版 Style1：TabLayout + ViewPager
          // 分组标签和搜索在同一排，左右滑动切换分组
          return Column(
            children: [
              // 顶部栏：分组标签 + 搜索按钮 + 更多菜单（同一排）
              Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top,
                ),
                color: Theme.of(context).colorScheme.primary,
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      // 分组标签（横向滚动）
                      Expanded(
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: groups.length,
                          itemBuilder: (context, index) {
                            final isSelected = index == provider.selectedGroupIndex;
                            return GestureDetector(
                              onTap: () {
                                provider.setSelectedGroupIndex(index);
                                provider.setGroup(groups[index]);
                                _pageController.animateToPage(
                                  index,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeInOut,
                                );
                              },
                              child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          alignment: Alignment.center,
                          child: Text(
                            groups[index],
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                              color: isSelected
                                  ? appBarForeground
                                  : appBarForeground.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                            );
                          },
                        ),
                      ),
                      // 搜索按钮
                      IconButton(
                        icon: Icon(Icons.search, color: appBarForeground),
                        tooltip: '搜索',
                        onPressed: () {
                          Navigator.pushNamed(context, AppRoutes.search);
                        },
                      ),
                      // 更多菜单
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert, color: appBarForeground),
                        tooltip: '更多选项',
                        color: Theme.of(context).colorScheme.surface,
                        elevation: 8,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        offset: const Offset(0, 48),
                        onSelected: (value) => _handleMenuSelection(value),
                        itemBuilder: (context) {
                          final onSurface = Theme.of(context).colorScheme.onSurface;
                          return [
                          PopupMenuItem(
                            value: 'refresh',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.refresh, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('更新目录', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'import_local',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.add, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('添加本地', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'import_remote',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.add, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('远程书籍', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'import_url',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.language, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('添加网址', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'bookshelf_manage',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.reorder, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('书架管理', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'download',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.download_outlined, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('缓存/导出', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'group_manage',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.folder_copy, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('分组管理', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'layout',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.view_quilt, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('书架布局', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'export_bookshelf',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.ios_share, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('导出书单', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'import_bookshelf',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.file_download, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('导入书单', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'log',
                            height: 48,
                            child: Row(
                              children: [
                                Icon(Icons.info_outline, size: 24, color: onSurface),
                                const SizedBox(width: 16),
                                Text('日志', style: TextStyle(color: onSurface)),
                              ],
                            ),
                          ),
                        ];
                      },
                      ),
                    ],
                  ),
                ),
              ),
              // 书籍列表（支持左右滑动切换分组）
              Expanded(
                child: provider.isBatchMode
                    ? _buildBatchView(provider)
                    : _buildMainView(provider, groups),
              ),
            ],
          );
        },
      ),
    );
  }

  void _handleMenuSelection(String value) {
    final provider = context.read<BookshelfProvider>();
    switch (value) {
      case 'refresh':
        _refreshAllBooks();
        break;
      case 'import_local':
        _showImportDialog();
        break;
      case 'import_remote':
        _showRemoteBookDialog();
        break;
      case 'import_url':
        _showUrlImportDialog();
        break;
      case 'bookshelf_manage':
        provider.enterBatchMode();
        break;
      case 'download':
        _showCacheExportDialog();
        break;
      case 'group_manage':
        _showGroupManageDialog();
        break;
      case 'layout':
        _showBookshelfLayoutDialog();
        break;
      case 'export_bookshelf':
        _exportBookshelf();
        break;
      case 'import_bookshelf':
        _importBookshelf();
        break;
      case 'log':
        _showLogDialog();
        break;
    }
  }

  Future<void> _refreshAllBooks() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在更新书籍目录...')),
    );
    // TODO: 实现更新逻辑
  }

  void _showRemoteBookDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('远程书籍'),
        content: const Text('远程书籍功能开发中...'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showUrlImportDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('URL导入'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入书籍URL',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: 实现URL导入
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _showGroupManageDialog() {
    final provider = context.read<BookshelfProvider>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Consumer<BookshelfProvider>(
        builder: (context, provider, child) {
          final allGroups = provider.getAllGroups();
          final defaultGroups = ['全部', '本地', '小说', '音频', '漫画', '视频'];

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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('分组管理', style: Theme.of(context).textTheme.titleLarge),
                      IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: '添加分组',
                        onPressed: () {
                          _showCreateGroupDialog(provider);
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: allGroups.length,
                    itemBuilder: (context, index) {
                      final group = allGroups[index];
                      final isDefault = defaultGroups.contains(group);
                      return ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(group),
                        trailing: isDefault
                            ? null
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20),
                                    tooltip: '编辑',
                                    onPressed: () {
                                      _showEditGroupDialog(provider, group);
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, size: 20),
                                    tooltip: '删除',
                                    onPressed: () {
                                      _showDeleteGroupDialog(provider, group);
                                    },
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showCreateGroupDialog(BookshelfProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入分组名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final success = await provider.addCustomGroup(controller.text);
                Navigator.pop(context);
                if (!success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('分组已达上限(64个)或名称已存在')),
                  );
                }
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _showEditGroupDialog(BookshelfProvider provider, String oldName) {
    final controller = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入分组名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (controller.text.isNotEmpty && controller.text != oldName) {
                final success = await provider.renameCustomGroup(oldName, controller.text);
                Navigator.pop(context);
                if (!success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('分组名称已存在')),
                  );
                }
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showDeleteGroupDialog(BookshelfProvider provider, String groupName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分组'),
        content: Text('确定要删除分组"$groupName"吗？\n该分组下的书籍将移至未分组。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await provider.removeCustomGroup(groupName);
              Navigator.pop(context);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showBookshelfLayoutDialog() {
    // 保存初始值用于取消时恢复
    final initialLayout = _layout;
    final initialSort = _sort;
    final initialGroupStyle = _groupStyle;
    final initialBookNameDisplay = _bookNameDisplay;
    final initialShowUnread = _showUnread;
    final initialShowLastUpdateTime = _showLastUpdateTime;
    final initialShowWaitUpdate = _showWaitUpdate;
    final initialShowFastScroller = _showFastScroller;
    final initialMargin = _margin;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('书架布局'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 分组样式
                  Row(
                    children: [
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Text('分组样式'),
                        ),
                      ),
                      DropdownButton<GroupStyle>(
                        value: _groupStyle,
                        underline: const SizedBox(),
                        items: const [
                          DropdownMenuItem(
                            value: GroupStyle.none,
                            child: Text('不分组'),
                          ),
                          DropdownMenuItem(
                            value: GroupStyle.byGroup,
                            child: Text('按分组'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() => _groupStyle = v);
                          }
                        },
                      ),
                    ],
                  ),
                  // 显示未读标志
                  SwitchListTile(
                    title: const Text('显示未读标志'),
                    value: _showUnread,
                    onChanged: (v) {
                      setDialogState(() => _showUnread = v);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  // 显示上次更新时间
                  SwitchListTile(
                    title: const Text('显示上次更新时间'),
                    value: _showLastUpdateTime,
                    onChanged: (v) {
                      setDialogState(() => _showLastUpdateTime = v);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  // 显示等待更新数量
                  SwitchListTile(
                    title: const Text('显示等待更新数量'),
                    value: _showWaitUpdate,
                    onChanged: (v) {
                      setDialogState(() => _showWaitUpdate = v);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  // 显示快速滚动条
                  SwitchListTile(
                    title: const Text('显示快速滚动条'),
                    value: _showFastScroller,
                    onChanged: (v) {
                      setDialogState(() => _showFastScroller = v);
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  // 视图和排序（两列布局）
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 视图
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: Text('视图', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                            ),
                            _buildRadioItem('列表', BookshelfLayout.list, _layout, (v) {
                              setDialogState(() {
                                _layout = v;
                                _gridColumnCount = _getGridColumnCount(v);
                              });
                            }),
                            _buildRadioItem('紧凑列表', BookshelfLayout.listCompact, _layout, (v) {
                              setDialogState(() {
                                _layout = v;
                                _gridColumnCount = _getGridColumnCount(v);
                              });
                            }),
                            _buildRadioItem('网格二列', BookshelfLayout.grid2, _layout, (v) {
                              setDialogState(() {
                                _layout = v;
                                _gridColumnCount = _getGridColumnCount(v);
                              });
                            }),
                            _buildRadioItem('网格三列', BookshelfLayout.grid3, _layout, (v) {
                              setDialogState(() {
                                _layout = v;
                                _gridColumnCount = _getGridColumnCount(v);
                              });
                            }),
                            _buildRadioItem('网格四列', BookshelfLayout.grid4, _layout, (v) {
                              setDialogState(() {
                                _layout = v;
                                _gridColumnCount = _getGridColumnCount(v);
                              });
                            }),
                            _buildRadioItem('网格五列', BookshelfLayout.grid5, _layout, (v) {
                              setDialogState(() {
                                _layout = v;
                                _gridColumnCount = _getGridColumnCount(v);
                              });
                            }),
                            _buildRadioItem('网格六列', BookshelfLayout.grid6, _layout, (v) {
                              setDialogState(() {
                                _layout = v;
                                _gridColumnCount = _getGridColumnCount(v);
                              });
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      // 排序
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: Text('排序', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                            ),
                            _buildRadioItem('按阅读时间', BookshelfSort.byTime, _sort, (v) {
                              setDialogState(() => _sort = v);
                            }),
                            _buildRadioItem('按更新时间', BookshelfSort.byLatest, _sort, (v) {
                              setDialogState(() => _sort = v);
                            }),
                            _buildRadioItem('按书名', BookshelfSort.byName, _sort, (v) {
                              setDialogState(() => _sort = v);
                            }),
                            _buildRadioItem('手动排序', BookshelfSort.byManual, _sort, (v) {
                              setDialogState(() => _sort = v);
                            }),
                            _buildRadioItem('综合排序', BookshelfSort.byAddTime, _sort, (v) {
                              setDialogState(() => _sort = v);
                            }),
                            _buildRadioItem('按作者', BookshelfSort.byAuthor, _sort, (v) {
                              setDialogState(() => _sort = v);
                            }),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // 书名显示（仅网格模式）
                  if (_layout != BookshelfLayout.list && _layout != BookshelfLayout.listCompact) ...[
                    const SizedBox(height: 8),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('书名', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                    ),
                    Row(
                      children: [
                        _buildRadioItem('显示', BookNameDisplay.show, _bookNameDisplay, (v) {
                          setDialogState(() => _bookNameDisplay = v);
                        }),
                        const SizedBox(width: 16),
                        _buildRadioItem('隐藏', BookNameDisplay.hide, _bookNameDisplay, (v) {
                          setDialogState(() => _bookNameDisplay = v);
                        }),
                        const SizedBox(width: 16),
                        _buildRadioItem('叠加', BookNameDisplay.overlay, _bookNameDisplay, (v) {
                          setDialogState(() => _bookNameDisplay = v);
                        }),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  // 间距
                  Row(
                    children: [
                      const Text('间距'),
                      Expanded(
                        child: Slider(
                          value: _margin,
                          min: 0,
                          max: 60,
                          divisions: 12,
                          onChanged: (v) {
                            setDialogState(() => _margin = v);
                          },
                        ),
                      ),
                      Text('${_margin.toInt()}'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                // 取消时恢复初始值
                setDialogState(() {
                  _layout = initialLayout;
                  _sort = initialSort;
                  _groupStyle = initialGroupStyle;
                  _bookNameDisplay = initialBookNameDisplay;
                  _showUnread = initialShowUnread;
                  _showLastUpdateTime = initialShowLastUpdateTime;
                  _showWaitUpdate = initialShowWaitUpdate;
                  _showFastScroller = initialShowFastScroller;
                  _margin = initialMargin;
                  _gridColumnCount = _getGridColumnCount(_layout);
                });
                Navigator.pop(context);
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                // 保存设置到配置
                _saveBookshelfConfig();
                Navigator.pop(context);
                // 刷新页面
                setState(() {});
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _saveBookshelfConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bookshelf_layout', _layout.index);
    await prefs.setInt('bookshelf_sort', _sort.index);
    await prefs.setInt('bookshelf_groupStyle', _groupStyle.index);
    await prefs.setInt('bookshelf_bookNameDisplay', _bookNameDisplay.index);
    await prefs.setBool('bookshelf_showUnread', _showUnread);
    await prefs.setBool('bookshelf_showLastUpdateTime', _showLastUpdateTime);
    await prefs.setBool('bookshelf_showWaitUpdate', _showWaitUpdate);
    await prefs.setBool('bookshelf_showFastScroller', _showFastScroller);
    await prefs.setDouble('bookshelf_margin', _margin);
    debugPrint('保存书架配置成功');
  }

  Widget _buildRadioItem<T>(String label, T value, T groupValue, void Function(T) onChanged) {
    return InkWell(
      onTap: () => onChanged(value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Radio<T>(
            value: value,
            groupValue: groupValue,
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          Text(label),
        ],
      ),
    );
  }

  void _showLogDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('日志'),
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
      ),
    );
  }

  int _getGridColumnCount(BookshelfLayout layout) {
    switch (layout) {
      case BookshelfLayout.list:
      case BookshelfLayout.listCompact:
        return 1;
      case BookshelfLayout.grid2:
        return 2;
      case BookshelfLayout.grid3:
        return 3;
      case BookshelfLayout.grid4:
        return 4;
      case BookshelfLayout.grid5:
        return 5;
      case BookshelfLayout.grid6:
        return 6;
    }
  }

  Widget _buildMainView(BookshelfProvider provider, List<String> groups) {
    final isList = _layout == BookshelfLayout.list || _layout == BookshelfLayout.listCompact;

    // 参考原版：使用 PageView 支持左右滑动切换分组
    return PageView.builder(
      controller: _pageController,
      itemCount: groups.length,
      onPageChanged: (index) {
        provider.setSelectedGroupIndex(index);
        provider.setGroup(groups[index]);
      },
      itemBuilder: (context, pageIndex) {
        // 根据分组索引获取该分组的书籍
        final groupBooks = provider.getBooksByGroup(groups[pageIndex]);

        // 每个分组的书籍列表
        if (groupBooks.isEmpty) {
          return _buildEmptyState();
        }

        return RefreshIndicator(
          onRefresh: provider.loadBooks,
          child: isList
              ? _buildListViewWithBooks(groupBooks, provider)
              : _buildGridViewWithBooks(groupBooks, provider),
        );
      },
    );
  }

  Widget _buildListViewWithBooks(List<Book> books, BookshelfProvider provider) {
    final listView = ListView.builder(
      cacheExtent: 500,
      padding: EdgeInsets.all(_margin),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return _buildListBookCard(book, provider);
      },
    );

    // 显示快速滚动条
    if (_showFastScroller) {
      return Scrollbar(
        thumbVisibility: true,
        child: listView,
      );
    }
    return listView;
  }

  Widget _buildGridViewWithBooks(List<Book> books, BookshelfProvider provider) {
    final gridView = GridView.builder(
      cacheExtent: 500,
      padding: EdgeInsets.all(_margin),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _gridColumnCount,
        childAspectRatio: 0.65,
        crossAxisSpacing: _margin,
        mainAxisSpacing: _margin,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return RepaintBoundary(
          child: _buildGridBookCard(book, provider),
        );
      },
    );

    // 显示快速滚动条
    if (_showFastScroller) {
      return Scrollbar(
        thumbVisibility: true,
        child: gridView,
      );
    }
    return gridView;
  }

  Widget _buildGridView(BookshelfProvider provider) {
    return GridView.builder(
      padding: EdgeInsets.all(_margin),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _gridColumnCount,
        childAspectRatio: 0.65,
        crossAxisSpacing: _margin,
        mainAxisSpacing: _margin,
      ),
      itemCount: provider.books.length,
      itemBuilder: (context, index) {
        final book = provider.books[index];
        return RepaintBoundary(
          child: _buildGridBookCard(book, provider),
        );
      },
    );
  }

  Widget _buildGridBookCard(Book book, BookshelfProvider provider) {
    // 参考原版设计：简洁的网格卡片
    final coverConfig = CoverConfigService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showCoverName = coverConfig.shouldShowName(isDark);
    final showCoverAuthor = coverConfig.shouldShowAuthor(isDark) && showCoverName;
    final useDefault = coverConfig.useDefaultCover;

    return GestureDetector(
      onTap: () => _openBook(book),
      onLongPress: () => _showBookOptions(book, provider),
      child: Stack(
        children: [
          // 参考原版：不包 Card，扁平化布局
          Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 封面
                        _buildCoverImage(book, isDark, useDefault),
                      // 书名覆盖在封面上（封面设置中的显示书名，且书架设置为overlay模式）
                      if (_bookNameDisplay == BookNameDisplay.overlay && showCoverName)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.7),
                                ],
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  book.displayName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    shadows: [
                                      Shadow(
                                        offset: Offset(0, 1),
                                        blurRadius: 2,
                                        color: Colors.black54,
                                      ),
                                    ],
                                  ),
                                ),
                                if (showCoverAuthor && book.displayAuthor.isNotEmpty)
                                  Text(
                                    book.displayAuthor,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.8),
                                      fontSize: 9,
                                      shadows: const [
                                        Shadow(
                                          offset: Offset(0, 1),
                                          blurRadius: 2,
                                          color: Colors.black54,
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
                // 书名显示在下方（参考原版：12sp，2行）
                if (_bookNameDisplay == BookNameDisplay.show)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
                    child: Text(
                      book.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 未读数徽章
          if (_showUnread && book.unreadCount > 0)
            Positioned(
              top: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${book.unreadCount}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          // 本地标签
          if (book.originType == BookOriginType.local)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                ),
                child: Text(
                  '本地',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontSize: 9,
                  ),
                ),
              ),
            ),
          // 置顶图标
          if (book.isTop)
            Positioned(
              bottom: _bookNameDisplay == BookNameDisplay.show ? 32 : 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.push_pin,
                  size: 12,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildListView(BookshelfProvider provider) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: provider.books.length,
      itemBuilder: (context, index) {
        final book = provider.books[index];
        return _buildListBookCard(book, provider);
      },
    );
  }

  Widget _buildListBookCard(Book book, BookshelfProvider provider) {
    final isCompact = _layout == BookshelfLayout.listCompact;
    final coverConfig = CoverConfigService.instance;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final useDefault = coverConfig.useDefaultCover;

    return InkWell(
      onTap: () => _openBook(book),
      onLongPress: () => _showBookOptions(book, provider),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面（参考原版：66x90dp，圆角4dp）
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: isCompact ? 48 : 66,
                height: isCompact ? 64 : 90,
                child: _buildCoverImage(book, isDark, useDefault, isList: true),
              ),
            ),
            const SizedBox(width: 10), // 参考原版：10dp间距
            // 书籍信息（参考 legado-main 布局）
            Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第1行：书名（参考原版：16sp，primaryText）
                      Row(
                        children: [
                          if (book.isTop)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.push_pin,
                                size: 14,
                                color: Theme.of(context).colorScheme.secondary,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              book.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          // 未读数徽章
                          if (_showUnread && book.unreadCount > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.secondary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${book.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (isCompact) ...[
                        // 紧凑模式第2行：作者 · 进度 | 更新时间（同一行）
                        Row(
                          children: [
                            Icon(Icons.person_outline, size: 14,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: RichText(
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                text: TextSpan(
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                  children: [
                                    TextSpan(text: book.author.isNotEmpty ? book.author : '未知作者'),
                                    if (book.durChapterTitle.isNotEmpty) ...[
                                      const TextSpan(text: ' · ', style: TextStyle(fontSize: 11)),
                                      TextSpan(text: book.durChapterTitle),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            if (_showLastUpdateTime && book.lastCheckTime != null)
                              Text(
                                _formatUpdateTime(book.lastCheckTime!),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // 紧凑模式第3行：最新章节
                        if (book.latestChapterTitle.isNotEmpty)
                          Row(
                            children: [
                              Icon(Icons.auto_stories, size: 14,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(book.latestChapterTitle,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                      ] else ...[
                        // 标准模式第2行：作者 | 更新时间
                        Row(
                          children: [
                            Icon(Icons.person_outline, size: 14,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                book.author.isNotEmpty ? book.author : '未知作者',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            if (_showLastUpdateTime && book.lastCheckTime != null)
                              Text(
                                _formatUpdateTime(book.lastCheckTime!),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // 标准模式第3行：阅读进度
                        Row(
                          children: [
                            Icon(Icons.history, size: 14,
                                color: Theme.of(context).colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                book.durChapterTitle.isNotEmpty ? book.durChapterTitle : '未开始阅读',
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // 标准模式第4行：最新章节
                        if (book.latestChapterTitle.isNotEmpty)
                          Row(
                            children: [
                              Icon(Icons.auto_stories, size: 14,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(book.latestChapterTitle,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 13,
                                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ],
                  ),
                ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatUpdateTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inDays == 0) {
      return '今天';
    } else if (diff.inDays == 1) {
      return '昨天';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      return '${time.month}/${time.day}';
    }
  }

  Widget _buildBatchView(BookshelfProvider provider) {
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _gridColumnCount,
              childAspectRatio: 0.65,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: provider.books.length,
            itemBuilder: (context, index) {
              final book = provider.books[index];
              final isSelected = provider.selectedBookIds.contains(book.bookUrl);

              return GestureDetector(
                onTap: () => provider.toggleBookSelection(book.bookUrl),
                child: Stack(
                  children: [
                    _buildGridBookCard(book, provider),
                    if (isSelected)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.check_circle,
                              size: 48,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: provider.selectedBookIds.isEmpty
                    ? null
                    : () => provider.batchRemove(),
                icon: const Icon(Icons.delete),
                label: const Text('批量移除'),
              ),
              TextButton.icon(
                onPressed: provider.selectedBookIds.isEmpty
                    ? null
                    : () => _showBatchUpdateDialog(provider),
                icon: const Icon(Icons.update),
                label: const Text('批量更新'),
              ),
              TextButton.icon(
                onPressed: () => provider.exitBatchMode(),
                icon: const Icon(Icons.close),
                label: const Text('取消'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showBatchUpdateDialog(BookshelfProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批量更新'),
        content: Text('确定要更新选中的 ${provider.selectedBookIds.length} 本书籍吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: 实现批量更新
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('正在更新...')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.book_outlined,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '书架空空如也',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右下角按钮导入书籍',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _showImportDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.folder),
                title: const Text('扫描目录'),
                subtitle: const Text('选择文件夹自动识别支持的格式'),
                onTap: () {
                  Navigator.pop(context);
                  _scanDirectory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: const Text('选择文件'),
                subtitle: const Text('手动选择单个或多个文件'),
                onTap: () {
                  Navigator.pop(context);
                  _selectFiles();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _scanDirectory() async {
    try {
      String? directoryPath = await FilePicker.platform.getDirectoryPath();
      if (directoryPath != null) {
        final books = await LocalBookService.instance.scanDirectory(directoryPath);
        for (final book in books) {
          await context.read<BookshelfProvider>().addToBookshelf(book);
        }
        if (books.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导入 ${books.length} 本书籍')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到支持的书籍文件')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描失败: $e')),
      );
    }
  }

  void _selectFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub', 'pdf'],
      );
      if (result != null) {
        int successCount = 0;
        for (final file in result.files) {
          if (file.path != null) {
            final book = await LocalBookService.instance.importFile(file.path!);
            if (book != null) {
              await context.read<BookshelfProvider>().addToBookshelf(book);
              successCount++;
            }
          }
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 $successCount 本书籍')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  void _showBookOptions(Book book, BookshelfProvider provider) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(book.isTop ? Icons.push_pin_outlined : Icons.push_pin),
                title: Text(book.isTop ? '取消置顶' : '置顶'),
                onTap: () {
                  provider.toggleTop(book.bookUrl);
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder),
                title: const Text('移动到分组'),
                onTap: () {
                  Navigator.pop(context);
                  _showMoveToGroupDialog(book, provider);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('从书架移除'),
                onTap: () {
                  provider.removeFromBookshelf(book.bookUrl);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoveToGroupDialog(Book book, BookshelfProvider provider) {
    final groups = provider.getAllGroups();
    final defaultGroups = ['全部', '本地', '小说', '音频', '漫画', '视频'];
    String selectedGroup = book.groupId ?? '全部';

    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.zero,
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.9,
          height: MediaQuery.of(context).size.height * 0.9,
          child: Column(
            children: [
              // 工具栏
              Material(
                color: Theme.of(context).colorScheme.primary,
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        child: Text(
                          '选择分组',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add, color: Theme.of(context).colorScheme.onPrimary),
                      tooltip: '添加分组',
                      onPressed: () {
                        Navigator.pop(context);
                        _showCreateGroupDialogForMove(book, provider);
                      },
                    ),
                  ],
                ),
              ),
              // 分组列表
              Expanded(
                child: StatefulBuilder(
                  builder: (context, setDialogState) => ListView.separated(
                    itemCount: groups.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      final isDefault = defaultGroups.contains(group);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: CheckboxListTile(
                                title: Text(group),
                                value: selectedGroup == group,
                                onChanged: (checked) {
                                  if (checked == true) {
                                    setDialogState(() => selectedGroup = group);
                                  }
                                },
                                controlAffinity: ListTileControlAffinity.leading,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            // 编辑按钮（仅自定义分组）
                            if (!isDefault)
                              TextButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  _showEditGroupDialogForMove(book, provider, group);
                                },
                                child: const Text('编辑'),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              // 底部按钮
              Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () {
                        provider.moveBookToGroup(book.bookUrl, selectedGroup == '全部' ? null : selectedGroup);
                        Navigator.pop(context);
                      },
                      child: Text(
                        '确定',
                        style: TextStyle(color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCreateGroupDialogForMove(Book book, BookshelfProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入分组名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final success = await provider.addCustomGroup(controller.text);
                Navigator.pop(context);
                if (!success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('分组已达上限(64个)或名称已存在')),
                  );
                }
                // 重新打开分组选择对话框
                _showMoveToGroupDialog(book, provider);
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _showEditGroupDialogForMove(Book book, BookshelfProvider provider, String oldName) {
    final controller = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入分组名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // 删除分组
              await provider.removeCustomGroup(oldName);
              // 重新打开分组选择对话框
              _showMoveToGroupDialog(book, provider);
            },
            child: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (controller.text.isNotEmpty && controller.text != oldName) {
                final success = await provider.renameCustomGroup(oldName, controller.text);
                Navigator.pop(context);
                if (!success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('分组名称已存在')),
                  );
                }
                // 重新打开分组选择对话框
                _showMoveToGroupDialog(book, provider);
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 构建封面图片 - 接入封面配置（默认封面、WiFi限制、高清封面）
  Widget _buildCoverImage(Book book, bool isDark, bool useDefault, {bool isList = false}) {
    final coverConfig = CoverConfigService.instance;
    final coverUrl = book.displayCoverUrl;

    // 总是使用默认封面
    if (useDefault) {
      return coverConfig.buildDefaultCoverPlaceholder(
        bookName: book.displayName,
        bookAuthor: book.displayAuthor,
        isDark: isDark,
        borderRadius: isList ? null : BorderRadius.zero,
      );
    }

    // 有网络封面
    if (coverUrl.isNotEmpty) {
      // 高清封面设置：非高清时使用缩略图缓存尺寸
      final memCacheWidth = coverConfig.loadCoverHighQuality ? null : 240;
      final maxWidthDiskCache = coverConfig.loadCoverHighQuality ? null : 320;

      return CachedNetworkImage(
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        memCacheWidth: memCacheWidth,
        maxWidthDiskCache: maxWidthDiskCache,
        placeholder: (context, url) => coverConfig.buildDefaultCoverPlaceholder(
          bookName: book.displayName,
          bookAuthor: book.displayAuthor,
          isDark: isDark,
        ),
        errorWidget: (context, url, error) => coverConfig.buildDefaultCoverPlaceholder(
          bookName: book.displayName,
          bookAuthor: book.displayAuthor,
          isDark: isDark,
        ),
      );
    }

    // 无封面URL，显示默认封面占位
    return coverConfig.buildDefaultCoverPlaceholder(
      bookName: book.displayName,
      bookAuthor: book.displayAuthor,
      isDark: isDark,
    );
  }

  void _openBook(Book book) {
    Navigator.pushNamed(
      context,
      AppRoutes.detail,
      arguments: {'bookUrl': book.bookUrl},
    );
  }

  void _showCacheExportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('缓存导出'),
        content: const Text('缓存导出功能可以导出书籍缓存文件，方便在其他设备使用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: 实现缓存导出
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('缓存导出功能开发中...')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _exportBookshelf() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出书架'),
        content: const Text('将书架数据导出为JSON文件，方便备份或迁移。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: 实现导出书架
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('导出书架功能开发中...')),
              );
            },
            child: const Text('导出'),
          ),
        ],
      ),
    );
  }

  void _importBookshelf() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入书架'),
        content: const Text('从JSON文件导入书架数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: 实现导入书架
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('导入书架功能开发中...')),
              );
            },
            child: const Text('选择文件'),
          ),
        ],
      ),
    );
  }
}
