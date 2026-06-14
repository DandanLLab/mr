// _JsoupLite CSS 选择器引擎测试
// 从 js_engine.dart 中提取的 _JsoupLite 完整代码 + 测试逻辑

var _javaCache = {};

var _JsoupLite = {
  _voidElements: ['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'],
  _debug: true,
  _log: function(msg) { if (_JsoupLite._debug) console.log('[JsoupLite] ' + msg); },
  _hashStr: function(s) {
    var h = 0;
    for (var i = 0; i < s.length; i++) {
      h = ((h << 5) - h + s.charCodeAt(i)) | 0;
    }
    return h;
  },
  _cacheKey: function(prefix, selector, html) {
    return prefix + ':' + selector + ':' + _JsoupLite._hashStr(html || '');
  },
  // 栈式 HTML 解析器，正确处理 void 元素和文本
  _parseHtml: function(html) {
    if (!html) return [];
    var nodes = [];
    var tagRe = /<([\/!]?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^>]*?)?)(\/?)>/g;
    var lastIdx = 0;
    var stack = [];
    var m;
    while ((m = tagRe.exec(html)) !== null) {
      // 文本节点
      if (m.index > lastIdx) {
        var txt = html.substring(lastIdx, m.index);
        if (stack.length > 0) {
          stack[stack.length - 1].childNodes.push({type: 'text', text: txt});
        }
      }
      lastIdx = m.index + m[0].length;
      var isClose = m[1] === '/';
      var tagName = m[2].toLowerCase();
      var attrStr = m[3] || '';
      var isSelfClose = m[4] === '/';
      // 跳过注释和 <!DOCTYPE>
      if (m[1] === '!' || tagName === '!doctype') continue;
      if (isClose) {
        // 弹栈，找到匹配的开标签
        var found = -1;
        for (var si = stack.length - 1; si >= 0; si--) {
          if (stack[si].tag === tagName) { found = si; break; }
        }
        if (found >= 0) {
          var closed = stack.splice(found)[0];
          if (found > 0 && stack.length > 0) {
            stack[found - 1].childNodes.push(closed);
          } else {
            nodes.push(closed);
          }
        }
        continue;
      }
      // 解析属性
      var attrs = {};
      var attrRe = /([a-zA-Z_][\w-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|(\S+)))?/g;
      var am;
      while ((am = attrRe.exec(attrStr)) !== null) {
        attrs[am[1].toLowerCase()] = am[2] !== undefined ? am[2] : (am[3] !== undefined ? am[3] : (am[4] !== undefined ? am[4] : ''));
      }
      var node = {tag: tagName, attrs: attrs, childNodes: [], parent: stack.length > 0 ? stack[stack.length - 1] : null};
      // void 元素或自闭合标签不入栈
      if (isSelfClose || _JsoupLite._voidElements.indexOf(tagName) >= 0) {
        if (stack.length > 0) {
          stack[stack.length - 1].childNodes.push(node);
        } else {
          nodes.push(node);
        }
      } else {
        stack.push(node);
      }
    }
    // 处理栈中剩余节点
    while (stack.length > 0) {
      var remaining = stack.pop();
      if (stack.length > 0) {
        stack[stack.length - 1].childNodes.push(remaining);
      } else {
        nodes.push(remaining);
      }
    }
    return nodes;
  },
  // 获取元素子节点（不含文本节点）
  _elementChildren: function(node) {
    if (!node || !node.childNodes) return [];
    return node.childNodes.filter(function(c) { return c.tag; });
  },
  // 获取文本内容（递归）
  _getText: function(node) {
    if (!node) return '';
    if (node.type === 'text') return node.text || '';
    if (!node.childNodes) return '';
    var text = '';
    for (var i = 0; i < node.childNodes.length; i++) {
      text += _JsoupLite._getText(node.childNodes[i]);
    }
    return text;
  },
  // 获取 outerHtml（递归重建）
  _getOuterHtml: function(node) {
    if (!node) return '';
    if (node.type === 'text') return node.text || '';
    var html = '<' + node.tag;
    for (var key in node.attrs) {
      html += ' ' + key + '="' + (node.attrs[key] || '').replace(/"/g, '&quot;') + '"';
    }
    html += '>';
    if (_JsoupLite._voidElements.indexOf(node.tag) >= 0) return html;
    for (var i = 0; i < node.childNodes.length; i++) {
      html += _JsoupLite._getOuterHtml(node.childNodes[i]);
    }
    html += '</' + node.tag + '>';
    return html;
  },
  // 拆分选择器中的伪类
  _splitPseudo: function(sel) {
    var m = sel.match(/^(.+?):(nth-child|nth-of-type)\((.+)\)$/);
    if (m) return {base: m[1], pseudo: m[2], expr: m[3]};
    return {base: sel, pseudo: null, expr: null};
  },
  // 匹配基础选择器（不含伪类）
  _matchesBase: function(node, selector) {
    if (!node || !node.tag) return false;
    var sel = selector.trim();
    // #id
    if (sel.startsWith('#') && sel.indexOf('.') < 0 && sel.indexOf('[') < 0) {
      return node.attrs['id'] === sel.substring(1);
    }
    // [attr$=val] 裸属性选择器
    var bareAttr = sel.match(/^\[([a-zA-Z_][\w-]*)([$^*]?=)["']?([^"'\]]*)["']?\]$/);
    if (bareAttr) {
      var val = node.attrs[bareAttr[1].toLowerCase()] || '';
      var op = bareAttr[2], bv = bareAttr[3];
      if (op === '=') return val === bv;
      if (op === '$=') return val.endsWith(bv);
      if (op === '^=') return val.startsWith(bv);
      if (op === '*=') return val.indexOf(bv) >= 0;
      return false;
    }
    // tag[attr$=val]
    var tagAttr = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)\[([a-zA-Z_][\w-]*)([$^*]?=)["']?([^"'\]]*)["']?\]$/);
    if (tagAttr) {
      if (node.tag !== tagAttr[1].toLowerCase()) return false;
      var av = node.attrs[tagAttr[2].toLowerCase()] || '';
      var aop = tagAttr[3], aval = tagAttr[4];
      if (aop === '=') return av === aval;
      if (aop === '$=') return av.endsWith(aval);
      if (aop === '^=') return av.startsWith(aval);
      if (aop === '*=') return av.indexOf(aval) >= 0;
      return false;
    }
    // tag.class
    var tagCls = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)\.([a-zA-Z_-][\w-]*)$/);
    if (tagCls) {
      if (node.tag !== tagCls[1].toLowerCase()) return false;
      var nc = (node.attrs['class'] || '').split(/\s+/);
      return nc.indexOf(tagCls[2]) >= 0;
    }
    // tag#id
    var tagId = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)#([a-zA-Z_-][\w-]*)$/);
    if (tagId) {
      return node.tag === tagId[1].toLowerCase() && node.attrs['id'] === tagId[2];
    }
    // .class（支持多类 .c1.c2）
    if (sel.startsWith('.')) {
      var classes = sel.substring(1).split('.');
      var nodeClasses = (node.attrs['class'] || '').split(/\s+/);
      for (var i = 0; i < classes.length; i++) {
        if (classes[i] && nodeClasses.indexOf(classes[i]) < 0) return false;
      }
      return true;
    }
    // 纯 tag
    if (/^[a-zA-Z][a-zA-Z0-9]*$/.test(sel)) {
      return node.tag === sel.toLowerCase();
    }
    return false;
  },
  // 解析 nth-child 表达式
  _resolveNth: function(expr, idx) {
    expr = expr.trim().replace(/\s+/g, '');
    if (expr === String(idx)) return true;
    if (expr === 'odd') return idx % 2 === 1;
    if (expr === 'even') return idx % 2 === 0;
    var m = expr.match(/^(-?\d*)n([+-]\d+)?$/);
    if (m) {
      var a = m[1] === '' ? 1 : (m[1] === '-' ? -1 : parseInt(m[1]));
      var b = m[2] ? parseInt(m[2]) : 0;
      if (a === 0) return idx === b;
      var n = (idx - b) / a;
      return n >= 0 && n === Math.floor(n);
    }
    return false;
  },
  // 核心查询：在节点树中查找匹配选择器的所有元素
  _queryAll: function(nodes, selector, depth) {
    depth = depth || 0;
    if (depth > 30 || !nodes) return [];
    var results = [];

    // 处理逗号分隔的多选择器
    if (selector.indexOf(',') >= 0 && selector.indexOf('(') < 0) {
      var sels = selector.split(',');
      for (var si = 0; si < sels.length; si++) {
        var r = _JsoupLite._queryAll(nodes, sels[si].trim(), depth + 1);
        for (var ri = 0; ri < r.length; ri++) {
          if (results.indexOf(r[ri]) < 0) results.push(r[ri]);
        }
      }
      return results;
    }

    // 处理子选择器 (> combinator)
    if (selector.indexOf(' > ') >= 0) {
      var childParts = selector.split(/\s*>\s*/);
      // 关键修复：第一步用后代搜索（_queryAll 递归查找），不是只看直接子元素
      // 例如 ".row:nth-child(2) > .col-12" 中 .row 可能嵌套在 html>body>div 下
      var current = _JsoupLite._queryAll(nodes, childParts[0].trim(), depth + 1);
      // 后续步骤：在匹配元素的直接子元素中查找
      for (var cp = 1; cp < childParts.length; cp++) {
        var partSel = childParts[cp].trim();
        var next = [];
        for (var ci = 0; ci < current.length; ci++) {
          var elChildren = _JsoupLite._elementChildren(current[ci]);
          var matched = _JsoupLite._filterBySelector(elChildren, partSel, current[ci]);
          next = next.concat(matched);
        }
        current = next;
      }
      return current;
    }

    // 处理后代选择器 (空格分隔)
    var parts = selector.split(/\s+/);
    if (parts.length > 1) {
      var cur = nodes;
      for (var pi = 0; pi < parts.length; pi++) {
        var pSel = parts[pi].trim();
        if (!pSel) continue;
        var found = _JsoupLite._queryAll(cur, pSel, depth + 1);
        if (pi < parts.length - 1) {
          // 收集所有后代
          var desc = [];
          for (var fi = 0; fi < found.length; fi++) {
            _JsoupLite._collectAllElements(found[fi], desc);
          }
          cur = desc;
        } else {
          cur = found;
        }
      }
      return cur;
    }

    // 单一选择器：深度优先遍历
    var sp = _JsoupLite._splitPseudo(selector);
    for (var ni = 0; ni < nodes.length; ni++) {
      var node = nodes[ni];
      if (!node.tag) continue;
      if (_JsoupLite._matchesBase(node, sp.base)) {
        if (sp.pseudo) {
          var parent = node.parent;
          if (parent) {
            var siblings = _JsoupLite._elementChildren(parent);
            if (sp.pseudo === 'nth-child') {
              // CSS 规范：:nth-child 计数所有兄弟元素，不只是匹配基础选择器的
              var pos = 0;
              for (var si2 = 0; si2 < siblings.length; si2++) {
                pos++;
                if (siblings[si2] === node) {
                  if (_JsoupLite._resolveNth(sp.expr, pos)) results.push(node);
                  break;
                }
              }
            } else if (sp.pseudo === 'nth-of-type') {
              // :nth-of-type 计数同类型（同标签名）的兄弟元素
              var pos2 = 0;
              for (var si3 = 0; si3 < siblings.length; si3++) {
                if (siblings[si3].tag === node.tag) {
                  pos2++;
                  if (siblings[si3] === node) {
                    if (_JsoupLite._resolveNth(sp.expr, pos2)) results.push(node);
                    break;
                  }
                }
              }
            }
          } else {
            results.push(node);
          }
        } else {
          results.push(node);
        }
      }
      // 递归搜索子节点
      var childResults = _JsoupLite._queryAll(_JsoupLite._elementChildren(node), selector, depth + 1);
      results = results.concat(childResults);
    }
    return results;
  },
  // 在同级元素中按选择器过滤（含伪类）
  _filterBySelector: function(elements, selector, parent) {
    var sp = _JsoupLite._splitPseudo(selector);
    var matched = [];
    if (sp.pseudo === 'nth-child') {
      // CSS 规范：:nth-child 计数所有兄弟元素
      var pos = 0;
      for (var i = 0; i < elements.length; i++) {
        pos++;
        if (_JsoupLite._matchesBase(elements[i], sp.base)) {
          if (_JsoupLite._resolveNth(sp.expr, pos)) {
            matched.push(elements[i]);
          }
        }
      }
    } else if (sp.pseudo === 'nth-of-type') {
      // :nth-of-type 计数同类型（同标签名）的兄弟元素
      var typePos = {};
      for (var j = 0; j < elements.length; j++) {
        var tag = elements[j].tag || '';
        if (!typePos[tag]) typePos[tag] = 0;
        typePos[tag]++;
        if (_JsoupLite._matchesBase(elements[j], sp.base)) {
          if (_JsoupLite._resolveNth(sp.expr, typePos[tag])) {
            matched.push(elements[j]);
          }
        }
      }
    } else {
      for (var k = 0; k < elements.length; k++) {
        if (_JsoupLite._matchesBase(elements[k], sp.base)) {
          matched.push(elements[k]);
        }
      }
    }
    return matched;
  },
  // 收集节点下所有元素（深度优先）
  _collectAllElements: function(node, arr) {
    if (!node || !node.childNodes) return;
    var children = _JsoupLite._elementChildren(node);
    for (var i = 0; i < children.length; i++) {
      arr.push(children[i]);
      _JsoupLite._collectAllElements(children[i], arr);
    }
  },
  // ===== 公共 API =====
  selectFirst: function(html, selector) {
    var key = _JsoupLite._cacheKey('jsoup_sf', selector, html);
    if (_javaCache[key] !== undefined) return _javaCache[key];
    var nodes = _JsoupLite._parseHtml(html);
    var found = _JsoupLite._queryAll(nodes, selector, 0);
    var result = found.length > 0 ? _JsoupLite._getText(found[0]) : '';
    _JsoupLite._log('selectFirst("' + selector + '") => ' + (result.length > 80 ? result.substring(0, 80) + '...' : result || '(empty)'));
    return result;
  },
  selectAll: function(html, selector) {
    var key = _JsoupLite._cacheKey('jsoup_sa', selector, html);
    if (_javaCache[key] !== undefined) return _javaCache[key];
    var nodes = _JsoupLite._parseHtml(html);
    var found = _JsoupLite._queryAll(nodes, selector, 0);
    var result = found.map(function(n) { return _JsoupLite._getOuterHtml(n); });
    _JsoupLite._log('selectAll("' + selector + '") => ' + result.length + ' elements');
    return result;
  },
  getAttr: function(html, selector, attr) {
    var key = _JsoupLite._cacheKey('jsoup_ga', selector + ':' + attr, html);
    if (_javaCache[key] !== undefined) return _javaCache[key];
    var nodes = _JsoupLite._parseHtml(html);
    var found = _JsoupLite._queryAll(nodes, selector, 0);
    var result = found.length > 0 ? (found[0].attrs[attr] || '') : '';
    _JsoupLite._log('getAttr("' + selector + '", "' + attr + '") => ' + (result || '(empty)'));
    return result;
  }
};

