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

    // [修复 Bug #4] 初始化时序保护
    // 之前 CrashLogService.init() 在 try-catch 外，且在 Hive 之前调用
    // 虽然其内部 _loadErrorCounters/_loadCrashLogs 有 try/catch 吞异常，
    // 但若 path_provider 在某些设备上抛异常仍可能中断 init() → 后续错误捕获注册失败
    // 现统一加 try/catch 保护，确保任何服务初始化失败都不会中断 runApp
    try {
      // 初始化崩溃日志服务（必须最先，注册全局错误捕获）
      await CrashLogService.instance.init();
    } catch (e) {
      debugPrint('CrashLogService init error: $e');
    }

    // 初始化应用日志文件系统（启动即记录所有操作日志）
    try {
      AppLogger.instance.initFileLogging();
      // 启用 debugPrint 全局拦截：所有 debugPrint 输出重定向到日志系统，
      // 调试页面和日志页面均可查看，同时仍保持控制台输出
      AppLogger.enableDebugPrintCapture();
    } catch (e) {
      debugPrint('AppLogger init error: $e');
    }

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
      try {
        await ProxyService.instance.start();
      } catch (e) {
        debugPrint('ProxyService start error: $e');
      }
    }

    runApp(const DanShenqiApp());
  }, (error, stack) {
    // Zone 级未捕获错误
    CrashLogService.instance.recordError(error, stack, type: 'zone');
    // 检测 Hive 数据损坏错误（如 typeId 非法），自动触发紧急重建
    // 避免下次启动或读取时再次崩溃
    final errStr = error.toString();
    if (errStr.contains('HiveError') ||
        errStr.contains('unknown typeId') ||
        errStr.contains('Did you forget to register an adapter')) {
      debugPrint('🚨 检测到 Hive 错误，触发紧急重建: $errStr');
      // fire-and-forget，避免阻塞 zone 错误回调
      StorageService.instance.emergencyRecoverAll().catchError((e) {
        debugPrint('❌ 紧急重建失败: $e');
      });
    }
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
