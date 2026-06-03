const http = require('http');
const https = require('https');

// 加载 Rust 原生桥接模块（降级到 Node.js 内置模块）
const native = require('./native-proxy');

const DEFAULT_PORT = 0; // 0 = 让操作系统随机分配可用端口
const MIN_PORT = 10000;
const MAX_PORT = 60000;

// 随机端口范围
function getRandomPort() {
  return Math.floor(Math.random() * (MAX_PORT - MIN_PORT + 1)) + MIN_PORT;
}

// 尝试在指定端口启动，失败则自动重试
function tryListen(server, port, maxRetries = 10) {
  return new Promise((resolve, reject) => {
    let attempts = 0;

    function attempt(p) {
      server.listen(p, () => {
        const actualPort = server.address().port;
        resolve(actualPort);
      });

      server.on('error', (e) => {
        if (e.code === 'EADDRINUSE') {
          attempts++;
          if (attempts >= maxRetries) {
            reject(new Error(`端口 ${port} 被占用，已重试 ${maxRetries} 次`));
            return;
          }
          const nextPort = p === 0 ? 0 : getRandomPort();
          console.log(`[Proxy] 端口 ${p} 被占用，尝试 ${nextPort}...`);
          server.close();
          attempt(nextPort);
        } else {
          reject(e);
        }
      });
    }

    attempt(port);
  });
}

const server = http.createServer((req, res) => {
  // ===== 始终注入跨域头，确保任何请求都自动跨域 =====
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS, PATCH, HEAD');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Target-Url, Accept, X-Requested-With, Cache-Control');
  res.setHeader('Access-Control-Max-Age', '86400');
  res.setHeader('Access-Control-Allow-Credentials', 'true');

  // 预检请求直接返回
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  let body = [];
  req.on('data', chunk => {
    body.push(chunk);
  });

  req.on('end', () => {
    body = Buffer.concat(body);

    // 从 URL 路径获取目标 URL
    let targetUrl = req.url.substring(1);

    // 或者从请求头获取
    const headerTargetUrl = req.headers['x-target-url'];
    if (headerTargetUrl && headerTargetUrl !== 'undefined') {
      targetUrl = headerTargetUrl;
    }

    if (!targetUrl || targetUrl === 'favicon.ico' || targetUrl === '') {
      res.writeHead(400);
      res.end('Missing target URL');
      return;
    }

    // 使用 Rust 原生 URL 解析（降级到 Node.js 内置）
    const parsed = native.parseUrl(targetUrl);
    if (!parsed) {
      res.writeHead(400);
      res.end('Invalid URL');
      return;
    }

    console.log(`[Proxy] ${req.method} ${targetUrl} ${native.isNativeAvailable ? '(Rust)' : '(Node.js)'}`);

    try {
      const options = {
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method: req.method,
        headers: {}
      };

      // 复制请求头，排除代理相关的头
      for (const [key, value] of Object.entries(req.headers)) {
        if (key.toLowerCase() !== 'host' &&
            key.toLowerCase() !== 'x-target-url' &&
            key.toLowerCase() !== 'origin' &&
            key.toLowerCase() !== 'referer') {
          options.headers[key] = value;
        }
      }

      options.headers['host'] = parsed.host;

      const protocol = parsed.protocol === 'https:' ? https : http;

      const proxyReq = protocol.request(options, (proxyRes) => {
        // 复制响应头，但确保跨域头始终生效
        const headersToSkip = ['transfer-encoding', 'connection'];
        for (const [key, value] of Object.entries(proxyRes.headers)) {
          if (!headersToSkip.includes(key.toLowerCase())) {
            // 不覆盖已设置的 CORS 头
            if (!key.toLowerCase().startsWith('access-control-')) {
              res.setHeader(key, value);
            }
          }
        }

        // 再次确保跨域头（防止源站覆盖）
        res.setHeader('Access-Control-Allow-Origin', '*');
        res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS, PATCH, HEAD');
        res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-Target-Url, Accept, X-Requested-With, Cache-Control');

        res.writeHead(proxyRes.statusCode);
        proxyRes.pipe(res);
      });

      proxyReq.on('error', (e) => {
        console.error(`Proxy error: ${e.message}`);
        res.writeHead(502);
        res.end(`Proxy error: ${e.message}`);
      });

      if (body.length > 0) {
        proxyReq.write(body);
      }
      proxyReq.end();

    } catch (e) {
      console.error(`URL parse error: ${e.message}`);
      res.writeHead(400);
      res.end(`Invalid URL: ${e.message}`);
    }
  });
});

// ===== API 路由：暴露 Rust 原生能力给前端 =====
const apiServer = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Content-Type', 'application/json');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://localhost:${apiPort}`);
  const route = url.pathname;

  // 路由分发
  if (route.startsWith('/api/jsoup/')) {
    handleJsoupApi(route, url, req, res);
  } else if (route.startsWith('/api/crypto/')) {
    handleCryptoApi(route, url, req, res);
  } else if (route.startsWith('/api/url/')) {
    handleUrlApi(route, url, req, res);
  } else if (route.startsWith('/api/js/')) {
    handleJsApi(route, url, req, res);
  } else if (route === '/api/status') {
    res.writeHead(200);
    res.end(JSON.stringify({
      nativeAvailable: native.isNativeAvailable,
      proxyPort: actualProxyPort,
      apiPort: apiPort,
    }));
  } else {
    res.writeHead(404);
    res.end(JSON.stringify({ error: 'Not found' }));
  }
});