// ===== 测试逻辑 =====

var testHtml = '<!DOCTYPE html>\n' +
'<html>\n' +
'<body>\n' +
'<div class="container">\n' +
'  <div class="row">\n' +
'    <div class="col-12">第一行内容</div>\n' +
'  </div>\n' +
'  <div class="row">\n' +
'    <div class="col-12">\n' +
'      <h3><a href="/book/123.html">[玄幻]大唐双龙传</a></h3>\n' +
'      <div class="book_other">作者：黄易</div>\n' +
'      <div class="book_other">状态：完结</div>\n' +
'      <div class="book_other">更新：2024-01-01</div>\n' +
'      <div class="book_other">最新：第100章</div>\n' +
'    </div>\n' +
'    <div class="col-12">\n' +
'      <h3><a href="/book/456.html">[武侠]大唐行歌</a></h3>\n' +
'      <div class="book_other">作者：某某</div>\n' +
'    </div>\n' +
'  </div>\n' +
'</div>\n' +
'</body>\n' +
'</html>';

var passCount = 0;
var failCount = 0;

function assert(condition, testName, detail) {
  if (condition) {
    passCount++;
    console.log('  ✅ PASS: ' + testName + (detail ? ' => ' + detail : ''));
  } else {
    failCount++;
    console.log('  ❌ FAIL: ' + testName + (detail ? ' => ' + detail : ''));
  }
}

