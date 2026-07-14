import 'package:flutter/material.dart';
import '../models/highlight.dart';
import '../services/storage_service.dart';
import '../services/reader_bookmark_service.dart';
import '../services/reader_tts_manager.dart';

enum PageMode { scroll, slide, cover, simulation, none }

enum TapZoneAction {
  none,
  showMenu,
  previousPage,
  nextPage,
  previousChapter,
  nextChapter,
}

@visibleForTesting
String readerParagraphIndentString(
  dynamic value, {
  double fallbackCount = 2.0,
}) {
  if (value is num) {
    return '\u3000' * value.round().clamp(0, 8);
  }
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) {
      return '\u3000' * parsed.round().clamp(0, 8);
    }
    final count = RegExp(r'^[\u3000\t ]*').firstMatch(value)?.group(0);
    if ((count?.isNotEmpty ?? false) && count!.length != value.length) {
      return '\u3000' * count.length.clamp(0, 8);
    }
    return value;
  }
  return '\u3000' * fallbackCount.round().clamp(0, 8);
}

@visibleForTesting
double readerParagraphIndentCount(String indent) {
  return RegExp(
        r'^[\u3000\t ]*',
      ).firstMatch(indent)?.group(0)?.length.toDouble() ??
      0.0;
}

class ReaderProvider extends ChangeNotifier {
  PageMode _pageMode = PageMode.simulation;
  double _fontSize = 20.0;
  double _lineHeight = 1.6;
  Color _backgroundColor = const Color(0xFFFFF8E1);
  Color _textColor = Colors.black87;
  double _brightness = 1.0;
  bool _isNightMode = false;
  bool _initialized = false;

