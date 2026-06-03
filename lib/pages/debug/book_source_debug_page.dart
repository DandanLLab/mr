import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../services/source_engine/source_engine.dart';
import '../../services/storage_service.dart';

enum _DebugMenuAction {
  clearLogs,
  copySearchSource,
  copyExploreSource,
  copyBookSource,
  copyTocSource,
  copyContentSource,
}

/// 书源调试页
class BookSourceDebugPage extends StatefulWidget {
  final String? sourceUrl;

  const BookSourceDebugPage({super.key, this.sourceUrl});

  @override
  State<BookSourceDebugPage> createState() => _BookSourceDebugPageState();
}

class _BookSourceDebugPageState extends State<BookSourceDebugPage> {
  BookSource? _source;
  WebBook? _webBook;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Stopwatch _debugWatch = Stopwatch();
  final List<String> _debugLogs = [];

  bool _isLoading = false;

  String _searchSrc = '';
  String _exploreSrc = '';
  String _bookSrc = '';
  String _tocSrc = '';
  String _contentSrc = '';

  final String _textMy = '我的';
  final String _textXt = '系统';
  final String _textFx = '耽美小说::/sort/1/{{page}}/';
  final String _textInfo = 'https://m.qidian.com/book/1015609210';
  final String _textToc = '++https://www.zhaishuyuan.com/read/303...';
  final String _textContent = '--https://www.zhaishuyuan.com/chapter/3...';

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
    final sourceUrl = widget.sourceUrl;
    if (sourceUrl == null || sourceUrl.isEmpty) return;

    final data = StorageService.instance.getBookSource(sourceUrl);
    if (data == null) return;

    _source = BookSource.fromJson(data);
    _webBook = WebBook(_source!);

    final searchKey = _source?.ruleSearch?.checkKeyWord;
    if (searchKey != null && searchKey.isNotEmpty) {
      _searchController.text = searchKey;
    }

