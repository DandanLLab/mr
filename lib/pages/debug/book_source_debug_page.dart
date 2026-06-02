import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../services/storage_service.dart';
import '../../services/source_engine/source_engine.dart';
import '../../services/source_engine/web_proxy.dart';

/// 书源调试页面
class BookSourceDebugPage extends StatefulWidget {
  final String? sourceUrl;

  const BookSourceDebugPage({super.key, this.sourceUrl});

  @override
  State<BookSourceDebugPage> createState() => _BookSourceDebugPageState();
}

class _BookSourceDebugPageState extends State<BookSourceDebugPage> {
  // 书源
  BookSource? _source;
  WebBook? _webBook;

  // 搜索框
  final TextEditingController _searchController = TextEditingController();

  // 调试输出
  final List<String> _debugLogs = [];
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;

  // 帮助面板是否显示
  bool _showHelp = true;

  // 缓存的源码
  String _searchSrc = '';
  String _exploreSrc = '';
  String _bookSrc = '';
  String _tocSrc = '';
  String _contentSrc = '';

  // 帮助按钮的默认值
  String _textMy = '我的';
  String _textXt = '系统';
  String _textFx = '系统::http://xxx';
  String _textInfo = 'https://m.qidian.com/book/1015609210';

  @override
  void initState() {
    super.initState();
    _loadSource();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSource() async {
    if (widget.sourceUrl != null) {
      final data = StorageService.instance.getBookSource(widget.sourceUrl!);
      if (data != null) {
        _source = BookSource.fromJson(data);
        _webBook = WebBook(_source!);

        // 设置校验关键字
        if (_source!.ruleSearch?.checkKeyWord != null &&
            _source!.ruleSearch!.checkKeyWord!.isNotEmpty) {
          _textMy = _source!.ruleSearch!.checkKeyWord!;
        }

        // 设置发现URL
        if (_source!.exploreUrl != null && _source!.exploreUrl!.isNotEmpty) {
          _textFx = '发现::${_source!.exploreUrl!.split('::').first}';
        }

        setState(() {});
      }
    }
  }

  void _addLog(String message) {
    setState(() {
      _debugLogs.add(message);
    });
    // 滚动到底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearLogs() {
    setState(() {
      _debugLogs.clear();
    });
  }

  Future<void> _startDebug(String key) async {
    if (_source == null || _webBook == null) {
      _addLog('错误: 未获取到书源');
      return;
    }

    // 检查代理服务（仅Web端）
    if (kIsWeb) {
      _addLog('检测到Web平台运行...');
      _addLog('注意: Web端需要启动CORS代理服务');
      _addLog('请运行: node tools/cors-proxy.js');
      _addLog('---');
    }

    _clearLogs();
    setState(() {
      _isLoading = true;
      _showHelp = false;
    });

    try {
      // 判断调试类型
      if (key.startsWith('++')) {
        // 调试目录页
        final url = key.substring(2);
        await _debugToc(url);
      } else if (key.startsWith('--')) {
        // 调试正文页
        final url = key.substring(2);
        await _debugContent(url);
      } else if (key.contains('::')) {
        // 调试发现
        await _debugExplore(key);
      } else if (key.startsWith('http')) {
        // 调试详情页
        await _debugBookInfo(key);
      } else {
        // 调试搜索
        await _debugSearch(key);
      }
    } catch (e, stackTrace) {
      _addLog('调试出错: $e');
      _addLog('堆栈: $stackTrace');
      
      // 如果是Web端网络错误，给出提示
      if (kIsWeb && e.toString().contains('XMLHttpRequest')) {
        _addLog('');
        _addLog('提示: 请确保已启动CORS代理服务');
        _addLog('运行命令: node tools/cors-proxy.js');
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _debugSearch(String keyword) async {
    _addLog('开始调试搜索...');
    _addLog('书源: ${_source!.bookSourceName}');
    _addLog('搜索地址: ${_source!.searchUrl}');
    _addLog('关键字: $keyword');
    _addLog('---');

    try {
      // 检查搜索地址
      if (_source!.searchUrl == null || _source!.searchUrl!.isEmpty) {
        _addLog('错误: 书源未配置搜索地址');
        return;
      }

      // 检查搜索规则
      final searchRule = _source!.ruleSearch;
      if (searchRule == null) {
        _addLog('错误: 书源未配置搜索规则');
        return;
      }

      _addLog('搜索规则:');
      _addLog('  书籍列表: ${searchRule.bookList}');
      _addLog('  书名: ${searchRule.name}');
      _addLog('  作者: ${searchRule.author}');
      _addLog('---');

      final results = await _webBook!.searchBook(keyword);

      // 缓存源码（原始 HTML）
      _searchSrc = _webBook!.lastSearchHtml ?? '';

      _addLog('搜索结果: ${results.length} 条');
      _addLog('---');

      if (results.isEmpty) {
        _addLog('提示: 未找到结果，请检查规则是否正确');
        return;
      }

      for (int i = 0; i < results.length && i < 5; i++) {
        final book = results[i];
        _addLog('[${i + 1}] ${book['name'] ?? ''}');
        _addLog('    作者: ${book['author'] ?? ''}');
        _addLog('    分类: ${book['kind'] ?? ''}');
        _addLog('    最新: ${book['lastChapter'] ?? ''}');
        _addLog('    封面: ${book['coverUrl'] ?? ''}');
        _addLog('    链接: ${book['bookUrl'] ?? ''}');
        _addLog('');
      }

      if (results.isNotEmpty) {
        _textInfo = results.first['bookUrl'] ?? '';
        _addLog('提示: 点击"调试详情页"可继续调试第一本书');
      }
    } catch (e, stackTrace) {
      _addLog('搜索失败: $e');
      _addLog('堆栈: $stackTrace');
    }
  }

  Future<void> _debugExplore(String key) async {
    _addLog('开始调试发现...');
    _addLog('书源: ${_source!.bookSourceName}');

    final parts = key.split('::');
    final title = parts.isNotEmpty ? parts.first : '';
    final url = parts.length > 1 ? parts.last : '';

    _addLog('发现分类: $title');
    _addLog('发现URL: $url');
    _addLog('---');

    try {
      final results = await _webBook!.exploreBook(url);

      // 缓存源码（原始 HTML）
      _exploreSrc = _webBook!.lastExploreHtml ?? '';

      _addLog('发现结果: ${results.length} 条');
      _addLog('---');

      for (int i = 0; i < results.length && i < 5; i++) {
        final book = results[i];
        _addLog('[${i + 1}] ${book['name'] ?? ''}');
        _addLog('    作者: ${book['author'] ?? ''}');
        _addLog('    链接: ${book['bookUrl'] ?? ''}');
        _addLog('');
      }
    } catch (e) {
      _addLog('发现失败: $e');
    }
  }

  Future<void> _debugBookInfo(String url) async {
    _addLog('开始调试详情页...');
    _addLog('书源: ${_source!.bookSourceName}');
    _addLog('详情URL: $url');
    _addLog('---');

    try {
      final bookInfo = await _webBook!.getBookInfo(url);

      if (bookInfo == null) {
        _addLog('获取详情失败: 返回为空');
        return;
      }

      // 缓存源码（原始 HTML）
      _bookSrc = _webBook!.lastBookInfoHtml ?? '';

      _addLog('书名: ${bookInfo.name}');
      _addLog('作者: ${bookInfo.author}');
      _addLog('分类: ${bookInfo.kind ?? ''}');
      _addLog('字数: ${bookInfo.wordCount ?? ''}');
      _addLog('最新章节: ${bookInfo.lastChapter ?? ''}');
      final introText = bookInfo.intro;
      if (introText != null && introText.isNotEmpty) {
        _addLog('简介: ${introText.length > 100 ? '${introText.substring(0, 100)}...' : introText}');
      }
      _addLog('封面: ${bookInfo.coverUrl}');
      _addLog('目录链接: ${bookInfo.tocUrl ?? ''}');
      _addLog('');

      if (bookInfo.tocUrl != null && bookInfo.tocUrl!.isNotEmpty) {
        _addLog('提示: 点击"调试目录页"可继续调试');
      }
    } catch (e) {
      _addLog('获取详情失败: $e');
    }
  }

  Future<void> _debugToc(String url) async {
    _addLog('开始调试目录页...');
    _addLog('书源: ${_source!.bookSourceName}');
    _addLog('目录URL: $url');
    _addLog('---');

    try {
      final chapters = await _webBook!.getChapterList(url);

      // 缓存源码（原始 HTML）
      _tocSrc = _webBook!.lastTocHtml ?? '';

      _addLog('章节总数: ${chapters.length}');
      _addLog('---');

      // 显示前10章
      for (int i = 0; i < chapters.length && i < 10; i++) {
        final chapter = chapters[i];
        _addLog('[${chapter.index + 1}] ${chapter.title}');
        _addLog('    URL: ${chapter.url}');
      }

      if (chapters.length > 10) {
        _addLog('...');
        _addLog('(还有 ${chapters.length - 10} 章)');
      }

      if (chapters.isNotEmpty) {
        _addLog('');
        _addLog('提示: 点击"调试正文页"可调试第一章');
      }
    } catch (e) {
      _addLog('获取目录失败: $e');
    }
  }

  Future<void> _debugContent(String url) async {
    _addLog('开始调试正文页...');
    _addLog('书源: ${_source!.bookSourceName}');
    _addLog('正文URL: $url');
    _addLog('---');

    try {
      final content = await _webBook!.getContent(url);

      // 缓存源码（原始 HTML）
      _contentSrc = _webBook!.lastContentHtml ?? '';

      if (content != null && content.isNotEmpty) {
        _addLog('正文长度: ${content.length} 字符');
        _addLog('---');
        _addLog('正文预览:');
        _addLog(content.length > 500 ? '${content.substring(0, 500)}...' : content);
      } else {
        _addLog('正文为空');
      }
    } catch (e, stackTrace) {
      _addLog('获取正文失败: $e');
      _addLog('堆栈: $stackTrace');
    }
  }

  void _showSourceDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(
              content.isEmpty ? '暂无内容' : content,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制到剪贴板')),
              );
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('调试帮助'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('调试搜索：', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('输入搜索关键字，如"我的"、"斗破苍穹"'),
              SizedBox(height: 16),
              Text('调试发现：', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('输入"分类名::发现URL"格式'),
              SizedBox(height: 16),
              Text('调试详情页：', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('输入书籍详情页URL'),
              SizedBox(height: 16),
              Text('调试目录页：', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('输入"++"前缀加目录页URL'),
              Text('例如: ++https://example.com/book/123'),
              SizedBox(height: 16),
              Text('调试正文页：', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('输入"--"前缀加正文页URL'),
              Text('例如: --https://example.com/chapter/123/1'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_source?.bookSourceName ?? '调试书源'),
        actions: [
          // 扫描二维码
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () {
              // TODO: 扫描二维码
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('扫描二维码功能开发中')),
              );
            },
            tooltip: '扫描二维码',
          ),
          // 更多菜单
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'search_src':
                  _showSourceDialog('搜索源码', _searchSrc);
                  break;
                case 'book_src':
                  _showSourceDialog('书籍源码', _bookSrc);
                  break;
                case 'toc_src':
                  _showSourceDialog('目录源码', _tocSrc);
                  break;
                case 'content_src':
                  _showSourceDialog('正文源码', _contentSrc);
                  break;
                case 'refresh_explore':
                  _loadSource();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已刷新发现')),
                  );
                  break;
                case 'help':
                  _showHelpDialog();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'search_src',
                child: ListTile(
                  leading: Icon(Icons.search),
                  title: Text('搜索源码'),
                ),
              ),
              const PopupMenuItem(
                value: 'book_src',
                child: ListTile(
                  leading: Icon(Icons.book),
                  title: Text('书籍源码'),
                ),
              ),
              const PopupMenuItem(
                value: 'toc_src',
                child: ListTile(
                  leading: Icon(Icons.list),
                  title: Text('目录源码'),
                ),
              ),
              const PopupMenuItem(
                value: 'content_src',
                child: ListTile(
                  leading: Icon(Icons.article),
                  title: Text('正文源码'),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'refresh_explore',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('刷新发现'),
                ),
              ),
              const PopupMenuItem(
                value: 'help',
                child: ListTile(
                  leading: Icon(Icons.help),
                  title: Text('帮助'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '输入关键字、URL或调试命令',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _isLoading || _searchController.text.isEmpty
                          ? null
                          : () => _startDebug(_searchController.text),
                    ),
                  ],
                ),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: _isLoading ? null : _startDebug,
              onChanged: (value) => setState(() {}),
            ),
          ),
          // 帮助面板
          if (_showHelp) _buildHelpPanel(),
          // 加载指示器
          if (_isLoading)
            const LinearProgressIndicator(),
          // 调试输出
          Expanded(
            child: _debugLogs.isEmpty
                ? Center(
                    child: Text(
                      '等待调试...',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _debugLogs.length,
                    itemBuilder: (context, index) {
                      final log = _debugLogs[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: SelectableText(
                          log,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Web端代理服务提示
            if (kIsWeb) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.warning, color: Colors.orange, size: 20),
                        SizedBox(width: 8),
                        Text('Web端需要启动代理服务', style: TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('在项目根目录运行以下命令：'),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const SelectableText(
                        'node tools/cors-proxy.js',
                        style: TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            // 调试搜索
            const Text(
              '调试搜索>>输入关键字，如：',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                _buildHelpChip(_textMy, () {
                  _searchController.text = _textMy;
                  _startDebug(_textMy);
                }),
                _buildHelpChip(_textXt, () {
                  _searchController.text = _textXt;
                  _startDebug(_textXt);
                }),
              ],
            ),
            const SizedBox(height: 12),
            // 调试发现
            const Text(
              '调试发现>>输入发现URL，如：',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            _buildHelpChip(_textFx, () {
              _searchController.text = _textFx;
              _startDebug(_textFx);
            }),
            const SizedBox(height: 12),
            // 调试详情页
            const Text(
              '调试详情页>>输入详情页URL，如：',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            _buildHelpChip(_textInfo, () {
              _searchController.text = _textInfo;
              _startDebug(_textInfo);
            }),
            const SizedBox(height: 12),
            // 调试目录页
            const Text(
              '调试目录页>>输入目录页URL，如：',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            _buildHelpChip('++https://www.zhaishuyuan.com/read/30394', () {
              _searchController.text = '++https://www.zhaishuyuan.com/read/30394';
            }),
            const SizedBox(height: 12),
            // 调试正文页
            const Text(
              '调试正文页>>输入正文页URL，如：',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 4),
            _buildHelpChip('--https://www.zhaishuyuan.com/chapter/30394/20940996', () {
              _searchController.text = '--https://www.zhaishuyuan.com/chapter/30394/20940996';
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildHelpChip(String label, VoidCallback onTap) {
    return ActionChip(
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onPressed: onTap,
    );
  }
}
