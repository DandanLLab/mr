import 'package:flutter/material.dart';
import '../models/highlight.dart';
import '../services/storage_service.dart';

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
}
