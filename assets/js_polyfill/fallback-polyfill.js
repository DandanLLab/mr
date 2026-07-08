/**
 * fallback-polyfill.js — java-bridge.js 加载失败时的最小回退
 *
 * 当 rootBundle 加载 java-bridge.js 失败时注入，
 * 确保后续 evaluate 不崩溃。*/
 /*
 * 设计原则：
 *   - 所有书源常用 API 提供空实现（返回 '' / [] / {} / false）
 *   - 网络请求类抛 __NEED_NETWORK__ 标记（与正式版一致，由 Dart 侧拦截）
 *   - 不依赖任何 __nativeCrypto / __nativeLz / __nativeBase64 / __nativeHtml（这些由 C 层注册，与 JS polyfill 独立）
 *   - 保持与 java-bridge.js 相同的 API 表面，避免书源调用未定义方法抛 ReferenceError
 **/

// ===== 基础变量 =====
var _javaCache = {};
var _pendingNetwork = null;
var __consoleLogs = [];

// ===== URL/URLSearchParams 最小兼容 =====
function URL(url, base) {
  if (!(this instanceof URL)) return new URL(url, base);
  this.href = url || '';
  this.protocol = ''; this.host = ''; this.hostname = ''; this.port = '';
  this.origin = ''; this.pathname = this.href; this.search = ''; this.hash = '';
  this.toString = function() { return this.href; };
}
function URLSearchParams(init) {
  if (!(this instanceof URLSearchParams)) return new URLSearchParams(init);
  this._params = [];
  this.get = function(name) { return null; };
  this.toString = function() { return ''; };
}

// ===== btoa/atob 最小实现 =====
function btoa(str) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var result = '';
  for (var i = 0; i < str.length; i += 3) {
    var a = str.charCodeAt(i) & 0xFF;
    var b = i + 1 < str.length ? str.charCodeAt(i + 1) & 0xFF : 0;
    var c = i + 2 < str.length ? str.charCodeAt(i + 2) & 0xFF : 0;
    result += chars[a >> 2] + chars[((a & 3) << 4) | (b >> 4)];
    result += i + 1 < str.length ? chars[((b & 15) << 2) | (c >> 6)] : '=';
    result += i + 2 < str.length ? chars[c & 63] : '=';
  }
  return result;
}
function atob(str) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var lookup = {};
  for (var i = 0; i < chars.length; i++) lookup[chars[i]] = i;
  str = str.replace(/=+$/, '');
  var result = '';
  for (var i = 0; i < str.length; i += 4) {
    var a = lookup[str[i]] || 0;
    var b = lookup[str[i + 1]] || 0;
    var c = lookup[str[i + 2]] || 0;
    var d = lookup[str[i + 3]] || 0;
    result += String.fromCharCode((a << 2) | (b >> 4));
    if (i + 2 < str.length) result += String.fromCharCode(((b & 15) << 4) | (c >> 2));
    if (i + 3 < str.length) result += String.fromCharCode(((c & 3) << 6) | d);
  }
  return result;
}

// ===== Uint8Array ↔ 字符串 =====
function _u8ToStr(u8) {
  if (Array.isArray(u8)) u8 = new Uint8Array(u8);
  var s = '';
  for (var i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]);
  try { return decodeURIComponent(escape(s)); } catch(e) { return s; }
}
function _strToU8(str) {
  var bytes = [];
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    if (c < 128) bytes.push(c);
    else if (c < 2048) bytes.push(192 | (c >> 6), 128 | (c & 63));
    else bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63));
  }
  return new Uint8Array(bytes);
}

// ===== LZString 空实现（解压失败返回 ''）=====
var LZString = {
  decompressFromBase64: function(str) { return ''; },
  decompress: function(str) { return ''; },
  compressToBase64: function(str) { return btoa(str); },
};

// ===== console 兼容 =====
var console = {
  log: function() { __consoleLogs.push({level: 'log', msg: Array.prototype.slice.call(arguments).join(' ')}); },
  warn: function() { __consoleLogs.push({level: 'warn', msg: Array.prototype.slice.call(arguments).join(' ')}); },
  error: function() { __consoleLogs.push({level: 'error', msg: Array.prototype.slice.call(arguments).join(' ')}); },
  info: function() { __consoleLogs.push({level: 'info', msg: Array.prototype.slice.call(arguments).join(' ')}); },
  debug: function() { __consoleLogs.push({level: 'debug', msg: Array.prototype.slice.call(arguments).join(' ')}); },
  _getLogs: function() { return __consoleLogs.slice(); },
  _clearLogs: function() { __consoleLogs.length = 0; },
};

