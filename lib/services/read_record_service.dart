import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../services/storage_service.dart';

/// 阅读记录数据模型
class ReadRecord {
  final String id;
  final String bookUrl;
  final String bookName;
  final String bookAuthor;
  final String coverUrl;
  final int readTime; // 阅读时长（秒）
  final int startTime; // 开始阅读时间戳
  final int endTime; // 结束阅读时间戳
  final int chapterIndex; // 阅读章节索引
  final String chapterTitle; // 阅读章节标题

  ReadRecord({
    required this.id,
    required this.bookUrl,
    required this.bookName,
    required this.bookAuthor,
    required this.coverUrl,
    required this.readTime,
    required this.startTime,
    required this.endTime,
    required this.chapterIndex,
    required this.chapterTitle,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'bookUrl': bookUrl,
    'bookName': bookName,
    'bookAuthor': bookAuthor,
    'coverUrl': coverUrl,
    'readTime': readTime,
    'startTime': startTime,
    'endTime': endTime,
    'chapterIndex': chapterIndex,
    'chapterTitle': chapterTitle,
  };

  factory ReadRecord.fromJson(Map<String, dynamic> json) => ReadRecord(
    id: json['id'] ?? '',
    bookUrl: json['bookUrl'] ?? '',
    bookName: json['bookName'] ?? '',
    bookAuthor: json['bookAuthor'] ?? '',
    coverUrl: json['coverUrl'] ?? '',
    readTime: json['readTime'] ?? 0,
    startTime: json['startTime'] ?? 0,
    endTime: json['endTime'] ?? 0,
    chapterIndex: json['chapterIndex'] ?? 0,
    chapterTitle: json['chapterTitle'] ?? '',
  );
}

/// 阅读记录聚合数据
class ReadRecordSummary {
  final String bookUrl;
  final String bookName;
  final String bookAuthor;
  final String coverUrl;
  final int totalReadTime; // 总阅读时长（秒）
  final int firstReadTime; // 首次阅读时间
  final int lastReadTime; // 最后阅读时间
  final int readCount; // 阅读次数
  final int lastChapterIndex;
  final String lastChapterTitle;

  ReadRecordSummary({
    required this.bookUrl,
    required this.bookName,
    required this.bookAuthor,
    required this.coverUrl,
    required this.totalReadTime,
    required this.firstReadTime,
    required this.lastReadTime,
    required this.readCount,
    required this.lastChapterIndex,
    required this.lastChapterTitle,
  });
}

/// 阅读记录服务
class ReadRecordService {
  static const String _recordKey = 'read_records';

  static final ReadRecordService instance = ReadRecordService._();
  ReadRecordService._();

  /// 获取所有阅读记录
  Future<List<ReadRecord>> getAllRecords() async {
    try {
      final data = await StorageService.instance.getCachedDataAsync(_recordKey);
      if (data == null || data is! String || data.isEmpty) {
        debugPrint('[ReadRecord] No records found');
        return [];
      }
      
      final decoded = jsonDecode(data) as List;
      final records = decoded
          .map((e) => ReadRecord.fromJson(e as Map<String, dynamic>))
          .toList();
      records.sort((a, b) => b.endTime.compareTo(a.endTime)); // 按时间倒序
      debugPrint('[ReadRecord] Loaded ${records.length} records');
      return records;
    } catch (e) {
      debugPrint('[ReadRecord] getAllRecords failed: $e');
      return [];
    }
  }

