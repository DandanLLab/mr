import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/book_source.dart';
import 'source_engine/source_engine.dart';
import 'storage_service.dart';

class DebugMessage {
  final String type;
  final String id;
  final Map<String, dynamic> data;
  final DateTime timestamp;

  DebugMessage({
    required this.type,
    required this.id,
    required this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory DebugMessage.fromJson(Map<String, dynamic> json) {
    return DebugMessage(
      type: json['type'] as String? ?? '',
      id: json['id'] as String? ?? '',
      data: json['data'] as Map<String, dynamic>? ?? {},
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'id': id,
      'data': data,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

class DebugResponse {
  final String id;
  final bool success;
  final dynamic result;
  final String? error;
  final DateTime timestamp;

  DebugResponse({
    required this.id,
    required this.success,
    this.result,
    this.error,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'success': success,
      'result': result,
      'error': error,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

class DebugService {
  static final DebugService _instance = DebugService._internal();
  static DebugService get instance => _instance;
  DebugService._internal();

  bool _isRunning = false;
  int _port = 9527;

  bool get isRunning => _isRunning;
  int get port => _port;

  Future<void> start({int port = 9527}) async {
    if (_isRunning) {
      debugPrint('调试服务已在运行中');
      return;
    }

    if (kIsWeb) {
      debugPrint('Web平台不支持WebSocket调试服务');
      return;
    }

    _port = port;
    
    try {
      _isRunning = true;
      debugPrint('🚀 调试服务已启动: ws://localhost:$_port');
      debugPrint('📡 注意: 调试服务仅在桌面/移动端可用');
    } catch (e) {
      debugPrint('启动调试服务失败: $e');
      _isRunning = false;
    }
  }

  Future<void> stop() async {
    _isRunning = false;
    debugPrint('调试服务已停止');
  }

  Future<DebugResponse> testSearch(Map<String, dynamic> sourceData, String keyword) async {
    try {
      final source = BookSource.fromJson(sourceData);
      final webBook = WebBook(source);
      final results = await webBook.searchBook(keyword);

      return DebugResponse(
        id: 'test_search',
        success: true,
        result: {
          'keyword': keyword,
          'count': results.length,
          'results': results,
        },
      );
    } catch (e) {
      return DebugResponse(
        id: 'test_search',
        success: false,
        error: '搜索测试失败: $e',
      );
    }
  }

  Future<DebugResponse> testExplore(Map<String, dynamic> sourceData, String? url) async {
    try {
      final source = BookSource.fromJson(sourceData);
      final webBook = WebBook(source);
      final results = await webBook.exploreBook(url ?? '');

      return DebugResponse(
        id: 'test_explore',
        success: true,
        result: {
          'url': url,
          'count': results.length,
          'results': results,
        },
      );
    } catch (e) {
      return DebugResponse(
        id: 'test_explore',
        success: false,
        error: '发现测试失败: $e',
      );
    }
  }

  Future<DebugResponse> testBookInfo(Map<String, dynamic> sourceData, String bookUrl) async {
    try {
      final source = BookSource.fromJson(sourceData);
      final webBook = WebBook(source);
      final bookInfo = await webBook.getBookInfo(bookUrl);

      return DebugResponse(
        id: 'test_book_info',
        success: true,
        result: bookInfo,
      );
    } catch (e) {
      return DebugResponse(
        id: 'test_book_info',
        success: false,
        error: '书籍信息测试失败: $e',
      );
    }
  }

  Future<DebugResponse> testToc(Map<String, dynamic> sourceData, String bookUrl) async {
    try {
      final source = BookSource.fromJson(sourceData);
      final webBook = WebBook(source);
      final chapters = await webBook.getChapterList(bookUrl);

      return DebugResponse(
        id: 'test_toc',
        success: true,
        result: {
          'count': chapters.length,
          'chapters': chapters,
        },
      );
    } catch (e) {
      return DebugResponse(
        id: 'test_toc',
        success: false,
        error: '目录测试失败: $e',
      );
    }
  }

  Future<DebugResponse> testContent(Map<String, dynamic> sourceData, String bookUrl, Map<String, dynamic> chapterData) async {
    try {
      final source = BookSource.fromJson(sourceData);
      final webBook = WebBook(source);
      final content = await webBook.getContent(bookUrl);

      return DebugResponse(
        id: 'test_content',
        success: true,
        result: {
          'content': content,
          'length': content?.length ?? 0,
        },
      );
    } catch (e) {
      return DebugResponse(
        id: 'test_content',
        success: false,
        error: '正文测试失败: $e',
      );
    }
  }

  Future<DebugResponse> testRule(String content, String rule, String ruleType) async {
    try {
      final analyzer = AnalyzeRule();
      analyzer.setContent(content);

      dynamic result;
      switch (ruleType) {
        case 'string':
          result = analyzer.getString(rule);
          break;
        case 'list':
          result = analyzer.getStringList(rule);
          break;
        case 'map':
          result = analyzer.getMapList(rule);
          break;
        default:
          result = analyzer.getString(rule);
      }

      return DebugResponse(
        id: 'test_rule',
        success: true,
        result: {
          'rule': rule,
          'ruleType': ruleType,
          'result': result,
        },
      );
    } catch (e) {
      return DebugResponse(
        id: 'test_rule',
        success: false,
        error: '规则测试失败: $e',
      );
    }
  }

  Future<DebugResponse> executeJs(String jsCode, Map<String, dynamic>? variables) async {
    try {
      final result = await JsEngine.instance.processJsRule(
        '',
        jsCode,
      );

      return DebugResponse(
        id: 'execute_js',
        success: true,
        result: {'result': result},
      );
    } catch (e) {
      return DebugResponse(
        id: 'execute_js',
        success: false,
        error: 'JS执行失败: $e',
      );
    }
  }

  Future<DebugResponse> getBookSources() async {
    try {
      final sources = StorageService.instance.getAllBookSources();
      return DebugResponse(
        id: 'get_book_sources',
        success: true,
        result: sources,
      );
    } catch (e) {
      return DebugResponse(
        id: 'get_book_sources',
        success: false,
        error: '获取书源列表失败: $e',
      );
    }
  }

  Future<DebugResponse> addBookSource(Map<String, dynamic> sourceData) async {
    try {
      await StorageService.instance.saveBookSource(sourceData);
      return DebugResponse(
        id: 'add_book_source',
        success: true,
        result: {'message': '书源添加成功'},
      );
    } catch (e) {
      return DebugResponse(
        id: 'add_book_source',
        success: false,
        error: '添加书源失败: $e',
      );
    }
  }

  Future<DebugResponse> deleteBookSource(String sourceUrl) async {
    try {
      await StorageService.instance.deleteBookSource(sourceUrl);
      return DebugResponse(
        id: 'delete_book_source',
        success: true,
        result: {'message': '书源删除成功'},
      );
    } catch (e) {
      return DebugResponse(
        id: 'delete_book_source',
        success: false,
        error: '删除书源失败: $e',
      );
    }
  }
}
