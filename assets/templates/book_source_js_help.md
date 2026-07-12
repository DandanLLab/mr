# JS 书源开发文档

> 本文档说明 JS 书源开发中可用的所有 API、语法和内置对象，标注实现状态及实际代码位置。
>
> JS 引擎调度入口：[lib/services/native/js_engine.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/native/js_engine.dart)

---

## 图例

| 标记 | 含义 |
|------|------|
| ✅ | 已完整实现 |
| ⚠️ | 已实现，但存在差异或限制 |
| 🔧 | 部分实现，功能受限 |
| ❌ | 未实现 |
| ➕ | 本应用独有 |

---

## 一、JS 引擎：QuickJS

本应用所有 JS 代码统一由 **QuickJS（C 原生 FFI）** 执行。规则中只需使用 `@js:` 前缀即可。

| 特性 | 说明 |
|------|------|
| **实现形式** | C 原生 FFI（Android 编译为 `.so`，iOS 编译为 `.a`，桌面端直接链接） |
| **JS 标准** | ES2020（含 ES6+ 全部特性：`const`/`let`/`=>`/`class`/`async`/`Proxy`/`BigInt` 等） |
| **执行模式** | 同步（`evaluate`） |
| **Web 平台** | `quickjs_runtime_stub.dart` 提供兼容 stub，部分能力受限 |

> 引擎实现：[lib/services/native/quickjs_runtime.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/native/quickjs_runtime.dart)

---

## 二、JS 内置变量

| 变量 | 类型 | 状态 | 说明 |
|------|------|------|------|
| `result` | String | ✅ | 当前规则处理的输入文本 |
| `baseUrl` | String | ✅ | 当前页面或请求的基础 URL |
| `content` | String | ✅ | `result` 的别名 |
| `src` | String | ✅ | `result` 的别名 |
| `title` | String | ✅ | 章节标题 |
| `index` | Number | ✅ | 章节索引（正文规则中可用） |
| `book` | Object | ✅ | 书籍信息对象 |
| `chapter` | Object | ✅ | 章节信息对象 |
| `source` | Object | ✅ | 书源元数据对象 |
| `cookie` | Object | ✅ | Cookie 信息 |
| `nextChapterUrl` | String | ✅ | 下一章节 URL |
| `isFromBookInfo` | Boolean | ✅ | 是否为详情页刷新触发 |

### source 对象属性

| 属性 | 状态 | 说明 |
|------|------|------|
| `source.bookSourceUrl` | ✅ | 书源 URL（唯一标识） |
| `source.bookSourceName` | ✅ | 书源名称 |
| `source.bookSourceGroup` | ✅ | 书源分组 |
| `source.bookSourceType` | ✅ | 类型：0文字 / 1音频 / 2图片 / 3文件 / 4视频 |
| `source.header` | ✅ | 请求头 JSON |
| `source.loginUrl` | ✅ | 登录 URL |
| `source.loginCheckJs` | ✅ | 登录检查 JS |
| `source.enabledCookieJar` | ✅ | CookieJar 开关 |
| `source.concurrentRate` | ✅ | 并发频率限制 |
| `source.jsLib` | ✅ | JS 库代码（公共函数库） |
| `source.variable` | ✅ | 书源持久化变量（JSON 字符串） |

### book 对象属性

| 属性 | 状态 | 说明 |
|------|------|------|
| `book.name` / `book.bookName` | ✅ | 书名 |
| `book.author` / `book.bookAuthor` | ✅ | 作者 |
| `book.bookUrl` | ✅ | 书籍详情页 URL |
| `book.coverUrl` | ✅ | 封面 URL |
| `book.intro` | ✅ | 简介 |
| `book.kind` | ✅ | 分类标签 |
| `book.lastChapter` | ✅ | 最新章节标题 |
| `book.tocUrl` | ✅ | 目录页 URL |
| `book.wordCount` | ✅ | 字数 |

### chapter 对象属性

