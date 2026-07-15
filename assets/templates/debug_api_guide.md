# 调试服务与面板

> 本文档说明本应用内置的调试能力，所有内容均基于真实代码。
>
> - 调试服务后端：[lib/services/source_debug_service.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_debug_service.dart)
> - 调试 UI 入口：[lib/pages/debug/book_source_debug_page.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/pages/debug/book_source_debug_page.dart)
> - 崩溃日志面板：[lib/pages/debug/crash_log_panel.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/pages/debug/crash_log_panel.dart)

> ⚠️ 本应用**没有** WebSocket / HTTP 远程调试服务，所有调试均为本地进程内调用。

---

## 一、SourceDebugService（本地调试服务）

单例服务，参考 Legado 的 `Debug` 对象设计，负责串行执行书源调试全流程并收集源码与日志。

### 1.1 核心接口

| 成员 | 说明 |
|------|------|
| `SourceDebugService.instance` | 单例入口 |
| `callback: DebugCallback?` | 调试回调，UI 层设置后接收日志输出 |
| `startDebug(BookSource source, String key)` | 启动调试，根据 `key` 格式自动路由 |
| `cancelDebug({bool destroy = false})` | 取消当前调试，`destroy=true` 时清空回调 |
| `isDebugging` | 是否正在调试 |
| `searchSrc` / `bookSrc` / `tocSrc` / `contentSrc` | 各阶段抓取到的原始 HTML 源码缓存 |

### 1.2 DebugCallback 接口

UI 层通过实现 `DebugCallback` 接收调试日志：

```dart
abstract class DebugCallback {
  /// [state] 状态码（见下表）
  /// [msg] 已格式化的日志消息（含时间戳前缀）
  void printLog(int state, String msg);
}
```

### 1.3 状态码（DebugState）

与 Legado 保持一致，UI 层可据此高亮和分类显示：

| 状态 | code | 含义 |
|------|------|------|
| `error` | -1 | 错误 |
| `warn` | 0 | 警告 |
| `normal` | 1 | 普通日志 |
| `searchSrc` | 10 | 搜索页源码（携带 HTML） |
| `exploreSrc` | 15 | 发现页源码 |
| `bookSrc` | 20 | 详情页源码 |
| `tocSrc` | 30 | 目录页源码 |
| `contentSrc` | 40 | 正文页源码 |
| `success` | 1000 | 全流程成功完成 |

> 源码状态码（10/15/20/30/40）触发时，`log()` 会把 `sourceHtml` 存入对应缓存字段，供 UI 在「源码」标签页查看。

### 1.4 key 格式路由

`startDebug(source, key)` 根据 `key` 前缀自动选择调试入口：

| key 格式 | 调试入口 | 示例 |
|----------|----------|------|
| `++URL` | 目录页调试 | `++https://example.com/toc` |
| `--URL` | 正文页调试 | `--https://example.com/chapter/1` |
| `名称::URL`（非 URL） | 发现页调试 | `玄幻::https://example.com/list/xuanhuan` |
| `http://...` / `https://...` | 详情页调试 | `https://example.com/book/123` |
| 其他文本 | 搜索调试 | `斗破苍穹` |

### 1.5 调试流程

调试采用**链式自动推进**，前一步成功后自动进入下一步：

```
搜索 → 详情 → 目录 → 正文 → success(1000)
```

每步流程：

1. **搜索**（`_debugSearch`）：调用 `WebBook.searchBook` → 缓存 `searchSrc` → 输出第一条结果 → 取 `bookUrl` 进入详情
2. **详情**（`_debugBookInfo`）：调用 `WebBook.getBookInfo` → 缓存 `bookSrc` → 输出书名/作者/分类/字数/简介/封面/目录链接 → 取 `tocUrl` 进入目录
3. **目录**（`_debugToc`）：调用 `WebBook.getChapterList` → 缓存 `tocSrc` → 输出首章信息 → 取首章 `chapterUrl` 进入正文
4. **正文**（`_debugContent`）：调用 `WebBook.getContent`（含 `nextChapterUrl` 熔断） → 缓存 `contentSrc` → 输出格式化正文 → `success(1000)`

> 每进入下一步前会调用 `JsEngine.instance.clearJavaCache()` 清理 JS 桥接缓存，防止单次调试链内 `_javaCache` 无限增长导致 OOM。

### 1.6 日志格式

每条日志由 `log()` 统一格式化：

```
[MM:SS.mmm] 消息内容
```

时间戳为相对调试开始的偏移（`_formatTimestamp`）。

### 1.7 取消与清理

- `cancelDebug()` 设置 `_isCancelled=true`，各调试步骤在 await 点检查后提前返回
- 同时清空四个源码缓存字段，释放大 HTML 内存
- 调用 `JsEngine.instance.clearJavaCache()` 清理 JS 侧缓存
- `destroy=true` 时额外置空 `callback`，断开 UI 回调

---

## 二、书源调试页（book_source_debug_page.dart）

应用内 UI，提供可视化的调试入口与结果展示。

### 2.1 标签页

| 标签 | 功能 |
|------|------|
| 调试 | 输入书源 + key，启动调试，实时显示日志流 |
| 日志 | 查看历史调试日志详情，支持复制 |

### 2.2 调试交互

- 选择书源 + 输入 key（支持 `++`/`--`/`::`/URL/关键字 五种格式）
- 启动调试后实时显示带时间戳的日志
- 可中途取消
- 查看各阶段抓取的源码 HTML
- 弹窗查看日志详情、调试帮助、崩溃详情

