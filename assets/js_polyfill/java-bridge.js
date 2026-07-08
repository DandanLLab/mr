/**
 * java-bridge.js — QuickJS 桥接脚本（纯路由模式）
 *
 * 架构原则：
 *   - 加密/哈希 → __nativeCrypto（C 原生，零 JS 解释器开销）
 *   - HTML 解析 → __nativeHtml（C 原生，替代 _JsoupLite）
 *   - Base64 → __nativeBase64（C 原生）
 *   - LZString → __nativeLz（C 原生）
 *   - 编码转换 → __nativeConv（C 原生）
 *   - HTTP 请求 → 网络标记协议（Dart Dio 处理）
 *   - 工具方法 → 最小化 JS 实现
 *
 * 网络标记协议：
 *   JS 调用 java.get(url) 时，若 _javaCache 中无缓存，
 *   抛出特殊标记 __NEED_NETWORK__:{JSON}，
 *   Dart 侧捕获后用 Dio 发起请求，结果写入 _javaCache，
 *   然后重新执行 JS 脚本。
 */

// ===== 基础变量 =====
var _javaCache = {};
var _pendingNetwork = null;  // 待处理的网络请求

// ===== Node.js 最小兼容层 =====
var process = {
  env: {},
  argv: [],
  version: 'v18.17.0',
  platform: 'android',
  arch: 'arm64',
  pid: 1,
  cwd: function() { return '/'; },
  exit: function(code) {},
  nextTick: function(fn) { setTimeout(fn, 0); },
  on: function(event, handler) {},
  stdout: { write: function(data) {} },
  stderr: { write: function(data) {} },
};

var Buffer = {
  from: function(data, encoding) {
    if (typeof data === 'string') {
      return { toString: function() { return data; }, length: data.length };
    }
    return { length: data ? data.length : 0 };
  },
  isBuffer: function(obj) { return false; },
  concat: function(list) { return Buffer.from(list.join('')); },
};

// ===== URL/URLSearchParams 兼容层 =====
function URL(url, base) {
  if (!(this instanceof URL)) return new URL(url, base);
  var input = url || '';
  if (base) {
    var baseParsed = new URL(base);
    if (input.startsWith('/') || input.startsWith('./') || input.startsWith('../')) {
      input = baseParsed.origin + input;
    } else if (!input.startsWith('http')) {
      input = baseParsed.origin + '/' + input;
    }
  }
  this.href = input;
  var protoMatch = input.match(/^(https?:)\/\//i);
  this.protocol = protoMatch ? protoMatch[1] : '';
  var hostMatch = input.match(/^https?:\/\/([^\/?#]+)/i);
  this.host = hostMatch ? hostMatch[1] : '';
  if (this.host) {
    var parts = this.host.split(':');
    this.hostname = parts[0];
    this.port = parts.length > 1 ? parts[1] : '';
  } else {
    this.hostname = '';
    this.port = '';
  }
  this.origin = this.protocol ? this.protocol + '//' + this.host : '';
  var pathPart = hostMatch ? input.substring(hostMatch.index + hostMatch[0].length) : input;
  var hashIdx = pathPart.indexOf('#');
  var hashPart = '';
  if (hashIdx >= 0) {
    hashPart = pathPart.substring(hashIdx);
    pathPart = pathPart.substring(0, hashIdx);
  }
  var searchIdx = pathPart.indexOf('?');
  if (searchIdx >= 0) {
    this.search = pathPart.substring(searchIdx);
    this.pathname = pathPart.substring(0, searchIdx) || '/';
  } else {
    this.search = '';
    this.pathname = pathPart || '/';
  }
  this.hash = hashPart;
  this.toString = function() { return this.href; };
}

function URLSearchParams(init) {
  if (!(this instanceof URLSearchParams)) return new URLSearchParams(init);
  this._params = [];
  if (typeof init === 'string') {
    var str = init.startsWith('?') ? init.substring(1) : init;
    if (str) {
      var pairs = str.split('&');
      for (var i = 0; i < pairs.length; i++) {
        var eq = pairs[i].indexOf('=');
        if (eq >= 0) {
          this._params.push([decodeURIComponent(pairs[i].substring(0, eq)), decodeURIComponent(pairs[i].substring(eq + 1))]);
        } else if (pairs[i]) {
          this._params.push([decodeURIComponent(pairs[i]), '']);
        }
      }
    }
  }
  this.get = function(name) {
    for (var i = 0; i < this._params.length; i++) {
      if (this._params[i][0] === name) return this._params[i][1];
    }
    return null;
  };
  this.toString = function() {
    return this._params.map(function(p) { return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]); }).join('&');
  };
}

// ===== btoa/atob → __nativeBase64 =====
function btoa(str) {
  if (typeof __nativeBase64 !== 'undefined') return __nativeBase64.encode(str);
  // 回退：简易实现
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
  if (typeof __nativeBase64 !== 'undefined') return __nativeBase64.decode(str);
  // 回退：简易实现
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

// ===== Uint8Array → 字符串（C 原生）=====
// 兼容 number[] 入参：C 层 __nativeBase64.uint8ToStr 只认 ArrayBuffer/Uint8Array，
// 直接传 number[] 会返回空串导致后续链路断掉，此处统一转 Uint8Array 再走 C 层。
function _u8ToStr(u8) {
  if (Array.isArray(u8)) u8 = new Uint8Array(u8);
  if (typeof __nativeBase64 !== 'undefined' && __nativeBase64.uint8ToStr && u8 instanceof Uint8Array) {
    var r = __nativeBase64.uint8ToStr(u8);
    if (r) return r;  // C 层失败返回空串时走 fallback
  }
  var s = '';
  for (var i = 0; i < u8.length; i++) s += String.fromCharCode(u8[i]);
  try { return decodeURIComponent(escape(s)); } catch(e) { return s; }
}

function _strToU8(str) {
  var bytes = [];
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    // 检测 UTF-16 代理对（emoji 等 U+10000-U+10FFFF 字符），合并为 4 字节 UTF-8
    // 否则高低代理各自被当作 3 字节 UTF-8 编码，产生 6 字节无效序列
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
      var c2 = str.charCodeAt(i + 1);
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        var code = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
        bytes.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
        i++;  // 跳过低代理
        continue;
      }
    }
    if (c < 128) bytes.push(c);
    else if (c < 2048) bytes.push(192 | (c >> 6), 128 | (c & 63));
    else bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 0x3F), 128 | (c & 0x3F));
  }
  return new Uint8Array(bytes);
}

