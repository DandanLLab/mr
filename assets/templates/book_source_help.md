# 书源规则帮助

> 本文档基于阅读（Legado）规则体系，标注每项功能的实现状态及与本应用实际代码的对应关系。
>
> 规则引擎核心代码：[lib/services/source_engine/analyze_rule.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_engine/analyze_rule.dart)

---

## 图例

| 标记 | 含义 |
|------|------|
| ✅ | 已完整实现，与 Legado 行为一致 |
| ⚠️ | 已实现，但与 Legado 存在差异（见备注） |
| 🔧 | 部分实现，功能受限 |
| ❌ | 未实现 |
| ➕ | 本应用独有，Legado 没有 |

---

## 一、规则模式

| 模式 | 前缀 | 状态 | 说明 | 实现位置 |
|------|------|------|------|----------|
| CSS/JSoup | `@@` / `@CSS:` / 无前缀 | ✅ | `package:html` CSS 选择器 | `analyze_rule.dart` 规则链 |
| JSON | `@Json:` / `$.` / `$[` | ✅ | JSONPath 递归搜索 + 过滤器 | `legado_json_path.dart` |
| XPath | `@XPath:` / `//` | ✅ | `xml` + `xpath` 包 + HTML 自动补全 | `legado_xpath.dart` |
| JS | `@js:` / `<js>`...`</js>` | ✅ | QuickJS 单引擎（ES2020） | `js_engine.dart` |
| Regex | `:` | ✅ | 正则模式，以 `:` 开头 | `analyze_rule.dart` |
| WebJS | `@webjs:` | 🔧 | WebView JS，需 InAppWebView 配合 | `js_advanced_service.dart` |
| TypeScript | `@ts:` | ➕ | 自动编译为 JS 后 QuickJS 执行 | `analyze_rule.dart` → quickjs |

---

## 二、CSS 选择器规则（JSoup 模式）

### 2.1 元素定位

| 语法 | 状态 | 说明 | 示例 |
|------|------|------|------|
| `class.xxx` | ✅ | CSS 类选择器 | `class.book-list` |
| `tag.xxx` | ✅ | 标签选择器 | `tag.div` |
| `id.xxx` | ✅ | ID 选择器 | `id.main` |
| `#xxx` | ✅ | 等同于 `id.xxx` | `#main` |
| `text.xxx` | ✅ | 文本内容匹配 | `text.章节` |
| `children` | ✅ | 子元素 | `children` |
| 标准 CSS 选择器 | ✅ | `querySelectorAll` | `div.class > p` |
| `@css:selector` | ✅ | 显式 CSS 前缀 | `@css:div.book-list > li` |

### 2.2 属性提取（`@` 分隔符后）

| 属性 | 状态 | 说明 |
|------|------|------|
| `@text` | ✅ | 元素文本（含子元素文本） |
| `@ownText` | ✅ | 元素自身文本（不含子元素） |
| `@textNodes` | ✅ | 直接文本节点列表 |
| `@html` | ✅ | 元素 HTML（移除 script/style） |
| `@all` | ✅ | 完整 HTML（含 script/style） |
| `@href` | ✅ | href 属性，自动拼接绝对 URL |
| `@src` | ✅ | src 属性，自动拼接绝对 URL |
| `@hrefUrl` | ✅ | 等同于 `@href` |
| `@srcUrl` | ✅ | 等同于 `@src` |
| `@onclick` | ✅ | onclick 属性，自动提取 JS 中的 URL |
| `@attr:xxx` | ✅ | 通用属性提取，含 JS 跳转代码自动提取 |
| `@title` / `@alt` / `@style` | ✅ | 常用属性快捷方式 |
| `@data-src` / `@data-original` | ✅ | data 属性快捷方式 |
| `@content` / `@name` / `@value` | ✅ | 表单属性快捷方式 |

### 2.3 索引选择

| 格式 | 状态 | 说明 | 示例 |
|------|------|------|------|
| `.索引` | ✅ | 按索引选择（0 开始） | `tag.div.0` |
| `.-1` | ✅ | 负数索引（倒数） | `tag.div.-1` |
| `:索引` | ✅ | 冒号分隔多索引 | `tag.div.0:2:4` |
| `[!0,1,2]` | ✅ | 排除模式切片 | `tag.div[!0,1]` |
| `[start:end:step]` | ✅ | 带步长的区间 | `tag.div[0:10:2]` |
| `[-1:0]` | ✅ | 反向列表 | `tag.div[-1:0]` |