// ===== CryptoJS 空实现（不依赖 C 原生）=====
var CryptoJS = {
  enc: {
    Utf8: { parse: function(str) { return _strToU8(str); }, stringify: function(u8) { return _u8ToStr(u8); } },
    Base64: { parse: function(str) { return _strToU8(atob(str)); }, stringify: function(u8) { return btoa(_u8ToStr(u8)); } },
    Hex: {
      parse: function(hex) { var b = []; for (var i = 0; i < hex.length; i += 2) b.push(parseInt(hex.substr(i, 2), 16)); return new Uint8Array(b); },
      stringify: function(u8) { var h = ''; for (var i = 0; i < u8.length; i++) h += (u8[i] < 16 ? '0' : '') + u8[i].toString(16); return h; },
    },
  },
  AES: {
    encrypt: function(data, key, cfg) { return { toString: function() { return ''; } }; },
    decrypt: function(cipher, key, cfg) { return { toString: function() { return ''; } }; },
  },
  MD5: function() { return { toString: function() { return ''; } }; },
  SHA1: function() { return { toString: function() { return ''; } }; },
  SHA256: function() { return { toString: function() { return ''; } }; },
  HmacSHA256: function() { return { toString: function() { return ''; } }; },
  mode: { CBC: 1, ECB: 2, CFB: 3, OFB: 4, CTR: 5 },
  pad: { Pkcs7: 1, ZeroPadding: 2, NoPadding: 3, Iso10126: 4, Iso97971: 5 },
};

// ===== _JsoupLite 空实现 =====
var _JsoupLite = {
  selectFirst: function(html, selector) { return ''; },
  selectAll: function(html, selector) { return []; },
  getAttr: function(html, selector, attr) { return ''; },
};

// ===== fetch 兼容（网络标记协议）=====
function fetch(url, options) {
  var method = (options && options.method) || 'GET';
  _pendingNetwork = JSON.stringify({ method: method, url: url, body: (options && options.body) || '', headers: (options && options.headers) || {}, cacheKey: 'http_' + method.toLowerCase() + ':' + url });
  throw '__NEED_NETWORK__:' + _pendingNetwork;
}

// ===== Node.js 最小兼容 =====
var process = { env: {}, argv: [], version: 'v18.17.0', platform: 'android', arch: 'arm64', pid: 1, cwd: function() { return '/'; }, exit: function(c) {}, nextTick: function(fn) { setTimeout(fn, 0); }, on: function(e, h) {}, stdout: { write: function() {} }, stderr: { write: function() {} } };
var Buffer = { from: function(d, e) { return { toString: function() { return typeof d === 'string' ? d : ''; }, length: d ? d.length : 0 }; }, isBuffer: function() { return false; }, concat: function(l) { return Buffer.from(l.join('')); } };

// ===== java 桥接对象（最小空实现，网络请求走标记协议）=====
function _throwNetwork(method, url, body, headers, cacheKey) {
  _pendingNetwork = JSON.stringify({ method: method, url: url, body: body || '', headers: headers || {}, cacheKey: cacheKey });
  throw '__NEED_NETWORK__:' + _pendingNetwork;
}

