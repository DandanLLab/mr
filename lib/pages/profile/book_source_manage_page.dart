import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/book_source.dart';
import '../../providers/discovery_provider.dart';
import '../../services/book_source_import_service.dart';
import '../../services/storage_service.dart';
import 'book_source_edit_page.dart';
import 'js_source_edit_page.dart';

/// 书源模板定义
class SourceTemplate {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color color;
  final String assetPath;
  final bool isJsFile; // 是否为纯JS文件模板

  const SourceTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
    required this.assetPath,
    this.isJsFile = false,
  });
}

/// JSON模板列表（创建.json书源文件）
const List<SourceTemplate> kJsonTemplates = [
  SourceTemplate(
    id: 'json_custom',
    name: '自定义',
    description: '空白模板，无预设值，完全自由配置',
    icon: Icons.edit_note,
    color: Colors.grey,
    assetPath: '', // 空模板，无资源文件
  ),
  SourceTemplate(
    id: 'json_default',
    name: '默认模板',
    description: '阅读3.0原版格式，CSS选择器规则，兼容Legado',
    icon: Icons.data_object,
    color: Colors.blue,
    assetPath: 'assets/templates/book_source_template.json',
  ),
  SourceTemplate(
    id: 'json_api',
    name: 'JSON API 模板',
    description: '适用于JSON接口API，使用\$.xxx语法',
    icon: Icons.api,
    color: Colors.green,
    assetPath: 'assets/templates/book_source_json_template.json',
  ),
  SourceTemplate(
    id: 'json_xpath',
    name: 'XPath 模板',
    description: '使用XPath选择器解析HTML/XML',
    icon: Icons.account_tree,
    color: Colors.purple,
    assetPath: 'assets/templates/book_source_xpath_template.json',
  ),
  SourceTemplate(
    id: 'json_regex',
    name: '正则模板',
    description: '使用正则表达式匹配网页内容',
    icon: Icons.pattern,
    color: Colors.red,
    assetPath: 'assets/templates/book_source_regex_template.json',
  ),
  SourceTemplate(
    id: 'json_js',
    name: 'JSON+JS 模板',
    description: 'JSON格式 + JS规则混合，jsLib内置工具库',
    icon: Icons.code,
    color: Colors.orange,
    assetPath: 'assets/templates/book_source_js_template.json',
  ),
];

/// JS模板列表（创建.js书源文件）
const List<SourceTemplate> kJsTemplates = [
  SourceTemplate(
    id: 'js_file',
    name: '纯JS书源',
    description: '全新格式，整个书源就是一个JS文件，自由度最高',
    icon: Icons.javascript,
    color: Colors.amber,
    assetPath: 'assets/templates/book_source_js_file_template.js',
    isJsFile: true,
  ),
];

/// 书源排序类型
enum BookSourceSort {
  manual, // 手动排序
  weight, // 权重排序
  name, // 按名称
  url, // 按URL
  update, // 按更新时间
  respond, // 按响应时间
  enable, // 按启用状态
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