// ===== LZString 兼容层 → __nativeLz =====
// 注意：C 原生 __nativeLz.decompressFromBase64 在解压失败或空串时返回 null，
// 此处统一兜底为 ''，避免下游 JSON.parse(null) → null → null.data 抛 TypeError
var LZString = {
  decompressFromBase64: function(str) {
    if (typeof __nativeLz !== 'undefined') {
      var r = __nativeLz.decompressFromBase64(str);
      return r === null ? '' : r;
    }
    return '';
  },
  decompress: function(str) {
    if (str == null) return '';
    if (str === '') return '';
    // 优先使用 C 原生实现（若已注册）。注意：C 层 __nativeLz 当前仅暴露
    // decompressFromBase64/Batch/Bin，标准 decompress（resetValue=32768，输入为原始压缩串）未注册，
    // 故此处 typeof 保护下走纯 JS 兜底，避免误用 decompressFromBase64（resetValue=32）导致语义错位。
    if (typeof __nativeLz !== 'undefined' && typeof __nativeLz.decompress === 'function') {
      var r = __nativeLz.decompress(str);
      return r === null ? '' : r;
    }
    // 纯 JS 实现（对齐 lz-string 官方 decompress：resetValue=32768）。
    // 关键：输入读取必须用 charCodeAt，否则含高位字节的压缩串会错位（见 project_memory LZString 教训）。
    var dictionary = [0, 1, 2];
    var enlargeIn = 4, dictSize = 4, numBits = 3;
    var entry, w, c, bits, resb, maxpower, power;
    var data = { val: str.charCodeAt(0), position: 32768, index: 1 };
    function readBits(n) {
      bits = 0; maxpower = Math.pow(2, n); power = 1;
      while (power != maxpower) {
        resb = data.val & data.position;
        data.position >>= 1;
        if (data.position == 0) { data.position = 32768; data.val = str.charCodeAt(data.index++); }
        bits |= (resb > 0 ? 1 : 0) * power;
        power <<= 1;
      }
      return bits;
    }
    var next = readBits(2);
    if (next === 0) c = String.fromCharCode(readBits(8));
    else if (next === 1) c = String.fromCharCode(readBits(16));
    else return '';  // next === 2
    dictionary[3] = c; w = c;
    var result = c;
    while (true) {
      c = readBits(numBits);
      if (c === 0) { dictionary[dictSize++] = String.fromCharCode(readBits(8)); enlargeIn--; }
      else if (c === 1) { dictionary[dictSize++] = String.fromCharCode(readBits(16)); enlargeIn--; }
      else if (c === 2) return result;
      if (enlargeIn === 0) { enlargeIn = Math.pow(2, numBits); numBits++; }
      if (dictionary[c] !== undefined) entry = dictionary[c];
      else { if (c === dictSize) entry = w + w.charAt(0); else return ''; }
      result += entry;
      dictionary[dictSize++] = w + entry.charAt(0);
      enlargeIn--;
      if (enlargeIn === 0) { enlargeIn = Math.pow(2, numBits); numBits++; }
      w = entry;
    }
  },
  compressToBase64: function(str) {
    // 注意：这是 stub 实现，仅做 base64 编码，不是真正的 LZ 压缩。
    // C 层 __nativeLz 未暴露 compress 方法，纯 JS 实现 LZ 压缩算法开销大且书源几乎不用。
    // 若书源确实需要 LZ 压缩，应在此处补充完整实现或下沉到 C 层。
    return btoa(str);
  },
};

// ===== console 增强 =====
var __consoleLogs = [];
var console = {
  log: function() { __consoleLogs.push({ level: 'log', msg: Array.prototype.slice.call(arguments).join(' ') }); },
  warn: function() { __consoleLogs.push({ level: 'warn', msg: Array.prototype.slice.call(arguments).join(' ') }); },
  error: function() { __consoleLogs.push({ level: 'error', msg: Array.prototype.slice.call(arguments).join(' ') }); },
  info: function() { __consoleLogs.push({ level: 'info', msg: Array.prototype.slice.call(arguments).join(' ') }); },
  debug: function() { __consoleLogs.push({ level: 'debug', msg: Array.prototype.slice.call(arguments).join(' ') }); },
  _getLogs: function() { return __consoleLogs.slice(); },
  _clearLogs: function() { __consoleLogs.length = 0; },
};

