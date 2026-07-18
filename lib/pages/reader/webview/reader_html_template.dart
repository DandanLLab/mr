import 'package:flutter/material.dart';
import '../../../models/highlight.dart';
import '../../../providers/reader_provider.dart';

/// 生成阅读器 HTML 模板
///
/// 架构参考 Lumina 项目（https://github.com/MilkFeng/lumina）：
/// - 使用 CSS Multi-column Layout 实现原生分栏分页
/// - 使用 CSS 变量驱动样式，无需重新加载即可更新
/// - 使用 JavaScript 计算页数、处理翻页、检测交互
///
/// 与 flutter_html 方案相比的优势：
/// - 原生支持 text-indent（首行缩进）
/// - 原生支持 white-space: pre（保留空格）
/// - 原生支持所有 CSS 属性（text-decoration-thickness 等）
/// - 性能更好（浏览器原生渲染，无需 Dart 侧 TextPainter 测量）
/// - 分页准确（CSS column 原生分栏，无字符级切割误差）
class ReaderHtmlTemplate {
  ReaderHtmlTemplate._();

  /// 生成完整的 HTML 文档
  ///
  /// [content] 已经过简繁转换和替换规则处理的纯文本章节内容
  /// [title] 章节标题
  /// [provider] 阅读器配置
  /// [viewWidth] / [viewHeight] 可视区域尺寸（用于 column-width 计算）
  /// [isScrollMode] 是否滚动模式（true: 取消分栏，改用纵向滚动）
  static String generate({
    required String content,
    required String title,
    required ReaderProvider provider,
    required double viewWidth,
    required double viewHeight,
    required bool isScrollMode,
    required int pageAnimDurationMs,
  }) {
    final css = _generateCss(provider, isScrollMode, pageAnimDurationMs);
    final js = _readerJs(pageAnimDurationMs);
    final paragraphsHtml = _buildParagraphsHtml(content, provider);
    final titleHtml = _buildTitleHtml(title, provider);

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <style>
    $css
  </style>
</head>
<body>
  <div id="reader-root">
    $titleHtml
    <div id="reader-content">
      $paragraphsHtml
    </div>
  </div>
  <script>
    $js
  </script>
  <script>
    window.addEventListener('DOMContentLoaded', function() {
      window.readerApi.init({
        viewWidth: ${viewWidth.floor()},
        viewHeight: ${viewHeight.floor()},
        isScrollMode: $isScrollMode,
        columnGap: 0,
        pageAnimDurationMs: $pageAnimDurationMs
      });
    });
  </script>
</body>
</html>
''';
  }

  /// 生成完整 CSS
  ///
  /// 分页模式核心：
  /// - body 设置 column-width = viewWidth，column-gap = 0
  /// - body 高度固定 = viewHeight，overflow: hidden
  /// - 内容会自动流式分栏，每栏一页
  ///
  /// 滚动模式核心：
  /// - 取消 column-width，改为正常文档流
  /// - body overflow-y: auto
  static String _generateCss(ReaderProvider provider, bool isScrollMode, int pageAnimDurationMs) {
    final textColor = _colorToHex(provider.textColor);
    final bgColor = _colorToHex(provider.backgroundColor);
    final fontFamily = provider.fontFamily.isEmpty ? 'inherit' : provider.fontFamily;
    // 缩进字符数：'\u3000\u3000' = 2 个全角空格 = 2em
    final indentEm = provider.paragraphIndent.length.toDouble();
    // 标题对齐模式：0=居左, 1=居中, 3=居右, 2=隐藏
    final titleAlign = provider.titleMode == 1
        ? 'center'
        : provider.titleMode == 3
            ? 'right'
            : 'left';
    // 标题字号 = 正文字号 * 1.4 + titleSize 增量
    final titleFontSizeCalc = 'calc(var(--reader-font-size) * 1.4 + ${provider.titleSize}px)';

    return '''
:root {
  --reader-font-size: ${provider.fontSize}px;
  --reader-line-height: ${provider.lineHeight};
  --reader-letter-spacing: ${provider.letterSpacing}px;
  --reader-paragraph-spacing: ${provider.paragraphSpacing}px;
  --reader-text-indent: ${indentEm}em;
  --reader-text-color: $textColor;
  --reader-bg-color: $bgColor;
  --reader-font-family: $fontFamily;
  --reader-text-weight: ${provider.textFontWeight};
  --reader-title-weight: ${provider.titleFontWeight};
  --reader-title-align: $titleAlign;
  --reader-title-font-size: $titleFontSizeCalc;
  --reader-page-anim-duration: ${pageAnimDurationMs}ms;
  --reader-padding-top: ${provider.paddingTop}px;
  --reader-padding-bottom: ${provider.paddingBottom}px;
  --reader-padding-left: ${provider.paddingLeft}px;
  --reader-padding-right: ${provider.paddingRight}px;
  --reader-title-top-spacing: ${provider.titleTopSpacing}px;
  --reader-title-bottom-spacing: ${provider.titleBottomSpacing}px;
}

* {
  box-sizing: border-box;
  -webkit-tap-highlight-color: transparent;
  /* 允许长按选择文字（替代 Flutter SelectionArea） */
  -webkit-touch-callout: default;
  -webkit-user-select: text;
  user-select: text;
}

html, body {
  margin: 0;
  padding: 0;
  width: 100%;
  height: 100%;
  background-color: var(--reader-bg-color);
  color: var(--reader-text-color);
  font-family: var(--reader-font-family);
  font-size: var(--reader-font-size);
  line-height: var(--reader-line-height);
  letter-spacing: var(--reader-letter-spacing);
  -webkit-text-size-adjust: none;
  text-size-adjust: none;
  overflow: hidden;
  touch-action: none;
}

#reader-root {
  padding-top: var(--reader-padding-top);
  padding-bottom: var(--reader-padding-bottom);
  padding-left: var(--reader-padding-left);
  padding-right: var(--reader-padding-right);
}

.reader-title {
  font-size: var(--reader-title-font-size);
  font-weight: var(--reader-title-weight);
  margin: var(--reader-title-top-spacing) 0 var(--reader-title-bottom-spacing) 0;
  padding: 0;
  text-align: var(--reader-title-align);
  color: var(--reader-text-color);
  line-height: var(--reader-line-height);
}

.reader-p {
  margin: 0 0 var(--reader-paragraph-spacing) 0;
  padding: 0;
  text-align: justify;
  text-indent: var(--reader-text-indent);
  word-break: break-word;
  overflow-wrap: break-word;
  font-weight: var(--reader-text-weight);
}

.reader-p:last-child {
  margin-bottom: 0;
}

/* 高亮规则 CSS */
${generateHighlightCss(provider)}

/* 分页模式：CSS Multi-column 布局 */
body.reader-paged {
  overflow: hidden;
}

body.reader-paged #reader-root {
  height: 100vh;
  width: 100vw;
}