### 2.4 组合操作符

| 操作符 | 状态 | 说明 |
|--------|------|------|
| `&&` | ✅ | 并集：合并多个规则结果 |
| `\|\|` | ✅ | 或集：取第一个非空结果即停止 |
| `%%` | ✅ | 交叉合并：按顺序交替合并 |

---

## 三、JSON 规则（JSONPath）

| 语法 | 状态 | 说明 | 示例 |
|------|------|------|------|
| `$.property` | ✅ | 属性访问 | `$.data.list` |
| `$[n]` | ✅ | 数组索引 | `$[0]` |
| `$[start:end]` | ✅ | 数组切片 | `$[0:10]` |
| `$..property` | ✅ | 递归搜索 | `$..name` |
| `$[*]` | ✅ | 通配符 | `$.data[*]` |
| `$[?(@.key==value)]` | ✅ | 过滤器（支持 == != > < >= <=） | `$.list[?(@.type==1)]` |
| `{$.rule}` | ✅ | 内嵌规则替换 | `{$.data.id}` |
| `&&` / `\|\|` / `%%` | ✅ | 组合操作符 | 同 CSS 模式 |

> 实现文件：[lib/services/source_engine/legado_json_path.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_engine/legado_json_path.dart)

---

## 四、XPath 规则

| 语法 | 状态 | 说明 | 示例 |
|------|------|------|------|
| `//元素` | ✅ | 任意位置选取 | `//div[@class="content"]` |
| `/元素` | ✅ | 绝对路径 | `/html/body/div` |
| `@属性` | ✅ | 选取属性 | `//a/@href` |
| `*` | ✅ | 通配符 | `//*` |
| HTML 自动补全 | ✅ | td/tr/li/option 自动包裹 | — |
| `&&` / `\|\|` / `%%` | ✅ | 组合操作符 | 同 CSS 模式 |

> 实现文件：[lib/services/source_engine/legado_xpath.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_engine/legado_xpath.dart)

---

## 五、正则替换规则

| 格式 | 状态 | 说明 |
|------|------|------|
| `规则##正则` | ✅ | 匹配结果替换为空（删除） |
| `规则##正则##替换文本` | ✅ | 匹配结果替换为指定文本 |
| `规则##正则##替换文本###` | ✅ | 三个 `#` 结尾 → 只替换第一个匹配 |
| `$1` `$2` ... `$n` | ✅ | 捕获组反向引用 |
| `{{}}` 内的 `##` 跳过 | ✅ | 模板表达式内的 `##` 不作为分隔符 |

> 链式规则：多个 `##` 步骤可串接，如 `tag.p@text##作者：##作者:`

---

## 六、模板规则

| 语法 | 状态 | 说明 |
|------|------|------|
| `{{@@.xxx@text}}` | ✅ | CSS 子规则模板 |
| `{{$.xxx}}` | ✅ | JSON 子规则模板 |
| `{{$[n]}}` | ✅ | JSON 数组子规则 |
| `{{//xxx}}` | ✅ | XPath 子规则模板 |
| `{{JS表达式}}` | ✅ | JS 表达式模板 |
| `{{变量名}}` | ✅ | 变量查找模板 |

---

## 七、变量系统

| 功能 | 状态 | 说明 |
|------|------|------|
| `@put:{key:value}` | ✅ | 存储变量到运行时缓存 |
| `@get:{key}` | ✅ | 读取运行时缓存变量 |
| 变量查找链 | ✅ | 顺序：本地变量 → book → source → 全局 |
| `java.put(key, value)` | ✅ | JS 中存取运行时缓存 |
| `java.getStr(key)` | ✅ | JS 读取运行时缓存 |
| `source.variable` | ✅ | 书源持久化变量（JSON 字符串） |
| `$1` `$2` 反向引用 | ✅ | 正则捕获组引用 |

---

## 八、URL 选项

| 选项 | 状态 | 说明 |
|------|------|------|
| `method` | ✅ | GET / POST |
| `body` | ✅ | POST 请求体 |
| `headers` | ✅ | 自定义请求头 |
| `charset` | ✅ | 响应编码（如 `gbk`） |
| `webView` | ⚠️ | WebView 加载（需 InAppWebView 配合） |
| `js` | ✅ | URL 级 JS 脚本（请求前执行） |
| `bodyJs` | ✅ | 响应体 JS 转换（请求后执行） |
| `retry` | ✅ | 重试次数 |
| `type` | ✅ | 响应类型（如 `audio` / `image`） |
| `webJs` | ⚠️ | WebView 中执行的 JS |
| `dnsIp` | ❌ | 强制 DNS 解析 |
| `proxy` | ❌ | 代理设置 |
| `concurrentRate` | ⚠️ | 并发频率限制（部分支持） |