---

## 三、崩溃日志面板（crash_log_panel.dart）

独立的 `CrashLogPanel` Widget，展示 `CrashLogService` 收集的崩溃记录。

### 3.1 功能

| 操作 | 说明 |
|------|------|
| 复制全部 | 将全部崩溃日志复制到剪贴板 |
| 导出到文件 | 把日志写入文件并提示路径，支持复制路径 |
| 加载 | 重新读取崩溃日志 |
| 清空 | 二次确认后清空所有崩溃记录 |

### 3.2 展示内容

- 空状态：显示「暂无崩溃日志」+ 应用运行时长
- 每条崩溃记录以 `_CrashLogCard` 卡片形式展示
- 卡片点击可展开详情对话框，支持复制单条日志

> 崩溃数据来源：`CrashLogService`（启动时由 `main.dart` 最先初始化，注册 `runZonedGuarded` 全局错误捕获）。

---

## 四、QuickJS Runtime 编程接口

QuickJS 引擎（[lib/services/native/quickjs_runtime.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/native/quickjs_runtime.dart)）提供以下编程接口，可在 Dart 代码中直接调用（**不是远程 API**）：

### 4.1 引擎生命周期

| 方法 | 说明 |
|------|------|
| `evaluate(script)` | 执行 JS 代码，返回 `JsEvalResult`（含 `isError` 字段） |
| `precompile(script)` | 预编译脚本为字节码 |
| `clearBytecodeCache()` | 清空字节码缓存 |
| `dispose()` | 释放 QuickJS runtime |

### 4.2 执行控制

| 方法 | 说明 |
|------|------|
| `setEvalTimeout(int timeoutMs)` | 设置单次执行超时（默认 5s） |
| `wasEvalInterrupted()` | 上次执行是否被超时熔断 |
| `hasException()` | 引擎是否处于异常状态 |
| `setCanBlock(bool)` | 是否允许阻塞调用 |
| `setUncatchableException(bool)` | 异常是否可被外部 catch |

### 4.3 内存与 GC

| 方法 | 说明 |
|------|------|
| `runGc()` | 手动触发 `JS_RunGC` |
| `resetCryptoStats()` | 重置加密调用统计 |

### 4.4 Promise 监控

| 方法 | 说明 |
|------|------|
| `promiseState(String varName)` | 查询全局变量的 Promise 状态 |

返回值：`0`=非 Promise，`1`=pending，`2`=fulfilled，`3`=rejected

### 4.5 原生函数（全局）

`quickjs_runtime.dart` 还导出以下全局原生函数，供 `js_engine.dart` 注册到 QuickJS 全局作用域：

| 函数 | 说明 |
|------|------|
| `nativeAesEncrypt(data, key, iv)` | AES 加密（C 原生 `crypto/aes.c`） |
| `nativeAesDecrypt(cipherB64, key, iv)` | AES 解密（Base64 输入） |
| `nativeHtmlQueryExtract(html, selector, attr, listMode)` | lexbor C 层 HTML 查询（`@CSS:` 规则走此路径） |
| `nativeUnescapeHtml(input)` | HTML 实体反转义 |
| `nativeUrlEncode(input)` / `nativeUrlDecode(input)` | URL 编解码 |
| `nativeCharsetUrlEncode(input, charset)` | 指定字符集的 URL 编码 |
| `nativeGetCpuCount()` | CPU 核数（FFI 健康检查用） |
| `nativeDetectModule(input)` | 检测是否为 ES Module |

---

## 五、调试流程建议

1. **选好入口**：根据想调试的阶段选择 key 格式
   - 想测搜索 → 直接输入关键字
   - 想测详情 → 输入书籍 URL
   - 想测目录 → `++目录页URL`
   - 想测正文 → `--正文页URL`
   - 想测发现 → `分类名::URL`
2. **观察日志流**：「调试」标签页实时输出，关注 `error`(-1) 状态的行
3. **查看源码**：每阶段完成后，对应源码已缓存，可切到「源码」查看 HTML 是否符合预期
4. **链式推进**：搜索成功后会自动进入详情→目录→正文，任一环节失败会以 `error` 终止
5. **排查 JS 桥接**：若 `java.ajax/get/post` 返回空，检查书源的 `header`/`charset` 配置；JS 侧抛 `__NEED_NETWORK__` 表示同步模式下未预缓存该 URL

---

## 六、规则语法参考

> 完整规则语法见 [book_source_help.md](book_source_help.md) | 书写指南见 [book_source_guide.md](book_source_guide.md) | JS API 见 [book_source_js_help.md](book_source_js_help.md)

### CSS 选择器
```
class.book-list          // class 选择器
tag.div                  // 标签选择器
class.book-list@tag.li   // 子元素选择
tag.h3@text              // 获取文本
tag.a@href               // 获取属性
tag.p.0@text             // 获取第一个 p 标签
tag.p.-1@text            // 获取最后一个
tag.p[0:3]@text          // 切片
```

### JSONPath
```
$.data.list              // 获取 data.list
$.data.books             // 获取数组
$.name                   // 获取字段
$.data.list.*.name       // 通配
$[?(@.type==1)]          // 过滤器
```

### XPath
```
//div[@class='book-list']/ul/li
.//h3/a/text()
.//a/@href
```

### JavaScript
```
:result.match(/name":"([^"]*)"/)?.[1] || ''
@js:const items = result.match(/.+?/g); JSON.stringify(items);
```
