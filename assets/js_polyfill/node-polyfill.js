// ===== Node.js 核心模块模拟（QuickJS polyfill）=====
// 提取自 js_engine.dart 内联代码，提供 process/Buffer/URL/console/btoa/atob 等

var process = {
  env: {},
  argv: [],
  version: 'v18.17.0',
  versions: { node: '18.17.0', v8: '10.2.154.4' },
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

// ===== URL/URLSearchParams 完整实现 =====
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
  var protoMatch = input.match(/^(https?:)\/\/ /i);
  this.protocol = protoMatch ? protoMatch[1] : '';
  var hostMatch = input.match(/^https?:\/\/ ([^\/?#]+)/i);
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
  this.getAll = function(name) {
    var results = [];
    for (var i = 0; i < this._params.length; i++) {
      if (this._params[i][0] === name) results.push(this._params[i][1]);
    }
    return results;
  };
  this.set = function(name, value) {
    var found = false;
    for (var i = 0; i < this._params.length; i++) {
      if (this._params[i][0] === name) {
        if (!found) { this._params[i][1] = value; found = true; }
        else { this._params.splice(i, 1); i--; }
      }
    }
    if (!found) this._params.push([name, value]);
  };
  this.has = function(name) {
    for (var i = 0; i < this._params.length; i++) {
      if (this._params[i][0] === name) return true;
    }
    return false;
  };
  this.delete = function(name) {
    for (var i = 0; i < this._params.length; i++) {
      if (this._params[i][0] === name) { this._params.splice(i, 1); i--; }
    }
  };
  this.append = function(name, value) { this._params.push([name, value]); };
  this.toString = function() {
    return this._params.map(function(p) {
      return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
    }).join('&');
  };
  this.keys = function() { return this._params.map(function(p) { return p[0]; }); };
  this.values = function() { return this._params.map(function(p) { return p[1]; }); };
  this.entries = function() { return this._params.map(function(p) { return [p[0], p[1]]; }); };
  this.forEach = function(fn) { for (var i = 0; i < this._params.length; i++) fn(this._params[i][1], this._params[i][0]); };
}

function EventEmitter() {
  this._events = {};
}
EventEmitter.prototype.on = function(event, handler) {
  if (!this._events[event]) this._events[event] = [];
  this._events[event].push(handler);
  return this;
};
EventEmitter.prototype.emit = function(event) {
  var args = Array.from(arguments).slice(1);
  (this._events[event] || []).forEach(function(handler) { handler.apply(null, args); });
  return this;
};
EventEmitter.prototype.off = function(event, handler) {
  if (this._events[event]) {
    this._events[event] = this._events[event].filter(function(h) { return h !== handler; });
  }
  return this;
};
EventEmitter.prototype.once = function(event, handler) {
  var self = this;
  var wrapper = function() {
    handler.apply(null, arguments);
    self.off(event, wrapper);
  };
  return this.on(event, wrapper);
};

var _modules = {};
var _moduleCache = {};
function require(name) {
  if (_moduleCache[name]) return _moduleCache[name];
  if (_modules[name]) {
    var module = { exports: {} };
    _modules[name](module, module.exports, require);
    _moduleCache[name] = module.exports;
    return _moduleCache[name];
  }
  switch(name) {
    case 'http': return { get: function(url, cb) {}, request: function() {} };
    case 'https': return { get: function(url, cb) {}, request: function() {} };
    case 'fs': return { readFileSync: function(path) { return ''; }, writeFileSync: function(path, data) {} };
    case 'path': return { join: function() { return Array.from(arguments).join('/'); }, resolve: function() { return '/'; }, basename: function(p) { return p.split('/').pop(); }, dirname: function(p) { return p.split('/').slice(0, -1).join('/'); } };
    case 'crypto': return { createHash: function(algo) { return { update: function(d) { return this; }, digest: function(enc) { return ''; } }; }, randomBytes: function(n) { return []; } };
    case 'url': return { parse: function(u) { return new URL(u); }, format: function(u) { return u.href || u; } };
    case 'querystring': return { parse: function(q) { var r = {}; q.split('&').forEach(function(p) { var kv = p.split('='); r[kv[0]] = kv[1]; }); return r; }, stringify: function(o) { return Object.keys(o).map(function(k) { return k + '=' + o[k]; }).join('&'); } };
    case 'events': return { EventEmitter: EventEmitter };
    case 'stream': return { Readable: function() {}, Writable: function() {}, Transform: function() {} };
    case 'util': return { promisify: function(fn) { return fn; }, inherits: function() {}, inspect: function(obj) { return JSON.stringify(obj); } };
    case 'cheerio': return { load: function(html) { return function(sel) { return { text: function() { return ''; }, attr: function(a) { return ''; }, find: function(s) { return this; }, each: function(fn) {} }; }; } };
    default: throw new Error('Module not found: ' + name);
  }
}

// ===== fetch() 全局函数 =====
// 兼容 legado 书源：fetch(url) 直接返回 HTML 字符串（从 _javaCache 取预缓存结果）
function fetch(input, init) {
  var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
  init = init || {};
  var method = (init.method || 'GET').toUpperCase();
  var body = init.body;
  var headers = init.headers || {};

  if (body && typeof body === 'object' && !(body instanceof ArrayBuffer)) {
    body = JSON.stringify(body);
  }
  if (typeof headers === 'string') {
    try { headers = JSON.parse(headers); } catch (e) { headers = {}; }
  }

  var realUrl = url;
  if (url && typeof url === 'string' && url.indexOf(',{') >= 0) {
    try {
      var idx = url.indexOf(',{');
      realUrl = url.substring(0, idx).trim();
      var urlOpt = JSON.parse(url.substring(idx + 1).trim());
      if (!init.method && urlOpt.method) method = String(urlOpt.method).toUpperCase();
      if (body == null && urlOpt.body != null) {
        body = typeof urlOpt.body === 'object' ? JSON.stringify(urlOpt.body) : String(urlOpt.body);
      }
      if (urlOpt.headers) {
        var mergedH = {};
        for (var k in urlOpt.headers) { mergedH[k] = urlOpt.headers[k]; }
        for (var k in headers) { mergedH[k] = headers[k]; }
        headers = mergedH;
      }
    } catch (e) { realUrl = url; }
  }

  var fullUrl = realUrl;
  if (realUrl && !realUrl.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
    fullUrl = baseUrl.replace(/\/+$/, '') + '/' + realUrl.replace(/^\/+/, '');
  }

  var cacheKey = method === 'POST' ? 'http_post:' + fullUrl : 'http_get:' + fullUrl;
  var cached = _javaCache[cacheKey];
  if (cached === undefined && fullUrl !== realUrl) {
    var origKey = method === 'POST' ? 'http_post:' + realUrl : 'http_get:' + realUrl;
    cached = _javaCache[origKey];
  }
  if (cached !== undefined) {
    return (typeof cached === 'object' && cached !== null && cached.body) ? cached.body : String(cached);
  }
  return '';
}

// ===== XMLHttpRequest 简易实现 =====
function XMLHttpRequest() {
  this.readyState = 0;
  this.status = 0;
  this.statusText = '';
  this.responseText = '';
  this.responseXML = null;
  this.response = '';
  this.responseType = '';
  this.timeout = 0;
  this.withCredentials = false;
  this._method = 'GET';
  this._url = '';
  this._headers = {};
  this._async = true;
  this.onreadystatechange = null;
  this.onload = null;
  this.onerror = null;
  this.onabort = null;
  this.ontimeout = null;
  this.onprogress = null;
}
XMLHttpRequest.prototype.open = function(method, url, async) {
  this._method = method.toUpperCase();
  this._url = url;
  this._async = async !== false;
  this.readyState = 1;
};
XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
  this._headers[name] = value;
};
XMLHttpRequest.prototype.send = function(body) {
  var self = this;
  var url = this._url;
  if (url && !url.startsWith('http') && typeof baseUrl !== 'undefined' && baseUrl) {
    url = baseUrl.replace(/\/+$/, '') + '/' + url.replace(/^\/+/, '');
  }
  var cacheKey = this._method === 'POST' ? 'http_post:' + url : 'http_get:' + url;
  var cachedText = _javaCache[cacheKey] || '';
  if (!cachedText && url !== this._url) {
    var origKey = this._method === 'POST' ? 'http_post:' + this._url : 'http_get:' + this._url;
    cachedText = _javaCache[origKey] || '';
  }
  this.readyState = 2;
  if (this.onreadystatechange) this.onreadystatechange();
  this.readyState = 3;
  if (this.onreadystatechange) this.onreadystatechange();
  this.status = cachedText ? 200 : 0;
  this.statusText = cachedText ? 'OK' : 'No cache';
  this.responseText = cachedText;
  this.response = cachedText;
  this.readyState = 4;
  if (this.onreadystatechange) this.onreadystatechange();
  if (cachedText && this.onload) this.onload();
  else if (!cachedText && this.onerror) this.onerror();
};
XMLHttpRequest.prototype.abort = function() {
  this.readyState = 0;
  if (this.onabort) this.onabort();
};
XMLHttpRequest.prototype.getResponseHeader = function(name) { return null; };
XMLHttpRequest.prototype.getAllResponseHeaders = function() { return ''; };

// ===== setTimeout / setInterval =====
if (typeof setTimeout === 'undefined') {
  var _timerId = 0;
  var _timers = {};
  globalThis.setTimeout = function(fn, delay) { var id = ++_timerId; fn(); return id; };
  globalThis.setInterval = function(fn, delay) { var id = ++_timerId; fn(); return id; };
  globalThis.clearTimeout = function(id) { delete _timers[id]; };
  globalThis.clearInterval = function(id) { delete _timers[id]; };
}

// ===== console 增强 =====
var _consoleLogs = [];
var _logSeq = 0;
function _jsLog(msg, level) {
  level = level || 'log';
  _logSeq++;
  _consoleLogs.push({
    seq: _logSeq,
    ts: Date.now(),
    level: level,
    msg: typeof msg === 'string' ? msg : (msg && msg.toString ? msg.toString() : String(msg))
  });
}
globalThis.console = {
  log: function() { _jsLog(Array.from(arguments).join(' '), 'log'); },
  warn: function() { _jsLog(Array.from(arguments).join(' '), 'warn'); },
  error: function() { _jsLog(Array.from(arguments).join(' '), 'error'); },
  info: function() { _jsLog(Array.from(arguments).join(' '), 'info'); },
  debug: function() { _jsLog(Array.from(arguments).join(' '), 'debug'); },
  trace: function() { _jsLog(Array.from(arguments).join(' '), 'trace'); },
  dir: function(obj) { _jsLog(JSON.stringify(obj, null, 2), 'log'); },
  table: function(data) { _jsLog(JSON.stringify(data, null, 2), 'log'); },
  time: function(label) { _consoleLogs._timers = _consoleLogs._timers || {}; _consoleLogs._timers[label] = Date.now(); },
  timeEnd: function(label) {
    _consoleLogs._timers = _consoleLogs._timers || {};
    if (_consoleLogs._timers[label]) {
      var ms = Date.now() - _consoleLogs._timers[label];
      _jsLog(label + ': ' + ms + 'ms', 'info');
      delete _consoleLogs._timers[label];
    }
  },
  count: function(label) {
    _consoleLogs._counts = _consoleLogs._counts || {};
    _consoleLogs._counts[label] = (_consoleLogs._counts[label] || 0) + 1;
    _jsLog(label + ': ' + _consoleLogs._counts[label], 'info');
  },
  assert: function(condition) {
    if (!condition) {
      _jsLog(Array.from(arguments).slice(1).join(' ') || 'Assertion failed', 'error');
    }
  },
  clear: function() { _consoleLogs.length = 0; },
  _getLogs: function() { return _consoleLogs.slice(); },
  _clearLogs: function() { _consoleLogs.length = 0; _logSeq = 0; },
  // 合并获取+清空为一次调用，减少 Dart↔JS 跨 FFI 往返开销
  _getAndClearLogs: function() {
    var logs = _consoleLogs.slice();
    _consoleLogs.length = 0;
    _logSeq = 0;
    return logs;
  },
  _logSeq: function() { return _logSeq; },
};
globalThis._jsLog = _jsLog;

// ===== btoa/atob 全局函数（纯 JS 实现）=====
var _b64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
globalThis.btoa = function(str) {
  var output = '';
  for (var i = 0; i < str.length; i += 3) {
    var byte1 = str.charCodeAt(i);
    var byte2 = i + 1 < str.length ? str.charCodeAt(i + 1) : 0;
    var byte3 = i + 2 < str.length ? str.charCodeAt(i + 2) : 0;
    var enc1 = byte1 >> 2;
    var enc2 = ((byte1 & 3) << 4) | (byte2 >> 4);
    var enc3 = ((byte2 & 15) << 2) | (byte3 >> 6);
    var enc4 = byte3 & 63;
    if (i + 1 >= str.length) { enc3 = enc4 = 64; }
    else if (i + 2 >= str.length) { enc4 = 64; }
    output += _b64Chars.charAt(enc1) + _b64Chars.charAt(enc2) + _b64Chars.charAt(enc3) + _b64Chars.charAt(enc4);
  }
  return output;
};
globalThis.atob = function(str) {
  var output = '';
  for (var i = 0; i < str.length; i += 4) {
    var enc1 = _b64Chars.indexOf(str.charAt(i));
    var enc2 = _b64Chars.indexOf(str.charAt(i + 1));
    var enc3 = _b64Chars.indexOf(str.charAt(i + 2));
    var enc4 = _b64Chars.indexOf(str.charAt(i + 3));
    var chr1 = (enc1 << 2) | (enc2 >> 4);
    var chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
    var chr3 = ((enc3 & 3) << 6) | enc4;
    output += String.fromCharCode(chr1);
    if (enc3 !== 64) output += String.fromCharCode(chr2);
    if (enc4 !== 64) output += String.fromCharCode(chr3);
  }
  return output;
};

// ===== LZString 兼容层 =====
if (typeof LZString === 'undefined') {
  var _lzKeyStr = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
  var _lzBase64ToStr = function(input) {
    var output = "";
    var ol = 0;
    var chr1, chr2, chr3;
    var enc1, enc2, enc3, enc4;
    var i = 0;
    input = input.replace(/[^A-Za-z0-9\+\/\=]/g, "");
    while (i < input.length) {
      enc1 = _lzKeyStr.indexOf(input.charAt(i++));
      enc2 = _lzKeyStr.indexOf(input.charAt(i++));
      enc3 = _lzKeyStr.indexOf(input.charAt(i++));
      enc4 = _lzKeyStr.indexOf(input.charAt(i++));
      chr1 = (enc1 << 2) | (enc2 >> 4);
      chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
      chr3 = ((enc3 & 3) << 6) | enc4;
      if (ol % 2 === 0) {
        output += String.fromCharCode((252 >> 2) | (chr1 & 3));
        output += String.fromCharCode((chr1 & 240) >> 4 | (chr2 & 15) << 4);
        output += String.fromCharCode((chr2 & 192) >> 6 | (chr3 & 63));
      } else {
        output += String.fromCharCode((252 >> 2) | (chr1 & 3) | (chr2 & 15) << 4);
        output += String.fromCharCode((chr1 & 192) >> 6 | (chr2 & 63));
      }
      ol += 3;
    }
    return output;
  };
  var _lzDecompress = function(compressed) {
    if (compressed == null) return "";
    if (compressed == "") return null;
    var dictionary = [];
    var enlargeIn = 4;
    var dictSize = 4;
    var numBits = 3;
    var entry = "";
    var result = "";
    var i, w, bits, resb, maxpower, power, c, data = { val: compressed.charAt(0), position: 32768, index: 1 };
    for (i = 0; i < 3; i += 1) dictionary[i] = i;
    bits = 0;
    maxpower = Math.pow(2, 2);
    power = 1;
    while (power != maxpower) {
      resb = data.val & data.position;
      data.position >>= 1;
      if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
      bits |= (resb > 0 ? 1 : 0) * power;
      power <<= 1;
    }
    switch (bits) {
      case 0:
        bits = 0; maxpower = Math.pow(2, 8); power = 1;
        while (power != maxpower) {
          resb = data.val & data.position; data.position >>= 1;
          if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
          bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
        }
        c = String.fromCharCode(bits);
        break;
      case 1:
        bits = 0; maxpower = Math.pow(2, 16); power = 1;
        while (power != maxpower) {
          resb = data.val & data.position; data.position >>= 1;
          if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
          bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
        }
        c = String.fromCharCode(bits);
        break;
      case 2: return "";
    }
    dictionary[3] = c; dictSize = 3; entry = c; result += c;
    while (true) {
      if (data.index > compressed.length) return "";
      bits = 0; maxpower = Math.pow(2, numBits); power = 1;
      while (power != maxpower) {
        resb = data.val & data.position; data.position >>= 1;
        if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
        bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
      }
      switch (c = bits) {
        case 0:
          bits = 0; maxpower = Math.pow(2, 8); power = 1;
          while (power != maxpower) {
            resb = data.val & data.position; data.position >>= 1;
            if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
            bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
          }
          dictionary[dictSize++] = String.fromCharCode(bits);
          c = dictSize - 1; enlargeIn--; break;
        case 1:
          bits = 0; maxpower = Math.pow(2, 16); power = 1;
          while (power != maxpower) {
            resb = data.val & data.position; data.position >>= 1;
            if (data.position == 0) { data.position = 32768; data.val = compressed.charAt(data.index++); }
            bits |= (resb > 0 ? 1 : 0) * power; power <<= 1;
          }
          dictionary[dictSize++] = String.fromCharCode(bits);
          c = dictSize - 1; enlargeIn--; break;
        case 2: return result;
      }
      if (enlargeIn == 0) { enlargeIn = Math.pow(2, numBits); numBits++; }
      if (dictionary[c]) { w = dictionary[c]; }
      else {
        if (c === dictSize) { w = entry + entry.charAt(0); }
        else { return null; }
      }
      result += w;
      dictionary[dictSize++] = entry + w.charAt(0);
      entry = w;
      enlargeIn--;
      if (enlargeIn == 0) { enlargeIn = Math.pow(2, numBits); numBits++; }
    }
  };
  globalThis.LZString = {
    decompressFromBase64: function(str) { return _lzDecompress(_lzBase64ToStr(str)); },
    decompress: function(str) {
      if (str == null) return "";
      if (str == "") return null;
      return _lzDecompress(str);
    },
    compressToBase64: function(str) { throw new Error('LZString.compressToBase64 not supported'); },
    compress: function(str) { throw new Error('LZString.compress not supported'); },
  };
}
