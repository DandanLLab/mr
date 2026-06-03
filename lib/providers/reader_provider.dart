import 'package:flutter/material.dart';
import '../models/highlight.dart';
import '../services/storage_service.dart';
import '../services/reader_bookmark_service.dart';
import '../services/reader_tts_manager.dart';

enum PageMode { scroll, slide, cover, simulation }

enum TapZoneAction { none, showMenu, previousPage, nextPage, previousChapter, nextChapter }

class ReaderProvider extends ChangeNotifier {
  PageMode _pageMode = PageMode.simulation;
  double _fontSize = 18.0;
  double _lineHeight = 1.5;
  Color _backgroundColor = const Color(0xFFFFF8E1);
  Color _textColor = Colors.black87;
  double _brightness = 1.0;
  bool _isNightMode = false;
  bool _initialized = false;

  double _letterSpacing = 0.0;
  double _paragraphSpacing = 8.0;
  double _textIndent = 2.0;
  List<HighlightRule> _highlightRules = HighlightRule.builtInRules();
  List<Highlight> _highlights = [];

  String _fontFamily = '';
  bool _loadEpubFonts = true;
  Map<String, String> _fontOverrides = {};
  TapZoneAction _centerTapAction = TapZoneAction.showMenu;
  List<List<TapZoneAction>> _tapZoneActions = [
    [TapZoneAction.none, TapZoneAction.none, TapZoneAction.none],
    [TapZoneAction.none, TapZoneAction.showMenu, TapZoneAction.none],
    [TapZoneAction.none, TapZoneAction.showMenu, TapZoneAction.none],
  ];

  // 书签服务
  final ReaderBookmarkService _bookmarkService = ReaderBookmarkService();
  List<Bookmark> _bookmarks = [];
  
  // TTS管理器
  ReaderTtsManager? _ttsManager;
  bool _isTtsPlaying = false;
  bool _isTtsPaused = false;
  int _ttsParagraphIndex = 0;
  int _ttsParagraphTotal = 0;
  double _ttsRate = 0.5;
  
  // 阅读设置
  bool _showReadingInfo = true;
  bool _showChapterTitle = true;
  bool _showClock = true;
  bool _showProgress = true;
  int _pageAnim = 3; // 仿真翻页
  int _pageAnimDurationMs = 300;
  double _screenBrightness = -1.0; // -1表示跟随系统
  bool _keepScreenOn = false;
  bool _enableVolumeKeyPage = false;
  bool _volumeKeyPageOnTts = false;
  bool _enableLongPressMenu = true;
  int _autoScrollSpeed = 50;
  int _autoPageIntervalSeconds = 0;
  List<int> _tapZones = [0, 4, 0, 0, 1, 0, 0, 3, 2];
  double _horizontalPadding = 16.0;
  double _verticalPadding = 12.0;
  String _paragraphIndent = '\u3000\u3000';
  int _fontWeightIndex = 1;
  String? _backgroundImagePath;

  PageMode get pageMode => _pageMode;
  double get fontSize => _fontSize;
  double get lineHeight => _lineHeight;
  Color get backgroundColor => _backgroundColor;
  Color get textColor => _textColor;
  double get brightness => _brightness;
  bool get isNightMode => _isNightMode;
  String get fontFamily => _fontFamily;
  bool get loadEpubFonts => _loadEpubFonts;
  Map<String, String> get fontOverrides => Map.unmodifiable(_fontOverrides);
  TapZoneAction get centerTapAction => _centerTapAction;
  List<List<TapZoneAction>> get tapZoneActions => _tapZoneActions;
  double get letterSpacing => _letterSpacing;
  double get paragraphSpacing => _paragraphSpacing;
  double get textIndent => _textIndent;
  List<HighlightRule> get highlightRules => List.unmodifiable(_highlightRules);
  List<Highlight> get highlights => List.unmodifiable(_highlights);