console.log('========================================');
console.log('  _JsoupLite CSS 选择器引擎测试');
console.log('========================================');

// 测试1: selectAll - .row:nth-child(2) > .col-12:nth-child(n+1)
console.log('\n--- 测试1: selectAll(".row:nth-child(2) > .col-12:nth-child(n+1)") ---');
var result1 = _JsoupLite.selectAll(testHtml, '.row:nth-child(2) > .col-12:nth-child(n+1)');
assert(result1.length === 2, '应返回 2 个元素', '实际返回 ' + result1.length + ' 个');
for (var i = 0; i < result1.length; i++) {
  console.log('  [' + i + '] ' + result1[i].substring(0, 120) + (result1[i].length > 120 ? '...' : ''));
}

// 测试2: selectFirst - h3 > a
console.log('\n--- 测试2: selectFirst("h3 > a") ---');
var result2 = _JsoupLite.selectFirst(testHtml, 'h3 > a');
assert(result2.length > 0, '应返回非空文本', '实际返回 "' + result2 + '"');
assert(result2.indexOf('大唐双龙传') >= 0, '应包含"大唐双龙传"', '实际文本 "' + result2 + '"');

// 测试3: getAttr - h3 > a 的 href
console.log('\n--- 测试3: getAttr("h3 > a", "href") ---');
var result3 = _JsoupLite.getAttr(testHtml, 'h3 > a', 'href');
assert(result3 === '/book/123.html', '应返回 "/book/123.html"', '实际返回 "' + result3 + '"');