var java = {
  // HTTP
  get: function(url, headers) { return _throwNetwork('GET', url, '', headers, 'http_get:' + url); },
  post: function(url, body, headers) { return _throwNetwork('POST', url, body, headers, 'http_post:' + url); },
  ajax: function(url, headers) { return _throwNetwork('GET', url, '', headers, 'http_get:' + url); },
  ajaxAll: function(urls) { return urls ? urls.map(function() { return ''; }) : []; },
  ajaxTestAll: function(urls) { return urls ? urls.map(function(u) { return { url: u, body: '', code: 200 }; }) : []; },
  connect: function(urlStr, header, callTimeout) { return _throwNetwork('GET', urlStr, '', header, 'http_get:' + urlStr); },
  head: function(urlStr, headers, timeout) { return _throwNetwork('HEAD', urlStr, '', headers, 'http_head:' + urlStr); },
  getStrResponse: function(url, ruleStr) { var html = java.ajax(url); return ruleStr ? java.getString(html, ruleStr) : html; },

  // 变量存取
  put: function(key, value) { _javaCache[key] = String(value); },
  getStr: function(key, defaultValue) { return _javaCache[key] || (defaultValue || ''); },
  getString: function(str, ruleStr) { return str || ''; },
  getJson: function(str) { try { return JSON.parse(str); } catch(e) { return {}; } },
  putJson: function(key, value) { _javaCache[key] = JSON.stringify(value); },

  // 加密/解密（空实现）
  aesEncode: function() { return ''; },
  aesDecode: function() { return ''; },
  aesDecodeBytes: function() { return new Uint8Array(0); },
  aesDecodeBatch: function(arr) { return arr ? arr.map(function() { return ''; }) : []; },
  md5Encode: function() { return ''; },
  sha1Encode: function() { return ''; },
  sha256Encode: function() { return ''; },
  hmacSHA256: function() { return ''; },
  md5Encode16: function() { return ''; },
  digestHex: function() { return ''; },
  digestBase64Str: function() { return ''; },
  HMacHex: function() { return ''; },
  HMacBase64Str: function() { return ''; },
  HMacBase64: function() { return ''; },

  // Base64
  base64Encode: function(str) { try { return btoa(unescape(encodeURIComponent(str))); } catch(e) { return ''; } },
  base64Decode: function(str) { try { return decodeURIComponent(escape(atob(str))); } catch(e) { return ''; } },
  base64DecodeToByteArray: function(str) { var d = java.base64Decode(str); return d ? java.strToBytes(d) : []; },
  hexDecodeToByteArray: function(hex) { var s = java.hexDecodeToString(hex); return s ? java.strToBytes(s) : []; },
  hexEncodeToString: function(str) { var h = ''; for (var i = 0; i < str.length; i++) h += str.charCodeAt(i).toString(16).padStart(2, '0'); return h; },
  hexDecodeToString: function(hex) { var s = ''; for (var i = 0; i < hex.length; i += 2) s += String.fromCharCode(parseInt(hex.substr(i, 2), 16)); return s; },

  // HTML（路由到 _JsoupLite 空实现）
  jsoup: {
    parse: function(html) { return { html: html, select: function() { return []; }, selectFirst: function() { return ''; }, text: function() { return (html || '').replace(/<[^>]+>/g, '').trim(); } }; },
    select: function() { return []; },
    selectFirst: function() { return ''; },
    getAttr: function() { return ''; },
    clean: function(html) { return (html || '').replace(/<[^>]+>/g, '').trim(); },
  },

  // 正则
  regex: {
    match: function(str, p) { try { var m = str.match(new RegExp(p)); return m ? m[0] : ''; } catch(e) { return ''; } },
    matchAll: function(str, p) { try { var r = []; var re = new RegExp(p, 'g'); var m; while(m = re.exec(str)) r.push(m[0]); return r; } catch(e) { return []; } },
    replace: function(str, p, r) { try { return str.replace(new RegExp(p, 'g'), r); } catch(e) { return str; } },
    test: function(str, p) { try { return new RegExp(p).test(str); } catch(e) { return false; } },
  },

  // 时间
  timeFormat: function(ts, fmt) { var d = new Date(ts); return fmt ? fmt.replace(/yyyy/g, d.getFullYear()) : d.toLocaleString(); },
  timeFormatUTC: function(ts, fmt, offset) { var d = new Date(ts); if (offset) d = new Date(d.getTime() + offset * 3600000); return fmt ? fmt.replace(/yyyy/g, d.getUTCFullYear()) : d.toUTCString(); },
  getTime: function() { return Date.now(); },
  encodeURI: function(str) { return encodeURIComponent(str); },

  // Cookie/WebView
  getCookie: function() { return ''; },
  webview: { eval: function() { return ''; } },
  webView: function() { return ''; },
  webViewGetSource: function() { return ''; },
  webViewGetOverrideUrl: function() { return ''; },
  startBrowser: function() {},
  startBrowserAwait: function() { return ''; },
  getVerificationCode: function() { return ''; },
  openVideoPlayer: function() {},

  // 缓存
  cache: { get: function(k) { return _javaCache[k] || ''; }, put: function(k, v) { _javaCache[k] = v; }, delete: function(k) { delete _javaCache[k]; } },

  // 日志
  log: function(msg) { console.log('[JavaBridge] ' + msg); },

  // 文本处理
  htmlFormat: function(str) { return (str || '').replace(/<[^>]+>/g, '').trim(); },
  t2s: function(t) { return t; },
  s2t: function(t) { return t; },
  toNumChapter: function(s) { if (!s) return ''; var m = s.match(/(\d+)/); return m ? m[1] : ''; },

  // 工具
  toast: function() {},
  longToast: function() {},
  getWebViewUA: function() { return 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Mobile Safari/537.36'; },
  randomUUID: function() { return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) { var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16); }); },
  androidId: function() { return java.randomUUID().replace(/-/g, '').substring(0, 16); },
  logType: function() {},
  toURL: function(urlStr, base) { try { return new URL(urlStr, base); } catch(e) { return { href: urlStr, toString: function() { return urlStr; } }; } },

  // 字节转换
  strToBytes: function(str) { var b = []; for (var i = 0; i < str.length; i++) { var c = str.charCodeAt(i); if (c < 128) b.push(c); else if (c < 2048) b.push(192 | (c >> 6), 128 | (c & 63)); else b.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63)); } return b; },
  bytesToStr: function(bytes) { if (!bytes || !bytes.length) return ''; var s = ''; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i] & 0xFF); try { return decodeURIComponent(escape(s)); } catch(e) { return s; } },

  // 文件操作（空实现）
  cacheFile: function() { return ''; },
  downloadFile: function(urlOrContent, url) { var u = url === undefined ? urlOrContent : url; return '/tmp/' + u; },
  getFile: function(path) { return { path: path, exists: function() { return false; }, readText: function() { return ''; } }; },
  importScript: function() { return ''; },
  readFile: function() { return ''; },
  readTxtFile: function() { return ''; },
  deleteFile: function() { return false; },
  writeFile: function() { return false; },
  unzipFile: function() { return ''; },
  un7zFile: function() { return ''; },
  unrarFile: function() { return ''; },
  unArchiveFile: function() { return ''; },
  getTxtInFolder: function() { return ''; },
  getZipStringContent: function() { return ''; },
  getRarStringContent: function() { return ''; },
  get7zStringContent: function() { return ''; },
  getZipByteArrayContent: function() { return []; },
  getRarByteArrayContent: function() { return []; },
  get7zByteArrayContent: function() { return []; },
  openUrl: function() {},

  // 配置
  getReadBookConfig: function() { return '{}'; },
  getReadBookConfigMap: function() { return {}; },
  getThemeMode: function() { return 'light'; },
  getThemeConfig: function() { return '{}'; },
  getThemeConfigMap: function() { return {}; },
  getSource: function() { return {}; },
  getTag: function() { return ''; },

  // AES 参数版空实现
  aesEncodeToString: function() { return ''; },
  aesEncodeToBase64String: function() { return ''; },
  aesDecodeToString: function() { return ''; },
  aesBase64DecodeToString: function() { return ''; },
  createSymmetricCrypto: function(t, key, iv) { return { encryptStr: function() { return ''; }, decryptStr: function() { return ''; }, encryptBase64: function() { return ''; }, decryptBase64: function() { return ''; }, encryptHex: function() { return ''; }, decryptHex: function() { return ''; }, encrypt: function() { return ''; }, decrypt: function() { return ''; }, setIv: function() { return this; } }; },
  desEncodeToString: function() { return ''; },
  desDecodeToString: function() { return ''; },
  desEncodeToBase64String: function() { return ''; },
  desBase64DecodeToString: function() { return ''; },
  tripleDESEncodeBase64Str: function() { return ''; },
  tripleDESDecodeArgsBase64Str: function() { return ''; },
  tripleDESDecodeStr: function() { return ''; },
  tripleDESEncodeArgsBase64Str: function() { return ''; },
  createAsymmetricCrypto: function() { return { encrypt: function() { return ''; }, decrypt: function() { return ''; }, encryptStr: function() { return ''; }, decryptStr: function() { return ''; }, encryptBase64: function() { return ''; }, decryptBase64: function() { return ''; } }; },
  createSign: function() { return { sign: function() { return ''; }, verify: function() { return false; }, signBase64: function() { return ''; }, verifyBase64: function() { return false; } }; },
  aesEncodeArgsBase64Str: function() { return ''; },
  aesDecodeArgsBase64Str: function() { return ''; },
  aesDecodeToByteArray: function() { return []; },
  aesEncodeToByteArray: function() { return []; },
  aesBase64DecodeToByteArray: function() { return []; },
  aesEncodeToBase64ByteArray: function() { return []; },

  // 元素操作
  getElements: function(html, rule) { return []; },
  getElement: function(html, rule) { return ''; },
  getStringList: function(html, rule) { return []; },
};

