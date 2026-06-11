import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/book_source.dart';
import '../../models/rules/search_rule.dart';
import '../../models/rules/explore_rule.dart';
import '../../models/rules/book_info_rule.dart';
import '../../models/rules/toc_rule.dart';
import '../../models/rules/content_rule.dart';
import '../../services/storage_service.dart';
import '../../routes/app_routes.dart';

/// JS 书源编辑器页面
/// 直接显示代码编辑器，简洁高效
/// 保存到内部存储（Hive），调试页面与 JSON 编辑器共用
class JsSourceEditPage extends StatefulWidget {
  final String initialJsCode;
  final String? sourceUrl;

  const JsSourceEditPage({
    super.key,
    this.initialJsCode = '',
    this.sourceUrl,
  });

  @override
  State<JsSourceEditPage> createState() => _JsSourceEditPageState();
}

class _JsSourceEditPageState extends State<JsSourceEditPage> {
  late TextEditingController _jsController;

  // 书源基本信息（从JS代码注释中提取或手动设置）
  String _sourceName = '';
  String _sourceUrl = '';
  String _sourceGroup = 'JS书源';

  bool _isModified = false;
  bool _isSaving = false;
  bool _showLineNumbers = true;

  @override
  void initState() {
    super.initState();
    _jsController = TextEditingController(text: widget.initialJsCode);
    _jsController.addListener(() {
      _isModified = true;
      _tryExtractMetadata();
    });

    if (widget.sourceUrl != null) {
      _loadExistingSource();
    } else if (widget.initialJsCode.isEmpty) {
      // 新建时插入默认模板
      _jsController.text = _defaultTemplate;
    }
  }

  /// 默认 JS 书源模板（包含元数据注释，借鉴 legado 的书源结构）
  static const _defaultTemplate = '''// @name 书源名称
// @url https://www.example.com
// @group JS书源
// @type 0

// 搜索（key=关键词, page=页码）
function search(key, page) {
  var url = "https://www.example.com/search?q=" + key + "&p=" + page;
  var html = fetch(url);
  // 解析搜索结果，返回数组
  return [];
}

// 发现（url=分类地址）
function explore(url) {
  var html = fetch(url);
  return [];
}

// 书籍详情
function bookInfo(url) {
  var html = fetch(url);
  return {};
}

// 章节目录
function toc(url) {
  var html = fetch(url);
  return [];
}

// 正文内容
function content(url) {
  var html = fetch(url);
  return "";
}
''';

  /// 从 JS 代码中动态提取元数据（借鉴 legado 的注释约定）
  void _tryExtractMetadata() {
    final code = _jsController.text;
    var name = _extractMeta(code, 'name');
    var url = _extractMeta(code, 'url');
    var group = _extractMeta(code, 'group');

    // 也支持 var bookSourceName = "xxx" 格式
    if (name == null) {
      final m = RegExp(r'''var\s+bookSourceName\s*=\s*["']([^"']+)["']''').firstMatch(code);
      name = m?.group(1);
    }
    if (url == null) {
      final m = RegExp(r'''var\s+bookSourceUrl\s*=\s*["']([^"']+)["']''').firstMatch(code);
      url = m?.group(1);
    }
    if (group == null) {
      final m = RegExp(r'''var\s+bookSourceGroup\s*=\s*["']([^"']+)["']''').firstMatch(code);
      group = m?.group(1);
    }

    if (name != null && name != _sourceName) {
      _sourceName = name;
    }
    if (url != null && url != _sourceUrl) {
      _sourceUrl = url;
    }
    if (group != null && group != _sourceGroup) {
      _sourceGroup = group;
    }
  }

  /// 提取 // @key value 格式的元数据
  static String? _extractMeta(String code, String key) {
    final m = RegExp('//\\s*@' + key + r'\s+(.+)$', multiLine: true).firstMatch(code);
    return m?.group(1)?.trim();
  }

  Future<void> _loadExistingSource() async {
    final storage = StorageService.instance;
    final sourceData = storage.getBookSource(widget.sourceUrl!);
    if (sourceData != null) {
      final source = BookSource.fromJson(sourceData);
      _sourceName = source.bookSourceName;
      _sourceUrl = source.bookSourceUrl;
      _sourceGroup = source.bookSourceGroup ?? 'JS书源';
      _jsController.text = source.jsLib ?? '';
    }
  }

  @override
  void dispose() {
    _jsController.dispose();
    super.dispose();
  }

