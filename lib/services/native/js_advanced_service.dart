import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../models/book_source.dart';
import 'js_engine.dart';
import '../app_logger.dart';

/// 高级 JS 功能服务
/// 借鉴 legado 的 ImageUtils / BackstageWebView / SourceLoginDialog / SourceCallBack
/// 实现 coverDecodeJs / imageDecode / webJs / loginUrl / loginUi / payAction / callBackJs
class JsAdvancedService {
  JsAdvancedService._();
  static final JsAdvancedService instance = JsAdvancedService._();

  // ===== 1. 图片解密 (coverDecodeJs / imageDecode) =====

  /// 解密图片（借鉴 legado 的 ImageUtils.decode）
  ///
  /// [imageBytes] 原始图片字节数组
  /// [imageUrl] 图片 URL
  /// [source] 书源
  /// [isCover] true=封面(用coverDecodeJs), false=正文图片(用imageDecode)
  /// [book] 书籍信息（可选）
  ///
  /// JS 上下文可用变量:
  /// - result: 图片原始字节数组（Base64 字符串）
  /// - src: 图片 URL
  /// - book: 书籍信息
  /// - source: 书源信息
  /// - baseUrl: 书源 URL
  ///
  /// JS 应返回解密后的 Base64 字符串
  Future<Uint8List?> decodeImage(
    Uint8List imageBytes,
    String imageUrl, {
    required BookSource source,
    bool isCover = false,
    Map<String, dynamic>? book,
  }) async {
    final ruleJs = _getImageDecodeRule(source, isCover);
    if (ruleJs == null || ruleJs.isEmpty) return imageBytes;

    try {
      // 借鉴 legado：图片数据以 Base64 传入 JS，JS 返回 Base64
      final base64Data = base64Encode(imageBytes);
      final result = JsEngine.instance.executeSync(
        ruleJs,
        base64Data,
        baseUrl: source.bookSourceUrl,
        sourceEngine: source.engineType,
        variables: {
          'src': imageUrl,
          'source': _sourceToMap(source),
          'book': book ?? {},
        },
      );

      if (result == null) return null;

      // JS 返回 Base64 字符串
      final resultStr = result.toString();
      if (resultStr.isEmpty || resultStr == 'null' || resultStr == 'undefined') {
        return imageBytes;
      }

      // 尝试 Base64 解码
      try {
        return base64Decode(resultStr);
      } catch (_) {
        // 如果不是 Base64，可能是十六进制或其他格式
        debugPrint('⚠️ 图片解密返回非Base64格式: ${resultStr.substring(0, resultStr.length > 50 ? 50 : resultStr.length)}');
        return imageBytes;
      }
    } catch (e) {
      AppLogger.instance.logJsError('decodeImage', '图片解密失败: $e');
      return imageBytes;
    }
  }

  /// 获取图片解密规则（借鉴 legado 的 ImageUtils.getRuleJs）
  String? _getImageDecodeRule(BookSource source, bool isCover) {
    if (isCover) {
      return source.coverDecodeJs;
    } else {
      return source.ruleContent?.imageDecode;
    }
  }

  // ===== 2. WebView JS (webJs) =====