| 属性 | 状态 | 说明 |
|------|------|------|
| `chapter.title` | ✅ | 章节标题 |
| `chapter.url` / `chapter.chapterUrl` | ✅ | 章节 URL |
| `chapter.index` / `chapter.chapterIndex` | ✅ | 章节序号 |
| `chapter.isVolume` | ✅ | 是否为卷 |

---

## 三、java 桥接对象

### 3.1 HTTP 请求

| 方法 | 状态 | 说明 |
|------|------|------|
| `java.get(url, headers)` | ✅ | HTTP GET，预缓存优先 |
| `java.post(url, body, headers)` | ✅ | HTTP POST，预缓存优先 |
| `java.ajax(url, headers)` | ✅ | 同 `java.get` |
| `java.ajaxAll(urls)` | ⚠️ | 并发请求，预缓存优先 |
| `java.getStrResponse(url, ruleStr)` | ✅ | 请求 + 规则解析 |
| `java.connect(url, header)` | ✅ | HTTP 连接，预缓存优先 |
| `java.head(url, headers)` | 🔧 | 仅从缓存取，无真实 HEAD 请求 |

### 3.2 变量存取

| 方法 | 状态 | 说明 |
|------|------|------|
| `java.put(key, value)` | ✅ | 内存缓存存储 |
| `java.getStr(key, defaultValue)` | ✅ | 内存缓存读取 |
| `java.getString(str, ruleStr)` | ✅ | 对字符串应用规则（CSS/JSON/正则） |
| `java.getString(content, ruleStr)` | ✅ | 对指定内容应用规则 |
| `java.getJson(str)` | ✅ | JSON 解析 |
| `java.putJson(key, value)` | ✅ | JSON 存储 |

### 3.3 加密/解密

| 方法 | 状态 | 说明 | 底层实现 |
|------|------|------|----------|
| `java.aesEncode(data, key, iv)` | ✅ | AES 加密 | C 原生 `quickjs/crypto/aes.c` |
| `java.aesDecode(data, key, iv)` | ✅ | AES 解密 | C 原生 `quickjs/crypto/aes.c` |
| `java.md5Encode(str)` | ✅ | MD5 哈希 | C 原生 `quickjs/crypto/md5.c` |
| `java.md5Encode16(str)` | ✅ | MD5 16 位 | C 原生 `md5.c` |
| `java.sha1Encode(str)` | ✅ | SHA-1 哈希 | C 原生 `quickjs/crypto/sha1.c` |
| `java.sha256Encode(str)` | ✅ | SHA-256 哈希 | C 原生 `quickjs/crypto/sha256.c` |
| `java.hmacSHA256(data, key)` | ✅ | HMAC-SHA256 | C 原生 `quickjs/crypto/hmac_sha256.c` |
| `java.base64Encode(str)` | ✅ | Base64 编码 | C 原生 |
| `java.base64Decode(str)` | ✅ | Base64 解码 | C 原生 |
| `java.hexEncodeToString(str)` | ✅ | 十六进制编码 | C 原生 |
| `java.hexDecodeToString(hex)` | ✅ | 十六进制解码 | C 原生 |
| `java.digestHex(data, algorithm)` | ✅ | 摘要哈希 | C 原生 |
| `java.digestBase64Str(data, algorithm)` | ✅ | 摘要 Base64 | C 原生 |
| `java.strToBytes(str)` | ✅ | 字符串转字节数组 |
| `java.bytesToStr(bytes)` | ✅ | 字节数组转字符串 |
| `java.desEncode` / `desDecode` | ⚠️ | 简化为 AES，非真实 DES |
| `java.createAsymmetricCrypto` | ❌ | 非对称加密未实现 |
| `java.createSign` | ❌ | 签名未实现 |

> C 原生加密调用：通过 FFI 加载 `libquickjs_c_bridge.so`（Android）或内置 Framework（iOS）

### 3.4 HTML 解析

