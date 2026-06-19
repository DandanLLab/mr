// @name 书源名称
// @url https://www.example.com
// @group JS书源
// @type 0
// @searchUrl /search?q={{key}}&p={{page}}
var searchUrl = '/search?q={{key}}&p={{page}}';
// @exploreUrl [{"title":"分类1","url":"/category/1/{{page}}.html","style":{"layout_flexBasisPercent":0.25,"layout_flexGrow":1}}]
var exploreUrl = JSON.stringify([
  {title:"分类1", url:"/category/1/{{page}}.html", style:{layout_flexBasisPercent:0.25, layout_flexGrow:1}}
]);
// @header

// ═══════════════════════════════════════════════
//  JS 书源模板 - 纯 JS 原生书源格式 (.source.js)
// ═══════════════════════════════════════════════
//
// 【元数据注释】（必须写在文件顶部）
//   @name        书源名称（必填）
//   @url         书源URL（必填）
//   @group       分组
//   @type        类型：0=文字 1=音频 2=图片 3=文件
//   @searchUrl   搜索URL模板（{{key}}=关键词 {{page}}=页码）
//   @exploreUrl  发现分类JSON
//   @header      请求头JSON
//
// 【函数参数说明】
//   search(key, page, result)    key=搜索词 page=页码 result=搜索页HTML
//   explore(baseUrl, result)     baseUrl=分类URL result=发现页HTML
//   bookInfo(result)             result=详情页HTML
//   toc(result)                  result=目录页HTML
//   content(result)              result=正文页HTML
//   nextTocUrl(result)           result=目录页HTML（可选，多页目录）
//   nextContentUrl(result)       result=正文页HTML（可选，多页正文）
//
//   注意：函数参数由框架自动注入，也可通过 globalThis 访问：
//     globalThis.key / globalThis.page / globalThis.result / globalThis.baseUrl
//
// 【返回值格式】
//   search()        → [{name, author, bookUrl, coverUrl, kind, lastChapter, intro}, ...]
//   explore()       → [{name, author, bookUrl, coverUrl, kind, lastChapter}, ...]
//   bookInfo()      → {name, author, coverUrl, intro, kind, lastChapter, tocUrl, wordCount}
//   toc()           → [{name, url, isVolume}, ...]
//   content()       → "正文文本"（纯文本或HTML）
//   nextTocUrl()    → "下一页URL" 或 ""（空字符串表示没有下一页）
//   nextContentUrl() → "下一页URL" 或 ""（空字符串表示没有下一页）
//
// 【可用API】
//   selectFirst(html, selector)             提取首个元素文本
//   select(html, selector)                  提取元素列表（返回HTML数组）
//   getAttr(html, selector, attr)           提取属性值
//   clean(html)                             清理HTML标签
//   put(key, value) / getStr(key)           变量存取
//   base64Encode/Decode(str)                Base64编解码
//   md5Encode(str) / sha256Encode(str)      哈希
//   aesEncode(data, key, iv) / aesDecode(data, key, iv)  AES加解密
//   CryptoJS.AES/MD5/SHA256/HmacSHA256      加密库
//   console.log/warn/error/info             日志输出（调试用，不影响结果）
//   JSON.parse/stringify                    JSON操作
//   fetch(url) / fetch(url, {method:'POST',body})  HTTP请求
//
// 【调试技巧】
//   1. 在函数开头加 _JsoupLite._debug = true; 开启CSS选择器调试日志
//   2. 用 console.log("变量=", 变量) 打印调试信息，不会影响返回值
//   3. 用 JSON.stringify(对象) 查看完整对象内容

// ===== 搜索 =====
function search(key, page, result) {
  var html = result;
  // 替换为实际网站的CSS选择器
  var items = select(html, ".book-list > .item");
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    results.push({
      name: selectFirst(item, ".book-name") || "",
      author: selectFirst(item, ".author") || "",
      bookUrl: getAttr(item, "a.title", "href") || "",
      coverUrl: getAttr(item, "img.cover", "src") || "",
      kind: selectFirst(item, ".tag") || "",
      lastChapter: selectFirst(item, ".latest") || "",
      intro: selectFirst(item, ".intro") || ""
    });
  }

  return results;
}

// ===== 发现 =====
function explore(baseUrl, result) {
  var html = result;
  // 替换为实际网站的CSS选择器
  var items = select(html, ".book-list > .item");
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    results.push({
      name: selectFirst(item, ".book-name") || "",
      author: selectFirst(item, ".author") || "",
      bookUrl: getAttr(item, "a.title", "href") || "",
      coverUrl: getAttr(item, "img.cover", "src") || "",
      kind: selectFirst(item, ".tag") || "",
      lastChapter: selectFirst(item, ".latest") || ""
    });
  }

  return results;
}

// ===== 书籍详情 =====
function bookInfo(result) {
  var html = result;

  return {
    name: selectFirst(html, "h1.book-title") || "",
    author: selectFirst(html, ".author-name") || "",
    coverUrl: getAttr(html, "img.cover", "src") || "",
    intro: selectFirst(html, ".book-intro") || "",
    kind: selectFirst(html, ".book-category") || "",
    lastChapter: selectFirst(html, ".latest-chapter") || "",
    tocUrl: "",
    wordCount: ""
  };
}

// ===== 章节目录 =====
function toc(result) {
  var html = result;
  // 替换为实际网站的CSS选择器
  // 注意：select 返回的是 HTML 字符串数组，不是 DOM 节点
  // 对每个 item 用 selectFirst(item, "a") 取文本，getAttr(item, "a", "href") 取链接
  var items = select(html, ".chapter-list li");
  var chapters = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];
    chapters.push({
      name: selectFirst(item, "a") || "",
      url: getAttr(item, "a", "href") || "",
      isVolume: false
    });
  }

  return chapters;
}

// ===== 目录下一页（可选，没有多页目录可删除）=====
function nextTocUrl(result) {
  var html = result;
  // 方式1：从分页链接提取
  var next = getAttr(html, "a.next-page", "href") || "";
  // 方式2：从下拉框提取（如 <option value="/book/xxx_2/">第21-40章</option>）
  // var options = select(html, "option");
  // for (var i = 0; i < options.length; i++) {
  //   var val = getAttr(options[i], "", "value") || "";
  //   if (val && !val.match(/\/\d+\/$/)) return val;
  // }
  return next;
}

// ===== 正文内容 =====
function content(result) {
  var html = result;
  // 替换为实际网站的CSS选择器
  var text = selectFirst(html, "#content");
  if (text) {
    text = text
      .replace(/.*最新网址.*/g, "")
      .replace(/上一章|下一章|返回目录|加入书签|下一页|上一页/g, "")
      .replace(/.*本章未完.*/g, "")
      .trim();
  }
  return text || "";
}

// ===== 正文下一页（可选，没有多页正文可删除）=====
function nextContentUrl(result) {
  var html = result;
  var links = select(html, "a");
  for (var i = 0; i < links.length; i++) {
    var text = selectFirst(links[i], "") || "";
    if (text.indexOf("下一页") >= 0) {
      return getAttr(links[i], "", "href") || "";
    }
  }
  return "";
}