  /// 构建 BookSource 对象（借鉴 legado 的书源结构）
  /// JS代码中定义的函数自动映射到对应规则
  BookSource _buildSource() {
    final code = _jsController.text;

    // 从JS代码提取 @type 元数据
    final typeStr = _extractMeta(code, 'type');
    final sourceType = typeStr != null ? int.tryParse(typeStr) ?? 0 : 0;

    // 从JS代码提取 searchUrl 和 exploreUrl（可选）
    final searchUrlMeta = _extractMeta(code, 'searchUrl');
    final exploreUrlMeta = _extractMeta(code, 'exploreUrl');
    final headerMeta = _extractMeta(code, 'header');

    // 检测JS代码中定义了哪些函数
    final hasSearch = RegExp(r'function\s+search\s*\(').hasMatch(code);
    final hasExplore = RegExp(r'function\s+explore\s*\(').hasMatch(code);
    final hasBookInfo = RegExp(r'function\s+bookInfo\s*\(').hasMatch(code);
    final hasToc = RegExp(r'function\s+toc\s*\(').hasMatch(code);
    final hasContent = RegExp(r'function\s+content\s*\(').hasMatch(code);

    return BookSource(
      bookSourceUrl: _sourceUrl,
      bookSourceName: _sourceName,
      bookSourceGroup: _sourceGroup,
      bookSourceType: BookSourceType.values.firstWhere(
        (e) => e.index == sourceType,
        orElse: () => BookSourceType.text,
      ),
      enabled: true,
      enabledExplore: hasExplore,
      enabledCookieJar: true,
      engine: 'quickjs',
      jsLib: code,
      sourceFormat: 'js',
      header: headerMeta,
      searchUrl: searchUrlMeta ?? '',
      exploreUrl: exploreUrlMeta ?? '',
      ruleSearch: hasSearch ? SearchRule(
        bookList: '<js>search(key, page, result)</js>',
        name: '\$.name',
        author: '\$.author',
        bookUrl: '\$.bookUrl',
        coverUrl: '\$.coverUrl',
        intro: '\$.intro',
        kind: '\$.kind',
        lastChapter: '\$.lastChapter',
      ) : null,
      ruleExplore: hasExplore ? ExploreRule(
        bookList: '<js>explore(baseUrl, result)</js>',
        name: '\$.name',
        author: '\$.author',
        bookUrl: '\$.bookUrl',
        coverUrl: '\$.coverUrl',
        intro: '\$.intro',
        kind: '\$.kind',
        lastChapter: '\$.lastChapter',
      ) : null,
      ruleBookInfo: hasBookInfo ? BookInfoRule(
        init: '<js>bookInfo(result)</js>',
        name: '\$.name',
        author: '\$.author',
        coverUrl: '\$.coverUrl',
        intro: '\$.intro',
        kind: '\$.kind',
        lastChapter: '\$.lastChapter',
        tocUrl: '\$.tocUrl',
        wordCount: '\$.wordCount',
      ) : null,
      ruleToc: hasToc ? TocRule(
        chapterList: '<js>toc(result)</js>',
        chapterName: '\$.name',
        chapterUrl: '\$.url',
        isVolume: '\$.isVolume',
        nextTocUrl: '<js>nextTocUrl(result)</js>',
      ) : null,
      ruleContent: hasContent ? ContentRule(
        content: '<js>content(result)</js>',
        nextContentUrl: '<js>nextContentUrl(result)</js>',
      ) : null,
    );
  }

