/// EPUB 脚注/尾注支持
///
/// 移植自 JRead/Legado 的 EpubFootnoteSupport.kt
///
/// 1. installJavascript：生成 JS 注入到 WebView，拦截本地脚注引用
/// 2. parsePayload：解析 JS 回调的 JSON payload，生成安全 HTML
///
/// 核心原则：绝不修改阅读器 DOM，只拦截点击 → 提取内容 → 回调原生
library;

import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

/// 脚注内容
class EpubFootnoteContent {
  final String sourceUrl;
  final String targetUrl;
  final String title;
  final String html;
  final String text;

  const EpubFootnoteContent({
    required this.sourceUrl,
    required this.targetUrl,
    required this.title,
    required this.html,
    required this.text,
  });

  /// 基础 URL（去 fragment）
  String get baseUrl => targetUrl.split('#').first;
}

/// EPUB 脚注支持
class EpubFootnoteSupport {
  EpubFootnoteSupport._();

  static const String epubReaderHost = 'epub.local';
  static const int _maxUrlChars = 4096;
  static const int _maxTitleChars = 160;
  static const int _maxHtmlChars = 128 * 1024;
  static const int _maxTextChars = 32 * 1024;
  static const int _maxPayloadChars = _maxHtmlChars + _maxTextChars + 16 * 1024;

  /// 解析 JS 回调的 JSON payload
  ///
  /// [payload] JSON 字符串，包含 sourceUrl/targetUrl/title/html/text
  /// 返回安全的内容，或 null（无效/空内容）
  static EpubFootnoteContent? parsePayload(String? payload) {
    if (payload == null || payload.trim().isEmpty || payload.length > _maxPayloadChars) {
      return null;
    }

    Map<String, dynamic> raw;
    try {
      raw = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final sourceUrl = _safeEpubUrl(raw['sourceUrl'] as String?);
    final targetUrl = _safeEpubUrl(raw['targetUrl'] as String?);
    if (sourceUrl == null || targetUrl == null) return null;

    final rawHtml = (raw['html'] as String?) ?? '';
    final safeHtml = _sanitizeHtml(rawHtml, targetUrl.split('#').first);

    final rawText = (raw['text'] as String?) ?? '';
    final safeText = rawText
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final truncatedText = safeText.length > _maxTextChars
        ? safeText.substring(0, _maxTextChars)
        : safeText;

    final rawTitle = (raw['title'] as String?) ?? '';
    final safeTitle = rawTitle
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final truncatedTitle = safeTitle.length > _maxTitleChars
        ? safeTitle.substring(0, _maxTitleChars)
        : safeTitle;

    // 检查内容是否为空
    final doc = html_parser.parseFragment(safeHtml);
    final hasText = doc.text?.trim().isNotEmpty == true;
    final hasMedia = doc.querySelectorAll('img,svg,table').isNotEmpty;
    if (!hasText && !hasMedia && safeText.isEmpty) return null;

    return EpubFootnoteContent(
      sourceUrl: sourceUrl,
      targetUrl: targetUrl,
      title: truncatedTitle,
      html: safeHtml,
      text: truncatedText,
    );
  }

  /// 生成脚注拦截 JS
  ///
  /// [token] 版本号，用于防止重复注入
  /// [bridgeName] WebView JS bridge 对象名
  static String installJavascript(int token, String bridgeName) {
    // 验证 bridgeName 是合法 JS 标识符
    if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(bridgeName)) {
      throw ArgumentError('Invalid bridge name: $bridgeName');
    }

    return '''
(function() {
  var TOKEN = $token;
  if (window.__motingFootnoteToken === TOKEN) return;
  window.__motingFootnoteToken = TOKEN;
  var bridge = window.$bridgeName;
  if (!bridge) return;
  var semanticPattern = /(^|[\\s_-])(noteref|footnote|endnote|rearnote|note)([\\s_-]|\$)/i;
  var noteHintPattern = /(^|[\\s_:#-])(fn|ftn|note|footnote|endnote|rearnote)\\d*([\\s_:#-]|\$)/i;
  var markerPattern = /^[\\s\\[(（【]?(?:\\d{1,4}|[*†‡§※]+)[\\s\\])）】]?\$/;
  var maxHtml = $_maxHtmlChars;
  var maxText = $_maxTextChars;

  function closestAnchor(node) {
    var element = node && node.nodeType === 1 ? node : node && node.parentElement;
    return element && element.closest ? element.closest('a[href]') : null;
  }

  function semanticValue(node) {
    if (!node || !node.getAttribute) return '';
    return [
      node.getAttribute('epub:type') || '',
      node.getAttribute('type') || '',
      node.getAttribute('role') || '',
      node.getAttribute('class') || '',
      node.getAttribute('id') || ''
    ].join(' ');
  }

  function isSemanticNote(node) {
    return semanticPattern.test(semanticValue(node));
  }

  function localTarget(anchor) {
    try {
      var target = new URL(anchor.getAttribute('href') || '', document.baseURI);
      if (target.origin !== window.location.origin) return null;
      if (!target.hash && !isSemanticNote(anchor)) return null;
      return target;
    } catch (_) {
      return null;
    }
  }

  function elementByFragment(doc, hash) {
    if (!hash) return null;
    var id = hash.charAt(0) === '#' ? hash.substring(1) : hash;
    try { id = decodeURIComponent(id); } catch (_) {}
    return doc.getElementById(id) || doc.querySelector('[name="' +
      String(id).replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"]');
  }

  function safeCloneHtml(node) {
    var clone = node.cloneNode(true);
    Array.prototype.forEach.call(
      clone.querySelectorAll('script,iframe,object,embed,form,input,button'),
      function(child) { child.remove(); }
    );
    var all = [clone].concat(Array.prototype.slice.call(clone.querySelectorAll('*')));
    all.forEach(function(element) {
      Array.prototype.slice.call(element.attributes || []).forEach(function(attr) {
        var name = String(attr.name || '').toLowerCase();
        if (name.indexOf('on') === 0 || name === 'style') {
          element.removeAttribute(attr.name);
        }
      });
    });
    return String(clone.outerHTML || clone.innerHTML || '').slice(0, maxHtml);
  }

  function fallbackNavigate(url) {
    window.location.assign(url.href);
  }

  function openReference(anchor, targetUrl) {
    var referenceSemantic = isSemanticNote(anchor);
    var sameResource =
      targetUrl.origin === window.location.origin &&
      targetUrl.pathname === window.location.pathname &&
      targetUrl.search === window.location.search;
    var targetDocumentPromise = sameResource
      ? Promise.resolve(document)
      : fetch(targetUrl.href, {
          credentials: 'omit',
          cache: 'force-cache'
        }).then(function(response) {
        if (!response.ok) throw new Error('HTTP ' + response.status);
        return response.text();
      }).then(function(source) {
        var targetDocument = new DOMParser()
          .parseFromString(source, 'application/xhtml+xml');
        if (targetDocument.querySelector('parsererror')) {
          targetDocument = new DOMParser().parseFromString(source, 'text/html');
        }
        return targetDocument;
      });
    targetDocumentPromise.then(function(targetDocument) {
      var targetElement = elementByFragment(targetDocument, targetUrl.hash);
      if (!targetElement && referenceSemantic && targetDocument.body) {
        targetElement = targetDocument.body;
      }
      var targetSemantic = isSemanticNote(targetElement);
      var markerFallback = !!targetElement &&
        markerPattern.test(String(anchor.textContent || '').trim()) &&
        (
          noteHintPattern.test(
            semanticValue(anchor) + ' ' +
            targetUrl.hash + ' ' +
            semanticValue(targetElement)
          ) ||
          !!targetElement.querySelector(
            'a[role="doc-backlink"],a[epub\\:type~="backlink"]'
          )
        );
      if (!referenceSemantic && !targetSemantic && !markerFallback) {
        fallbackNavigate(targetUrl);
        return;
      }
      if (!targetElement) throw new Error('missing footnote target');
      var text = String(targetElement.textContent || '')
        .replace(/\\s+/g, ' ')
        .trim()
        .slice(0, maxText);
      bridge.onFootnoteRequested(TOKEN, JSON.stringify({
        sourceUrl: window.location.href,
        targetUrl: targetUrl.href,
        title: anchor.getAttribute('title') || '',
        html: safeCloneHtml(targetElement),
        text: text
      }));
    }).catch(function(error) {
      if (referenceSemantic) {
        bridge.onFootnoteError(TOKEN, String(error || 'footnote unavailable'));
      } else {
        fallbackNavigate(targetUrl);
      }
    }).then(function() {
      bridge.onEmbeddedInteractiveTouch(TOKEN, false);
    });
  }

  document.addEventListener('touchstart', function(event) {
    var anchor = closestAnchor(event.target);
    if (anchor && localTarget(anchor)) {
      bridge.onEmbeddedInteractiveTouch(TOKEN, true);
    }
  }, true);
  document.addEventListener('touchcancel', function() {
    bridge.onEmbeddedInteractiveTouch(TOKEN, false);
  }, true);
  document.addEventListener('touchend', function() {
    setTimeout(function() {
      bridge.onEmbeddedInteractiveTouch(TOKEN, false);
    }, 0);
  }, true);
  document.addEventListener('click', function(event) {
    if (event.defaultPrevented) return;
    var anchor = closestAnchor(event.target);
    if (!anchor) return;
    var targetUrl = localTarget(anchor);
    if (!targetUrl) return;
    event.preventDefault();
    event.stopPropagation();
    openReference(anchor, targetUrl);
  }, true);
})();
''';
  }

