/// native-proxy: Rust 原生桥接模块
///
/// 模块化架构，每个功能分组对应一个 Rust 源文件：
///
///   Rust 文件            →  JS 分组          →  API 路由前缀
///   src/jsoup.rs         →  jsoup.*          →  /api/jsoup/*
///   src/crypto.rs        →  crypto.*         →  /api/crypto/*
///   src/url_parser.rs    →  url.*            →  /api/url/*
///   src/http.rs          →  http.*           →  (直接使用)
///   src/js.rs            →  js.*             →  /api/js/*
///
/// 添加新模块只需三步：
///   1. 创建 src/[模块名].rs，用 #[napi] 标注导出函数
///   2. 在 src/lib.rs 添加 mod [模块名];
///   3. 在本文件添加对应的分组和 JS 降级实现
///
/// 命名规则：
///   Rust: snake_case (jsoup_select) → JS: camelCase (jsoupSelect)
///   napi-rs 自动转换命名风格

let native = null;

try {
  native = require('./native-proxy.node');
} catch (e) {
  console.warn('[native-proxy] 原生模块未编译，使用 JS 降级实现');
  console.warn('[native-proxy] 运行 `cd tools/native-proxy && npm run build` 编译');
  native = null;
}

const isNativeAvailable = !!native;

// ============================================================
//  jsoup 模块 - HTML 解析（对应 src/jsoup.rs）
// ============================================================

const jsoup = {
  select: native?.jsoupSelect || function(html, selector) {
    console.warn('[native-proxy] jsoup.select: JS fallback');
    return [];
  },

  selectFirst: native?.jsoupSelectFirst || function(html, selector) {
    console.warn('[native-proxy] jsoup.selectFirst: JS fallback');
    return { text: '', html: '', attr: '', tag: '' };
  },

  getAttr: native?.jsoupGetAttr || function(html, selector, attr) {
    console.warn('[native-proxy] jsoup.getAttr: JS fallback');
    return '';
  },

  clean: native?.jsoupClean || function(html) {
    return html
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  },
};

// ============================================================
//  crypto 模块 - 加密/哈希（对应 src/crypto.rs）
// ============================================================

const crypto = {
  md5: native?.md5 || function(input) {
    console.warn('[native-proxy] crypto.md5: JS fallback');
    return '';
  },

  sha256: native?.sha256 || function(input) {
    console.warn('[native-proxy] crypto.sha256: JS fallback');
    return '';
  },

  base64Encode: native?.base64_encode || function(input) {
    return Buffer.from(input, 'utf-8').toString('base64');
  },

  base64Decode: native?.base64_decode || function(input) {
    return Buffer.from(input, 'base64').toString('utf-8');
  },

  aesCbcEncrypt: native?.aes_cbc_encrypt || function(data, key, iv) {
    console.warn('[native-proxy] crypto.aesCbcEncrypt: JS fallback');
    return '';
  },

  aesCbcDecrypt: native?.aes_cbc_decrypt || function(data, key, iv) {
    console.warn('[native-proxy] crypto.aesCbcDecrypt: JS fallback');
    return '';
  },

  hmacSha256: native?.hmac_sha256 || function(key, message) {
    console.warn('[native-proxy] crypto.hmacSha256: JS fallback');
    return '';
  },
};

// ============================================================
//  url 模块 - URL 解析（对应 src/url_parser.rs）
// ============================================================

const url = {
  parse: native?.parse_url || function(rawUrl) {
    try {
      const u = new URL(rawUrl);
      return {
        href: u.href,
        protocol: u.protocol,
        host: u.host,
        hostname: u.hostname,
        port: u.port,
        pathname: u.pathname,
        search: u.search,
        hash: u.hash,
        origin: u.origin,
      };
    } catch (e) {
      return null;
    }
  },

  resolve: native?.resolve_url || function(base, relative) {
    try {
      return new URL(relative, base).href;
    } catch (e) {
      return '';
    }
  },
};

// ============================================================
//  http 模块 - HTTP 请求（对应 src/http.rs）
// ============================================================