// ===== CryptoJS 兼容层 → __nativeCrypto =====
var CryptoJS = {
  enc: {
    Utf8: {
      parse: function(str) { return _strToU8(str); },
      stringify: function(u8) { return _u8ToStr(u8); },
    },
    Base64: {
      parse: function(str) {
        if (typeof __nativeBase64 !== 'undefined' && __nativeBase64.decodeToBytes) return __nativeBase64.decodeToBytes(str);
        return _strToU8(atob(str));
      },
      stringify: function(u8) {
        if (typeof __nativeBase64 !== 'undefined' && __nativeBase64.b64FromBytes) return __nativeBase64.b64FromBytes(u8);
        return btoa(_u8ToStr(u8));
      },
    },
    Hex: {
      parse: function(hex) {
        var bytes = [];
        for (var i = 0; i < hex.length; i += 2) bytes.push(parseInt(hex.substr(i, 2), 16));
        return new Uint8Array(bytes);
      },
      stringify: function(u8) {
        var hex = '';
        for (var i = 0; i < u8.length; i++) hex += (u8[i] < 16 ? '0' : '') + u8[i].toString(16);
        return hex;
      },
    },
  },
  AES: {
    encrypt: function(data, key, cfg) {
      // 统一 key 为 Uint8Array（key 通常来自 enc.Utf8.parse → _strToU8 → Uint8Array；
      // 也可能是 enc.Base64.parse → __nativeBase64.decodeToBytes → ArrayBuffer）
      var keyU8 = key instanceof Uint8Array ? key : (Array.isArray(key) ? new Uint8Array(key) : (key instanceof ArrayBuffer ? new Uint8Array(key) : _strToU8(String(key))));
      // 统一 iv 为 Uint8Array（书源可能传 number[] / Uint8Array / ArrayBuffer / string）
      var ivU8 = null;
      if (cfg && cfg.iv) {
        var iv = cfg.iv;
        ivU8 = iv instanceof Uint8Array ? iv : (Array.isArray(iv) ? new Uint8Array(iv) : (iv instanceof ArrayBuffer ? new Uint8Array(iv) : (typeof iv === 'string' ? _strToU8(iv) : null)));
      }
      // 统一 data 为 Uint8Array（书源可能传字符串、CryptoJS.enc.Utf8.parse → Uint8Array、enc.Base64.parse → ArrayBuffer）
      var dataU8 = data instanceof Uint8Array ? data : (Array.isArray(data) ? new Uint8Array(data) : (data instanceof ArrayBuffer ? new Uint8Array(data) : _strToU8(String(data))));
      var result;
      if (typeof __nativeCrypto !== 'undefined') {
        if (ivU8 && ivU8.length > 0 && __nativeCrypto.aesEncryptNative) {
          // CBC 模式：直接走原生 ArrayBuffer 路径，零 base64 开销
          var cipherU8 = __nativeCrypto.aesEncryptNative(dataU8, keyU8, ivU8);
          if (cipherU8 && cipherU8.byteLength > 0) result = btoa(_u8ToStr(cipherU8));
        } else if ((!ivU8 || ivU8.length === 0) && __nativeCrypto.aesEncryptNativeECB) {
          // ECB 模式：原生 ArrayBuffer 路径
          var cipherU8Ecb = __nativeCrypto.aesEncryptNativeECB(dataU8, keyU8);
          if (cipherU8Ecb && cipherU8Ecb.byteLength > 0) result = btoa(_u8ToStr(cipherU8Ecb));
        } else if (ivU8 && ivU8.length > 0 && __nativeCrypto.aesEncryptFromBase64) {
          // 兜底：base64 字符串路径
          result = __nativeCrypto.aesEncryptFromBase64(btoa(_u8ToStr(dataU8)), _u8ToStr(keyU8), _u8ToStr(ivU8));
        } else if ((!ivU8 || ivU8.length === 0) && __nativeCrypto.aesEncryptFromBase64ECB) {
          result = __nativeCrypto.aesEncryptFromBase64ECB(btoa(_u8ToStr(dataU8)), _u8ToStr(keyU8));
        }
      }
      return { toString: function() { return result || ''; } };
    },
    decrypt: function(ciphertext, key, cfg) {
      // 统一 key 为 Uint8Array（key 通常来自 enc.Utf8.parse → _strToU8 → Uint8Array；
      // 也可能是 enc.Base64.parse → __nativeBase64.decodeToBytes → ArrayBuffer）
      var keyU8 = key instanceof Uint8Array ? key : (Array.isArray(key) ? new Uint8Array(key) : (key instanceof ArrayBuffer ? new Uint8Array(key) : _strToU8(String(key))));
      // 统一 iv 为 Uint8Array（书源可能传 number[] / Uint8Array / ArrayBuffer / string）
      var ivU8 = null;
      if (cfg && cfg.iv) {
        var iv = cfg.iv;
        ivU8 = iv instanceof Uint8Array ? iv : (Array.isArray(iv) ? new Uint8Array(iv) : (iv instanceof ArrayBuffer ? new Uint8Array(iv) : (typeof iv === 'string' ? _strToU8(iv) : null)));
      }
      var hasIv = ivU8 && ivU8.length > 0;
      var result;
      if (typeof __nativeCrypto !== 'undefined') {
        // cipher 为字节序列（number[] / Uint8Array / ArrayBuffer）时优先走 aesDecryptNative，零 base64 开销。
        // 兼容书源常见写法：atob(result) 取字节 → number[] 直接传入 CryptoJS.AES.decrypt；
        // 或 CryptoJS.enc.Base64.parse(base64Cipher) → ArrayBuffer → 传入 CryptoJS.AES.decrypt。
        var isBytes = (ciphertext instanceof Uint8Array) || (ciphertext instanceof ArrayBuffer) || Array.isArray(ciphertext);
        if (isBytes && hasIv && __nativeCrypto.aesDecryptNative) {
          var ctU8 = ciphertext instanceof Uint8Array ? ciphertext : new Uint8Array(ciphertext);
          var plainU8 = __nativeCrypto.aesDecryptNative(ctU8, keyU8, ivU8);
          if (plainU8 && plainU8.byteLength > 0) result = _u8ToStr(plainU8);
        } else if (isBytes && !hasIv && __nativeCrypto.aesDecryptNativeECB) {
          // ECB 模式：字节数组直接走原生
          var ctU8Ecb = ciphertext instanceof Uint8Array ? ciphertext : new Uint8Array(ciphertext);
          var plainU8Ecb = __nativeCrypto.aesDecryptNativeECB(ctU8Ecb, keyU8);
          if (plainU8Ecb && plainU8Ecb.byteLength > 0) result = _u8ToStr(plainU8Ecb);
        } else if (hasIv && __nativeCrypto.aesDecryptFromBase64) {
          // cipher 为 base64 字符串（标准 CryptoJS 路径）；数组则先转 base64
          var ctStr = typeof ciphertext === 'string' ? ciphertext : btoa(_u8ToStr(new Uint8Array(ciphertext)));
          var plainU8b = __nativeCrypto.aesDecryptFromBase64(ctStr, _u8ToStr(keyU8), _u8ToStr(ivU8));
          if (plainU8b && plainU8b.byteLength > 0) result = _u8ToStr(plainU8b);
        } else if (!hasIv && __nativeCrypto.aesDecryptFromBase64ECB) {
          var ctStr2 = typeof ciphertext === 'string' ? ciphertext : btoa(_u8ToStr(new Uint8Array(ciphertext)));
          var plainU8c = __nativeCrypto.aesDecryptFromBase64ECB(ctStr2, _u8ToStr(keyU8));
          if (plainU8c && plainU8c.byteLength > 0) result = _u8ToStr(plainU8c);
        }
      }
      return { toString: function(enc) { return result || ''; } };
    },
  },
  MD5: function(data) {
    if (typeof __nativeCrypto !== 'undefined') return { toString: function() { return __nativeCrypto.md5(data); } };
    return { toString: function() { return ''; } };
  },
  SHA1: function(data) {
    if (typeof __nativeCrypto !== 'undefined') return { toString: function() { return __nativeCrypto.sha1(data); } };
    return { toString: function() { return ''; } };
  },
  SHA256: function(data) {
    if (typeof __nativeCrypto !== 'undefined') return { toString: function() { return __nativeCrypto.sha256(data); } };
    return { toString: function() { return ''; } };
  },
  HmacSHA256: function(data, key) {
    if (typeof __nativeCrypto !== 'undefined') return { toString: function() { return __nativeCrypto.hmacSHA256(data, key); } };
    return { toString: function() { return ''; } };
  },
  mode: { CBC: 1, ECB: 2, CFB: 3, OFB: 4, CTR: 5 },
  pad: { Pkcs7: 1, ZeroPadding: 2, NoPadding: 3, Iso10126: 4, Iso97971: 5 },
};