  Future<void> _navigateToEditPage({String? sourceUrl, BookSource? templateSource}) async {
    // 根据书源文件格式选择编辑器
    // sourceFormat == 'js' → JS代码编辑器
    // sourceFormat == 'json' 或 null → JSON表单编辑器
    if (sourceUrl != null && templateSource == null) {
      final data = StorageService.instance.getBookSource(sourceUrl);
      if (data != null) {
        final sourceFormat = data['sourceFormat'] as String? ?? '';
        if (sourceFormat == 'js') {
          // JS 书源 → 进入 JS 编辑器
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => JsSourceEditPage(sourceUrl: sourceUrl),
            ),
          );
          _loadSources();
          return;
        }
      }
    }
    // JSON 书源或新建 → 进入 JSON 表单编辑器
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BookSourceEditPage(
          sourceUrl: sourceUrl,
          templateSource: templateSource,
        ),
      ),
    );
    _loadSources();
  }

  /// 显示模板选择对话框（底部弹出式，分两大类）
  Future<void> _showTemplatePicker() async {
    final selected = await showModalBottomSheet<SourceTemplate>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.85,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            // 顶部拖拽指示条
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Text('选择书源模板', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 模板列表
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  // JSON 模板分组标题
                  _buildSectionHeader(
                    icon: Icons.data_object,
                    title: 'JSON 书源模板',
                    subtitle: '创建 .json 格式书源',
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 4),
                  // JSON 模板网格
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: kJsonTemplates.map((t) => _buildTemplateCard(context, t)).toList(),
                  ),
                  const SizedBox(height: 16),
                  // JS 模板分组标题
                  _buildSectionHeader(
                    icon: Icons.javascript,
                    title: 'JS 书源模板',
                    subtitle: '创建 .js 格式书源',
                    color: Colors.amber.shade800,
                  ),
                  const SizedBox(height: 4),
                  // JS 模板网格
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: kJsTemplates.map((t) => _buildTemplateCard(context, t)).toList(),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (selected != null) {
      _createFromTemplate(selected);
    }
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: color)),
              Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTemplateCard(BuildContext context, SourceTemplate template) {
    return InkWell(
      onTap: () => Navigator.pop(context, template),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: (MediaQuery.of(context).size.width - 56) / 2,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: template.color.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(12),
          color: template.color.withValues(alpha: 0.05),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(template.icon, color: template.color, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    template.name,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: template.color),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              template.description,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// 从模板创建书源
  Future<void> _createFromTemplate(SourceTemplate template) async {
    try {
      if (template.isJsFile) {
        // JS文件模板：进入JS代码编辑器页面
        final jsCode = template.assetPath.isEmpty
            ? '' // 空白JS模板
            : await rootBundle.loadString(template.assetPath);
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => JsSourceEditPage(initialJsCode: jsCode),
          ),
        ).then((_) => _loadSources());
      } else if (template.id == 'json_custom' || template.assetPath.isEmpty) {
        // 自定义空模板：直接进入空白编辑器
        _navigateToEditPage();
      } else {
        // JSON模板：直接加载JSON创建书源
        final jsonStr = await rootBundle.loadString(template.assetPath);
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        // 清空URL和名称，让用户填写
        json['bookSourceUrl'] = '';
        json['bookSourceName'] = '';
        final templateSource = BookSource.fromJson(json);
        _navigateToEditPage(templateSource: templateSource);
      }
    } catch (e) {
      // 模板加载失败，直接创建空白书源
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('模板加载失败: $e，将创建空白书源')),
        );
      }
      _navigateToEditPage();
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
        if (source.bookSourceGroup != null &&
            source.bookSourceGroup!.isNotEmpty) {
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
        result = result
            .where((s) => s.loginUrl != null && s.loginUrl!.isNotEmpty)
            .toList();
      } else if (keyword == '无分组' || keyword == 'no_group') {
        result = result
            .where(
                (s) => s.bookSourceGroup == null || s.bookSourceGroup!.isEmpty)
            .toList();
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
          sortedSources
              .sort((a, b) => a.bookSourceName.compareTo(b.bookSourceName));
        } else {
          sortedSources
              .sort((a, b) => b.bookSourceName.compareTo(a.bookSourceName));
        }
        break;
      case BookSourceSort.url:
        if (_isSortAscending) {
          sortedSources
              .sort((a, b) => a.bookSourceUrl.compareTo(b.bookSourceUrl));
        } else {
          sortedSources
              .sort((a, b) => b.bookSourceUrl.compareTo(a.bookSourceUrl));
        }
        break;
      case BookSourceSort.update:
        if (_isSortAscending) {
          sortedSources
              .sort((a, b) => a.lastUpdateTime.compareTo(b.lastUpdateTime));
        } else {
          sortedSources
              .sort((a, b) => b.lastUpdateTime.compareTo(a.lastUpdateTime));
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
            return cmp != 0
                ? cmp
                : a.bookSourceName.compareTo(b.bookSourceName);
          });
        } else {
          sortedSources.sort((a, b) {
            final aEnabled = a.enabled ? 1 : 0;
            final bEnabled = b.enabled ? 1 : 0;
            final cmp = aEnabled.compareTo(bEnabled);
            return cmp != 0
                ? cmp
                : a.bookSourceName.compareTo(b.bookSourceName);
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
    final updatedSource =
        source.copyWith(enabledExplore: !source.enabledExplore);
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
        child: RadioGroup<BookSourceSort>(
          groupValue: _sortType,
          onChanged: (value) {
            Navigator.pop(context);
            _setSortType(value!);
          },
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
                      icon: Icon(_isSortAscending
                          ? Icons.arrow_upward
                          : Icons.arrow_downward),
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
                  )),
            ],
          ),
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
              child:
                  Text('分组筛选', style: Theme.of(context).textTheme.titleLarge),
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
                child: Text('自定义分组',
                    style: Theme.of(context).textTheme.titleMedium),
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
                _showTemplatePicker();
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
              leading: const Icon(Icons.file_download),
              title: const Text('导出书源'),
              onTap: () {
                Navigator.pop(context);
                _exportSources();
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
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'js'],
        withData: true,
      );
      final file = picked?.files.single;
      final bytes = file?.bytes;
      if (bytes == null) return;
      // 根据文件后缀判定格式
      final ext = file?.extension?.toLowerCase();
      final result = await BookSourceImportService().importBytes(bytes, fileExtension: ext);
      await _loadSources();
      if (!mounted) return;
      _showImportResult(result);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
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

    if (confirmed == true && controller.text.trim().isNotEmpty) {
      try {
        final result =
            await BookSourceImportService().importText(controller.text);
        await _loadSources();
        if (!mounted) return;
        _showImportResult(result);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('网络导入失败: $e')),
        );
      }
    }
  }

  void _showImportResult(BookSourceImportResult result) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '导入 ${result.sources.length} 个书源：新增 ${result.added}，更新 ${result.updated}，未变 ${result.unchanged}',
        ),
      ),
    );
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

  /// 导出所有书源为JSON文件并通过share_plus分享
  Future<void> _exportSources() async {
    if (_allSources.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可导出的书源')),
        );
      }
      return;
    }
    await _doExport(_allSources);
  }

  /// 导出已选中的书源
  Future<void> _exportSelectedSources() async {
    if (_selectedSourceUrls.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先选择要导出的书源')),
        );
      }
      return;
    }
    final selectedSources = _allSources
        .where((s) => _selectedSourceUrls.contains(s.bookSourceUrl))
        .toList();
    await _doExport(selectedSources);
  }

  /// 执行导出：将书源列表序列化为JSON，写入临时文件后通过share_plus分享
  Future<void> _doExport(List<BookSource> sources) async {
    try {
      final jsonList = sources.map((s) => s.toJson()).toList();
      final jsonStr = const JsonEncoder.withIndent('  ').convert(jsonList);

      // 写入应用临时目录（无需任何权限）
      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      final fileName =
          'book_source_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.json';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(jsonStr);

      if (!mounted) return;
      // 通过系统分享面板导出，用户可选择保存到任意位置
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: '导出书源',
        text: '导出 ${sources.length} 个书源',
      );

      // 分享完成后清理临时文件
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: $e')),
      );
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
              if (source.bookSourceComment != null &&
                  source.bookSourceComment!.isNotEmpty)
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
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red),
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
      appBar: _isSelectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
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
                      final isSelected =
                          _selectedSourceUrls.contains(source.bookSourceUrl);
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
                _showTemplatePicker();
                break;
              case 'import_local':
                _importFromLocal();
                break;
              case 'import_url':
                _importFromUrl();
                break;
              case 'export':
                _exportSources();
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
            const PopupMenuItem(
              value: 'export',
              child: ListTile(
                leading: Icon(Icons.file_download),
                title: Text('导出书源'),
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
              case 'export':
                _exportSelectedSources();
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
            const PopupMenuItem(
              value: 'export',
              child: ListTile(
                leading: Icon(Icons.file_download),
                title: Text('导出所选'),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

}
