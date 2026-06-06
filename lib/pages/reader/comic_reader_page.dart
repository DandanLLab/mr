import 'package:flutter/material.dart';

class ComicReaderPage extends StatefulWidget {
  final String bookId;
  final String chapterId;

  const ComicReaderPage({
    super.key,
    required this.bookId,
    required this.chapterId,
  });

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  bool _showMenu = false;
  int _currentChapterIndex = 0;
  final int _totalChapters = 50;
  String _chapterTitle = '';
  List<String> _images = [];
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadChapter();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadChapter() async {
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() {
      _chapterTitle = '第${_currentChapterIndex + 1}话';
      _images = List.generate(20, (index) => 'image_$index');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
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
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (_showMenu)
          SliverToBoxAdapter(
            child: Container(
              height: kToolbarHeight,
              color: Colors.black.withValues(alpha: 0.7),
            ),
          ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              return _buildImageItem(index);
            },
            childCount: _images.length,
          ),
        ),
        if (_showMenu)
          SliverToBoxAdapter(
            child: Container(
              height: 80,
              color: Colors.black.withValues(alpha: 0.7),
            ),
          ),
      ],
    );
  }

  Widget _buildImageItem(int index) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        minHeight: 400,
      ),
      color: Colors.grey[900],
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.image,
              size: 64,
              color: Colors.white54,
            ),
            const SizedBox(height: 8),
            Text(
              '第 ${index + 1} 页',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
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
        color: Colors.black.withValues(alpha: 0.7),
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                _chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.list, color: Colors.white),
              onPressed: _showChapterList,
            ),
            IconButton(
              icon: const Icon(Icons.more_vert, color: Colors.white),
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
        color: Colors.black.withValues(alpha: 0.7),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressSlider(),
            _buildNavigationButtons(),
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
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          Expanded(
            child: Slider(
              value: _currentChapterIndex.toDouble(),
              min: 0,
              max: (_totalChapters - 1).toDouble(),
              activeColor: Colors.white,
              inactiveColor: Colors.white54,
              onChanged: (value) {
                setState(() {
                  _currentChapterIndex = value.toInt();
                });
                _loadChapter();
              },
            ),
          ),
          Text(
            '$_totalChapters',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton.icon(
            onPressed: _previousChapter,
            icon: const Icon(Icons.chevron_left, color: Colors.white),
            label: const Text('上一话', style: TextStyle(color: Colors.white)),
          ),
          TextButton.icon(
            onPressed: _nextChapter,
            icon: const Icon(Icons.chevron_right, color: Colors.white),
            label: const Text('下一话', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.screen_rotation, color: Colors.white),
            onPressed: () {},
            tooltip: '屏幕方向',
          ),
          IconButton(
            icon: const Icon(Icons.brightness_6, color: Colors.white),
            onPressed: () {},
            tooltip: '亮度',
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in, color: Colors.white),
            onPressed: () {},
            tooltip: '缩放',
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
      _loadChapter();
    }
  }

  void _nextChapter() {
    if (_currentChapterIndex < _totalChapters - 1) {
      setState(() {
        _currentChapterIndex++;
      });
      _loadChapter();
    }
  }

  void _showChapterList() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (context) {
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '目录',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                      ),
                ),
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: ListView.builder(
                  itemCount: _totalChapters,
                  itemBuilder: (context, index) {
                    return ListTile(
                      title: Text(
                        '第${index + 1}话',
                        style: const TextStyle(color: Colors.white),
                      ),
                      selected: index == _currentChapterIndex,
                      selectedTileColor: Colors.white24,
                      onTap: () {
                        setState(() {
                          _currentChapterIndex = index;
                        });
                        _loadChapter();
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
      backgroundColor: Colors.grey[900],
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.download, color: Colors.white),
                title: const Text('缓存本话', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share, color: Colors.white),
                title: const Text('分享', style: TextStyle(color: Colors.white)),
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
}
