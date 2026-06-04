import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../services/app_logger.dart';
import '../../services/source_engine/source_engine.dart';
import '../../services/storage_service.dart';

/// 调试状态码
enum DebugState {
  searchSrc,    // 10: 搜索源码
  exploreSrc,   // 探索源码
  bookSrc,      // 20: 详情源码
  tocSrc,       // 30: 目录源码
  contentSrc,   // 40: 正文源码
  error,        // -1: 错误
  success,      // 1000: 成功完成
}

/// 调试菜单操作
enum _DebugMenuAction {
  searchSource,
  bookSource,
  tocSource,
  contentSource,
  refreshExploreKinds,
  help,
}

class _ExploreKindItem {
  final String title;
  final String url;

  const _ExploreKindItem(this.title, this.url);
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
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final Stopwatch _debugWatch = Stopwatch();
  final List<String> _debugLogs = [];

  bool _isLoading = false;
  bool _showHelp = true;
  bool _debugCancelled = false;
  int _currentTab = 0; // 0: 调试, 1: 日志

  // AppLogger 订阅
  StreamSubscription<LogEntry>? _logSubscription;
  final List<LogEntry> _appLogs = [];
  LogLevel _logFilterLevel = LogLevel.verbose;
  LogCategory? _logFilterCategory;

  // 源码存储
  String _searchSrc = '';
  String _exploreSrc = '';
  String _bookSrc = '';
  String _tocSrc = '';
  String _contentSrc = '';

  // 发现分类缓存
  List<_ExploreKindItem> _exploreKinds = [];
  int _currentExploreIndex = 0;

  // 示例文本
  String _textMy = '我的';
  String _textXt = '系统';
  String _textFx = '系统::http://xxx';
  String _textInfo = 'https://m.qidian.com/book/1015609210';
  String _textToc = '++https://www.zhaishuyuan.com/read/303...';
  String _textContent = '--https://www.zhaishuyuan.com/chapter/3...';

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(() {
      if (!mounted) return;
      setState(() {
        _showHelp = _searchFocusNode.hasFocus;
      });
    });
    _loadSource();

    // 订阅 AppLogger 日志流
    _logSubscription = AppLogger.instance.stream.listen((entry) {
      if (!mounted) return;
      setState(() {
        _appLogs.add(entry);
        if (_appLogs.length > 500) {
          _appLogs.removeRange(0, _appLogs.length - 500);
        }
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSource() async {
    final sourceUrl = widget.sourceUrl;
    debugPrint('=== 调试页面加载书源 ===');
    debugPrint('sourceUrl: $sourceUrl');
    
    if (sourceUrl == null || sourceUrl.isEmpty) {
      debugPrint('sourceUrl 为空，无法加载书源');
      if (mounted) {
        setState(() {
          _showHelp = true;
        });
      }
      return;
    }

    final data = StorageService.instance.getBookSource(sourceUrl);
    debugPrint('书源数据: ${data != null ? "找到" : "未找到"}');
    
    if (data == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('未找到书源: $sourceUrl')),
        );
      }
      return;
    }

    try {
      _source = BookSource.fromJson(data);
      _webBook = WebBook(_source!);
      debugPrint('书源加载成功: ${_source!.bookSourceName}');
    } catch (e) {
      debugPrint('书源解析失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('书源解析失败: $e')),
        );
      }
      return;
    }

    final searchKey = _source?.ruleSearch?.checkKeyWord;
    if (searchKey != null && searchKey.isNotEmpty) {
      _searchController.text = searchKey;
      _textMy = searchKey;
    }

    // 解析发现分类
    _exploreKinds = _parseExploreKinds(_source);
    if (_exploreKinds.isNotEmpty) {
      _textFx = '${_exploreKinds.first.title}::${_exploreKinds.first.url}';
    } else if (_source?.exploreUrl != null && _source!.exploreUrl!.isNotEmpty) {
      _textFx = '发现::${_source!.exploreUrl}';
    }

    if (mounted) {
      setState(() {
        _showHelp = true;
      });
    }
  }

  /// 刷新发现分类
  void _refreshExploreKinds() {
    _exploreKinds = _parseExploreKinds(_source);
    _currentExploreIndex = 0;
    if (_exploreKinds.isNotEmpty) {
      _textFx = '${_exploreKinds.first.title}::${_exploreKinds.first.url}';
    }
    if (mounted) {
      setState(() {});
    }
    _addLog('≡已刷新发现分类');
  }