// ===== 将 java 方法别名到 globalThis（兼容 Legado 书源裸调用）=====
(function() {
  for (var k in java) {
    if (k.charAt(0) === '_') continue;
    if (globalThis[k] === undefined) globalThis[k] = java[k];
  }
})();

// ===== _jsLog 辅助 =====
function _jsLog(msg, level) {
  if (level === 'error') console.error(msg);
  else if (level === 'warn') console.warn(msg);
  else console.log(msg);
}

// ===== Dart 侧动态操作辅助函数 =====
function __setCache(key, value) { _javaCache[key] = value; }
function __getCache(key) { return _javaCache[key]; }
function __clearCache() { _javaCache = {}; }
function __evalVar(expr) { try { var __v = eval(expr); return (typeof __v === 'string' && __v.length > 50) ? __v : ''; } catch (e) { return ''; } }
function __regexReplace(text, pattern, replacement) { try { return String(text).replace(new RegExp(pattern, 'g'), replacement); } catch (e) { return null; } }
function __cssSelect(html, selector) { try { return java.jsoup.selectFirst(html, selector); } catch (e) { return null; } }
function __jsonPath(jsonStr, path) { try { var data = JSON.parse(jsonStr); var p = path.replace(/^\$\./, ''); var parts = p.split('.'); var r = data; for (var i = 0; i < parts.length; i++) { if (r == null) return null; r = r[parts[i]]; } return JSON.stringify(r); } catch (e) { return null; } }
function __batchEvalUrls(varCodeArr, exprArr) { var __r = []; for (var i = 0; i < varCodeArr.length; i++) { try { eval(varCodeArr[i]); } catch (e) {} } for (var j = 0; j < exprArr.length; j++) { try { var __u = String(eval(exprArr[j])); if (__u.indexOf('http') === 0) __r.push(__u); } catch (e) {} } return JSON.stringify(__r); }

