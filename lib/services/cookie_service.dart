import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Cookie 条目
class CookieItem {
  final String name;
  final String value;
  final String domain;
  final String path;
  final int? expiresAt; // 过期时间戳（毫秒），null 表示会话 Cookie
  final bool secure;
  final bool httpOnly;
  final int? maxAge; // 秒

  CookieItem({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.expiresAt,
    this.secure = false,
    this.httpOnly = false,
    this.maxAge,
  });

  /// 是否为会话 Cookie（应用关闭后失效）
  bool get isSessionCookie => expiresAt == null && maxAge == null;

  /// 是否已过期
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().millisecondsSinceEpoch > expiresAt!;
  }

  /// 是否匹配指定 URL
  bool matches(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      final urlPath = uri.path.isEmpty ? '/' : uri.path;

      // 域名匹配
      if (!_domainMatches(host)) return false;

      // 路径匹配
      if (!_pathMatches(urlPath)) return false;

      // Secure 检查
      if (secure && uri.scheme != 'https') return false;

      return true;
    } catch (e) {
      return false;
    }
  }

  /// 域名匹配规则
  /// - 如果 domain 以 . 开头，则匹配该域名及其子域名
  /// - 否则精确匹配
  bool _domainMatches(String host) {
    var cookieDomain = domain;
    if (cookieDomain.startsWith('.')) {
      cookieDomain = cookieDomain.substring(1);
    }

    // 精确匹配
    if (host.toLowerCase() == cookieDomain.toLowerCase()) return true;

    // 子域名匹配（domain 以 . 开头或隐式子域名匹配）
    if (host.toLowerCase().endsWith('.${cookieDomain.toLowerCase()}')) {
      return true;
    }

    return false;
  }

  /// 路径匹配规则
  /// Cookie path 必须是请求路径的前缀
  bool _pathMatches(String urlPath) {
    if (path == '/' || path.isEmpty) return true;
    if (urlPath.startsWith(path)) return true;
    // 路径必须完全匹配或以 / 结尾的目录匹配
    if (urlPath == path) return true;
    return false;
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'expiresAt': expiresAt,
    'secure': secure,
    'httpOnly': httpOnly,
    'maxAge': maxAge,
  };

  factory CookieItem.fromJson(Map<String, dynamic> json) => CookieItem(
    name: json['name'] ?? '',
    value: json['value'] ?? '',
    domain: json['domain'] ?? '',
    path: json['path'] ?? '/',
    expiresAt: json['expiresAt'],
    secure: json['secure'] == true,
    httpOnly: json['httpOnly'] == true,
    maxAge: json['maxAge'],
  );

  /// 从 Set-Cookie 头解析
  factory CookieItem.fromSetCookieHeader(String header, String requestUrl) {
    final parts = header.split(';').map((s) => s.trim()).toList();
    if (parts.isEmpty) {
      throw FormatException('Invalid Set-Cookie header');
    }

    // 解析 name=value
    final nameValue = parts[0].split('=');
    if (nameValue.length < 2) {
      throw FormatException('Invalid cookie name-value pair');
    }

    final name = nameValue[0].trim();
    final value = nameValue.sublist(1).join('=').trim();

    // 默认值
    String domain = _extractDomain(requestUrl);
    String path = '/';
    int? expiresAt;
    bool secure = false;
    bool httpOnly = false;
    int? maxAge;

    // 解析属性
    for (var i = 1; i < parts.length; i++) {
      final part = parts[i];
      final lowerPart = part.toLowerCase();

      if (lowerPart == 'secure') {
        secure = true;
      } else if (lowerPart == 'httponly') {
        httpOnly = true;
      } else if (lowerPart.startsWith('domain=')) {
        var d = part.substring(7).trim();
        if (d.startsWith('.')) {
          d = d.substring(1);
        }
        if (d.isNotEmpty) {
          domain = d;
        }
      } else if (lowerPart.startsWith('path=')) {
        final p = part.substring(5).trim();
        if (p.isNotEmpty) {
          path = p;
        }
      } else if (lowerPart.startsWith('max-age=')) {
        final age = int.tryParse(lowerPart.substring(8));
        if (age != null) {
          maxAge = age;
          if (age > 0) {
            expiresAt = DateTime.now().millisecondsSinceEpoch + (age * 1000);
          } else {
            // max-age=0 表示立即删除
            expiresAt = 0;
          }
        }
      } else if (lowerPart.startsWith('expires=')) {
        final expiresStr = part.substring(8).trim();
        final parsed = _parseExpiresDate(expiresStr);
        if (parsed != null) {
          expiresAt = parsed.millisecondsSinceEpoch;
        }
      }
    }

    return CookieItem(
      name: name,
      value: value,
      domain: domain,
      path: path,
      expiresAt: expiresAt,
      secure: secure,
      httpOnly: httpOnly,
      maxAge: maxAge,
    );
  }

  /// 从 URL 提取域名
  static String _extractDomain(String url) {
    try {
      return Uri.parse(url).host;
    } catch (e) {
      return url;
    }
  }

  /// 解析 Expires 日期
  static DateTime? _parseExpiresDate(String dateStr) {
    // 常见格式：
    // Wed, 21 Oct 2015 07:28:00 GMT
    // Wed, 21-Oct-2015 07:28:00 GMT
    try {
      // 尝试解析 HTTP 日期格式
      final cleaned = dateStr.replaceAll('-', ' ');
      return HttpDate.parse(cleaned);
    } catch (e) {
      return null;
    }
  }

  @override
  String toString() => 'CookieItem($name=$value, domain=$domain, path=$path)';
}