  double _letterSpacing = 0.1;
  double _paragraphSpacing = 4.0;
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
  double _verticalPadding = 6.0;
  String _paragraphIndent = '\u3000\u3000';
  int _fontWeightIndex = 1;
  String? _backgroundImagePath;
  // 繁简转换 0:不转换 1:简转繁 2:繁转简
  int _chineseConverterType = 0;
  // 字重精细模式
  bool _fontWeightFine = false;
  int _textBoldFine = 400;
  int _titleBoldFine = 700;
  // 标题设置
  int _titleMode = 0;
  int _titleSize = 4;
  int _titleTopSpacing = 0;
  int _titleBottomSpacing = 0;
  // 正文边距（四向独立）
  double _paddingTop = 6.0;
  double _paddingBottom = 6.0;
  double _paddingLeft = 16.0;
  double _paddingRight = 16.0;
  // 页眉边距
  double _headerPaddingTop = 0.0;
  double _headerPaddingBottom = 0.0;
  double _headerPaddingLeft = 16.0;
  double _headerPaddingRight = 16.0;
  // 页脚边距
  double _footerPaddingTop = 6.0;
  double _footerPaddingBottom = 6.0;
  double _footerPaddingLeft = 16.0;
  double _footerPaddingRight = 16.0;
  // 分隔线
  bool _showHeaderLine = false;
  bool _showFooterLine = true;
  // 信息(页眉页脚)配置
  int _headerMode = 1;
  int _footerMode = 0;
  int _tipHeaderLeft = 2;
  int _tipHeaderMiddle = 0;
  int _tipHeaderRight = 4;
  int _tipFooterLeft = 1;
  int _tipFooterMiddle = 0;
  int _tipFooterRight = 6;
  int _headerFontSize = 12;
  int _footerFontSize = 12;
  int _tipColor = 0;
  int _tipDividerColor = -1;

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
      _fontSize = (config['fontSize'] as num?)?.toDouble() ?? 20.0;
      _lineHeight = (config['lineHeight'] as num?)?.toDouble() ?? 1.6;
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
      if (centerActionIndex != null &&
          centerActionIndex < TapZoneAction.values.length) {
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
      _letterSpacing = (config['letterSpacing'] as num?)?.toDouble() ?? 0.1;
      _paragraphSpacing =
          (config['paragraphSpacing'] as num?)?.toDouble() ?? 4.0;
      _textIndent = (config['textIndent'] as num?)?.toDouble() ?? 2.0;
      _paragraphIndent = readerParagraphIndentString(
        config['paragraphIndent'],
        fallbackCount: _textIndent,
      );
      _textIndent = readerParagraphIndentCount(_paragraphIndent);
      _showReadingInfo = config['showReadingInfo'] as bool? ?? true;
      _showChapterTitle = config['showChapterTitle'] as bool? ?? true;
      _showClock = config['showClock'] as bool? ?? true;
      _showProgress = config['showProgress'] as bool? ?? true;
      _pageAnimDurationMs = config['pageAnimDurationMs'] as int? ?? 300;
      _keepScreenOn = config['keepScreenOn'] as bool? ?? false;
      _enableVolumeKeyPage = config['enableVolumeKeyPage'] as bool? ?? false;
      _volumeKeyPageOnTts = config['volumeKeyPageOnTts'] as bool? ?? false;
      _enableLongPressMenu = config['enableLongPressMenu'] as bool? ?? true;
      _autoScrollSpeed = config['autoScrollSpeed'] as int? ?? 50;
      _autoPageIntervalSeconds = config['autoPageIntervalSeconds'] as int? ?? 0;
      _horizontalPadding =
          (config['horizontalPadding'] as num?)?.toDouble() ?? 16.0;
      _verticalPadding = (config['verticalPadding'] as num?)?.toDouble() ?? 6.0;
      _fontWeightIndex = config['fontWeightIndex'] as int? ?? 1;
      _backgroundImagePath = config['backgroundImagePath'] as String?;
      _chineseConverterType = config['chineseConverterType'] as int? ?? 0;
      _fontWeightFine = config['fontWeightFine'] as bool? ?? false;
      _textBoldFine = config['textBoldFine'] as int? ?? 400;
      _titleBoldFine = config['titleBoldFine'] as int? ?? 700;
      _titleMode = config['titleMode'] as int? ?? 0;
      _titleSize = config['titleSize'] as int? ?? 4;
      _titleTopSpacing = config['titleTopSpacing'] as int? ?? 0;
      _titleBottomSpacing = config['titleBottomSpacing'] as int? ?? 0;
      _paddingTop =
          (config['paddingTop'] as num?)?.toDouble() ??
          (config['verticalPadding'] as num?)?.toDouble() ??
          6.0;
      _paddingBottom =
          (config['paddingBottom'] as num?)?.toDouble() ??
          (config['verticalPadding'] as num?)?.toDouble() ??
          6.0;
      _paddingLeft =
          (config['paddingLeft'] as num?)?.toDouble() ??
          (config['horizontalPadding'] as num?)?.toDouble() ??
          16.0;
      _paddingRight =
          (config['paddingRight'] as num?)?.toDouble() ??
          (config['horizontalPadding'] as num?)?.toDouble() ??
          16.0;
      _headerPaddingTop =
          (config['headerPaddingTop'] as num?)?.toDouble() ?? 0.0;
      _headerPaddingBottom =
          (config['headerPaddingBottom'] as num?)?.toDouble() ?? 0.0;
      _headerPaddingLeft =
          (config['headerPaddingLeft'] as num?)?.toDouble() ?? 16.0;
      _headerPaddingRight =
          (config['headerPaddingRight'] as num?)?.toDouble() ?? 16.0;
      _footerPaddingTop =
          (config['footerPaddingTop'] as num?)?.toDouble() ?? 6.0;
      _footerPaddingBottom =
          (config['footerPaddingBottom'] as num?)?.toDouble() ?? 6.0;
      _footerPaddingLeft =
          (config['footerPaddingLeft'] as num?)?.toDouble() ?? 16.0;
      _footerPaddingRight =
          (config['footerPaddingRight'] as num?)?.toDouble() ?? 16.0;
      _showHeaderLine = config['showHeaderLine'] as bool? ?? false;
      _showFooterLine = config['showFooterLine'] as bool? ?? true;
      _headerMode = config['headerMode'] as int? ?? 1;
      _footerMode = config['footerMode'] as int? ?? 0;
      _tipHeaderLeft = config['tipHeaderLeft'] as int? ?? 2;
      _tipHeaderMiddle = config['tipHeaderMiddle'] as int? ?? 0;
      _tipHeaderRight = config['tipHeaderRight'] as int? ?? 4;
      _tipFooterLeft = config['tipFooterLeft'] as int? ?? 1;
      _tipFooterMiddle = config['tipFooterMiddle'] as int? ?? 0;
      _tipFooterRight = config['tipFooterRight'] as int? ?? 6;
      _headerFontSize = config['headerFontSize'] as int? ?? 12;
      _footerFontSize = config['footerFontSize'] as int? ?? 12;
      _tipColor = config['tipColor'] as int? ?? 0;
      _tipDividerColor = config['tipDividerColor'] as int? ?? -1;
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
      'tapZoneActions': _tapZoneActions
          .map((row) => row.map((a) => a.index).toList())
          .toList(),
      'letterSpacing': _letterSpacing,
      'paragraphSpacing': _paragraphSpacing,
      'textIndent': _textIndent,
      'highlightRules': _highlightRules.map((e) => e.toJson()).toList(),
      'highlights': _highlights.map((e) => e.toJson()).toList(),
      'showReadingInfo': _showReadingInfo,
      'showChapterTitle': _showChapterTitle,
      'showClock': _showClock,
      'showProgress': _showProgress,
      'pageAnimDurationMs': _pageAnimDurationMs,
      'keepScreenOn': _keepScreenOn,
      'enableVolumeKeyPage': _enableVolumeKeyPage,
      'volumeKeyPageOnTts': _volumeKeyPageOnTts,
      'enableLongPressMenu': _enableLongPressMenu,
      'autoScrollSpeed': _autoScrollSpeed,
      'autoPageIntervalSeconds': _autoPageIntervalSeconds,
      'horizontalPadding': _horizontalPadding,
      'verticalPadding': _verticalPadding,
      'paragraphIndent': _paragraphIndent,
      'fontWeightIndex': _fontWeightIndex,
      'backgroundImagePath': _backgroundImagePath,
      'chineseConverterType': _chineseConverterType,
      'fontWeightFine': _fontWeightFine,
      'textBoldFine': _textBoldFine,
      'titleBoldFine': _titleBoldFine,
      'titleMode': _titleMode,
      'titleSize': _titleSize,
      'titleTopSpacing': _titleTopSpacing,
      'titleBottomSpacing': _titleBottomSpacing,
      'paddingTop': _paddingTop,
      'paddingBottom': _paddingBottom,
      'paddingLeft': _paddingLeft,
      'paddingRight': _paddingRight,
      'headerPaddingTop': _headerPaddingTop,
      'headerPaddingBottom': _headerPaddingBottom,
      'headerPaddingLeft': _headerPaddingLeft,
      'headerPaddingRight': _headerPaddingRight,
      'footerPaddingTop': _footerPaddingTop,
      'footerPaddingBottom': _footerPaddingBottom,
      'footerPaddingLeft': _footerPaddingLeft,
      'footerPaddingRight': _footerPaddingRight,
      'showHeaderLine': _showHeaderLine,
      'showFooterLine': _showFooterLine,
      'headerMode': _headerMode,
      'footerMode': _footerMode,
      'tipHeaderLeft': _tipHeaderLeft,
      'tipHeaderMiddle': _tipHeaderMiddle,
      'tipHeaderRight': _tipHeaderRight,
      'tipFooterLeft': _tipFooterLeft,
      'tipFooterMiddle': _tipFooterMiddle,
      'tipFooterRight': _tipFooterRight,
      'headerFontSize': _headerFontSize,
      'footerFontSize': _footerFontSize,
      'tipColor': _tipColor,
      'tipDividerColor': _tipDividerColor,
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
    // 根据背景色亮度自动适应文字色
    _autoAdaptTextColor(color);
    _saveToStorage();
    notifyListeners();
  }

