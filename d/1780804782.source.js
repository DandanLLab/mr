// @name 大唐小说网
// @url https://www.dtxsw.com
// @group 小说
// @type 0
// @searchUrl /search.php?q={{key}}&p={{page}}
// @exploreUrl [{"title":"玄幻","url":"/list1/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}},{"title":"武侠","url":"/list2/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}},{"title":"都市","url":"/list3/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}},{"title":"历史","url":"/list4/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}},{"title":"网游","url":"/list5/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}},{"title":"科幻","url":"/list6/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}},{"title":"言情","url":"/list7/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}},{"title":"其他","url":"/list8/{{page}}.html","style":{"layout_flexBasisPercent":0.2,"layout_flexGrow":1}}]

// ===== 搜索 =====
function search(key, page, result) {
  var html = result;
  var items = select(html, ".row:nth-child(2) > .col-12");
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];

    var nameRaw = selectFirst(item, "h3 > a");
    var name = nameRaw ? nameRaw.replace(/\[.*\]/, "").trim() : "";

    var tagMatch = nameRaw ? nameRaw.match(/\[(.*)\]/) : null;
    var tag = tagMatch ? tagMatch[1] : "";

    var author = selectFirst(item, ".book_other:nth-child(3)");
    author = author ? author.replace(/作者：?/, "").trim() : "";

    var bookUrl = getAttr(item, "h3 > a", "href");
    var coverUrl = getAttr(item, "img", "src");

    var status = selectFirst(item, ".book_other:nth-child(4)");
    status = status ? status.replace(/[\u4e00-\u9fa5]+：/g, "").trim() : "";
    var updateTime = selectFirst(item, ".book_other:nth-child(5)");
    updateTime = updateTime ? updateTime.replace(/[\u4e00-\u9fa5]+：/g, "").trim() : "";
    var kind = [tag, status, updateTime].filter(function(x) { return x; }).join(",");

    var lastChapter = selectFirst(item, ".book_other:nth-child(6)");
    lastChapter = lastChapter ? lastChapter.replace(/[\u4e00-\u9fa5]+：/g, "").trim() : "";

    results.push({
      name: name,
      author: author,
      bookUrl: bookUrl,
      coverUrl: coverUrl,
      kind: kind,
      lastChapter: lastChapter,
      intro: ""
    });
  }

  return results;
}

// ===== 发现 =====
function explore(baseUrl, result) {
  var html = result;
  var items = select(html, ".row .col-12");
  var results = [];

  for (var i = 0; i < items.length; i++) {
    var item = items[i];

    var nameRaw = selectFirst(item, "h3 > a");
    var name = nameRaw ? nameRaw.replace(/\[.*\]/, "").trim() : "";

    var tagMatch = nameRaw ? nameRaw.match(/\[(.*)\]/) : null;
    var tag = tagMatch ? tagMatch[1] : "";

    var author = selectFirst(item, ".book_other:nth-child(3)");
    author = author ? author.replace(/作者：?/, "").trim() : "";

    var bookUrl = getAttr(item, "h3 > a", "href");
    var coverUrl = getAttr(item, "img", "src");

    var status = selectFirst(item, ".book_other:nth-child(4)");
    status = status ? status.replace(/[\u4e00-\u9fa5]+：/g, "").trim() : "";
    var updateTime = selectFirst(item, ".book_other:nth-child(5)");
    updateTime = updateTime ? updateTime.replace(/[\u4e00-\u9fa5]+：/g, "").trim() : "";
    var kind = [tag, status, updateTime].filter(function(x) { return x; }).join(",");

    var lastChapter = selectFirst(item, ".book_other:nth-child(6)");
    lastChapter = lastChapter ? lastChapter.replace(/[\u4e00-\u9fa5]+：/g, "").trim() : "";

    results.push({
      name: name,
      author: author,
      bookUrl: bookUrl,
      coverUrl: coverUrl,
      kind: kind,
      lastChapter: lastChapter
    });
  }

  return results;
}

// ===== 书籍详情 =====
function bookInfo(result) {
  var html = result;

  var name = getAttr(html, "[property$=book_name]", "content") || "";
  var author = getAttr(html, "[property$=author]", "content") || "";
  var intro = getAttr(html, "[property$=description]", "content") || "";

  // 简介分段：在句号/问号后加换行
  intro = intro.replace(/(^|[。！？]+["」）】]?)/g, "$1\n");

  var kind = select(html, "[property~=category|status|update_time]")
    .map(function(el) { return getAttr(el, "", "content"); })
    .filter(function(x) { return x; })
    .join(",");

  return {
    name: name,
    author: author,
    coverUrl: "",
    intro: intro,
    kind: kind,
    lastChapter: "",
    tocUrl: "",
    wordCount: ""
  };
}

// ===== 章节目录 =====
function toc(result) {
  var html = result;
  var links = select(html, ".book_list2 .col-md-3 > a");
  var chapters = [];

  for (var i = 0; i < links.length; i++) {
    var link = links[i];
    var name = selectFirst(link, "a") || link;
    if (typeof name !== "string") name = name.toString();
    name = name.trim();

    var chapterUrl = getAttr(link, "a", "href");

    chapters.push({
      name: name,
      url: chapterUrl,
      isVolume: false
    });
  }

  return chapters;
}

// ===== 目录下一页 =====
// 原始规则: .page-item.4@a@href → 提取最大页码 → 生成所有分页URL
function nextTocUrl(result) {
  var html = result;
  var maxPage = 1;

  // 从分页链接中找最大页码
  var pageLinks = select(html, ".page-item a");
  for (var i = 0; i < pageLinks.length; i++) {
    var href = getAttr(pageLinks[i], "a", "href") || "";
    var match = href.match(/index_(\d+)\.html/);
    if (match) {
      var n = parseInt(match[1], 10);
      if (n > maxPage) maxPage = n;
    }
  }

  if (maxPage <= 1) return [];

  // 生成第2页到最后一页的URL
  var list = [];
  for (var i = 2; i <= maxPage; i++) {
    list.push("index_" + i + ".html");
  }
  return list;
}

// ===== 正文内容 =====
function content(result) {
  var html = result;
  var text = selectFirst(html, ".font_max");

  // 去广告
  if (text) {
    text = text
      .replace(/第\(\d+\/\d+\)页/g, "")
      .replace(/dengbi\.net|dmxsw\.com|qqxsw\.com/g, "")
      .replace(/yifan\.net|shuyue\.net|epzw\.net/g, "")
      .replace(/qqwxw\.com|xsguan\.com|xs007\.com/g, "")
      .replace(/zhuike\.net|readw\.com|23zw\.cc/g, "")
      .replace(/https?:\/\/[^\s<>"]+/g, "")
      .trim();
  }

  return text || "";
}

// ===== 正文下一页 =====
// 原始规则: text.下一@href
function nextContentUrl(result) {
  var html = result;
  var links = select(html, "a");
  for (var i = 0; i < links.length; i++) {
    var text = selectFirst(links[i], "") || "";
    if (text.indexOf("下一") >= 0) {
      return getAttr(links[i], "", "href") || "";
    }
  }
  return "";
}