  void _fillExample(String value) {
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
  }

  List<_ExploreKindItem> _parseExploreKinds(BookSource? source) {
    final exploreUrl = source?.exploreUrl?.trim();
    if (exploreUrl == null || exploreUrl.isEmpty) return const [];

    final raw = exploreUrl.startsWith('[') ? exploreUrl : exploreUrl;
    if (raw.startsWith('@js:') || raw.startsWith('<js>')) {
      return const [];
    }

    if (raw.startsWith('[')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map((e) => _ExploreKindItem(
                    '${e['title'] ?? ''}'.trim(),
                    '${e['url'] ?? ''}'.trim(),
                  ))
              .where((e) => e.title.isNotEmpty && e.url.isNotEmpty)
              .toList(growable: false);
        }
      } catch (_) {
        // fall through
      }
    }

    final items = <_ExploreKindItem>[];
    for (final line in raw.split(RegExp(r'(&&|\n)+'))) {
      final kindCfg = line.split('::');
      if (kindCfg.isEmpty) continue;
      final title = kindCfg.first.trim();
      final url = kindCfg.length > 1 ? kindCfg[1].trim() : '';
      if (title.isNotEmpty && url.isNotEmpty) {
        items.add(_ExploreKindItem(title, url));
      }
    }
    return items;
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

  /// 添加调试日志
  /// [message] 日志消息
  /// [state] 状态码：-1错误，0警告，1正常，10搜索源码，20详情源码，30目录源码，40正文源码，1000完成
  /// [sourceHtml] 源码内容（用于保存）
  void _addLog(String message, {int state = 1, String? sourceHtml}) {
    if (_debugCancelled && state > 0 && state != 1000) return;

    final stamp = _formatStamp(_debugWatch.elapsed);
    final lines = message.split('\n');

    // 根据state保存源码
    if (sourceHtml != null && sourceHtml.isNotEmpty) {
      switch (state) {
        case 10:
          _searchSrc = sourceHtml;
          break;
        case 15:
          _exploreSrc = sourceHtml;
          break;
        case 20:
          _bookSrc = sourceHtml;
          break;
        case 30:
          _tocSrc = sourceHtml;
          break;
        case 40:
          _contentSrc = sourceHtml;
          break;
      }
    }

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
    
    // 先检查书源是否存在
    final webBook = _webBook;
    final source = _source;
    if (source == null || webBook == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('未获取到书源'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    
    _searchFocusNode.unfocus();
    if (mounted) {
      setState(() {
        _showHelp = false;
      });
    }
    await _startDebug(text);
  }

  Future<void> _submitPrefixed(String prefix) async {
    final query = _searchController.text.trim();
    if (query.isEmpty || query.length <= 2) {
      _searchController.text = prefix;
      _searchController.selection =
          TextSelection.collapsed(offset: prefix.length);
      await _submitDebug(prefix);
      return;
    }

    final next = query.startsWith(prefix) ? query : '$prefix$query';
    _searchController.text = next;
    _searchController.selection =
        TextSelection.collapsed(offset: next.length);
    await _submitDebug(next);
  }

  Future<void> _startDebug(String key) async {
    final webBook = _webBook!;
    final source = _source!;

    // 重置状态
    _debugCancelled = false;
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
        _addLog('≡检测到 Web 平台运行');
        _addLog('≡提示: Web 端需要可用的 CORS 代理');
      }

      if (key.startsWith('++')) {
        _addLog('⇒开始访问目录页:${_extractRealUrl(key)}');
        await _debugToc(_extractRealUrl(key));
      } else if (key.startsWith('--')) {
        _addLog('⇒开始访问正文页:${_extractRealUrl(key)}');
        await _debugContent(_extractRealUrl(key));
      } else if (key.contains('::') && !_looksLikeUrl(key)) {
        final url = _extractRealUrl(key);
        _addLog('⇒开始访问发现页:$url');
        await _debugExplore(key);
      } else if (_looksLikeUrl(key)) {
        _addLog('⇒开始访问详情页:$key');
        await _debugBookInfo(key);
      } else {
        _addLog('⇒开始搜索关键字:$key');
        await _debugSearch(key);
      }
    } catch (e) {
      _addLog('⇒错误: $e', state: -1);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _debugSearch(String keyword) async {
    if (_debugCancelled) return;
    final webBook = _webBook!;
    _addLog('︾开始解析搜索页');

    final results = await webBook.searchBook(keyword);
    if (_debugCancelled) return;

    final searchHtml = webBook.lastSearchHtml ?? '';
    _addLog('︽搜索页解析完成', state: 10, sourceHtml: searchHtml);
    _addLog('');

    if (results.isEmpty) {
      _addLog('≡未获取到书籍', state: -1);
      return;
    }

    final first = results.first;
    _addLog('⇒获取书名');
    _addLog('${first['name'] ?? ''}');
    _addLog('⇒获取作者');
    _addLog('${first['author'] ?? ''}');
    _addLog('⇒获取分类');
    _addLog('${first['kind'] ?? ''}');
    _addLog('⇒获取字数');
    _addLog('${first['wordCount'] ?? ''}');
    _addLog('⇒获取最新章节');
    _addLog('${first['lastChapter'] ?? ''}');
    _addLog('⇒获取简介');
    _addLog('${first['intro'] ?? ''}');
    _addLog('⇒获取封面链接');
    _addLog('${first['coverUrl'] ?? ''}');
    _addLog('⇒获取详情链接');

    final bookUrl = '${first['bookUrl'] ?? ''}'.trim();
    _addLog(bookUrl);

    if (bookUrl.isEmpty) return;
    await _debugBookInfo(bookUrl);
  }

  Future<void> _debugExplore(String exploreUrl) async {
    if (_debugCancelled) return;
    final webBook = _webBook!;
    final realUrl = _extractRealUrl(exploreUrl);
    _addLog('︾开始解析发现页');

    final results = await webBook.exploreBook(realUrl);
    if (_debugCancelled) return;

    final exploreHtml = webBook.lastExploreHtml ?? '';
    _addLog('︽发现页解析完成', state: 15, sourceHtml: exploreHtml);
    _addLog('');

    if (results.isEmpty) {
      _addLog('≡未获取到书籍', state: -1);
      return;
    }

    final first = results.first;
    _addLog('⇒获取书名');
    _addLog('${first['name'] ?? ''}');
    _addLog('⇒获取作者');
    _addLog('${first['author'] ?? ''}');
    _addLog('⇒获取分类');
    _addLog('${first['kind'] ?? ''}');
    _addLog('⇒获取简介');
    _addLog('${first['intro'] ?? ''}');
    _addLog('⇒获取封面链接');
    _addLog('${first['coverUrl'] ?? ''}');
    _addLog('⇒获取详情链接');

    final bookUrl = '${first['bookUrl'] ?? ''}'.trim();
    _addLog(bookUrl);

    if (bookUrl.isEmpty) return;
    await _debugBookInfo(bookUrl);
  }

  Future<void> _debugBookInfo(String bookUrl) async {
    if (_debugCancelled) return;
    final webBook = _webBook!;
    _addLog('︾开始解析详情页');

    final Book? book = await webBook.getBookInfo(bookUrl);
    if (_debugCancelled) return;

    final bookHtml = webBook.lastBookInfoHtml ?? '';
    _addLog('︽详情页解析完成', state: 20, sourceHtml: bookHtml);
    _addLog('');

    if (book == null) {
      _addLog('≡详情页解析失败', state: -1);
      return;
    }

    _addLog('├获取书名');
    _addLog('├${book.name}');
    _addLog('├获取作者');
    _addLog('├${book.author}');
    _addLog('├获取分类');
    _addLog('├${book.kind ?? ''}');
    _addLog('├获取字数');
    _addLog('├${book.wordCount ?? ''}');
    _addLog('├获取最新章节');
    _addLog('├${book.lastChapter ?? ''}');
    _addLog('├获取简介');
    _addLog('├${book.intro}');
    _addLog('├获取封面链接');
    _addLog('├${book.coverUrl}');
    _addLog('└获取目录链接');
    _addLog(book.tocUrl ?? '');

    final tocUrl = book.tocUrl?.trim();
    final effectiveTocUrl = (tocUrl != null && tocUrl.isNotEmpty) ? tocUrl : bookUrl;
    
    if (tocUrl != null && tocUrl.isNotEmpty) {
      _addLog('≡已获取目录链接，开始解析目录');
    } else {
      _addLog('≡目录链接为空，使用详情页作为目录页');
    }
    _addLog('');
    await _debugToc(effectiveTocUrl);
  }

  Future<void> _debugToc(String tocUrl) async {
    if (_debugCancelled) return;
    final webBook = _webBook!;
    final realUrl = _extractRealUrl(tocUrl);
    _addLog('︾开始解析目录页');

    _addLog('├获取目录链接');
    _addLog('└$realUrl');

    final List<Chapter> chapters = await webBook.getChapterList(realUrl);
    if (_debugCancelled) return;

    final tocHtml = webBook.lastTocHtml ?? '';
    _addLog('︽目录页解析完成', state: 30, sourceHtml: tocHtml);
    _addLog('');

    if (chapters.isEmpty) {
      _addLog('≡没有正文章节');
      return;
    }

    _addLog('≡首章信息');
    final Chapter first = chapters.first;
    _addLog('◇章节名称:${first.title}');
    _addLog('◇章节链接:${first.url ?? ''}');
    _addLog('◇章节信息:');
    _addLog('◇├是否VIP:false');
    _addLog('◇├是否购买:false');
    _addLog('◇└目录总数:${chapters.length}');
    _addLog('');

    final chapterUrl = first.url?.trim();
    if (chapterUrl != null && chapterUrl.isNotEmpty) {
      await _debugContent(chapterUrl);
    }
  }

  Future<void> _debugContent(String chapterUrl) async {
    if (_debugCancelled) return;
    final webBook = _webBook!;
    final realUrl = _extractRealUrl(chapterUrl);
    _addLog('︾开始解析正文页');

    final String? content = await webBook.getContent(realUrl);
    if (_debugCancelled) return;

    final contentHtml = webBook.lastContentHtml ?? '';
    _addLog('︽正文页解析完成', state: 40, sourceHtml: contentHtml);
    _addLog('');

    _addLog('≡获取成功:$realUrl');
    _addLog('');
    _addLog('├获取正文下一页链接');
    _addLog('└${webBook.source.ruleContent?.nextContentUrl ?? ''}');

    if (content == null) {
      _addLog('≡正文解析失败: 返回null', state: -1);
      return;
    }
    
    final trimmedContent = content.trim();
    if (trimmedContent.isEmpty) {
      _addLog('≡正文解析失败: 内容为空', state: -1);
      return;
    }

    _addLog('┌获取正文内容 (${trimmedContent.length}字符)');
    _addLog('└\n$trimmedContent');
    _addLog('≡解析完成', state: 1000);
  }

  /// 显示源码对话框
  void _showSourceDialog(String title, String source) {
    if (source.isEmpty) {
      _addLog('≡源码为空');
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          children: [
            AppBar(
              title: Text(title),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: '复制',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: source));
                    Navigator.pop(ctx);
                    _addLog('≡已复制源码');
                  },
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  source,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onMenuSelected(_DebugMenuAction action) {
    switch (action) {
      case _DebugMenuAction.searchSource:
        _showSourceDialog('搜索源码', _searchSrc);
        break;
      case _DebugMenuAction.bookSource:
        _showSourceDialog('详情源码', _bookSrc);
        break;
      case _DebugMenuAction.tocSource:
        _showSourceDialog('目录源码', _tocSrc);
        break;
      case _DebugMenuAction.contentSource:
        _showSourceDialog('正文源码', _contentSrc);
        break;
      case _DebugMenuAction.refreshExploreKinds:
        _refreshExploreKinds();
        break;
      case _DebugMenuAction.help:
        _showHelpDialog();
        break;
    }
  }

  /// 显示帮助对话框
  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('调试帮助'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('调试搜索：输入关键字进行搜索'),
              SizedBox(height: 8),
              Text('调试发现：输入 发现名::发现URL'),
              SizedBox(height: 8),
              Text('调试详情页：输入详情页URL'),
              SizedBox(height: 8),
              Text('调试目录页：输入 ++目录页URL'),
              SizedBox(height: 8),
              Text('调试正文页：输入 --正文页URL'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
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
            focusNode: _searchFocusNode,
            textInputAction: TextInputAction.search,
            onTap: () {
              if (mounted) {
                setState(() {
                  _showHelp = true;
                });
              }
            },
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
              value: _DebugMenuAction.searchSource,
              child: Text('搜索源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.bookSource,
              child: Text('详情源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.tocSource,
              child: Text('目录源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.contentSource,
              child: Text('正文源码'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.refreshExploreKinds,
              child: Text('刷新发现'),
            ),
            PopupMenuItem(
              value: _DebugMenuAction.help,
              child: Text('帮助'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildExampleChip(String label, String value,
      {bool fullWidth = false, VoidCallback? onTap}) {
    final width = fullWidth ? double.infinity : null;
    return GestureDetector(
      onTap: onTap ?? () => _fillExample(value),
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
              _buildExampleChip(
                _textMy,
                _textMy,
                onTap: () => _submitDebug(_textMy),
              ),
              _buildExampleChip(
                _textXt,
                _textXt,
                onTap: () => _submitDebug(_textXt),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('调试发现>>输入发现URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(
            _textFx,
            _textFx,
            fullWidth: true,
            onTap: () => _submitDebug(_textFx),
          ),
          const SizedBox(height: 18),
          const Text('调试详情页>>输入详情页URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(
            _textInfo,
            _textInfo,
            fullWidth: true,
            onTap: () => _submitDebug(
              _searchController.text.trim().isNotEmpty
                  ? _searchController.text.trim()
                  : _textInfo,
            ),
          ),
          const SizedBox(height: 18),
          const Text('调试目录页>>输入目录页URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(
            _textToc,
            _textToc,
            fullWidth: true,
            onTap: () => _submitPrefixed('++'),
          ),
          const SizedBox(height: 18),
          const Text('调试正文页>>输入正文页URL，如：', style: labelStyle),
          const SizedBox(height: 10),
          _buildExampleChip(
            _textContent,
            _textContent,
            fullWidth: true,
            onTap: () => _submitPrefixed('--'),
          ),
        ],
      ),
    );
  }

  /// 构建日志行，支持文本选择和URL点击
  Widget _buildLogLine(String line) {
    final match = RegExp(r'^\[(\d{2}:\d{2}\.\d{3})\]\s*(.*)$').firstMatch(line);
    final stamp = match?.group(1) ?? '';
    final body = match?.group(2) ?? line;

    Color bodyColor = const Color(0xFF444444);
    FontWeight bodyWeight = FontWeight.w400;

    // 根据特殊字符和内容设置颜色
    if (body.startsWith('︾')) {
      bodyColor = const Color(0xFF1976D2);
      bodyWeight = FontWeight.w500;
    } else if (body.startsWith('︽')) {
      bodyColor = const Color(0xFF2E7D32);
      bodyWeight = FontWeight.w600;
    } else if (body.startsWith('⇒')) {
      bodyColor = const Color(0xFF0277BD);
      bodyWeight = FontWeight.w400;
    } else if (body.startsWith('≡')) {
      bodyColor = const Color(0xFF616161);
      bodyWeight = FontWeight.w400;
    } else if (body.contains('错误') || body.contains('失败')) {
      bodyColor = const Color(0xFFD32F2F);
      bodyWeight = FontWeight.w600;
    } else if (body.startsWith('http://') || body.startsWith('https://')) {
      bodyColor = const Color(0xFF1565C0);
      bodyWeight = FontWeight.w500;
    } else if (body.contains('完成') || body.contains('成功')) {
      bodyColor = const Color(0xFF2E7D32);
      bodyWeight = FontWeight.w500;
    }

    // 解析URL，使其可点击
    final urlPattern = RegExp(r'(https?://[^\s]+)');
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final urlMatch in urlPattern.allMatches(body)) {
      // 添加URL前的文本
      if (urlMatch.start > lastEnd) {
        spans.add(TextSpan(
          text: body.substring(lastEnd, urlMatch.start),
          style: TextStyle(color: bodyColor, fontWeight: bodyWeight),
        ));
      }
      // 添加可点击的URL
      spans.add(TextSpan(
        text: urlMatch.group(0),
        style: const TextStyle(
          color: Color(0xFF1565C0),
          fontWeight: FontWeight.w500,
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _onUrlTap(urlMatch.group(0)!),
      ));
      lastEnd = urlMatch.end;
    }
    // 添加剩余文本
    if (lastEnd < body.length) {
      spans.add(TextSpan(
        text: body.substring(lastEnd),
        style: TextStyle(color: bodyColor, fontWeight: bodyWeight),
      ));
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectableText.rich(
        TextSpan(
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
            ...spans,
          ],
        ),
        contextMenuBuilder: (context, editableTextState) {
          return AdaptiveTextSelectionToolbar.editableText(
            editableTextState: editableTextState,
          );
        },
      ),
    );
  }

  /// URL点击处理
  void _onUrlTap(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // 弹出选项：复制链接或用此URL调试
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制链接'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.pop(ctx);
                _addLog('≡已复制链接');
              },
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('调试此URL'),
              onTap: () {
                Navigator.pop(ctx);
                _searchController.text = url;
                _submitDebug(url);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('在浏览器中打开'),
              onTap: () async {
                Navigator.pop(ctx);
                // 使用 url_launcher 或其他方式打开
                _addLog('≡请在浏览器中打开: $url');
              },
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
      body: _currentTab == 0 ? _buildDebugBody() : _buildLogViewerBody(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        onTap: (index) => setState(() => _currentTab = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.bug_report_outlined),
            activeIcon: Icon(Icons.bug_report),
            label: '调试',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.article_outlined),
            activeIcon: Icon(Icons.article),
            label: '日志',
          ),
        ],
        selectedItemColor: const Color(0xFF1976D2),
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }

  /// 调试 Tab 内容
  Widget _buildDebugBody() {
    return Stack(
      children: [
        if (!_showHelp)
          Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
              children: _debugLogs.isEmpty
                  ? [
                      const SizedBox(height: 120),
                      const Text(
                        '等待调试结果...',
                        style: TextStyle(
                          fontSize: 16,
                          color: Color(0xFF9A9A9A),
                        ),
                      ),
                    ]
                  : _debugLogs.map(_buildLogLine).toList(),
            ),
          )
        else
          SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 28),
            child: _buildHelpPanel(),
          ),
        if (_isLoading)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 36,
                child: const CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF1976D2),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 日志查看器 Tab 内容
  final ScrollController _logScrollController = ScrollController();

  Widget _buildLogViewerBody() {
    final filteredLogs = _appLogs.where((e) {
      if (e.level.index < _logFilterLevel.index) return false;
      if (_logFilterCategory != null && e.category != _logFilterCategory) return false;
      return true;
    }).toList();

    return Column(
      children: [
        // 过滤器栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: const Color(0xFFF5F5F5),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // 级别过滤
                _buildFilterChip('全部', _logFilterLevel == LogLevel.verbose, () {
                  setState(() => _logFilterLevel = LogLevel.verbose);
                }),
                _buildFilterChip('Debug', _logFilterLevel == LogLevel.debug, () {
                  setState(() => _logFilterLevel = LogLevel.debug);
                }),
                _buildFilterChip('Info', _logFilterLevel == LogLevel.info, () {
                  setState(() => _logFilterLevel = LogLevel.info);
                }),
                _buildFilterChip('Warn', _logFilterLevel == LogLevel.warning, () {
                  setState(() => _logFilterLevel = LogLevel.warning);
                }),
                _buildFilterChip('Error', _logFilterLevel == LogLevel.error, () {
                  setState(() => _logFilterLevel = LogLevel.error);
                }),
                const SizedBox(width: 8),
                // 分类过滤
                _buildFilterChip('全部类别', _logFilterCategory == null, () {
                  setState(() => _logFilterCategory = null);
                }),
                for (final cat in LogCategory.values)
                  _buildFilterChip(cat.label, _logFilterCategory == cat, () {
                    setState(() => _logFilterCategory = cat);
                  }),
              ],
            ),
          ),
        ),
        // 日志统计
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          color: const Color(0xFFFAFAFA),
          child: Row(
            children: [
              Text('共 ${filteredLogs.length} 条日志',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '清空日志',
                onPressed: () {
                  AppLogger.instance.clear();
                  setState(() => _appLogs.clear());
                },
              ),
            ],
          ),
        ),
        // 日志列表
        Expanded(
          child: filteredLogs.isEmpty
              ? const Center(
                  child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  controller: _logScrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: filteredLogs.length,
                  itemBuilder: (context, index) {
                    final entry = filteredLogs[index];
                    return _buildAppLogEntry(entry);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1976D2) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF1976D2) : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.white : Colors.black54,
          ),
        ),
      ),
    );
  }

  Widget _buildAppLogEntry(LogEntry entry) {
    Color bgColor;
    switch (entry.level) {
      case LogLevel.error:
        bgColor = const Color(0xFFFFEBEE);
        break;
      case LogLevel.warning:
        bgColor = const Color(0xFFFFF8E1);
        break;
      case LogLevel.info:
        bgColor = const Color(0xFFE8F5E9);
        break;
      default:
        bgColor = Colors.transparent;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(entry.levelIcon, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Text(
                '${entry.time.hour.toString().padLeft(2, '0')}:${entry.time.minute.toString().padLeft(2, '0')}:${entry.time.second.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace'),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  entry.category.label,
                  style: const TextStyle(fontSize: 9, color: Colors.black54),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.message,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF333333)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (entry.detail != null && entry.detail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                entry.detail!,
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF666666),
                  fontFamily: 'monospace',
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
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
