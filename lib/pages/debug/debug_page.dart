import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/debug_service.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../services/source_engine/source_engine.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  final TextEditingController _jsonController = TextEditingController();
  final TextEditingController _keywordController = TextEditingController(text: '斗破苍穹');
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _ruleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _jsController = TextEditingController();
  
  String _output = '';
  bool _isLoading = false;
  int _selectedTab = 0;
  bool _serviceRunning = false;

  @override
  void initState() {
    super.initState();
    _checkServiceStatus();
  }

  void _checkServiceStatus() {
    setState(() {
      _serviceRunning = DebugService.instance.isRunning;
    });
  }

  Future<void> _toggleService() async {
    if (_serviceRunning) {
      await DebugService.instance.stop();
    } else {
      await DebugService.instance.start(port: 9527);
    }
    _checkServiceStatus();
  }

  Future<void> _testSearch() async {
    if (_jsonController.text.isEmpty) {
      _showError('请输入书源JSON');
      return;
    }

    setState(() {
      _isLoading = true;
      _output = '正在测试搜索...';
    });

    try {
      final sourceJson = json.decode(_jsonController.text) as Map<String, dynamic>;
      final source = BookSource.fromJson(sourceJson);
      final webBook = WebBook(source);
      final results = await webBook.searchBook(_keywordController.text);

      setState(() {
        _output = _formatOutput({
          'success': true,
          'keyword': _keywordController.text,
          'count': results.length,
          'results': results.take(5).toList(),
        });
      });
    } catch (e) {
      _showError('搜索测试失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _testExplore() async {
    if (_jsonController.text.isEmpty) {
      _showError('请输入书源JSON');
      return;
    }

    setState(() {
      _isLoading = true;
      _output = '正在测试发现...';
    });

    try {
      final sourceJson = json.decode(_jsonController.text) as Map<String, dynamic>;
      final source = BookSource.fromJson(sourceJson);
      final webBook = WebBook(source);
      final results = await webBook.exploreBook(_urlController.text.isEmpty ? '' : _urlController.text);

      setState(() {
        _output = _formatOutput({
          'success': true,
          'count': results.length,
          'results': results.take(5).toList(),
        });
      });
    } catch (e) {
      _showError('发现测试失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _testBookInfo() async {
    if (_jsonController.text.isEmpty || _urlController.text.isEmpty) {
      _showError('请输入书源JSON和书籍URL');
      return;
    }

    setState(() {
      _isLoading = true;
      _output = '正在测试书籍信息...';
    });

    try {
      final sourceJson = json.decode(_jsonController.text) as Map<String, dynamic>;
      final source = BookSource.fromJson(sourceJson);
      final webBook = WebBook(source);
      final bookInfo = await webBook.getBookInfo(_urlController.text);

      setState(() {
        _output = _formatOutput({
          'success': true,
          'bookInfo': bookInfo,
        });
      });
    } catch (e) {
      _showError('书籍信息测试失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _testToc() async {
    if (_jsonController.text.isEmpty || _urlController.text.isEmpty) {
      _showError('请输入书源JSON和书籍URL');
      return;
    }

    setState(() {
      _isLoading = true;
      _output = '正在测试目录...';
    });

    try {
      final sourceJson = json.decode(_jsonController.text) as Map<String, dynamic>;
      final source = BookSource.fromJson(sourceJson);
      final webBook = WebBook(source);
      final chapters = await webBook.getChapterList(_urlController.text);

      setState(() {
        _output = _formatOutput({
          'success': true,
          'count': chapters.length,
          'chapters': chapters.take(10).toList(),
        });
      });
    } catch (e) {
      _showError('目录测试失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _testContent() async {
    if (_jsonController.text.isEmpty || _urlController.text.isEmpty) {
      _showError('请输入书源JSON和章节URL');
      return;
    }

    setState(() {
      _isLoading = true;
      _output = '正在测试正文...';
    });

    try {
      final sourceJson = json.decode(_jsonController.text) as Map<String, dynamic>;
      final source = BookSource.fromJson(sourceJson);
      final webBook = WebBook(source);
      final chapter = Chapter(
        id: 'test',
        bookId: 'test',
        title: '测试章节',
        index: 0,
        url: _urlController.text,
      );
      final content = await webBook.getContent(_urlController.text);

      setState(() {
        _output = _formatOutput({
          'success': true,
          'length': content?.length ?? 0,
          'preview': content != null && content.length > 500 ? '${content.substring(0, 500)}...' : content ?? '',
        });
      });
    } catch (e) {
      _showError('正文测试失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _testRule() async {
    if (_ruleController.text.isEmpty || _contentController.text.isEmpty) {
      _showError('请输入规则和内容');
      return;
    }

    setState(() {
      _isLoading = true;
      _output = '正在测试规则...';
    });

    try {
      final analyzer = AnalyzeRule();
      analyzer.setContent(_contentController.text);
      final result = analyzer.getString(_ruleController.text);

      setState(() {
        _output = _formatOutput({
          'success': true,
          'rule': _ruleController.text,
          'result': result,
        });
      });
    } catch (e) {
      _showError('规则测试失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _executeJs() async {
    if (_jsController.text.isEmpty) {
      _showError('请输入JS代码');
      return;
    }

    setState(() {
      _isLoading = true;
      _output = '正在执行JS...';
    });

    try {
      final result = await JsEngine.instance.processJsRule('', _jsController.text);

      setState(() {
        _output = _formatOutput({
          'success': true,
          'result': result,
        });
      });
    } catch (e) {
      _showError('JS执行失败: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    setState(() {
      _output = _formatOutput({
        'success': false,
        'error': message,
      });
    });
  }

  String _formatOutput(Map<String, dynamic> data) {
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  void _copyOutput() {
    Clipboard.setData(ClipboardData(text: _output));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  void _loadTemplate() {
    final template = {
      'bookSourceUrl': 'https://example.com',
      'bookSourceName': '示例书源',
      'bookSourceType': 0,
      'enabled': true,
      'searchUrl': 'https://example.com/search?key={{key}}',
      'ruleSearch': {
        'bookList': 'class.book-list@tag.li',
        'name': 'tag.h3@text',
        'author': 'tag.p@text##作者：',
        'bookUrl': 'tag.a@href',
      },
      'ruleBookInfo': {
        'name': 'tag.h1@text',
        'author': 'class.author@text',
        'intro': 'class.intro@text',
      },
      'ruleToc': {
        'chapterList': 'class.chapter-list@tag.li',
        'chapterName': 'tag.a@text',
        'chapterUrl': 'tag.a@href',
      },
      'ruleContent': {
        'content': 'class.content@html',
      },
    };

    _jsonController.text = _formatOutput(template);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('调试工具'),
        actions: [
          IconButton(
            icon: Icon(_serviceRunning ? Icons.stop : Icons.play_arrow),
            onPressed: _toggleService,
            tooltip: _serviceRunning ? '停止服务' : '启动服务',
          ),
          IconButton(
            icon: const Icon(Icons.content_copy),
            onPressed: _output.isEmpty ? null : _copyOutput,
            tooltip: '复制输出',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_serviceRunning)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.green.withOpacity(0.1),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    '调试服务运行中 - WebSocket: ws://localhost:${DebugService.instance.port}',
                    style: const TextStyle(fontSize: 12, color: Colors.green),
                  ),
                ],
              ),
            ),
          _buildTabBar(),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: _buildInputPanel(),
                ),
                const VerticalDivider(),
                Expanded(
                  flex: 1,
                  child: _buildOutputPanel(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          _buildTab('书源测试', 0),
          _buildTab('规则测试', 1),
          _buildTab('JS执行', 2),
        ],
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final isSelected = _selectedTab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_selectedTab == 0) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('书源JSON', style: Theme.of(context).textTheme.titleMedium),
                TextButton(
                  onPressed: _loadTemplate,
                  child: const Text('加载模板'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _jsonController,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: '粘贴书源JSON...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _keywordController,
              decoration: const InputDecoration(
                labelText: '搜索关键词',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: '书籍/章节URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _isLoading ? null : _testSearch,
                  child: const Text('测试搜索'),
                ),
                ElevatedButton(
                  onPressed: _isLoading ? null : _testExplore,
                  child: const Text('测试发现'),
                ),
                ElevatedButton(
                  onPressed: _isLoading ? null : _testBookInfo,
                  child: const Text('测试书籍信息'),
                ),
                ElevatedButton(
                  onPressed: _isLoading ? null : _testToc,
                  child: const Text('测试目录'),
                ),
                ElevatedButton(
                  onPressed: _isLoading ? null : _testContent,
                  child: const Text('测试正文'),
                ),
              ],
            ),
          ],
          if (_selectedTab == 1) ...[
            Text('规则测试', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _ruleController,
              decoration: const InputDecoration(
                labelText: '规则',
                hintText: '例如: class.book-list@tag.li',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contentController,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'HTML/JSON内容',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _testRule,
              child: const Text('测试规则'),
            ),
          ],
          if (_selectedTab == 2) ...[
            Text('JS执行', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _jsController,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'JavaScript代码',
                hintText: '输入JS代码...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _executeJs,
              child: const Text('执行JS'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutputPanel() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            color: Theme.of(context).colorScheme.surface,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('输出', style: Theme.of(context).textTheme.titleSmall),
                if (_isLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _output.isEmpty ? '等待输出...' : _output,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