  /// 执行 webJs（借鉴 legado 的 BackstageWebView + BookContent）
  ///
  /// webJs 用于在 WebView 中执行 JS 代码获取页面内容。
  /// 当普通 HTTP 请求无法获取动态加载的内容时使用。
  ///
  /// [url] 页面 URL
  /// [webJs] 要在 WebView 中执行的 JS 代码
  /// [source] 书源
  /// [sourceRegex] 资源嗅探正则（可选）
  /// [book] 书籍信息（可选）
  /// [html] 预加载的 HTML（可选）
  ///
  /// 返回 WebView 执行 JS 后的结果
  Future<String?> executeWebJs({
    required String url,
    required String webJs,
    required BookSource source,
    String? sourceRegex,
    Map<String, dynamic>? book,
    String? html,
  }) async {
    try {
      // 借鉴 legado 的 BackstageWebView：
      // 1. 创建后台 HeadlessWebView
      // 2. 加载 URL 或 HTML
      // 3. 页面加载完成后执行 webJs
      // 4. 获取 JS 执行结果
      // 5. 如果有 sourceRegex，嗅探匹配的资源 URL

      final completer = Completer<String?>();

      // 借鉴 legado 的 WebViewPool：复用配置创建 HeadlessWebView
      final headlessWebView = HeadlessInAppWebView(
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          useWideViewPort: true,
          loadWithOverviewMode: true,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          mediaPlaybackRequiresUserGesture: false,
          // 借鉴 legado 的 WebViewPool：设置 User-Agent
          userAgent: source.header,
        ),
        onLoadStop: (controller, loadedUrl) async {
          // 借鉴 legado 的 EvalJsRunnable：页面加载完成后执行 JS
          if (!completer.isCompleted) {
            // 延迟执行，等待动态内容加载
            await Future.delayed(const Duration(milliseconds: 300));

            final jsToRun = webJs.isEmpty
                ? 'document.documentElement.outerHTML'
                : webJs;

            final result = await controller.evaluateJavascript(
              source: jsToRun,
            );

            if (!completer.isCompleted) {
              if (result != null && result.toString() != 'null') {
                var cleanResult = result.toString();
                // 借鉴 legado 的 EvalJsRunnable：清理 JSON 转义
                cleanResult = cleanResult
                    .replaceAll('\\u003C', '<')
                    .replaceAll('\\u003E', '>')
                    .replaceAll('\\/', '/')
                    .replaceAll('\\n', '\n')
                    .replaceAll('\\t', '\t')
                    .replaceAll('\\"', '"');
                completer.complete(cleanResult);
              } else {
                // 借鉴 legado 的重试机制
                await Future.delayed(const Duration(milliseconds: 500));
                final retryResult = await controller.evaluateJavascript(
                  source: jsToRun,
                );
                if (!completer.isCompleted) {
                  completer.complete(retryResult?.toString());
                }
              }
            }
          }
        },
        onConsoleMessage: (controller, consoleMessage) {
          debugPrint('🌐 WebView Console: ${consoleMessage.message}');
        },
        shouldInterceptRequest: sourceRegex != null
              ? (controller, request) async {
                // 借鉴 legado 的 SnifferWebClient：嗅探资源 URL
                final resUrl = request.url.toString();
                try {
                  if (RegExp(sourceRegex).hasMatch(resUrl)) {
                    if (!completer.isCompleted) {
                      completer.complete(resUrl);
                    }
                  }
                } catch (e) {
                  debugPrint('⚠️ sourceRegex匹配失败: $e');
                }
                return null;
              }
            : null,
      );

      try {
        // 运行 HeadlessWebView
        await headlessWebView.run();

        // 加载页面
        if (html != null && html.isNotEmpty) {
          await headlessWebView.webViewController?.loadData(
            data: html,
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: WebUri(url),
          );
        } else {
          await headlessWebView.webViewController?.loadUrl(
            urlRequest: URLRequest(url: WebUri(url)),
          );
        }

        // 借鉴 legado 的超时机制：30 秒超时
        final result = await completer.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () => null,
        );

        return result;
      } finally {
        // 确保任何路径都释放 WebView，防止内存泄漏
        await headlessWebView.dispose();
      }
    } catch (e) {
      AppLogger.instance.logJsError('executeWebJs', 'WebView JS执行失败: $e');
      return null;
    }
  }

  // ===== 3. 登录 (loginUrl / loginUi) =====

  /// 解析 loginUrl 中的 JS 代码（借鉴 legado 的 BaseSource.getLoginJs）
  String? getLoginJs(BookSource source) {
    final loginUrl = source.loginUrl;
    if (loginUrl == null || loginUrl.isEmpty) return null;

    if (loginUrl.startsWith('@js:')) {
      return loginUrl.substring(4);
    } else if (loginUrl.startsWith('<js>')) {
      final endIndex = loginUrl.lastIndexOf('</js>');
      if (endIndex > 4) {
        return loginUrl.substring(4, endIndex);
      }
    }
    // 不是 JS，是普通 URL
    return null;
  }

  /// 执行登录（借鉴 legado 的 BaseSource.login）
  ///
  /// [source] 书源
  /// [loginData] 登录表单数据
  /// [book] 书籍信息（可选）
  /// [chapter] 章节信息（可选）
  ///
  /// JS 上下文可用变量:
  /// - result: 登录表单数据 Map
  /// - book: 书籍信息
  /// - chapter: 章节信息
  /// - source: 书源信息
  /// - baseUrl: 书源 URL
  Future<bool> executeLogin({
    required BookSource source,
    required Map<String, String> loginData,
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
  }) async {
    final loginJs = getLoginJs(source);
    if (loginJs == null || loginJs.isEmpty) return false;

    try {
      // 借鉴 legado：拼接 login() 函数调用
      final fullJs = '''
        $loginJs
        if(typeof login=='function'){
          login.apply(this);
        } else {
          throw('Function login not implements!!!');
        }
      ''';

      await JsEngine.instance.processJsRule(
        jsonEncode(loginData),
        fullJs,
        baseUrl: source.bookSourceUrl,
        env: {
          'source': _sourceToMap(source),
          'book': book ?? {},
          'chapter': chapter ?? {},
        },
      );
      return true;
    } catch (e) {
      AppLogger.instance.logJsError('executeLogin', '登录执行失败: $e');
      return false;
    }
  }

  /// 解析 loginUi（借鉴 legado 的 SourceLoginDialog）
  ///
  /// loginUi 可以是 JSON 数组直接定义表单，也可以是 @js: 动态生成
  /// 返回表单定义列表
  Future<List<LoginRowUi>> parseLoginUi(BookSource source) async {
    final loginUiStr = source.loginUi;
    if (loginUiStr == null || loginUiStr.isEmpty) return [];

    String? jsonStr = loginUiStr;

    // 借鉴 legado：loginUi 支持 @js: / <js> 动态生成
    if (loginUiStr.startsWith('@js:')) {
      final jsCode = loginUiStr.substring(4);
      final result = JsEngine.instance.executeSync(
        jsCode, null,
        baseUrl: source.bookSourceUrl,
        sourceEngine: source.engineType,
        variables: {
          'source': _sourceToMap(source),
        },
      );
      jsonStr = result?.toString();
    } else if (loginUiStr.startsWith('<js>')) {
      final endIndex = loginUiStr.lastIndexOf('</js>');
      if (endIndex > 4) {
        final jsCode = loginUiStr.substring(4, endIndex);
        final result = JsEngine.instance.executeSync(
          jsCode, null,
          baseUrl: source.bookSourceUrl,
          sourceEngine: source.engineType,
          variables: {
            'source': _sourceToMap(source),
          },
        );
        jsonStr = result?.toString();
      }
    }

    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return decoded
            .map((item) => LoginRowUi.fromJson(item as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      AppLogger.instance.logJsError('parseLoginUi', '解析loginUi失败: $e');
    }
    return [];
  }

  // ===== 4. 付费操作 (payAction) =====

  /// 执行付费操作（借鉴 legado 的 ReadBookActivity.payAction）
  ///
  /// [source] 书源
  /// [book] 书籍信息
  /// [chapter] 章节信息
  ///
  /// JS 上下文可用变量:
  /// - book: 书籍信息
  /// - chapter: 章节信息
  /// - title: 章节标题
  /// - baseUrl: 章节 URL
  /// - source: 书源信息
  ///
  /// 返回值:
  /// - URL 字符串: 打开 WebView 支付页面
  /// - true/"true": 购买成功
  /// - 其他: 失败
  Future<PayActionResult> executePayAction({
    required BookSource source,
    required Map<String, dynamic> book,
    required Map<String, dynamic> chapter,
  }) async {
    final payAction = source.ruleContent?.payAction;
    if (payAction == null || payAction.isEmpty) {
      return PayActionResult.notImplemented;
    }

    try {
      final result = await JsEngine.instance.processJsRule(
        '',
        payAction,
        baseUrl: chapter['url'] ?? '',
        env: {
          'source': _sourceToMap(source),
          'book': book,
          'chapter': chapter,
        },
      );

      final resultStr = result?.toString() ?? '';

      // 借鉴 legado：返回 URL 则打开 WebView，返回 true 则标记成功
      if (resultStr.startsWith('http://') || resultStr.startsWith('https://')) {
        return PayActionResult(url: resultStr);
      } else if (resultStr.toLowerCase() == 'true') {
        return const PayActionResult(success: true);
      } else {
        return PayActionResult.notImplemented;
      }
    } catch (e) {
      AppLogger.instance.logJsError('executePayAction', '付费操作失败: $e');
      return PayActionResult.notImplemented;
    }
  }

  // ===== 5. 回调 JS (callBackJs) =====

  /// 执行回调 JS（借鉴 legado 的 SourceCallBack）
  ///
  /// [source] 书源
  /// [event] 事件名称（如 clickAuthor, startRead 等）
  /// [book] 书籍信息（可选）
  /// [chapter] 章节信息（可选）
  /// [result] 额外数据（可选）
  ///
  /// JS 上下文可用变量:
  /// - event: 事件名称
  /// - result: 额外数据
  /// - book: 书籍信息
  /// - chapter: 章节信息
  /// - source: 书源信息
  ///
  /// 返回 true 表示 JS 拦截了原生操作，false 表示执行原生默认操作
  Future<bool> executeCallBack({
    required BookSource source,
    required String event,
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
    String? result,
  }) async {
    // 借鉴 legado：eventListener 是 callBackJs 的总开关
    if (!source.eventListener) return false;

    final callBackJs = source.ruleContent?.callBackJs;
    if (callBackJs == null || callBackJs.isEmpty) return false;

    try {
      final jsResult = await JsEngine.instance.processJsRule(
        result ?? '',
        callBackJs,
        baseUrl: source.bookSourceUrl,
        env: {
          'event': event,
          'source': _sourceToMap(source),
          'book': book ?? {},
          'chapter': chapter ?? {},
        },
      );

      final resultStr = jsResult?.toString().toLowerCase() ?? '';
      // 借鉴 legado：返回 true 拦截原生操作
      return resultStr == 'true';
    } catch (e) {
      AppLogger.instance.logJsError('executeCallBack', '回调执行失败: $e');
      return false;
    }
  }

  // ===== 工具方法 =====

  Map<String, dynamic> _sourceToMap(BookSource source) {
    return {
      'bookSourceUrl': source.bookSourceUrl,
      'bookSourceName': source.bookSourceName,
      'bookSourceGroup': source.bookSourceGroup ?? '',
      'header': source.header ?? '',
      'loginUrl': source.loginUrl ?? '',
      'loginUi': source.loginUi ?? '',
      'loginCheckJs': source.loginCheckJs ?? '',
      'coverDecodeJs': source.coverDecodeJs ?? '',
      'variable': source.variable ?? '',
    };
  }
}