// 测试4: 额外验证 - selectAll 获取所有 h3 > a
console.log('\n--- 测试4: selectAll("h3 > a") ---');
var result4 = _JsoupLite.selectAll(testHtml, 'h3 > a');
assert(result4.length === 2, '应返回 2 个 <a> 元素', '实际返回 ' + result4.length + ' 个');

// 测试5: getAttr 获取第二个 h3 > a 的 href
console.log('\n--- 测试5: getAttr 第二个 h3 > a 的 href ---');
var nodes5 = _JsoupLite._parseHtml(testHtml);
var found5 = _JsoupLite._queryAll(nodes5, 'h3 > a', 0);
if (found5.length >= 2) {
  var href5 = found5[1].attrs['href'] || '';
  assert(href5 === '/book/456.html', '第二个 a 的 href 应为 "/book/456.html"', '实际为 "' + href5 + '"');
} else {
  failCount++;
  console.log('  ❌ FAIL: 找到的 h3 > a 不足 2 个');
}

// 测试6: .book_other 选择器
console.log('\n--- 测试6: selectAll(".book_other") ---');
var result6 = _JsoupLite.selectAll(testHtml, '.book_other');
assert(result6.length === 5, '应返回 5 个 .book_other 元素', '实际返回 ' + result6.length + ' 个');

// 测试7: .row:nth-child(1) > .col-12
console.log('\n--- 测试7: selectAll(".row:nth-child(1) > .col-12") ---');
var result7 = _JsoupLite.selectAll(testHtml, '.row:nth-child(1) > .col-12');
assert(result7.length === 1, '应返回 1 个元素', '实际返回 ' + result7.length + ' 个');

// 汇总
console.log('\n========================================');
console.log('  测试结果: ' + passCount + ' 通过, ' + failCount + ' 失败');
console.log('========================================');