### URL 模板变量

| 变量 | 状态 | 说明 |
|------|------|------|
| `{{key}}` | ✅ | 搜索关键词 |
| `{{page}}` | ✅ | 当前页码 |
| `{{page,1,2,3...}}` | ⚠️ | 分页模板（部分支持） |
| `{{host}}` | ✅ | 当前书源域名 |
| `{{result}}` | ✅ | 上一步规则结果 |

---

## 九、内容渲染标签

| 标签 | 状态 | 说明 |
|------|------|------|
| `<usehtml>...</usehtml>` | ✅ | HTML 样式渲染 |
| `<md>...</md>` | ✅ | Markdown 渲染 |
| `<useweb>...</useweb>` | ❌ | 浏览器渲染 |
| HTML 自动检测 | ✅ | 含 HTML 标签的内容自动用 Html widget 渲染 |

---

## 十、与 Legado 的关键差异

### 10.1 引擎架构差异

| 项目 | Legado（阅读） | 本应用 |
|------|----------------|--------|
| JS 引擎 | Rhino（JVM） | QuickJS（C FFI，ES2020） |
| HTML 解析 | JSoup（Java） | `package:html`（Dart CSS 选择器） |
| JSON 解析 | Gson + 自定义 JSONPath | Dart json + `legado_json_path.dart` |
| XPath 解析 | Jaxen | `xml` + `xpath` Dart 包 |
| HTTP 客户端 | OkHttp | Dio + OkHttp（Android 原生通道） |
| 平台 | Android only | Flutter 跨平台（Android / iOS / Web / 桌面） |
| 加密实现 | Java | C 原生（`quickjs/crypto/`，FFI 调用） |

### 10.2 规则解析差异

| 差异点 | 说明 |
|--------|------|
| CSS 选择器 | Legado 用 JSoup（Java），本应用用 `package:html`（Dart）+ `xml/xpath` 包，多数选择器兼容，少数高级伪类（`:has()`）不支持 |
| `@text` | 行为一致：获取元素及子元素的文本 |
| `@html` | 行为一致：返回 outerHtml，移除 script/style |
| `@ownText` | 行为一致：仅自身文本，不含子元素 |
| `@onclick` | 行为一致：自动从 JS 代码提取 URL |
| 索引选择 | 行为一致：`.0` / `.-1` / `[0:3]` / `[!0]` |
| `&&` / `\|\|` / `%%` | 行为一致 |
| 正则替换 `##` | 行为一致：`##regex##replacement` / `###` = replaceFirst |
| `$1` 反向引用 | 行为一致：正则替换中引用捕获组 |
| `{{@@.xxx}}` 模板 | 行为一致：子规则模板替换 |
| `@put` / `@get` | 行为一致：变量存取 |

### 10.3 JS 桥接差异

