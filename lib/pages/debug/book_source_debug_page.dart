import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/book_source.dart';
import '../../routes/app_routes.dart';
import '../../services/app_logger.dart';
import '../../services/source_debug_service.dart';
import '../../services/storage_service.dart';

/// 书源调试页（优化版）
/// 
/// 主要优化点：
/// 1. 使用 SourceDebugService 单例管理调试逻辑
/// 2. 简化代码结构，移除冗余方法
/// 3. 保留完整的调试功能
class BookSourceDebugPage extends StatefulWidget {
  final String? sourceUrl;
  final BookSource? source;

  const BookSourceDebugPage({super.key, this.sourceUrl, this.source});

  @override
  State<BookSourceDebugPage> createState() => _BookSourceDebugPageState();
}

class _BookSourceDebugPageState extends State<BookSourceDebugPage>
    implements DebugCallback {
  BookSource? _source;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<String> _debugLogs = [];

  bool _isLoading = false;
  bool _showHelp = true;
  int _currentTab = 0;

  // AppLogger 订阅
  StreamSubscription<LogEntry>? _logSubscription;
  final List<LogEntry> _appLogs = [];
  LogLevel _logFilterLevel = LogLevel.verbose;
  LogCategory? _logFilterCategory;

  // 发现分类缓存
  List<_ExploreKindItem> _exploreKinds = [];

  // 示例文本
  String _textMy = '我的';
  final String _textXt = '系统';
  String _textFx = '系统::http://xxx';
  final String _textInfo = 'https://m.qidian.com/book/1015609210';
  final String _textToc = '++https://www.zhaishuyuan.com/read/303...';
  final String _textContent = '--https://www.zhaishuyuan.com/chapter/3...';

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

    // 注册调试回调
    SourceDebugService.instance.callback = this;

    // 订阅 AppLogger 日志流
    _logSubscription = AppLogger.instance.stream.listen((entry) {
      if (!mounted) return;
      setState(() {
        _appLogs.add(entry);
        // 限制日志数量，防止内存无限增长
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
    // 取消调试回调
    SourceDebugService.instance.callback = null;
    SourceDebugService.instance.cancelDebug(destroy: true);

    _logSubscription?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  /// DebugCallback 实现
  @override
  void printLog(int state, String msg) {
    if (!mounted) return;
    setState(() {
      _debugLogs.add(msg);
    });
  }

  Future<void> _loadSource() async {
    debugPrint('=== 调试页面加载书源 ===');
    AppLogger.instance.info(LogCategory.parse, '调试页面加载书源');

    // 优先使用直接传入的 BookSource 对象
    if (widget.source != null) {
      _source = widget.source;
      debugPrint('✅ 使用传入的书源对象: ${_source!.bookSourceName}');
      AppLogger.instance.info(
        LogCategory.parse,
        '使用传入的书源对象',
        detail: _source!.bookSourceName,
      );
      _afterSourceLoaded();
      return;
    }

    // 降级：从 StorageService 加载
    final sourceUrl = widget.sourceUrl;
    if (sourceUrl == null || sourceUrl.isEmpty) {
      debugPrint('sourceUrl 为空，无法加载书源');
      AppLogger.instance.warn(LogCategory.parse, 'sourceUrl 为空，无法加载书源');
      if (mounted) {
        setState(() {
          _showHelp = true;
        });
      }
      return;
    }

    if (!StorageService.instance.isInitialized) {
      AppLogger.instance.warn(
        LogCategory.storage,
        'StorageService 未初始化，尝试初始化...',
      );
      try {
        await StorageService.instance.init();
      } catch (e) {
        AppLogger.instance.error(
          LogCategory.storage,
          'StorageService 初始化失败',
          detail: e.toString(),
        );
      }
    }

    final data = StorageService.instance.getBookSource(sourceUrl);
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
      debugPrint('书源加载成功: ${_source!.bookSourceName}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('书源解析失败: $e')),
        );
      }
      return;
    }

    _afterSourceLoaded();
  }

  void _afterSourceLoaded() {
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

  List<_ExploreKindItem> _parseExploreKinds(BookSource? source) {
    final exploreUrl = source?.exploreUrl?.trim();
    if (exploreUrl == null || exploreUrl.isEmpty) return const [];

    if (exploreUrl.startsWith('@js:') || exploreUrl.startsWith('<js>')) {
      return const [];
    }

    final items = <_ExploreKindItem>[];
    for (final line in exploreUrl.split(RegExp(r'(&&|\n)+'))) {
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

  Future<void> _submitDebug([String? value]) async {
    final text = (value ?? _searchController.text).trim();
    if (text.isEmpty) return;

    final source = _source;
    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未获取到书源'), duration: Duration(seconds: 2)),
      );
      return;
    }

    _searchFocusNode.unfocus();
    if (mounted) {
      setState(() {
        _showHelp = false;
        _isLoading = true;
        _debugLogs.clear();
      });
    }

    try {
      await SourceDebugService.instance.startDebug(source, text);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _fillExample(String value) {
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
  }

  /// 显示源码对话框
  void _showSourceDialog(String title, String source) {
    if (source.isEmpty) {
      setState(() {
        _debugLogs.add('≡源码为空，请检查：1)网络权限 2)URL是否正确 3)书源规则');
      });
      return;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? Colors.grey[900] : Colors.white;
    final textColor = isDark ? Colors.grey[200] : Colors.grey[800];
    final appBarBgColor = isDark ? Colors.grey[850] : const Color(0xFFF5F5F5);
    final appBarFgColor = ThemeData.estimateBrightnessForColor(appBarBgColor!) == Brightness.dark
        ? Colors.white
        : Colors.black87;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          children: [
            // 自定义标题栏
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: appBarBgColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.close, color: appBarFgColor),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: appBarFgColor,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.copy, color: appBarFgColor),
                    tooltip: '复制',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: source));
                      Navigator.pop(ctx);
                      setState(() {
                        _debugLogs.add('≡已复制源码');
                      });
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 源码内容
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  source,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: textColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? null : Colors.white,
      appBar: _buildAppBar(context),
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

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final bgColor = isDark ? null : Colors.white;
    final searchBgColor = isDark ? Colors.grey[800] : const Color(0xFFF1F1F1);
    final hintColor = isDark ? Colors.grey[400] : Colors.black38;
    
    return AppBar(
      backgroundColor: bgColor,
      surfaceTintColor: bgColor,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded),
        color: textColor,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      titleSpacing: 0,
      title: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          height: 36,
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
            style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
            decoration: InputDecoration(
              hintText: '搜索书名、作者',
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: hintColor,
              ),
              prefixIcon: Icon(Icons.search, size: 18, color: textColor.withValues(alpha: 0.6)),
              suffixIcon: IconButton(
                icon: Icon(Icons.chevron_right_rounded, size: 20, color: textColor.withValues(alpha: 0.6)),
                onPressed: () => _submitDebug(),
              ),
              filled: true,
              fillColor: searchBgColor,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: isDark ? Colors.blue[300]! : const Color(0xFFB8D5FF)),
              ),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: '扫描二维码',
          onPressed: _scanQrCode,
          icon: const Icon(Icons.qr_code_scanner),
          color: textColor,
        ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: textColor),
          tooltip: '更多选项',
          offset: const Offset(0, 48),
          onSelected: (value) {
            switch (value) {
              case 'search_src':
                _showSourceDialog('搜索源码', SourceDebugService.instance.searchSrc);
                break;
              case 'book_src':
                _showSourceDialog('详情源码', SourceDebugService.instance.bookSrc);
                break;
              case 'toc_src':
                _showSourceDialog('目录源码', SourceDebugService.instance.tocSrc);
                break;
              case 'content_src':
                _showSourceDialog('正文源码', SourceDebugService.instance.contentSrc);
                break;
              case 'refresh_explore':
                _exploreKinds = _parseExploreKinds(_source);
                if (_exploreKinds.isNotEmpty) {
                  _textFx = '${_exploreKinds.first.title}::${_exploreKinds.first.url}';
                }
                setState(() {});
                break;
              case 'import':
                Navigator.pushNamed(context, AppRoutes.bookSourceImport);
                break;
              case 'help':
                _showHelpDialog();
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'search_src',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('搜索源码', style: TextStyle(color: textColor)),
            ),
            PopupMenuItem(
              value: 'book_src',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('详情源码', style: TextStyle(color: textColor)),
            ),
            PopupMenuItem(
              value: 'toc_src',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('目录源码', style: TextStyle(color: textColor)),
            ),
            PopupMenuItem(
              value: 'content_src',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('正文源码', style: TextStyle(color: textColor)),
            ),
            PopupMenuItem(
              value: 'refresh_explore',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('刷新发现', style: TextStyle(color: textColor)),
            ),
            PopupMenuItem(
              value: 'import',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('导入书源', style: TextStyle(color: textColor)),
            ),
            PopupMenuItem(
              value: 'help',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('帮助', style: TextStyle(color: textColor)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDebugBody() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hintColor = isDark ? Colors.grey[500] : const Color(0xFF9A9A9A);
    
    return Stack(
      children: [
        if (!_showHelp)
          Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
              children: _debugLogs.isEmpty
                  ? [
                      const SizedBox(height: 120),
                      Text(
                        '等待调试结果...',
                        style: TextStyle(
                          fontSize: 16,
                          color: hintColor,
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
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: isDark ? Colors.lightBlue[300] : const Color(0xFF1976D2),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHelpPanel() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.grey[400] : Colors.black54;
    final labelStyle = TextStyle(
      fontSize: 13,
      color: labelColor,
      height: 1.25,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('调试搜索>>输入关键字，如：', style: labelStyle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _buildExampleChip(
                _textMy,
                _textMy,
                onTap: () {
                  _searchController.text = _textMy;
                  _submitDebug(_textMy);
                },
              ),
              _buildExampleChip(
                _textXt,
                _textXt,
                onTap: () {
                  _searchController.text = _textXt;
                  _submitDebug(_textXt);
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('调试发现>>输入发现URL，如：', style: labelStyle),
          const SizedBox(height: 8),
          _buildExampleChip(
            _textFx,
            _textFx,
            fullWidth: true,
            onTap: () {
              _searchController.text = _textFx;
              _submitDebug(_textFx);
            },
            onLongPress: _exploreKinds.length > 1
                ? () => _showExploreKindSelector()
                : null,
          ),
          const SizedBox(height: 14),
          Text('调试详情页>>输入详情页URL，如：', style: labelStyle),
          const SizedBox(height: 8),
          _buildExampleChip(
            _textInfo,
            _textInfo,
            fullWidth: true,
            onTap: () {
              final url = _searchController.text.trim().isNotEmpty
                  ? _searchController.text.trim()
                  : _textInfo;
              _submitDebug(url);
            },
          ),
          const SizedBox(height: 14),
          Text('调试目录页>>输入目录页URL，如：', style: labelStyle),
          const SizedBox(height: 8),
          _buildExampleChip(
            _textToc,
            _textToc,
            fullWidth: true,
            onTap: () => _submitPrefixed('++'),
          ),
          const SizedBox(height: 14),
          Text('调试正文页>>输入正文页URL，如：', style: labelStyle),
          const SizedBox(height: 8),
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

  Future<void> _submitPrefixed(String prefix) async {
    final query = _searchController.text.trim();
    if (query.isEmpty || query.length <= 2) {
      _searchController.text = prefix;
      _searchController.selection = TextSelection.collapsed(offset: prefix.length);
      await _submitDebug(prefix);
      return;
    }

    final next = query.startsWith(prefix) ? query : '$prefix$query';
    _searchController.text = next;
    _searchController.selection = TextSelection.collapsed(offset: next.length);
    await _submitDebug(next);
  }

  Widget _buildExampleChip(
    String label,
    String value, {
    bool fullWidth = false,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipBgColor = isDark ? Colors.grey[800] : const Color(0xFFD9D9D9);
    final chipTextColor = isDark ? Colors.grey[200] : Colors.black87;
    
    final width = fullWidth ? double.infinity : null;
    return GestureDetector(
      onTap: onTap ?? () => _fillExample(value),
      onLongPress: onLongPress,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: chipBgColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: chipTextColor,
            fontSize: 13,
            height: 1.15,
          ),
        ),
      ),
    );
  }

  /// 显示发现分类选择器
  void _showExploreKindSelector() {
    if (_exploreKinds.isEmpty) return;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '选择发现分类',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            ..._exploreKinds.map((kind) => ListTile(
              title: Text(kind.title),
              subtitle: Text(
                kind.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _textFx = '${kind.title}::${kind.url}';
                });
                _searchController.text = _textFx;
                _submitDebug(_textFx);
              },
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildLogLine(String line) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // 解析时间戳（格式: [00:00.000] 消息内容）
    final match = RegExp(r'^\[(\d{2}:\d{2}\.\d{3})\]\s*(.*)$').firstMatch(line);
    final stamp = match?.group(1);
    final body = match?.group(2) ?? line;

    if (body.startsWith('└\n')) {
      return _buildContentLogLine(line, stamp, body.substring(2));
    }

    // 默认颜色根据主题调整
    Color bodyColor = isDark ? Colors.grey[300]! : const Color(0xFF444444);
    FontWeight bodyWeight = FontWeight.w400;

    // 根据特殊字符设置颜色（深色模式下使用更亮的颜色）
    if (body.startsWith('︾')) {
      bodyColor = isDark ? Colors.lightBlue[300]! : const Color(0xFF1976D2);
      bodyWeight = FontWeight.w500;
    } else if (body.startsWith('︽')) {
      bodyColor = isDark ? Colors.green[300]! : const Color(0xFF2E7D32);
      bodyWeight = FontWeight.w600;
    } else if (body.startsWith('⇒')) {
      bodyColor = isDark ? Colors.lightBlue[200]! : const Color(0xFF0277BD);
      bodyWeight = FontWeight.w400;
    } else if (body.startsWith('≡')) {
      bodyColor = isDark ? Colors.grey[400]! : const Color(0xFF616161);
      bodyWeight = FontWeight.w400;
    } else if (body.startsWith('┌')) {
      bodyColor = isDark ? Colors.blue[200]! : const Color(0xFF1565C0);
      bodyWeight = FontWeight.w500;
    } else if (body.startsWith('└') && !body.startsWith('└\n')) {
      // 正文内容以 └\n 开头，使用默认颜色
      bodyColor = isDark ? Colors.grey[300]! : const Color(0xFF333333);
      bodyWeight = FontWeight.w400;
    } else if (body.startsWith('◇')) {
      bodyColor = isDark ? Colors.purple[200]! : const Color(0xFF6A1B9A);
      bodyWeight = FontWeight.w500;
    } else if (body.contains('错误') || body.contains('失败')) {
      bodyColor = isDark ? Colors.red[300]! : const Color(0xFFD32F2F);
      bodyWeight = FontWeight.w600;
    } else if (body.contains('完成') || body.contains('成功')) {
      bodyColor = isDark ? Colors.green[300]! : const Color(0xFF2E7D32);
      bodyWeight = FontWeight.w500;
    }

    // URL 颜色
    final urlColor = isDark ? Colors.lightBlue[200]! : const Color(0xFF1565C0);

    // 解析 URL，用 WORD JOINER 阻止 URL 内断行
    // 只匹配 URL 有效字符，排除中文标点和常见结束符
    final urlPattern = RegExp(r'(https?://[a-zA-Z0-9\-._~:/?#\[\]@!$&()*+,;=%]+)');
    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final urlMatch in urlPattern.allMatches(body)) {
      if (urlMatch.start > lastEnd) {
        spans.add(
          TextSpan(
            text: body.substring(lastEnd, urlMatch.start),
            style: TextStyle(color: bodyColor, fontWeight: bodyWeight),
          ),
        );
      }
      final url = urlMatch.group(0)!;
      spans.add(
        TextSpan(
          text: _protectUrl(url),
          style: TextStyle(
            color: urlColor,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.underline,
            decorationColor: urlColor,
            decorationThickness: 1.5,
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _onUrlTap(url),
        ),
      );
      lastEnd = urlMatch.end;
    }
    if (lastEnd < body.length) {
      spans.add(
        TextSpan(
          text: body.substring(lastEnd),
          style: TextStyle(color: bodyColor, fontWeight: bodyWeight),
        ),
      );
    }

    // 时间戳颜色
    final stampColor = isDark ? Colors.grey[500] : const Color(0xFFAAAAAA);
    final defaultTextColor = isDark ? Colors.grey[300] : const Color(0xFF555555);

    return GestureDetector(
      onTap: () => _showDebugLogDetail(line, body),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: SelectableText.rich(
          TextSpan(
            style: TextStyle(
              fontSize: 14,
              height: 1.35,
              color: defaultTextColor,
            ),
            children: [
              if (stamp != null)
                TextSpan(
                  text: '[$stamp] ',
                  style: TextStyle(color: stampColor, fontSize: 13),
                ),
              ...spans,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContentLogLine(String line, String? stamp, String content) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stampColor = isDark ? Colors.grey[500] : const Color(0xFFAAAAAA);
    final textColor = isDark ? Colors.grey[200] : const Color(0xFF333333);
    final bgColor = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF7F7F7);
    final borderColor = isDark ? Colors.grey[800]! : const Color(0xFFE0E0E0);

    return GestureDetector(
      onTap: () => _showDebugLogDetail(line, content),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stamp != null) ...[
                Text(
                  '[$stamp] 正文内容',
                  style: TextStyle(
                    color: stampColor,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 6),
              ],
              SelectableText(
                content,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: textColor,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _protectUrl(String url) {
    // 在 URL 的 / . - : ? & = # 等字符后插入 WORD JOINER (U+2060)
    // 阻止 Flutter ICU 引擎在这些字符后断行
    return url.replaceAllMapped(
      RegExp(r'([/.:\?&=#])'),
      (m) => '${m[1]}\u2060',
    );
  }

  void _showDebugLogDetail(String fullLine, String body) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.grey[200] : Colors.grey[800];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('日志详情'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                body,
                style: TextStyle(
                  fontSize: 14,
                  fontFamily: 'monospace',
                  height: 1.5,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: body));
              Navigator.pop(ctx);
              setState(() {
                _debugLogs.add('≡已复制日志内容');
              });
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _onUrlTap(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    // 默认使用内置浏览器打开链接
    Navigator.pushNamed(
      context,
      AppRoutes.internalBrowser,
      arguments: {
        'url': url,
        'title': '',
        'sourceUrl': _source?.bookSourceUrl ?? '',
        'sourceName': _source?.bookSourceName ?? '',
      },
    );
  }

  /// 扫描二维码
  void _scanQrCode() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (ctx) => const _QrScannerPage(),
      ),
    );
    
    if (result != null && result.isNotEmpty && mounted) {
      // 将扫描结果填入搜索框
      _searchController.text = result;
      _searchController.selection = TextSelection.collapsed(offset: result.length);
      setState(() {
        _showHelp = true;
      });
    }
  }

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

  final ScrollController _logScrollController = ScrollController();

  Widget _buildLogViewerBody() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final filterBarColor = isDark ? Colors.grey[850] : const Color(0xFFF5F5F5);
    final statsBarColor = isDark ? Colors.grey[900] : const Color(0xFFFAFAFA);
    
    final filteredLogs = _appLogs.where((e) {
      if (e.level.index < _logFilterLevel.index) {
        return false;
      }
      if (_logFilterCategory != null && e.category != _logFilterCategory) {
        return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        // 过滤器栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: filterBarColor,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
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
          color: statsBarColor,
          child: Row(
            children: [
              Text(
                '共 ${filteredLogs.length} 条日志',
                style: TextStyle(fontSize: 12, color: isDark ? Colors.grey[400] : Colors.grey),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.file_download_outlined, size: 18, color: isDark ? Colors.grey[400] : null),
                tooltip: '导出日志',
                onPressed: () => _exportLogs(),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, size: 18, color: isDark ? Colors.grey[400] : null),
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
              ? Center(
                  child: Text('暂无日志', style: TextStyle(color: isDark ? Colors.grey[500] : Colors.grey)),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1976D2) : (isDark ? Colors.grey[800] : Colors.white),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF1976D2) : (isDark ? Colors.grey[700]! : Colors.grey.shade300),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.white : (isDark ? Colors.grey[400] : Colors.black54),
          ),
        ),
      ),
    );
  }

  Widget _buildAppLogEntry(LogEntry entry) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    Color bgColor;
    switch (entry.level) {
      case LogLevel.error:
        bgColor = isDark ? Colors.red[900]!.withValues(alpha: 0.3) : const Color(0xFFFFEBEE);
        break;
      case LogLevel.warning:
        bgColor = isDark ? Colors.orange[900]!.withValues(alpha: 0.3) : const Color(0xFFFFF8E1);
        break;
      case LogLevel.info:
        bgColor = isDark ? Colors.green[900]!.withValues(alpha: 0.3) : const Color(0xFFE8F5E9);
        break;
      default:
        bgColor = Colors.transparent;
    }

    final textColor = isDark ? Colors.grey[200] : const Color(0xFF333333);
    final detailColor = isDark ? Colors.grey[400] : const Color(0xFF666666);
    final timeColor = isDark ? Colors.grey[500] : Colors.grey;
    final categoryBgColor = isDark ? Colors.grey[700] : const Color(0xFFE0E0E0);
    final categoryTextColor = isDark ? Colors.grey[300] : Colors.black54;

    return GestureDetector(
      onTap: () => _showLogDetailDialog(entry),
      child: Container(
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
                  style: TextStyle(
                    fontSize: 10,
                    color: timeColor,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: categoryBgColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    entry.category.label,
                    style: TextStyle(fontSize: 9, color: categoryTextColor),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.message,
                    style: TextStyle(fontSize: 12, color: textColor),
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
                  style: TextStyle(
                    fontSize: 11,
                    color: detailColor,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showLogDetailDialog(LogEntry entry) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.grey[200] : null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Text(entry.levelIcon),
            const SizedBox(width: 8),
            Text(entry.category.label),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('时间: ${entry.time.toString().substring(0, 19)}'),
              const SizedBox(height: 4),
              Text('级别: ${entry.level.name}'),
              const SizedBox(height: 8),
              const Text('消息:', style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(
                entry.message,
                style: TextStyle(fontFamily: 'monospace', color: textColor),
              ),
              if (entry.detail != null && entry.detail!.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('详情:', style: TextStyle(fontWeight: FontWeight.bold)),
                SelectableText(
                  entry.detail!,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: textColor),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(
              ClipboardData(text: '${entry.message}\n${entry.detail ?? ''}'),
            ),
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs() async {
    try {
      final text = AppLogger.instance.exportLogs(
        category: _logFilterCategory,
        minLevel: _logFilterLevel,
      );

      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      final fileName =
          'APP_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(text);

      setState(() {
        _debugLogs.add('≡正在导出日志...');
      });

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: '导出调试日志',
        text: '导出调试日志',
      );

      if (file.existsSync()) {
        await file.delete();
      }
      setState(() {
        _debugLogs.add('≡日志导出完成');
      });
    } catch (e) {
      setState(() {
        _debugLogs.add('≡导出日志失败: $e');
      });
    }
  }
}

class _ExploreKindItem {
  final String title;
  final String url;

  const _ExploreKindItem(this.title, this.url);
}

/// 二维码扫描页面
class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('扫描二维码', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_off, color: Colors.white),
            tooltip: '闪光灯',
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch, color: Colors.white),
            tooltip: '切换摄像头',
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              final barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                final value = barcode.rawValue;
                if (value != null && value.isNotEmpty) {
                  _controller.stop();
                  Navigator.pop(context, value);
                  return;
                }
              }
            },
          ),
          // 扫描框
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white54, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const CustomPaint(
                painter: _ScanCornerPainter(),
              ),
            ),
          ),
          // 提示文字
          Positioned(
            left: 0,
            right: 0,
            bottom: 100,
            child: Text(
              '将二维码放入框内自动扫描',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 扫描框四角装饰
class _ScanCornerPainter extends CustomPainter {
  const _ScanCornerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF1976D2)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    const cornerLength = 25.0;

    // 左上角
    canvas.drawLine(const Offset(0, cornerLength), Offset.zero, paint);
    canvas.drawLine(Offset.zero, const Offset(cornerLength, 0), paint);

    // 右上角
    canvas.drawLine(Offset(size.width - cornerLength, 0), Offset(size.width, 0), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, cornerLength), paint);

    // 左下角
    canvas.drawLine(Offset(0, size.height - cornerLength), Offset(0, size.height), paint);
    canvas.drawLine(Offset(0, size.height), Offset(cornerLength, size.height), paint);

    // 右下角
    canvas.drawLine(Offset(size.width - cornerLength, size.height), Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(size.width, size.height - cornerLength), Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
