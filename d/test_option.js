// 测试 _JsoupLite 对 <option> 的解析
// 模拟 nextTocUrl 的实际执行

var html = '<div class="listpage"><span class="middle"><select name="pageselect"><option value="/book/164033/" selected="selected">第1-20章</option><option value="/164/164033_2/">第21-40章</option><option value="/164/164033_3/">第41-60章</option><option value="/164/164033_4/">第61-80章</option></select></span></div>';

var options = select(html, "option");
console.log("option count: " + options.length);

for (var i = 0; i < options.length; i++) {
  var val = getAttr(options[i], "", "value");
  var text = selectFirst(options[i], "");
  console.log("option[" + i + "]: value=" + val + " text=" + text);
}

// 测试 nextTocUrl 逻辑
var urls = [];
for (var i = 0; i < options.length; i++) {
  var val = getAttr(options[i], "", "value") || "";
  if (val && urls.indexOf(val) < 0) urls.push(val);
}
console.log("nextTocUrl result: " + JSON.stringify(urls));