  Future<void> loadFromStorage() async {
    if (_initialized) return;
    final config = StorageService.instance.getReaderConfig();
    if (config != null) {
      _fontSize = (config['fontSize'] as num?)?.toDouble() ?? 18.0;
      _lineHeight = (config['lineHeight'] as num?)?.toDouble() ?? 1.5;
      _brightness = (config['brightness'] as num?)?.toDouble() ?? 1.0;
      _isNightMode = config['isNightMode'] as bool? ?? false;
      final bgValue = config['backgroundColor'] as int?;
      if (bgValue != null) _backgroundColor = Color(bgValue);
      final modeIndex = config['pageMode'] as int?;
      if (modeIndex != null && modeIndex < PageMode.values.length) {
        _pageMode = PageMode.values[modeIndex];
      }
      _fontFamily = config['fontFamily'] as String? ?? '';
      _loadEpubFonts = config['loadEpubFonts'] as bool? ?? true;
      final overrides = config['fontOverrides'] as Map?;
      if (overrides != null) {
        _fontOverrides = Map<String, String>.from(overrides);
      }
      final centerActionIndex = config['centerTapAction'] as int?;
      if (centerActionIndex != null && centerActionIndex < TapZoneAction.values.length) {
        _centerTapAction = TapZoneAction.values[centerActionIndex];
      }
      final tapActions = config['tapZoneActions'] as List?;
      if (tapActions != null) {
        _tapZoneActions = tapActions.map((row) {
          final rowList = row as List;
          return rowList.map((cell) {
            final idx = cell as int;
            if (idx >= 0 && idx < TapZoneAction.values.length) {
              return TapZoneAction.values[idx];
            }
            return TapZoneAction.none;
          }).toList();
        }).toList();
      }
      if (_isNightMode) {
        _backgroundColor = const Color(0xFF1A1A1A);
        _textColor = Colors.white70;
      }
      _letterSpacing = (config['letterSpacing'] as num?)?.toDouble() ?? 0.0;
      _paragraphSpacing = (config['paragraphSpacing'] as num?)?.toDouble() ?? 8.0;
      _textIndent = (config['textIndent'] as num?)?.toDouble() ?? 2.0;
      final highlightRulesJson = config['highlightRules'] as List?;
      if (highlightRulesJson != null) {
        _highlightRules = highlightRulesJson
            .map((e) => HighlightRule.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      final highlightsJson = config['highlights'] as List?;
      if (highlightsJson != null) {
        _highlights = highlightsJson
            .map((e) => Highlight.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> _saveToStorage() async {
    await StorageService.instance.saveReaderConfig({
      'fontSize': _fontSize,
      'lineHeight': _lineHeight,
      'brightness': _brightness,
      'isNightMode': _isNightMode,
      'backgroundColor': _backgroundColor.value,
      'pageMode': _pageMode.index,
      'fontFamily': _fontFamily,
      'loadEpubFonts': _loadEpubFonts,
      'fontOverrides': _fontOverrides,
      'centerTapAction': _centerTapAction.index,
      'tapZoneActions': _tapZoneActions.map((row) => row.map((a) => a.index).toList()).toList(),
      'letterSpacing': _letterSpacing,
      'paragraphSpacing': _paragraphSpacing,
      'textIndent': _textIndent,
      'highlightRules': _highlightRules.map((e) => e.toJson()).toList(),
      'highlights': _highlights.map((e) => e.toJson()).toList(),
    });
  }

  void setPageMode(PageMode mode) {
    _pageMode = mode;
    _saveToStorage();
    notifyListeners();
  }

  void setFontSize(double size) {
    _fontSize = size;
    _saveToStorage();
    notifyListeners();
  }

  void setLineHeight(double height) {
    _lineHeight = height;
    _saveToStorage();
    notifyListeners();
  }

  void setBackgroundColor(Color color) {
    _backgroundColor = color;
    _saveToStorage();
    notifyListeners();
  }

  void setTextColor(Color color) {
    _textColor = color;
    notifyListeners();
  }

  void setBrightness(double value) {
    _brightness = value;
    _saveToStorage();
    notifyListeners();
  }

  void toggleNightMode() {
    _isNightMode = !_isNightMode;
    if (_isNightMode) {
      _backgroundColor = const Color(0xFF1A1A1A);
      _textColor = Colors.white70;
    } else {
      _backgroundColor = const Color(0xFFFFF8E1);
      _textColor = Colors.black87;
    }
    _saveToStorage();
    notifyListeners();
  }

  void setFontFamily(String family) {
    _fontFamily = family;
    _saveToStorage();
    notifyListeners();
  }

  void setLoadEpubFonts(bool load) {
    _loadEpubFonts = load;
    _saveToStorage();
    notifyListeners();
  }

  void setCenterTapAction(TapZoneAction action) {
    _centerTapAction = action;
    _saveToStorage();
    notifyListeners();
  }

  void setTapZoneAction(int row, int col, TapZoneAction action) {
    if (row < 0 || row >= _tapZoneActions.length) return;
    if (col < 0 || col >= _tapZoneActions[row].length) return;
    _tapZoneActions[row][col] = action;
    _saveToStorage();
    notifyListeners();
  }

  void setFontOverride(String original, String override) {
    _fontOverrides[original] = override;
    _saveToStorage();
    notifyListeners();
  }

  void removeFontOverride(String original) {
    _fontOverrides.remove(original);
    _saveToStorage();
    notifyListeners();
  }

  void setLetterSpacing(double value) {
    _letterSpacing = value;
    _saveToStorage();
    notifyListeners();
  }

  void setParagraphSpacing(double value) {
    _paragraphSpacing = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTextIndent(double value) {
    _textIndent = value;
    _saveToStorage();
    notifyListeners();
  }

  void addHighlightRule(HighlightRule rule) {
    _highlightRules.add(rule);
    _saveToStorage();
    notifyListeners();
  }

  void removeHighlightRule(String ruleId) {
    _highlightRules.removeWhere((rule) => rule.id == ruleId);
    _saveToStorage();
    notifyListeners();
  }

  void toggleHighlightRule(String ruleId) {
    final index = _highlightRules.indexWhere((rule) => rule.id == ruleId);
    if (index != -1) {
      final rule = _highlightRules[index];
      _highlightRules[index] = HighlightRule(
        id: rule.id,
        name: rule.name,
        pattern: rule.pattern,
        style: rule.style,
        color: rule.color,
        enabled: !rule.enabled,
        isBuiltIn: rule.isBuiltIn,
        serialNumber: rule.serialNumber,
      );
      _saveToStorage();
      notifyListeners();
    }
  }

  void addHighlight(Highlight highlight) {
    _highlights.add(highlight);
    _saveToStorage();
    notifyListeners();
  }

  void removeHighlight(String highlightId) {
    _highlights.removeWhere((h) => h.id == highlightId);
    _saveToStorage();
    notifyListeners();
  }

  void updateHighlightNote(String highlightId, String note) {
    final index = _highlights.indexWhere((h) => h.id == highlightId);
    if (index != -1) {
      _highlights[index] = _highlights[index].copyWith(note: note, updatedAt: DateTime.now());
      _saveToStorage();
      notifyListeners();
    }
  }

  List<Highlight> getHighlightsForChapter(String bookUrl, int chapterIndex) {
    return _highlights
        .where((h) => h.bookUrl == bookUrl && h.chapterIndex == chapterIndex)
        .toList();
  }

  // ==================== 书签相关 ====================
  List<Bookmark> get bookmarks => List.unmodifiable(_bookmarks);
  
  Future<void> loadBookmarks(String bookUrl) async {
    _bookmarks = await _bookmarkService.list(bookUrl);
    notifyListeners();
  }
  
  Future<bool> hasBookmarkForChapter(String bookUrl, int chapterIndex) async {
    return await _bookmarkService.hasBookmarkForChapter(bookUrl, chapterIndex);
  }
  
  Future<Bookmark?> addBookmark({
    required String bookUrl,
    required int chapterIndex,
    required String chapterTitle,
    required String content,
    String? note,
  }) async {
    final bookmark = await _bookmarkService.add(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      content: content,
      note: note,
    );
    if (bookmark != null) {
      _bookmarks.add(bookmark);
      notifyListeners();
    }
    return bookmark;
  }
  
  Future<void> removeBookmark(String bookUrl, String bookmarkId) async {
    await _bookmarkService.remove(bookUrl: bookUrl, bookmarkId: bookmarkId);
    _bookmarks.removeWhere((b) => b.id == bookmarkId);
    notifyListeners();
  }

  // ==================== TTS相关 ====================
  bool get isTtsPlaying => _isTtsPlaying;
  bool get isTtsPaused => _isTtsPaused;
  int get ttsParagraphIndex => _ttsParagraphIndex;
  int get ttsParagraphTotal => _ttsParagraphTotal;
  double get ttsRate => _ttsRate;
  
  Future<void> initTts({
    double rate = 0.5,
    VoidCallback? onStateChanged,
    VoidCallback? onParagraphChanged,
  }) async {
    _ttsManager = ReaderTtsManager();
    _ttsRate = rate;
    await _ttsManager!.init(
      rate: rate,
      onStateChanged: () {
        _isTtsPlaying = _ttsManager!.isSpeaking;
        _isTtsPaused = _ttsManager!.isPaused;
        _ttsParagraphIndex = _ttsManager!.paragraphIndex;
        onStateChanged?.call();
        notifyListeners();
      },
      onParagraphChanged: () {
        _ttsParagraphIndex = _ttsManager!.paragraphIndex;
        onParagraphChanged?.call();
        notifyListeners();
      },
    );
  }
  
  void setTtsChapterContent(String content) {
    _ttsManager?.setChapterContent(content);
    // 计算段落总数
    _ttsParagraphTotal = content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .length;
    notifyListeners();
  }
  
  Future<void> startTts() async {
    await _ttsManager?.start();
  }
  
  void pauseTts() {
    _ttsManager?.pause();
  }
  
  Future<void> resumeTts() async {
    await _ttsManager?.resume();
  }
  
  void stopTts() {
    _ttsManager?.stop();
  }
  
  Future<void> nextTtsParagraph() async {
    await _ttsManager?.nextParagraph();
  }
  
  Future<void> prevTtsParagraph() async {
    await _ttsManager?.prevParagraph();
  }
  
  Future<void> setTtsRate(double rate) async {
    _ttsRate = rate;
    await _ttsManager?.setRate(rate);
    notifyListeners();
  }
  
  void disposeTts() {
    _ttsManager?.dispose();
    _ttsManager = null;
  }

  // ==================== 阅读设置 ====================
  bool get showReadingInfo => _showReadingInfo;
  bool get showChapterTitle => _showChapterTitle;
  bool get showClock => _showClock;
  bool get showProgress => _showProgress;
  int get pageAnim => _pageAnim;
  int get pageAnimDurationMs => _pageAnimDurationMs;
  double get screenBrightness => _screenBrightness;
  bool get keepScreenOn => _keepScreenOn;
  bool get enableVolumeKeyPage => _enableVolumeKeyPage;
  bool get volumeKeyPageOnTts => _volumeKeyPageOnTts;
  bool get enableLongPressMenu => _enableLongPressMenu;
  int get autoScrollSpeed => _autoScrollSpeed;
  int get autoPageIntervalSeconds => _autoPageIntervalSeconds;
  List<int> get tapZones => _tapZones;
  double get horizontalPadding => _horizontalPadding;
  double get verticalPadding => _verticalPadding;
  String get paragraphIndent => _paragraphIndent;
  int get fontWeightIndex => _fontWeightIndex;
  String? get backgroundImagePath => _backgroundImagePath;

  void setShowReadingInfo(bool value) {
    _showReadingInfo = value;
    _saveToStorage();
    notifyListeners();
  }

  void setShowChapterTitle(bool value) {
    _showChapterTitle = value;
    _saveToStorage();
    notifyListeners();
  }

  void setShowClock(bool value) {
    _showClock = value;
    _saveToStorage();
    notifyListeners();
  }

  void setShowProgress(bool value) {
    _showProgress = value;
    _saveToStorage();
    notifyListeners();
  }

  void setPageAnim(int value) {
    _pageAnim = value;
    _saveToStorage();
    notifyListeners();
  }

  void setPageAnimDurationMs(int value) {
    _pageAnimDurationMs = value;
    _saveToStorage();
    notifyListeners();
  }

  void setScreenBrightness(double value) {
    _screenBrightness = value;
    _saveToStorage();
    notifyListeners();
  }

  void setKeepScreenOn(bool value) {
    _keepScreenOn = value;
    _saveToStorage();
    notifyListeners();
  }

  void setEnableVolumeKeyPage(bool value) {
    _enableVolumeKeyPage = value;
    _saveToStorage();
    notifyListeners();
  }

  void setVolumeKeyPageOnTts(bool value) {
    _volumeKeyPageOnTts = value;
    _saveToStorage();
    notifyListeners();
  }

  void setEnableLongPressMenu(bool value) {
    _enableLongPressMenu = value;
    _saveToStorage();
    notifyListeners();
  }

  void setAutoScrollSpeed(int value) {
    _autoScrollSpeed = value;
    _saveToStorage();
    notifyListeners();
  }

  void setAutoPageIntervalSeconds(int value) {
    _autoPageIntervalSeconds = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTapZones(List<int> value) {
    _tapZones = List.from(value);
    _saveToStorage();
    notifyListeners();
  }

  void setHorizontalPadding(double value) {
    _horizontalPadding = value;
    _saveToStorage();
    notifyListeners();
  }

  void setVerticalPadding(double value) {
    _verticalPadding = value;
    _saveToStorage();
    notifyListeners();
  }

  void setParagraphIndent(String value) {
    _paragraphIndent = value;
    _saveToStorage();
    notifyListeners();
  }

  void setFontWeightIndex(int value) {
    _fontWeightIndex = value;
    _saveToStorage();
    notifyListeners();
  }

  void setBackgroundImagePath(String? value) {
    _backgroundImagePath = value;
    _saveToStorage();
    notifyListeners();
  }
}