  void setTextColor(Color color) {
    _textColor = color;
    _saveToStorage();
    notifyListeners();
  }

  /// 根据背景色亮度自动设置文字色（深色背景→白字，浅色背景→黑字）
  void _autoAdaptTextColor(Color bgColor) {
    // 计算亮度：0.0 全黑，1.0 全白
    final brightness = bgColor.computeLuminance();
    if (brightness < 0.5) {
      // 深色背景 → 白色文字
      _textColor = Colors.white70;
    } else {
      // 浅色背景 → 黑色文字
      _textColor = Colors.black87;
    }
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

  void setNightMode(bool value) {
    if (_isNightMode == value) return;
    toggleNightMode();
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
    // 同步更新缩进字符串，使缩进滑块生效
    _paragraphIndent = readerParagraphIndentString(value);
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
      _highlights[index] = _highlights[index].copyWith(
        note: note,
        updatedAt: DateTime.now(),
      );
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
        // 防护：disposeTts() 可能在回调队列中置 null，导致 _ttsManager! 崩溃
        final manager = _ttsManager;
        if (manager == null) return;
        _isTtsPlaying = manager.isSpeaking;
        _isTtsPaused = manager.isPaused;
        _ttsParagraphIndex = manager.paragraphIndex;
        onStateChanged?.call();
        notifyListeners();
      },
      onParagraphChanged: () {
        final manager = _ttsManager;
        if (manager == null) return;
        _ttsParagraphIndex = manager.paragraphIndex;
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
  int get chineseConverterType => _chineseConverterType;
  bool get fontWeightFine => _fontWeightFine;
  int get textBoldFine => _textBoldFine;
  int get titleBoldFine => _titleBoldFine;
  int get titleMode => _titleMode;
  int get titleSize => _titleSize;
  int get titleTopSpacing => _titleTopSpacing;
  int get titleBottomSpacing => _titleBottomSpacing;
  double get paddingTop => _paddingTop;
  double get paddingBottom => _paddingBottom;
  double get paddingLeft => _paddingLeft;
  double get paddingRight => _paddingRight;
  double get headerPaddingTop => _headerPaddingTop;
  double get headerPaddingBottom => _headerPaddingBottom;
  double get headerPaddingLeft => _headerPaddingLeft;
  double get headerPaddingRight => _headerPaddingRight;
  double get footerPaddingTop => _footerPaddingTop;
  double get footerPaddingBottom => _footerPaddingBottom;
  double get footerPaddingLeft => _footerPaddingLeft;
  double get footerPaddingRight => _footerPaddingRight;
  bool get showHeaderLine => _showHeaderLine;
  bool get showFooterLine => _showFooterLine;
  int get headerMode => _headerMode;
  int get footerMode => _footerMode;
  int get tipHeaderLeft => _tipHeaderLeft;
  int get tipHeaderMiddle => _tipHeaderMiddle;
  int get tipHeaderRight => _tipHeaderRight;
  int get tipFooterLeft => _tipFooterLeft;
  int get tipFooterMiddle => _tipFooterMiddle;
  int get tipFooterRight => _tipFooterRight;
  int get headerFontSize => _headerFontSize;
  int get footerFontSize => _footerFontSize;
  int get tipColor => _tipColor;
  int get tipDividerColor => _tipDividerColor;
  int get textFontWeight => _fontWeightFine
      ? _textBoldFine.clamp(100, 900)
      : switch (_fontWeightIndex) {
          0 => 300,
          2 => 700,
          _ => 400,
        };
  int get titleFontWeight =>
      _fontWeightFine ? _titleBoldFine.clamp(100, 900) : 700;

  void setShowReadingInfo(bool value) {
    _showReadingInfo = value;
    _saveToStorage();
    notifyListeners();
  }

  void setShowChapterTitle(bool value) {
    _showChapterTitle = value;
    if (!value) {
      _titleMode = 2;
    } else if (_titleMode == 2) {
      _titleMode = 0;
    }
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
    _paddingLeft = value;
    _paddingRight = value;
    _saveToStorage();
    notifyListeners();
  }

  void setVerticalPadding(double value) {
    _verticalPadding = value;
    _paddingTop = value;
    _paddingBottom = value;
    _saveToStorage();
    notifyListeners();
  }

  void setParagraphIndent(String value) {
    _paragraphIndent = readerParagraphIndentString(value);
    _textIndent = readerParagraphIndentCount(_paragraphIndent);
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

  void setChineseConverterType(int value) {
    _chineseConverterType = value.clamp(0, 2);
    _saveToStorage();
    notifyListeners();
  }

  void setFontWeightFine(bool value) {
    _fontWeightFine = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTextBoldFine(int value) {
    _textBoldFine = value.clamp(100, 900);
    _saveToStorage();
    notifyListeners();
  }

  void setTitleBoldFine(int value) {
    _titleBoldFine = value.clamp(100, 900);
    _saveToStorage();
    notifyListeners();
  }

  void setTitleMode(int value) {
    _titleMode = value.clamp(0, 3);
    _showChapterTitle = _titleMode != 2;
    _saveToStorage();
    notifyListeners();
  }

  void setTitleSize(int value) {
    _titleSize = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTitleTopSpacing(int value) {
    _titleTopSpacing = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTitleBottomSpacing(int value) {
    _titleBottomSpacing = value;
    _saveToStorage();
    notifyListeners();
  }

  void setPaddingTop(double value) {
    _paddingTop = value;
    _verticalPadding = (_paddingTop + _paddingBottom) / 2;
    _saveToStorage();
    notifyListeners();
  }

  void setPaddingBottom(double value) {
    _paddingBottom = value;
    _verticalPadding = (_paddingTop + _paddingBottom) / 2;
    _saveToStorage();
    notifyListeners();
  }

  void setPaddingLeft(double value) {
    _paddingLeft = value;
    _horizontalPadding = (_paddingLeft + _paddingRight) / 2;
    _saveToStorage();
    notifyListeners();
  }

  void setPaddingRight(double value) {
    _paddingRight = value;
    _horizontalPadding = (_paddingLeft + _paddingRight) / 2;
    _saveToStorage();
    notifyListeners();
  }

  void setHeaderPaddingTop(double value) {
    _headerPaddingTop = value;
    _saveToStorage();
    notifyListeners();
  }

  void setHeaderPaddingBottom(double value) {
    _headerPaddingBottom = value;
    _saveToStorage();
    notifyListeners();
  }

  void setHeaderPaddingLeft(double value) {
    _headerPaddingLeft = value;
    _saveToStorage();
    notifyListeners();
  }

  void setHeaderPaddingRight(double value) {
    _headerPaddingRight = value;
    _saveToStorage();
    notifyListeners();
  }

  void setFooterPaddingTop(double value) {
    _footerPaddingTop = value;
    _saveToStorage();
    notifyListeners();
  }

  void setFooterPaddingBottom(double value) {
    _footerPaddingBottom = value;
    _saveToStorage();
    notifyListeners();
  }

  void setFooterPaddingLeft(double value) {
    _footerPaddingLeft = value;
    _saveToStorage();
    notifyListeners();
  }

  void setFooterPaddingRight(double value) {
    _footerPaddingRight = value;
    _saveToStorage();
    notifyListeners();
  }

  void setShowHeaderLine(bool value) {
    _showHeaderLine = value;
    _saveToStorage();
    notifyListeners();
  }

  void setShowFooterLine(bool value) {
    _showFooterLine = value;
    _saveToStorage();
    notifyListeners();
  }

  void setHeaderMode(int value) {
    _headerMode = value;
    _saveToStorage();
    notifyListeners();
  }

  void setFooterMode(int value) {
    _footerMode = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipHeaderLeft(int value) {
    _tipHeaderLeft = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipHeaderMiddle(int value) {
    _tipHeaderMiddle = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipHeaderRight(int value) {
    _tipHeaderRight = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipFooterLeft(int value) {
    _tipFooterLeft = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipFooterMiddle(int value) {
    _tipFooterMiddle = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipFooterRight(int value) {
    _tipFooterRight = value;
    _saveToStorage();
    notifyListeners();
  }

  void setHeaderFontSize(int value) {
    _headerFontSize = value;
    _saveToStorage();
    notifyListeners();
  }

  void setFooterFontSize(int value) {
    _footerFontSize = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipColor(int value) {
    _tipColor = value;
    _saveToStorage();
    notifyListeners();
  }

  void setTipDividerColor(int value) {
    _tipDividerColor = value;
    _saveToStorage();
    notifyListeners();
  }
}