// Jsoup API
function handleJsoupApi(route, url, req, res) {
  const html = url.searchParams.get('html') || '';
  const selector = url.searchParams.get('selector') || '';

  try {
    let result;
    if (route === '/api/jsoup/select') {
      result = native.jsoupSelect(html, selector);
    } else if (route === '/api/jsoup/selectFirst') {
      result = native.jsoupSelectFirst(html, selector);
    } else if (route === '/api/jsoup/getAttr') {
      const attr = url.searchParams.get('attr') || '';
      result = native.jsoupGetAttr(html, selector, attr);
    } else if (route === '/api/jsoup/clean') {
      result = native.jsoupClean(html);
    } else {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Unknown jsoup API' }));
      return;
    }
    res.writeHead(200);
    res.end(JSON.stringify({ result }));
  } catch (e) {
    res.writeHead(500);
    res.end(JSON.stringify({ error: e.message }));
  }
}

// Crypto API
function handleCryptoApi(route, url, req, res) {
  const input = url.searchParams.get('input') || '';

  try {
    let result;
    if (route === '/api/crypto/md5') {
      result = native.md5(input);
    } else if (route === '/api/crypto/sha256') {
      result = native.sha256(input);
    } else if (route === '/api/crypto/base64Encode') {
      result = native.base64Encode(input);
    } else if (route === '/api/crypto/base64Decode') {
      result = native.base64Decode(input);
    } else if (route === '/api/crypto/hmacSha256') {
      const key = url.searchParams.get('key') || '';
      result = native.hmacSha256(key, input);
    } else {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Unknown crypto API' }));
      return;
    }
    res.writeHead(200);
    res.end(JSON.stringify({ result }));
  } catch (e) {
    res.writeHead(500);
    res.end(JSON.stringify({ error: e.message }));
  }
}

// URL API
function handleUrlApi(route, url, req, res) {
  try {
    let result;
    if (route === '/api/url/parse') {
      const rawUrl = url.searchParams.get('url') || '';
      result = native.parseUrl(rawUrl);
    } else if (route === '/api/url/resolve') {
      const base = url.searchParams.get('base') || '';
      const relative = url.searchParams.get('relative') || '';
      result = native.resolveUrl(base, relative);
    } else {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Unknown URL API' }));
      return;
    }
    res.writeHead(200);
    res.end(JSON.stringify({ result }));
  } catch (e) {
    res.writeHead(500);
    res.end(JSON.stringify({ error: e.message }));
  }
}

// JS API（QuickJS 降级引擎）
function handleJsApi(route, url, req, res) {
  try {
    let result;
    if (route === '/api/js/evaluate') {
      const code = url.searchParams.get('code') || '';
      result = native.jsEvaluate(code);
    } else if (route === '/api/js/evaluateWithVars') {
      const code = url.searchParams.get('code') || '';
      const varsStr = url.searchParams.get('vars') || '{}';
      const variables = JSON.parse(varsStr);
      result = native.jsEvaluateWithVars(code, variables);
    } else if (route === '/api/js/evaluateWithContext') {
      const code = url.searchParams.get('code') || '';
      const resultStr = url.searchParams.get('result') || '';
      const baseUrl = url.searchParams.get('baseUrl') || '';
      const content = url.searchParams.get('content') || '';
      const bookJson = url.searchParams.get('book') || null;
      const chapterJson = url.searchParams.get('chapter') || null;
      result = native.jsEvaluateWithContext(code, resultStr, baseUrl, content, bookJson, chapterJson);
    } else {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Unknown JS API' }));
      return;
    }
    res.writeHead(200);
    res.end(JSON.stringify({ result }));
  } catch (e) {
    res.writeHead(500);
    res.end(JSON.stringify({ error: e.message }));
  }
}

// ===== 启动 =====
let actualProxyPort = 0;
let apiPort = 0;

async function start() {
  // 启动 CORS 代理
  const proxyPort = process.argv[2] ? parseInt(process.argv[2]) : DEFAULT_PORT;
  actualProxyPort = await tryListen(server, proxyPort);

  // 启动 API 服务（随机端口）
  apiPort = await tryListen(apiServer, 0);

  console.log(`\n🚀 CORS Proxy Server running at http://localhost:${actualProxyPort}`);
  console.log(`📡 Proxy Usage: http://localhost:${actualProxyPort}/https://example.com/api`);
  console.log(`   Or use header: X-Target-Url: https://example.com/api`);
  console.log(`\n🔧 Native API Server running at http://localhost:${apiPort}`);
  console.log(`   /api/jsoup/select?html=...&selector=...`);
  console.log(`   /api/jsoup/selectFirst?html=...&selector=...`);
  console.log(`   /api/jsoup/clean?html=...`);
  console.log(`   /api/crypto/md5?input=...`);
  console.log(`   /api/crypto/sha256?input=...`);
  console.log(`   /api/crypto/base64Encode?input=...`);
  console.log(`   /api/crypto/base64Decode?input=...`);
  console.log(`   /api/url/parse?url=...`);
  console.log(`   /api/url/resolve?base=...&relative=...`);
  console.log(`   /api/status`);
  console.log(`\n⚡ Rust Native: ${native.isNativeAvailable ? '已启用' : '未编译（使用 JS 降级）'}`);
  console.log(`🔄 跨域已自动启用，所有请求均支持 CORS\n`);

  // 输出端口信息到 stderr，方便程序解析
  process.stderr.write(`PROXY_PORT:${actualProxyPort}\n`);
  process.stderr.write(`API_PORT:${apiPort}\n`);
}

start().catch((e) => {
  console.error(`❌ 启动失败: ${e.message}`);
  process.exit(1);
});