body.reader-paged #reader-content {
  column-width: calc(100vw - var(--reader-padding-left) - var(--reader-padding-right));
  column-gap: 0;
  column-fill: auto;
  height: calc(100vh - var(--reader-padding-top) - var(--reader-padding-bottom));
  overflow: hidden;
  /* 翻页动画：translateX 变换时的过渡时长（slide/cover/simulation 共用） */
  transition: transform var(--reader-page-anim-duration) ease;
  will-change: transform;
}

/* 滚动模式：正常文档流 */
body.reader-scroll {
  overflow-y: auto;
  overflow-x: hidden;
  height: 100vh;
}

body.reader-scroll #reader-root {
  min-height: 100vh;
}

body.reader-scroll #reader-content {
  column-width: auto;
  column-gap: 0;
  height: auto;
}

/* 图片样式（如果有） */
.reader-p img {
  max-width: 100%;
  height: auto;
  display: block;
  margin: var(--reader-paragraph-spacing) auto;
}

/* 滚动条隐藏 */
::-webkit-scrollbar {
  display: none;
  width: 0;
  height: 0;
}
''';
  }

  /// 生成高亮规则的 CSS
  static String generateHighlightCss(ReaderProvider provider) {
    final rules = provider.highlightRules.where((r) => r.enabled).toList();
    final buf = StringBuffer();
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      buf.writeln('.hl-$i { ${_highlightStyleToCss(rule)} }');
    }
    return buf.toString();
  }

  /// 高亮规则转 CSS 字符串
  static String _highlightStyleToCss(HighlightRule rule) {
    final c = rule.color.color;
    final r = (c.r * 255).round().clamp(0, 255);
    final g = (c.g * 255).round().clamp(0, 255);
    final b = (c.b * 255).round().clamp(0, 255);
    final a = (c.a * 255).round().clamp(0, 255);
    final rgba = 'rgba($r, $g, $b, ${a / 255})';
    return switch (rule.style) {
      HighlightStyle.background =>
        'background-color: rgba($r, $g, $b, 0.4);',
      HighlightStyle.underline =>
        'text-decoration: underline; text-decoration-color: $rgba; text-decoration-thickness: 2px;',
      HighlightStyle.strikethrough =>
        'text-decoration: line-through; text-decoration-color: $rgba; text-decoration-thickness: 2px;',
      HighlightStyle.wavy =>
        'text-decoration: underline wavy; text-decoration-color: $rgba; text-decoration-thickness: 2px;',
    };
  }

  /// 构建段落 HTML
  static String _buildParagraphsHtml(
    String content,
    ReaderProvider provider,
  ) {
    final rules = provider.highlightRules.where((r) => r.enabled).toList();
    final paragraphs = _splitToParagraphs(content);
    final buf = StringBuffer();

    for (var i = 0; i < paragraphs.length; i++) {
      final raw = paragraphs[i];
      // 剥掉源内容自带缩进（全角空格 / 半角空格 / Tab）
      final trimmed = raw.replaceAll(RegExp(r'^[\u3000\t ]+'), '');
      // 应用高亮规则
      final highlighted = _applyHighlight(trimmed, rules);
      buf.write('<p class="reader-p" data-para-index="$i">');
      buf.write(highlighted);
      buf.write('</p>');
    }
    return buf.toString();
  }

  /// 构建章节标题 HTML
  /// titleMode: 0=居左, 1=居中, 2=隐藏, 3=居右
  static String _buildTitleHtml(String title, ReaderProvider provider) {
    if (!provider.showChapterTitle || title.isEmpty) return '';
    if (provider.titleMode == 2) return '';
    return '<h1 id="reader-title" class="reader-title">${_escapeHtml(title)}</h1>';
  }

  /// 把内容切分成段落
  static List<String> _splitToParagraphs(String content) {
    return content
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// 应用高亮规则
  static String _applyHighlight(String text, List<HighlightRule> rules) {
    if (rules.isEmpty) return _escapeHtml(text);

    var result = _escapeHtml(text);
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      if (rule.pattern.isEmpty) continue;
      try {
        final regex = RegExp(rule.pattern, multiLine: true);
        result = result.replaceAllMapped(regex, (match) {
          final matched = match.group(0) ?? '';
          if (matched.isEmpty) return '';
          return '<span class="hl-$i">$matched</span>';
        });
      } catch (_) {}
    }
    return result;
  }

  /// HTML 特殊字符转义
  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  /// Color 转 hex 字符串（#RRGGBB）
  static String _colorToHex(Color color) {
    final argb = color.toARGB32();
    return '#${argb.toRadixString(16).padLeft(8, '0').substring(2)}';
  }

  /// JavaScript 脚本：分页计算 + 翻页 + 交互检测
  ///
  /// API 暴露在 window.readerApi：
  /// - init(config): 初始化
  /// - getPageCount(): 获取总页数
  /// - jumpToPage(pageIndex, animate?): 跳转到指定页（animate 默认 true）
  /// - getCurrentPage(): 获取当前页码
  /// - getScrollProgress(): 获取滚动进度（0-1）
  /// - setScrollProgress(ratio): 设置滚动进度（仅滚动模式）
  /// - checkTap(x, y): 检测点击位置（用于交互区分）
  ///
  /// 翻页动画：CSS transition 驱动 translateX 过渡，时长由
  /// --reader-page-anim-duration 控制（pageAnimDurationMs 注入）。
  /// 进度恢复时传 animate=false 临时禁用 transition 避免初始滑动。
  static String _readerJs(int pageAnimDurationMs) {
    // duration 为 0 时 JS 的 animEnabled 会为 false，所有跳转都无动画
    return r'''
