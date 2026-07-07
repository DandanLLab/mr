import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// HTTP 响应封装
class HttpResponse {
  final int statusCode;
  final String body;
  final Map<String, String> headers;

  const HttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// 统一平台桥接：Dio HTTP + MethodChannel 原生 API
///
/// 网络部分（Dio）：
///   httpGet / httpPost / httpDownload / httpHead
///   HTTP/HTTPS 统一处理，不再区分平台
///
/// 原生部分（MethodChannel）：
///   TTS / 屏幕亮度 / WebView JS 执行 / Cookie / 设备信息
///   仅限 JS 引擎做不到或不合适的平台特有 API
class PlatformBridge {
  static PlatformBridge? _instance;
  static PlatformBridge get instance => _instance ??= PlatformBridge._();

  PlatformBridge._();

  /// Dio 实例（所有 HTTP 请求的唯一来源）
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    followRedirects: true,
    maxRedirects: 5,
    validateStatus: (status) => status != null && status < 600,
    responseType: ResponseType.plain,
  ));

  /// MethodChannel（原生桥接）
  static const MethodChannel _channel = MethodChannel('com.mr.app/native');

  // ===== Dio HTTP =====

  /// HTTP GET
  Future<HttpResponse> httpGet(
    String url, {
    Map<String, String>? headers,
    int timeoutMs = 15000,
  }) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          headers: headers,
          receiveTimeout: Duration(milliseconds: timeoutMs),
        ),
      );
      return HttpResponse(
        statusCode: response.statusCode ?? 200,
        body: response.data ?? '',
        headers: _extractHeaders(response),
      );
    } on DioException catch (e) {
      debugPrint('PlatformBridge.httpGet error: $url → ${e.message}');
      return HttpResponse(
        statusCode: e.response?.statusCode ?? 0,
        body: e.response?.data?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('PlatformBridge.httpGet error: $url → $e');
      return const HttpResponse(statusCode: 0, body: '');
    }
  }

  /// HTTP POST
  Future<HttpResponse> httpPost(
    String url,
    String body, {
    Map<String, String>? headers,
    int timeoutMs = 15000,
  }) async {
    try {
      final response = await _dio.post<String>(
        url,
        data: body,
        options: Options(
          headers: headers,
          receiveTimeout: Duration(milliseconds: timeoutMs),
        ),
      );
      return HttpResponse(
        statusCode: response.statusCode ?? 200,
        body: response.data ?? '',
        headers: _extractHeaders(response),
      );
    } on DioException catch (e) {
      debugPrint('PlatformBridge.httpPost error: $url → ${e.message}');
      return HttpResponse(
        statusCode: e.response?.statusCode ?? 0,
        body: e.response?.data?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('PlatformBridge.httpPost error: $url → $e');
      return const HttpResponse(statusCode: 0, body: '');
    }
  }

  /// HTTP HEAD（返回响应头）
  Future<Map<String, String>> httpHead(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.head(
        url,
        options: Options(headers: headers),
      );
      return _extractHeaders(response);
    } catch (e) {
      debugPrint('PlatformBridge.httpHead error: $url → $e');
      return {};
    }
  }

  /// 文件下载
  Future<String> httpDownload(
    String url,
    String savePath, {
    Map<String, String>? headers,
  }) async {
    try {
      await _dio.download(
        url,
        savePath,
        options: Options(headers: headers),
      );
      return savePath;
    } catch (e) {
      debugPrint('PlatformBridge.httpDownload error: $url → $e');
      return '';
    }
  }

  /// 提取响应头
  Map<String, String> _extractHeaders(Response response) {
    final result = <String, String>{};
    response.headers.map.forEach((key, values) {
      if (values.isNotEmpty) result[key] = values.first;
    });
    return result;
  }

  // ===== MethodChannel 原生 API =====

  /// 获取屏幕亮度
  Future<double> getScreenBrightness() async {
    try {
      return await _channel.invokeMethod<double>('getScreenBrightness') ?? -1;
    } on PlatformException catch (_) {
      return -1;
    } on MissingPluginException catch (_) {
      return -1;
    }
  }

  /// 设置屏幕亮度
  Future<bool> setScreenBrightness(double value) async {
    try {
      return await _channel.invokeMethod<bool>('setScreenBrightness', {
            'value': value.clamp(-1.0, 1.0),
          }) ??
          false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }

  /// 在 WebView 中执行 JS（用于需要浏览器渲染的页面）
  Future<String?> executeWebViewJs({
    required String url,
    required String jsCode,
    String? sourceRegex,
    String? html,
    int delayTime = 200,
  }) async {
    try {
      return await _channel.invokeMethod<String>('executeWebViewJs', {
        'url': url,
        'jsCode': jsCode,
        'sourceRegex': sourceRegex,
        'html': html,
        'delayTime': delayTime,
      });
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      return null;
    }
  }

  /// 获取 Cookie
  Future<String?> getCookie(String url, {String? key}) async {
    try {
      return await _channel.invokeMethod<String>('getCookie', {
        'url': url,
        'key': key,
      });
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      return null;
    }
  }

  /// 获取设备信息
  Future<Map<String, dynamic>> getDeviceInfo() async {
    try {
      final result = await _channel.invokeMethod<Map>('getDeviceInfo');
      if (result == null) return {};
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (_) {
      return {};
    } on MissingPluginException catch (_) {
      return {};
    }
  }

  // ===== TTS（通过 flutter_tts 包，不需要 MethodChannel）=====
  // TTS 由 ReaderTtsManager 通过 flutter_tts 包直接管理，此处不需要额外封装

  /// 关闭 Dio
  void dispose() {
    _dio.close();
  }
}