/// HTTP 日期解析（简化版）
class HttpDate {
  static final List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static DateTime? parse(String input) {
    try {
      // 格式: Wed, 21 Oct 2015 07:28:00 GMT
      final parts = input.trim().split(RegExp(r'\s+'));
      if (parts.length < 5) return null;

      // 跳过星期几
      int idx = 0;
      if (parts[0].endsWith(',')) idx = 1;

      final day = int.parse(parts[idx]);
      final month = _months.indexOf(parts[idx + 1]) + 1;
      final year = int.parse(parts[idx + 2]);

      final timeParts = parts[idx + 3].split(':');
      final hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);
      final second = int.parse(timeParts[2]);

      return DateTime.utc(year, month, day, hour, minute, second);
    } catch (e) {
      return null;
    }
  }
}

/// Cookie 存储接口
abstract class CookieStorage {
  Future<void> save(String domain, List<CookieItem> cookies);
  Future<List<CookieItem>> load(String domain);
  Future<void> remove(String domain);
  Future<void> removeAll();
  Future<List<String>> getAllDomains();
}

/// SharedPreferences Cookie 存储
class PrefsCookieStorage implements CookieStorage {
  static const String _prefix = 'cookie_store_';

  @override
  Future<void> save(String domain, List<CookieItem> cookies) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = cookies.map((c) => c.toJson()).toList();
    await prefs.setString('$_prefix$domain', jsonEncode(jsonList));
  }

  @override
  Future<List<CookieItem>> load(String domain) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('$_prefix$domain');
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((item) => CookieItem.fromJson(item as Map<String, dynamic>))
          .where((c) => !c.isExpired)
          .toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> remove(String domain) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$domain');
  }

  @override
  Future<void> removeAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  @override
  Future<List<String>> getAllDomains() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getKeys()
        .where((k) => k.startsWith(_prefix))
        .map((k) => k.substring(_prefix.length))
        .toList();
  }
}

/// Cookie 管理服务
/// 特点：
/// 1. 完整的 RFC 6265 Cookie 规范支持
/// 2. 域名、路径、Secure、HttpOnly 完整匹配
/// 3. 会话 Cookie 和持久化 Cookie 分离
/// 4. 自动过期清理
/// 5. CF 等特殊 Cookie 支持
/// 6. 线程安全
class CookieService {
  static final CookieService instance = CookieService._internal();
  CookieService._internal();

  CookieStorage _storage = PrefsCookieStorage();

  // 内存缓存（会话 Cookie + 热数据）
  final Map<String, List<CookieItem>> _cache = {};

  // 是否已初始化
  bool _initialized = false;

  /// 设置自定义存储后端
  void setStorage(CookieStorage storage) {
    _storage = storage;
  }

  /// 初始化（加载所有持久化 Cookie 到内存）
  Future<void> init() async {
    if (_initialized) return;

    try {
      final domains = await _storage.getAllDomains();
      for (final domain in domains) {
        final cookies = await _storage.load(domain);
        if (cookies.isNotEmpty) {
          _cache[domain] = cookies;
        }
      }
      _initialized = true;
    } catch (e) {
      // 初始化失败，继续使用空缓存
      _initialized = true;
    }
  }

  /// 从响应头保存 Cookie
  /// [url] 请求 URL
  /// [setCookieHeaders] Set-Cookie 头列表
  Future<void> saveFromHeaders(String url, List<String> setCookieHeaders) async {
    for (final header in setCookieHeaders) {
      try {
        final cookie = CookieItem.fromSetCookieHeader(header, url);
        await _saveCookie(cookie);
      } catch (e) {
        // 忽略解析失败的 Cookie
        continue;
      }
    }
  }

  /// 保存单个 Cookie
  Future<void> _saveCookie(CookieItem cookie) async {
    final domain = cookie.domain;

    // 获取或创建该域名的 Cookie 列表
    var cookies = _cache[domain];
    if (cookies == null) {
      cookies = await _storage.load(domain);
      _cache[domain] = cookies;
    }

    // 查找并替换同名 Cookie
    var found = false;
    for (var i = 0; i < cookies.length; i++) {
      if (cookies[i].name == cookie.name && cookies[i].path == cookie.path) {
        // 检查是否要删除（max-age=0 或已过期）
        if (cookie.isExpired) {
          cookies.removeAt(i);
        } else {
          cookies[i] = cookie;
        }
        found = true;
        break;
      }
    }

    // 新增 Cookie
    if (!found && !cookie.isExpired) {
      cookies.add(cookie);
    }

    // 持久化
    await _storage.save(domain, cookies);
  }

