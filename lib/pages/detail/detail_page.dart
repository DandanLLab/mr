import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/app_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/storage_service.dart';
import '../../services/book_data_provider.dart';
import '../../services/chapter_cache_service.dart';
import '../../widgets/change_source_sheet.dart';
import '../../services/cover_config_service.dart';
import '../../widgets/book_edit_sheet.dart';
import '../../utils/design_tokens.dart';

const _coverWidth = 110.0;
const _coverHeight = 160.0;

class DetailPage extends StatefulWidget {
  final String bookUrl;
  final Book? initialBook;

  const DetailPage({super.key, required this.bookUrl, this.initialBook});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  bool _isInBookshelf = false;
  bool _isLoading = true;
  bool _isRefreshing = false;
  Book? _book;
  List<Chapter> _chapters = [];
  int _totalWordCount = 0;
  BookDataProvider? _dataProvider;
  bool _showReadRecord = true;
  BookSource? _bookSource;

  @override
  void initState() {
    super.initState();
    _loadDisplayPrefs();
    _loadData();
  }

  Future<void> _loadDisplayPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showReadRecord = prefs.getBool('bookInfoShowReadRecord') ?? true;
    });
  }

  Future<void> _loadData() async {
    final storedData = StorageService.instance.getBook(widget.bookUrl);
    final storedBook = storedData == null ? null : Book.fromJson(storedData);
    Book? book = storedBook ?? widget.initialBook;
    List<Chapter> chapters = [];
    String? error;
    BookSource? bookSource;

    if (book != null) {
      try {
        _dataProvider = createBookDataProvider(book);
        if (book.originType == BookOriginType.online) {
          final detailedBook = await _dataProvider!.getBookInfo(book.bookUrl);
          if (detailedBook != null) {
            book = mergeBookMetadata(detailedBook, book);
          }
          // 获取书源
          if (book.sourceUrl != null) {
            final sourceData = StorageService.instance.getBookSource(
              book.sourceUrl!,
            );
            if (sourceData != null) {
              bookSource = BookSource.fromJson(sourceData);
              // 参照 Legado：根据书源类型刷新 mediaType，确保类型始终与书源一致
              final sourceMediaType = bookSource.bookSourceType.mediaType;
              if (book.mediaType != sourceMediaType) {
                book = book.copyWith(mediaType: sourceMediaType);
              }
            }
          }
        }
        chapters = await _dataProvider!.getChapterList(book);
        if (book.totalChapterNum == null && chapters.isNotEmpty) {
          book = book.copyWith(totalChapterNum: chapters.length);
        }
      } catch (e) {
        error = e.toString();
      }
    }

    _totalWordCount = chapters.fold<int>(
      0,
      (sum, ch) => sum + (ch.wordCount ?? 0),
    );

    if (mounted) {
      setState(() {
        _book = book;
        _chapters = chapters;
        _isInBookshelf = storedData != null;
        _isLoading = false;
        _bookSource = bookSource;
      });
      if (error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('部分信息加载失败：$error')));
      }
    }
  }

  Future<void> _refreshData() async {
    if (_isRefreshing) return;
    setState(() {
      _isRefreshing = true;
    });

    if (_book != null) {
      try {
        _dataProvider = createBookDataProvider(_book!);
        if (_book!.originType == BookOriginType.online) {
          final detailedBook = await _dataProvider!.getBookInfo(_book!.bookUrl);
          if (detailedBook != null) {
            _book = mergeBookMetadata(detailedBook, _book!);
          }
          // 参照 Legado：根据书源类型刷新 mediaType
          if (_book!.sourceUrl != null) {
            final sourceData = StorageService.instance.getBookSource(
              _book!.sourceUrl!,
            );
            if (sourceData != null) {
              final source = BookSource.fromJson(sourceData);
              final sourceMediaType = source.bookSourceType.mediaType;
              if (_book!.mediaType != sourceMediaType) {
                _book = _book!.copyWith(mediaType: sourceMediaType);
              }
            }
          }
        }
        _chapters = await _dataProvider!.getChapterList(_book!);
      } catch (_) {
        // Keep the currently displayed metadata if refreshing fails.
      }
      _totalWordCount = _chapters.fold<int>(
        0,
        (sum, ch) => sum + (ch.wordCount ?? 0),
      );
    }

    if (mounted) {
      setState(() {
        _isRefreshing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_book == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('书籍信息未找到')),
      );
    }

    final bookInfoBackground = context
        .watch<AppProvider>()
        .currentBookInfoBackgroundImage;
    final hasCustomBackground =
        bookInfoBackground != null && bookInfoBackground.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      bottomNavigationBar: _buildBottomActionBar(),
      body: Stack(
        children: [
          if (hasCustomBackground)
            Positioned.fill(child: _buildBackgroundImage(bookInfoBackground)),
          if (!hasCustomBackground &&
              _book!.coverUrl.isNotEmpty &&
              !CoverConfigService.instance.useDefaultCover)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: _book!.coverUrl,
                fit: BoxFit.cover,
                placeholder: (_, __) =>
                    Container(color: Theme.of(context).colorScheme.primary),
                errorWidget: (_, __, ___) =>
                    Container(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          Positioned.fill(
            child: RepaintBoundary(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: hasCustomBackground ? 0 : 10,
                  sigmaY: hasCustomBackground ? 0 : 10,
                ),
                child: Container(
                  color: Colors.black.withValues(
                    alpha: hasCustomBackground ? 0.24 : 0.31,
                  ),
                ),
              ),
            ),
          ),
          // 主内容
          RefreshIndicator(
            onRefresh: _refreshData,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                _buildAppBar(),
                SliverToBoxAdapter(child: _buildOriginalBookInfoLayout()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundImage(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: path,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  Widget _buildOriginalBookInfoLayout() {
    final scheme = Theme.of(context).colorScheme;
    final labels = _buildOriginalLabels();
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.paddingOf(context).top -
        DesignTokens.topBarHeight -
        DesignTokens.bottomBarHeight -
        MediaQuery.paddingOf(context).bottom -
        168;

    return Column(
      children: [
        SizedBox(
          height: 168,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 90,
                left: 0,
                right: 0,
                child: ClipPath(
                  clipper: _BookInfoArcClipper(),
                  child: Container(height: 78, color: scheme.surface),
                ),
              ),
              Positioned(
                top: 3,
                child: Hero(
                  tag: 'cover_${widget.bookUrl}',
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.28),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
                      child: SizedBox(
                        width: _coverWidth,
                        height: _coverHeight,
                        child: _buildDetailCover(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          constraints: BoxConstraints(
            minHeight: availableHeight > 0 ? availableHeight : 0,
          ),
          color: scheme.surface,
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: _searchBookName,
                onLongPress: _copyBookName,
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    _book!.displayName,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: DesignTokens.fontTitle,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (labels.isNotEmpty) ...[
                const SizedBox(height: 7),
                Center(
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    runAlignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 5,
                    children: labels,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _buildOriginalInfoRows(),
              const SizedBox(height: 14),
              _buildIntroContent(scheme.onSurfaceVariant),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildOriginalLabels() {
    final labels = <({String text, _BookLabelType type})>[];
    final seen = <String>{};

    void addLabel(String? value, _BookLabelType type) {
      final text = value?.trim() ?? '';
      if (text.isEmpty || !seen.add(text)) return;
      labels.add((text: text, type: type));
    }

    final tags = <String>[
      ...?_book!.tags,
      ..._splitBookLabels(_book!.kind),
      ..._splitBookLabels(_book!.category),
    ];
    final visibleTags = tags
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .take(3);
    for (final tag in visibleTags) {
      addLabel(tag, _BookLabelType.tag);
    }

    addLabel(_displayStatus, _BookLabelType.status);
    if (_book!.showWordCount) {
      addLabel(_displayWordCount, _BookLabelType.wordCount);
    }

    return labels
        .map((label) => _buildOriginalLabel(label.text, type: label.type))
        .toList();
  }

  List<String> _splitBookLabels(String? value) {
    if (value == null || value.trim().isEmpty) return const [];
    return value
        .split(RegExp(r'[,，、|/·\s]+'))
        .where((item) => item.trim().isNotEmpty)
        .toList();
  }

  String get _displayStatus {
    final status = _book!.status?.trim() ?? '';
    if (status.isEmpty) return '';
    switch (status.toLowerCase()) {
      case '0':
      case 'serial':
      case 'ongoing':
        return '连载';
      case '1':
      case 'complete':
      case 'completed':
      case 'finished':
        return '完结';
      default:
        return status;
    }
  }

  Widget _buildOriginalLabel(String text, {required _BookLabelType type}) {
    final scheme = Theme.of(context).colorScheme;
    final filled = type == _BookLabelType.tag;
    final borderColor = type == _BookLabelType.status
        ? scheme.primary
        : scheme.outline;
    final textColor = filled
        ? scheme.onPrimary
        : type == _BookLabelType.status
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? scheme.primary : Colors.transparent,
        border: Border.all(
          color: filled ? scheme.primary : borderColor,
          width: 0.8,
        ),
        borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
      ),
      child: Text(
        text,
        style: TextStyle(color: textColor, fontSize: DesignTokens.fontSummary, height: 1.25),
      ),
    );
  }

  Widget _buildOriginalInfoRows() {
    final isOnline = _book!.originType == BookOriginType.online;
    return Column(
      children: [
        InkWell(
          onTap: _searchAuthor,
          onLongPress: _copyAuthor,
          child: _buildOriginalInfoRow(
            icon: Icons.person_outline,
            text: '作者：${_book!.displayAuthor}',
          ),
        ),
        InkWell(
          onTap: _editSource,
          child: _buildOriginalInfoRow(
            icon: Icons.public_outlined,
            text: '来源：${_book!.sourceName ?? "本地"}',
            action: isOnline
                ? _buildOriginalAction('换源', _showChangeSourceDialog)
                : null,
          ),
        ),
        if (_book!.latestChapterTitle.isNotEmpty)
          _buildOriginalInfoRow(
            icon: Icons.explore_outlined,
            text: '最新：${_book!.latestChapterTitle}',
          ),
        InkWell(
          onTap: _showChangeGroupDialog,
          child: _buildOriginalInfoRow(
            icon: Icons.account_tree_outlined,
            text: '分组：${_getGroupName()}',
            action: _buildOriginalAction('设置分组', _showChangeGroupDialog),
          ),
        ),
        InkWell(
          onTap: _openFullChapterList,
          child: _buildOriginalInfoRow(
            icon: Icons.folder_open_outlined,
            text: '目录：${_chapterSummaryText()}',
            action: _buildOriginalAction('查看目录', _openFullChapterList),
          ),
        ),
        if (_showReadRecord && _book!.durChapterIndex > 0)
          InkWell(
            onTap: _showReadRecordDialog,
            child: _buildOriginalInfoRow(
              icon: Icons.history,
              text: '阅读记录：${_readRecordSummaryText()}',
              action: _buildOriginalAction('查看', _showReadRecordDialog),
            ),
          ),
      ],
    );
  }

  Widget _buildOriginalInfoRow({
    required IconData icon,
    required String text,
    Widget? action,
  }) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: DesignTokens.fontSummary, height: 1.35),
            ),
          ),
          if (action != null) ...[const SizedBox(width: DesignTokens.spacingSm), action],
        ],
      ),
    );
  }

  Widget _buildOriginalAction(String text, VoidCallback onPressed) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: scheme.onPrimary,
        backgroundColor: scheme.primary,
        minimumSize: const Size(0, 24),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DesignTokens.actionRadius)),
      ),
      child: Text(text, style: TextStyle(fontSize: DesignTokens.fontSummary, height: 1)),
    );
  }

  Widget _buildIntroContent(Color color) {
    final intro = _book!.displayIntro;
    if (intro.isEmpty) {
      return Text('暂无简介', style: TextStyle(color: color));
    }
    return _buildFullIntro(intro);
  }

  String _chapterSummaryText() {
    if (_chapters.isEmpty) {
      return '加载中';
    }
    if (_book!.durChapterTitle.isNotEmpty) {
      return _book!.durChapterTitle;
    }
    return '共 ${_chapters.length} 章';
  }

  String _readRecordSummaryText() {
    if (_book!.durChapterTitle.isNotEmpty) {
      final index = _book!.durChapterIndex + 1;
      final total = _chapters.isNotEmpty
          ? _chapters.length
          : (_book!.totalChapterNum ?? 0);
      if (total > 0) {
        return '$index/$total章 · ${_book!.durChapterTitle}';
      }
      return _book!.durChapterTitle;
    }
    return '暂无阅读记录';
  }

  /// 构建详情页封面 - 接入封面配置
  Widget _buildDetailCover() {
    final coverConfig = CoverConfigService.instance;
    final isDark =
        context.watch<AppProvider>().themeMode == ThemeMode.dark ||
        (context.watch<AppProvider>().themeMode == ThemeMode.system &&
            MediaQuery.of(context).platformBrightness == Brightness.dark);
    final useDefault = coverConfig.useDefaultCover;
    final coverUrl = _book!.displayCoverUrl;

    if (useDefault) {
      return coverConfig.buildDefaultCoverPlaceholder(
        bookName: _book!.displayName,
        bookAuthor: _book!.displayAuthor,
        isDark: isDark,
      );
    }

    if (coverUrl.isNotEmpty) {
      final memCacheWidth = coverConfig.loadCoverHighQuality ? null : 240;
      final maxWidthDiskCache = coverConfig.loadCoverHighQuality ? null : 320;
      return CachedNetworkImage(
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        memCacheWidth: memCacheWidth,
        maxWidthDiskCache: maxWidthDiskCache,
        placeholder: (_, __) => coverConfig.buildDefaultCoverPlaceholder(
          bookName: _book!.displayName,
          bookAuthor: _book!.displayAuthor,
          isDark: isDark,
        ),
        errorWidget: (_, __, ___) => coverConfig.buildDefaultCoverPlaceholder(
          bookName: _book!.displayName,
          bookAuthor: _book!.displayAuthor,
          isDark: isDark,
        ),
      );
    }

    return coverConfig.buildDefaultCoverPlaceholder(
      bookName: _book!.displayName,
      bookAuthor: _book!.displayAuthor,
      isDark: isDark,
    );
  }

  Widget _buildAppBar() {
    final isOnline = _book!.originType == BookOriginType.online;
    const fg = Colors.white;

    return SliverAppBar(
      expandedHeight: DesignTokens.topBarHeight,
      pinned: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: fg,
      elevation: 0,
      title: const Text('书籍信息'),
      titleTextStyle: TextStyle(
        color: fg,
        fontSize: DesignTokens.fontTitle,
        fontWeight: FontWeight.w600,
      ),
      actions: [
        // 定制按钮（书源有定制按钮时才显示）
        if (_bookSource?.customButton == true)
          IconButton(
            icon: const Icon(Icons.album_outlined),
            tooltip: '定制',
            onPressed: _showCustomButton,
          ),
        // 编辑按钮（仅在书架中显示）
        if (_isInBookshelf)
          IconButton(
            icon: const Icon(Icons.edit_note),
            tooltip: '编辑',
            onPressed: _showBookEditSheet,
          ),
        // 分享按钮
        IconButton(
          icon: const Icon(Icons.share_outlined, size: 22),
          tooltip: '分享',
          onPressed: _shareBook,
        ),
        // 更多选项
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          offset: const Offset(0, 48),
          onSelected: (value) {
            switch (value) {
              case 'refresh':
                _refreshData();
                break;
              case 'login':
                _showSourceLogin();
                break;
              case 'top':
                _topBook();
                break;
              case 'set_source_variable':
                _showSetSourceVariable();
                break;
              case 'set_book_variable':
                _showSetBookVariable();
                break;
              case 'copy_book_url':
                _copyBookUrl();
                break;
              case 'copy_toc_url':
                _copyTocUrl();
                break;
              case 'can_update':
                _toggleCanUpdate();
                break;
              case 'delete_alert':
                _toggleDeleteAlert();
                break;
              case 'show_read_record':
                _toggleShowReadRecord();
                break;
              case 'clear_cache':
                _clearCache();
                break;
              case 'log':
                _showLog();
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'refresh',
              padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
              child: const Text('刷新'),
            ),
            if (isOnline)
              const PopupMenuItem(
                value: 'login',
                padding: EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
                child: Text('登录'),
              ),
            if (_isInBookshelf)
              PopupMenuItem(
                value: 'top',
                padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.spacingLg,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('置顶')),
                    _buildCheckbox(_book!.isTop, fg),
                  ],
                ),
              ),
            if (isOnline)
              const PopupMenuItem(
                value: 'set_source_variable',
                padding: EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
                child: Text('设置源变量'),
              ),
            const PopupMenuItem(
              value: 'set_book_variable',
              padding: EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
              child: Text('设置书籍变量'),
            ),
            const PopupMenuItem(
              value: 'copy_book_url',
              padding: EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
              child: Text('拷贝书籍URL'),
            ),
            if (_book!.tocUrl?.isNotEmpty == true)
              const PopupMenuItem(
                value: 'copy_toc_url',
                padding: EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
                child: Text('拷贝目录URL'),
              ),
            if (isOnline)
              PopupMenuItem(
                value: 'can_update',
                padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.spacingLg,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('允许更新')),
                    _buildCheckbox(_book!.canUpdate, fg),
                  ],
                ),
              ),
            if (_isInBookshelf)
              PopupMenuItem(
                value: 'delete_alert',
                padding: const EdgeInsets.symmetric(
                  horizontal: DesignTokens.spacingLg,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('删除提醒')),
                    _buildCheckbox(_book!.deleteAlert ?? false, fg),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'show_read_record',
              padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
              child: Row(
                children: [
                  const Expanded(child: Text('显示阅读记录')),
                  _buildCheckbox(_showReadRecord, fg),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'clear_cache',
              padding: EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
              child: Text('清理缓存'),
            ),
            const PopupMenuItem(
              value: 'log',
              padding: EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
              child: Text('日志'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCheckbox(bool checked, Color fg) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        border: Border.all(
          color: checked
              ? Theme.of(context).colorScheme.primary
              : fg.withValues(alpha: 0.5),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
        color: checked
            ? Theme.of(context).colorScheme.primary
            : Colors.transparent,
      ),
      child: checked
          ? Icon(
              Icons.check,
              size: 14,
              color: Theme.of(context).colorScheme.onPrimary,
            )
          : null,
    );
  }

  String _getGroupName() {
    if (_book!.originType == BookOriginType.local) {
      return '本地无分组';
    }
    return _book!.groupId ?? '无分组';
  }

  void _showChangeSourceDialog() {
    if (_book == null) return;

    ChangeSourceSheet.show(
      context: context,
      bookName: _book!.displayName,
      bookAuthor: _book!.displayAuthor,
      currentSourceUrl: _book!.sourceUrl,
      currentSourceName: _book!.sourceName,
      onSourceSelected: (sourceUrl, sourceName, bookData) async {
        // 切换书源
        if (_book == null) return;

        try {
          // 显示加载提示
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('正在获取目录...')));

          // 创建新的书籍对象
          final newBook = _book!.copyWith(
            sourceUrl: sourceUrl,
            sourceName: sourceName,
            bookUrl: bookData['bookUrl'] ?? _book!.bookUrl,
            name: bookData['name'] ?? _book!.name,
            author: bookData['author'] ?? _book!.author,
            coverUrl: bookData['coverUrl'] ?? _book!.coverUrl,
            intro: bookData['intro'] ?? _book!.intro,
            lastChapter: bookData['lastChapter'] ?? _book!.lastChapter,
          );

          // 获取新书源的目录
          _dataProvider = createBookDataProvider(newBook);
          final chapters = await _dataProvider!.getChapterList(newBook);

          if (!mounted) return;

          // 更新书籍
          final updatedBook = newBook.copyWith(
            totalChapterNum: chapters.length,
          );

          // 保存到书架
          if (_isInBookshelf) {
            StorageService.instance.addToBookshelf(updatedBook.toJson());
            final provider = context.read<BookshelfProvider>();
            provider.loadBooks();
          }

          // 更新状态
          setState(() {
            _book = updatedBook;
            _chapters = chapters;
            _totalWordCount = chapters.fold<int>(
              0,
              (sum, ch) => sum + (ch.wordCount ?? 0),
            );
          });

          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('已切换到 $sourceName')));
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('换源失败: $e')));
          }
        }
      },
    );
  }

  void _showChangeGroupDialog() {
    final bookshelfProvider = context.read<BookshelfProvider>();
    final groups = bookshelfProvider.getAllGroups();
    final defaultGroups = ['全部', '本地', '小说', '音频', '漫画', '视频'];
    String selectedGroup = _book!.groupId ?? '全部';

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
                        padding: const EdgeInsets.symmetric(
                          horizontal: DesignTokens.spacingLg,
                          vertical: 16,
                        ),
                        child: Text(
                          '选择分组',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: DesignTokens.fontTitle,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.add,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                      tooltip: '添加分组',
                      onPressed: () {
                        Navigator.pop(context);
                        _showCreateGroupDialog(bookshelfProvider);
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
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      final isDefault = defaultGroups.contains(group);
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
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
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            // 编辑按钮（仅自定义分组）
                            if (!isDefault)
                              TextButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  _showEditGroupDialog(
                                    bookshelfProvider,
                                    group,
                                  );
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
                padding: const EdgeInsets.only(right: DesignTokens.spacingLg, bottom: DesignTokens.spacingSm),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        // 更新分组
                        final newGroupId = selectedGroup == '全部'
                            ? null
                            : selectedGroup;
                        final updatedBook = _book!.copyWith(
                          groupId: newGroupId,
                        );
                        await StorageService.instance.addToBookshelf(
                          updatedBook.toJson(),
                        );
                        if (!mounted) return;
                        setState(() {
                          _book = updatedBook;
                        });
                        // 刷新书架
                        bookshelfProvider.loadBooks();
                      },
                      child: Text(
                        '确定',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                        ),
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

  void _showCreateGroupDialog(BookshelfProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入分组名称'),
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
                if (!mounted) return;
                Navigator.pop(context);
                if (!success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('分组已达上限(64个)或名称已存在')),
                  );
                }
                // 重新打开分组选择对话框
                _showChangeGroupDialog();
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
          decoration: const InputDecoration(hintText: '输入分组名称'),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // 删除分组
              await provider.removeCustomGroup(oldName);
              if (!mounted) return;
              // 重新打开分组选择对话框
              _showChangeGroupDialog();
            },
            child: Text(
              '删除',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (controller.text.isNotEmpty && controller.text != oldName) {
                final success = await provider.renameCustomGroup(
                  oldName,
                  controller.text,
                );
                if (!mounted) return;
                Navigator.pop(context);
                if (!success) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('分组名称已存在')));
                }
                // 重新打开分组选择对话框
                _showChangeGroupDialog();
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

  void _showReadRecordDialog() {
    if (_book == null) return;
    Navigator.pushNamed(
      context,
      AppRoutes.readRecord,
      arguments: {'bookUrl': _book!.bookUrl},
    );
  }

  void _showDownloadDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载当前章节'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline),
              title: const Text('下载后续50章'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_download),
              title: const Text('下载全本'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatWordCount(int count) {
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)}万字';
    }
    return '${count}字';
  }

  Widget _buildBottomActionBar() {
    final scheme = Theme.of(context).colorScheme;
    final canRead = _chapters.isNotEmpty;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: _toggleBookshelf,
                child: SizedBox(
                  height: DesignTokens.bottomBarHeight,
                  child: Center(
                    child: Text(
                      _isInBookshelf ? '移出书架' : '放入书架',
                      style: TextStyle(fontSize: DesignTokens.fontBody, color: scheme.onSurface),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Material(
                color: canRead
                    ? scheme.primary
                    : scheme.primary.withValues(alpha: 0.4),
                child: InkWell(
                  onTap: canRead ? _startReading : null,
                  child: SizedBox(
                    height: DesignTokens.bottomBarHeight,
                    child: Center(
                      child: Text(
                        '阅读',
                        style: TextStyle(
                          fontSize: DesignTokens.fontBody,
                          fontWeight: FontWeight.w600,
                          color: scheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 检测内容是否包含HTML标签（用于决定是否用Html widget渲染）
  /// 支持两种情况：
  /// 1. 以<开头的纯HTML内容
  /// 2. 混合内容（纯文本+HTML标签，如模板规则返回的结果）
  static final RegExp _htmlTagPattern = RegExp(
    r'<(a|abbr|address|article|aside|b|blockquote|br|caption|cite|code|col|dd|del|details|div|dl|dt|em|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|i|img|input|ins|label|legend|li|main|mark|nav|ol|optgroup|option|p|pre|section|select|small|source|span|strong|sub|summary|sup|table|tbody|td|textarea|tfoot|th|thead|time|tr|u|ul|video)\b[^/>]*/?>',
    caseSensitive: false,
  );

  bool _isHtmlContent(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    // 快速路径：以<开头且包含闭合标签
    if (trimmed.startsWith('<') &&
        (trimmed.contains('</') || trimmed.contains('/>'))) {
      return true;
    }
    // 混合内容：检测是否包含有意义的HTML标签
    return _htmlTagPattern.hasMatch(trimmed);
  }

  bool _isMarkdownContent(String text) {
    int count = 0;
    if (RegExp(r'^#{1,6}\s', multiLine: true).hasMatch(text)) count++;
    if (RegExp(r'\*\*[^*]+\*\*').hasMatch(text)) count++;
    if (RegExp(r'(?<!\*)\*[^*]+\*(?!\*)').hasMatch(text)) count++;
    if (RegExp(r'^\s*[-*+]\s', multiLine: true).hasMatch(text)) count++;
    if (RegExp(r'\[.*?\]\(.*?\)').hasMatch(text)) count++;
    if (RegExp(r'```').hasMatch(text)) count++;
    if (RegExp(r'^>', multiLine: true).hasMatch(text)) count++;
    return count >= 2;
  }

  Widget _buildFullIntro(String text) {
    if (_isHtmlContent(text)) {
      return Html(
        data: text,
        style: {
          'body': Style(color: Theme.of(context).colorScheme.onSurfaceVariant),
        },
      );
    } else if (_isMarkdownContent(text)) {
      return MarkdownBody(data: text, selectable: true);
    } else {
      return Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
  }

  Future<void> _toggleBookshelf() async {
    if (_book == null) return;
    final provider = context.read<BookshelfProvider>();
    if (_isInBookshelf) {
      if (_book!.deleteAlert ?? false) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('确认移除'),
            content: Text('确定从书架移除《${_book!.displayName}》吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      await provider.removeFromBookshelf(_book!.bookUrl);
      if (!mounted) return;
      setState(() {
        _isInBookshelf = false;
      });
    } else {
      await provider.addToBookshelf(_book!);
      if (!mounted) return;
      setState(() {
        _isInBookshelf = true;
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isInBookshelf ? '已加入书架' : '已从书架移除'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 参照 Legado 路由优先级：video → audio → comic → novel
  String _readerRouteName() {
    final mediaType = _book?.mediaType;
    if (mediaType == MediaType.video) return AppRoutes.videoPlayer;
    if (mediaType == MediaType.audio) return AppRoutes.audioPlayer;
    if (mediaType == MediaType.comic) return AppRoutes.comicReader;
    return AppRoutes.novelReader;
  }

  Future<void> _startReading() async {
    if (_chapters.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('目录为空，无法开始阅读')));
      return;
    }
    await Navigator.pushNamed(
      context,
      _readerRouteName(),
      arguments: {
        'bookUrl': widget.bookUrl,
        'bookId': widget.bookUrl,
        'chapterIndex': _book?.durChapterIndex ?? 0,
        'trackId': (_book?.durChapterIndex ?? 0).toString(),
        'episodeId': (_book?.durChapterIndex ?? 0).toString(),
        'resumeProgress': true,
        'bookData': _book,
      },
    );
    if (mounted) {
      await _loadData();
    }
  }

  Future<void> _openFullChapterList() async {
    await Navigator.pushNamed(
      context,
      AppRoutes.chapterList,
      arguments: {
        'bookUrl': widget.bookUrl,
        'bookData': _book,
        'currentChapterIndex': _book?.durChapterIndex ?? 0,
      },
    );
    if (mounted) {
      await _loadData();
    }
  }

  void _showBookEditSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => BookEditSheet(book: _book!, onSaved: _refreshData),
    );
  }

  String get _displayWordCount {
    if (_book?.wordCount?.trim().isNotEmpty == true) {
      final value = _book!.wordCount!.trim();
      // 如果已经包含单位，直接返回
      if (RegExp(r'(字|词|页|P|p)$').hasMatch(value)) {
        return value;
      }
      // 如果是纯数字，按字数格式化（万字/字）
      final numValue = int.tryParse(value);
      if (numValue != null) {
        return _formatWordCount(numValue);
      }
      return '$value字';
    }
    return _totalWordCount > 0 ? _formatWordCount(_totalWordCount) : '';
  }

  void _shareBook() {
    if (_book == null) return;
    final shareText =
        '${_book!.displayName}\n作者：${_book!.displayAuthor}\n来源：${_book!.sourceName ?? "本地"}\n链接：${_book!.bookUrl}';
    Clipboard.setData(ClipboardData(text: shareText));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('书籍信息已复制到剪贴板')));
  }

  void _searchBookName() async {
    if (_book == null) return;

    // 执行书源回调，如果返回true则不执行默认操作
    final handled = await _executeSourceCallback(
      'clickBookName',
      result: _book!.displayName,
    );

    if (!handled && mounted) {
      // 跳转到搜索页面搜索书名
      Navigator.pushNamed(
        context,
        AppRoutes.search,
        arguments: {'keyword': _book!.displayName},
      );
    }
  }

  void _copyBookName() async {
    if (_book == null) return;

    // 执行书源回调
    final handled = await _executeSourceCallback(
      'longClickBookName',
      result: _book!.displayName,
    );

    if (!handled && mounted) {
      Clipboard.setData(ClipboardData(text: _book!.displayName));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('书名已复制')));
    }
  }

  void _searchAuthor() async {
    if (_book == null) return;

    // 执行书源回调
    final handled = await _executeSourceCallback(
      'clickAuthor',
      result: _book!.displayAuthor,
    );

    if (!handled && mounted) {
      // 跳转到搜索页面搜索作者
      Navigator.pushNamed(
        context,
        AppRoutes.search,
        arguments: {'keyword': _book!.displayAuthor},
      );
    }
  }

  void _copyAuthor() async {
    if (_book == null) return;

    // 执行书源回调
    final handled = await _executeSourceCallback(
      'longClickAuthor',
      result: _book!.displayAuthor,
    );

    if (!handled && mounted) {
      Clipboard.setData(ClipboardData(text: _book!.displayAuthor));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('作者已复制')));
    }
  }

  /// 执行书源回调
  /// 返回 true 表示回调已处理，不需要执行默认操作
  Future<bool> _executeSourceCallback(String event, {String? result}) async {
    if (_bookSource == null || !_bookSource!.eventListener) {
      return false;
    }

    final callBackJs = _bookSource!.ruleContent?.callBackJs;
    if (callBackJs == null || callBackJs.isEmpty) {
      return false;
    }

    try {
      // TODO: 实现JS执行
      // 参考 SourceCallBack.callBackBtn
      // 执行JS: source.evalJS(jsStr) { put("event", event); put("result", result); put("book", book); }
      // 如果返回 "true"，则不执行默认操作

      debugPrint('执行书源回调: $event, result: $result');
      // 目前先返回false，执行默认操作
      return false;
    } catch (e) {
      debugPrint('执行书源回调失败: $e');
      return false;
    }
  }

  void _editSource() {
    if (_book == null) return;
    if (_book!.originType == BookOriginType.local) return;
    if (_book!.sourceUrl == null) return;

    // 跳转到书源编辑页面
    Navigator.pushNamed(
      context,
      AppRoutes.bookSourceEdit,
      arguments: {'sourceUrl': _book!.sourceUrl},
    );
  }

  void _copyBookUrl() {
    if (_book == null) return;
    Clipboard.setData(ClipboardData(text: _book!.bookUrl));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('书籍链接已复制')));
  }

  void _copyTocUrl() {
    if (_book == null || _book!.tocUrl == null) return;
    Clipboard.setData(ClipboardData(text: _book!.tocUrl!));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('目录链接已复制')));
  }

  void _clearCache() async {
    if (_book == null) return;
    try {
      await ChapterCacheService.instance.clearBookCache(_book!);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('缓存已清除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清除缓存失败：$e')));
      }
    }
  }

  void _topBook() {
    if (_book == null) return;
    final newTop = !_book!.isTop;
    final provider = context.read<BookshelfProvider>();
    if (_isInBookshelf) {
      provider.toggleTop(_book!.bookUrl);
    }
    _book = _book!.copyWith(isTop: newTop);
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(newTop ? '已置顶' : '已取消置顶')));
  }

  void _toggleCanUpdate() {
    if (_book == null) return;
    final newValue = !_book!.canUpdate;
    _book = _book!.copyWith(canUpdate: newValue);
    if (_isInBookshelf) {
      StorageService.instance.addToBookshelf(_book!.toJson());
    }
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(newValue ? '已允许更新' : '已禁止更新')));
  }

  void _toggleDeleteAlert() {
    if (_book == null) return;
    final newValue = !(_book!.deleteAlert ?? false);
    _book = _book!.copyWith(deleteAlert: newValue);
    if (_isInBookshelf) {
      StorageService.instance.addToBookshelf(_book!.toJson());
    }
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(newValue ? '已开启删除提醒' : '已关闭删除提醒')));
  }

  Future<void> _toggleShowReadRecord() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _showReadRecord = !_showReadRecord;
    });
    await prefs.setBool('bookInfoShowReadRecord', _showReadRecord);
  }

  void _showCustomButton() async {
    // 检查书源是否有定制按钮
    if (_bookSource != null && _bookSource!.customButton) {
      // 书源有定制按钮，执行书源回调
      // TODO: 实现书源回调JS执行
      // 参考 SourceCallBack.callBackBtn
      final callBackJs = _bookSource!.ruleContent?.callBackJs;
      if (callBackJs != null && callBackJs.isNotEmpty) {
        // 执行回调JS
        try {
          // 这里需要执行JS并处理结果
          // 如果JS返回true，则不显示默认菜单
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('执行书源定制按钮回调...')));
          return;
        } catch (e) {
          debugPrint('执行定制按钮回调失败: $e');
        }
      }
    }

    // 没有书源定制按钮或回调返回false，显示默认菜单
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(DesignTokens.spacingLg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('定制按钮', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(DesignTokens.spacingLg),
                children: [
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('刷新目录'),
                    onTap: () {
                      Navigator.pop(context);
                      _refreshData();
                    },
                  ),
                  if (_book!.originType == BookOriginType.online)
                    ListTile(
                      leading: const Icon(Icons.swap_horiz),
                      title: const Text('换源'),
                      onTap: () {
                        Navigator.pop(context);
                        _showChangeSourceDialog();
                      },
                    ),
                  if (_book!.originType == BookOriginType.online)
                    ListTile(
                      leading: const Icon(Icons.download),
                      title: const Text('下载'),
                      onTap: () {
                        Navigator.pop(context);
                        _showDownloadDialog();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSourceLogin() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('登录功能开发中...')));
  }

  void _showSetSourceVariable() {
    if (_bookSource == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无书源信息，无法设置源变量')),
      );
      return;
    }
    final controller = TextEditingController(
      text: _bookSource!.variable ?? '',
    );
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置源变量'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '源变量可在JS中通过source.getVariable()获取',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text;
              Navigator.pop(context);
              final updated = _bookSource!.copyWith(variable: value);
              StorageService.instance.saveBookSource(updated.toJson());
              setState(() => _bookSource = updated);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('源变量已设置')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showSetBookVariable() {
    if (_book == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无书籍信息，无法设置书籍变量')),
      );
      return;
    }
    final storedData = StorageService.instance.getBook(_book!.bookUrl);
    final currentVariable =
        storedData != null ? (storedData['variable'] as String? ?? '') : '';
    final controller = TextEditingController(text: currentVariable);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置书籍变量'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '书籍变量可在书源规则中使用',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text;
              Navigator.pop(context);
              if (storedData != null) {
                storedData['variable'] = value;
                StorageService.instance.saveBook(storedData);
              }
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('书籍变量已设置')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showLog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(DesignTokens.spacingLg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('日志', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(DesignTokens.spacingLg),
                children: [
                  Text('书籍URL: ${_book?.bookUrl ?? "未知"}'),
                  const SizedBox(height: DesignTokens.spacingSm),
                  Text('书源: ${_book?.sourceName ?? "本地"}'),
                  const SizedBox(height: DesignTokens.spacingSm),
                  Text('章节数: ${_chapters.length}'),
                  const SizedBox(height: DesignTokens.spacingSm),
                  Text('当前章节: ${_book?.durChapterTitle ?? "无"}'),
                  const SizedBox(height: DesignTokens.spacingSm),
                  Text(
                    '阅读进度: ${_book?.durChapterIndex ?? 0}/${_chapters.length}',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookInfoArcClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path()
      ..moveTo(0, 36)
      ..quadraticBezierTo(size.width / 2, 0, size.width, 36)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

enum _BookLabelType { tag, status, wordCount }
