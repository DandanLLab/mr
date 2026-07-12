# 书源规则编写指南

> 基于 Legado 规则体系的书源编写指南，字段定义与代码实现 [lib/models/book_source.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/models/book_source.dart) | 规则解析引擎 [lib/services/source_engine/analyze_rule.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_engine/analyze_rule.dart)

---

## 一、书源基础信息

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `bookSourceUrl` | String | 是 | 书源地址，作为唯一标识 |
| `bookSourceName` | String | 是 | 书源名称 |
| `bookSourceGroup` | String | 否 | 书源分组（如"动漫"、"小说"） |
| `bookSourceType` | Int | 否 | 类型：0=小说, 1=音频, 2=图片, 3=文件, 4=视频 |
| `enabled` | Bool | 否 | 是否启用，默认 true |
| `enabledExplore` | Bool | 否 | 是否启用发现，默认 true |
| `header` | String | 否 | 请求头 JSON |
| `searchUrl` | String | 否 | 搜索地址，支持 `{{key}}` `{{page}}` 变量 |
| `exploreUrl` | String | 否 | 发现地址，格式：`名称::URL`，多行用 `\n` 分隔 |
| `jsLib` | String | 否 | 公共 JS 库，可在规则中调用 |
| `bookSourceComment` | String | 否 | 书源说明 |
| `concurrentRate` | String | 否 | 并发频率限制 |
| `enabledCookieJar` | Bool | 否 | CookieJar 开关 |
| `loginUrl` | String | 否 | 登录 URL |
| `loginCheckJs` | String | 否 | 登录检查 JS |
| `customOrder` | Int | 否 | 自定义排序 |

---

## 二、URL 变量

在 `searchUrl` 和 `exploreUrl` 中可用：

| 变量 | 说明 |
|------|------|
| `{{key}}` | 搜索关键词 |
| `{{page}}` | 页码（从 0 或 1 开始，取决于书源） |
| `{{host}}` | 书源地址 |
| `{{result}}` | 上一步规则结果 |

示例：
```json
"searchUrl": "https://example.com/search?keyword={{key}}&page={{page}}"
"exploreUrl": "全部::https://example.com/list/all\n玄幻::https://example.com/list/xuanhuan"
```

---

## 三、规则语法

### 3.1 规则类型前缀

| 前缀 | 说明 | 示例 |
|------|------|------|
| `@css:` | CSS 选择器 | `@css:.book-list li` |
| `@xpath:` | XPath | `@xpath://div[@class='book']/a` |
| `@json:` | JSONPath | `@json:$.data.list` |
| `@js:` 或 `:` | JavaScript | `:result.match(/name":"([^"]*)"/)?.[1]` |
| `@ts:` | TypeScript | `@ts:(x: number) => x * 2` |
| 无前缀 | 自动判断 | 根据内容自动选择解析方式 |

### 3.2 CSS 选择器语法

#### 基本选择器
```
class.book-list        // class 选择器
tag.div                // 标签选择器
#book-id               // ID 选择器
text.章节               // 文本内容匹配
children               // 子元素
```

#### 属性获取
```
tag.a@href             // 获取 href 属性
tag.img@src            // 获取 src 属性
class.cover@data-url   // 获取 data-url 属性
```

#### 文本获取
```
tag.h1@text            // 获取文本内容（含子元素）
tag.p@ownText          // 仅自身文本（不含子元素）
class.intro@html       // 获取 HTML 内容
class.content@all      // 获取完整 HTML（含 script/style）
```

#### 子元素选择
```
class.book-list@tag.li           // 选择子元素 li
class.book-info@tag.p.0          // 选择第一个 p 标签
class.book-info@tag.p.-1         // 选择最后一个 p 标签
class.book-info@tag.p[0:3]       // 选择第 0-2 个 p 标签
class.book-info@tag.p[!0,2]      // 排除第 0 和 2 个
class.book-info@tag.p[-1:0]      // 反向选择
```

#### 链式规则

用 `##` 分隔多个步骤：
```
tag.p@text##作者：##作者:        // 获取文本后替换"作者："和"作者:"
class.intro@text##\\s+##        // 去除多余空白
```

### 3.3 JSONPath 语法

```
$.data.list           // 获取 data.list 数组
$.data.books          // 获取 data.books 数组
$.name                // 获取 name 字段
$.author              // 获取 author 字段
$.data.list.*.name    // 获取 list 数组中所有 name
$[0]                  // 数组索引
$[0:10]               // 数组切片
$..name               // 递归搜索 name
$[?(@.type==1)]       // 过滤器
```

实现：[lib/services/source_engine/legado_json_path.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_engine/legado_json_path.dart)

### 3.4 XPath 语法

