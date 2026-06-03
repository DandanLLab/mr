import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 阅读器TTS管理器
/// 管理文字转语音朗读功能
class ReaderTtsManager {
  ReaderTtsManager();

  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  bool _isSpeaking = false;
  bool _isPaused = false;
  int _paragraphIndex = 0;
  double _rate = 0.5;

  /// 当前朗读章节正文
  String _chapterContent = '';

  /// 段落列表
  List<String> _paragraphs = [];

  VoidCallback? _onStateChanged;
  VoidCallback? _onParagraphChanged;

  bool get isSpeaking => _isSpeaking;
  bool get isPaused => _isPaused;
  int get paragraphIndex => _paragraphIndex;
  int get paragraphCount => _paragraphs.length;
  double get rate => _rate;

  /// 初始化TTS引擎
  Future<void> init({
    double rate = 0.5,
    VoidCallback? onStateChanged,
    VoidCallback? onParagraphChanged,
  }) async {
    _onStateChanged = onStateChanged;
    _onParagraphChanged = onParagraphChanged;
    _rate = rate;

    try {
      debugPrint('[TTS] init: starting...');
      
      // 设置中文语言
      bool langOk = false;
      for (final code in ['zh-CN', 'zh', 'cmn', 'zh-Hans']) {
        final result = await _tts.setLanguage(code);
        debugPrint('[TTS] setLanguage("$code") returned: $result');
        if (result == 1) {
          langOk = true;
          break;
        }
      }
      if (!langOk) {
        debugPrint('[TTS] No Chinese language matched. Using default voice.');
      }
      
      // 设置语速
      final rateResult = await _tts.setSpeechRate(_rate);
      debugPrint('[TTS] setSpeechRate returned: $rateResult');
      
      // 设置完成回调
      _tts.setCompletionHandler(() {
        if (_isSpeaking) {
          nextParagraph();
        }
      });
      
      _initialized = true;
      debugPrint('[TTS] init: done');
    } catch (e, st) {
      debugPrint('[TTS] init FAILED: $e\n$st');
    }
  }

  /// 设置当前章节内容
  void setChapterContent(String content) {
    _chapterContent = content;
    _paragraphs = _splitParagraphs(content);
    _paragraphIndex = 0;
  }

  /// 开始朗读
  Future<void> start() async {
    if (!_initialized) return;
    try {
      _isSpeaking = true;
      _isPaused = false;
      _paragraphIndex = 0;
      _onStateChanged?.call();
      await _tts.stop();
      await _speakCurrent();
    } catch (e, st) {
      debugPrint('[TTS] start FAILED: $e\n$st');
    }
  }

  /// 朗读当前段落
  Future<void> _speakCurrent() async {
    if (!_isSpeaking) return;
    
    if (_paragraphIndex >= _paragraphs.length) {
      // 章节结束
      _paragraphIndex = 0;
      _onParagraphChanged?.call();
      _onStateChanged?.call();
      return;
    }
    
    final text = _paragraphs[_paragraphIndex];
    debugPrint('[TTS] Speaking paragraph $_paragraphIndex: "${text.length > 30 ? text.substring(0, 30) : text}..."');
    
    await _tts.speak(text);
  }

  /// 暂停
  void pause() {
    _isPaused = true;
    _tts.pause();
    _onStateChanged?.call();
  }

  /// 恢复
  Future<void> resume() async {
    if (!_isSpeaking) {
      await start();
      return;
    }
    _isPaused = false;
    _onStateChanged?.call();
    await _speakCurrent();
  }

  /// 停止
  void stop() {
    _isSpeaking = false;
    _isPaused = false;
    _tts.stop();
    _onStateChanged?.call();
  }

  /// 下一段
  Future<void> nextParagraph() async {
    if (_paragraphIndex < _paragraphs.length - 1) {
      _paragraphIndex++;
      _onParagraphChanged?.call();
      await _speakCurrent();
    } else {
      // 章节结束
      _paragraphIndex = 0;
      _onParagraphChanged?.call();
      _onStateChanged?.call();
    }
  }

  /// 上一段
  Future<void> prevParagraph() async {
    if (_paragraphIndex > 0) {
      _paragraphIndex--;
      _onParagraphChanged?.call();
      await _tts.stop();
      await _speakCurrent();
    }
  }

  /// 跳到指定段落
  Future<void> goToParagraph(int index) async {
    if (index >= 0 && index < _paragraphs.length) {
      _paragraphIndex = index;
      _onParagraphChanged?.call();
      await _tts.stop();
      await _speakCurrent();
    }
  }

  /// 设置语速
  Future<void> setRate(double rate) async {
    _rate = rate;
    if (_isSpeaking) {
      await _tts.setSpeechRate(rate);
    }
  }

  /// 释放资源
  void dispose() {
    try {
      _tts.stop();
    } catch (e) {
      debugPrint('[TTS] stop on dispose failed: $e');
    }
    try {
      _tts.setCompletionHandler(() {});
    } catch (e) {
      debugPrint('[TTS] reset completion handler failed: $e');
    }
    _onStateChanged = null;
    _onParagraphChanged = null;
  }

  /// 分割段落
  static List<String> _splitParagraphs(String content) {
    return content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
  }

  /// 获取当前段落文本
  String get currentParagraph {
    if (_paragraphs.isEmpty || _paragraphIndex >= _paragraphs.length) {
      return '';
    }
    return _paragraphs[_paragraphIndex];
  }
}