// ===== console 日志提取与恢复 =====
function __flushConsoleLogs() {
  var logs = [];
  if (typeof __consoleLogs !== 'undefined' && __consoleLogs.length > 0) {
    logs = __consoleLogs.slice();
    __consoleLogs.length = 0;
  } else if (typeof console !== 'undefined' && typeof console._getLogs === 'function') {
    logs = console._getLogs();
    if (console._clearLogs) console._clearLogs();
  } else if (typeof console === 'undefined' || typeof console._getLogs !== 'function') {
    return 'NEED_REINJECT';
  }
  return JSON.stringify(logs);
}
function __reinjectConsole() {
  if (typeof __consoleLogs === 'undefined') globalThis.__consoleLogs = [];
  else __consoleLogs.length = 0;
  globalThis.console = {
    log: function() { __consoleLogs.push({level: 'log', msg: Array.prototype.slice.call(arguments).join(' ')}); },
    warn: function() { __consoleLogs.push({level: 'warn', msg: Array.prototype.slice.call(arguments).join(' ')}); },
    error: function() { __consoleLogs.push({level: 'error', msg: Array.prototype.slice.call(arguments).join(' ')}); },
    info: function() { __consoleLogs.push({level: 'info', msg: Array.prototype.slice.call(arguments).join(' ')}); },
    debug: function() { __consoleLogs.push({level: 'debug', msg: Array.prototype.slice.call(arguments).join(' ')}); },
    _getLogs: function() { return __consoleLogs.slice(); },
    _clearLogs: function() { __consoleLogs.length = 0; },
  };
}