```
//div[@class='book-list']/ul/li    // 选择 book-list 下的 li
.//h3/a/text()                     // 相对路径，获取文本
.//a/@href                         // 获取 href 属性
//div[@class='content']/html()     // 获取 HTML 内容
```

HTML 自动补全：`td`/`tr`/`li`/`option` 等标签自动包裹到 `<table>/<ul>/<select>` 中。

实现：[lib/services/source_engine/legado_xpath.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_engine/legado_xpath.dart)

### 3.5 正则表达式

```
<h3[^>]*>([^<]*)<\/h3>              // 匹配 h3 标签内容
作者[：:]([^<]*)                     // 匹配作者信息
<img[^>]*src="([^"]*)"             // 匹配图片 src
```

替换语法：
```
规则##正则                      // 匹配替换为空
规则##正则##替换文本             // 替换为指定文本
规则##正则##替换文本###          // 只替换第一个匹配
```

### 3.6 JavaScript 规则

```javascript
// 简单表达式
:result.match(/name":"([^"]*)"/)?.[1] || ''

// 复杂处理
:const items = result.match(/<li[^>]*>[\s\S]*?<\/li>/g) || [];
const books = items.map(item => ({
  name: item.match(/<h3>([^<]*)<\/h3>/)?.[1] || '',
  author: item.match(/作者：([^<]*)/)?.[1] || ''
}));
JSON.stringify(books);
```

---

## 四、搜索规则（ruleSearch）

| 字段 | 说明 | 示例 |
|------|------|------|
| `checkKeyWord` | 校验关键词 | `data` |
| `bookList` | 书籍列表规则 | `class.book-list@tag.li` |
| `name` | 书名规则 | `tag.h3@text` |
| `author` | 作者规则 | `tag.p.0@text##作者：` |
| `intro` | 简介规则 | `class.intro@text` |
| `kind` | 分类规则 | `tag.span.0@text` |
| `lastChapter` | 最新章节规则 | `tag.a.1@text` |
| `updateTime` | 更新时间规则 | `tag.span.1@text` |
| `bookUrl` | 书籍详情 URL 规则 | `tag.a.0@href` |
| `coverUrl` | 封面 URL 规则 | `tag.img@src` |
| `wordCount` | 字数规则 | `tag.span.2@text` |

---

## 五、发现规则（ruleExplore）

与搜索规则字段相同，用于发现页内容解析。

---

## 六、书籍信息规则（ruleBookInfo）

| 字段 | 说明 | 示例 |
|------|------|------|
| `init` | 初始化规则（JS 预处理页面） | `:js预处理代码` |
| `name` | 书名规则 | `tag.h1@text` |
| `author` | 作者规则 | `class.author@text##作者：` |
| `intro` | 简介规则 | `class.intro@text` |
| `kind` | 分类规则 | `class.category@text` |
| `lastChapter` | 最新章节规则 | `class.last-chapter@text` |
| `updateTime` | 更新时间规则 | `class.update-time@text` |
| `coverUrl` | 封面 URL 规则 | `tag.img@src` |
| `tocUrl` | 目录页 URL 规则 | `class.read-btn@href` |
| `wordCount` | 字数规则 | `class.word-count@text` |
| `canReName` | 是否可重命名 | `true` |
| `downloadUrls` | 下载地址规则 | `class.download@href` |

---

## 七、目录规则（ruleToc）

| 字段 | 说明 | 示例 |
|------|------|------|
| `preUpdateJs` | 预处理 JS | `:预处理代码` |
| `chapterList` | 章节列表规则 | `class.chapter-list@tag.li` |
| `chapterName` | 章节名称规则 | `tag.a@text` |
| `chapterUrl` | 章节 URL 规则 | `tag.a@href` |
| `formatJs` | 格式化 JS | `:格式化代码` |
| `isVolume` | 是否为卷名规则 | `tag.span@text##卷` |
| `isVip` | 是否 VIP 章节规则 | `class.vip@text` |
| `isPay` | 是否付费章节规则 | `class.pay@text` |
| `updateTime` | 更新时间规则 | `tag.time@text` |
| `nextTocUrl` | 下一页目录 URL 规则 | `class.next-page@href` |

---

## 八、正文规则（ruleContent）

| 字段 | 说明 | 示例 |
|------|------|------|
| `content` | 正文内容规则 | `class.content@html` |
| `subContent` | 备用正文规则 | `class.article@html` |
| `title` | 章节标题规则 | `tag.h1@text` |
| `nextContentUrl` | 下一页 URL 规则 | `class.next-page@href` |
| `webJs` | 网页 JS 执行 | `:JS代码` |
| `sourceRegex` | 资源正则 | `正则表达式` |
| `replaceRegex` | 替换正则 | `##<script[^>]*>.*?</script>##` |
| `imageStyle` | 图片样式 | `style="max-width:100%"` |
| `imageDecode` | 图片解码 JS | `:解码代码` |
| `payAction` | 付费动作 JS | `:付费处理代码` |
| `callBackJs` | 回调 JS | `:回调代码` |