  /// 获取聚合的阅读记录（按书籍分组）
  Future<List<ReadRecordSummary>> getSummaryRecords() async {
    final records = await getAllRecords();
    final Map<String, List<ReadRecord>> grouped = {};
    
    for (final record in records) {
      final key = '${record.bookName}_${record.bookAuthor}';
      grouped.putIfAbsent(key, () => []).add(record);
    }
    
    return grouped.entries.map((entry) {
      final list = entry.value;
      final totalReadTime = list.fold<int>(0, (sum, r) => sum + r.readTime);
      final firstReadTime = list.map((r) => r.startTime).reduce((a, b) => a < b ? a : b);
      final lastReadTime = list.map((r) => r.endTime).reduce((a, b) => a > b ? a : b);
      final lastRecord = list.first; // 已按时间倒序
      
      return ReadRecordSummary(
        bookUrl: lastRecord.bookUrl,
        bookName: lastRecord.bookName,
        bookAuthor: lastRecord.bookAuthor,
        coverUrl: lastRecord.coverUrl,
        totalReadTime: totalReadTime,
        firstReadTime: firstReadTime,
        lastReadTime: lastReadTime,
        readCount: list.length,
        lastChapterIndex: lastRecord.chapterIndex,
        lastChapterTitle: lastRecord.chapterTitle,
      );
    }).toList()
      ..sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime)); // 按最后阅读时间倒序
  }

  /// 添加阅读记录
  Future<void> addRecord(ReadRecord record) async {
    try {
      debugPrint('[ReadRecord] Adding record: ${record.bookName}, time: ${record.readTime}s');
      final records = await getAllRecords();
      records.insert(0, record);
      
      // 保留最近1000条记录
      if (records.length > 1000) {
        records.removeRange(1000, records.length);
      }
      
      final jsonStr = jsonEncode(records.map((r) => r.toJson()).toList());
      await StorageService.instance.cacheData(_recordKey, jsonStr);
      debugPrint('[ReadRecord] Saved ${records.length} records');
    } catch (e) {
      debugPrint('[ReadRecord] addRecord failed: $e');
    }
  }

  /// 删除阅读记录
  Future<void> deleteRecord(String recordId) async {
    try {
      final records = await getAllRecords();
      records.removeWhere((r) => r.id == recordId);
      
      await StorageService.instance.cacheData(
        _recordKey,
        jsonEncode(records.map((r) => r.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[ReadRecord] deleteRecord failed: $e');
    }
  }

  /// 删除书籍的所有阅读记录
  Future<void> deleteRecordsByBook(String bookName, String bookAuthor) async {
    try {
      final records = await getAllRecords();
      records.removeWhere((r) => r.bookName == bookName && r.bookAuthor == bookAuthor);
      
      await StorageService.instance.cacheData(
        _recordKey,
        jsonEncode(records.map((r) => r.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[ReadRecord] deleteRecordsByBook failed: $e');
    }
  }

  /// 清空所有阅读记录
  Future<void> clearAllRecords() async {
    try {
      await StorageService.instance.cacheData(_recordKey, '[]');
    } catch (e) {
      debugPrint('[ReadRecord] clearAllRecords failed: $e');
    }
  }

  /// 获取总阅读时长
  Future<int> getTotalReadTime() async {
    final records = await getAllRecords();
    return records.fold<int>(0, (sum, r) => sum + r.readTime);
  }

  /// 获取今日阅读时长
  Future<int> getTodayReadTime() async {
    final records = await getAllRecords();
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;
    
    return records
        .where((r) => r.startTime * 1000 >= todayStart)
        .fold<int>(0, (sum, r) => sum + r.readTime);
  }

  /// 开始阅读（记录开始时间）
  int startReading() {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  /// 结束阅读（保存记录）
  Future<void> endReading({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
    required String coverUrl,
    required int startTime,
    required int chapterIndex,
    required String chapterTitle,
  }) async {
    debugPrint('[ReadRecord] endReading called: $bookName, startTime: $startTime');
    
    final endTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final readTime = endTime - startTime;
    
    debugPrint('[ReadRecord] readTime: $readTime seconds');
    
    // 只保存阅读时长超过5秒的记录
    if (readTime < 5) {
      debugPrint('[ReadRecord] Skipped: read time too short (< 5s)');
      return;
    }
    
    final record = ReadRecord(
      id: '${bookUrl}_$startTime',
      bookUrl: bookUrl,
      bookName: bookName,
      bookAuthor: bookAuthor,
      coverUrl: coverUrl,
      readTime: readTime,
      startTime: startTime,
      endTime: endTime,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
    );
    
    await addRecord(record);
  }
}