| 方法 | 状态 | 说明 |
|------|------|------|
| `java.jsoup.parse(html)` | ✅ | 解析 HTML |
| `java.jsoup.select(html, selector)` | ✅ | CSS 选择所有元素 |
| `java.jsoup.selectFirst(html, selector)` | ✅ | CSS 选择首个元素 |
| `java.jsoup.getAttr(html, selector, attr)` | ✅ | 获取属性 |
| `java.jsoup.clean(html)` | ✅ | 清理 HTML |
| `java.getElements(html, rule)` | ✅ | 获取元素列表 |
| `java.getElement(html, rule)` | ✅ | 获取单个元素 |
| `java.htmlFormat(str)` | ✅ | HTML 格式化 |

### 3.5 正则操作

| 方法 | 状态 | 说明 |
|------|------|------|
| `java.regex.match(str, pattern)` | ✅ | 正则匹配 |
| `java.regex.matchAll(str, pattern)` | ✅ | 正则匹配所有 |
| `java.regex.replace(str, pattern, repl)` | ✅ | 正则替换 |
| `java.regex.test(str, pattern)` | ✅ | 正则测试 |

### 3.6 工具方法

| 方法 | 状态 | 说明 |
|------|------|------|
| `java.log(msg)` | ✅ | 日志输出 |
| `java.timeFormat(timestamp, format)` | ✅ | 时间格式化 |
| `java.getTime()` | ✅ | 当前时间戳 |
| `java.encodeURI(str)` | ✅ | URI 编码 |
| `java.randomUUID()` | ✅ | 生成 UUID |
| `java.androidId()` | ⚠️ | 伪 ID（基于 UUID，非真实 Android ID） |
| `java.getWebViewUA()` | ⚠️ | 固定 UA 字符串，非真实 User-Agent |
| `java.t2s(text)` / `java.s2t(text)` | ⚠️ | 简易繁简映射表 |
| `java.toNumChapter(s)` | ✅ | 章节号转换 |
| `java.toast(msg)` / `java.longToast(msg)` | 🔧 | 仅 console.log，无 Toast UI |
| `java.toURL(urlStr, base)` | ✅ | URL 解析 |
| `java.getCookie(tag, key)` | 🔧 | 仅从缓存取 |
| `java.getVerificationCode(imageUrl)` | 🔧 | 仅从缓存取 |
| `java.startBrowser(url)` | 🔧 | 空操作（不打开浏览器） |
| `java.startBrowserAwait(url, title)` | ✅ | 预缓存优先，等待浏览器结果 |
| `java.cacheFile(url)` | 🔧 | 仅从缓存取 |
| `java.importScript(path)` | 🔧 | 仅从缓存取 |
| `java.getResponseCode` | ❌ | 未实现 |
| `java.readFile` / `readTxtFile` | ❌ | 未实现 |
| `java.deleteFile` | ❌ | 未实现 |
| `java.unzipFile` / `un7zFile` / `unrarFile` | ❌ | 未实现 |
| `java.getReadBookConfig()` | ❌ | 返回空 JSON |
| `java.getThemeMode()` | ❌ | 返回固定值 |
| `java.openUrl(url)` | ❌ | 空操作 |

### 3.7 缓存管理

| 方法 | 状态 | 说明 |
|------|------|------|
| `java.cache.get(key)` | ⚠️ | QuickJS 仅内存有效，跨会话用 `source.variable` |
| `java.cache.put(key, value)` | ⚠️ | 同上 |
| `java.cache.delete(key)` | ⚠️ | 同上 |

---

## 四、CryptoJS 加密库

标准 Web 加密 API，底层通过 C 原生加密 FFI 实现。

| 功能 | 状态 | 说明 |
|------|------|------|
| `CryptoJS.AES.encrypt/decrypt` | ✅ | AES 加解密 |
| `CryptoJS.MD5(str)` | ✅ | MD5 哈希 |
| `CryptoJS.SHA256(str)` | ✅ | SHA-256 哈希 |
| `CryptoJS.SHA1(str)` | ✅ | SHA-1 哈希 |
| `CryptoJS.HmacSHA256(data, key)` | ✅ | HMAC-SHA256 |
| `CryptoJS.enc.Utf8/Base64/Hex` | ✅ | 编码器 |
| `CryptoJS.mode.ECB/CBC` | ✅ | 加密模式 |
| `CryptoJS.pad.Pkcs7/ZeroPadding/NoPadding` | ✅ | 填充模式 |

