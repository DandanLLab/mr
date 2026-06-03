import 'dart:async';
import 'package:flutter/foundation.dart';

class ProxyService {
  static final ProxyService _instance = ProxyService._internal();
  static ProxyService get instance => _instance;
  ProxyService._internal();

  bool _isRunning = false;
  int _port = 8888;

  bool get isRunning => _isRunning;
  int get port => _port;

  Future<void> start({int port = 8888}) async {
    if (kIsWeb) {
      debugPrint('Web平台需要外部代理服务');
      debugPrint('请运行: node tools/cors-proxy.js');
      return;
    }

    _port = port;
    debugPrint('代理服务在移动端不需要，直接使用Dio请求');
    _isRunning = false;
  }

  Future<void> stop() async {
    _isRunning = false;
    debugPrint('代理服务已停止');
  }
}
