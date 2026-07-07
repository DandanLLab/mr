// ===== Legado Java 桥接对象（QuickJS 侧）=====
// 借鉴 legado 的 JsExtensions 接口
// 核心策略：同步模式从 _javaCache 取缓存值，异步模式由 Dart 端预缓存
// 加密/HTML 解析重定向到 CryptoJS/_JsoupLite（纯 JS，不依赖 C FFI）

// 确保基础变量存在
if (typeof _javaCache === 'undefined') var _javaCache = {};

var java = {
  // ===== HTTP 请求方法（核心，对齐 legado JsExtensions）=====
  _buildResponse: function(body, url, headers) {
    return {
      body: body || '',
      url: url || '',
      headerMap: headers || {},
      html: body || '',
      toString: function() { return this.body; },
      getHeader: function(name) { return this.headerMap[name] || ''; }
    };
  },
  _parseUrlOptions: function(urlStr) {
    if (!urlStr || typeof urlStr !== 'string') return null;
    var str = urlStr.trim();
    var idx = str.indexOf(',{');
    if (idx < 0) return null;
    try {
      var opt = JSON.parse(str.substring(idx + 1).trim());
      opt._url = str.substring(0, idx).trim();
      return opt;
    } catch (e) { return null; }
  },
  _extractUrl: function(urlStr) {
    if (!urlStr || typeof urlStr !== 'string') return urlStr || '';
    var str = urlStr.trim();
    var idx = str.indexOf(',{');
    return idx >= 0 ? str.substring(0, idx).trim() : str;
  },
  _normalizeBody: function(body) {
    if (body == null) return '';
    if (typeof body === 'object') return JSON.stringify(body);
    return String(body);
  },
  _mergeHeaders: function(optHeaders, paramHeaders) {
    var result = {};
    if (optHeaders && typeof optHeaders === 'object') {
      for (var k in optHeaders) { if (Object.prototype.hasOwnProperty.call(optHeaders, k)) result[k] = optHeaders[k]; }
    }
    if (paramHeaders && typeof paramHeaders === 'object') {
      for (var k in paramHeaders) { if (Object.prototype.hasOwnProperty.call(paramHeaders, k)) result[k] = paramHeaders[k]; }
    } else if (typeof paramHeaders === 'string') {
      try {
        var parsed = JSON.parse(paramHeaders);
        for (var k in parsed) { if (Object.prototype.hasOwnProperty.call(parsed, k)) result[k] = parsed[k]; }
      } catch (e) {}
    }
    return result;
  },
  get: function(url, headers) {
    var realUrl = java._extractUrl(url);
    var fullUrl = realUrl;
    if (realUrl && !realUrl.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
      fullUrl = baseUrl.replace(/\/+$/, '') + '/' + realUrl.replace(/^\/+/, '');
    }
    var cacheKey = 'http_get:' + fullUrl;
    if (_javaCache[cacheKey] !== undefined) {
      var cached = _javaCache[cacheKey];
      if (typeof cached === 'object' && cached !== null && 'body' in cached) return cached;
      return java._buildResponse(cached, fullUrl, {});
    }
    if (fullUrl !== realUrl) {
      var origKey = 'http_get:' + realUrl;
      if (_javaCache[origKey] !== undefined) {
        var origCached = _javaCache[origKey];
        if (typeof origCached === 'object' && origCached !== null && 'body' in origCached) return origCached;
        return java._buildResponse(origCached, realUrl, {});
      }
    }
    return java._buildResponse('', fullUrl, {});
  },
  post: function(url, body, headers) {
    var realUrl = java._extractUrl(url);
    var fullUrl = realUrl;
    if (realUrl && !realUrl.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
      fullUrl = baseUrl.replace(/\/+$/, '') + '/' + realUrl.replace(/^\/+/, '');
    }
    var cacheKey = 'http_post:' + fullUrl;
    if (_javaCache[cacheKey] !== undefined) {
      var cached = _javaCache[cacheKey];
      if (typeof cached === 'object' && cached !== null && 'body' in cached) return cached;
      return java._buildResponse(cached, fullUrl, {});
    }
    if (fullUrl !== realUrl) {
      var origKey = 'http_post:' + realUrl;
      if (_javaCache[origKey] !== undefined) {
        var origCached = _javaCache[origKey];
        if (typeof origCached === 'object' && origCached !== null && 'body' in origCached) return origCached;
        return java._buildResponse(origCached, realUrl, {});
      }
    }
    return java._buildResponse('', fullUrl, {});
  },
  ajax: function(url, headers) {
    var opt = java._parseUrlOptions(url);
    if (opt && opt.method) {
      var method = String(opt.method).toUpperCase();
      var realUrl = opt._url || java._extractUrl(url);
      var reqHeaders = java._mergeHeaders(opt.headers, headers);
      if (method === 'POST') {
        var body = java._normalizeBody(opt.body);
        var resp = java.post(realUrl, body, reqHeaders);
        return (typeof resp === 'object' && resp !== null && 'body' in resp) ? resp.body : String(resp || '');
      }
      if (method === 'HEAD') return java.head(realUrl, reqHeaders);
      if (method === 'PUT' || method === 'DELETE') {
        var body2 = java._normalizeBody(opt.body);
        var resp2 = java.post(realUrl, body2, reqHeaders);
        return (typeof resp2 === 'object' && resp2 !== null && 'body' in resp2) ? resp2.body : String(resp2 || '');
      }
      var resp3 = java.get(realUrl, reqHeaders);
      return (typeof resp3 === 'object' && resp3 !== null && 'body' in resp3) ? resp3.body : String(resp3 || '');
    }
    var resp = java.get(url, headers);
    return (typeof resp === 'object' && resp !== null && 'body' in resp) ? resp.body : String(resp || '');
  },
  ajaxAll: function(urls) {
    if (!urls || !urls.length) return [];
    var results = [];
    for (var i = 0; i < urls.length; i++) results.push(java.ajax(urls[i]));
    return results;
  },
  ajaxTestAll: function(urlList, timeout, skipRateLimit) {
    if (!urlList || !urlList.length) return [];
    var results = [];
    for (var i = 0; i < urlList.length; i++) {
      results.push({ url: urlList[i], body: java.ajax(urlList[i]), code: 200 });
    }
    return results;
  },
  connect: function(urlStr, header, callTimeout) {
    var opt = java._parseUrlOptions(urlStr);
    var realUrl = opt ? (opt._url || java._extractUrl(urlStr)) : urlStr;
    var method = opt && opt.method ? String(opt.method).toUpperCase() : 'GET';
    var body = opt ? java._normalizeBody(opt.body) : '';
    var reqHeaders = opt ? java._mergeHeaders(opt.headers, header) : (header || {});
    var fullUrl = realUrl;
    if (realUrl && !realUrl.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
      fullUrl = baseUrl.replace(/\/+$/, '') + '/' + realUrl.replace(/^\/+/, '');
    }
    var cacheKey = method === 'POST' ? 'http_post:' + fullUrl : 'http_get:' + fullUrl;
    if (_javaCache[cacheKey] !== undefined) {
      var cached = _javaCache[cacheKey];
      if (typeof cached === 'object' && cached !== null && 'body' in cached) return cached;
      return java._buildResponse(cached, fullUrl, reqHeaders);
    }
    if (fullUrl !== realUrl) {
      var origKey = method === 'POST' ? 'http_post:' + realUrl : 'http_get:' + realUrl;
      if (_javaCache[origKey] !== undefined) {
        var origCached = _javaCache[origKey];
        if (typeof origCached === 'object' && origCached !== null && 'body' in origCached) return origCached;
        return java._buildResponse(origCached, realUrl, reqHeaders);
      }
    }
    if (method === 'POST') return java.post(realUrl, body, reqHeaders);
    return java.get(realUrl, reqHeaders);
  },
  head: function(urlStr, headers, timeout) {
    var realUrl = java._extractUrl(urlStr);
    var cacheKey = 'http_head:' + realUrl;
    if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
    if (realUrl !== urlStr) {
      var origKey = 'http_head:' + urlStr;
      if (_javaCache[origKey] !== undefined) return _javaCache[origKey];
    }
    return '';
  },
  getCookie: function(tag, key) {
    var cacheKey = 'cookie:' + tag;
    if (_javaCache[cacheKey] === undefined) return '';
    var cookieStr = _javaCache[cacheKey];
    if (!key) return cookieStr;
    var match = cookieStr.match(new RegExp('(?:^|;\\s*)' + key + '=([^;]+)'));
    return match ? match[1] : '';
  },

  // ===== 变量存取 =====
  put: function(key, value) { _javaCache[key] = typeof value === 'object' ? JSON.stringify(value) : String(value); },
  getStr: function(key, defaultValue) { return _javaCache[key] || (defaultValue || ''); },
  getString: function(str, ruleStr) {
    var content, rule;
    if (ruleStr === undefined || ruleStr === null) { rule = str; content = (typeof result !== 'undefined') ? result : ''; }
    else { content = str; rule = ruleStr; }
    if (!rule) return content || '';
    if (rule.indexOf('@@') === 0) rule = rule.substring(2);
    if (rule.startsWith('@css:') || rule.startsWith('@CSS:')) {
      var cssSel = rule.substring(5);
      var textKey = 'jsoup_text:' + cssSel + ':' + _JsoupLite._hashStr(content || '');
      if (_javaCache[textKey] !== undefined) return _javaCache[textKey];
      var hrefKey = 'jsoup_href:' + cssSel + ':' + _JsoupLite._hashStr(content || '');
      if (_javaCache[hrefKey] !== undefined) return _javaCache[hrefKey];
      return _JsoupLite.selectFirst(content, cssSel);
    }
    if (rule.startsWith('@json:') || rule.startsWith('@JSON:')) {
      try {
        var data = (typeof content === 'string') ? JSON.parse(content) : content;
        var path = rule.substring(6).trim().replace(/^\$\./, '');
        var parts = path.split('.');
        var r = data;
        for (var i = 0; i < parts.length; i++) { if (r == null) return ''; r = r[parts[i]]; }
        return r != null ? String(r) : '';
      } catch(e) { return ''; }
    }
    if (rule.startsWith('@regex:') || rule.startsWith('@Regex:')) {
      try { var pattern = rule.substring(7); var m = String(content).match(new RegExp(pattern)); return m ? (m[1] || m[0]) : ''; } catch(e) { return ''; }
    }
    try {
      var textKey2 = 'jsoup_text:' + rule + ':' + _JsoupLite._hashStr(content || '');
      if (_javaCache[textKey2] !== undefined) return _javaCache[textKey2];
      var hrefKey2 = 'jsoup_href:' + rule + ':' + _JsoupLite._hashStr(content || '');
      if (_javaCache[hrefKey2] !== undefined) return _javaCache[hrefKey2];
      return _JsoupLite.selectFirst(content, rule);
    } catch(e) {}
    return String(content);
  },
  getStrResponse: function(url, ruleStr) { var html = java.ajax(url); if (ruleStr) return java.getString(html, ruleStr); return html; },
  getJson: function(str) { try { return JSON.parse(str); } catch(e) { return {}; } },
  putJson: function(key, value) { _javaCache[key] = JSON.stringify(value); },

  // ===== 加密/解密（重定向到 CryptoJS 纯 JS 实现）=====
  aesEncode: function(data, key, iv) {
    var cacheKey = 'aes_enc:' + data + ':' + key + ':' + (iv || '');
    if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
    try {
      var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
      var result = CryptoJS.AES.encrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString();
      _javaCache[cacheKey] = result;
      return result;
    } catch(e) { _jsLog('AES encrypt failed: ' + e, 'error'); return ''; }
  },
  aesDecode: function(data, key, iv) {
    var cacheKey = 'aes_dec:' + data + ':' + key + ':' + (iv || '');
    if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
    try {
      var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
      var result = CryptoJS.AES.decrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString(CryptoJS.enc.Utf8);
      _javaCache[cacheKey] = result;
      return result;
    } catch(e) { _jsLog('AES decrypt failed: ' + e, 'error'); return ''; }
  },
  aesDecodeBytes: function(data, key, iv) {
    try {
      var s = java.aesDecode(data, key, iv);
      var u8 = new Uint8Array(s.length);
      for (var i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i) & 0xff;
      return u8;
    } catch(e) { return new Uint8Array(0); }
  },
  aesDecodeBatch: function(dataArray, key, iv) {
    if (!Array.isArray(dataArray) || dataArray.length === 0) return [];
    return dataArray.map(function(data) { return java.aesDecode(data, key, iv); });
  },
  md5Encode: function(str) { return _MD5(str); },
  md5Encode16: function(str) { var full = _MD5(str); return full.length >= 32 ? full.substring(8, 24) : ''; },
  sha1Encode: function(str) { return _SHA1(str); },
  sha256Encode: function(str) { return _SHA256(str); },
  hmacSHA256: function(data, key) { return _HMACSHA256(data, key); },
  base64Encode: function(str, flags) { try { return btoa(unescape(encodeURIComponent(str))); } catch(e) { return ''; } },
  base64Decode: function(str, arg2) { try { return decodeURIComponent(escape(atob(str))); } catch(e) { return ''; } },
  base64DecodeToByteArray: function(str) { var decoded = java.base64Decode(str); if (!decoded) return []; return java.strToBytes(decoded); },
  hexDecodeToByteArray: function(hex) { var s = java.hexDecodeToString(hex); return s ? java.strToBytes(s) : []; },
  digestHex: function(data, algorithm) {
    var algo = (algorithm || '').toLowerCase();
    if (algo.indexOf('md5') >= 0) return _MD5(data);
    if (algo.indexOf('sha-1') >= 0 || algo.indexOf('sha1') >= 0) return _SHA1(data);
    if (algo.indexOf('sha-256') >= 0 || algo.indexOf('sha256') >= 0) return _SHA256(data);
    return '';
  },
  digestBase64Str: function(data, algorithm) { var hex = java.digestHex(data, algorithm); if (!hex) return ''; try { return java.base64Encode(java.hexDecodeToString(hex)); } catch(e) { return ''; } },
  HMacHex: function(data, algorithm, key) {
    var algo = (algorithm || '').toLowerCase();
    if (algo.indexOf('sha256') >= 0 || algo.indexOf('hmacsha256') >= 0) return _HMACSHA256(data, key);
    return '';
  },
  HMacBase64Str: function(data, algorithm, key) { var hex = java.HMacHex(data, algorithm, key); if (!hex) return ''; try { return java.base64Encode(java.hexDecodeToString(hex)); } catch(e) { return ''; } },
  HMacBase64: function(data, algorithm, key) { return java.HMacBase64Str(data, algorithm, key); },

  // ===== HTML 解析（重定向到 _JsoupLite 纯 JS 实现）=====
  jsoup: {
    parse: function(html) {
      return {
        html: html,
        select: function(sel) { return _JsoupLite.selectAll(html, sel); },
        selectFirst: function(sel) { return _JsoupLite.selectFirst(html, sel); },
        text: function() { return (html || '').replace(/<[^>]+>/g, '').trim(); },
      };
    },
    select: function(html, selector) { return _JsoupLite.selectAll(html, selector); },
    selectFirst: function(html, selector) { var result = _JsoupLite.selectFirst(html, selector); return result ? result.replace(/<[^>]+>/g, '').trim() : ''; },
    getAttr: function(html, selector, attr) { return _JsoupLite.getAttr(html, selector, attr); },
    clean: function(html) {
      if (!html) return '';
      return html.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '')
                 .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '')
                 .replace(/<[^>]+>/g, '')
                 .replace(/&nbsp;/g, ' ')
                 .replace(/&amp;/g, '&')
                 .replace(/&lt;/g, '<')
                 .replace(/&gt;/g, '>')
                 .replace(/&quot;/g, '"')
                 .trim();
    },
  },

  // ===== 正则操作 =====
  regex: {
    match: function(str, pattern) { try { var m = str.match(new RegExp(pattern)); return m ? m[0] : ''; } catch(e) { return ''; } },
    matchAll: function(str, pattern) { try { var results = []; var r = new RegExp(pattern, 'g'); var m; while(m = r.exec(str)) { results.push(m[0]); } return results; } catch(e) { return []; } },
    replace: function(str, pattern, replacement) { try { return str.replace(new RegExp(pattern, 'g'), replacement); } catch(e) { return str; } },
    test: function(str, pattern) { try { return new RegExp(pattern).test(str); } catch(e) { return false; } },
  },

  // ===== 时间/编码工具 =====
  timeFormat: function(timestamp, format) {
    var d = new Date(timestamp);
    if (!format) return d.toLocaleString();
    return format.replace(/yyyy/g, d.getFullYear()).replace(/MM/g, (d.getMonth() + 1).toString().padStart(2, '0')).replace(/dd/g, d.getDate().toString().padStart(2, '0')).replace(/HH/g, d.getHours().toString().padStart(2, '0')).replace(/mm/g, d.getMinutes().toString().padStart(2, '0')).replace(/ss/g, d.getSeconds().toString().padStart(2, '0'));
  },
  timeFormatUTC: function(timestamp, format, offset) {
    var d = new Date(timestamp);
    if (offset) d = new Date(d.getTime() + offset * 3600000);
    var year = d.getUTCFullYear().toString();
    return format.replace(/yyyy/g, year).replace(/yy/g, year.slice(-2)).replace(/MM/g, (d.getUTCMonth() + 1).toString().padStart(2, '0')).replace(/dd/g, d.getUTCDate().toString().padStart(2, '0')).replace(/HH/g, d.getUTCHours().toString().padStart(2, '0')).replace(/mm/g, d.getUTCMinutes().toString().padStart(2, '0')).replace(/ss/g, d.getUTCSeconds().toString().padStart(2, '0'));
  },
  getTime: function() { return Date.now(); },
  encodeURI: function(str, enc) { return encodeURIComponent(str); },
  hexEncodeToString: function(str) { var hex = ''; for (var i = 0; i < str.length; i++) { hex += str.charCodeAt(i).toString(16).padStart(2, '0'); } return hex; },
  hexDecodeToString: function(hex) { var str = ''; for (var i = 0; i < hex.length; i += 2) { str += String.fromCharCode(parseInt(hex.substr(i, 2), 16)); } return str; },
  strToBytes: function(str, charset) { var bytes = []; for (var i = 0; i < str.length; i++) { var c = str.charCodeAt(i); if (c < 128) { bytes.push(c); } else if (c < 2048) { bytes.push(192 | (c >> 6), 128 | (c & 63)); } else { bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 63), 128 | (c & 63)); } } return bytes; },
  bytesToStr: function(bytes, charset) { if (!bytes || !bytes.length) return ''; var str = ''; for (var i = 0; i < bytes.length; i++) { str += String.fromCharCode(bytes[i] & 0xFF); } try { return decodeURIComponent(escape(str)); } catch(e) { return str; } },

  // ===== WebView（从缓存取）=====
  webview: { eval: function(url, js) { var cacheKey = 'webview:' + url + ':' + (js || '').length; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; } },
  webView: function(html, url, js, cacheFirst) { var cacheKey = 'webview:' + (url || '') + ':' + (html || '').length; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  webViewGetSource: function(html, url, js, sourceRegex, cacheFirst, delayTime) { var cacheKey = 'webview_src:' + (url || '') + ':' + (sourceRegex || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  webViewGetOverrideUrl: function(html, url, js, overrideUrlRegex, cacheFirst, delayTime) { var cacheKey = 'webview_override:' + (url || '') + ':' + (overrideUrlRegex || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  openVideoPlayer: function(url, title, isFloat) {},

  // ===== 缓存管理 =====
  cache: { get: function(key) { return _javaCache[key] || ''; }, put: function(key, value) { _javaCache[key] = value; }, delete: function(key) { delete _javaCache[key]; } },
  log: function(msg) { console.log('[JavaBridge] ' + msg); },

  // ===== 文件操作（从缓存取）=====
  cacheFile: function(url, saveTime) { var cacheKey = 'cache_file:' + url; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  downloadFile: function(urlOrContent, url) { var u = url === undefined ? urlOrContent : url; var cacheKey = 'download_file:' + u; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return '/tmp/' + _MD5(u).substring(0, 16); },
  getFile: function(path) { return { path: path, exists: function() { return false; }, readText: function() { return ''; } }; },
  importScript: function(path) { var cacheKey = 'file_importScript:' + path; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  readFile: function(path) { var cacheKey = 'file_readFile:' + path; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  readTxtFile: function(path, charset) { var cacheKey = 'file_readTxtFile:' + path; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  deleteFile: function(path) { var cacheKey = 'file_deleteFile:' + path; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey] === 'true'; return false; },
  writeFile: function(path, content) { var cacheKey = 'file_writeFile:' + path; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey] === 'true'; return false; },
  unzipFile: function(path, password) { var cacheKey = 'archive_unzipFile:' + path + '::' + (password || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  un7zFile: function(path, password) { var cacheKey = 'archive_un7zFile:' + path + '::' + (password || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  unrarFile: function(path, password) { var cacheKey = 'archive_unrarFile:' + path + '::' + (password || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  unArchiveFile: function(path, password) { var cacheKey = 'archive_unArchiveFile:' + path + '::' + (password || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  getZipStringContent: function(path, password) { var cacheKey = 'archive_getZipStringContent:' + path + '::' + (password || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  getRarStringContent: function(path, password) { var cacheKey = 'archive_getRarStringContent:' + path + '::' + (password || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  get7zStringContent: function(path, password) { var cacheKey = 'archive_get7zStringContent:' + path + '::' + (password || ''); if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },

  // ===== 浏览器/验证码（从缓存取）=====
  startBrowser: function(url, title, html) {},
  startBrowserAwait: function(url, title, refetchAfterSuccess, html) { var cacheKey = 'browser:' + url; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  getVerificationCode: function(imageUrl) { var cacheKey = 'captcha:' + imageUrl; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return ''; },
  openUrl: function(url) {},

  // ===== 文本处理 =====
  htmlFormat: function(str) {
    if (!str) return '';
    return str.replace(/<p[^>]*>/gi, '\n').replace(/<br[^>]*\/?>/gi, '\n').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\n{3,}/g, '\n\n').trim();
  },
  toNumChapter: function(s) {
    if (!s) return '';
    var numMap = {'零':0,'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9,'十':10,'百':100,'千':1000,'万':10000};
    var m = s.match(/(\d+)/);
    if (m) return m[1];
    var result = 0, current = 0;
    for (var i = 0; i < s.length; i++) { var ch = s[i]; if (numMap[ch] !== undefined) { var val = numMap[ch]; if (val >= 10) { current = current === 0 ? val : current * val; if (val >= 10000) { result = (result + current) * val; current = 0; } else if (val >= 1000) { result += current; current = 0; } } else { current = val; } } }
    return String(result + current);
  },

  // ===== 工具方法 =====
  toast: function(msg) { console.log('[Toast] ' + msg); },
  longToast: function(msg) { console.log('[LongToast] ' + msg); },
  getWebViewUA: function() { var cacheKey = 'webview_ua'; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'; },
  randomUUID: function() { return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) { var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16); }); },
  androidId: function() { var cacheKey = 'android_id'; if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey]; return java.randomUUID().replace(/-/g, '').substring(0, 16); },
};

// ===== 挂载 java 到 globalThis + 自动挂载所有方法到全局 =====
globalThis.java = java;
// 快捷全局方法
globalThis.select = function(html, selector) { return java.jsoup.select(html, selector); };
globalThis.selectFirst = function(html, selector) { return java.jsoup.selectFirst(html, selector); };
globalThis.getAttr = function(html, selector, attr) { return java.jsoup.getAttr(html, selector, attr); };
globalThis.clean = function(html) { return java.jsoup.clean(html); };
globalThis.getString = function(content, rule) { return java.getString(content, rule); };
globalThis.put = function(key, value) { return java.put(key, value); };
globalThis.getStr = function(key, def) { return java.getStr(key, def); };
globalThis.base64Encode = function(str) { return java.base64Encode(str); };
globalThis.base64Decode = function(str) { return java.base64Decode(str); };
globalThis.md5Encode = function(str) { return java.md5Encode(str); };
globalThis.sha256Encode = function(str) { return java.sha256Encode ? java.sha256Encode(str) : ''; };
globalThis.aesEncode = function(data, key, iv) { return java.aesEncode(data, key, iv); };
globalThis.aesDecode = function(data, key, iv) { return java.aesDecode(data, key, iv); };
globalThis.getWebViewUA = function() { return java.getWebViewUA(); };
globalThis.ajax = function(url, opt) { return java.ajax(url, opt); };
globalThis.timeFormatUTC = function(ts, fmt, offset) { return java.timeFormatUTC(ts, fmt, offset); };

// 自动挂载所有 java 方法到 globalThis（对齐 Legado 行为）
(function() {
  var _alreadyMounted = {
    getString: true, put: true, getStr: true,
    base64Encode: true, base64Decode: true,
    md5Encode: true, sha256Encode: true,
    aesEncode: true, aesDecode: true,
    getWebViewUA: true, ajax: true, timeFormatUTC: true
  };
  Object.keys(java).forEach(function(k) {
    if (_alreadyMounted[k] || k.charAt(0) === '_') return;
    try {
      if (typeof java[k] === 'function' && typeof globalThis[k] === 'undefined') {
        globalThis[k] = function() { return java[k].apply(java, arguments); };
      }
    } catch (e) {}
  });
})();
