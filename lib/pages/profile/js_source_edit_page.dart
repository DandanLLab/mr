import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
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
      // 刷新行号和元数据显示
      if (mounted) setState(() {});
    });

    if (widget.sourceUrl != null) {
      _loadExistingSource();
    } else if (widget.initialJsCode.isEmpty) {
      // 新建时插入默认模板
      _jsController.text = _defaultTemplate;
    }
  }

  /// 默认 JS 书源模板（包含元数据注释，借鉴 legado 的书源结构）
  /// 函数签名与 _buildSource() 生成的规则一致：
  ///   search(key, page, result)  — key=搜索词 page=页码 result=搜索页HTML
  ///   explore(baseUrl, result)   — baseUrl=分类URL result=发现页HTML
  ///   bookInfo(result)           — result=详情页HTML
  ///   toc(result)                — result=目录页HTML
  ///   content(result)            — result=正文页HTML
  static const _defaultTemplate = r'''// @name 书源名称
// @url https://www.example.com
// @group JS书源
// @type 0
var searchUrl = '/search?q={{key}}&p={{page}}';
var exploreUrl = JSON.stringify([
  {title:"分类1", url:"/category/1/{{page}}.html", style:{layout_flexBasisPercent:0.25, layout_flexGrow:1}}
]);

// ===== 搜索 =====
// key=搜索词, page=页码, result=搜索页HTML（框架自动请求并传入）
function search(key, page, result) {
  var html = result;
  var items = select(html, ".book-list > .item");
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    results.push({
      name: selectFirst(item, ".book-name") || "",
      author: selectFirst(item, ".author") || "",
      bookUrl: getAttr(item, "a.title", "href") || "",
      coverUrl: getAttr(item, "img.cover", "src") || "",
      kind: selectFirst(item, ".tag") || "",
      lastChapter: selectFirst(item, ".latest") || "",
      intro: selectFirst(item, ".intro") || ""
    });
  }

  return results;
}

// ===== 发现 =====
// baseUrl=分类URL, result=发现页HTML
function explore(baseUrl, result) {
  var html = result;
  var items = select(html, ".book-list > .item");
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    results.push({
      name: selectFirst(item, ".book-name") || "",
      author: selectFirst(item, ".author") || "",
      bookUrl: getAttr(item, "a.title", "href") || "",
      coverUrl: getAttr(item, "img.cover", "src") || "",
      kind: selectFirst(item, ".tag") || "",
      lastChapter: selectFirst(item, ".latest") || ""
    });
  }

  return results;
}

// ===== 书籍详情 =====
function bookInfo(result) {
  var html = result;

  return {
    name: selectFirst(html, "h1.book-title") || "",
    author: selectFirst(html, ".author-name") || "",
    coverUrl: getAttr(html, "img.cover", "src") || "",
    intro: selectFirst(html, ".book-intro") || "",
    kind: selectFirst(html, ".book-category") || "",
    lastChapter: selectFirst(html, ".latest-chapter") || "",
    tocUrl: "",
    wordCount: ""
  };
}

// ===== 章节目录 =====
function toc(result) {
  var html = result;
  var items = select(html, ".chapter-list li");
  var chapters = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    chapters.push({
      name: selectFirst(item, "a") || "",
      url: getAttr(item, "a", "href") || "",
      isVolume: false
    });
  }

  return chapters;
}

// ===== 目录下一页（可选，没有多页目录可删除）=====
function nextTocUrl(result) {
  var html = result;
  // 方式1：从分页链接提取
  var next = getAttr(html, "a.next-page", "href") || "";
  // 方式2：从下拉框提取（如 <option value="/book/xxx_2/">第21-40章</option>）
  // var options = select(html, "option");
  // for (var i = 0; i < options.length; i++) {
  //   var val = getAttr(options[i], "", "value") || "";
  //   if (val && !val.match(/\/\d+\/$/)) return val;
  // }
  return next;
}

// ===== 正文内容 =====
function content(result) {
  var html = result;
  var text = selectFirst(html, "#content");
  if (text) {
    text = text
      .replace(/.*最新网址.*/g, "")
      .replace(/上一章|下一章|返回目录/g, "")
      .trim();
  }
  return text || "";
}

// ===== 正文下一页（可选，没有多页正文可删除）=====
function nextContentUrl(result) {
  var html = result;
  var links = select(html, "a");
  for (var i = 0; i < links.length; i++) {
    var text = selectFirst(links[i], "") || "";
    if (text.indexOf("下一页") >= 0) {
      return getAttr(links[i], "", "href") || "";
    }
  }
  return "";
}
''';

  /// 从 JS 代码中动态提取元数据
  /// 支持两种格式：
  ///   1. 注释格式：// @name 书源名称
  ///   2. JS 变量格式：var bookSourceName = "书源名称" 或 var name = "书源名称"
  void _tryExtractMetadata() {
    final code = _jsController.text;
    var name = _extractMeta(code, 'name');
    var url = _extractMeta(code, 'url');
    var group = _extractMeta(code, 'group');

    // 也支持 JS 变量声明格式
    if (name == null) {
      final m = RegExp(r'''var\s+(?:bookSource)?[Nn]ame\s*=\s*["']([^"']+)["']''').firstMatch(code);
      name = m?.group(1);
    }
    if (url == null) {
      final m = RegExp(r'''var\s+(?:bookSource)?[Uu]rl\s*=\s*["']([^"']+)["']''').firstMatch(code);
      url = m?.group(1);
    }
    if (group == null) {
      final m = RegExp(r'''var\s+(?:bookSource)?[Gg]roup\s*=\s*["']([^"']+)["']''').firstMatch(code);
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
    final lines = code.split('\n');
    final buffer = StringBuffer();
    bool collecting = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (!collecting) {
        final m = RegExp('^//\\s*@' + key + r'\s+(.*)$').firstMatch(trimmed);
        if (m != null) {
          collecting = true;
          final rest = m.group(1)?.trim() ?? '';
          if (rest.isNotEmpty) buffer.write(rest);
        }
      } else {
        if (trimmed.startsWith('//')) {
          final content = trimmed.substring(2).trim();
          if (RegExp(r'^@\w+').hasMatch(content)) break;
          buffer.writeln();
          buffer.write(content);
        } else {
          break;
        }
      }
    }

    final result = buffer.toString().trim();
    return result.isEmpty ? null : result;
  }

  /// 从 JS 变量声明中提取元数据
  /// 支持：var searchUrl = "xxx" 或 var searchUrl = 'xxx'
  /// 对于 JS 表达式（如 JSON.stringify(...)），自动添加 @js: 前缀
  static String? _extractJsVar(String code, String key) {
    // 简单字符串赋值：var xxx = "value" 或 var xxx = 'value'
    final simpleMatch = RegExp('''var\\s+$key\\s*=\\s*["']([^"']+)["']''').firstMatch(code);
    if (simpleMatch != null) return simpleMatch.group(1);

    // JS 表达式赋值：var xxx = JSON.stringify({...}) 等
    // 提取到下一个 var/function/@注释 为止
    final multiLineMatch = RegExp('var\\s+$key\\s*=\\s*(.*?)(?=\\nvar\\s|\\nfunction\\s|\\n//\\s*@)', dotAll: true).firstMatch(code);
    if (multiLineMatch != null) {
      var value = multiLineMatch.group(1)?.trim() ?? '';
      if (value.isNotEmpty) {
        // JS 表达式需要 @js: 前缀，运行时才知道要执行
        return '@js:$value';
      }
    }

    return null;
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

    // 从JS代码提取元数据（支持注释格式和 JS 变量格式）
    final typeStr = _extractMeta(code, 'type') ?? _extractJsVar(code, 'type');
    final sourceType = typeStr != null ? int.tryParse(typeStr) ?? 0 : 0;

    var searchUrlMeta = _extractMeta(code, 'searchUrl') ?? _extractJsVar(code, 'searchUrl');
    var exploreUrlMeta = _extractMeta(code, 'exploreUrl') ?? _extractJsVar(code, 'exploreUrl');
    var headerMeta = _extractMeta(code, 'header') ?? _extractJsVar(code, 'header');

    // 检测JS代码中定义了哪些函数
    final hasSearch = RegExp(r'function\s+search\s*\(').hasMatch(code);
    final hasExplore = RegExp(r'function\s+explore\s*\(').hasMatch(code);
    final hasBookInfo = RegExp(r'function\s+bookInfo\s*\(').hasMatch(code);
    final hasToc = RegExp(r'function\s+toc\s*\(').hasMatch(code);
    final hasContent = RegExp(r'function\s+content\s*\(').hasMatch(code);
    final hasNextTocUrl = RegExp(r'function\s+nextTocUrl\s*\(').hasMatch(code);
    final hasNextContentUrl = RegExp(r'function\s+nextContentUrl\s*\(').hasMatch(code);

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
        nextTocUrl: hasNextTocUrl ? '<js>nextTocUrl(result)</js>' : null,
      ) : null,
      ruleContent: hasContent ? ContentRule(
        content: '<js>content(result)</js>',
        nextContentUrl: hasNextContentUrl ? '<js>nextContentUrl(result)</js>' : null,
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
    final source = _buildSource();
    if (source.bookSourceUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写书源URL（// @url）再调试')),
      );
      return;
    }
    Navigator.pushNamed(context, AppRoutes.bookSourceDebug, arguments: {
      'sourceUrl': source.bookSourceUrl,
      'source': source,
    });
  }

  /// 搜索测试（保存后跳转搜索页）
  void _searchWithSource() {
    final source = _buildSource();
    if (source.bookSourceUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写书源URL（// @url）再搜索测试')),
      );
      return;
    }
    StorageService.instance.saveBookSource(source.toJson()).then((_) {
      if (!mounted) return;
      Navigator.pushNamed(context, AppRoutes.search, arguments: {
        'sourceUrl': source.bookSourceUrl,
      });
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

  /// 从剪贴板粘贴代码
  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板为空')),
        );
      }
      return;
    }
    _insertSnippet(text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已粘贴剪贴板内容')),
      );
    }
  }

  /// 二维码导入（跳转到导入页面）
  void _importFromQr() {
    Navigator.pushNamed(context, AppRoutes.bookSourceImport);
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
                  case 'search':
                    _searchWithSource();
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
                  case 'paste':
                    _pasteFromClipboard();
                    break;
                  case 'qr':
                    _importFromQr();
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
                  value: 'search',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('搜索测试'),
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
                  value: 'paste',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('粘贴代码'),
                ),
                const PopupMenuItem(
                  value: 'qr',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text('二维码导入'),
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
      ('元数据', '// @name 书源名称\n// @url https://\n// @group JS书源\n// @type 0\nvar searchUrl = \'/search?q={{key}}&p={{page}}\';\nvar exploreUrl = \'[]\';\n'),
      ('搜索', 'function search(key, page, result) {\n  var html = result;\n  var items = select(html, ".item");\n  var results = [];\n  for (var i = 0; i < items.length; i++) {\n    var item = items[i];\n    results.push({\n      name: selectFirst(item, "a") || "",\n      author: selectFirst(item, ".author") || "",\n      bookUrl: getAttr(item, "a", "href") || "",\n      coverUrl: getAttr(item, "img", "src") || "",\n      kind: "",\n      lastChapter: "",\n      intro: ""\n    });\n  }\n  return results;\n}\n'),
      ('发现', 'function explore(baseUrl, result) {\n  var html = result;\n  var items = select(html, ".item");\n  var results = [];\n  for (var i = 0; i < items.length; i++) {\n    var item = items[i];\n    results.push({\n      name: selectFirst(item, "a") || "",\n      author: selectFirst(item, ".author") || "",\n      bookUrl: getAttr(item, "a", "href") || "",\n      coverUrl: getAttr(item, "img", "src") || "",\n      kind: "",\n      lastChapter: ""\n    });\n  }\n  return results;\n}\n'),
      ('详情', 'function bookInfo(result) {\n  var html = result;\n  return {\n    name: selectFirst(html, "h1") || "",\n    author: selectFirst(html, ".author") || "",\n    coverUrl: getAttr(html, "img", "src") || "",\n    intro: selectFirst(html, ".intro") || "",\n    kind: "",\n    lastChapter: "",\n    tocUrl: "",\n    wordCount: ""\n  };\n}\n'),
      ('目录', 'function toc(result) {\n  var html = result;\n  var items = select(html, ".chapter-list li");\n  var chapters = [];\n  for (var i = 0; i < items.length; i++) {\n    var item = items[i];\n    chapters.push({\n      name: selectFirst(item, "a") || "",\n      url: getAttr(item, "a", "href") || "",\n      isVolume: false\n    });\n  }\n  return chapters;\n}\n'),
      ('正文', 'function content(result) {\n  var html = result;\n  var text = selectFirst(html, "#content");\n  if (text) {\n    text = text.replace(/上一章|下一章|返回目录/g, "").trim();\n  }\n  return text || "";\n}\n'),
      ('目录翻页', 'function nextTocUrl(result) {\n  var html = result;\n  var next = getAttr(html, "a.next-page", "href") || "";\n  return next;\n}\n'),
      ('正文翻页', 'function nextContentUrl(result) {\n  var html = result;\n  var links = select(html, "a");\n  for (var i = 0; i < links.length; i++) {\n    var text = selectFirst(links[i], "") || "";\n    if (text.indexOf("下一页") >= 0) {\n      return getAttr(links[i], "", "href") || "";\n    }\n  }\n  return "";\n}\n'),
      ('select', 'select(html, "CSS选择器")\n'),
      ('selectFirst', 'selectFirst(html, "CSS选择器")\n'),
      ('getAttr', 'getAttr(html, "CSS选择器", "属性名")\n'),
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
        hintText: '// 用注释定义元数据：\n'
            '// @name 书源名称\n'
            '// @url https://www.example.com\n'
            '// @searchUrl /search?q={{key}}&p={{page}}\n\n'
            '// 函数参数由框架自动注入：\n'
            '//   search(key, page, result)  result=搜索页HTML\n'
            '//   explore(baseUrl, result)   result=发现页HTML\n'
            '//   bookInfo/toc/content(result)\n\n'
            '// 可用API: select/selectFirst/getAttr\n'
            '//         console.log(), CryptoJS, JSON.parse/stringify\n'
            'function search(key, page, result) {\n'
            '  var html = result;\n'
            '  return [];\n'
            '}',
        hintStyle: TextStyle(color: Color(0xFF6A9955)),
      ),
      cursorColor: const Color(0xFFAEAFAD),
    );
  }

  void _formatCode() {
    // 仅做安全的基础格式化：统一缩进并保留块结构
    // 不做激进重排，避免破坏多行字符串和正则
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
      // 计算闭合括号减缩进
      final closingCount = RegExp(r'^[}\])]').allMatches(trimmed).length;
      if (closingCount > 0) {
        indent = (indent - closingCount).clamp(0, 100);
      }
      formatted.add('  ' * indent + trimmed);
      // 计算开括号加缩进（行尾的 { [ ( ）
      final openingCount = RegExp(r'[{\[(]\s*$').allMatches(trimmed).length;
      if (openingCount > 0) {
        indent = (indent + openingCount).clamp(0, 100);
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
      child: Markdown(
        data: content,
        padding: EdgeInsets.zero,
      ),
    );
  }
}
