import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/read_record_service.dart';
import '../../routes/app_routes.dart';

enum DisplayMode { aggregate, timeline, latest, readTime }

class ReadRecordPage extends StatefulWidget {
  final String? bookUrl;

  const ReadRecordPage({super.key, this.bookUrl});

  @override
  State<ReadRecordPage> createState() => _ReadRecordPageState();
}

class _ReadRecordPageState extends State<ReadRecordPage> {
  final TextEditingController _searchController = TextEditingController();
  final _service = ReadRecordService.instance;
  
  String _searchKeyword = '';
  List<ReadRecord> _allRecords = [];
  List<ReadRecordSummary> _summaryRecords = [];
  bool _isLoading = true;
  int _totalReadTime = 0;
  int _todayReadTime = 0;
  
  bool _showSearch = false;
  DisplayMode _displayMode = DisplayMode.aggregate;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    setState(() => _isLoading = true);
    
    final allRecords = await _service.getAllRecords();
    final summaryRecords = await _service.getSummaryRecords();
    final totalReadTime = await _service.getTotalReadTime();
    final todayReadTime = await _service.getTodayReadTime();

    setState(() {
      _allRecords = allRecords;
      _summaryRecords = summaryRecords;
      _totalReadTime = totalReadTime;
      _todayReadTime = todayReadTime;
      _isLoading = false;
    });
  }

  void _toggleDisplayMode() {
    setState(() {
      _displayMode = DisplayMode.values[(_displayMode.index + 1) % DisplayMode.values.length];
    });
  }

  String _getDisplayModeName() {
    switch (_displayMode) {
      case DisplayMode.aggregate:
        return '聚合';
      case DisplayMode.timeline:
        return '时间线';
      case DisplayMode.latest:
        return '最近阅读';
      case DisplayMode.readTime:
        return '阅读时长';
    }
  }

  IconData _getDisplayModeIcon() {
    switch (_displayMode) {
      case DisplayMode.aggregate:
        return Icons.timeline;
      case DisplayMode.timeline:
        return Icons.view_timeline;
      case DisplayMode.latest:
        return Icons.schedule;
      case DisplayMode.readTime:
        return Icons.auto_awesome;
    }
  }

  Future<void> _deleteRecord(ReadRecordSummary record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除确认'),
        content: Text('确定要清除 "${record.bookName}" 的阅读记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _service.deleteRecordsByBook(record.bookName, record.bookAuthor);
      _loadRecords();
    }
  }

  Future<void> _deleteSingleRecord(ReadRecord record) async {
    await _service.deleteRecord(record.id);
    _loadRecords();
  }

  Future<void> _clearAllRecords() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除全部'),
        content: const Text('确定要清除所有阅读记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _service.clearAllRecords();
      _loadRecords();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('阅读记录'),
            Text(
              _getDisplayModeName(),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              setState(() => _showSearch = !_showSearch);
              if (!_showSearch) {
                _searchController.clear();
                setState(() => _searchKeyword = '');
              }
            },
            tooltip: '搜索',
          ),
          IconButton(
            icon: Icon(_getDisplayModeIcon()),
            onPressed: _toggleDisplayMode,
            tooltip: '切换视图',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'clear_all') {
                _clearAllRecords();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear_all',
                child: Text('清除全部记录'),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 搜索框
                if (_showSearch)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: '搜索书籍',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchKeyword.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchKeyword = '');
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      ),
                      onChanged: (value) => setState(() => _searchKeyword = value.trim().toLowerCase()),
                    ),
                  ),
                // 统计卡片
                _buildSummaryCard(),
                // 记录列表
                Expanded(
                  child: _buildContentByMode(),
                ),
              ],
            ),
    );
  }

  Widget _buildContentByMode() {
    switch (_displayMode) {
      case DisplayMode.aggregate:
        return _buildAggregateView();
      case DisplayMode.timeline:
        return _buildTimelineView();
      case DisplayMode.latest:
        return _buildLatestView();
      case DisplayMode.readTime:
        return _buildReadTimeView();
    }
  }

  Widget _buildSummaryCard() {
    final hours = _totalReadTime ~/ 3600;
    final minutes = (_totalReadTime % 3600) ~/ 60;
    final timeString = hours > 0 ? '$hours小时$minutes分钟' : '$minutes分钟';
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '阅读成就',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '已读 ',
                          style: TextStyle(
                            fontSize: 16,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        TextSpan(
                          text: '${_summaryRecords.length}',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        TextSpan(
                          text: ' 本',
                          style: TextStyle(
                            fontSize: 16,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '累计阅读 $timeString',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (_summaryRecords.isNotEmpty) _buildBookStack(),
          ],
        ),
      ),
    );
  }

  Widget _buildBookStack() {
    final displayRecords = _summaryRecords.take(3).toList();
    const double coverWidth = 48;
    const double coverHeight = 72;
    const double offsetStep = 12;
    final double stackWidth = coverWidth + offsetStep * (displayRecords.length - 1);
    
    return SizedBox(
      width: stackWidth,
      height: coverHeight,
      child: Stack(
        children: displayRecords.asMap().entries.map((entry) {
          final index = entry.key;
          final record = entry.value;
          final isEven = index % 2 == 0;
          
          return Positioned(
            left: offsetStep * index,
            child: Transform.rotate(
              angle: isEven ? 0.05 : -0.05,
              child: Container(
                width: coverWidth,
                height: coverHeight,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: record.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: record.coverUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _buildStackDefaultCover(),
                        )
                      : _buildStackDefaultCover(),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStackDefaultCover() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.book,
          size: 24,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  // 聚合视图 - 按日期分组
  Widget _buildAggregateView() {
    final filtered = _summaryRecords.where((r) {
      if (_searchKeyword.isEmpty) return true;
      return r.bookName.toLowerCase().contains(_searchKeyword) ||
          r.bookAuthor.toLowerCase().contains(_searchKeyword);
    }).toList();
    
    // 按日期分组
    final grouped = <String, List<ReadRecordSummary>>{};
    for (final record in filtered) {
      final date = _formatDate(record.lastReadTime);
      grouped.putIfAbsent(date, () => []).add(record);
    }
    
    final sortedDates = grouped.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    
    if (sortedDates.isEmpty) return _buildEmptyState();
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sortedDates.length,
      itemBuilder: (context, index) {
        final date = sortedDates[index];
        final records = grouped[date]!..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                date,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            ...records.map((r) => _buildSummaryItem(r)),
          ],
        );
      },
    );
  }

  // 时间线视图 - 显示每次阅读会话
  Widget _buildTimelineView() {
    final filtered = _allRecords.where((r) {
      if (_searchKeyword.isEmpty) return true;
      return r.bookName.toLowerCase().contains(_searchKeyword) ||
          r.bookAuthor.toLowerCase().contains(_searchKeyword);
    }).toList();
    
    if (filtered.isEmpty) return _buildEmptyState();
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        return _buildTimelineItem(filtered[index]);
      },
    );
  }

  // 最近阅读视图
  Widget _buildLatestView() {
    final filtered = _summaryRecords.where((r) {
      if (_searchKeyword.isEmpty) return true;
      return r.bookName.toLowerCase().contains(_searchKeyword) ||
          r.bookAuthor.toLowerCase().contains(_searchKeyword);
    }).toList()
      ..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
    
    if (filtered.isEmpty) return _buildEmptyState();
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildSummaryItem(filtered[index]),
    );
  }

  // 阅读时长视图
  Widget _buildReadTimeView() {
    final filtered = _summaryRecords.where((r) {
      if (_searchKeyword.isEmpty) return true;
      return r.bookName.toLowerCase().contains(_searchKeyword) ||
          r.bookAuthor.toLowerCase().contains(_searchKeyword);
    }).toList()
      ..sort((a, b) => b.totalReadTime.compareTo(a.totalReadTime));
    
    if (filtered.isEmpty) return _buildEmptyState();
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: filtered.length,
      itemBuilder: (context, index) => _buildSummaryItem(filtered[index], showReadTime: true),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            _searchKeyword.isNotEmpty ? '未找到匹配的记录' : '暂无阅读记录',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(ReadRecordSummary record, {bool showReadTime = false}) {
    return Dismissible(
      key: Key(record.bookUrl),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (direction) => _deleteRecord(record),
      child: InkWell(
        onTap: () {
          Navigator.pushNamed(context, AppRoutes.detail, arguments: {
            'bookUrl': record.bookUrl,
          });
        },
        onLongPress: () => _deleteRecord(record),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: record.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: record.coverUrl,
                          width: 44,
                          height: 60,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _buildDefaultCover(),
                        )
                      : _buildDefaultCover(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.bookName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        record.bookAuthor.isNotEmpty ? record.bookAuthor : '未知作者',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.schedule,
                            size: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatDuration(record.totalReadTime),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '·',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatDateTime(record.lastReadTime),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (showReadTime)
                  Text(
                    _formatDuration(record.totalReadTime),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineItem(ReadRecord record) {
    return Dismissible(
      key: Key(record.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (direction) => _deleteSingleRecord(record),
      child: InkWell(
        onTap: () {
          Navigator.pushNamed(context, AppRoutes.detail, arguments: {
            'bookUrl': record.bookUrl,
          });
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: record.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: record.coverUrl,
                          width: 44,
                          height: 60,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => _buildDefaultCover(),
                        )
                      : _buildDefaultCover(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.bookName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        record.chapterTitle.isNotEmpty 
                            ? record.chapterTitle 
                            : '第${record.chapterIndex + 1}章',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.schedule,
                            size: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatDuration(record.readTime),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(record.startTime),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDefaultCover() {
    return Container(
      width: 44,
      height: 60,
      color: Colors.grey[300],
      child: const Icon(Icons.book, size: 20),
    );
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) {
      return '$seconds秒';
    } else if (seconds < 3600) {
      return '${seconds ~/ 60}分钟';
    } else {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      if (minutes == 0) {
        return '$hours小时';
      }
      return '$hours小时$minutes分钟';
    }
  }

  String _formatDateTime(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inDays == 0) {
      return '今天 ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return '昨天';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      return '${time.month}/${time.day}';
    }
  }

  String _formatDate(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final recordDate = DateTime(time.year, time.month, time.day);
    
    if (recordDate == today) {
      return '今天';
    } else if (recordDate == yesterday) {
      return '昨天';
    } else {
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
    }
  }

  String _formatTime(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
