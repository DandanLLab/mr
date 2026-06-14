import 'package:flutter/services.dart';
import '../app_logger.dart';

/// Android 原生平台通道
/// 桥接 OkHttp（高性能HTTP）、Jsoup（HTML解析）、加解密、数据持久化等原生库
class NativeChannel {
  static NativeChannel? _instance;
  static NativeChannel get instance => _instance ??= NativeChannel._();

  NativeChannel._();

  static const MethodChannel _channel = MethodChannel(
    'com.mr.app/native',
  );

  Future<double> getScreenBrightness() async {
    try {
      return await _channel.invokeMethod<double>('getScreenBrightness') ?? -1;
    } on PlatformException {
      return -1;
    }
  }

  Future<bool> setScreenBrightness(double value) async {
    try {
      return await _channel.invokeMethod<bool>('setScreenBrightness', {
            'value': value.clamp(-1.0, 1.0),
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// OkHttp: 高性能 HTTP 请求
  /// 支持拦截器、缓存、WebSocket、HTTP/2、连接池复用
  Future<String?> httpGet(
    String url, {
    Map<String, String>? headers,
    int timeoutMs = 10000,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('httpGet', {
        'url': url,
        'headers': headers,
        'timeoutMs': timeoutMs,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// OkHttp: POST 请求
  Future<String?> httpPost(
    String url, {
    String? body,
    Map<String, String>? headers,
    int timeoutMs = 10000,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('httpPost', {
        'url': url,
        'body': body,
        'headers': headers,
        'timeoutMs': timeoutMs,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Jsoup: 解析 HTML 并提取文本
  /// 支持CSS选择器、XPath等高级选择方式
  Future<String?> jsoupSelect(String html, String cssSelector) async {
    try {
      final result = await _channel.invokeMethod<String>('jsoupSelect', {
        'html': html,
        'selector': cssSelector,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Jsoup: 提取所有匹配元素的文本
  Future<List<String>?> jsoupSelectAll(String html, String cssSelector) async {
    try {
      final result = await _channel.invokeMethod<List>('jsoupSelectAll', {
        'html': html,
        'selector': cssSelector,
      });
      return result?.cast<String>();
    } on PlatformException {
      return null;
    }
  }

  /// Jsoup: 提取元素属性
  Future<String?> jsoupGetAttr(
    String html,
    String cssSelector,
    String attr,
  ) async {
    try {
      final result = await _channel.invokeMethod<String>('jsoupGetAttr', {
        'html': html,
        'selector': cssSelector,
        'attr': attr,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Jsoup: 清理 HTML（移除脚本/样式等）
  Future<String?> jsoupClean(String html) async {
    try {
      final result = await _channel.invokeMethod<String>('jsoupClean', {
        'html': html,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// OkHttp: 带缓存的请求（适用于书源内容缓存）
  Future<String?> httpGetWithCache(
    String url, {
    Map<String, String>? headers,
    int cacheMaxAge = 3600,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('httpGetWithCache', {
        'url': url,
        'headers': headers,
        'cacheMaxAge': cacheMaxAge,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  // ===== 新增桥接方法 =====

  /// Jsoup: 从 URL 直接解析 HTML
  Future<String?> jsoupParseUrl(
    String url, {
    Map<String, String>? headers,
    String? cssSelector,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('jsoupParseUrl', {
        'url': url,
        'headers': headers,
        'selector': cssSelector,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Jsoup: 获取所有链接
  Future<List<String>?> jsoupGetLinks(String html, {String? baseUrl}) async {
    try {
      final result = await _channel.invokeMethod<List>('jsoupGetLinks', {
        'html': html,
        'baseUrl': baseUrl,
      });
      return result?.cast<String>();
    } on PlatformException {
      return null;
    }
  }

  /// OkHttp: 下载文件
  Future<String?> httpDownload(
    String url,
    String savePath, {
    Map<String, String>? headers,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('httpDownload', {
        'url': url,
        'savePath': savePath,
        'headers': headers,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// AES 加密
  Future<String?> aesEncrypt(String data, String key, {String? iv}) async {
    try {
      final result = await _channel.invokeMethod<String>('aesEncrypt', {
        'data': data,
        'key': key,
        'iv': iv,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// AES 解密
  Future<String?> aesDecrypt(String data, String key, {String? iv}) async {
    try {
      final result = await _channel.invokeMethod<String>('aesDecrypt', {
        'data': data,
        'key': key,
        'iv': iv,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// MD5 哈希
  Future<String?> md5(String data) async {
    try {
      final result = await _channel.invokeMethod<String>('md5', {'data': data});
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// SHA1 哈希
  Future<String?> sha1(String data) async {
    try {
      final result = await _channel.invokeMethod<String>('sha1', {'data': data});
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// SHA256 哈希
  Future<String?> sha256(String data) async {
    try {
      final result = await _channel.invokeMethod<String>('sha256', {'data': data});
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// HMAC-SHA256
  Future<String?> hmacSHA256(String data, String key) async {
    try {
      final result = await _channel.invokeMethod<String>('hmacSHA256', {
        'data': data,
        'key': key,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// HTTP HEAD 请求
  Future<Map<String, String>?> httpHead(String url, {Map<String, String>? headers}) async {
    try {
      final result = await _channel.invokeMethod<Map>('httpHead', {
        'url': url,
        'headers': headers,
      });
      if (result == null) return null;
      return result.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    } on PlatformException {
      return null;
    }
  }

  /// 获取 Cookie
  Future<String?> getCookie(String url, {String? key}) async {
    try {
      final result = await _channel.invokeMethod<String>('getCookie', {
        'url': url,
        'key': key,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Base64 编码
  Future<String?> base64Encode(String data) async {
    try {
      final result = await _channel.invokeMethod<String>('base64Encode', {
        'data': data,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// Base64 解码
  Future<String?> base64Decode(String data) async {
    try {
      final result = await _channel.invokeMethod<String>('base64Decode', {
        'data': data,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// 执行 Java 规则
  Future<String?> evaluateJavaRule(
    String javaCode, {
    String? result,
    Map<String, dynamic>? env,
  }) async {
    try {
      final res = await _channel.invokeMethod<String>('evaluateJavaRule', {
        'code': javaCode,
        'result': result,
        'env': env,
      });
      return res;
    } on PlatformException {
      return null;
    }
  }

  /// 执行通用脚本（通过 Rhino 引擎）
  Future<String?> executeScript(
    String script, {
    Map<String, dynamic>? bindings,
  }) async {
    try {
      final res = await _channel.invokeMethod<String>('executeScript', {
        'script': script,
        'bindings': bindings,
      });
      return res;
    } on PlatformException {
      return null;
    }
  }

  /// 存储键值对
  Future<bool> putData(String key, String value) async {
    try {
      await _channel.invokeMethod<void>('putData', {
        'key': key,
        'value': value,
      });
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// 读取键值对
  Future<String?> getData(String key, {String defaultValue = ''}) async {
    try {
      final result = await _channel.invokeMethod<String>('getData', {
        'key': key,
        'defaultValue': defaultValue,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  /// 删除键值对
  Future<bool> deleteData(String key) async {
    try {
      await _channel.invokeMethod<void>('deleteData', {'key': key});
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// 获取设备信息（SDK版本等）
  Future<Map<String, dynamic>?> getDeviceInfo() async {
    try {
      final result = await _channel.invokeMethod<Map>('getDeviceInfo');
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on PlatformException {
      return null;
    }
  }

  // ===== WebView JS 执行（借鉴 legado 的 BackstageWebView）=====

  /// 在 WebView 中加载 URL 并执行 JS 代码
  /// 借鉴 legado 的 BackstageWebView.getStrResponse()
  ///
  /// [url] 要加载的页面 URL
  /// [jsCode] 页面加载完成后执行的 JS 代码
  /// [sourceRegex] 资源嗅探正则（可选，用于嗅探视频/音频 URL）
  /// [html] 预加载的 HTML（可选，不加载 URL 直接用 HTML）
  /// [delayTime] JS 执行延迟时间（毫秒，默认 200）
  Future<String?> executeWebViewJs({
    required String url,
    required String jsCode,
    String? sourceRegex,
    String? html,
    int delayTime = 200,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('executeWebViewJs', {
        'url': url,
        'jsCode': jsCode,
        'sourceRegex': sourceRegex,
        'html': html,
        'delayTime': delayTime,
      });
      return result;
    } on PlatformException {
      return null;
    }
  }

  // ===== 解析规则桥接（直通 Kotlin 原生 AnalyzeRule）=====
  // 等价于 legado 的 AnalyzeRule.getString/getStringList/getElements
  // 支持 Default(JSoup/CSS)、@CSS、@XPath、@JSon、{{...}}、@js:、@get:、@put: 等全部 6 种模式

  /// 解析规则取单个字符串
  /// [content] 原始内容（HTML/JSON/文本）
  /// [rule] legado 风格规则，如 `class.title@text` 或 `$.data[0].name` 或 `//h1/text()`
  /// [baseUrl] 基础 URL（用于 isUrl=true 时拼接相对路径）
  /// [isUrl] 结果是否为 URL（true 时会自动拼接成绝对路径）
  Future<String?> analyzeRuleGetString(
    String content,
    String rule, {
    String? baseUrl,
    String? redirectUrl,
    bool isUrl = false,
    bool unescape = true,
    Map<String, dynamic>? sourceInfo,
    Map<String, dynamic>? bookInfo,
    Map<String, dynamic>? chapterInfo,
    String? nextChapterUrl,
  }) async {
    try {
      return await _channel.invokeMethod<String>('analyzeRuleGetString', {
        'content': content,
        'rule': rule,
        'baseUrl': baseUrl,
        'redirectUrl': redirectUrl,
        'isUrl': isUrl,
        'unescape': unescape,
        'sourceInfo': sourceInfo,
        'bookInfo': bookInfo,
        'chapterInfo': chapterInfo,
        'nextChapterUrl': nextChapterUrl,
      });
    } on PlatformException {
      return null;
    }
  }

  /// 解析规则取字符串列表（章节名列表、图片 URL 列表等）
  Future<List<String>?> analyzeRuleGetStringList(
    String content,
    String rule, {
    String? baseUrl,
    String? redirectUrl,
    bool isUrl = false,
    Map<String, dynamic>? sourceInfo,
    Map<String, dynamic>? bookInfo,
    Map<String, dynamic>? chapterInfo,
    String? nextChapterUrl,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('analyzeRuleGetStringList', {
        'content': content,
        'rule': rule,
        'baseUrl': baseUrl,
        'redirectUrl': redirectUrl,
        'isUrl': isUrl,
        'sourceInfo': sourceInfo,
        'bookInfo': bookInfo,
        'chapterInfo': chapterInfo,
        'nextChapterUrl': nextChapterUrl,
      });
      if (result == null) return null;
      // 解析 JS 日志，写入 AppLogger
      final logs = result['logs'];
      if (logs is List && logs.isNotEmpty) {
        for (final log in logs) {
          AppLogger.instance.debug(LogCategory.js, '[Rhino] $log');
        }
      }
      final data = result['data'];
      if (data is List) return data.cast<String>();
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 解析规则取元素列表（HTML 节点 outerHtml 列表，用于二次解析）
  Future<List<String>?> analyzeRuleGetElements(
    String content,
    String rule, {
    String? baseUrl,
    String? redirectUrl,
    Map<String, dynamic>? sourceInfo,
    Map<String, dynamic>? bookInfo,
    Map<String, dynamic>? chapterInfo,
    String? nextChapterUrl,
  }) async {
    try {
      final result = await _channel.invokeMethod<List>('analyzeRuleGetElements', {
        'content': content,
        'rule': rule,
        'baseUrl': baseUrl,
        'redirectUrl': redirectUrl,
        'sourceInfo': sourceInfo,
        'bookInfo': bookInfo,
        'chapterInfo': chapterInfo,
        'nextChapterUrl': nextChapterUrl,
      });
      return result?.cast<String>();
    } on PlatformException {
      return null;
    }
  }

  // ===== 内置 Node.js 运行时 =====

  /// 初始化内置 Node.js（解压二进制 + 脚本）
  /// 返回 Node.js 可执行文件路径
  Future<String?> nodeSetup() async {
    try {
      return await _channel.invokeMethod<String>('nodeSetup');
    } on PlatformException {
      return null;
    }
  }

  /// 启动内置 Node.js 代理服务（直接启动，无需解压）
  /// 返回 { proxyPort, apiPort, running }
  Future<Map<String, dynamic>?> nodeStartProxy() async {
    try {
      final result = await _channel.invokeMethod<Map>('nodeStartProxy');
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on PlatformException {
      return null;
    }
  }

  /// 停止内置 Node.js 进程
  Future<bool> nodeStop() async {
    try {
      await _channel.invokeMethod<void>('nodeStop');
      return true;
    } on PlatformException {
      return false;
    }
  }

  /// 获取内置 Node.js 运行状态
  Future<Map<String, dynamic>?> nodeStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>('nodeStatus');
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } on PlatformException {
      return null;
    }
  }
}