const http = {
  get: native?.http_get || async function(targetUrl, headers) {
    console.warn('[native-proxy] http.get: Node.js fallback');
    const nativeHttp = require('http');
    const nativeHttps = require('https');
    const protocol = targetUrl.startsWith('https') ? nativeHttps : nativeHttp;

    return new Promise((resolve, reject) => {
      protocol.get(targetUrl, { headers: headers || {} }, (res) => {
        let body = '';
        res.on('data', (chunk) => body += chunk);
        res.on('end', () => {
          const respHeaders = {};
          for (const [key, value] of Object.entries(res.headers)) {
            respHeaders[key] = Array.isArray(value) ? value.join(', ') : value;
          }
          resolve({ status: res.statusCode, body, headers: respHeaders });
        });
      }).on('error', reject);
    });
  },

  post: native?.http_post || async function(targetUrl, reqBody, headers) {
    console.warn('[native-proxy] http.post: Node.js fallback');
    const nativeHttp = require('http');
    const nativeHttps = require('https');
    const parsedUrl = new URL(targetUrl);
    const protocol = parsedUrl.protocol === 'https:' ? nativeHttps : nativeHttp;

    return new Promise((resolve, reject) => {
      const options = {
        hostname: parsedUrl.hostname,
        port: parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
        path: parsedUrl.pathname + parsedUrl.search,
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          ...(headers || {}),
          'Content-Length': Buffer.byteLength(reqBody || ''),
        },
      };

      const req = protocol.request(options, (res) => {
        let responseBody = '';
        res.on('data', (chunk) => responseBody += chunk);
        res.on('end', () => {
          const respHeaders = {};
          for (const [key, value] of Object.entries(res.headers)) {
            respHeaders[key] = Array.isArray(value) ? value.join(', ') : value;
          }
          resolve({ status: res.statusCode, body: responseBody, headers: respHeaders });
        });
      });

      req.on('error', reject);
      req.write(reqBody || '');
      req.end();
    });
  },
};

// ============================================================
//  js 模块 - JS 引擎（对应 src/js.rs）
//  QuickJS 解析失败时的降级引擎
// ============================================================

const js = {
  evaluate: native?.js_evaluate || function(code) {
    console.warn('[native-proxy] js.evaluate: JS fallback (eval)');
    try {
      const result = eval(code);
      if (result === undefined) return { success: true, result: 'undefined', value_type: 'undefined' };
      if (result === null) return { success: true, result: 'null', value_type: 'null' };
      if (typeof result === 'object') return { success: true, result: JSON.stringify(result), value_type: 'object' };
      return { success: true, result: String(result), value_type: typeof result };
    } catch (e) {
      return { success: false, result: e.message, value_type: 'error' };
    }
  },

  evaluateWithVars: native?.js_evaluate_with_vars || function(code, variables) {
    console.warn('[native-proxy] js.evaluateWithVars: JS fallback (eval)');
    try {
      for (const [key, value] of Object.entries(variables || {})) {
        global[key] = JSON.parse(value);
      }
      const result = eval(code);
      if (result === undefined) return { success: true, result: 'undefined', value_type: 'undefined' };
      if (result === null) return { success: true, result: 'null', value_type: 'null' };
      if (typeof result === 'object') return { success: true, result: JSON.stringify(result), value_type: 'object' };
      return { success: true, result: String(result), value_type: typeof result };
    } catch (e) {
      return { success: false, result: e.message, value_type: 'error' };
    }
  },

  evaluateWithContext: native?.js_evaluate_with_context || function(code, result, baseUrl, content, bookJson, chapterJson) {
    console.warn('[native-proxy] js.evaluateWithContext: JS fallback (eval)');
    try {
      // 注入变量到全局
      global.result = result ? JSON.parse(result) : result;
      global.baseUrl = baseUrl || '';
      global.content = global.result;
      if (bookJson) global.book = JSON.parse(bookJson);
      if (chapterJson) global.chapter = JSON.parse(chapterJson);

      const evalResult = eval(code);
      if (evalResult === undefined) return { success: true, result: 'undefined', value_type: 'undefined' };
      if (evalResult === null) return { success: true, result: 'null', value_type: 'null' };
      if (typeof evalResult === 'object') return { success: true, result: JSON.stringify(evalResult), value_type: 'object' };
      return { success: true, result: String(evalResult), value_type: typeof evalResult };
    } catch (e) {
      return { success: false, result: e.message, value_type: 'error' };
    }
  },
};

// ============================================================
//  导出
// ============================================================

module.exports = {
  isNativeAvailable,

  // 功能模块（按 Rust 源文件分组）
  jsoup,
  crypto,
  url,
  http,
  js,

  // 兼容旧版平铺导出（不推荐，新代码请用分组方式）
  jsoupSelect: jsoup.select,
  jsoupSelectFirst: jsoup.selectFirst,
  jsoupGetAttr: jsoup.getAttr,
  jsoupClean: jsoup.clean,
  md5: crypto.md5,
  sha256: crypto.sha256,
  base64Encode: crypto.base64Encode,
  base64Decode: crypto.base64Decode,
  aesCbcEncrypt: crypto.aesCbcEncrypt,
  aesCbcDecrypt: crypto.aesCbcDecrypt,
  hmacSha256: crypto.hmacSha256,
  parseUrl: url.parse,
  resolveUrl: url.resolve,
  httpGet: http.get,
  httpPost: http.post,
  jsEvaluate: js.evaluate,
  jsEvaluateWithVars: js.evaluateWithVars,
  jsEvaluateWithContext: js.evaluateWithContext,
};