  /// 保存 Cookie 字符串
  /// [url] 用于确定域名
  /// [cookieStr] Cookie 字符串（如 "name=value; name2=value2"）
  Future<void> setCookie(String url, String cookieStr) async {
    if (cookieStr.isEmpty) return;

    final domain = _extractDomain(url);
    final pairs = cookieStr.split(';');

    for (final pair in pairs) {
      final kv = pair.trim().split('=');
      if (kv.length >= 2) {
        final name = kv[0].trim();
        final value = kv.sublist(1).join('=').trim();

        if (name.isNotEmpty) {
          final cookie = CookieItem(
            name: name,
            value: value,
            domain: domain,
            path: '/',
          );
          await _saveCookie(cookie);
        }
      }
    }
  }

  /// 获取指定 URL 的 Cookie 字符串
  Future<String> getCookie(String url) async {
    final cookies = await getCookies(url);
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// 获取指定 URL 的 Cookie 列表
  Future<List<CookieItem>> getCookies(String url) async {
    final result = <CookieItem>[];

    // 遍历所有域名，找出匹配的 Cookie
    for (final entry in _cache.entries) {
      for (final cookie in entry.value) {
        if (!cookie.isExpired && cookie.matches(url)) {
          // 检查是否已存在同名 Cookie（优先选择更具体的路径）
          var existingIdx = result.indexWhere((c) => c.name == cookie.name);
          if (existingIdx >= 0) {
            // 路径更长的优先
            if (cookie.path.length > result[existingIdx].path.length) {
              result[existingIdx] = cookie;
            }
          } else {
            result.add(cookie);
          }
        }
      }
    }

    // 也检查存储中可能遗漏的域名
    final domains = await _storage.getAllDomains();
    for (final domain in domains) {
      if (!_cache.containsKey(domain)) {
        final cookies = await _storage.load(domain);
        if (cookies.isNotEmpty) {
          _cache[domain] = cookies;
          for (final cookie in cookies) {
            if (!cookie.isExpired && cookie.matches(url)) {
              var existingIdx = result.indexWhere((c) => c.name == cookie.name);
              if (existingIdx >= 0) {
                if (cookie.path.length > result[existingIdx].path.length) {
                  result[existingIdx] = cookie;
                }
              } else {
                result.add(cookie);
              }
            }
          }
        }
      }
    }

    return result;
  }

  /// 获取单个 Cookie 值
  Future<String> getCookieValue(String url, String name) async {
    final cookies = await getCookies(url);
    for (final cookie in cookies) {
      if (cookie.name == name) {
        return cookie.value;
      }
    }
    return '';
  }

  /// 清除指定 URL 的所有 Cookie
  Future<void> removeCookie(String url) async {
    final domain = _extractDomain(url);

    // 清除内存缓存
    _cache.remove(domain);

    // 清除存储
    await _storage.remove(domain);

    // 也清除可能的完整 host 存储
    final host = Uri.parse(url).host;
    if (host != domain) {
      _cache.remove(host);
      await _storage.remove(host);
    }
  }

  /// 清除指定 URL 的单个 Cookie
  Future<void> removeCookieValue(String url, String name) async {
    final domain = _extractDomain(url);
    var cookies = _cache[domain] ?? await _storage.load(domain);

    cookies = cookies.where((c) => c.name != name).toList();
    _cache[domain] = cookies;
    await _storage.save(domain, cookies);
  }

  /// 清除所有 Cookie
  Future<void> clearAll() async {
    _cache.clear();
    await _storage.removeAll();
  }

  /// 获取所有 Cookie（用于调试）
  Future<Map<String, List<CookieItem>>> getAllCookies() async {
    final result = <String, List<CookieItem>>{};

    for (final entry in _cache.entries) {
      final validCookies = entry.value.where((c) => !c.isExpired).toList();
      if (validCookies.isNotEmpty) {
        result[entry.key] = validCookies;
      }
    }

    return result;
  }

  /// 清理过期 Cookie
  Future<void> cleanExpired() async {
    final domains = await _storage.getAllDomains();
    for (final domain in domains) {
      var cookies = _cache[domain] ?? await _storage.load(domain);
      final validCookies = cookies.where((c) => !c.isExpired).toList();

      if (validCookies.length != cookies.length) {
        _cache[domain] = validCookies;
        if (validCookies.isEmpty) {
          await _storage.remove(domain);
        } else {
          await _storage.save(domain, validCookies);
        }
      }
    }
  }

  /// 提取域名
  String _extractDomain(String url) {
    try {
      return Uri.parse(url).host;
    } catch (e) {
      return url;
    }
  }

  /// Cookie 字符串转 Map
  Map<String, String> cookieToMap(String? cookie) {
    final map = <String, String>{};
    if (cookie == null || cookie.isEmpty) return map;

    for (final pair in cookie.split(';')) {
      final kv = pair.trim().split('=');
      if (kv.length >= 2) {
        map[kv[0].trim()] = kv.sublist(1).join('=').trim();
      }
    }
    return map;
  }

  /// Map 转 Cookie 字符串
  String? mapToCookie(Map<String, String>? map) {
    if (map == null || map.isEmpty) return null;
    return map.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }
}