  /// 验证 URL 是否为安全的 epub.local URL
  static String? _safeEpubUrl(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > _maxUrlChars) return null;

    try {
      final uri = Uri.parse(trimmed);
      if (uri.scheme.toLowerCase() != 'https' ||
          (uri.host.toLowerCase() != epubReaderHost)) {
        return null;
      }
      return trimmed;
    } catch (_) {
      return null;
    }
  }

  /// 简化版 HTML 清洗
  ///
  /// 移除 script/iframe/object/embed/form/input/button 等危险元素
  /// 移除 on* 事件属性和 style 属性
  static String _sanitizeHtml(String html, String baseUrl) {
    if (html.isEmpty) return '';
    final truncated = html.length > _maxHtmlChars
        ? html.substring(0, _maxHtmlChars)
        : html;

    // 用 html 包解析后重新序列化，自动清理不合法的标签
    final doc = html_parser.parse(truncated);

    // 移除危险元素
    for (final selector in ['script', 'iframe', 'object', 'embed', 'form', 'input', 'button']) {
      for (final el in doc.querySelectorAll(selector)) {
        el.remove();
      }
    }

    // 移除 on* 属性和 style 属性
    for (final el in doc.querySelectorAll('*')) {
      final attrsToRemove = <String>[];
      for (final key in el.attributes.keys.cast<String>()) {
        final lower = key.toLowerCase();
        if (lower.startsWith('on') || lower == 'style') {
          attrsToRemove.add(key);
        }
      }
      for (final attr in attrsToRemove) {
        el.attributes.remove(attr);
      }
    }

    // 返回 body 内部 HTML
    return doc.body?.innerHtml.trim() ?? '';
  }
}