// ===== fetch 兼容（网络标记协议）=====
function fetch(url, options) {
  var method = (options && options.method) || 'GET';
  var body = (options && options.body) || '';
  var headers = (options && options.headers) || {};
  var fullUrl = url;
  if (url && !url.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
    fullUrl = baseUrl.replace(/\/+$/, '') + '/' + url.replace(/^\/+/, '');
  }
  var cacheKey = 'http_' + method.toLowerCase() + ':' + fullUrl;
  if (_javaCache[cacheKey] !== undefined) {
    var cached = _javaCache[cacheKey];
    return {
      text: function() { return typeof cached === 'object' && cached.body ? cached.body : String(cached || ''); },
      json: function() { try { return JSON.parse(typeof cached === 'string' ? cached : cached.body || '{}'); } catch(e) { return {}; } },
      ok: true,
      status: 200,
    };
  }
  // 网络标记：通知 Dart 侧需要发起 HTTP 请求
  _pendingNetwork = JSON.stringify({ method: method, url: fullUrl, body: body, headers: headers, cacheKey: cacheKey });
  throw '__NEED_NETWORK__:' + _pendingNetwork;
}

// ===== _JsoupLite → __nativeHtml 路由 =====
var _JsoupLite = {
  selectFirst: function(html, selector) {
    if (typeof __nativeHtml !== 'undefined') return __nativeHtml.select(html, selector, '@text');
    return '';
  },
  selectAll: function(html, selector) {
    if (typeof __nativeHtml !== 'undefined') {
      var result = __nativeHtml.selectAll(html, selector, '@outerHtml');
      try { return JSON.parse(result); } catch(e) { return []; }
    }
    return [];
  },
  getAttr: function(html, selector, attr) {
    if (typeof __nativeHtml !== 'undefined') return __nativeHtml.getAttr(html, selector, attr);
    return '';
  },
};