---

## 五、QuickJS 独有全局 API

本应用向 QuickJS 引擎注入的 Web / Node.js 兼容 API：

| API | 状态 | 说明 |
|-----|------|------|
| `fetch(url, options)` | ✅ | 标准 Web HTTP 请求接口 |
| `console.log/warn/error/info/dir/table/time/timeEnd` | ✅ | 完整控制台 |
| `btoa()` / `atob()` | ✅ | Base64 编解码 |
| `setTimeout` / `setInterval` | ✅ | 定时器 |
| `URL` / `URLSearchParams` | ✅ | URL 解析 |
| `XMLHttpRequest` | ✅ | HTTP 请求（简化模拟） |
| `require()` | ✅ | Node.js 模块模拟（http/https/fs/path/crypto） |
| `process` | ✅ | Node.js process 模拟 |
| `Buffer` | ✅ | Node.js Buffer 模拟 |

---

## 六、ES2020 语法支持（QuickJS）

| 语法 | 状态 | 示例 |
|------|------|------|
| `const` / `let` | ✅ | `const x = 1; let y = 2;` |
| 箭头函数 | ✅ | `(x) => x * 2` |
| 模板字符串 | ✅ | `` `Hello ${name}` `` |
| 解构赋值 | ✅ | `const {a, b} = obj;` |
| 展开运算符 | ✅ | `const arr2 = [...arr, 4]` |
| 剩余参数 | ✅ | `function fn(...args) {}` |
| 默认参数 | ✅ | `function fn(x = 10) {}` |
| `class` | ✅ | `class Foo {}` |
| `Promise` | ✅ | `new Promise(...)` |
| `async` / `await` | ✅ | `await fetch(url)` |
| `for...of` | ✅ | `for (const x of arr) {}` |
| `Symbol` | ✅ | `Symbol('key')` |
| `Map` / `Set` | ✅ | `new Map(); new Set()` |
| `Proxy` / `Reflect` | ✅ | `new Proxy(obj, h)` |
| `Generator` | ✅ | `function* gen() { yield 1; }` |
| `BigInt` | ✅ | `9007199254740991n` |
| 可选链 `?.` | ✅ | `obj?.prop?.method?.()` |
| 空值合并 `??` | ✅ | `null ?? 'default'` |
| 命名捕获组 | ✅ | `(?<name>\w+)` |
| `String.replaceAll` | ✅ | `str.replaceAll('a', 'b')` |
| `Array.flatMap` | ✅ | `arr.flatMap(x => [x])` |
| `Object.fromEntries` | ✅ | `Object.fromEntries(arr)` |

---

## 七、变量系统

### @put / @get 规则

```
@put:{"token":"tag.span@text","id":"class.uid@attr(data-id)"}
@get:{token}
```

### 变量查找链（优先级从高到低）

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | 本地变量 | `@put` 存入的运行时变量 |
| 2 | 书源变量 | `source.variable`（JSON 字符串） |
| 3 | 书源快捷属性 | `bookSourceUrl` / `bookSourceName` 等 |
| 4 | 书籍快捷属性 | `name` / `author` / `bookUrl` 等 |
| 5 | 章节快捷属性 | `title` / `chapterUrl` 等 |

### {{expression}} 模板

解析顺序：变量查找 → 规则执行（`@`/`$.`/`//`/`$[`）→ JS 执行

```
https://api.com/search?keyword={{key}}&page={{page}}
https://api.com/detail?id={{$.data.id}}
《{{@@.bookname@text}}》标签：{{@@.tags@a@text##\s##,}}
```

---

## 八、实战示例

### 用 fetch + CryptoJS 解密

