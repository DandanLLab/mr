import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'providers/app_provider.dart';
import 'providers/bookshelf_provider.dart';
import 'providers/discovery_provider.dart';
import 'providers/explore_show_provider.dart';
import 'providers/reader_provider.dart';
import 'providers/search_provider.dart';
import 'routes/app_routes.dart';
import 'services/app_logger.dart';
import 'services/crash_log_service.dart';
import 'services/native/js_engine.dart';
import 'services/storage_service.dart';
import 'services/source_engine/proxy_service.dart';
import 'services/cover_config_service.dart';
import 'widgets/themed_background.dart';

void main() async {
  // 在 Zone 中运行，捕获所有未处理的异步错误
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // 初始化崩溃日志服务（必须最先，注册全局错误捕获）
    await CrashLogService.instance.init();

    // 初始化应用日志文件系统（启动即记录所有操作日志）
    AppLogger.instance.initFileLogging();

    try {
      await Hive.initFlutter();
      await StorageService.instance.init();
      if (!StorageService.instance.isInitialized) {
        debugPrint('❌ StorageService 初始化失败: ${StorageService.instance.initError}');
      }
    } catch (e) {
      debugPrint('❌ Storage init error: $e');
    }

    try {
      await JsEngine.instance.init();
    } catch (e) {
      debugPrint('JsEngine init error: $e');
    }

    // 初始化封面配置服务
    try {
      await CoverConfigService.instance.init();
    } catch (e) {
      debugPrint('CoverConfigService init error: $e');
    }

    // 启动 CORS 代理服务（仅 Web 端需要，原生端 Dio 不受 CORS 限制）
    if (kIsWeb) {
      await ProxyService.instance.start();
    }

    runApp(const DanShenqiApp());
  }, (error, stack) {
    // Zone 级未捕获错误
    CrashLogService.instance.recordError(error, stack, type: 'zone');
  });
}

class DanShenqiApp extends StatelessWidget {
  const DanShenqiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider()),
        ChangeNotifierProvider(create: (_) => BookshelfProvider()),
        ChangeNotifierProvider(create: (_) => DiscoveryProvider()),
        ChangeNotifierProvider(create: (_) => ExploreShowProvider()),
        ChangeNotifierProvider(create: (_) => ReaderProvider()),
        ChangeNotifierProvider(create: (_) => SearchProvider()),
      ],
      child: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          return MaterialApp(
            title: 'mr',
            debugShowCheckedModeBanner: false,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('zh', 'CN'),
              Locale('zh', 'TW'),
              Locale('en', 'US'),
            ],
            locale: const Locale('zh', 'CN'),
            theme: appProvider.lightTheme,
            darkTheme: appProvider.darkTheme,
            themeMode: appProvider.themeMode,
            initialRoute: AppRoutes.main,
            onGenerateRoute: AppRoutes.generateRoute,
            // 应用全局背景图片
            builder: (context, widget) {
              final mediaQuery = MediaQuery.of(context);
              // 启动时检查是否有崩溃日志
              _checkAndShowCrashDialog(context);
              return ThemedBackground(
                child: MediaQuery(
                  data: mediaQuery.copyWith(
                    textScaler: TextScaler.linear(
                      appProvider.currentFontScale / 10,
                    ),
                  ),
                  child: widget ?? const SizedBox(),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 启动时检查是否有崩溃日志，有则弹窗显示
  static bool _crashDialogShown = false;
  void _checkAndShowCrashDialog(BuildContext context) {
    if (_crashDialogShown) return;
    if (!CrashLogService.instance.hasNewCrash) return;
    if (CrashLogService.instance.entries.isEmpty) return;

    _crashDialogShown = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      _showCrashDialog(context);
    });
  }

  void _showCrashDialog(BuildContext context) {
    final lastCrash = CrashLogService.instance.entries.last;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Text('应用崩溃日志'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '检测到上次运行时发生崩溃，崩溃日志已自动复制到粘贴板。',
                  style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    lastCrash.toFullString(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: lastCrash.toFullString()));
              Navigator.pop(ctx);
            },
            child: const Text('复制并关闭'),
          ),
          TextButton(
            onPressed: () {
              CrashLogService.instance.markCrashViewed();
              Navigator.pop(ctx);
            },
            child: const Text('仅关闭'),
          ),
        ],
      ),
    ).then((_) {
      CrashLogService.instance.markCrashViewed();
    });
  }
}
