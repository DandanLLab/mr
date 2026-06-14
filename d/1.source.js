// @name 00小说网
// @url https://m.00shu.la/
// @group 写源
// @type 0
// @searchUrl /s.php,{"body":"searchkey={{key}}&type=articlename","charset":"utf-8","method":"POST"}
// @exploreUrl @js:
// sort=[];
// push=(title,url,type1,type2)=>sort.push({title:title,url:url,style:{layout_flexGrow:type1,layout_flexBasisPercent:type2}});
// push("全部🌊分类",null,1,1);
// push("全本🌊小说","/full/{{page}}/",1,0.35);
// push("最新🌊入库","/top/postdate_{{page}}/",1,0.35);
// arList=["玄幻奇幻","武侠仙侠","都市言情","历史军事","游戏竞技","科幻灵异","其他类型"];
// arList.map((tag,index)=>{push(tag,"/sort/"+(index+1)+"_{{page}}/",1,0.25)});
// JSON.stringify(sort)
// @header @js:
// JSON.stringify({
//   'User-Agent': java.getWebViewUA(),
//   'sec-ch-ua-platform': '"Android"',
//   'origin': baseUrl,
//   'x-requested-with': 'cn.mujiankeji.mbrowser',
//   'Referer': baseUrl,
//   'Accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7'
// })

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
  // .list_xm!0 表示排除第一个匹配，即跳过索引0
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

  // 优先: option 的 value 属性（空选择器=从根元素取属性）
  var options = select(html, "option");
  var urls = [];
  for (var i = 0; i < options.length; i++) {
    var val = getAttr(options[i], "", "value") || "";
    if (val && urls.indexOf(val) < 0) urls.push(val);
  }
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
