import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'providers/app_provider.dart';
import 'providers/bookshelf_provider.dart';
import 'providers/discovery_provider.dart';
import 'providers/reader_provider.dart';
import 'routes/app_routes.dart';
import 'themes/app_theme.dart';
import 'services/nojs_engine.dart';
import 'services/storage_service.dart';
import 'services/source_engine/proxy_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Hive.initFlutter();
    await StorageService.instance.init();
  } catch (e) {
    debugPrint('Storage init error: $e');
  }

  try {
    await NojsEngine.instance.init();
  } catch (e) {
    debugPrint('NojsEngine init error: $e');
  }

  // 启动代理服务（非 Web 平台）
  if (!kIsWeb) {
    await ProxyService.instance.start(port: 8888);
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
      ],
      child: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          return MaterialApp(
            title: 'mr',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: appProvider.themeMode,
            initialRoute: AppRoutes.splash,
            onGenerateRoute: AppRoutes.generateRoute,
          );
        },
      ),
    );
  }
}
