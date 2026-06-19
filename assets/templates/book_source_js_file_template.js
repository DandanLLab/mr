/**
 * 纯JS书源模板
 *
 * 这是全新的书源格式，整个书源就是一个JS文件。
 * 通过函数声明定义书源的所有规则。
 *
 * 【元数据注释】（必须写在文件顶部）
 *   @name        书源名称（必填）
 *   @url         书源URL（必填）
 *   @group       分组
 *   @type        类型：0=文字 1=音频 2=图片 3=文件
 *   @searchUrl   搜索URL模板（{{key}}=关键词 {{page}}=页码）
 *   @exploreUrl  发现分类JSON
 *   @header      请求头JS代码
 *
 * 【函数参数说明】
 *   search(key, page, result)    key=搜索词 page=页码 result=搜索页HTML
 *   explore(baseUrl, result)     baseUrl=分类URL result=发现页HTML
 *   bookInfo(result)             result=详情页HTML
 *   toc(result)                  result=目录页HTML
 *   content(result)              result=正文页HTML
 *   nextTocUrl(result)           result=目录页HTML（可选，多页目录）
 *   nextContentUrl(result)       result=正文页HTML（可选，多页正文）
 *
 * 【返回值格式】
 *   search()        → [{name, author, bookUrl, coverUrl, kind, lastChapter, intro}, ...]
 *   explore()       → [{name, author, bookUrl, coverUrl, kind, lastChapter}, ...]
 *   bookInfo()      → {name, author, coverUrl, intro, kind, lastChapter, tocUrl, wordCount}
 *   toc()           → [{name, url, isVolume}, ...]
 *   content()       → "正文文本"（纯文本或HTML）
 *   nextTocUrl()    → "下一页URL" 或 ""（空字符串表示没有下一页）
 *   nextContentUrl() → "下一页URL" 或 ""（空字符串表示没有下一页）
 *
 * 【可用API】
 *   selectFirst(html, selector)             提取首个元素文本
 *   select(html, selector)                  提取元素列表（返回HTML数组）
 *   getAttr(html, selector, attr)           提取属性值
 *   clean(html)                             清理HTML标签
 *   put(key, value) / getStr(key)           变量存取
 *   base64Encode/Decode(str)                Base64编解码
 *   md5Encode(str) / sha256Encode(str)      哈希
 *   aesEncode(data, key, iv) / aesDecode(data, key, iv)  AES加解密
 *   CryptoJS.AES/MD5/SHA256/HmacSHA256      加密库
 *   console.log/warn/error/info             日志输出（调试用，不影响结果）
 *   JSON.parse/stringify                    JSON操作
 *   fetch(url) / fetch(url, {method:'POST',body})  HTTP请求
 */

// @name 书源名称
// @url https://www.example.com
// @group JS书源
// @type 0
var searchUrl = '/search?q={{key}}&p={{page}}';
var exploreUrl = JSON.stringify([
  {title:"分类1", url:"/category/1/{{page}}.html", style:{layout_flexBasisPercent:0.25, layout_flexGrow:1}}
]);

// ===== 搜索 =====
function search(key, page, result) {
  var html = result;
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
  var next = getAttr(html, "a.next-page", "href") || "";
  return next;
}

// ===== 正文内容 =====
function content(result) {
  var html = result;
  var text = selectFirst(html, "#content");
  if (text) {
    text = text
      .replace(/.*最新网址.*/g, "")
      .replace(/上一章|下一章|返回目录/g, "")
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
