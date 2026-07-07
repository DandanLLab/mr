// ===== _JsoupLite — 纯 JS CSS 选择器引擎 =====
// 提取自 js_engine.dart 内联代码，提供 legado Jsoup 兼容的 HTML 解析
// 支持: tag / .class / #id / [attr] / [attr=val] / 后代 / 子代 / 伪类 / 多选择器

var _JsoupLite = {
  _voidElements: ['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'],
  _autoCloseTags: ['option','optgroup','li','tr','td','th','dt','dd','p','rt','rp'],
  _debug: false,
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
  _parseHtml: function(html) {
    if (!html) return [];
    var nodes = [];
    var tagRe = /<([\/!]?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^>]*?)?)(\/?)>/g;
    var lastIdx = 0;
    var stack = [];
    var m;
    while ((m = tagRe.exec(html)) !== null) {
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
      if (m[1] === '!' || tagName === '!doctype') continue;
      if (isClose) {
        var found = -1;
        for (var si = stack.length - 1; si >= 0; si--) {
          if (stack[si].tag === tagName) { found = si; break; }
        }
        if (found >= 0) {
          while (stack.length > found + 1) {
            var orphan = stack.pop();
            stack[found].childNodes.push(orphan);
          }
          var closed = stack.pop();
          if (stack.length > 0) {
            stack[stack.length - 1].childNodes.push(closed);
          } else {
            nodes.push(closed);
          }
        }
        continue;
      }
      var attrs = {};
      var attrRe = /([a-zA-Z_][\w-]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|(\S+)))?/g;
      var am;
      while ((am = attrRe.exec(attrStr)) !== null) {
        attrs[am[1].toLowerCase()] = am[2] !== undefined ? am[2] : (am[3] !== undefined ? am[3] : (am[4] !== undefined ? am[4] : ''));
      }
      var node = {tag: tagName, attrs: attrs, childNodes: [], parent: stack.length > 0 ? stack[stack.length - 1] : null};
      if (isSelfClose || _JsoupLite._voidElements.indexOf(tagName) >= 0) {
        if (stack.length > 0) {
          stack[stack.length - 1].childNodes.push(node);
        } else {
          nodes.push(node);
        }
      } else {
        if (_JsoupLite._autoCloseTags.indexOf(tagName) >= 0) {
          for (var si = stack.length - 1; si >= 0; si--) {
            if (stack[si].tag === tagName) {
              while (stack.length > si + 1) {
                var orphan = stack.pop();
                stack[si].childNodes.push(orphan);
              }
              var closed = stack.pop();
              if (stack.length > 0) {
                stack[stack.length - 1].childNodes.push(closed);
              } else {
                nodes.push(closed);
              }
              break;
            }
          }
        }
        stack.push(node);
      }
    }
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
  _elementChildren: function(node) {
    if (!node || !node.childNodes) return [];
    return node.childNodes.filter(function(c) { return c.tag; });
  },
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
  _splitPseudo: function(sel) {
    var m = sel.match(/^(.+?):(nth-child|nth-of-type)\((.+)\)$/);
    if (m) return {base: m[1], pseudo: m[2], expr: m[3]};
    return {base: sel, pseudo: null, expr: null};
  },
  _matchesBase: function(node, selector) {
    if (!node || !node.tag) return false;
    var sel = selector.trim();
    if (!sel) return true;
    if (sel.startsWith('#') && sel.indexOf('.') < 0 && sel.indexOf('[') < 0) {
      return node.attrs['id'] === sel.substring(1);
    }
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
    var tagCls = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)\.([a-zA-Z_-][\w-]*)$/);
    if (tagCls) {
      if (node.tag !== tagCls[1].toLowerCase()) return false;
      var nc = (node.attrs['class'] || '').split(/\s+/);
      return nc.indexOf(tagCls[2]) >= 0;
    }
    var tagId = sel.match(/^([a-zA-Z][a-zA-Z0-9]*)#([a-zA-Z_-][\w-]*)$/);
    if (tagId) {
      return node.tag === tagId[1].toLowerCase() && node.attrs['id'] === tagId[2];
    }
    if (sel.startsWith('.')) {
      var classes = sel.substring(1).split('.');
      var nodeClasses = (node.attrs['class'] || '').split(/\s+/);
      for (var i = 0; i < classes.length; i++) {
        if (classes[i] && nodeClasses.indexOf(classes[i]) < 0) return false;
      }
      return true;
    }
    if (/^[a-zA-Z][a-zA-Z0-9]*$/.test(sel)) {
      return node.tag === sel.toLowerCase();
    }
    return false;
  },
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
  _queryAll: function(nodes, selector, depth) {
    depth = depth || 0;
    if (depth > 30 || !nodes) return [];
    var results = [];

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

    if (selector.indexOf(' > ') >= 0) {
      var childParts = selector.split(/\s*>\s*/);
      var current = _JsoupLite._queryAll(nodes, childParts[0].trim(), depth + 1);
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

    var parts = selector.split(/\s+/);
    if (parts.length > 1) {
      var cur = nodes;
      for (var pi = 0; pi < parts.length; pi++) {
        var pSel = parts[pi].trim();
        if (!pSel) continue;
        var found = _JsoupLite._queryAll(cur, pSel, depth + 1);
        if (pi < parts.length - 1) {
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
              var pos = 0;
              for (var si2 = 0; si2 < siblings.length; si2++) {
                pos++;
                if (siblings[si2] === node) {
                  if (_JsoupLite._resolveNth(sp.expr, pos)) results.push(node);
                  break;
                }
              }
            } else if (sp.pseudo === 'nth-of-type') {
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
      var childResults = _JsoupLite._queryAll(_JsoupLite._elementChildren(node), selector, depth + 1);
      results = results.concat(childResults);
    }
    return results;
  },
  _filterBySelector: function(elements, selector, parent) {
    var sp = _JsoupLite._splitPseudo(selector);
    var matched = [];
    if (sp.pseudo === 'nth-child') {
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
    return result;
  },
  selectAll: function(html, selector) {
    var key = _JsoupLite._cacheKey('jsoup_sa', selector, html);
    if (_javaCache[key] !== undefined) return _javaCache[key];
    var nodes = _JsoupLite._parseHtml(html);
    var found = _JsoupLite._queryAll(nodes, selector, 0);
    var result = found.map(function(n) { return _JsoupLite._getOuterHtml(n); });
    return result;
  },
  getAttr: function(html, selector, attr) {
    var key = _JsoupLite._cacheKey('jsoup_ga', selector + ':' + attr, html);
    if (_javaCache[key] !== undefined) return _javaCache[key];
    var nodes = _JsoupLite._parseHtml(html);
    var found = _JsoupLite._queryAll(nodes, selector, 0);
    var result = found.length > 0 ? (found[0].attrs[attr] || '') : '';
    return result;
  }
};
