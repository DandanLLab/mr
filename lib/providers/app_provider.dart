import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppProvider extends ChangeNotifier {
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
  // 夜间模式
  Color _nightPrimaryColor = const Color(0xFF303030); // 深灰
  Color _nightAccentColor = const Color(0xFFE0E0E0); // 浅灰
  Color _nightBackgroundColor = const Color(0xFF424242); // Grey 800
  Color _nightSurfaceColor = const Color(0xFF303030); // Grey 700

  ThemeMode get themeMode => _themeMode;
  bool get isNoImageMode => _isNoImageMode;
  String? get nickname => _nickname;
  int get concurrentSearchLimit => _concurrentSearchLimit;

  Color get dayPrimaryColor => _dayPrimaryColor;
  Color get dayAccentColor => _dayAccentColor;
  Color get dayBackgroundColor => _dayBackgroundColor;
  Color get daySurfaceColor => _daySurfaceColor;
  Color get nightPrimaryColor => _nightPrimaryColor;
  Color get nightAccentColor => _nightAccentColor;
  Color get nightBackgroundColor => _nightBackgroundColor;
  Color get nightSurfaceColor => _nightSurfaceColor;

  // 获取日间主题
  ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.light(
        primary: _dayPrimaryColor,
        secondary: _dayAccentColor,
        surface: _daySurfaceColor,
        background: _dayBackgroundColor,
        onPrimary: Colors.white, // primary 色上的文字颜色
        onSecondary: Colors.white, // secondary 色上的文字颜色
        onSurface: Colors.black87, // surface 色上的文字颜色
        onBackground: Colors.black87, // background 色上的文字颜色
        error: const Color(0xFFE53935),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: _dayBackgroundColor,
      appBarTheme: AppBarTheme(
        backgroundColor: _dayPrimaryColor,
        foregroundColor: Colors.white,
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _dayPrimaryColor,
        foregroundColor: Colors.white,
      ),
      // 确保文字主题正确
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.black87),
        bodyMedium: TextStyle(color: Colors.black87),
        bodySmall: TextStyle(color: Colors.black54),
        titleLarge: TextStyle(color: Colors.black87),
        titleMedium: TextStyle(color: Colors.black87),
        titleSmall: TextStyle(color: Colors.black87),
      ),
    );
  }

  // 获取夜间主题
  ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: _nightPrimaryColor,
        secondary: _nightAccentColor,
        surface: _nightSurfaceColor,
        background: _nightBackgroundColor,
        onPrimary: Colors.white, // primary 色上的文字颜色
        onSecondary: Colors.black87, // secondary 色上的文字颜色
        onSurface: Colors.white70, // surface 色上的文字颜色
        onBackground: Colors.white70, // background 色上的文字颜色
        error: const Color(0xFFE53935),
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: _nightBackgroundColor,
      appBarTheme: AppBarTheme(
        backgroundColor: _nightSurfaceColor,
        foregroundColor: Colors.white,
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _nightPrimaryColor,
        foregroundColor: Colors.white,
      ),
      // 确保文字主题正确
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.white70),
        bodyMedium: TextStyle(color: Colors.white70),
        bodySmall: TextStyle(color: Colors.white54),
        titleLarge: TextStyle(color: Colors.white),
        titleMedium: TextStyle(color: Colors.white),
        titleSmall: TextStyle(color: Colors.white70),
      ),
    );
  }

  AppProvider() {
    _loadThemeSettings();
  }

  Future<void> _loadThemeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _dayPrimaryColor = Color(prefs.getInt('dayPrimaryColor') ?? 0xFF0288D1);
    _dayAccentColor = Color(prefs.getInt('dayAccentColor') ?? 0xFFAD1457);
    _dayBackgroundColor = Color(prefs.getInt('dayBackgroundColor') ?? 0xFFFAFAFA);
    _daySurfaceColor = Color(prefs.getInt('daySurfaceColor') ?? 0xFFFFFFFF);
    _nightPrimaryColor = Color(prefs.getInt('nightPrimaryColor') ?? 0xFF303030);
    _nightAccentColor = Color(prefs.getInt('nightAccentColor') ?? 0xFFE0E0E0);
    _nightBackgroundColor = Color(prefs.getInt('nightBackgroundColor') ?? 0xFF424242);
    _nightSurfaceColor = Color(prefs.getInt('nightSurfaceColor') ?? 0xFF303030);
    notifyListeners();
  }

  Future<void> setDayThemeColors({
    Color? primaryColor,
    Color? accentColor,
    Color? backgroundColor,
    Color? surfaceColor,
  }) async {
    if (primaryColor != null) _dayPrimaryColor = primaryColor;
    if (accentColor != null) _dayAccentColor = accentColor;
    if (backgroundColor != null) _dayBackgroundColor = backgroundColor;
    if (surfaceColor != null) _daySurfaceColor = surfaceColor;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('dayPrimaryColor', _dayPrimaryColor.value);
    await prefs.setInt('dayAccentColor', _dayAccentColor.value);
    await prefs.setInt('dayBackgroundColor', _dayBackgroundColor.value);
    await prefs.setInt('daySurfaceColor', _daySurfaceColor.value);
    notifyListeners();
  }

  Future<void> setNightThemeColors({
    Color? primaryColor,
    Color? accentColor,
    Color? backgroundColor,
    Color? surfaceColor,
  }) async {
    if (primaryColor != null) _nightPrimaryColor = primaryColor;
    if (accentColor != null) _nightAccentColor = accentColor;
    if (backgroundColor != null) _nightBackgroundColor = backgroundColor;
    if (surfaceColor != null) _nightSurfaceColor = surfaceColor;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nightPrimaryColor', _nightPrimaryColor.value);
    await prefs.setInt('nightAccentColor', _nightAccentColor.value);
    await prefs.setInt('nightBackgroundColor', _nightBackgroundColor.value);
    await prefs.setInt('nightSurfaceColor', _nightSurfaceColor.value);
    notifyListeners();
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
}