// ===== java 桥接对象 =====
var java = {
  // ===== 辅助方法 =====
  _buildResponse: function(body, url, headers) {
    return {
      body: body || '',
      url: url || '',
      headerMap: headers || {},
      html: body || '',
      toString: function() { return this.body; },
      getHeader: function(name) { return this.headerMap[name] || ''; },
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
  _fullUrl: function(url) {
    if (url && !url.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
      return baseUrl.replace(/\/+$/, '') + '/' + url.replace(/^\/+/, '');
    }
    return url;
  },

  // ===== HTTP 请求（网络标记协议）=====
  get: function(url, headers) {
    var realUrl = java._extractUrl(url);
    var fullUrl = java._fullUrl(realUrl);
    var cacheKey = 'http_get:' + fullUrl;
    if (_javaCache[cacheKey] !== undefined) {
      var cached = _javaCache[cacheKey];
      if (typeof cached === 'object' && cached !== null && 'body' in cached) return cached;
      return java._buildResponse(cached, fullUrl, {});
    }
    // 网络标记
    _pendingNetwork = JSON.stringify({ method: 'GET', url: fullUrl, body: '', headers: headers || {}, cacheKey: cacheKey });
    throw '__NEED_NETWORK__:' + _pendingNetwork;
  },
  post: function(url, body, headers) {
    var realUrl = java._extractUrl(url);
    var fullUrl = java._fullUrl(realUrl);
    var cacheKey = 'http_post:' + fullUrl;
    if (_javaCache[cacheKey] !== undefined) {
      var cached = _javaCache[cacheKey];
      if (typeof cached === 'object' && cached !== null && 'body' in cached) return cached;
      return java._buildResponse(cached, fullUrl, {});
    }
    _pendingNetwork = JSON.stringify({ method: 'POST', url: fullUrl, body: java._normalizeBody(body), headers: headers || {}, cacheKey: cacheKey });
    throw '__NEED_NETWORK__:' + _pendingNetwork;
  },
  ajax: function(url, headers) {
    var opt = java._parseUrlOptions(url);
    if (opt && opt.method) {
      var method = String(opt.method).toUpperCase();
      var realUrl = opt._url || java._extractUrl(url);
      var reqHeaders = java._mergeHeaders(opt.headers, headers);
      if (method === 'POST') {
        var resp = java.post(realUrl, java._normalizeBody(opt.body), reqHeaders);
        return (typeof resp === 'object' && resp !== null && 'body' in resp) ? resp.body : String(resp || '');
      }
      var respG = java.get(realUrl, reqHeaders);
      return (typeof respG === 'object' && respG !== null && 'body' in respG) ? respG.body : String(respG || '');
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
    if (method === 'POST') return java.post(realUrl, body, reqHeaders);
    return java.get(realUrl, reqHeaders);
  },
  head: function(urlStr, headers, timeout) {
    var realUrl = java._extractUrl(urlStr);
    var cacheKey = 'http_head:' + realUrl;
    if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
    _pendingNetwork = JSON.stringify({ method: 'HEAD', url: realUrl, body: '', headers: headers || {}, cacheKey: cacheKey });
    throw '__NEED_NETWORK__:' + _pendingNetwork;
  },
  getStrResponse: function(url, ruleStr) {
    var html = java.ajax(url);
    if (ruleStr) return java.getString(html, ruleStr);
    return html;
  },

  // ===== 变量存取 =====
  put: function(key, value) { _javaCache[key] = typeof value === 'object' ? JSON.stringify(value) : String(value); },
  getStr: function(key, defaultValue) { return _javaCache[key] || (defaultValue || ''); },
  getString: function(str, ruleStr) {
    var content, rule;
    if (ruleStr === undefined || ruleStr === null) {
      rule = str; content = (typeof result !== 'undefined') ? result : '';
    } else {
      content = str; rule = ruleStr;
    }
    if (!rule) return content || '';
    if (rule.indexOf('@@') === 0) rule = rule.substring(2);
    if (rule.startsWith('@css:') || rule.startsWith('@CSS:')) {
      return _JsoupLite.selectFirst(content, rule.substring(5));
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
      try { var m = String(content).match(new RegExp(rule.substring(7))); return m ? (m[1] || m[0]) : ''; } catch(e) { return ''; }
    }
    try { return _JsoupLite.selectFirst(content, rule); } catch(e) {}
    return String(content);
  },
  getJson: function(str) { try { return JSON.parse(str); } catch(e) { return {}; } },
  putJson: function(key, value) { _javaCache[key] = JSON.stringify(value); },

  // ===== 加密/解密（路由到 __nativeCrypto）=====
  aesEncode: function(data, key, iv) {
    var cacheKey = 'aes_enc:' + data + ':' + key + ':' + (iv || '');
    if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
    try {
      var result;
      if (typeof CryptoJS !== 'undefined' && CryptoJS.AES) {
        var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
        result = CryptoJS.AES.encrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString();
      }
      _javaCache[cacheKey] = result;
      return result;
    } catch(e) { return ''; }
  },
  aesDecode: function(data, key, iv) {
    var cacheKey = 'aes_dec:' + data + ':' + key + ':' + (iv || '');
    if (_javaCache[cacheKey] !== undefined) return _javaCache[cacheKey];
    try {
      var result;
      if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto.aesDecryptFromBase64) {
        var plainU8 = iv ? __nativeCrypto.aesDecryptFromBase64(data, key, iv) : __nativeCrypto.aesDecryptFromBase64ECB(data, key);
        if (plainU8 && plainU8.byteLength > 0) {
          result = _u8ToStr(plainU8);
          if (result && result.length > 0) { _javaCache[cacheKey] = result; return result; }
        }
      }
      if (typeof CryptoJS !== 'undefined' && CryptoJS.AES) {
        var cfg = iv ? { iv: CryptoJS.enc.Utf8.parse(iv), mode: CryptoJS.mode.CBC } : { mode: CryptoJS.mode.ECB };
        result = CryptoJS.AES.decrypt(data, CryptoJS.enc.Utf8.parse(key), cfg).toString(CryptoJS.enc.Utf8);
      }
      _javaCache[cacheKey] = result;
      return result;
    } catch(e) { return ''; }
  },
  aesDecodeBytes: function(data, key, iv) {
    try {
      if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto.aesDecryptFromBase64) {
        return iv ? __nativeCrypto.aesDecryptFromBase64(data, key, iv) : __nativeCrypto.aesDecryptFromBase64ECB(data, key);
      }
      return _strToU8(java.aesDecode(data, key, iv));
    } catch(e) { return new Uint8Array(0); }
  },
  aesDecodeBatch: function(dataArray, key, iv) {
    if (!Array.isArray(dataArray) || dataArray.length === 0) return [];
    try {
      if (typeof __nativeCrypto !== 'undefined') {
        if (iv && __nativeCrypto.aesDecryptFromBase64Batch) {
          return __nativeCrypto.aesDecryptFromBase64Batch(dataArray, key, iv).map(function(r) { return r === null ? '' : r; });
        }
        if (!iv && __nativeCrypto.aesDecryptFromBase64ECBBatch) {
          return __nativeCrypto.aesDecryptFromBase64ECBBatch(dataArray, key).map(function(r) { return r === null ? '' : r; });
        }
      }
      return dataArray.map(function(data) { return java.aesDecode(data, key, iv); });
    } catch(e) { return dataArray.map(function() { return ''; }); }
  },
  md5Encode: function(str) {
    if (typeof __nativeCrypto !== 'undefined') return __nativeCrypto.md5(str);
    return '';
  },
  sha1Encode: function(str) {
    if (typeof __nativeCrypto !== 'undefined') return __nativeCrypto.sha1(str);
    return '';
  },
  sha256Encode: function(str) {
    if (typeof __nativeCrypto !== 'undefined') return __nativeCrypto.sha256(str);
    return '';
  },
  hmacSHA256: function(data, key) {
    if (typeof __nativeCrypto !== 'undefined') return __nativeCrypto.hmacSHA256(data, key);
    return '';
  },
  md5Encode16: function(str) {
    var full = java.md5Encode(str);
    return full.length >= 32 ? full.substring(8, 24) : '';
  },
  digestHex: function(data, algorithm) {
    var algo = (algorithm || '').toLowerCase();
    if (algo.indexOf('md5') >= 0) return java.md5Encode(data);
    if (algo.indexOf('sha-1') >= 0 || algo.indexOf('sha1') >= 0) return java.sha1Encode(data);
    if (algo.indexOf('sha-256') >= 0 || algo.indexOf('sha256') >= 0) return java.sha256Encode(data);
    return '';
  },
  digestBase64Str: function(data, algorithm) {
    var hex = java.digestHex(data, algorithm);
    if (!hex) return '';
    try { return java.base64Encode(java.hexDecodeToString(hex)); } catch(e) { return ''; }
  },
  HMacHex: function(data, algorithm, key) {
    var algo = (algorithm || '').toLowerCase();
    if (algo.indexOf('sha256') >= 0 || algo.indexOf('hmacsha256') >= 0) return java.hmacSHA256(data, key);
    return '';
  },
  HMacBase64Str: function(data, algorithm, key) {
    var hex = java.HMacHex(data, algorithm, key);
    if (!hex) return '';
    try { return java.base64Encode(java.hexDecodeToString(hex)); } catch(e) { return ''; }
  },
  HMacBase64: function(data, algorithm, key) { return java.HMacBase64Str(data, algorithm, key); },

  // ===== Base64（路由到 __nativeBase64）=====
  base64Encode: function(str, flags) {
    try { return btoa(unescape(encodeURIComponent(str))); } catch(e) { return ''; }
  },
  base64Decode: function(str, arg2) {
    try { return decodeURIComponent(escape(atob(str))); } catch(e) { return ''; }
  },
  base64DecodeToByteArray: function(str) {
    var decoded = java.base64Decode(str);
    return decoded ? java.strToBytes(decoded) : [];
  },
  hexDecodeToByteArray: function(hex) {
    var s = java.hexDecodeToString(hex);
    return s ? java.strToBytes(s) : [];
  },

  // ===== HTML 解析（路由到 __nativeHtml）=====
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
    selectFirst: function(html, selector) {
      var result = _JsoupLite.selectFirst(html, selector);
      return result ? result.replace(/<[^>]+>/g, '').trim() : '';
    },
    getAttr: function(html, selector, attr) { return _JsoupLite.getAttr(html, selector, attr); },
    clean: function(html) {
      if (!html) return '';
      return html.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '')
                 .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '')
                 .replace(/<[^>]+>/g, '')
                 .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
                 .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
                 .replace(/&quot;/g, '"').trim();
    },
  },

  // ===== 正则操作 =====
  regex: {
    match: function(str, pattern) { try { var m = str.match(new RegExp(pattern)); return m ? m[0] : ''; } catch(e) { return ''; } },
    matchAll: function(str, pattern) { try { var r = []; var re = new RegExp(pattern, 'g'); var m; while(m = re.exec(str)) r.push(m[0]); return r; } catch(e) { return []; } },
    replace: function(str, pattern, replacement) { try { return str.replace(new RegExp(pattern, 'g'), replacement); } catch(e) { return str; } },
    test: function(str, pattern) { try { return new RegExp(pattern).test(str); } catch(e) { return false; } },
  },

  // ===== 时间/编码工具 =====
  timeFormat: function(timestamp, format) {
    var d = new Date(timestamp);
    if (!format) return d.toLocaleString();
    return format.replace(/yyyy/g, d.getFullYear())
      .replace(/MM/g, (d.getMonth() + 1).toString().padStart(2, '0'))
      .replace(/dd/g, d.getDate().toString().padStart(2, '0'))
      .replace(/HH/g, d.getHours().toString().padStart(2, '0'))
      .replace(/mm/g, d.getMinutes().toString().padStart(2, '0'))
      .replace(/ss/g, d.getSeconds().toString().padStart(2, '0'));
  },
  timeFormatUTC: function(timestamp, format, offset) {
    var d = new Date(timestamp);
    if (offset) d = new Date(d.getTime() + offset * 3600000);
    return format.replace(/yyyy/g, d.getUTCFullYear())
      .replace(/MM/g, (d.getUTCMonth() + 1).toString().padStart(2, '0'))
      .replace(/dd/g, d.getUTCDate().toString().padStart(2, '0'))
      .replace(/HH/g, d.getUTCHours().toString().padStart(2, '0'))
      .replace(/mm/g, d.getUTCMinutes().toString().padStart(2, '0'))
      .replace(/ss/g, d.getUTCSeconds().toString().padStart(2, '0'));
  },
  getTime: function() { return Date.now(); },
  encodeURI: function(str, enc) { return encodeURIComponent(str); },
  hexEncodeToString: function(str) {
    var hex = '';
    for (var i = 0; i < str.length; i++) hex += str.charCodeAt(i).toString(16).padStart(2, '0');
    return hex;
  },
  hexDecodeToString: function(hex) {
    var str = '';
    for (var i = 0; i < hex.length; i += 2) str += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
    return str;
  },

  // ===== Cookie/WebView/浏览器 =====
  getCookie: function(tag, key) {
    var cacheKey = 'cookie:' + tag;
    if (_javaCache[cacheKey] === undefined) return '';
    var cookieStr = _javaCache[cacheKey];
    if (!key) return cookieStr;
    var match = cookieStr.match(new RegExp('(?:^|;\\s*)' + key + '=([^;]+)'));
    return match ? match[1] : '';
  },
  webview: { eval: function(url, js) { var k = 'webview:' + url + ':' + (js || '').length; return _javaCache[k] !== undefined ? _javaCache[k] : ''; } },
  webView: function(html, url, js, cacheFirst) {
    var k = 'webview:' + (url || '') + ':' + (html || '').length;
    return _javaCache[k] !== undefined ? _javaCache[k] : '';
  },
  webViewGetSource: function(html, url, js, sourceRegex, cacheFirst, delayTime) { var k = 'webview_src:' + (url || '') + ':' + (sourceRegex || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  webViewGetOverrideUrl: function(html, url, js, overrideUrlRegex, cacheFirst, delayTime) { var k = 'webview_override:' + (url || '') + ':' + (overrideUrlRegex || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  startBrowser: function(url, title, html) {},
  startBrowserAwait: function(url, title, refetchAfterSuccess, html) { var k = 'browser:' + url; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  getVerificationCode: function(imageUrl) { var k = 'captcha:' + imageUrl; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  openVideoPlayer: function(url, title, isFloat) {},

  // ===== 缓存管理 =====
  cache: { get: function(key) { return _javaCache[key] || ''; }, put: function(key, value) { _javaCache[key] = value; }, delete: function(key) { delete _javaCache[key]; } },

  // ===== 日志 =====
  log: function(msg) { console.log('[JavaBridge] ' + msg); },

  // ===== 文本处理 =====
  htmlFormat: function(str) {
    if (!str) return '';
    return str.replace(/<p[^>]*>/gi, '\n').replace(/<br[^>]*\/?>/gi, '\n')
      .replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'").replace(/\n{3,}/g, '\n\n').trim();
  },
  t2s: function(text) { var k = 't2s:' + text; if (_javaCache[k] !== undefined) return _javaCache[k]; return text; },
  s2t: function(text) { var k = 's2t:' + text; if (_javaCache[k] !== undefined) return _javaCache[k]; return text; },
  toNumChapter: function(s) {
    if (!s) return '';
    var m = s.match(/(\d+)/); if (m) return m[1];
    var numMap = {'零':0,'一':1,'二':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9,'十':10,'百':100,'千':1000,'万':10000};
    var result = 0, current = 0;
    for (var i = 0; i < s.length; i++) {
      var ch = s[i]; if (numMap[ch] === undefined) continue;
      var val = numMap[ch];
      if (val >= 10) { current = current === 0 ? val : current * val; if (val >= 10000) { result = (result + current) * val; current = 0; } else if (val >= 1000) { result += current; current = 0; } }
      else current = val;
    }
    return String(result + current);
  },

  // ===== 工具方法 =====
  toast: function(msg) { console.log('[Toast] ' + msg); },
  longToast: function(msg) { console.log('[LongToast] ' + msg); },
  getWebViewUA: function() { var k = 'webview_ua'; return _javaCache[k] !== undefined ? _javaCache[k] : 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'; },
  randomUUID: function() { return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) { var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16); }); },
  androidId: function() { var k = 'android_id'; return _javaCache[k] !== undefined ? _javaCache[k] : java.randomUUID().replace(/-/g, '').substring(0, 16); },
  logType: function(any) { console.log('[logType] ' + typeof any + ': ' + (any === null ? 'null' : String(any).substring(0, 100))); },
  toURL: function(urlStr, base) {
    try { return new URL(urlStr, base); } catch(e) { return { href: urlStr, toString: function() { return urlStr; } }; }
  },

  // ===== 字节转换 =====
  strToBytes: function(str, charset) {
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      // 检测 UTF-16 代理对（与 _strToU8 保持一致）
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
          var code = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
          bytes.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
          i++;
          continue;
        }
      }
      if (c < 128) bytes.push(c);
      else if (c < 2048) bytes.push(192 | (c >> 6), 128 | (c & 63));
      else bytes.push(224 | (c >> 12), 128 | ((c >> 6) & 0x3F), 128 | (c & 0x3F));
    }
    return bytes;
  },
  bytesToStr: function(bytes, charset) {
    if (!bytes || !bytes.length) return '';
    var str = ''; for (var i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i] & 0xFF);
    try { return decodeURIComponent(escape(str)); } catch(e) { return str; }
  },

  // ===== 文件操作（缓存桥接）=====
  cacheFile: function(url, saveTime) { var k = 'cache_file:' + url; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  downloadFile: function(urlOrContent, url) { var u = url === undefined ? urlOrContent : url; var k = 'download_file:' + u; return _javaCache[k] !== undefined ? _javaCache[k] : '/tmp/' + java.md5Encode(u).substring(0, 16); },
  getFile: function(path) { return { path: path, exists: function() { return false; }, readText: function() { return ''; } }; },
  importScript: function(path) { var k = 'file_importScript:' + path; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  readFile: function(path) { var k = 'file_readFile:' + path; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  readTxtFile: function(path, charset) { var k = 'file_readTxtFile:' + path; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  deleteFile: function(path) { var k = 'file_deleteFile:' + path; return _javaCache[k] !== undefined ? _javaCache[k] === 'true' : false; },
  writeFile: function(path, content) { var k = 'file_writeFile:' + path; return _javaCache[k] !== undefined ? _javaCache[k] === 'true' : false; },
  unzipFile: function(path, password) { var k = 'archive_unzipFile:' + path + '::' + (password || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  un7zFile: function(path, password) { var k = 'archive_un7zFile:' + path + '::' + (password || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  unrarFile: function(path, password) { var k = 'archive_unrarFile:' + path + '::' + (password || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  unArchiveFile: function(path, password) { var k = 'archive_unArchiveFile:' + path + '::' + (password || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  getTxtInFolder: function(path) { var k = 'file_getTxtInFolder:' + path; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  getZipStringContent: function(url, path, charset, password) { var k = 'archive_getZipStringContent:' + url + ':' + (path || '') + ':' + (password || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  getRarStringContent: function(url, path, charset, password) { var k = 'archive_getRarStringContent:' + url + ':' + (path || '') + ':' + (password || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  get7zStringContent: function(url, path, charset, password) { var k = 'archive_get7zStringContent:' + url + ':' + (path || '') + ':' + (password || ''); return _javaCache[k] !== undefined ? _javaCache[k] : ''; },
  getZipByteArrayContent: function(url, path, password) { return java.getZipStringContent(url, path, null, password); },
  getRarByteArrayContent: function(url, path, password) { return java.getRarStringContent(url, path, null, password); },
  get7zByteArrayContent: function(url, path, password) { return java.get7zStringContent(url, path, null, password); },
  openUrl: function(url, mimeType) {},

  // ===== 配置/书源 =====
  getReadBookConfig: function() { var k = 'read_book_config'; return _javaCache[k] !== undefined ? _javaCache[k] : '{}'; },
  getReadBookConfigMap: function() { try { return JSON.parse(java.getReadBookConfig()); } catch(_) { return {}; } },
  getThemeMode: function() { var k = 'theme_mode'; return _javaCache[k] !== undefined ? _javaCache[k] : 'light'; },
  getThemeConfig: function() { var k = 'theme_config'; return _javaCache[k] !== undefined ? _javaCache[k] : '{}'; },
  getThemeConfigMap: function() { try { return JSON.parse(java.getThemeConfig()); } catch(_) { return {}; } },
  getSource: function() { var k = 'source'; if (_javaCache[k] !== undefined) { try { return JSON.parse(_javaCache[k]); } catch(_) {} } return {}; },
  getTag: function() { var k = 'tag'; return _javaCache[k] !== undefined ? _javaCache[k] : ''; },

  // ===== AES 参数版（对齐 legado JsEncodeUtils）=====
  aesEncodeToString: function(data, key, transformation, iv) { return java.aesEncode(data, key, iv); },
  aesEncodeToBase64String: function(data, key, transformation, iv) { var r = java.aesEncode(data, key, iv); return r ? java.base64Encode(r) : ''; },
  aesDecodeToString: function(str, key, transformation, iv) { return java.aesDecode(str, key, iv); },
  aesBase64DecodeToString: function(str, key, transformation, iv) { var d = java.base64Decode(str); return d ? java.aesDecode(d, key, iv) : ''; },
  createSymmetricCrypto: function(transformation, key, iv) {
    var keyStr = typeof key === 'string' ? key : String(key || '');
    var ivStr = typeof iv === 'string' ? iv : String(iv || '');
    return {
      encryptStr: function(data) { return java.aesEncode(data, keyStr, ivStr); },
      decryptStr: function(data) { return java.aesDecode(data, keyStr, ivStr); },
      encryptBase64: function(data) { return java.aesEncodeToBase64String(data, keyStr, '', ivStr); },
      decryptBase64: function(data) { return java.aesBase64DecodeToString(data, keyStr, '', ivStr); },
      encryptHex: function(data) { var b = java.aesEncodeToBase64String(data, keyStr, '', ivStr); return b ? java.hexDecodeToString(b) : ''; },
      decryptHex: function(hex) { return java.aesDecode(hex, keyStr, ivStr); },
      encrypt: function(data) { return java.aesEncode(data, keyStr, ivStr); },
      decrypt: function(data) { return java.aesDecode(data, keyStr, ivStr); },
      setIv: function(newIv) { ivStr = String(newIv || ''); return this; },
    };
  },
  desEncodeToString: function(data, key, transformation, iv) { return java.aesEncode(data, key, iv); },
  desDecodeToString: function(data, key, transformation, iv) { return java.aesDecode(data, key, iv); },
  desEncodeToBase64String: function(data, key, transformation, iv) { return java.aesEncodeToBase64String(data, key, '', iv); },
  desBase64DecodeToString: function(data, key, transformation, iv) { return java.aesBase64DecodeToString(data, key, '', iv); },
  tripleDESEncodeBase64Str: function(data, key, mode, padding, iv) { return java.aesEncodeToBase64String(data, key, '', iv); },
  tripleDESDecodeArgsBase64Str: function(data, key, mode, padding, iv) { return java.aesBase64DecodeToString(data, key, '', iv); },
  tripleDESDecodeStr: function(data, key, mode, padding, iv) { return java.aesDecode(data, key, iv); },
  tripleDESEncodeArgsBase64Str: function(data, key, mode, padding, iv) { return java.aesEncodeToBase64String(data, key, '', iv); },
  createAsymmetricCrypto: function(transformation) { return { encrypt: function(d) { return ''; }, decrypt: function(d) { return ''; }, encryptStr: function(d) { return ''; }, decryptStr: function(d) { return ''; }, encryptBase64: function(d) { return ''; }, decryptBase64: function(d) { return ''; } }; },
  createSign: function(algorithm) { return { sign: function(d) { return ''; }, verify: function(d, s) { return false; }, signBase64: function(d) { return ''; }, verifyBase64: function(d, s) { return false; } }; },
  aesEncodeArgsBase64Str: function(data, key, mode, padding, iv) { return java.aesEncodeToBase64String(data, key, '', iv); },
  aesDecodeArgsBase64Str: function(data, key, mode, padding, iv) { return java.aesBase64DecodeToString(data, key, '', iv); },
  aesDecodeToByteArray: function(str, key, transformation, iv) { var r = java.aesDecode(str, key, iv); return r ? java.strToBytes(r) : []; },
  aesEncodeToByteArray: function(data, key, transformation, iv) { var r = java.aesEncode(data, key, iv); return r ? java.strToBytes(r) : []; },
  aesBase64DecodeToByteArray: function(str, key, transformation, iv) { var r = java.aesBase64DecodeToString(str, key, transformation, iv); return r ? java.strToBytes(r) : []; },
  aesEncodeToBase64ByteArray: function(data, key, transformation, iv) { var r = java.aesEncodeToBase64String(data, key, transformation, iv); return r ? java.strToBytes(r) : []; },

  // ===== 元素操作 =====
  getElements: function(html, rule) {
    var content, r;
    if (rule === undefined || rule === null) { r = html; content = (typeof result !== 'undefined') ? result : ''; }
    else { content = html; r = rule; }
    if (!r) return [];
    try { return _JsoupLite.selectAll(content, r); } catch(e) { return []; }
  },
  getElement: function(html, rule) {
    var content, r;
    if (rule === undefined || rule === null) { r = html; content = (typeof result !== 'undefined') ? result : ''; }
    else { content = html; r = rule; }
    if (!r) return '';
    try { return _JsoupLite.selectFirst(content, r); } catch(e) { return ''; }
  },
  getStringList: function(html, rule) {
    var results = java.getElements(html, rule);
    return Array.isArray(results) ? results : [];
  },
};

// ===== 将 java 桥接方法暴露为全局函数（兼容 Legado 书源裸调用）=====
// 原版 Legado 通过 @JavascriptInterface 将 JsExtensions 方法同时绑定为 java.xxx() 与顶层 xxx()，
// jsHelp.md 中文件操作类（downloadFile/readTxtFile/deleteFile 等）官方即采用裸调用写法。
// MR 用纯 JS polyfill 模拟，需手动将 java 上的成员别名到 globalThis；不覆盖已存在的全局。
(function() {
  for (var k in java) {
    if (k.charAt(0) === '_') continue;            // 跳过 _buildResponse / _parseUrlOptions 等内部辅助
    if (globalThis[k] === undefined) {            // 不覆盖原生全局（如 encodeURI）与已绑定的 polyfill
      globalThis[k] = java[k];
    }
  }
})();

// ===== _jsLog 辅助 =====
function _jsLog(msg, level) {
  if (level === 'error') console.error(msg);
  else if (level === 'warn') console.warn(msg);
  else console.log(msg);
}

// ===== Dart 侧动态操作辅助函数 =====
// 以下函数替代 js_engine.dart 中的内联 JS 拼接，
// Dart 侧通过 evaluate('__setCache(key, value)') 调用。

// 设置 _javaCache 键值对（替代 evaluate('_javaCache[key] = value;')）
function __setCache(key, value) {
  _javaCache[key] = value;
}

// 获取 _javaCache 值（替代 evaluate('_javaCache[key]')）
function __getCache(key) {
  return _javaCache[key];
}

// 清空 _javaCache（替代 evaluate('_javaCache = {};')）
function __clearCache() {
  _javaCache = {};
}

// 求值变量表达式（替代 evaluate('(function(){ try { var __v = expr; ... })()')）
function __evalVar(expr) {
  try {
    var __v = eval(expr);
    return (typeof __v === 'string' && __v.length > 50) ? __v : '';
  } catch (e) {
    return '';
  }
}

// 正则替换（替代内联 text.replace(new RegExp(pattern, 'g'), replacement)）
function __regexReplace(text, pattern, replacement) {
  try {
    return String(text).replace(new RegExp(pattern, 'g'), replacement);
  } catch (e) {
    return null;
  }
}

// CSS 选择器查询第一个（替代内联 java.jsoup.selectFirst(html, selector)）
function __cssSelect(html, selector) {
  try {
    return java.jsoup.selectFirst(html, selector);
  } catch (e) {
    return null;
  }
}

// JSON 路径查询（替代内联 JSON.parse + 逐级访问）
function __jsonPath(jsonStr, path) {
  try {
    var data = JSON.parse(jsonStr);
    var p = path.replace(/^\$\./, '');
    var parts = p.split('.');
    var result = data;
    for (var i = 0; i < parts.length; i++) {
      if (result == null) return null;
      result = result[parts[i]];
    }
    return JSON.stringify(result);
  } catch (e) {
    return null;
  }
}

// 批量 URL 求值（替代内联批量 URL 提取脚本）
// varCodeArr: ['var key = "value";', ...]
// exprArr: ['result', 'java.ajax(...)', ...]
function __batchEvalUrls(varCodeArr, exprArr) {
  var __results = [];
  for (var i = 0; i < varCodeArr.length; i++) {
    try { eval(varCodeArr[i]); } catch (e) {}
  }
  for (var j = 0; j < exprArr.length; j++) {
    try {
      var __u = String(eval(exprArr[j]));
      if (__u.indexOf('http') === 0) __results.push(__u);
    } catch (e) {}
  }
  return JSON.stringify(__results);
}
