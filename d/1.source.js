// @name 00小说网
// @url https://m.00shu.la/
// @group 写源
// @type 0
var searchUrl = JSON.stringify({
  url: '/s.php',
  body: 'searchkey={{key}}&type=articlename',
  charset: 'utf-8',
  method: 'POST'
});
var exploreUrl = JSON.stringify([
  {title:"全部🌊分类", url:null, style:{layout_flexGrow:1, layout_flexBasisPercent:1}},
  {title:"全本🌊小说", url:"/full/{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.35}},
  {title:"最新🌊入库", url:"/top/postdate_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.35}},
  {title:"玄幻奇幻", url:"/sort/1_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.25}},
  {title:"武侠仙侠", url:"/sort/2_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.25}},
  {title:"都市言情", url:"/sort/3_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.25}},
  {title:"历史军事", url:"/sort/4_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.25}},
  {title:"游戏竞技", url:"/sort/5_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.25}},
  {title:"科幻灵异", url:"/sort/6_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.25}},
  {title:"其他类型", url:"/sort/7_{{page}}/", style:{layout_flexGrow:1, layout_flexBasisPercent:0.25}}
]);
var header = JSON.stringify({
  'User-Agent': getWebViewUA(),
  'sec-ch-ua-platform': '"Android"',
  'origin': baseUrl,
  'x-requested-with': 'cn.mujiankeji.mbrowser',
  'Referer': baseUrl,
  'Accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7'
});

// ===== 搜索 =====
function search(key, page, result) {
  var html = result;
  var items = select(html, ".sone");
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];

    var name = selectFirst(item, "a:nth-child(1)") || "";
    var author = selectFirst(item, "a:nth-child(2)") || "";
    var bookUrl = getAttr(item, "a:nth-child(1)", "href") || "";

    // 封面URL: 从bookUrl提取bid，计算aid，拼接图片路径
    var coverUrl = "";
    var bidMatch = bookUrl.match(/\/(\d+)\/$/);
    if (bidMatch) {
      var bid = parseInt(bidMatch[1], 10);
      var aid = parseInt(bid / 1000, 10);
      coverUrl = "/image/" + aid + "/" + bid + "/" + bid + "s.jpg";
    }

    results.push({
      name: name,
      author: author,
      bookUrl: bookUrl,
      coverUrl: coverUrl,
      kind: "",
      lastChapter: "",
      intro: ""
    });
  }

  return results;
}

// ===== 发现 =====
function explore(baseUrl, result) {
  var html = result;
  // .article 和 .full_content 取交集
  var items1 = select(html, ".article");
  var items2 = select(html, ".full_content");
  // 取两者中较短的列表（交集逻辑）
  var items = items1.length <= items2.length ? items1 : items2;
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];

    var name = selectFirst(item, "h6 a:nth-child(1)") || selectFirst(item, "a:nth-child(1)") || "";
    var author = selectFirst(item, ".author") || selectFirst(item, ".p3") || "";
    var intro = selectFirst(item, ".simple") || "";
    var kind = selectFirst(item, ".p1") || "";
    var bookUrl = getAttr(item, "a:nth-child(1)", "href") || "";
    var coverUrl = getAttr(item, "img", "src") || "";

    results.push({
      name: name,
      author: author,
      bookUrl: bookUrl,
      coverUrl: coverUrl,
      kind: kind,
      lastChapter: ""
    });
  }

  return results;
}

// ===== 书籍详情 =====
function bookInfo(result) {
  var html = result;

  var name = getAttr(html, '[property="og:novel:book_name"]', "content") || "";
  var author = getAttr(html, '[property="og:novel:author"]', "content") || "";
  var intro = getAttr(html, '[property="og:description"]', "content") || "";
  var coverUrl = getAttr(html, '[property="og:image"]', "content") || "";
  var lastChapter = getAttr(html, "[property~=las?test_chapter_name]", "content") || "";

  // kind: status + update_time
  var kindParts = [];
  var statusEl = getAttr(html, "[property~=status]", "content");
  var updateTimeEl = getAttr(html, "[property~=update_time]", "content");
  if (statusEl) kindParts.push(statusEl);
  if (updateTimeEl) kindParts.push(updateTimeEl);
  var kind = kindParts.join(",");

  // 简介去空白
  intro = intro.replace(/\s/g, "");

  return {
    name: name,
    author: author,
    coverUrl: coverUrl,
    intro: intro,
    kind: kind,
    lastChapter: lastChapter,
    tocUrl: "",
    wordCount: ""
  };
}

// ===== 章节目录 =====
function toc(result) {
  var html = result;
  var allItems = select(html, ".list_xm li");
  var chapters = [];

  // 跳过第一个元素（!0）
  for (var i = 1; i < allItems.length; i++) {
    var item = allItems[i];
    var name = selectFirst(item, "a") || "";
    var chapterUrl = getAttr(item, "a", "href") || "";

    chapters.push({
      name: name,
      url: chapterUrl,
      isVolume: false
    });
  }

  return chapters;
}

// ===== 目录下一页 =====
// 原始规则: option@value||text.下一页@href
function nextTocUrl(result) {
  var html = result;

  // 优先: option 的 value 属性
  var options = select(html, "option");
  var urls = [];
  for (var i = 0; i < options.length; i++) {
    var val = getAttr(options[i], "", "value") || "";
    if (val && urls.indexOf(val) < 0) urls.push(val);
  }
  // 排除当前页URL（第一页通常是 /book/xxx/ 格式，不含 _2 _3 等后缀）
  urls = urls.filter(function(u) { return !u.match(/\/\d+\/$/); });
  if (urls.length > 0) return urls;

  // 备选: 文本含"下一页"的链接
  var links = select(html, "a");
  for (var j = 0; j < links.length; j++) {
    var text = selectFirst(links[j], "") || "";
    if (text.indexOf("下一页") >= 0) {
      var href = getAttr(links[j], "", "href") || "";
      if (href) return [href];
    }
  }

  return [];
}

// ===== 正文内容 =====
function content(result) {
  var html = result;
  var text = selectFirst(html, "#novelcontent");

  if (text) {
    text = text
      .replace(/.*最新网址.*/g, "")
      .replace(/.*第\d+\/\d+.*/g, "")
      .replace(/上一章|下一章|返回目录|加入书签|下一页|上一页/g, "")
      .replace(/.*本章未完.*/g, "")
      .trim();
  }

  return text || "";
}

// ===== 正文下一页 =====
// 原始规则: text.下一页@href
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