---

## 九、完整示例

### 9.1 HTML 网站书源

```json
{
  "bookSourceUrl": "https://www.example.com",
  "bookSourceName": "示例小说站",
  "bookSourceType": 0,
  "enabled": true,
  "searchUrl": "https://www.example.com/search.php?keyword={{key}}",
  "exploreUrl": "全部::https://www.example.com/category/all\n玄幻::https://www.example.com/category/xuanhuan",
  "ruleSearch": {
    "bookList": "class.grid@tag.li",
    "name": "tag.h3@tag.a@text",
    "author": "tag.p.0@text##作者：",
    "bookUrl": "tag.h3@tag.a@href"
  },
  "ruleBookInfo": {
    "name": "class.book-name@text",
    "author": "class.author@text##作者：",
    "intro": "class.intro@text",
    "tocUrl": "class.read-btn@href"
  },
  "ruleToc": {
    "chapterList": "class.chapter-list@tag.li",
    "chapterName": "tag.a@text",
    "chapterUrl": "tag.a@href"
  },
  "ruleContent": {
    "content": "class.content@html##<script[^>]*>.*?</script>"
  }
}
```

### 9.2 JSON API 书源

```json
{
  "bookSourceUrl": "https://api.example.com",
  "bookSourceName": "API 示例",
  "bookSourceType": 0,
  "header": "{\"Content-Type\": \"application/json\"}",
  "searchUrl": "https://api.example.com/v1/search?keyword={{key}}",
  "ruleSearch": {
    "bookList": "$.data.books",
    "name": "$.name",
    "author": "$.author",
    "bookUrl": "$.url"
  },
  "ruleBookInfo": {
    "name": "$.data.name",
    "author": "$.data.author",
    "intro": "$.data.intro"
  },
  "ruleToc": {
    "chapterList": "$.data.chapters",
    "chapterName": "$.title",
    "chapterUrl": "$.url"
  },
  "ruleContent": {
    "content": "$.data.content"
  }
}
```

### 9.3 JavaScript 书源

```json
{
  "bookSourceUrl": "https://dynamic.example.com",
  "bookSourceName": "动态处理站",
  "jsLib": "function parseAuthor(str) { return str.replace(/作者[：:]/, '').trim(); }",
  "ruleSearch": {
    "bookList": ":const items = result.match(/<li[^>]*>([\\s\\S]*?)<\\/li>/g) || []; JSON.stringify(items.map(item => ({ name: item.match(/<h3>([^<]*)<\\/h3>/)[1], author: item.match(/作者[：:]([^<]*)/)[1], bookUrl: item.match(/href=\"([^\"]+)\"/)[1] })));"
  },
  "ruleContent": {
    "content": "@js:result.match(/<div class=\"content\">([\\s\\S]*?)<\\/div>/)[1];"
  }
}
```

---

## 十、调试技巧

### 浏览器开发者工具
1. F12 打开开发者工具
2. Elements 面板检查 HTML 结构
3. Console 测试 JS 表达式

### 规则测试顺序
1. 先测试 `bookList` 规则是否获取到列表
2. 再测试各字段规则（name/author/bookUrl）
3. 最后测试正文规则

### 本应用调试工具

打开书源调试页（`book_source_debug_page.dart`），进入「引擎性能统计」面板（`crypto_stats_panel.dart`）：

| 功能 | 说明 |
|------|------|
| 加密性能统计 | C 原生加密调用次数、耗时、吞吐量 |
| C 层内存监控 | 全局 malloc/free 计数、峰值 |
| JS 引擎内存 | 25 字段 `JS_ComputeMemoryUsage` 全量展示 |
| Promise 状态 | 输入变量名，显示 pending/fulfilled/rejected |
| JS 值打印 | 流式输出任意 JS 表达式 |
| 手动 GC | AppBar 按钮一键触发 `JS_RunGC` |

### 常见问题排查

| 问题 | 检查项 |
|------|--------|
| 搜索结果为空 | 检查 HTML 结构是否有动态加载内容 |
| 图片不显示 | 检查防盗链策略，可能需要配置 `header` |
| 编码乱码 | 设置 `charset` 选项为 `gbk` 等 |
| 反爬虫 | 配置正确的 `header` 和 `cookie` |
| JS 执行超时 | 默认 5 秒超时，检查死循环或过大 HTML |
| 加密结果不符 | 确认 AES 模式/填充/IV 正确，推荐用 `CryptoJS` |

> 更多帮助：[book_source_help.md](book_source_help.md) | [book_source_js_help.md](book_source_js_help.md)