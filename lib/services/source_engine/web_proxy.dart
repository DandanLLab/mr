import 'dart:async';
import 'package:flutter/foundation.dart';
import 'web_proxy_stub.dart'
    if (dart.library.html) 'web_proxy_web.dart' as platform;

class WebProxy {
  static final WebProxy _instance = WebProxy._internal();
  static WebProxy get instance => _instance;
  WebProxy._internal();

  static const String _proxyUrl = 'http://localhost:8888/';
  static bool _proxyAvailable = false;
  static bool _proxyChecked = false;

  bool get isProxyAvailable => _proxyAvailable;
  String get proxyUrl => _proxyUrl;

  Future<String> fetch(String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('WebProxy only works on web platform');
    }

    final proxyUrl = '$_proxyUrl$url';
    
    try {
      final response = await platform.fetch(
        proxyUrl,
        method: method,
        headers: headers,
        body: body,
      );
      
      if (!_proxyAvailable) {
        _proxyAvailable = true;
        debugPrint('✅ CORS Proxy connected: $_proxyUrl');
      }
      
      return response;
    } catch (e) {
      if (!_proxyChecked) {
        _proxyChecked = true;
        debugPrint('⚠️ CORS Proxy not available. Please run: node tools/cors-proxy.js');
        debugPrint('   Error: $e');
      }
      rethrow;
    }
  }

  void resetProxyStatus() {
    _proxyChecked = false;
    _proxyAvailable = false;
  }
}