/// 付费操作结果（借鉴 legado 的 payAction 返回值处理）
class PayActionResult {
  final bool success;
  final String? url;

  const PayActionResult({this.success = false, this.url});

  static const notImplemented = PayActionResult();

  bool get isUrl => url != null && url!.isNotEmpty;
  bool get isSuccess => success;
}

/// 登录表单行定义（借鉴 legado 的 RowUi）
class LoginRowUi {
  final String name;
  final String type; // text / password / button / toggle / select
  final String? action; // 按钮点击时执行的 JS 代码
  final List<String>? chars; // select/toggle 的选项列表
  final String? defaultValue; // 默认值
  final String? viewName; // 显示名称

  const LoginRowUi({
    required this.name,
    this.type = 'text',
    this.action,
    this.chars,
    this.defaultValue,
    this.viewName,
  });

  factory LoginRowUi.fromJson(Map<String, dynamic> json) {
    return LoginRowUi(
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'text',
      action: json['action'] as String?,
      chars: (json['chars'] as List?)?.map((e) => e.toString()).toList(),
      defaultValue: json['default'] as String?,
      viewName: json['viewName'] as String?,
    );
  }
}

/// 回调事件常量（借鉴 legado 的 SourceCallBack）
class CallBackEvent {
  static const clickAuthor = 'clickAuthor';
  static const longClickAuthor = 'longClickAuthor';
  static const clickBookName = 'clickBookName';
  static const longClickBookName = 'longClickBookName';
  static const clickCustomButton = 'clickCustomButton';
  static const longClickCustomButton = 'longClickCustomButton';
  static const clickShareBook = 'clickShareBook';
  static const clickClearCache = 'clickClearCache';
  static const clickCopyBookUrl = 'clickCopyBookUrl';
  static const clickCopyTocUrl = 'clickCopyTocUrl';
  static const addBookShelf = 'addBookShelf';
  static const delBookShelf = 'delBookShelf';
  static const saveRead = 'saveRead';
  static const startRead = 'startRead';
  static const endRead = 'endRead';
  static const startShelfRefresh = 'startShelfRefresh';
  static const endShelfRefresh = 'endShelfRefresh';
}
