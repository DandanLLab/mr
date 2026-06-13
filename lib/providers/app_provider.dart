import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppProvider extends ChangeNotifier with WidgetsBindingObserver {
  AppProvider() {
    WidgetsBinding.instance.addObserver(this);
    _loadThemeSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static final Map<String, String> _loadedFonts = {};

  ThemeMode _themeMode = ThemeMode.system;
  bool _isNoImageMode = false;
  String? _nickname;
  int _concurrentSearchLimit = 5;

  // 自定义主题颜色（默认使用原版 legado 的默认主题 - Light Blue）
  // 日间模式：primary = Light Blue 600, accent = Pink 800
  Color _dayPrimaryColor = const Color(0xFF0288D1); // Light Blue 600
  Color _dayAccentColor = const Color(0xFFAD1457); // Pink 800
  Color _dayBackgroundColor = const Color(0xFFFAFAFA); // Grey 50
  Color _daySurfaceColor = const Color(0xFFFFFFFF); // White
  Color _dayNavBarColor = const Color(0xFFF5F5F5);
  // 夜间模式
  Color _nightPrimaryColor = const Color(0xFF303030); // 深灰
  Color _nightAccentColor = const Color(0xFFE0E0E0); // 浅灰
  Color _nightBackgroundColor = const Color(0xFF424242); // Grey 800
  Color _nightSurfaceColor = const Color(0xFF303030); // Grey 700
  Color _nightNavBarColor = const Color(0xFF000000);

  // 背景图片设置
  String? _dayBackgroundImage;
  String? _nightBackgroundImage;
  int _dayBackgroundBlur = 0;
  int _nightBackgroundBlur = 0;
  String? _dayBookInfoBackgroundImage;
  String? _nightBookInfoBackgroundImage;
  String? _dayPanelBackgroundImage;
  String? _nightPanelBackgroundImage;
  String _dayPanelBackgroundMode = 'crop';
  String _nightPanelBackgroundMode = 'crop';
  double _dayCornerScale = 1;
  double _nightCornerScale = 1;
  int _dayLayoutAlpha = 100;
  int _nightLayoutAlpha = 100;
  Color? _dayPanelBorderColor;
  Color? _nightPanelBorderColor;
  int _dayPanelBorderAlpha = 100;
  int _nightPanelBorderAlpha = 100;
  bool _daySearchFollow = false;
  bool _nightSearchFollow = false;
  bool _dayReplyFollow = false;
  bool _nightReplyFollow = false;
  int _dayFontScale = 10;
  int _nightFontScale = 10;
  String? _dayUiFontPath;
  String? _nightUiFontPath;
  String? _dayTitleFontPath;
  String? _nightTitleFontPath;
  String? _dayUiFontFamily;
  String? _nightUiFontFamily;
  String? _dayTitleFontFamily;
  String? _nightTitleFontFamily;

  // 底栏配置
  String _navBarLayoutMode = 'floating'; // floating, standard, sidebar
  String _navBarEffectMode = 'glass'; // solid, glass, frosted
  int _navBarOpacity = 72;
  int? _navBarBorderColor;
  int _navBarBorderAlpha = 100;
  String? _navBarWallpaperPath;
  String? _navBarSidebarBackgroundPath;
  String _navBarSidebarGravity = 'start'; // start, end

  ThemeMode get themeMode => _themeMode;
  bool get isNoImageMode => _isNoImageMode;
  String? get nickname => _nickname;
  int get concurrentSearchLimit => _concurrentSearchLimit;

  Color get dayPrimaryColor => _dayPrimaryColor;
  Color get dayAccentColor => _dayAccentColor;
  Color get dayBackgroundColor => _dayBackgroundColor;
  Color get daySurfaceColor => _daySurfaceColor;
  Color get dayNavBarColor => _dayNavBarColor;
  Color get nightPrimaryColor => _nightPrimaryColor;
  Color get nightAccentColor => _nightAccentColor;
  Color get nightBackgroundColor => _nightBackgroundColor;
  Color get nightSurfaceColor => _nightSurfaceColor;
  Color get nightNavBarColor => _nightNavBarColor;

  // 背景图片 getter
  String? get dayBackgroundImage => _dayBackgroundImage;
  String? get nightBackgroundImage => _nightBackgroundImage;
  int get dayBackgroundBlur => _dayBackgroundBlur;
  int get nightBackgroundBlur => _nightBackgroundBlur;

  // 底栏配置 getter
  String get navBarLayoutMode => _navBarLayoutMode;
  String get navBarEffectMode => _navBarEffectMode;
  int get navBarOpacity => _navBarOpacity;
  int? get navBarBorderColor => _navBarBorderColor;
  int get navBarBorderAlpha => _navBarBorderAlpha;
  String? get navBarWallpaperPath => _navBarWallpaperPath;
  String? get navBarSidebarBackgroundPath => _navBarSidebarBackgroundPath;
  String get navBarSidebarGravity => _navBarSidebarGravity;

  // 获取当前主题的背景图片
  String? get currentBackgroundImage {
    if (_themeMode == ThemeMode.dark) {
      return _nightBackgroundImage;
    } else if (_themeMode == ThemeMode.light) {
      return _dayBackgroundImage;
    } else {
      // 跟随系统
      final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark ? _nightBackgroundImage : _dayBackgroundImage;
    }
  }

  // 获取当前主题的背景模糊度
  int get currentBackgroundBlur {
    if (_themeMode == ThemeMode.dark) {
      return _nightBackgroundBlur;
    } else if (_themeMode == ThemeMode.light) {
      return _dayBackgroundBlur;
    } else {
      final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark ? _nightBackgroundBlur : _dayBackgroundBlur;
    }
  }

  bool get _usesNightTheme {
    if (_themeMode == ThemeMode.dark) return true;
    if (_themeMode == ThemeMode.light) return false;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  String? get currentBookInfoBackgroundImage => _usesNightTheme
      ? _nightBookInfoBackgroundImage
      : _dayBookInfoBackgroundImage;
  String? get currentPanelBackgroundImage =>
      _usesNightTheme ? _nightPanelBackgroundImage : _dayPanelBackgroundImage;
  String get currentPanelBackgroundMode =>
      _usesNightTheme ? _nightPanelBackgroundMode : _dayPanelBackgroundMode;
  double get currentCornerScale =>
      _usesNightTheme ? _nightCornerScale : _dayCornerScale;
  int get currentLayoutAlpha =>
      _usesNightTheme ? _nightLayoutAlpha : _dayLayoutAlpha;
  Color? get currentPanelBorderColor =>
      _usesNightTheme ? _nightPanelBorderColor : _dayPanelBorderColor;
  int get currentPanelBorderAlpha =>
      _usesNightTheme ? _nightPanelBorderAlpha : _dayPanelBorderAlpha;
  bool get currentSearchFollow =>
      _usesNightTheme ? _nightSearchFollow : _daySearchFollow;
  bool get currentReplyFollow =>
      _usesNightTheme ? _nightReplyFollow : _dayReplyFollow;
  int get currentFontScale =>
      _usesNightTheme ? _nightFontScale : _dayFontScale;

  Color get currentNavBarColor {
    if (_themeMode == ThemeMode.dark) {
      return _nightNavBarColor;
    } else if (_themeMode == ThemeMode.light) {
      return _dayNavBarColor;
    }
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    return brightness == Brightness.dark
        ? _nightNavBarColor
        : _dayNavBarColor;
  }

  // 获取日间主题
  ThemeData get lightTheme {
    // 如果有背景图片，Scaffold 背景色设置为透明，这样背景图片才能显示
    final scaffoldBgColor = (_dayBackgroundImage != null && _dayBackgroundImage!.isNotEmpty)
        ? Colors.transparent
        : _dayBackgroundColor;

    final panelRadius = 10 * _dayCornerScale;
    final panelBorder = _panelBorder(
      _dayPanelBorderColor,
      _dayPanelBorderAlpha,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: _dayUiFontFamily,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: _dayPrimaryColor,
        secondary: _dayAccentColor,
        surface: _daySurfaceColor,
        background: _dayBackgroundColor,
        onPrimary: _foregroundFor(_dayPrimaryColor),
        onSecondary: _foregroundFor(_dayAccentColor),
        onSurface: const Color(0xDE000000), // surface 色上的文字颜色 (87%黑)
        onSurfaceVariant: const Color(0x8A000000), // 次要文字颜色 (54%黑)
        onBackground: const Color(0xDE000000), // background 色上的文字颜色 (87%黑)
        error: const Color(0xFFE53935),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: scaffoldBgColor,
      appBarTheme: AppBarTheme(
        toolbarHeight: 48,
        backgroundColor: _dayPrimaryColor,
        foregroundColor: _foregroundFor(_dayPrimaryColor), // 根据实际 primary 颜色明暗决定（参考 legado-main）
        titleTextStyle: TextStyle(
          color: _foregroundFor(_dayPrimaryColor),
          fontSize: 20,
          fontWeight: FontWeight.normal,
          fontFamily: _dayTitleFontFamily ?? _dayUiFontFamily,
        ),
      ),
      cardTheme: CardThemeData(
        color: _daySurfaceColor.withValues(alpha: _dayLayoutAlpha / 100),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: panelBorder,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: _daySurfaceColor.withValues(
          alpha: _dayLayoutAlpha / 100,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: panelBorder,
        ),
      ),
      inputDecorationTheme: _inputDecorationTheme(
        _dayReplyFollow,
        panelRadius,
        _daySurfaceColor,
        _dayLayoutAlpha,
      ),
      switchTheme: _switchTheme(_dayAccentColor),
      checkboxTheme: _checkboxTheme(_dayAccentColor),
      radioTheme: _radioTheme(_dayAccentColor),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: _dayAccentColor,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: _dayNavBarColor,
        selectedItemColor: _dayAccentColor,
        unselectedItemColor: Colors.black54,
        elevation: 4,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _dayNavBarColor,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? _dayAccentColor
                : Colors.black54,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _dayPrimaryColor,
        foregroundColor: _foregroundFor(_dayPrimaryColor),
      ),
      // 确保文字主题正确
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Color(0xDE000000)), // 87%黑
        bodyMedium: TextStyle(color: Color(0xDE000000)), // 87%黑
        bodySmall: TextStyle(color: Color(0x8A000000)), // 54%黑
        titleLarge: TextStyle(color: Color(0xDE000000)), // 87%黑
        titleMedium: TextStyle(color: Color(0xDE000000)), // 87%黑
        titleSmall: TextStyle(color: Color(0xDE000000)), // 87%黑
      ),
    );
  }

  // 获取夜间主题
  ThemeData get darkTheme {
    // 如果有背景图片，Scaffold 背景色设置为透明，这样背景图片才能显示
    final scaffoldBgColor = (_nightBackgroundImage != null && _nightBackgroundImage!.isNotEmpty)
        ? Colors.transparent
        : _nightBackgroundColor;

    final panelRadius = 10 * _nightCornerScale;
    final panelBorder = _panelBorder(
      _nightPanelBorderColor,
      _nightPanelBorderAlpha,
    );
    return ThemeData(
      useMaterial3: true,
      fontFamily: _nightUiFontFamily,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _nightPrimaryColor,
        secondary: _nightAccentColor,
        surface: _nightSurfaceColor,
        background: _nightBackgroundColor,
        onPrimary: _foregroundFor(_nightPrimaryColor),
        onSecondary: _foregroundFor(_nightAccentColor),
        onSurface: const Color(0xDEFFFFFF), // surface 色上的文字颜色 (87%白)
        onSurfaceVariant: const Color(0xB3FFFFFF), // 次要文字颜色 (70%白)
        onBackground: const Color(0xDEFFFFFF), // background 色上的文字颜色 (87%白)
        error: const Color(0xFFE53935),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: scaffoldBgColor,
      appBarTheme: AppBarTheme(
        toolbarHeight: 48,
        backgroundColor: _nightPrimaryColor,
        foregroundColor: _foregroundFor(_nightPrimaryColor), // 根据实际 primary 颜色明暗决定（参考 legado-main）
        titleTextStyle: TextStyle(
          color: _foregroundFor(_nightPrimaryColor),
          fontSize: 20,
          fontWeight: FontWeight.normal,
          fontFamily: _nightTitleFontFamily ?? _nightUiFontFamily,
        ),
      ),
      cardTheme: CardThemeData(
        color: _nightSurfaceColor.withValues(alpha: _nightLayoutAlpha / 100),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: panelBorder,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: _nightSurfaceColor.withValues(
          alpha: _nightLayoutAlpha / 100,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: panelBorder,
        ),
      ),
      inputDecorationTheme: _inputDecorationTheme(
        _nightReplyFollow,
        panelRadius,
        _nightSurfaceColor,
        _nightLayoutAlpha,
      ),
      switchTheme: _switchTheme(_nightAccentColor),
      checkboxTheme: _checkboxTheme(_nightAccentColor),
      radioTheme: _radioTheme(_nightAccentColor),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: _nightAccentColor,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: _nightNavBarColor,
        selectedItemColor: _nightAccentColor,
        unselectedItemColor: Colors.white70,
        elevation: 4,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _nightNavBarColor,
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? _nightAccentColor
                : Colors.white70,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _nightPrimaryColor,
        foregroundColor: _foregroundFor(_nightPrimaryColor),
      ),
      // 确保文字主题正确
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Color(0xDEFFFFFF)), // 87%白
        bodyMedium: TextStyle(color: Color(0xDEFFFFFF)), // 87%白
        bodySmall: TextStyle(color: Color(0xB3FFFFFF)), // 70%白
        titleLarge: TextStyle(color: Color(0xFFFFFFFF)), // 100%白
        titleMedium: TextStyle(color: Color(0xDEFFFFFF)), // 87%白
        titleSmall: TextStyle(color: Color(0xDEFFFFFF)), // 87%白
      ),
    );
  }

  @override
  void didChangePlatformBrightness() {
    if (_themeMode == ThemeMode.system) {
      notifyListeners();
    }
  }

  Future<void> _loadThemeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _dayPrimaryColor = Color(prefs.getInt('dayPrimaryColor') ?? 0xFF0288D1);
    _dayAccentColor = Color(prefs.getInt('dayAccentColor') ?? 0xFFAD1457);
    _dayBackgroundColor = Color(prefs.getInt('dayBackgroundColor') ?? 0xFFFAFAFA);
    _daySurfaceColor = Color(prefs.getInt('daySurfaceColor') ?? 0xFFFFFFFF);
    _dayNavBarColor = Color(prefs.getInt('dayNavBarColor') ?? 0xFFF5F5F5);
    _nightPrimaryColor = Color(prefs.getInt('nightPrimaryColor') ?? 0xFF303030);
    _nightAccentColor = Color(prefs.getInt('nightAccentColor') ?? 0xFFE0E0E0);
    _nightBackgroundColor = Color(prefs.getInt('nightBackgroundColor') ?? 0xFF424242);
    _nightSurfaceColor = Color(prefs.getInt('nightSurfaceColor') ?? 0xFF303030);
    _nightNavBarColor = Color(prefs.getInt('nightNavBarColor') ?? 0xFF000000);

    // 加载背景图片设置
    _dayBackgroundImage = prefs.getString('dayBackgroundImage');
    _nightBackgroundImage = prefs.getString('nightBackgroundImage');
    _dayBackgroundBlur = prefs.getInt('dayBackgroundBlur') ?? 0;
    _nightBackgroundBlur = prefs.getInt('nightBackgroundBlur') ?? 0;
    _dayBookInfoBackgroundImage = prefs.getString('dayBookInfoBackgroundImage');
    _nightBookInfoBackgroundImage =
        prefs.getString('nightBookInfoBackgroundImage');
    _dayPanelBackgroundImage = prefs.getString('dayPanelBackgroundImage');
    _nightPanelBackgroundImage = prefs.getString('nightPanelBackgroundImage');
    _dayPanelBackgroundMode =
        prefs.getString('dayPanelBackgroundMode') ?? 'crop';
    _nightPanelBackgroundMode =
        prefs.getString('nightPanelBackgroundMode') ?? 'crop';
    _dayCornerScale = prefs.getDouble('dayCornerScale') ?? 1;
    _nightCornerScale = prefs.getDouble('nightCornerScale') ?? 1;
    _dayLayoutAlpha = prefs.getInt('dayLayoutAlpha') ?? 100;
    _nightLayoutAlpha = prefs.getInt('nightLayoutAlpha') ?? 100;
    _dayPanelBorderColor = _storedColor(prefs, 'dayPanelBorderColor');
    _nightPanelBorderColor = _storedColor(prefs, 'nightPanelBorderColor');
    _dayPanelBorderAlpha = prefs.getInt('dayPanelBorderAlpha') ?? 100;
    _nightPanelBorderAlpha = prefs.getInt('nightPanelBorderAlpha') ?? 100;
    _daySearchFollow = prefs.getBool('daySearchFollow') ?? false;
    _nightSearchFollow = prefs.getBool('nightSearchFollow') ?? false;
    _dayReplyFollow = prefs.getBool('dayReplyFollow') ?? false;
    _nightReplyFollow = prefs.getBool('nightReplyFollow') ?? false;
    _dayFontScale = prefs.getInt('dayFontScale') ?? 10;
    _nightFontScale = prefs.getInt('nightFontScale') ?? 10;
    _dayUiFontPath = prefs.getString('dayUiFontPath');
    _nightUiFontPath = prefs.getString('nightUiFontPath');
    _dayTitleFontPath = prefs.getString('dayTitleFontPath');
    _nightTitleFontPath = prefs.getString('nightTitleFontPath');
    _dayUiFontFamily = await _loadFont(_dayUiFontPath, 'day_ui');
    _nightUiFontFamily = await _loadFont(_nightUiFontPath, 'night_ui');
    _dayTitleFontFamily = await _loadFont(_dayTitleFontPath, 'day_title');
    _nightTitleFontFamily = await _loadFont(_nightTitleFontPath, 'night_title');

    // 加载底栏配置
    _navBarLayoutMode = prefs.getString('navBarLayoutMode') ?? 'floating';
    _navBarEffectMode = prefs.getString('navBarEffectMode') ?? 'glass';
    _navBarOpacity = prefs.getInt('navBarOpacity') ?? 72;
    final borderColorValue = prefs.getInt('navBarBorderColor');
    _navBarBorderColor = borderColorValue != null && borderColorValue != 0 ? borderColorValue : null;
    _navBarBorderAlpha = prefs.getInt('navBarBorderAlpha') ?? 100;
    _navBarWallpaperPath = prefs.getString('navBarWallpaperPath');
    _navBarSidebarBackgroundPath = prefs.getString('navBarSidebarBackgroundPath');
    _navBarSidebarGravity = prefs.getString('navBarSidebarGravity') ?? 'start';

    notifyListeners();
  }

  Future<void> setDayThemeColors({
    Color? primaryColor,
    Color? accentColor,
    Color? backgroundColor,
    Color? surfaceColor,
    Color? navBarColor,
    String? backgroundImage,
    int? backgroundBlur,
    String? bookInfoBackgroundImage,
    String? panelBackgroundImage,
    String? panelBackgroundMode,
    double? cornerScale,
    int? layoutAlpha,
    Color? panelBorderColor,
    int? panelBorderAlpha,
    bool? searchFollow,
    bool? replyFollow,
    int? fontScale,
    String? uiFontPath,
    String? titleFontPath,
  }) async {
    if (primaryColor != null) _dayPrimaryColor = primaryColor;
    if (accentColor != null) _dayAccentColor = accentColor;
    if (backgroundColor != null) _dayBackgroundColor = backgroundColor;
    if (surfaceColor != null) _daySurfaceColor = surfaceColor;
    if (navBarColor != null) _dayNavBarColor = navBarColor;
    if (backgroundImage != null) _dayBackgroundImage = backgroundImage.isEmpty ? null : backgroundImage;
    if (backgroundBlur != null) _dayBackgroundBlur = backgroundBlur;
    _dayBookInfoBackgroundImage = _updatedPath(
      bookInfoBackgroundImage,
      _dayBookInfoBackgroundImage,
    );
    _dayPanelBackgroundImage = _updatedPath(
      panelBackgroundImage,
      _dayPanelBackgroundImage,
    );
    if (panelBackgroundMode != null) {
      _dayPanelBackgroundMode = panelBackgroundMode;
    }
    if (cornerScale != null) _dayCornerScale = cornerScale.clamp(0, 3);
    if (layoutAlpha != null) _dayLayoutAlpha = layoutAlpha.clamp(0, 100);
    if (panelBorderColor != null) {
      _dayPanelBorderColor = panelBorderColor.a == 0 ? null : panelBorderColor;
    }
    if (panelBorderAlpha != null) {
      _dayPanelBorderAlpha = panelBorderAlpha.clamp(0, 100);
    }
    if (searchFollow != null) _daySearchFollow = searchFollow;
    if (replyFollow != null) _dayReplyFollow = replyFollow;
    if (fontScale != null) _dayFontScale = fontScale.clamp(8, 16);
    if (uiFontPath != null) {
      _dayUiFontPath = uiFontPath.isEmpty ? null : uiFontPath;
      _dayUiFontFamily = await _loadFont(_dayUiFontPath, 'day_ui');
    }
    if (titleFontPath != null) {
      _dayTitleFontPath = titleFontPath.isEmpty ? null : titleFontPath;
      _dayTitleFontFamily = await _loadFont(_dayTitleFontPath, 'day_title');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('dayPrimaryColor', _dayPrimaryColor.value);
    await prefs.setInt('dayAccentColor', _dayAccentColor.value);
    await prefs.setInt('dayBackgroundColor', _dayBackgroundColor.value);
    await prefs.setInt('daySurfaceColor', _daySurfaceColor.value);
    await prefs.setInt('dayNavBarColor', _dayNavBarColor.value);
    await _saveThemeExtras(prefs, isNight: false);
    if (backgroundImage != null) {
      if (backgroundImage.isEmpty) {
        await prefs.remove('dayBackgroundImage');
      } else {
        await prefs.setString('dayBackgroundImage', backgroundImage);
      }
    }
    if (backgroundBlur != null) {
      await prefs.setInt('dayBackgroundBlur', backgroundBlur);
    }

    notifyListeners();
  }

  Future<void> setNightThemeColors({
    Color? primaryColor,
    Color? accentColor,
    Color? backgroundColor,
    Color? surfaceColor,
    Color? navBarColor,
    String? backgroundImage,
    int? backgroundBlur,
    String? bookInfoBackgroundImage,
    String? panelBackgroundImage,
    String? panelBackgroundMode,
    double? cornerScale,
    int? layoutAlpha,
    Color? panelBorderColor,
    int? panelBorderAlpha,
    bool? searchFollow,
    bool? replyFollow,
    int? fontScale,
    String? uiFontPath,
    String? titleFontPath,
  }) async {
    if (primaryColor != null) _nightPrimaryColor = primaryColor;
    if (accentColor != null) _nightAccentColor = accentColor;
    if (backgroundColor != null) _nightBackgroundColor = backgroundColor;
    if (surfaceColor != null) _nightSurfaceColor = surfaceColor;
    if (navBarColor != null) _nightNavBarColor = navBarColor;
    if (backgroundImage != null) _nightBackgroundImage = backgroundImage.isEmpty ? null : backgroundImage;
    if (backgroundBlur != null) _nightBackgroundBlur = backgroundBlur;
    _nightBookInfoBackgroundImage = _updatedPath(
      bookInfoBackgroundImage,
      _nightBookInfoBackgroundImage,
    );
    _nightPanelBackgroundImage = _updatedPath(
      panelBackgroundImage,
      _nightPanelBackgroundImage,
    );
    if (panelBackgroundMode != null) {
      _nightPanelBackgroundMode = panelBackgroundMode;
    }
    if (cornerScale != null) _nightCornerScale = cornerScale.clamp(0, 3);
    if (layoutAlpha != null) _nightLayoutAlpha = layoutAlpha.clamp(0, 100);
    if (panelBorderColor != null) {
      _nightPanelBorderColor =
          panelBorderColor.a == 0 ? null : panelBorderColor;
    }
    if (panelBorderAlpha != null) {
      _nightPanelBorderAlpha = panelBorderAlpha.clamp(0, 100);
    }
    if (searchFollow != null) _nightSearchFollow = searchFollow;
    if (replyFollow != null) _nightReplyFollow = replyFollow;
    if (fontScale != null) _nightFontScale = fontScale.clamp(8, 16);
    if (uiFontPath != null) {
      _nightUiFontPath = uiFontPath.isEmpty ? null : uiFontPath;
      _nightUiFontFamily = await _loadFont(_nightUiFontPath, 'night_ui');
    }
    if (titleFontPath != null) {
      _nightTitleFontPath = titleFontPath.isEmpty ? null : titleFontPath;
      _nightTitleFontFamily = await _loadFont(
        _nightTitleFontPath,
        'night_title',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nightPrimaryColor', _nightPrimaryColor.value);
    await prefs.setInt('nightAccentColor', _nightAccentColor.value);
    await prefs.setInt('nightBackgroundColor', _nightBackgroundColor.value);
    await prefs.setInt('nightSurfaceColor', _nightSurfaceColor.value);
    await prefs.setInt('nightNavBarColor', _nightNavBarColor.value);
    await _saveThemeExtras(prefs, isNight: true);
    if (backgroundImage != null) {
      if (backgroundImage.isEmpty) {
        await prefs.remove('nightBackgroundImage');
      } else {
        await prefs.setString('nightBackgroundImage', backgroundImage);
      }
    }
    if (backgroundBlur != null) {
      await prefs.setInt('nightBackgroundBlur', backgroundBlur);
    }

    notifyListeners();
  }

  static Color _foregroundFor(Color background) {
    return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
        ? Colors.white
        : Colors.black87;
  }

  static BorderSide _panelBorder(Color? color, int alpha) {
    if (color == null) return BorderSide.none;
    return BorderSide(color: color.withValues(alpha: alpha / 100));
  }

  static InputDecorationTheme _inputDecorationTheme(
    bool followTheme,
    double radius,
    Color surface,
    int alpha,
  ) {
    if (!followTheme) return const InputDecorationTheme();
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide.none,
    );
    return InputDecorationTheme(
      filled: true,
      fillColor: surface.withValues(alpha: alpha / 100),
      border: border,
      enabledBorder: border,
      focusedBorder: border,
    );
  }

  static Color? _storedColor(SharedPreferences prefs, String key) {
    final value = prefs.getInt(key);
    return value == null ? null : Color(value);
  }

  static String? _updatedPath(String? value, String? current) {
    if (value == null) return current;
    return value.isEmpty ? null : value;
  }

  Future<String?> _loadFont(String? path, String prefix) async {
    if (path == null || path.isEmpty || path.startsWith('http')) return null;
    final cached = _loadedFonts[path];
    if (cached != null) return cached;
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      final family = 'theme_${prefix}_${path.hashCode.abs()}';
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedFonts[path] = family;
      return family;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveThemeExtras(
    SharedPreferences prefs, {
    required bool isNight,
  }) async {
    final prefix = isNight ? 'night' : 'day';
    final bookInfo = isNight
        ? _nightBookInfoBackgroundImage
        : _dayBookInfoBackgroundImage;
    final panel = isNight
        ? _nightPanelBackgroundImage
        : _dayPanelBackgroundImage;
    final border = isNight ? _nightPanelBorderColor : _dayPanelBorderColor;
    await _saveOptionalString(prefs, '${prefix}BookInfoBackgroundImage', bookInfo);
    await _saveOptionalString(prefs, '${prefix}PanelBackgroundImage', panel);
    await prefs.setString(
      '${prefix}PanelBackgroundMode',
      isNight ? _nightPanelBackgroundMode : _dayPanelBackgroundMode,
    );
    await prefs.setDouble(
      '${prefix}CornerScale',
      isNight ? _nightCornerScale : _dayCornerScale,
    );
    await prefs.setInt(
      '${prefix}LayoutAlpha',
      isNight ? _nightLayoutAlpha : _dayLayoutAlpha,
    );
    if (border == null) {
      await prefs.remove('${prefix}PanelBorderColor');
    } else {
      await prefs.setInt('${prefix}PanelBorderColor', border.value);
    }
    await prefs.setInt(
      '${prefix}PanelBorderAlpha',
      isNight ? _nightPanelBorderAlpha : _dayPanelBorderAlpha,
    );
    await prefs.setBool(
      '${prefix}SearchFollow',
      isNight ? _nightSearchFollow : _daySearchFollow,
    );
    await prefs.setBool(
      '${prefix}ReplyFollow',
      isNight ? _nightReplyFollow : _dayReplyFollow,
    );
    await prefs.setInt(
      '${prefix}FontScale',
      isNight ? _nightFontScale : _dayFontScale,
    );
    await _saveOptionalString(
      prefs,
      '${prefix}UiFontPath',
      isNight ? _nightUiFontPath : _dayUiFontPath,
    );
    await _saveOptionalString(
      prefs,
      '${prefix}TitleFontPath',
      isNight ? _nightTitleFontPath : _dayTitleFontPath,
    );
  }

  static Future<void> _saveOptionalString(
    SharedPreferences prefs,
    String key,
    String? value,
  ) async {
    if (value == null || value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  static SwitchThemeData _switchTheme(Color accent) {
    return SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent.withValues(alpha: 0.5)
            : null,
      ),
    );
  }

  static CheckboxThemeData _checkboxTheme(Color accent) {
    return CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : null,
      ),
    );
  }

  static RadioThemeData _radioTheme(Color accent) {
    return RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? accent : null,
      ),
    );
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  void toggleNoImageMode() {
    _isNoImageMode = !_isNoImageMode;
    notifyListeners();
  }

  void setNickname(String name) {
    _nickname = name;
    notifyListeners();
  }

  void setConcurrentSearchLimit(int limit) {
    _concurrentSearchLimit = limit;
    notifyListeners();
  }

  // 设置底栏配置
  Future<void> setNavBarConfig({
    String? layoutMode,
    String? effectMode,
    int? opacity,
    int? borderColor,
    int? borderAlpha,
    String? wallpaperPath,
    String? sidebarBackgroundPath,
    String? sidebarGravity,
  }) async {
    if (layoutMode != null) _navBarLayoutMode = layoutMode;
    if (effectMode != null) _navBarEffectMode = effectMode;
    if (opacity != null) _navBarOpacity = opacity;
    if (borderColor != null) _navBarBorderColor = borderColor == 0 ? null : borderColor;
    if (borderAlpha != null) _navBarBorderAlpha = borderAlpha;
    if (wallpaperPath != null) _navBarWallpaperPath = wallpaperPath.isEmpty ? null : wallpaperPath;
    if (sidebarBackgroundPath != null) _navBarSidebarBackgroundPath = sidebarBackgroundPath.isEmpty ? null : sidebarBackgroundPath;
    if (sidebarGravity != null) _navBarSidebarGravity = sidebarGravity;

    final prefs = await SharedPreferences.getInstance();
    if (layoutMode != null) await prefs.setString('navBarLayoutMode', layoutMode);
    if (effectMode != null) await prefs.setString('navBarEffectMode', effectMode);
    if (opacity != null) await prefs.setInt('navBarOpacity', opacity);
    if (borderColor != null) {
      if (borderColor == 0) {
        await prefs.remove('navBarBorderColor');
      } else {
        await prefs.setInt('navBarBorderColor', borderColor);
      }
    }
    if (borderAlpha != null) await prefs.setInt('navBarBorderAlpha', borderAlpha);
    if (wallpaperPath != null) {
      if (wallpaperPath.isEmpty) {
        await prefs.remove('navBarWallpaperPath');
      } else {
        await prefs.setString('navBarWallpaperPath', wallpaperPath);
      }
    }
    if (sidebarBackgroundPath != null) {
      if (sidebarBackgroundPath.isEmpty) {
        await prefs.remove('navBarSidebarBackgroundPath');
      } else {
        await prefs.setString('navBarSidebarBackgroundPath', sidebarBackgroundPath);
      }
    }
    if (sidebarGravity != null) await prefs.setString('navBarSidebarGravity', sidebarGravity);

    notifyListeners();
  }
}