  /// 保存书源（内部存储，不需要权限）
  Future<void> _saveSource() async {
    // 从JS代码中提取元数据（@name, @url, @group 等）
    _tryExtractMetadata();

    // 自动补全缺失的元数据，不弹对话框
    if (_sourceName.isEmpty) {
      _sourceName = 'JS书源_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    }
    if (_sourceUrl.isEmpty) {
      _sourceUrl = 'js_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    }
    if (_sourceGroup.isEmpty) {
      _sourceGroup = 'JS书源';
    }

    setState(() => _isSaving = true);

    try {
      final source = _buildSource();
      await StorageService.instance.saveBookSource(source.toJson());
      _isModified = false;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存成功')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保存失败: $e'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: '重试',
              onPressed: _saveSource,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 弹出书源基本信息对话框
  Future<Map<String, String>?> _showSourceInfoDialog() async {
    final nameCtl = TextEditingController(text: _sourceName);
    final urlCtl = TextEditingController(text: _sourceUrl);
    final groupCtl = TextEditingController(text: _sourceGroup);

    return showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('书源信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(
                labelText: '书源名称 *',
                hintText: '例如：笔趣阁',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtl,
              decoration: const InputDecoration(
                labelText: '书源URL *',
                hintText: '例如：https://www.biquge.com',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: groupCtl,
              decoration: const InputDecoration(
                labelText: '分组',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, {
              'name': nameCtl.text.trim(),
              'url': urlCtl.text.trim(),
              'group': groupCtl.text.trim(),
            }),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 调试书源
  void _debugSource() {
    if (_sourceUrl.isEmpty) {
      // 先保存再调试
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先保存书源再调试')),
      );
      return;
    }
    final source = _buildSource();
    Navigator.pushNamed(context, AppRoutes.bookSourceDebug, arguments: {
      'sourceUrl': source.bookSourceUrl,
      'source': source,
    });
  }

  /// 插入代码片段
  void _insertSnippet(String snippet) {
    final text = _jsController.text;
    final sel = _jsController.selection;
    final start = sel.baseOffset;
    final end = sel.extentOffset;
    final newText = text.replaceRange(start, end, snippet);
    _jsController.text = newText;
    _jsController.selection = TextSelection.collapsed(
      offset: start + snippet.length,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isModified,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _showDiscardDialog();
        if (shouldPop && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_sourceName.isEmpty ? 'JS 书源' : _sourceName),
          actions: [
            // 保存
            IconButton(
              icon: _isSaving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              tooltip: '保存',
              onPressed: _isSaving ? null : _saveSource,
            ),
            // 调试
            IconButton(
              icon: const Icon(Icons.bug_report),
              tooltip: '调试',
              onPressed: _debugSource,
            ),
            // 更多菜单（代码片段、行号、帮助、书源信息等）
            PopupMenuButton<String>(
              tooltip: '更多选项',
              offset: const Offset(0, 48),
              onSelected: (value) {
                switch (value) {
                  case 'snippet':
                    _showSnippetPanel();
                    break;
                  case 'linenum':
                    setState(() => _showLineNumbers = !_showLineNumbers);
                    break;
                  case 'help':
                    Navigator.push(context, MaterialPageRoute(
                      builder: (context) => const _JsHelpPage(),
                    ));
                    break;
                  case 'info':
                    _showSourceInfoDialog().then((r) {
                      if (r != null) {
                        setState(() {
                          _sourceName = r['name'] ?? _sourceName;
                          _sourceUrl = r['url'] ?? _sourceUrl;
                          _sourceGroup = r['group'] ?? _sourceGroup;
                        });
                      }
                    });
                    break;
                  case 'format':
                    _formatCode();
                    break;
                  case 'copy':
                    Clipboard.setData(ClipboardData(text: _jsController.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制到剪贴板')),
                    );
                    break;
                  case 'clear':
                    _jsController.clear();
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'snippet',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('代码片段'),
                ),
                PopupMenuItem(
                  value: 'linenum',
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(_showLineNumbers ? '隐藏行号' : '显示行号'),
                ),
                const PopupMenuItem(
                  value: 'help',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('帮助文档'),
                ),
                const PopupMenuItem(
                  value: 'info',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('书源信息'),
                ),
                const PopupMenuItem(
                  value: 'format',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('格式化代码'),
                ),
                const PopupMenuItem(
                  value: 'copy',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('复制全部代码'),
                ),
                const PopupMenuItem(
                  value: 'clear',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('清空代码'),
                ),
              ],
            ),
          ],
        ),
        body: _buildCodeEditor(),
      ),
    );
  }

  void _showSnippetPanel() {
    final snippets = [
      ('元数据', '// @name 书源名称\n// @url https://\n// @group JS书源\n// @type 0\n'),
      ('搜索', 'function search(key, page) {\n  var url = "https://www.example.com/search?q=" + key;\n  var html = fetch(url);\n  return [];\n}\n'),
      ('发现', 'function explore(url) {\n  var html = fetch(url);\n  return [];\n}\n'),
      ('详情', 'function bookInfo(url) {\n  var html = fetch(url);\n  return {};\n}\n'),
      ('目录', 'function toc(url) {\n  var html = fetch(url);\n  return [];\n}\n'),
      ('正文', 'function content(url) {\n  var html = fetch(url);\n  return "";\n}\n'),
      ('GET', 'var html = fetch(url);\n'),
      ('POST', "var result = fetch(url, {method: 'POST', body: data});\n"),
      ('AES', "var key = CryptoJS.enc.Utf8.parse('key');\nvar iv = CryptoJS.enc.Utf8.parse('iv');\nvar enc = CryptoJS.AES.encrypt(data, key, {iv: iv});\n"),
      ('MD5', "var hash = CryptoJS.MD5(data).toString();\n"),
      ('JSON', 'var data = JSON.parse(result);\n'),
      ('日志', "console.log('debug:', value);\n"),
    ];

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SizedBox(
        height: 200,
        child: GridView.count(
          crossAxisCount: 4,
          padding: const EdgeInsets.all(12),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.5,
          children: snippets.map((item) {
            final (label, _) = item;
            return ActionChip(
              label: Text(label, style: const TextStyle(fontSize: 12)),
              onPressed: () {
                _insertSnippet(item.$2);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildCodeEditor() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_showLineNumbers) _buildLineNumbers(),
          Expanded(child: _buildCodeField()),
        ],
      ),
    );
  }

  Widget _buildLineNumbers() {
    final lines = _jsController.text.split('\n').length;
    return Container(
      width: 48,
      color: const Color(0xFF252526),
      padding: const EdgeInsets.only(top: 12, right: 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(lines, (i) => Text(
            '${i + 1}',
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 13,
              color: Color(0xFF858585),
              height: 1.5,
            ),
          )),
        ),
      ),
    );
  }

  Widget _buildCodeField() {
    return TextField(
      controller: _jsController,
      maxLines: null,
      expands: true,
      style: const TextStyle(
        fontFamily: 'Consolas',
        fontSize: 13,
        color: Color(0xFFD4D4D4),
        height: 1.5,
      ),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(12),
        hintText: '// 在代码中用注释定义元数据，无需手动配置：\n'
            '// @name 书源名称\n'
            '// @url https://www.example.com\n'
            '// @group JS书源\n'
            '// @type 0\n\n'
            '// 可用变量: result, baseUrl, source, book, chapter, cookie\n'
            '// 可用函数: fetch(), console.log(), CryptoJS, btoa(), atob()\n'
            '// 可用桥接: java.get(), java.jsoup.*, java.aesEncode()\n\n'
            'function search(key, page) {\n'
            '  return [];\n'
            '}',
        hintStyle: TextStyle(color: Color(0xFF6A9955)),
      ),
      cursorColor: const Color(0xFFAEAFAD),
    );
  }

  void _formatCode() {
    final code = _jsController.text;
    final lines = code.split('\n');
    final formatted = <String>[];
    int indent = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        formatted.add('');
        continue;
      }
      if (trimmed.startsWith('}') || trimmed.startsWith(']') || trimmed.startsWith(')')) {
        indent = (indent - 1).clamp(0, 100);
      }
      formatted.add('  ' * indent + trimmed);
      if (trimmed.endsWith('{') || trimmed.endsWith('[') || trimmed.endsWith('(')) {
        indent = (indent + 1).clamp(0, 100);
      }
    }
    _jsController.text = formatted.join('\n');
  }

  Future<bool> _showDiscardDialog() async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('你有未保存的修改，确定要退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context, false);
              _saveSource();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ) ?? false;
  }
}

/// JS帮助文档页面
class _JsHelpPage extends StatefulWidget {
  const _JsHelpPage();

  @override
  State<_JsHelpPage> createState() => _JsHelpPageState();
}

class _JsHelpPageState extends State<_JsHelpPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _jsHelp = '';
  String _generalHelp = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadHelp();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadHelp() async {
    try {
      final results = await Future.wait([
        rootBundle.loadString('assets/templates/book_source_js_help.md'),
        rootBundle.loadString('assets/templates/book_source_help.md'),
      ]);
      if (mounted) {
        setState(() {
          _jsHelp = results[0];
          _generalHelp = results[1];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _jsHelp = '# 加载帮助文档失败\n\n$e';
          _generalHelp = _jsHelp;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('帮助文档'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'JS 开发'),
            Tab(text: '规则语法'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildMarkdownView(_jsHelp),
                _buildMarkdownView(_generalHelp),
              ],
            ),
    );
  }

  Widget _buildMarkdownView(String content) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        content,
        style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.6),
      ),
    );
  }
}
