import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/read_record_service.dart';
import '../../services/cover_config_service.dart';
import '../../routes/app_routes.dart';
import '../../widgets/swipe_action_container.dart';

enum DisplayMode { aggregate, timeline, latest, readTime }
enum HeatmapMode { count, time }

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
  bool _enableReadRecord = true;
  bool _skipDeleteConfirm = false;
  
  // 日历相关
  DateTime _currentMonth = DateTime.now();
  DateTime? _selectedDate;
  HeatmapMode _heatmapMode = HeatmapMode.time;
  Map<DateTime, int> _dailyReadCounts = {};
  Map<DateTime, int> _dailyReadTimes = {};

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadRecords();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _enableReadRecord = prefs.getBool('enable_read_record') ?? true;
      _skipDeleteConfirm = prefs.getBool('skip_delete_confirm') ?? false;
      // 读取保存的显示模式
      final displayModeIndex = prefs.getInt('read_record_display_mode') ?? 0;
      _displayMode = DisplayMode.values[displayModeIndex.clamp(0, DisplayMode.values.length - 1)];
    });
  }

  Future<void> _toggleReadRecord() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _enableReadRecord = !_enableReadRecord;
    });
    await prefs.setBool('enable_read_record', _enableReadRecord);
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
    
    // 计算每日阅读次数和时长
    final dailyCounts = <DateTime, int>{};
    final dailyTimes = <DateTime, int>{};
    for (final record in allRecords) {
      final date = DateTime.fromMillisecondsSinceEpoch(record.startTime * 1000);
      final dateKey = DateTime(date.year, date.month, date.day);
      dailyCounts[dateKey] = (dailyCounts[dateKey] ?? 0) + 1;
      dailyTimes[dateKey] = (dailyTimes[dateKey] ?? 0) + record.readTime;
    }

    setState(() {
      _allRecords = allRecords;
      _summaryRecords = summaryRecords;
      _totalReadTime = totalReadTime;
      _todayReadTime = todayReadTime;
      _dailyReadCounts = dailyCounts;
      _dailyReadTimes = dailyTimes;
      _isLoading = false;
    });
  }

  Future<void> _toggleDisplayMode() async {
    setState(() {
      _displayMode = DisplayMode.values[(_displayMode.index + 1) % DisplayMode.values.length];
    });
    // 保存显示模式
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('read_record_display_mode', _displayMode.index);
  }

  String _getDisplayModeName() {
    switch (_displayMode) {
      case DisplayMode.aggregate:
        return '汇总视图';
      case DisplayMode.timeline:
        return '时间线视图';
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
    // 如果已设置跳过确认，直接删除
    if (_skipDeleteConfirm) {
      await _service.deleteRecordsByBook(record.bookName, record.bookAuthor);
      _loadRecords();
      return;
    }

    bool skipNextTime = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('确认删除'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('确定要删除这条阅读记录吗？'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: skipNextTime,
                    onChanged: (value) => setState(() => skipNextTime = value ?? false),
                  ),
                  const Text('不再提示'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                if (skipNextTime) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('skip_delete_confirm', true);
                  _skipDeleteConfirm = true;
                }
                Navigator.pop(context, true);
              },
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      await _service.deleteRecordsByBook(record.bookName, record.bookAuthor);
      _loadRecords();
    }
  }

  Future<void> _deleteSingleRecord(ReadRecord record) async {
    // 如果已设置跳过确认，直接删除
    if (_skipDeleteConfirm) {
      await _service.deleteRecord(record.id);
      _loadRecords();
      return;
    }

    bool skipNextTime = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('确认删除'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('确定要删除这条阅读记录吗？'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: skipNextTime,
                    onChanged: (value) => setState(() => skipNextTime = value ?? false),
                  ),
                  const Text('不再提示'),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                if (skipNextTime) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('skip_delete_confirm', true);
                  _skipDeleteConfirm = true;
                }
                Navigator.pop(context, true);
              },
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      await _service.deleteRecord(record.id);
      _loadRecords();
    }
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

  void _showCalendar() {
    // 重置为当前月份
    setState(() {
      _currentMonth = DateTime.now();
    });
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          return DraggableScrollableSheet(
            initialChildSize: 0.75,
            minChildSize: 0.5,
            maxChildSize: 0.85,
            expand: false,
            builder: (context, scrollController) => _buildCalendarSheet(
              scrollController,
              onDateSelected: (date) {
                setState(() {
                  _selectedDate = date;
                });
                Navigator.pop(sheetContext);
              },
              onModeChanged: (mode) {
                setSheetState(() {
                  _heatmapMode = mode;
                });
              },
              onMonthChanged: (month) {
                setSheetState(() {
                  _currentMonth = month;
                });
              },
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final appBarFg = ThemeData.estimateBrightnessForColor(primaryColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
          padding: EdgeInsets.zero,
        ),
        leadingWidth: 44,
        centerTitle: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('阅读记录', style: TextStyle(fontSize: 18)),
            Text(
              _getDisplayModeName(),
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                color: appBarFg.withValues(alpha: 0.6),
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
            icon: const Icon(Icons.calendar_month),
            onPressed: _showCalendar,
            tooltip: '阅读日历',
          ),
          IconButton(
            icon: Icon(_getDisplayModeIcon()),
            onPressed: _toggleDisplayMode,
            tooltip: '切换视图',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: '更多',
            offset: const Offset(0, 48),
            onSelected: (value) {
              if (value == 'toggle') {
                _toggleReadRecord();
              } else if (value == 'clear') {
                _clearAllRecords();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'toggle',
                child: Row(
                  children: [
                    Icon(_enableReadRecord ? Icons.visibility_off : Icons.visibility),
                    const SizedBox(width: 8),
                    Text(_enableReadRecord ? '关闭阅读记录' : '开启阅读记录'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Text('清除全部记录', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ),
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
                // 记录列表
                Expanded(
                  child: _buildContentByMode(),
                ),
              ],
            ),
    );
  }

  Widget _buildContentByMode() {
    // 根据选中日期过滤
    List<ReadRecord> filteredRecords = _allRecords;
    List<ReadRecordSummary> filteredSummaries = _summaryRecords;
    
    if (widget.bookUrl?.isNotEmpty == true) {
      filteredRecords =
          filteredRecords.where((r) => r.bookUrl == widget.bookUrl).toList();
      filteredSummaries = filteredSummaries
          .where((r) => r.bookUrl == widget.bookUrl)
          .toList();
    }
    
    if (_selectedDate != null) {
      filteredRecords = filteredRecords.where((r) {
        final date = DateTime.fromMillisecondsSinceEpoch(r.startTime * 1000);
        final dateKey = DateTime(date.year, date.month, date.day);
        return dateKey == _selectedDate;
      }).toList();
      
      // 重新计算汇总
      final summaryMap = <String, ReadRecordSummary>{};
      for (final record in filteredRecords) {
        final key = '${record.bookName}_${record.bookAuthor}';
        if (summaryMap.containsKey(key)) {
          final existing = summaryMap[key]!;
          summaryMap[key] = ReadRecordSummary(
            bookUrl: existing.bookUrl,
            bookName: existing.bookName,
            bookAuthor: existing.bookAuthor,
            coverUrl: existing.coverUrl,
            totalReadTime: existing.totalReadTime + record.readTime,
            firstReadTime: record.startTime < existing.firstReadTime ? record.startTime : existing.firstReadTime,
            lastReadTime: record.endTime > existing.lastReadTime ? record.endTime : existing.lastReadTime,
            readCount: existing.readCount + 1,
            lastChapterIndex: record.chapterIndex,
            lastChapterTitle: record.chapterTitle,
          );
        } else {
          summaryMap[key] = ReadRecordSummary(
            bookUrl: record.bookUrl,
            bookName: record.bookName,
            bookAuthor: record.bookAuthor,
            coverUrl: record.coverUrl,
            totalReadTime: record.readTime,
            firstReadTime: record.startTime,
            lastReadTime: record.endTime,
            readCount: 1,
            lastChapterIndex: record.chapterIndex,
            lastChapterTitle: record.chapterTitle,
          );
        }
      }
      filteredSummaries = summaryMap.values.toList();
    }
    
    // 搜索过滤
    if (_searchKeyword.isNotEmpty) {
      filteredRecords = filteredRecords.where((r) {
        return r.bookName.toLowerCase().contains(_searchKeyword) ||
            r.bookAuthor.toLowerCase().contains(_searchKeyword);
      }).toList();
      filteredSummaries = filteredSummaries.where((r) {
        return r.bookName.toLowerCase().contains(_searchKeyword) ||
            r.bookAuthor.toLowerCase().contains(_searchKeyword);
      }).toList();
    }
    
    if (filteredSummaries.isEmpty && filteredRecords.isEmpty) {
      return _buildEmptyState();
    }
    
    switch (_displayMode) {
      case DisplayMode.aggregate:
        return _buildAggregateView(filteredSummaries);
      case DisplayMode.timeline:
        return _buildTimelineView(filteredRecords);
      case DisplayMode.latest:
        return _buildLatestView(filteredSummaries);
      case DisplayMode.readTime:
        return _buildReadTimeView(filteredSummaries);
    }
  }

  Widget _buildSummaryCard() {
    final summaryRecords = widget.bookUrl?.isNotEmpty == true
        ? _summaryRecords.where((r) => r.bookUrl == widget.bookUrl).toList()
        : _summaryRecords;
    final totalReadTime = widget.bookUrl?.isNotEmpty == true
        ? _allRecords
            .where((r) => r.bookUrl == widget.bookUrl)
            .fold<int>(0, (sum, record) => sum + record.readTime)
        : _totalReadTime;
    final hours = totalReadTime ~/ 3600;
    final minutes = (totalReadTime % 3600) ~/ 60;
    final timeString = hours > 0 ? '$hours小时$minutes分钟' : '$minutes分钟';
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
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
                          text: '${summaryRecords.length}',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.secondary,
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
            if (summaryRecords.isNotEmpty) _buildBookStack(summaryRecords),
          ],
        ),
      ),
    );
  }

  Widget _buildBookStack(List<ReadRecordSummary> records) {
    final displayRecords = records.take(3).toList();
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
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: record.coverUrl.isNotEmpty && !CoverConfigService.instance.useDefaultCover
                      ? CachedNetworkImage(
                          imageUrl: record.coverUrl,
                          fit: BoxFit.cover,
                          cacheKey: record.coverUrl,
                          memCacheWidth: 100,
                          maxWidthDiskCache: 200,
                          placeholder: (_, __) => _buildStackDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
                          errorWidget: (_, __, ___) => _buildStackDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
                        )
                      : _buildStackDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildStackDefaultCover({String? bookName, String? bookAuthor}) {
    final coverConfig = CoverConfigService.instance;
    if (coverConfig.useDefaultCover && bookName != null && bookName.isNotEmpty) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return coverConfig.buildDefaultCoverPlaceholder(
        bookName: bookName,
        bookAuthor: bookAuthor,
        isDark: isDark,
      );
    }
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
  Widget _buildAggregateView(List<ReadRecordSummary> records) {
    // 按日期分组
    final grouped = <String, List<ReadRecordSummary>>{};
    for (final record in records) {
      final date = _formatDate(record.lastReadTime);
      grouped.putIfAbsent(date, () => []).add(record);
    }
    
    final sortedDates = grouped.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sortedDates.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildSummaryCard();
        
        final dateIndex = index - 1;
        final date = sortedDates[dateIndex];
        final dateRecords = grouped[date]!..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 日期头部
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    date,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                  Text(
                    _formatDuration(dateRecords.fold(0, (sum, r) => sum + r.totalReadTime)),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // 记录列表
            ...dateRecords.map((r) => _buildSummaryItem(r)),
          ],
        );
      },
    );
  }

  // 时间线视图 - 显示每次阅读会话
  Widget _buildTimelineView(List<ReadRecord> records) {
    // 按日期分组
    final grouped = <String, List<ReadRecord>>{};
    for (final record in records) {
      final date = _formatDateOnly(record.startTime);
      grouped.putIfAbsent(date, () => []).add(record);
    }
    
    final sortedDates = grouped.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sortedDates.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildSummaryCard();
        
        final dateIndex = index - 1;
        final date = sortedDates[dateIndex];
        final dateRecords = grouped[date]!..sort((a, b) => b.startTime.compareTo(a.startTime));
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 日期头部
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    date,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                  Text(
                    _formatDuration(dateRecords.fold(0, (sum, r) => sum + r.readTime)),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // 时间线记录
            ...dateRecords.asMap().entries.map((entry) {
              final idx = entry.key;
              final record = entry.value;
              final isFirst = idx == 0;
              final isLast = idx == dateRecords.length - 1;
              return _buildTimelineItem(record, isFirst, isLast);
            }),
          ],
        );
      },
    );
  }

  // 最近阅读视图
  Widget _buildLatestView(List<ReadRecordSummary> records) {
    records.sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: records.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildSummaryCard();
        return _buildLatestRecordItem(records[index - 1]);
      },
    );
  }

  Widget _buildLatestRecordItem(ReadRecordSummary record) {
    final content = InkWell(
      onTap: () {
        Navigator.pushNamed(context, AppRoutes.detail, arguments: {
          'bookUrl': record.bookUrl,
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: record.coverUrl.isNotEmpty && !CoverConfigService.instance.useDefaultCover
                    ? CachedNetworkImage(
                        imageUrl: record.coverUrl,
                        width: 44,
                        height: 60,
                        fit: BoxFit.cover,
                        cacheKey: record.coverUrl,
                        memCacheWidth: 100,
                        maxWidthDiskCache: 200,
                        placeholder: (_, __) => _buildDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
                        errorWidget: (_, __, ___) => _buildDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
                      )
                    : _buildDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
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
              // 三个点菜单
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: Theme.of(context).colorScheme.onSurfaceVariant),
              position: PopupMenuPosition.under,
              offset: const Offset(-8, 4),
              onSelected: (value) {
                if (value == 'delete') {
                  _deleteRecord(record);
                  } else if (value == 'merge') {
                    _showMergeDialog(record);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'merge',
                    child: Row(
                      children: [
                        Icon(Icons.merge),
                        SizedBox(width: 8),
                        Text('合并同名书籍'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                        const SizedBox(width: 8),
                        Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
      ),
    );

    return SwipeActionContainer(
      startActions: [createSwipeDeleteAction(context, () => _deleteRecord(record))],
      child: content,
    );
  }

  void _showMergeDialog(ReadRecordSummary record) {
    // 查找同名书籍
    final sameNameRecords = _summaryRecords.where((r) {
      return r.bookName == record.bookName && r.bookAuthor != record.bookAuthor;
    }).toList();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('合并同名书籍'),
        content: sameNameRecords.isEmpty
            ? const Text('没有找到可合并的同名书籍')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('将 "${record.bookName}" 与以下书籍合并：'),
                  const SizedBox(height: 8),
                  ...sameNameRecords.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('· ${r.bookName} - ${r.bookAuthor.isNotEmpty ? r.bookAuthor : "未知作者"}'),
                  )),
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (sameNameRecords.isNotEmpty)
            TextButton(
              onPressed: () async {
                // 合并阅读记录
                for (final r in sameNameRecords) {
                  await _service.mergeRecords(
                    sourceBookName: r.bookName,
                    sourceBookAuthor: r.bookAuthor,
                    targetBookName: record.bookName,
                    targetBookAuthor: record.bookAuthor,
                  );
                }
                Navigator.pop(context);
                _loadRecords();
              },
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('合并'),
            ),
        ],
      ),
    );
  }

  // 阅读时长视图
  Widget _buildReadTimeView(List<ReadRecordSummary> records) {
    records.sort((a, b) => b.totalReadTime.compareTo(a.totalReadTime));
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: records.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildSummaryCard();
        return _buildSummaryItem(records[index - 1], showReadTime: true);
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.menu_book,
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
    final content = InkWell(
      onTap: () {
        Navigator.pushNamed(context, AppRoutes.detail, arguments: {
          'bookUrl': record.bookUrl,
        });
      },
      onLongPress: () => _deleteRecord(record),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: record.coverUrl.isNotEmpty && !CoverConfigService.instance.useDefaultCover
                    ? CachedNetworkImage(
                        imageUrl: record.coverUrl,
                        width: 44,
                        height: 60,
                        fit: BoxFit.cover,
                        cacheKey: record.coverUrl,
                        memCacheWidth: 100,
                        maxWidthDiskCache: 200,
                        placeholder: (_, __) => _buildDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
                        errorWidget: (_, __, ___) => _buildDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
                      )
                    : _buildDefaultCover(bookName: record.bookName, bookAuthor: record.bookAuthor),
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
    );

    return SwipeActionContainer(
      startActions: [createSwipeDeleteAction(context, () => _deleteRecord(record))],
      child: content,
    );
  }

  Widget _buildTimelineItem(ReadRecord record, bool isFirst, bool isLast) {
    final timeFormat = '${record.startTime ~/ 3600 % 24}:${(record.startTime % 3600 ~/ 60).toString().padLeft(2, '0')}';
    
    final content = InkWell(
      onTap: () {
        Navigator.pushNamed(context, AppRoutes.detail, arguments: {
          'bookUrl': record.bookUrl,
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 时间线指示器
            SizedBox(
              width: 20,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // 上半部分线
                  if (!isFirst)
                    Positioned(
                      bottom: 7,
                      child: Container(
                        width: 2,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.secondary.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  // 下半部分线
                  if (!isLast)
                    Positioned(
                      top: 7,
                      child: Container(
                        width: 2,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.secondary.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  // 圆点
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Theme.of(context).colorScheme.secondary.withOpacity(0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 时间
            SizedBox(
              width: 48,
              child: Text(
                timeFormat,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 8),
            // 封面
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: record.coverUrl.isNotEmpty && !CoverConfigService.instance.useDefaultCover
                  ? CachedNetworkImage(
                      imageUrl: record.coverUrl,
                      width: 40,
                      height: 54,
                      fit: BoxFit.cover,
                      cacheKey: record.coverUrl,
                      memCacheWidth: 100,
                      maxWidthDiskCache: 200,
                      placeholder: (_, __) => _buildDefaultCover(size: 40, bookName: record.bookName, bookAuthor: record.bookAuthor),
                      errorWidget: (_, __, ___) => _buildDefaultCover(size: 40, bookName: record.bookName, bookAuthor: record.bookAuthor),
                    )
                  : _buildDefaultCover(size: 40, bookName: record.bookName, bookAuthor: record.bookAuthor),
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.bookName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    record.bookAuthor.isNotEmpty ? record.bookAuthor : '未知作者',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    record.chapterTitle.isNotEmpty ? record.chapterTitle : '第${record.chapterIndex + 1}章',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return SwipeActionContainer(
      startActions: [createSwipeDeleteAction(context, () => _deleteSingleRecord(record))],
      child: content,
    );
  }

  Widget _buildDefaultCover({double size = 44, String? bookName, String? bookAuthor}) {
    final coverConfig = CoverConfigService.instance;
    if (coverConfig.useDefaultCover && bookName != null && bookName.isNotEmpty) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return SizedBox(
        width: size,
        height: size * 60 / 44,
        child: coverConfig.buildDefaultCoverPlaceholder(
          bookName: bookName,
          bookAuthor: bookAuthor,
          isDark: isDark,
        ),
      );
    }
    return Container(
      width: size,
      height: size * 60 / 44,
      color: Colors.grey[300],
      child: Icon(Icons.book, size: size * 0.45),
    );
  }

  // 日历底部弹窗
  Widget _buildCalendarSheet(
    ScrollController controller, {
    required Function(DateTime?) onDateSelected,
    required Function(HeatmapMode) onModeChanged,
    required Function(DateTime) onMonthChanged,
  }) {
    return SingleChildScrollView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '阅读日历',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '记录你的阅读轨迹',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              // 模式切换
              Row(
                children: [
                  _buildModeChip('次数', _heatmapMode == HeatmapMode.count, () {
                    onModeChanged(HeatmapMode.count);
                  }),
                  const SizedBox(width: 4),
                  _buildModeChip('时长', _heatmapMode == HeatmapMode.time, () {
                    onModeChanged(HeatmapMode.time);
                  }),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 日历
          _buildCalendar(onDateSelected, onMonthChanged),
        ],
      ),
    );
  }

  Widget _buildCalendar(
    Function(DateTime?) onDateSelected,
    Function(DateTime) onMonthChanged,
  ) {
    final firstDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final lastDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);
    
    // 计算第一天是星期几（0=周一，6=周日）
    final firstWeekday = (firstDayOfMonth.weekday - 1) % 7;
    
    // 计算需要显示的天数
    final daysInMonth = lastDayOfMonth.day;
    final totalCells = ((firstWeekday + daysInMonth + 6) / 7).ceil() * 7;
    
    // 计算最大值用于热力图
    int maxValue = 1;
    for (final date in _dailyReadCounts.keys) {
      if (date.year == _currentMonth.year && date.month == _currentMonth.month) {
        final value = _heatmapMode == HeatmapMode.count
            ? (_dailyReadCounts[date] ?? 0)
            : ((_dailyReadTimes[date] ?? 0) ~/ 60);
        if (value > maxValue) maxValue = value;
      }
    }
    maxValue = maxValue.clamp(6, 120);
    
    // 计算月度统计
    int monthReadCount = 0;
    int monthReadTime = 0;
    int activeDays = 0;
    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_currentMonth.year, _currentMonth.month, day);
      final count = _dailyReadCounts[date] ?? 0;
      final time = _dailyReadTimes[date] ?? 0;
      monthReadCount += count;
      monthReadTime += time;
      if (count > 0 || time > 0) activeDays++;
    }
    
    return Column(
      children: [
        // 月份导航
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () {
                      onMonthChanged(DateTime(_currentMonth.year, _currentMonth.month - 1));
                    },
                  ),
                  Column(
                    children: [
                      Text(
                        '${_currentMonth.year}年${_currentMonth.month}月',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _heatmapMode == HeatmapMode.count ? '按阅读次数显示' : '按阅读时长显示',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () {
                      onMonthChanged(DateTime(_currentMonth.year, _currentMonth.month + 1));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 月度统计
              Row(
                children: [
                  _buildStatPill('阅读', '$monthReadCount次'),
                  const SizedBox(width: 8),
                  _buildStatPill('时长', _formatDuration(monthReadTime)),
                  const SizedBox(width: 8),
                  _buildStatPill('天数', '$activeDays天'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 星期标题
        Row(
          children: ['一', '二', '三', '四', '五', '六', '日'].map((day) {
            return Expanded(
              child: Text(
                day,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        // 日历网格
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: List.generate(totalCells, (index) {
            final dayOffset = index - firstWeekday;
            final isCurrentMonth = dayOffset >= 0 && dayOffset < daysInMonth;
            
            if (!isCurrentMonth) {
              // 非当前月份的日期
              DateTime date;
              if (dayOffset < 0) {
                // 上月末的日期
                final prevMonth = DateTime(_currentMonth.year, _currentMonth.month, 0);
                date = DateTime(prevMonth.year, prevMonth.month, prevMonth.day + dayOffset + 1);
              } else {
                // 下月初的日期
                date = DateTime(_currentMonth.year, _currentMonth.month + 1, dayOffset - daysInMonth + 1);
              }
              return _buildDayCell(
                date.day,
                0,
                maxValue,
                false,
                false,
                () {},
                isCurrentMonth: false,
              );
            }
            
            final day = dayOffset + 1;
            final date = DateTime(_currentMonth.year, _currentMonth.month, day);
            final today = DateTime.now();
            final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
            final isSelected = _selectedDate != null &&
                date.year == _selectedDate!.year &&
                date.month == _selectedDate!.month &&
                date.day == _selectedDate!.day;
            
            final value = _heatmapMode == HeatmapMode.count
                ? (_dailyReadCounts[date] ?? 0)
                : ((_dailyReadTimes[date] ?? 0) ~/ 60);
            
            return _buildDayCell(day, value, maxValue, isToday, isSelected, () {
              onDateSelected(isSelected ? null : date);
            });
          }),
        ),
        const SizedBox(height: 12),
        // 图例
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '少',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 4),
            ...List.generate(5, (index) {
              final color = _getHeatmapColor(index, 4);
              return Container(
                width: 14,
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
            const SizedBox(width: 4),
            Text(
              '多',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        // 选中日期信息
        if (_selectedDate != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_selectedDate!.month}月${_selectedDate!.day}日',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${_dailyReadCounts[_selectedDate] ?? 0}次 · ${_formatDuration(_dailyReadTimes[_selectedDate] ?? 0)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () {
                    onDateSelected(null);
                  },
                  child: Row(
                    children: [
                      Icon(Icons.close, size: 16, color: Theme.of(context).colorScheme.error),
                      const SizedBox(width: 4),
                      Text('清除筛选', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStatPill(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withOpacity(0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCell() {
    return SizedBox(
      width: (MediaQuery.of(context).size.width - 48) / 7 - 4,
      height: (MediaQuery.of(context).size.width - 48) / 7 - 4,
    );
  }

  Widget _buildDayCell(
    int day,
    int value,
    int maxValue,
    bool isToday,
    bool isSelected,
    VoidCallback onTap, {
    bool isCurrentMonth = true,
  }) {
    final cellSize = (MediaQuery.of(context).size.width - 48) / 7 - 4;
    
    Color bgColor;
    Color textColor;
    
    if (isSelected) {
      bgColor = Theme.of(context).colorScheme.secondary;
      textColor = Theme.of(context).colorScheme.onSecondary;
    } else if (!isCurrentMonth) {
      bgColor = Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.22);
      textColor = Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.35);
    } else if (value <= 0) {
      bgColor = Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.38);
      textColor = Theme.of(context).colorScheme.onSurfaceVariant;
    } else {
      final ratio = (value / maxValue).clamp(0.0, 1.0);
      final intensity = ratio * ratio;
      bgColor = Color.lerp(
        Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.42),
        Theme.of(context).colorScheme.secondary,
        intensity,
      )!;
      textColor = ratio > 0.72
          ? Theme.of(context).colorScheme.onSecondary
          : Theme.of(context).colorScheme.onSurface;
    }
    
    return GestureDetector(
      onTap: isCurrentMonth ? onTap : null,
      child: Container(
        width: cellSize,
        height: cellSize,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: isToday && !isSelected
              ? Border.all(color: Theme.of(context).colorScheme.secondary, width: 2)
              : isSelected
                  ? Border.all(color: Theme.of(context).colorScheme.onSecondary.withOpacity(0.75), width: 2)
                  : null,
        ),
        child: Center(
          child: Text(
            '$day',
            style: TextStyle(
              fontSize: 12,
              fontWeight: isToday || isSelected ? FontWeight.bold : FontWeight.normal,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  Color _getHeatmapColor(int index, int maxIndex) {
    if (index == 0) {
      return Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.4);
    }
    final ratio = index / maxIndex;
    final intensity = ratio * ratio;
    return Color.lerp(
      Theme.of(context).colorScheme.secondaryContainer.withOpacity(0.4),
      Theme.of(context).colorScheme.secondary,
      intensity,
    )!;
  }

  Widget _buildModeChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.secondaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.secondary
                : Theme.of(context).colorScheme.outline,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected
                ? Theme.of(context).colorScheme.onSecondaryContainer
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
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

  String _formatDateOnly(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}