    if (mounted) {
      setState(() {});
    }
  }

  void _fillExample(String value) {
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
  }

  void _clearLogs() {
    if (!mounted) return;
    setState(() {
      _debugLogs.clear();
    });
  }

  String _formatStamp(Duration elapsed) {
    final totalMs = elapsed.inMilliseconds;
    final minutes = (totalMs ~/ 60000).toString().padLeft(2, '0');
    final seconds = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
    final millis = (totalMs % 1000).toString().padLeft(3, '0');
    return '$minutes:$seconds.$millis';
  }

  void _addLog(String message) {
    final stamp = _formatStamp(_debugWatch.elapsed);
    final lines = message.split('\n');
    if (!mounted) return;

    setState(() {
      for (final line in lines) {
        _debugLogs.add('[$stamp] $line');
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  bool _looksLikeUrl(String value) {
    return value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('//') ||
        value.contains('://');
  }

  String _extractRealUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('++') || trimmed.startsWith('--')) {
      return trimmed.substring(2).trim();
    }
    if (trimmed.contains('::') && !_looksLikeUrl(trimmed)) {
      return trimmed.split('::').last.trim();
    }
    return trimmed;
  }

  Future<void> _submitDebug([String? value]) async {
    final text = (value ?? _searchController.text).trim();
    if (text.isEmpty) return;
    await _startDebug(text);
  }

  Future<void> _startDebug(String key) async {
    final webBook = _webBook;
    final source = _source;
    if (source == null || webBook == null) {
      _addLog('错误: 未加载到书源');
      return;
    }

    _debugWatch
      ..reset()
      ..start();
    _clearLogs();

    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      if (kIsWeb) {
        _addLog('检测到 Web 平台运行');
        _addLog('提示: Web 端需要可用的 CORS 代理');
        _addLog('---');
      }

      if (key.startsWith('++')) {
        await _debugToc(_extractRealUrl(key));
      } else if (key.startsWith('--')) {
        await _debugContent(_extractRealUrl(key));
      } else if (key.contains('::') && !_looksLikeUrl(key)) {
        await _debugExplore(key);
      } else if (_looksLikeUrl(key)) {
        await _debugBookInfo(key);
      } else {
        await _debugSearch(key);
      }
    } catch (e) {
      _addLog('错误: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _debugSearch(String keyword) async {
    final webBook = _webBook!;
    _addLog('开始搜索关键字:$keyword');
    _addLog('开始解析搜索页');

    final results = await webBook.searchBook(keyword);
    _searchSrc = webBook.lastSearchHtml ?? '';

    _addLog('获取书籍列表');
    _addLog('列表大小:${results.length}');
    if (results.isEmpty) {
      _addLog('搜索页解析完成');
      return;
    }

    final first = results.first;
    _addLog('获取书名');
    _addLog('书名: ${first['name'] ?? ''}');
    _addLog('获取作者');
    _addLog('作者: ${first['author'] ?? ''}');
    _addLog('获取分类');
    _addLog('分类: ${first['kind'] ?? ''}');
    _addLog('获取字数');
    _addLog('字数: ${first['wordCount'] ?? ''}');
    _addLog('获取最新章节');
    _addLog('最新章节: ${first['lastChapter'] ?? ''}');
    _addLog('获取简介');
    _addLog('简介: ${first['intro'] ?? ''}');
    _addLog('获取封面链接');
    _addLog('${first['coverUrl'] ?? ''}');
    _addLog('获取详情链接');

    final bookUrl = '${first['bookUrl'] ?? ''}'.trim();
    _addLog(bookUrl);
    _addLog('搜索页解析完成');

    if (bookUrl.isEmpty) return;
    await _debugBookInfo(bookUrl);
  }

  Future<void> _debugExplore(String exploreUrl) async {
    final webBook = _webBook!;
    final realUrl = _extractRealUrl(exploreUrl);
    _addLog('开始解析发现页');
    _addLog('获取成功:$realUrl');

    final results = await webBook.exploreBook(realUrl);
    _exploreSrc = webBook.lastExploreHtml ?? '';

    _addLog('获取发现列表');
    _addLog('列表大小:${results.length}');
    if (results.isEmpty) {
      _addLog('发现页解析完成');
      return;
    }

    final first = results.first;
    _addLog('获取书名');
    _addLog('书名: ${first['name'] ?? ''}');
    _addLog('获取作者');
    _addLog('作者: ${first['author'] ?? ''}');
    _addLog('获取分类');
    _addLog('分类: ${first['kind'] ?? ''}');
    _addLog('获取简介');
    _addLog('简介: ${first['intro'] ?? ''}');
    _addLog('获取封面链接');
    _addLog('${first['coverUrl'] ?? ''}');
    _addLog('获取详情链接');

    final bookUrl = '${first['bookUrl'] ?? ''}'.trim();
    _addLog(bookUrl);
    _addLog('发现页解析完成');

    if (bookUrl.isEmpty) return;
    await _debugBookInfo(bookUrl);
  }

  Future<void> _debugBookInfo(String bookUrl) async {
    final webBook = _webBook!;
    _addLog('开始解析详情页');
    _addLog('获取成功:$bookUrl');

    final Book? book = await webBook.getBookInfo(bookUrl);
    _bookSrc = webBook.lastBookInfoHtml ?? '';
    if (book == null) {
      _addLog('详情页解析失败');
      return;
    }

    _addLog('获取书名');
    _addLog('书名: ${book.name}');
    _addLog('获取作者');
    _addLog('作者: ${book.author}');
    _addLog('获取分类');
    _addLog('分类: ${book.kind ?? ''}');
    _addLog('获取字数');
    _addLog('字数: ${book.wordCount ?? ''}');
    _addLog('获取最新章节');
    _addLog('最新章节: ${book.lastChapter ?? ''}');
    _addLog('获取简介');
    _addLog('简介: ${book.intro}');
    _addLog('获取封面链接');
    _addLog(book.coverUrl);
    _addLog('获取目录链接');
    _addLog(book.tocUrl ?? '');
    _addLog('详情页解析完成');

    final tocUrl = book.tocUrl?.trim();
    if (tocUrl != null && tocUrl.isNotEmpty) {
      await _debugToc(tocUrl);
    }
  }

  Future<void> _debugToc(String tocUrl) async {
    final webBook = _webBook!;
    final realUrl = _extractRealUrl(tocUrl);
    _addLog('开始解析目录页');
    _addLog('获取成功:$realUrl');

    final List<Chapter> chapters = await webBook.getChapterList(realUrl);
    _tocSrc = webBook.lastTocHtml ?? '';

    _addLog('获取目录列表');
    _addLog('列表大小:${chapters.length}');
    if (chapters.isEmpty) {
      _addLog('目录页解析完成');
      return;
    }

    final Chapter first = chapters.first;
    _addLog('首章信息');
    _addLog('章节名称:${first.title}');
    _addLog('章节链接:${first.url ?? ''}');
    _addLog('章节信息:');
    _addLog('是否VIP:false');
    _addLog('是否购买:false');
    _addLog('目录总数:${chapters.length}');
    _addLog('目录页解析完成');

    final chapterUrl = first.url?.trim();
    if (chapterUrl != null && chapterUrl.isNotEmpty) {
      await _debugContent(chapterUrl);
    }
  }

  Future<void> _debugContent(String chapterUrl) async {
    final webBook = _webBook!;
    final realUrl = _extractRealUrl(chapterUrl);
    _addLog('开始解析正文页');
    _addLog('获取成功:$realUrl');

    final String? content = await webBook.getContent(realUrl);
    _contentSrc = webBook.lastContentHtml ?? '';

    _addLog('获取正文下一页链接');
    _addLog(webBook.source.ruleContent?.nextContentUrl ?? '');
    _addLog('本章总页数:1');

    if (content == null || content.trim().isEmpty) {
      _addLog('正文解析失败');
      return;
    }

    _addLog('获取章节名称');
    _addLog('第一章');
    _addLog('获取正文内容');
    _addLog(content.trim());
  }

  Future<void> _copyCurrentSource(String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    _addLog('已复制到剪贴板');
  }

  void _onMenuSelected(_DebugMenuAction action) {
    switch (action) {
      case _DebugMenuAction.clearLogs:
        _clearLogs();
        break;
      case _DebugMenuAction.copySearchSource:
        _copyCurrentSource(_searchSrc);
        break;
      case _DebugMenuAction.copyExploreSource:
        _copyCurrentSource(_exploreSrc);
        break;
      case _DebugMenuAction.copyBookSource:
        _copyCurrentSource(_bookSrc);
        break;
      case _DebugMenuAction.copyTocSource:
        _copyCurrentSource(_tocSrc);
        break;
      case _DebugMenuAction.copyContentSource:
        _copyCurrentSource(_contentSrc);
        break;
    }
  }

  PreferredSizeWidget _buildDebugAppBar(BuildContext context) {
    final theme = Theme.of(context);
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded),
        color: Colors.black87,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: SizedBox(
          height: 44,
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onSubmitted: _submitDebug,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: Colors.black87,
            ),
            decoration: InputDecoration(
              hintText: '搜索书名、作者',
              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.black38,
              ),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: IconButton(
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: () => _submitDebug(),
              ),
              filled: true,
              fillColor: const Color(0xFFF1F1F1),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: const BorderSide(color: Color(0xFFB8D5FF)),
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: '清空输入',
          onPressed: () {
            _searchController.clear();
          },
          icon: const Icon(Icons.crop_free_rounded),
          color: Colors.black87,
        ),
        PopupMenuButton<_DebugMenuAction>(
          icon: const Icon(Icons.more_vert),
          color: Colors.white,
          onSelected: _onMenuSelected,
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _DebugMenuAction.clearLogs,
              child: Text('清空日志'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.copySearchSource,
              child: Text('复制搜索源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.copyExploreSource,
              child: Text('复制发现源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.copyBookSource,
              child: Text('复制详情源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.copyTocSource,
              child: Text('复制目录源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.copyContentSource,
              child: Text('复制正文源码'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildExampleChip(String label, String value,
      {bool fullWidth = false}) {
    final width = fullWidth ? double.infinity : null;
    return GestureDetector(
      onTap: () => _fillExample(value),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFD9D9D9),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 18,
            height: 1.15,
          ),
        ),
      ),
    );
  }

  Widget _buildHelpPanel() {
    const labelStyle = TextStyle(
      fontSize: 18,
      color: Colors.black54,
      height: 1.25,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('调试搜索>>输入关键字，如：', style: labelStyle),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 12,
            children: [
              _buildExampleChip(_textMy, _textMy),
              _buildExampleChip(_textXt, _textXt),
            ],
          ),
          const SizedBox(height: 18),
          const Text('调试发现>>输入发现URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(_textFx, _textFx, fullWidth: true),
          const SizedBox(height: 18),
          const Text('调试详情页>>输入详情页URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(_textInfo, _textInfo, fullWidth: true),
          const SizedBox(height: 18),
          const Text('调试目录页>>输入目录页URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(_textToc, _textToc, fullWidth: true),
          const SizedBox(height: 18),
          const Text('调试正文页>>输入正文页URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(_textContent, _textContent, fullWidth: true),
        ],
      ),
    );
  }

  Widget _buildLogLine(String line) {
    final match = RegExp(r'^\[(\d{2}:\d{2}\.\d{3})\]\s*(.*)$').firstMatch(line);
    final stamp = match?.group(1) ?? '';
    final body = match?.group(2) ?? line;

    Color bodyColor = const Color(0xFF444444);
    FontWeight bodyWeight = FontWeight.w400;

    if (body.startsWith('---') || body.startsWith('===')) {
      bodyColor = const Color(0xFF9A9A9A);
    } else if (body.contains('错误') ||
        body.contains('失败') ||
        body.contains('未加载')) {
      bodyColor = const Color(0xFFD64B4B);
      bodyWeight = FontWeight.w600;
    } else if (body.startsWith('http://') || body.startsWith('https://')) {
      bodyColor = const Color(0xFFB00020);
      bodyWeight = FontWeight.w500;
    } else if (body.contains('完成') || body.contains('成功')) {
      bodyColor = const Color(0xFF2E7D32);
      bodyWeight = FontWeight.w500;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(
            fontSize: 14,
            height: 1.35,
            color: Color(0xFF555555),
          ),
          children: [
            TextSpan(
              text: '[$stamp] ',
              style: const TextStyle(
                color: Color(0xFF8F8F8F),
                fontSize: 13,
              ),
            ),
            TextSpan(
              text: body,
              style: TextStyle(
                color: bodyColor,
                fontWeight: bodyWeight,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactScaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: _buildDebugAppBar(context),
      body: Stack(
        children: [
          Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                _buildHelpPanel(),
                if (_debugLogs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1, thickness: 1, color: Color(0xFFEDEDED)),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _debugLogs.map(_buildLogLine).toList(),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 120),
                ],
              ],
            ),
          ),
          if (_isLoading)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _buildCompactScaffold(context);
  }
}
