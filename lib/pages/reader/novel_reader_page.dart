import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../providers/reader_provider.dart';
import '../../providers/bookshelf_provider.dart';
import '../../services/local_book/local_book_service.dart';
import '../../services/storage_service.dart';

class NovelReaderPage extends StatefulWidget {
  final String bookUrl;
  final int chapterIndex;

  const NovelReaderPage({
    super.key,
    required this.bookUrl,
    this.chapterIndex = 0,
  });

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  bool _showMenu = false;
  String _content = '';
  String _chapterTitle = '';
  int _currentChapterIndex = 0;
  int _totalChapters = 0;
  bool _isLoading = true;
  Book? _book;
  List<Chapter> _chapters = [];

  String? _prevContent;
  String? _nextContent;

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.chapterIndex;
    _loadBookAndChapters();
  }

  Future<void> _loadBookAndChapters() async {
    final bookData = StorageService.instance.getBook(widget.bookUrl);
    if (bookData != null) {
      _book = Book.fromJson(bookData);
      _chapters = await LocalBookService.instance.getChapterList(_book!);
      _totalChapters = _chapters.length;
      _currentChapterIndex = _book!.durChapterIndex.clamp(0, _totalChapters - 1);
    }
    await _loadChapterContent();
  }

  Future<void> _loadChapterContent() async {
    if (_book == null || _chapters.isEmpty) {
      setState(() {
        _isLoading = false;
        _content = '无法加载内容';
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final chapter = _currentChapterIndex < _chapters.length
        ? _chapters[_currentChapterIndex]
        : null;

    if (chapter == null) {
      setState(() {
        _isLoading = false;
        _content = '章节不存在';
      });
      return;
    }

    final content = await LocalBookService.instance.getContent(_book!, chapter);

    _preloadAdjacentChapters();

    if (mounted) {
      setState(() {
        _chapterTitle = chapter.title;
        _content = content ?? '内容加载失败';
        _isLoading = false;
      });

      context.read<BookshelfProvider>().updateBookProgress(
        widget.bookUrl,
        durChapterIndex: _currentChapterIndex,
        durChapterTitle: chapter.title,
      );
    }
  }

  Future<void> _preloadAdjacentChapters() async {
    if (_book == null) return;

    if (_currentChapterIndex > 0) {
      final prevChapter = _chapters[_currentChapterIndex - 1];
      _prevContent = await LocalBookService.instance.getContent(_book!, prevChapter);
    }

    if (_currentChapterIndex < _totalChapters - 1) {
      final nextChapter = _chapters[_currentChapterIndex + 1];
      _nextContent = await LocalBookService.instance.getContent(_book!, nextChapter);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.watch<ReaderProvider>().backgroundColor,
      body: GestureDetector(
        onTap: _toggleMenu,
        child: Stack(
          children: [
            _buildContent(),
            if (_showMenu) _buildMenu(),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final provider = context.watch<ReaderProvider>();

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SafeArea(
      child: Column(
        children: [
          if (_showMenu)
            Container(
              height: kToolbarHeight,
              color: Theme.of(context).colorScheme.surface,
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_prevContent != null) ...[
                    SelectableText(
                      _formatContent(_prevContent!),
                      style: TextStyle(
                        fontSize: provider.fontSize,
                        color: provider.textColor,
                        height: provider.lineHeight,
                      ),
                    ),
                    const Divider(),
                  ],
                  Text(
                    _chapterTitle,
                    style: TextStyle(
                      fontSize: provider.fontSize + 4,
                      fontWeight: FontWeight.bold,
                      color: provider.textColor,
                      height: provider.lineHeight,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SelectableText(
                    _formatContent(_content),
                    style: TextStyle(
                      fontSize: provider.fontSize,
                      color: provider.textColor,
                      height: provider.lineHeight,
                    ),
                  ),
                  if (_nextContent != null) ...[
                    const Divider(),
                    Text(
                      _chapters[_currentChapterIndex + 1].title,
                      style: TextStyle(
                        fontSize: provider.fontSize + 4,
                        fontWeight: FontWeight.bold,
                        color: provider.textColor,
                        height: provider.lineHeight,
                      ),
                    ),
                    const SizedBox(height: 24),
                    SelectableText(
                      _formatContent(_nextContent!),
                      style: TextStyle(
                        fontSize: provider.fontSize,
                        color: provider.textColor,
                        height: provider.lineHeight,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_showMenu)
            Container(
              height: 80,
              color: Theme.of(context).colorScheme.surface,
            ),
        ],
      ),
    );
  }

  String _formatContent(String content) {
    return content
        .split(RegExp(r'\n'))
        .map((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return '';
          return '\u3000\u3000$trimmed';
        })
        .join('\n');
  }

  Widget _buildMenu() {
    return Column(
      children: [
        _buildTopBar(),
        const Spacer(),
        _buildBottomBar(),
      ],
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                _chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.list),
              onPressed: _showChapterList,
            ),
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _showMoreOptions,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressSlider(),
            _buildSettingsButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSlider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            '${_currentChapterIndex + 1}',
            style: const TextStyle(fontSize: 12),
          ),
          Expanded(
            child: Slider(
              value: _totalChapters > 0 ? _currentChapterIndex.toDouble() : 0,
              min: 0,
              max: (_totalChapters - 1).clamp(0, 999999).toDouble(),
              onChanged: (value) {
                setState(() {
                  _currentChapterIndex = value.toInt();
                });
                _loadChapterContent();
              },
            ),
          ),
          Text(
            '$_totalChapters',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsButtons() {
    final provider = context.read<ReaderProvider>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.format_size),
            onPressed: () => _showFontSizeDialog(provider),
            tooltip: '字体大小',
          ),
          IconButton(
            icon: const Icon(Icons.line_weight),
            onPressed: () => _showLineHeightDialog(provider),
            tooltip: '行距',
          ),
          IconButton(
            icon: const Icon(Icons.palette),
            onPressed: () => _showBackgroundColorDialog(provider),
            tooltip: '背景色',
          ),
          IconButton(
            icon: Icon(
              provider.isNightMode ? Icons.light_mode : Icons.dark_mode,
            ),
            onPressed: provider.toggleNightMode,
            tooltip: '夜间模式',
          ),
          IconButton(
            icon: const Icon(Icons.brightness_6),
            onPressed: () => _showBrightnessDialog(provider),
            tooltip: '亮度',
          ),
        ],
      ),
    );
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
  }

  void _previousChapter() {
    if (_currentChapterIndex > 0) {
      setState(() {
        _currentChapterIndex--;
      });
      _loadChapterContent();
    }
  }

  void _nextChapter() {
    if (_currentChapterIndex < _totalChapters - 1) {
      setState(() {
        _currentChapterIndex++;
      });
      _loadChapterContent();
    }
  }

  void _showChapterList() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '目录',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: _totalChapters,
                  itemBuilder: (context, index) {
                    final chapter = index < _chapters.length ? _chapters[index] : null;
                    return ListTile(
                      title: Text(chapter?.title ?? '第${index + 1}章'),
                      selected: index == _currentChapterIndex,
                      onTap: () {
                        setState(() {
                          _currentChapterIndex = index;
                        });
                        _loadChapterContent();
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoreOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_book?.originType == BookOriginType.online)
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('缓存本章'),
                  onTap: () {
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showFontSizeDialog(ReaderProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('字体大小'),
          content: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: provider.fontSize,
                    min: 12,
                    max: 32,
                    divisions: 20,
                    onChanged: (value) {
                      provider.setFontSize(value);
                    },
                  ),
                  Text('${provider.fontSize.toInt()}'),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showLineHeightDialog(ReaderProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('行距'),
          content: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: provider.lineHeight,
                    min: 1.0,
                    max: 3.0,
                    divisions: 20,
                    onChanged: (value) {
                      provider.setLineHeight(value);
                    },
                  ),
                  Text(provider.lineHeight.toStringAsFixed(1)),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showBackgroundColorDialog(ReaderProvider provider) {
    final colors = [
      const Color(0xFFFFF8E1),
      const Color(0xFFE8F5E9),
      const Color(0xFFE3F2FD),
      const Color(0xFFFFF3E0),
      const Color(0xFFF3E5F5),
      const Color(0xFF1A1A1A),
    ];

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('背景色'),
          content: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: colors.map((color) {
              return GestureDetector(
                onTap: () {
                  provider.setBackgroundColor(color);
                  Navigator.pop(context);
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: provider.backgroundColor == color
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                      width: 2,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }

  void _showBrightnessDialog(ReaderProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('亮度'),
          content: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: provider.brightness,
                    min: 0.1,
                    max: 1.0,
                    onChanged: (value) {
                      provider.setBrightness(value);
                    },
                  ),
                  Text('${(provider.brightness * 100).toInt()}%'),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }
}
