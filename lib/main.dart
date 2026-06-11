import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'providers/app_provider.dart';
import 'providers/bookshelf_provider.dart';
import 'providers/discovery_provider.dart';
import 'providers/reader_provider.dart';
import 'providers/search_provider.dart';
import 'routes/app_routes.dart';
import 'themes/app_theme.dart';
import 'services/native/js_engine.dart';
import 'services/native/engine_dispatcher.dart';
import 'services/storage_service.dart';
import 'services/source_engine/proxy_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // 启动 CORS 代理服务（仅 Web 端需要，原生端 Dio 不受 CORS 限制）
  if (kIsWeb) {
    await ProxyService.instance.start();
  }

  // 启动四引擎调度器（含 Node.js 进程，仅原生端）
  if (!kIsWeb) {
    try {
      await EngineDispatcher.instance.startNodeProxy();
      debugPrint('[四引擎] 状态:\n${EngineDispatcher.instance.statusSummary}');
    } catch (e) {
      debugPrint('[四引擎] Node.js 启动失败: $e');
    }
  }

  runApp(const DanShenqiApp());
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
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: appProvider.themeMode,
            initialRoute: AppRoutes.main,
            onGenerateRoute: AppRoutes.generateRoute,
          );
        },
      ),
    );
  }
}
