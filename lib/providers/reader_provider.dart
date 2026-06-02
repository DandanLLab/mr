import 'package:flutter/material.dart';
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
}