| 方法 | Legado | 本应用 |
|------|--------|--------|
| `java.ajax(url)` | 真实 HTTP 请求 | 预缓存优先，异步模式真实请求 |
| `java.get(url)` | 真实 HTTP 请求 | 预缓存优先，异步模式真实请求 |
| `java.post(url)` | 真实 HTTP 请求 | 预缓存优先，异步模式真实请求 |
| `java.ajaxAll(urls)` | 并发 HTTP 请求 | 预缓存优先，部分支持 |
| `java.head(url)` | 真实 HEAD 请求 | 仅从缓存取 |
| `java.getCookie(tag, key)` | CookieStore 操作 | JS 侧内存缓存实现 |
| `java.getVerificationCode(imageUrl)` | 验证码识别 | 仅从缓存取 |
| `java.startBrowser(url)` | 打开浏览器 | 空操作 |
| `java.startBrowserAwait(url, title)` | 浏览器获取页面 | 预缓存优先 |
| `java.cacheFile(url)` | 缓存文件 | 仅从缓存取 |
| `java.importScript(path)` | 导入脚本 | 仅从缓存取 |
| `java.readFile` / `readTxtFile` | 文件读取 | ❌ 未实现 |
| `java.deleteFile` | 文件删除 | ❌ 未实现 |
| `java.unzipFile` / `un7zFile` | 解压缩 | ❌ 未实现 |
| `java.getResponseCode` | 获取响应码 | ❌ 未实现 |
| `java.createAsymmetricCrypto` | 非对称加密 | ❌ 未实现 |
| `java.createSign` | 签名 | ❌ 未实现 |
| `java.desEncode` / `desDecode` | DES 加密 | ⚠️ 简化为 AES |
| `java.toast` / `java.longToast` | Toast 提示 | 仅 console.log |
| `java.getWebViewUA()` | 真实 User-Agent | 固定字符串 |
| `java.randomUUID()` | UUID | ✅ 一致 |
| `java.androidId()` | Android ID | 伪 ID（基于 UUID） |
| `java.t2s` / `java.s2t` | 繁简转换 | ⚠️ 简易映射表 |
| `java.htmlFormat(str)` | HTML 格式化 | ✅ 一致 |
| `java.toNumChapter(s)` | 章节号转换 | ✅ 一致 |
| `java.connect(url)` | HTTP 连接 | 预缓存优先 |
| `java.getString(ruleStr)` | 规则解析 | ✅ 支持 CSS/JSON/正则/默认模式 |
| `java.getElements(html, rule)` | 获取元素列表 | ✅ 一致 |
| `CryptoJS.*` | Java 实现 | ✅ 底层通过 C 原生加密 FFI 实现，API 全兼容 |

### 10.4 本应用独有功能

| 功能 | 说明 | 代码位置 |
|------|------|----------|
| `@ts:` TypeScript 前缀 | 自动编译 TS 为 JS 后执行 | `analyze_rule.dart` |
| ES2020 语法支持 | const/let/箭头函数/模板字符串/async-await 等 | QuickJS（ES2020） |
| `fetch()` 标准 Web API | 内置 HTTP 请求接口 | `quickjs_runtime.dart` |
| `console` 完整实现 | log/warn/error/info/dir/table/time/timeEnd | `js_engine.dart` |
| `btoa()` / `atob()` | Base64 编解码 | C 原生 `base64` |
| `URL` / `URLSearchParams` | URL 解析接口 | `quickjs_runtime.dart` |
| `require()` Node.js 模拟 | http/https/fs/path/crypto 等 | `quickjs_runtime.dart` |
| `Buffer` Node.js 模拟 | Buffer 操作 | `quickjs_runtime.dart` |
| 跨平台支持 | Android / iOS / Web / Desktop | Flutter 框架 |
| 预缓存桥接机制 | JS 执行前预缓存 HTTP/加密结果，加速同步执行 | `js_engine.dart` |
| JS 执行追踪树 | 调试页面可视化 JS 执行流程 | `source_debug_service.dart` |

---

## 十一、规则执行位置

| 书源字段 | 状态 | 说明 |
|----------|------|------|
| `searchUrl` | ✅ | 搜索 URL 生成 |
| `checkKeyWord` | ✅ | 搜索结果校验 |
| `bookList` | ✅ | 书籍列表提取 |
| `bookInfo.init` | ✅ | 详情页初始化 JS |
| `preUpdateJs` | ✅ | 目录更新前 JS |
| `formatJs` | ✅ | 章节名格式化 JS |
| `subContent` | ✅ | 备用正文规则 |
| `js` | ✅ | 正文 JS 预处理 |
| `contentRule.js` | ✅ | 正文加载后 JS |
| `callBackJs` | ✅ | 内容回调 JS |
| `loginCheckJs` | ✅ | 登录状态检查 JS |
| `replaceRegex` | ✅ | 正文替换规则 |
| `webJs` | ⚠️ | WebView JS（需 InAppWebView） |
| `imageDecode` | ✅ | 图片解码 JS |

---

## 十二、规则调试

本应用提供 `crypto_stats_panel.dart` 调试面板，位于书源调试页，支持：

- **加密性能统计**：C 原生加密方法调用次数、耗时、吞吐量
- **C 层内存监控**：`memory_tracker` 全局分配/释放/峰值
- **JS 引擎内存**：`JS_ComputeMemoryUsage` 25 字段全量展示
- **Promise 状态监控**：输入变量名查询 Promise pending/fulfilled/rejected
- **JS 值打印**：`JS_PrintValue` 流式输出任意 JS 表达式
- **手动 GC**：AppBar 按钮一键触发 `JS_RunGC`

> 详见 [debug_api_guide.md](debug_api_guide.md) 与 [book_source_js_help.md](book_source_js_help.md)。