window.readerApi = (function() {
  var config = { viewWidth: 0, viewHeight: 0, isScrollMode: false, columnGap: 0, pageAnimDurationMs: 0 };
  var body = document.body;
  var animEnabled = true; // 全局动画开关（false 时所有跳转都无动画）

  function init(cfg) {
    config = cfg;
    animEnabled = (config.pageAnimDurationMs || 0) > 0;
    body.classList.add(config.isScrollMode ? 'reader-scroll' : 'reader-paged');
    // 绑定 click 监听器：WebView 拦截了 pointer 事件，外层 Listener 收不到
    // tap，所以由 JS 检测 click 后回调 Dart 侧处理（菜单/翻页分区）
    document.addEventListener('click', function(e) {
      // 点击图片交给 onImageTap
      if (e.target && e.target.tagName === 'IMG') {
        notifyImageTap(e.target.src, e.target.getBoundingClientRect());
        return;
      }
      // 取 clientX/clientY（相对 WebView 视口）
      notifyTap(e.clientX, e.clientY);
    }, { passive: true });
    // 滚动模式：监听 scroll 事件，防抖回调进度（用于保存/恢复阅读位置）
    if (config.isScrollMode) {
      var scrollTimer = null;
      var scrollTarget = config.isScrollMode ? body : null;
      window.addEventListener('scroll', function() {
        if (scrollTimer) clearTimeout(scrollTimer);
        scrollTimer = setTimeout(function() {
          var progress = getScrollProgress();
          if (window.flutter_inappwebview) {
            // 用 progress * 1000 作为「虚拟页码」传给 Dart 侧
            window.flutter_inappwebview.callHandler('onPageChanged', Math.round(progress * 1000));
          }
        }, 200);
      }, { passive: true });
    }
    // 等待 DOM 渲染完成后通知 Dart 侧
    requestAnimationFrame(function() {
      requestAnimationFrame(function() {
        notifyPageCountReady();
      });
    });
  }

  function getColumnWidth() {
    // column-width = 100vw - paddingLeft - paddingRight
    var root = document.getElementById('reader-root');
    var style = getComputedStyle(root);
    var pl = parseFloat(style.paddingLeft) || 0;
    var pr = parseFloat(style.paddingRight) || 0;
    return window.innerWidth - pl - pr;
  }

  function getPageCount() {
    if (config.isScrollMode) return 1;
    var content = document.getElementById('reader-content');
    if (!content) return 1;
    var columnWidth = getColumnWidth();
    var gap = config.columnGap || 0;
    var scrollWidth = content.scrollWidth;
    return Math.max(1, Math.round((scrollWidth + gap) / (columnWidth + gap)));
  }

  function getCurrentPage() {
    if (config.isScrollMode) return 0;
    var content = document.getElementById('reader-content');
    if (!content) return 0;
    var columnWidth = getColumnWidth();
    var gap = config.columnGap || 0;
    var scrollLeft = content.scrollLeft || window.scrollX || 0;
    return Math.round(scrollLeft / (columnWidth + gap));
  }

  // 翻到指定页
  // animate: true=带过渡动画（用户翻页）, false=无动画（进度恢复/初始化）
  function jumpToPage(pageIndex, animate) {
    if (config.isScrollMode) return;
    var content = document.getElementById('reader-content');
    if (!content) return;
    var columnWidth = getColumnWidth();
    var gap = config.columnGap || 0;
    var offset = pageIndex * (columnWidth + gap);
    // 临时禁用 transition（animate=false 或全局 animEnabled=false）
    var useAnim = animate !== false && animEnabled;
    if (!useAnim) {
      content.style.transition = 'none';
    }
    content.style.transform = 'translateX(-' + offset + 'px)';
    if (!useAnim) {
      // 强制重排，确保下次 transition 生效
      void content.offsetHeight;
      content.style.transition = '';
    }
    // 通知 Dart 侧页码变更
    notifyPageChanged(pageIndex);
  }

  function getScrollProgress() {
    if (config.isScrollMode) {
      var st = body.scrollTop || document.documentElement.scrollTop;
      var sh = body.scrollHeight - window.innerHeight;
      return sh > 0 ? st / sh : 0;
    }
    return getPageCount() > 0 ? getCurrentPage() / getPageCount() : 0;
  }

  function setScrollProgress(ratio) {
    if (!config.isScrollMode) {
      var pageCount = getPageCount();
      var page = Math.round(ratio * pageCount);
      jumpToPage(page);
      return;
    }
    var sh = body.scrollHeight - window.innerHeight;
    body.scrollTop = sh * ratio;
  }

  // 获取当前滚动像素偏移（滚动模式进度保存用）
  function getScrollOffset() {
    if (!config.isScrollMode) return 0;
    return body.scrollTop || document.documentElement.scrollTop || 0;
  }

  // 滚动到指定像素偏移（滚动模式进度恢复用）
  function scrollToOffset(px) {
    if (!config.isScrollMode) return;
    body.scrollTop = Math.max(0, px);
  }

  // 按视口高度滚动（direction: -1 上翻 / +1 下翻）
  // 返回滚动后的进度（0-1），若已到顶/底返回 -1 表示触发章节切换
  function scrollByViewport(direction) {
    if (!config.isScrollMode) return -1;
    var viewport = window.innerHeight;
    var maxScroll = body.scrollHeight - viewport;
    if (maxScroll <= 0) return -1;
    var current = body.scrollTop || 0;
    var target = current + direction * viewport * 0.9;
    if (target <= 0) {
      body.scrollTop = 0;
      return -1; // 已到顶
    }
    if (target >= maxScroll) {
      body.scrollTop = maxScroll;
      return -1; // 已到底
    }
    body.scrollTop = target;
    return target / maxScroll;
  }

  function checkTap(x, y) {
    // 转换为 WebView 内部坐标（考虑 padding）
    var root = document.getElementById('reader-root');
    var rect = root.getBoundingClientRect();
    var localX = x - rect.left;
    var localY = y - rect.top;

    // 检测是否点击在交互元素上（目前只有图片）
    var el = document.elementFromPoint(localX, localY);
    if (el && el.tagName === 'IMG') {
      notifyImageTap(el.src, el.getBoundingClientRect());
      return;
    }

    // 通知 Dart 侧普通点击
    notifyTap(x, y);
  }

  // ============ Dart 通信 ============
  function notifyPageCountReady() {
    var count = getPageCount();
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onPageCountReady', count);
    }
  }

  function notifyPageChanged(pageIndex) {
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onPageChanged', pageIndex);
    }
  }

  function notifyTap(x, y) {
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onTap', x, y);
    }
  }

  function notifyImageTap(src, rect) {
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onImageTap', src, rect.left, rect.top, rect.width, rect.height);
    }
  }

  return {
    init: init,
    getPageCount: getPageCount,
    getCurrentPage: getCurrentPage,
    jumpToPage: jumpToPage,
    getScrollProgress: getScrollProgress,
    setScrollProgress: setScrollProgress,
    getScrollOffset: getScrollOffset,
    scrollToOffset: scrollToOffset,
    scrollByViewport: scrollByViewport,
    checkTap: checkTap
  };
})();
''';
  }
}
