import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/book_source.dart';
import '../../providers/discovery_provider.dart';
import '../../services/storage_service.dart';
import 'book_source_edit_page.dart';

/// 书源排序类型
enum BookSourceSort {
  manual,    // 手动排序
  weight,    // 权重排序
  name,      // 按名称
  url,       // 按URL
  update,    // 按更新时间
  respond,   // 按响应时间
  enable,    // 按启用状态
}

/// 书源管理页面
class BookSourceManagePage extends StatefulWidget {
  const BookSourceManagePage({super.key});

  @override
  State<BookSourceManagePage> createState() => _BookSourceManagePageState();
}

class _BookSourceManagePageState extends State<BookSourceManagePage> {
  // 搜索相关
  final TextEditingController _searchController = TextEditingController();
  String _searchKeyword = '';

  // 排序相关
  BookSourceSort _sortType = BookSourceSort.manual;
  bool _isSortAscending = true;

  // 筛选相关
  String? _filterGroup;

  // 选择模式
  bool _isSelectionMode = false;
  final Set<String> _selectedSourceUrls = {};

  // 书源列表
  List<BookSource> _allSources = [];
  List<BookSource> _filteredSources = [];

  // 分组列表
  final Set<String> _groups = {};

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _navigateToEditPage({String? sourceUrl}) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BookSourceEditPage(sourceUrl: sourceUrl),
      ),
    );
    if (result == true) {
      _loadSources();
    }
  }

  Future<void> _loadSources() async {
    final provider = context.read<DiscoveryProvider>();
    await provider.loadBookSources();

    setState(() {
      _allSources = List.from(provider.bookSources);
      // 提取所有分组
      _groups.clear();
      for (final source in _allSources) {
        if (source.bookSourceGroup != null && source.bookSourceGroup!.isNotEmpty) {
          _groups.add(source.bookSourceGroup!);
        }
      }
      _applyFilterAndSort();
    });
  }

  void _applyFilterAndSort() {
    List<BookSource> result = List.from(_allSources);

    // 应用搜索筛选
    if (_searchKeyword.isNotEmpty) {
      final keyword = _searchKeyword.toLowerCase();
      // 特殊搜索关键词
      if (keyword == '启用' || keyword == 'enabled') {
        result = result.where((s) => s.enabled).toList();
      } else if (keyword == '禁用' || keyword == 'disabled') {
        result = result.where((s) => !s.enabled).toList();
      } else if (keyword == '需登录' || keyword == 'need_login') {
        result = result.where((s) => s.loginUrl != null && s.loginUrl!.isNotEmpty).toList();
      } else if (keyword == '无分组' || keyword == 'no_group') {
        result = result.where((s) => s.bookSourceGroup == null || s.bookSourceGroup!.isEmpty).toList();
      } else if (keyword == '启用发现' || keyword == 'enabled_explore') {
        result = result.where((s) => s.enabledExplore).toList();
      } else if (keyword == '禁用发现' || keyword == 'disabled_explore') {
        result = result.where((s) => !s.enabledExplore).toList();
      } else if (keyword.startsWith('group:')) {
        final groupName = keyword.substring(6);
        result = result.where((s) => s.bookSourceGroup == groupName).toList();
      } else {
        // 普通搜索
        result = result.where((s) {
          return s.bookSourceName.toLowerCase().contains(keyword) ||
              s.bookSourceUrl.toLowerCase().contains(keyword) ||
              (s.bookSourceGroup?.toLowerCase().contains(keyword) ?? false);
        }).toList();
      }
    }

    // 应用分组筛选
    if (_filterGroup != null) {
      result = result.where((s) => s.bookSourceGroup == _filterGroup).toList();
    }

    // 应用排序
    result = _sortSources(result);

    setState(() {
      _filteredSources = result;
    });
  }

  List<BookSource> _sortSources(List<BookSource> sources) {
    final sortedSources = List<BookSource>.from(sources);

    switch (_sortType) {
      case BookSourceSort.manual:
        if (!_isSortAscending) {
          return sortedSources.reversed.toList();
        }
        return sortedSources;
      case BookSourceSort.weight:
        if (_isSortAscending) {
          sortedSources.sort((a, b) => a.weight.compareTo(b.weight));
        } else {
          sortedSources.sort((a, b) => b.weight.compareTo(a.weight));
        }
        break;
      case BookSourceSort.name:
        if (_isSortAscending) {
          sortedSources.sort((a, b) => a.bookSourceName.compareTo(b.bookSourceName));
        } else {
          sortedSources.sort((a, b) => b.bookSourceName.compareTo(a.bookSourceName));
        }
        break;
      case BookSourceSort.url:
        if (_isSortAscending) {
          sortedSources.sort((a, b) => a.bookSourceUrl.compareTo(b.bookSourceUrl));
        } else {
          sortedSources.sort((a, b) => b.bookSourceUrl.compareTo(a.bookSourceUrl));
        }
        break;
      case BookSourceSort.update:
        if (_isSortAscending) {
          sortedSources.sort((a, b) => a.lastUpdateTime.compareTo(b.lastUpdateTime));
        } else {
          sortedSources.sort((a, b) => b.lastUpdateTime.compareTo(a.lastUpdateTime));
        }
        break;
      case BookSourceSort.respond:
        if (_isSortAscending) {
          sortedSources.sort((a, b) => a.respondTime.compareTo(b.respondTime));
        } else {
          sortedSources.sort((a, b) => b.respondTime.compareTo(a.respondTime));
        }
        break;
      case BookSourceSort.enable:
        if (_isSortAscending) {
          sortedSources.sort((a, b) {
            final aEnabled = a.enabled ? 1 : 0;
            final bEnabled = b.enabled ? 1 : 0;
            final cmp = -(aEnabled.compareTo(bEnabled));
            return cmp != 0 ? cmp : a.bookSourceName.compareTo(b.bookSourceName);
          });
        } else {
          sortedSources.sort((a, b) {
            final aEnabled = a.enabled ? 1 : 0;
            final bEnabled = b.enabled ? 1 : 0;
            final cmp = aEnabled.compareTo(bEnabled);
            return cmp != 0 ? cmp : a.bookSourceName.compareTo(b.bookSourceName);
          });
        }
        break;
    }

    return sortedSources;
  }

  void _onSearch(String keyword) {
    setState(() {
      _searchKeyword = keyword.trim();
      _filterGroup = null;
    });
    _applyFilterAndSort();
  }

  void _setSortType(BookSourceSort type) {
    setState(() {
      _sortType = type;
    });
    _applyFilterAndSort();
  }

  void _toggleSortOrder() {
    setState(() {
      _isSortAscending = !_isSortAscending;
    });
    _applyFilterAndSort();
  }

  void _setFilterGroup(String? group) {
    setState(() {
      _filterGroup = group;
      _searchKeyword = '';
      _searchController.clear();
    });
    _applyFilterAndSort();
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedSourceUrls.clear();
      }
    });
  }

  void _toggleSourceSelection(String sourceUrl) {
    setState(() {
      if (_selectedSourceUrls.contains(sourceUrl)) {
        _selectedSourceUrls.remove(sourceUrl);
      } else {
        _selectedSourceUrls.add(sourceUrl);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selectedSourceUrls.clear();
      _selectedSourceUrls.addAll(_filteredSources.map((s) => s.bookSourceUrl));
    });
  }

  void _invertSelection() {
    setState(() {
      final newSelection = <String>{};
      for (final source in _filteredSources) {
        if (!_selectedSourceUrls.contains(source.bookSourceUrl)) {
          newSelection.add(source.bookSourceUrl);
        }
      }
      _selectedSourceUrls.clear();
      _selectedSourceUrls.addAll(newSelection);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedSourceUrls.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定要删除选中的 ${_selectedSourceUrls.length} 个书源吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      for (final url in _selectedSourceUrls) {
        await StorageService.instance.deleteBookSource(url);
      }
      _selectedSourceUrls.clear();
      _isSelectionMode = false;
      await _loadSources();
    }
  }

  Future<void> _enableSelected(bool enable) async {
    for (final url in _selectedSourceUrls) {
      final index = _allSources.indexWhere((s) => s.bookSourceUrl == url);
      if (index != -1) {
        final source = _allSources[index].copyWith(enabled: enable);
        await StorageService.instance.saveBookSource(source.toJson());
      }
    }
    await _loadSources();
  }

  Future<void> _toggleSourceEnabled(BookSource source) async {
    final updatedSource = source.copyWith(enabled: !source.enabled);
    await StorageService.instance.saveBookSource(updatedSource.toJson());
    await _loadSources();
  }

  Future<void> _toggleSourceExplore(BookSource source) async {
    final updatedSource = source.copyWith(enabledExplore: !source.enabledExplore);
    await StorageService.instance.saveBookSource(updatedSource.toJson());
    await _loadSources();
  }

  Future<void> _deleteSource(BookSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定要删除书源 "${source.bookSourceName}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await StorageService.instance.deleteBookSource(source.bookSourceUrl);
      await _loadSources();
    }
  }

  void _showSortMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('排序方式', style: Theme.of(context).textTheme.titleLarge),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _toggleSortOrder();
                    },
                    icon: Icon(_isSortAscending ? Icons.arrow_upward : Icons.arrow_downward),
                    label: Text(_isSortAscending ? '升序' : '降序'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ...[
              (BookSourceSort.manual, '手动排序'),
              (BookSourceSort.weight, '按权重'),
              (BookSourceSort.name, '按名称'),
              (BookSourceSort.url, '按URL'),
              (BookSourceSort.update, '按更新时间'),
              (BookSourceSort.respond, '按响应时间'),
              (BookSourceSort.enable, '按启用状态'),
            ].map((item) => RadioListTile<BookSourceSort>(
              title: Text(item.$2),
              value: item.$1,
              groupValue: _sortType,
              onChanged: (value) {
                Navigator.pop(context);
                _setSortType(value!);
              },
            )),
          ],
        ),
      ),
    );
  }

  void _showGroupMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('分组筛选', style: Theme.of(context).textTheme.titleLarge),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.list),
              title: const Text('全部书源'),
              selected: _filterGroup == null && _searchKeyword.isEmpty,
              onTap: () {
                Navigator.pop(context);
                setState(() {
                  _filterGroup = null;
                  _searchKeyword = '';
                  _searchController.clear();
                });
                _applyFilterAndSort();
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle),
              title: const Text('启用的书源'),
              onTap: () {
                Navigator.pop(context);
                _onSearch('启用');
              },
            ),
            ListTile(
              leading: const Icon(Icons.cancel),
              title: const Text('禁用的书源'),
              onTap: () {
                Navigator.pop(context);
                _onSearch('禁用');
              },
            ),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('需登录的书源'),
              onTap: () {
                Navigator.pop(context);
                _onSearch('需登录');
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('无分组的书源'),
              onTap: () {
                Navigator.pop(context);
                _onSearch('无分组');
              },
            ),
            ListTile(
              leading: const Icon(Icons.explore),
              title: const Text('启用发现的书源'),
              onTap: () {
                Navigator.pop(context);
                _onSearch('启用发现');
              },
            ),
            ListTile(
              leading: const Icon(Icons.explore_off),
              title: const Text('禁用发现的书源'),
              onTap: () {
                Navigator.pop(context);
                _onSearch('禁用发现');
              },
            ),
            if (_groups.isNotEmpty) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('自定义分组', style: Theme.of(context).textTheme.titleMedium),
              ),
              ..._groups.map((group) => ListTile(
                leading: const Icon(Icons.folder),
                title: Text(group),
                selected: _filterGroup == group,
                onTap: () {
                  Navigator.pop(context);
                  _onSearch('group:$group');
                },
              )),
            ],
          ],
        ),
      ),
    );
  }

  void _showMoreMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建书源'),
              onTap: () {
                Navigator.pop(context);
                _navigateToEditPage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_upload),
              title: const Text('本地导入'),
              onTap: () {
                Navigator.pop(context);
                _importFromLocal();
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_download),
              title: const Text('网络导入'),
              onTap: () {
                Navigator.pop(context);
                _importFromUrl();
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('二维码导入'),
              onTap: () {
                Navigator.pop(context);
                // TODO: 实现二维码扫描
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.select_all),
              title: const Text('批量选择'),
              onTap: () {
                Navigator.pop(context);
                _toggleSelectionMode();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep),
              title: const Text('清空书源'),
              onTap: () {
                Navigator.pop(context);
                _clearAllSources();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('帮助'),
              onTap: () {
                Navigator.pop(context);
                _showHelp();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromLocal() async {
    // TODO: 实现本地文件导入
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本地导入功能开发中...')),
    );
  }

  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('网络导入'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '请输入书源URL',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );

    if (confirmed == true && controller.text.isNotEmpty) {
      // TODO: 实现网络导入
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('网络导入功能开发中...')),
      );
    }
  }

  Future<void> _clearAllSources() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空确认'),
        content: const Text('确定要清空所有书源吗？此操作不可恢复！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await StorageService.instance.clearBookSources();
      await _loadSources();
    }
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('书源管理帮助'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('搜索技巧：'),
              SizedBox(height: 8),
              Text('• 输入关键词搜索书源名称、URL或分组'),
              Text('• 输入"启用"或"禁用"筛选启用状态'),
              Text('• 输入"需登录"筛选需要登录的书源'),
              Text('• 输入"启用发现"或"禁用发现"筛选发现状态'),
              Text('• 输入"group:分组名"按分组筛选'),
              SizedBox(height: 16),
              Text('排序方式：'),
              SizedBox(height: 8),
              Text('• 手动排序：按自定义顺序排列'),
              Text('• 按权重：按书源权重排序'),
              Text('• 按名称：按书源名称排序'),
              Text('• 按更新时间：按最后更新时间排序'),
              Text('• 按响应时间：按书源响应速度排序'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showSourceDetail(BookSource source) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        source.bookSourceName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () {
                        Navigator.pop(context);
                        _navigateToEditPage(sourceUrl: source.bookSourceUrl);
                      },
                    ),
                  ],
                ),
              ),
              const Divider(),
              _buildDetailItem('书源URL', source.bookSourceUrl),
              _buildDetailItem('分组', source.bookSourceGroup ?? '无'),
              _buildDetailItem('类型', source.typeName),
              _buildDetailItem('权重', source.weight.toString()),
              _buildDetailItem('响应时间', '${source.respondTime}ms'),
              _buildDetailItem('最后更新', _formatTime(source.lastUpdateTime)),
              if (source.bookSourceComment != null && source.bookSourceComment!.isNotEmpty)
                _buildDetailItem('备注', source.bookSourceComment!),
              const Divider(),
              SwitchListTile(
                title: const Text('启用书源'),
                value: source.enabled,
                onChanged: (value) async {
                  await _toggleSourceEnabled(source);
                  Navigator.pop(context);
                },
              ),
              SwitchListTile(
                title: const Text('启用发现'),
                value: source.enabledExplore,
                onChanged: (value) async {
                  await _toggleSourceExplore(source);
                  Navigator.pop(context);
                },
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.delete),
                        label: const Text('删除书源'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                        onPressed: () async {
                          Navigator.pop(context);
                          await _deleteSource(source);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }

  String _formatTime(int timestamp) {
    if (timestamp == 0) return '未知';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isSelectionMode
          ? _buildSelectionAppBar()
          : _buildNormalAppBar(),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索书源...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchKeyword.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearch('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
              ),
              onSubmitted: _onSearch,
            ),
          ),
          // 书源数量
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '共 ${_filteredSources.length} 个书源',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_searchKeyword.isNotEmpty || _filterGroup != null)
                  TextButton(
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _searchKeyword = '';
                        _filterGroup = null;
                      });
                      _applyFilterAndSort();
                    },
                    child: const Text('清除筛选'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 书源列表
          Expanded(
            child: _filteredSources.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    itemCount: _filteredSources.length,
                    itemBuilder: (context, index) {
                      final source = _filteredSources[index];
                      final isSelected = _selectedSourceUrls.contains(source.bookSourceUrl);
                      return _buildSourceItem(source, isSelected);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
      title: const Text('书源管理'),
      actions: [
        // 排序按钮
        IconButton(
          icon: const Icon(Icons.sort),
          onPressed: _showSortMenu,
          tooltip: '排序',
        ),
        // 分组按钮
        IconButton(
          icon: const Icon(Icons.folder),
          onPressed: _showGroupMenu,
          tooltip: '分组',
        ),
        // 更多按钮
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'add':
                _navigateToEditPage();
                break;
              case 'import_local':
                _importFromLocal();
                break;
              case 'import_url':
                _importFromUrl();
                break;
              case 'selection':
                _toggleSelectionMode();
                break;
              case 'clear':
                _clearAllSources();
                break;
              case 'help':
                _showHelp();
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'add',
              child: ListTile(
                leading: Icon(Icons.add),
                title: Text('新建书源'),
              ),
            ),
            const PopupMenuItem(
              value: 'import_local',
              child: ListTile(
                leading: Icon(Icons.file_upload),
                title: Text('本地导入'),
              ),
            ),
            const PopupMenuItem(
              value: 'import_url',
              child: ListTile(
                leading: Icon(Icons.cloud_download),
                title: Text('网络导入'),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'selection',
              child: ListTile(
                leading: Icon(Icons.select_all),
                title: Text('批量选择'),
              ),
            ),
            const PopupMenuItem(
              value: 'clear',
              child: ListTile(
                leading: Icon(Icons.delete_sweep),
                title: Text('清空书源'),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'help',
              child: ListTile(
                leading: Icon(Icons.help_outline),
                title: Text('帮助'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _toggleSelectionMode,
      ),
      title: Text('已选择 ${_selectedSourceUrls.length} 个'),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          onPressed: _selectAll,
          tooltip: '全选',
        ),
        IconButton(
          icon: const Icon(Icons.flip),
          onPressed: _invertSelection,
          tooltip: '反选',
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'enable':
                _enableSelected(true);
                break;
              case 'disable':
                _enableSelected(false);
                break;
              case 'delete':
                _deleteSelected();
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'enable',
              child: ListTile(
                leading: Icon(Icons.check_circle),
                title: Text('启用所选'),
              ),
            ),
            const PopupMenuItem(
              value: 'disable',
              child: ListTile(
                leading: Icon(Icons.cancel),
                title: Text('禁用所选'),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete),
                title: Text('删除所选'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.source,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            _searchKeyword.isNotEmpty ? '未找到匹配的书源' : '暂无书源',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (_searchKeyword.isEmpty)
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('导入书源'),
              onPressed: _showMoreMenu,
            ),
        ],
      ),
    );
  }

  Widget _buildSourceItem(BookSource source, bool isSelected) {
    if (_isSelectionMode) {
      return CheckboxListTile(
        value: isSelected,
        onChanged: (checked) => _toggleSourceSelection(source.bookSourceUrl),
        secondary: _buildSourceTypeIcon(source),
        title: Text(source.bookSourceName),
        subtitle: Text(
          source.bookSourceGroup ?? source.typeName,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListTile(
      leading: _buildSourceTypeIcon(source),
      title: Row(
        children: [
          Expanded(child: Text(source.bookSourceName)),
          if (!source.enabled)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '禁用',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  source.typeName,
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              if (source.bookSourceGroup != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    source.bookSourceGroup!,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            source.bookSourceUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: Switch(
        value: source.enabled,
        onChanged: (value) => _toggleSourceEnabled(source),
      ),
      onTap: () => _showSourceDetail(source),
      onLongPress: () {
        setState(() {
          _isSelectionMode = true;
          _selectedSourceUrls.add(source.bookSourceUrl);
        });
      },
    );
  }

  Widget _buildSourceTypeIcon(BookSource source) {
    IconData icon;
    Color color;

    switch (source.bookSourceType) {
      case BookSourceType.text:
        icon = Icons.book;
        color = Colors.blue;
        break;
      case BookSourceType.audio:
        icon = Icons.headphones;
        color = Colors.orange;
        break;
      case BookSourceType.image:
        icon = Icons.image;
        color = Colors.green;
        break;
      case BookSourceType.video:
        icon = Icons.video_library;
        color = Colors.red;
        break;
      case BookSourceType.file:
        icon = Icons.folder;
        color = Colors.grey;
        break;
    }

    return CircleAvatar(
      backgroundColor: color.withOpacity(0.2),
      child: Icon(icon, color: color, size: 20),
    );
  }

  String _getSortName() {
    switch (_sortType) {
      case BookSourceSort.manual:
        return '手动';
      case BookSourceSort.weight:
        return '权重';
      case BookSourceSort.name:
        return '名称';
      case BookSourceSort.url:
        return 'URL';
      case BookSourceSort.update:
        return '更新';
      case BookSourceSort.respond:
        return '响应';
      case BookSourceSort.enable:
        return '状态';
    }
  }
}