```javascript
<js>
var key = CryptoJS.enc.Utf8.parse("1234567890123456");
var iv = CryptoJS.enc.Utf8.parse("1234567890123456");
var encrypted = CryptoJS.AES.encrypt("hello", key, {iv: iv});
var encStr = encrypted.toString();

var decrypted = CryptoJS.AES.decrypt(encStr, key, {iv: iv});
var decStr = CryptoJS.enc.Utf8.stringify(decrypted);
decStr;
</js>
```

### 用 jsoup 解析 HTML

```javascript
<js>
var name = java.jsoup.selectFirst(result, "h1.book-name");
var author = java.jsoup.selectFirst(result, "p.author");
var coverUrl = java.jsoup.getAttr(result, "img.cover", "src");
var intro = java.jsoup.selectFirst(result, "div.intro");
JSON.stringify({name, author, coverUrl, intro});
</js>
```

### console.log 调试

```javascript
<js>
console.log("result长度:", result.length);
console.log("baseUrl:", baseUrl);
console.log("书名:", book.name);
console.time("解析耗时");
// ... 解析逻辑 ...
console.timeEnd("解析耗时");
result;
</js>
```

### JS 执行追踪 + 引擎内存监控

QuickJS 执行时可通过调试面板（`crypto_stats_panel.dart`）可视化：

```javascript
<js>
// 调试面板可查看：
// 1. JS 引擎内存（25 字段：malloc/memory/size/objects/strings/shapes...）
// 2. Promise 状态（pending/fulfilled/rejected）
// 3. 手动触发 GC
// 4. JS_PrintValue 输出
var p = fetch("https://api.example.com/data");  // 在 Promise 监控面板查询 p 的状态
</js>
```

---

## 九、常见问题

**Q: fetch() 返回空字符串？**
A: 同步模式下 `fetch()` 优先从缓存获取。使用异步规则（`processJsRule`）或 `java.ajax()` 预缓存。

**Q: CryptoJS 和 java.aesEncode 有什么区别？**
A: `CryptoJS` 是标准 Web API 写法，`java.aesEncode` 是阅读 3.0 兼容写法。底层 C 原生实现相同，推荐用 `CryptoJS`。

**Q: console.log 在哪里看？**
A: 书源调试页面的「日志」标签页。

**Q: QuickJS 引擎有什么限制？**
A: 本应用只有 QuickJS 引擎，规则中使用 `@js:` 前缀即可。旧书源的 `@java:` 前缀通过 `java.*` 桥接对象兼容，无需担心。

**Q: java.cache 在 QuickJS 下能持久化吗？**
A: QuickJS 下仅内存有效。如需跨会话持久化，用 `source.variable`。

**Q: 支持 TypeScript 吗？**
A: 支持！使用 `@ts:` 前缀，自动编译为 JS 后执行。

**Q: 如何监控 QuickJS 引擎的健康状况？**
A: 打开调试页面的「引擎性能统计」面板，可查看 JS 内存占用、Promise 状态、手动触发 GC、流式打印 JS 值。

---

## 十、引擎内部机制参考

| 机制 | 文件 | 说明 |
|------|------|------|
| FFI 加载 + 函数绑定 | `lib/services/native/quickjs_runtime.dart` | Dart 侧 FFI 绑定 |
| Web 平台 stub | `lib/services/native/quickjs_runtime_stub.dart` | Web 回退实现 |
| C 桥接层 | `quickjs/quickjs_bridge.c` | 所有 FFI 导出符号 |
| 句柄表（ABA 防护） | `quickjs/handle_table.c` | id→指针映射，防止 Dart GC 后野指针 |
| 内存追踪 | `quickjs/memory_tracker.c` | 全局 malloc/free 计数 + 峰值 |
| 超时熔断 | `quickjs/quickjs_bridge.c` | 5s 默认超时，`JS_SetInterruptHandler` |
| GC 阈值 | `quickjs/quickjs_bridge.c` | memory_limit/4，`JS_SetGCThreshold` |
| JS 内存统计 | `quickjs/quickjs_bridge.c` | `JS_ComputeMemoryUsage` 25 字段 |