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
/// 翻页动画：双层容器方案
/// - #reader-content-a：主层，静态时显示当前页，可交互（选文字、点链接）
/// - #reader-content-b：动画层，默认 visibility:hidden，翻页时显示并做动画
/// - 动画结束后 a 跳到目标页（无动画），b 隐藏
/// - 全程文字选择可用（动画期间 b 拦截点击，但动画很快用户感知不到）
///
/// 三种翻页模式：
/// - slide：a/b 同时平移（a 滑出，b 滑入）
/// - cover：a 不动，b 从侧边滑入覆盖
/// - simulation：b 带 3D rotateY 翻折从侧边滑入
class ReaderHtmlTemplate {
  ReaderHtmlTemplate._();

  /// 生成完整的 HTML 文档
  static String generate({
    required String content,
    required String title,
    required ReaderProvider provider,
    required double viewWidth,
    required double viewHeight,
    required bool isScrollMode,
    required int pageAnimDurationMs,
    required int pageModeIndex,
  }) {
    final css = _generateCss(provider, isScrollMode);
    final js = _readerJs();
    final paragraphsHtml = _buildParagraphsHtml(content, provider);
    final titleHtml = _buildTitleHtml(title, provider);

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <style>
    $css
  </style>
</head>
<body>
  <div id="reader-root">
    $titleHtml
    <div id="reader-stage">
      <div id="reader-content-a" class="reader-content">
        $paragraphsHtml
      </div>
      <div id="reader-content-b" class="reader-content">
        $paragraphsHtml
      </div>
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
        pageAnimDurationMs: $pageAnimDurationMs,
        pageModeIndex: $pageModeIndex
      });
    });
  </script>
</body>
</html>
''';
  }

  /// 生成完整 CSS
  ///
  /// 填充溢出修复（借鉴 lumina）：
  /// - 用 min() 限制 padding 不超过 viewport - 100px
  /// - 保证内容区最小 100px，padding 之和永不超 viewport
  ///
  /// 双层容器：
  /// - #reader-stage: relative + overflow:hidden，作为 a/b 的定位容器
  /// - .reader-content: absolute + column 布局，a/b 重叠在同一位置
  /// - #reader-content-b: 默认 visibility:hidden + pointer-events:none
  static String _generateCss(ReaderProvider provider, bool isScrollMode) {
    final textColor = _colorToHex(provider.textColor);
    final bgColor = _colorToHex(provider.backgroundColor);
    final fontFamily = provider.fontFamily.isEmpty ? 'inherit' : provider.fontFamily;
    final indentEm = provider.paragraphIndent.length.toDouble();
    final titleAlign = provider.titleMode == 1
        ? 'center'
        : provider.titleMode == 3
            ? 'right'
            : 'left';
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
  /* 原始 padding 值（用户配置） */
  --reader-padding-top-raw: ${provider.paddingTop}px;
  --reader-padding-bottom-raw: ${provider.paddingBottom}px;
  --reader-padding-left-raw: ${provider.paddingLeft}px;
  --reader-padding-right-raw: ${provider.paddingRight}px;
  /* --reader-vw/vh 由 JS 在 init 时注入（= window.innerWidth/innerHeight，
     即 WebView widget 实际尺寸）。不能用 100vw/100vh，因为在 Android
     InAppWebView 中 100vw = 设备屏幕宽度，不等于 widget 宽度，会导致
     内容区比 widget 宽 → 溢出 → 允许双指缩放 → 分页错乱。 */
  --reader-vw: 100vw;
  --reader-vh: 100vh;
  /* 限制 padding 不超 viewport，保证内容区最小 100px 防溢出 */
  --reader-padding-top: min(var(--reader-padding-top-raw), calc((var(--reader-vh) - 100px) / 2));
  --reader-padding-bottom: min(var(--reader-padding-bottom-raw), calc(var(--reader-vh) - 100px - var(--reader-padding-top)));
  --reader-padding-left: min(var(--reader-padding-left-raw), calc((var(--reader-vw) - 100px) / 2));
  --reader-padding-right: min(var(--reader-padding-right-raw), calc(var(--reader-vw) - 100px - var(--reader-padding-left)));
  /* 安全区尺寸（内容区） */
  --reader-safe-width: calc(var(--reader-vw) - var(--reader-padding-left) - var(--reader-padding-right));
  --reader-safe-height: calc(var(--reader-vh) - var(--reader-padding-top) - var(--reader-padding-bottom));
  --reader-title-top-spacing: ${provider.titleTopSpacing}px;
  --reader-title-bottom-spacing: ${provider.titleBottomSpacing}px;
}

* {
  box-sizing: border-box;
  -webkit-tap-highlight-color: transparent;
  -webkit-touch-callout: default;
  -webkit-user-select: text;
  user-select: text;
}

/* 参考 lumina：html/body 统一 100%/100%，padding 放 html 上
   100vw/100vh 在 InAppWebView 里可能等于屏幕尺寸而非 widget 尺寸，
   所以用 --reader-vw/vh（JS 注入 window.innerWidth/innerHeight）替代 */
html, body {
  margin: 0;
  padding: 0;
  /* 不设置 width：html 作为根元素默认 width=viewport（=--reader-vw）；
     body 作为块级元素默认 width=auto，填满 html 的 content area
     （= --reader-vw - paddingLeft - paddingRight = --reader-safe-width）。
     之前写 width: var(--reader-vw) 会让 body 比 html content area 宽，
     滚动模式下 #reader-root(width:100%) 横向溢出屏幕。 */
  height: var(--reader-vh);
  background-color: var(--reader-bg-color);
  color: var(--reader-text-color);
  font-family: var(--reader-font-family);
  font-size: var(--reader-font-size);
  line-height: var(--reader-line-height);
  letter-spacing: var(--reader-letter-spacing);
  -webkit-text-size-adjust: none;
  text-size-adjust: none;
  overflow: hidden;
  /* manipulation: 允许点击和轻触，禁用双击缩放和滚动
     none 在某些 WebView 上会阻断 click 事件合成 */
  touch-action: manipulation;
}

/* padding 放 html 上（与 lumina 一致），body 不设 padding */
html {
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

/* ============ 分页模式 ============ */
/* #reader-root 是 flex 纵向容器：标题占自然高度，#reader-stage flex:1
   撑满剩余空间。#reader-stage 是 a/b 的定位容器（position:relative +
   overflow:hidden）。这样标题和正文不会重叠（之前 a/b absolute top:0
   会覆盖标题）。 */
body.reader-paged {
  position: relative;
  overflow: hidden;
}

body.reader-paged #reader-root {
  position: relative;
  display: flex;
  flex-direction: column;
  width: var(--reader-safe-width);
  height: var(--reader-safe-height);
  overflow: hidden;
}

body.reader-paged #reader-stage {
  position: relative;
  /* flex:1 让 stage 占满 #reader-root 内 .reader-title 之外的剩余高度。
     不设 height:100%，避免与 flex:1 冲突（两者都试图设高度，flex 容器内
     height:100% 行为不一致，部分 WebView 上会导致 stage 高度计算错误） */
  flex: 1 1 0;
  width: 100%;
  min-height: 0; /* flex 子项默认 min-height:auto 会阻止收缩，导致溢出 */
  overflow: hidden;
  /* perspective：让子元素 .reader-content 的 rotateY 有立体感（C3 修复）
     - 仅 simulation 模式生效，slide/cover 的 transform 是 2D 平移不受影响
     - 1500px 是经验值：过小畸变严重，过大立体感弱
     - 必须设在父元素（stage）上，子元素自身 perspective 无效 */
  perspective: 1500px;
  perspective-origin: center center;
}

/* a/b 共用样式：absolute 重叠在 #reader-stage 内，column 分栏
   关键：不设 width，让 column 布局自动扩展到内容总宽度，
   这样 scrollWidth 才能返回所有列的总宽度（= pageCount * columnWidth）。
   高度用 top:0 + bottom:0 撑满 stage，避免 height:100% 在 flex 父容器
   内的高度计算不稳定（部分 Android WebView 上 flex 子项 absolute 子元素
   的 height:100% 会算成 0，导致 column 布局坍缩成 1 列）。
   裁剪由 #reader-stage 的 overflow:hidden 负责。 */
body.reader-paged .reader-content {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  column-width: var(--reader-safe-width);
  column-gap: 0;
  column-fill: auto;
  will-change: transform;
  backface-visibility: hidden;
  -webkit-backface-visibility: hidden;
  transform: translate3d(0, 0, 0);
  /* preserve-3d：让自身 rotateY 不被压平成 2D（C3 修复，配合父元素 perspective）
     仅 simulation 模式用到 rotateY，其他模式 transform 是 2D 不受影响 */
  transform-style: preserve-3d;
}

/* a 层显式启用交互，确保点击穿透 b 后能命中 a */
body.reader-paged #reader-content-a {
  pointer-events: auto;
}

/* b 层默认隐藏（visibility:hidden + opacity:0 双重保险，避免某些
   Android WebView 上单 visibility:hidden 对 absolute 元素仍渲染
   导致与 a 层视觉重叠） */
body.reader-paged #reader-content-b {
  visibility: hidden;
  opacity: 0;
  pointer-events: none;
  transform: translate3d(0, 0, 0);
}

/* b 层动画进行中：显示并暂时拦截事件（避免动画期间误触） */
body.reader-paged #reader-content-b.animating {
  visibility: visible;
  opacity: 1;
  pointer-events: auto;
}

/* ============ 滚动模式 ============ */
body.reader-scroll {
  overflow-y: auto;
  overflow-x: hidden;
  /* height: 100% 相对 html content area（= --reader-vh - paddingTop - paddingBottom
     = --reader-safe-height）。之前用 var(--reader-vh) 会让 body 竖向溢出 html
     content area，被 html overflow:hidden 裁剪后，body 滚动区域大于可见区域，
     滚动到 padding 区域的内容被遮挡看不到，且滚动卡顿不丝滑。 */
  height: 100%;
  /* 启用硬件加速合成层：让 body 自身作为合成层，
     在 Android WebView 上滚动更流畅（替代无效的 -webkit-overflow-scrolling: touch） */
  will-change: scroll-position;
  transform: translateZ(0);
  /* 关键：让滚动贴近物理手感，禁用边界回弹（避免过度滚动反而卡顿） */
  overscroll-behavior: contain;
}

body.reader-scroll #reader-root {
  position: relative;
  min-height: var(--reader-safe-height);
  width: 100%;
  height: auto;
}

body.reader-scroll #reader-stage {
  position: relative;
  width: 100%;
  height: auto;
}

body.reader-scroll .reader-content {
  position: relative;
  column-width: auto;
  column-gap: 0;
  height: auto;
  width: 100%;
  transform: none !important;
}

/* 滚动模式隐藏 b 层（不需要翻页动画） */
body.reader-scroll #reader-content-b {
  display: none;
}

/* 图片样式 */
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

  /// JavaScript 脚本：分页计算 + 双层翻页动画 + 交互检测
  ///
  /// 双层翻页流程（从第 N 页 → 第 M 页）：
  /// 1. b 跳到目标页 M（无动画），显示 b
  /// 2. 根据 mode 和方向设置 a/b 的 transform 起止值
  /// 3. 启动 transition 动画
  /// 4. transitionend 回调：a 跳到 M（无动画），b 隐藏
  ///
  /// mode 行为：
  /// - slide(1): a/b 同时平移（a 滑出，b 滑入）
  /// - cover(2): a 不动，b 从侧边滑入覆盖
  /// - simulation(3): b 带 3D rotateY 翻折滑入
  /// - none(4): 无动画，a 直接跳到目标页
  static String _readerJs() {
    return r'''
// 日志桥：劫持 console.*，所有日志通过 callHandler 回传到 Flutter debugPrint
// 封装 WebView 无法连 chrome://inspect，必须通过此通道看 JS 日志
(function() {
  var origLog = console.log.bind(console);
  var origWarn = console.warn.bind(console);
  var origErr = console.error.bind(console);
  function send(level, args) {
    try {
      var msg = Array.prototype.slice.call(args).map(function(a) {
        return (typeof a === 'object') ? JSON.stringify(a) : String(a);
      }).join(' ');
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('onReaderLog', '[' + level + '] ' + msg);
      }
    } catch (e) {}
  }
  console.log = function() { send('log', arguments); origLog.apply(console, arguments); };
  console.warn = function() { send('warn', arguments); origWarn.apply(console, arguments); };
  console.error = function() { send('error', arguments); origErr.apply(console, arguments); };
  window.addEventListener('error', function(e) {
    send('error', ['uncaught: ' + (e.message || '') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0)]);
  });
})();

window.readerApi = (function() {
  var config = { viewWidth: 0, viewHeight: 0, isScrollMode: false, columnGap: 0, pageAnimDurationMs: 0, pageModeIndex: 4 };
  var body = document.body;
  var contentA = null;  // 主层（静态可交互）
  var contentB = null;  // 动画层（默认隐藏）
  var animEnabled = true;     // 全局动画开关
  var isAnimating = false;    // 当前是否在动画中
  var currentPage = 0;        // 当前页码（a 显示的页）
  var animEndTimer = null;    // 动画超时兜底（防止 transitionend 不触发）

  function init(cfg) {
    config = cfg;
    animEnabled = (config.pageAnimDurationMs || 0) > 0 && (config.pageModeIndex !== 4);
    contentA = document.getElementById('reader-content-a');
    contentB = document.getElementById('reader-content-b');
    body.classList.add(config.isScrollMode ? 'reader-scroll' : 'reader-paged');

    // overflow 完全由 CSS class 控制，不再用 inline style 强制设置：
    //   - html, body { overflow: hidden }（共用样式，防横向溢出）
    //   - body.reader-paged { overflow: hidden }（分页模式保持隐藏）
    //   - body.reader-scroll { overflow-y: auto; overflow-x: hidden }（滚动模式）
    // 之前用 body.style.overflow='hidden' 是 inline style，优先级高于
    // CSS class，会覆盖 body.reader-scroll 的 overflow-y:auto，导致滚动模式
    // 下 body 实际 overflow=hidden 不能滚动，只能靠 WebView 控件自身滚动，
    // 既卡顿又不丝滑。
    // 防双指缩放由 disableGestureZoom() 负责，与 overflow 无关。

    // 关键：注入 WebView 实际尺寸到 CSS 变量
    // window.innerWidth/innerHeight = WebView widget 实际尺寸（DIP）
    // 不能用 100vw/100vh，Android InAppWebView 中 100vw = 屏幕宽度 ≠ widget 宽度
    updateViewportSize();
    // 监听 resize（键盘弹出/旋转等）
    window.addEventListener('resize', function() {
      updateViewportSize();
      // 尺寸变化后重新通知页数
      requestAnimationFrame(function() {
        requestAnimationFrame(function() {
          notifyPageCountReady();
        });
      });
    });

    // 禁用所有手势缩放（防止双指放大内容导致溢出可见 + 分页错乱）
    disableGestureZoom();

    console.log('[reader] init', JSON.stringify(config), 'animEnabled=' + animEnabled,
      'vw=' + window.innerWidth, 'vh=' + window.innerHeight,
      'contentA=' + !!contentA, 'contentB=' + !!contentB);

    // 绑定 click 监听器
    document.addEventListener('click', function(e) {
      if (isAnimating) {
        console.log('[reader] click ignored (animating)');
        return;
      }
      if (e.target && e.target.tagName === 'IMG') {
        notifyImageTap(e.target.src, e.target.getBoundingClientRect());
        return;
      }
      console.log('[reader] click at', e.clientX, e.clientY, 'target:', e.target.tagName);
      notifyTap(e.clientX, e.clientY);
    }, { passive: true });

    // 滚动模式：监听 scroll 事件
    // 关键：滚动容器是 body（CSS body.reader-scroll { overflow-y: auto }），
    // 不是 window。window 的 scroll 事件只在 document.scrollingElement 滚动时触发，
    // 而 body 自身滚动不会派发 window 的 scroll 事件（scroll 事件不冒泡）。
    // 之前监听 window 导致滚动进度永远不回调（C4 bug）
    if (config.isScrollMode) {
      var scrollTimer = null;
      body.addEventListener('scroll', function() {
        if (scrollTimer) clearTimeout(scrollTimer);
        scrollTimer = setTimeout(function() {
          var progress = getScrollProgress();
          if (window.flutter_inappwebview) {
            window.flutter_inappwebview.callHandler('onPageChanged', Math.round(progress * 1000));
          }
        }, 200);
      }, { passive: true });
    }

    // b 层 transitionend 监听（动画结束清理）
    if (contentB) {
      contentB.addEventListener('transitionend', function(e) {
        if (e.target !== contentB) return;
        if (e.propertyName !== 'transform') return;
        onAnimEnd();
      });
    }

    // 等待 DOM 渲染完成后通知 Dart 侧
    requestAnimationFrame(function() {
      requestAnimationFrame(function() {
        notifyPageCountReady();
      });
    });
  }

  // 更新视口尺寸 CSS 变量
  function updateViewportSize() {
    var root = document.documentElement;
    root.style.setProperty('--reader-vw', window.innerWidth + 'px');
    root.style.setProperty('--reader-vh', window.innerHeight + 'px');
  }

  // 禁用所有手势缩放
  // 多层防护：iOS gesture 事件 + touchstart/touchmove 多指拦截 + 双击 + wheel
  // 关键：必须在 touchstart 阶段就拦截多指，仅 touchmove 拦不住 Android
  // WebView 底层手势识别器（它在 touchstart 时就进入缩放模式）
  function disableGestureZoom() {
    // iOS: gesturestart/change/end
    document.addEventListener('gesturestart', function(e) { e.preventDefault(); }, { passive: false });
    document.addEventListener('gesturechange', function(e) { e.preventDefault(); }, { passive: false });
    document.addEventListener('gestureend', function(e) { e.preventDefault(); }, { passive: false });

    // 通用: touchstart 阶段检测多指，立即 preventDefault 阻止 WebView 进入缩放模式
    // （touchstart 不阻塞滚动，可以放心用 passive:false）
    document.addEventListener('touchstart', function(e) {
      if (e.touches.length > 1) {
        e.preventDefault();
      }
    }, { passive: false });

    // touchmove 多指也拦截（双保险）
    // 关键：必须 passive:true，否则浏览器在每次 touchmove 都要同步执行 JS，
    // 会阻塞主线程的滚动响应，导致滚动模式严重卡顿（passive:false 是滚动卡顿元凶）
    // supportZoom:false + viewport user-scalable=no 已禁用缩放，多指时即便不
    // preventDefault 也不会触发缩放
    document.addEventListener('touchmove', function(e) {
      if (e.touches.length > 1) {
        e.preventDefault();
      }
    }, { passive: true });

    // 双击检测：仅记录时间戳，不 preventDefault（双击放大已由 supportZoom:false 禁用）
    // touchend passive:true 让浏览器滚动结束时不受 JS 阻塞
    var lastTouchEnd = 0;
    document.addEventListener('touchend', function() {
      var now = Date.now();
      if (now - lastTouchEnd <= 300) {
        // 双击：不阻止默认行为（缩放已禁），仅日志
        console.log('[reader] double tap detected');
      }
      lastTouchEnd = now;
    }, { passive: true });

    // 鼠标滚轮缩放（Ctrl+wheel）
    document.addEventListener('wheel', function(e) {
      if (e.ctrlKey) e.preventDefault();
    }, { passive: false });
  }

  function getColumnWidth() {
    // column-width = 安全区宽度（已扣除 padding）
    //
    // 必须用 contentA.clientWidth，不能用 getComputedStyle 读 CSS 自定义属性：
    // 未注册（无 @property）的自定义属性在 JS 端 getComputedStyle 返回的是
    // substituted value（var() 替换后的 calc/min 表达式字符串），parseFloat 解析
    // NaN，导致 getPageCount 算出错误页数、jumpToPage translate3d 偏移错误。
    // 即使部分 WebView 会自动计算 calc，行为也不一致。clientWidth 是布局后实际
    // 像素值，最可靠（C1 bug 修复）
    if (contentA) {
      var w = contentA.clientWidth;
      if (w > 0) return w;
    }
    // 兜底：用 viewport - padding（避免 padding 漏算导致 column-width 偏大）
    var cs = getComputedStyle(document.documentElement);
    var pl = parseFloat(cs.paddingLeft) || 0;
    var pr = parseFloat(cs.paddingRight) || 0;
    return Math.max(100, window.innerWidth - pl - pr);
  }

  function getPaddingLeft() {
    // padding 在 html 上（参考 lumina），不在 #reader-root
    return parseFloat(getComputedStyle(document.documentElement).paddingLeft) || 0;
  }

  function getPaddingRight() {
    return parseFloat(getComputedStyle(document.documentElement).paddingRight) || 0;
  }

  function getPageCount() {
    if (config.isScrollMode) return 1;
    if (!contentA) return 1;
    var columnWidth = getColumnWidth();
    var gap = config.columnGap || 0;
    var scrollWidth = contentA.scrollWidth;
    if (columnWidth + gap <= 0) return 1;
    // 用 ceil：内容哪怕只溢出第 2 列一点点，也是 2 页
    // 减 1px 容差：避免浮点误差导致多算一个空白页
    var pageCount = Math.ceil((scrollWidth - 1) / (columnWidth + gap));
    return Math.max(1, pageCount);
  }

  function getCurrentPage() {
    if (config.isScrollMode) return 0;
    return currentPage;
  }

  // ============ 翻页核心 ============
  // animate: true=带动画（用户翻页）, false=无动画（进度恢复/初始化）
  function jumpToPage(pageIndex, animate) {
    if (config.isScrollMode) return;
    if (!contentA || !contentB) {
      console.log('[reader] jumpToPage skipped: contentA/B not ready');
      return;
    }

    var pageCount = getPageCount();
    if (pageIndex < 0) pageIndex = 0;
    if (pageIndex >= pageCount) pageIndex = pageCount - 1;

    var useAnim = animate !== false && animEnabled && !isAnimating;
    console.log('[reader] jumpToPage', pageIndex, 'animate=' + animate, 'useAnim=' + useAnim, 'currentPage=' + currentPage, 'pageCount=' + pageCount);

    if (!useAnim) {
      // 无动画：a 直接跳到目标页，b 隐藏重置
      // 清除动画状态（防止上次动画残留的 isAnimating/animEndTimer 干扰）
      if (animEndTimer) {
        clearTimeout(animEndTimer);
        animEndTimer = null;
      }
      isAnimating = false;
      jumpA(pageIndex, false);
      hideB();
      currentPage = pageIndex;
      notifyPageChanged(pageIndex);
      return;
    }

    // 有动画：用 b 做过渡
    var isForward = pageIndex > currentPage;
    var columnWidth = getColumnWidth();
    var gap = config.columnGap || 0;
    var step = columnWidth + gap;
    var mode = config.pageModeIndex;
    var duration = config.pageAnimDurationMs;

    // 用 try-finally 保护 isAnimating，防止异常导致卡死
    try {
      // 1. 显式重置 a 起点到当前页（无动画），防止上次动画残留
      contentA.style.transition = 'none';
      contentA.style.transform = 'translate3d(' + (-currentPage * step) + 'px, 0, 0)';
      void contentA.offsetHeight;

      // 2. b 跳到动画起点（无动画），具体位置由 mode 决定
      contentB.style.transition = 'none';
      contentB.style.transformStyle = 'preserve-3d';
      if (isForward) {
        contentB.style.transform = 'translate3d(' + (-(pageIndex - 1) * step) + 'px, 0, 0)';
      } else {
        contentB.style.transform = 'translate3d(' + (-(pageIndex + 1) * step) + 'px, 0, 0)';
      }
      void contentB.offsetHeight;

      // 3. 显示 b 并标记动画中
      contentB.classList.add('animating');
      isAnimating = true;

      // 4. 设置 transition 和终点 transform
      var aTiming = 'ease-out';
      var bTiming = 'ease-out';
      if (mode === 2) {
        aTiming = 'none';
        bTiming = 'cubic-bezier(0.4, 0, 1, 1)';
      } else if (mode === 3) {
        aTiming = 'none';
        bTiming = 'cubic-bezier(0.25, 0.1, 0.25, 1)';
      }

      if (aTiming === 'none') {
        contentA.style.transition = 'none';
      } else {
        contentA.style.transition = 'transform ' + duration + 'ms ' + aTiming;
        void contentA.offsetHeight;
        contentA.style.transform = 'translate3d(' + (-pageIndex * step) + 'px, 0, 0)';
      }

      if (mode === 3) {
        // simulation 模式：b 像书页一样从侧边翻入盖到当前页
        //
        // 关键修复（C2 + C3）：
        // 1. transformOrigin 必须用具体像素值（目标页的边缘），不能用
        //    'right center'/'left center'——那是 b 容器整体最右/左边缘
        //    （scrollWidth 可达几千 px，远在视口外），旋转中心错位
        // 2. b 全程 translate3d 不变（在目标页位置），只 rotateY 变化，
        //    实现"翻入"效果（原代码起点终点 translate3d 不同，变成滑动+翻转混合）
        // 3. 起点 transform 包含 rotateY，必须先关 transition + reflow + 再开
        //    transition，否则从上面设置的 slide/cover 起点 transform 跑到
        //    simulation 起点 transform 会触发一次多余 transition
        // 4. 父元素 #reader-stage 需要 perspective（CSS 中已加），否则
        //    rotateY 是正交投影无立体感
        contentB.style.transition = 'none';
        if (isForward) {
          // 翻向下一页：b 从右边翻入
          // transformOrigin = 目标页右边缘 = (pageIndex+1) * step
          // （b 容器原始坐标系，第 pageIndex 列的右边缘；
          //  应用 translate3d(-pageIndex*step) 后正好位于视口右边缘）
          contentB.style.transformOrigin = ((pageIndex + 1) * step) + 'px 50%';
          // 起点：b 在目标页位置，立着朝右
          // rotateY(90deg) 绕右边旋转：右边不动、左边远离观察者
          // → b 正面朝向视口右侧，从视口看不见正面
          contentB.style.transform = 'translate3d(' + (-pageIndex * step) + 'px, 0, 0) rotateY(90deg)';
        } else {
          // 翻向上一页：b 从左边翻入
          // transformOrigin = 目标页左边缘 = pageIndex * step
          contentB.style.transformOrigin = (pageIndex * step) + 'px 50%';
          // 起点：b 在目标页位置，立着朝左
          // rotateY(-90deg) 绕左边旋转：左边不动、右边远离观察者
          // → b 正面朝向视口左侧，从视口看不见正面
          contentB.style.transform = 'translate3d(' + (-pageIndex * step) + 'px, 0, 0) rotateY(-90deg)';
        }
        void contentB.offsetHeight; // 强制 reflow 让起点 transform 生效
        // 再开启 transition
        contentB.style.transition = 'transform ' + duration + 'ms ' + bTiming;
        // 下一帧设终点（平躺、正面朝向观察者），触发 transition
        requestAnimationFrame(function() {
          contentB.style.transform = 'translate3d(' + (-pageIndex * step) + 'px, 0, 0) rotateY(0deg)';
        });
      } else {
        // slide/cover 模式：b 平移到目标页位置
        contentB.style.transition = 'transform ' + duration + 'ms ' + bTiming;
        void contentB.offsetHeight;
        contentB.style.transform = 'translate3d(' + (-pageIndex * step) + 'px, 0, 0)';
      }
    } catch (err) {
      // 异常时立即清理动画状态，防止 isAnimating 卡死导致后续点击全被吞
      console.error('[reader] jumpToPage animation error:', err);
      isAnimating = false;
      hideB();
      jumpA(pageIndex, false);
      currentPage = pageIndex;
      notifyPageChanged(pageIndex);
      return;
    }

    // 5. 兜底超时（防止 transitionend 不触发）
    if (animEndTimer) clearTimeout(animEndTimer);
    animEndTimer = setTimeout(function() {
      onAnimEnd();
    }, duration + 50);

    currentPage = pageIndex;
  }

  // a 直接跳到指定页（无动画）
  function jumpA(pageIndex, useAnim) {
    if (!contentA) return;
    var columnWidth = getColumnWidth();
    var gap = config.columnGap || 0;
    var step = columnWidth + gap;
    if (!useAnim) {
      contentA.style.transition = 'none';
    }
    contentA.style.transform = 'translate3d(' + (-pageIndex * step) + 'px, 0, 0)';
    if (!useAnim) {
      void contentA.offsetHeight;
      contentA.style.transition = '';
    }
  }

  // 隐藏并重置 b 层
  function hideB() {
    if (!contentB) return;
    contentB.classList.remove('animating');
    contentB.style.transition = 'none';
    contentB.style.transform = 'translate3d(0, 0, 0)';
    contentB.style.transformOrigin = '';
    contentB.style.transformStyle = '';
    void contentB.offsetHeight;
    contentB.style.transition = '';
  }

  // 动画结束回调
  function onAnimEnd() {
    if (!isAnimating) return;
    if (animEndTimer) {
      clearTimeout(animEndTimer);
      animEndTimer = null;
    }
    isAnimating = false;
    // a 跳到当前页（无动画）
    jumpA(currentPage, false);
    // b 隐藏重置
    hideB();
    // 通知 Dart 侧页码变更
    notifyPageChanged(currentPage);
  }

  function getScrollProgress() {
    if (config.isScrollMode) {
      var st = body.scrollTop || document.documentElement.scrollTop;
      // 用 body.clientHeight 而非 window.innerHeight：
      // scroll 模式下 body { height: 100% }，其 clientHeight = html content area
      // = vh - paddingTop - paddingBottom = safe-height，小于 window.innerHeight
      // (= vh)。用 innerHeight 会让分母偏大，到底时显示 ~96% 而非 100%（C5 bug）
      var sh = body.scrollHeight - body.clientHeight;
      return sh > 0 ? st / sh : 0;
    }
    return getPageCount() > 0 ? currentPage / getPageCount() : 0;
  }

  function setScrollProgress(ratio) {
    if (!config.isScrollMode) {
      var pageCount = getPageCount();
      var page = Math.round(ratio * pageCount);
      jumpToPage(page, false);
      return;
    }
    var sh = body.scrollHeight - body.clientHeight;
    body.scrollTop = sh * ratio;
  }

  function getScrollOffset() {
    if (!config.isScrollMode) return 0;
    return body.scrollTop || document.documentElement.scrollTop || 0;
  }

  function scrollToOffset(px) {
    if (!config.isScrollMode) return;
    body.scrollTop = Math.max(0, px);
  }

  function scrollByViewport(direction) {
    if (!config.isScrollMode) return -1;
    // 用 body.clientHeight 而非 window.innerHeight（同 getScrollProgress）
    var viewport = body.clientHeight;
    var maxScroll = body.scrollHeight - viewport;
    if (maxScroll <= 0) return -1;
    var current = body.scrollTop || 0;
    var target = current + direction * viewport * 0.9;
    if (target <= 0) {
      body.scrollTop = 0;
      return -1;
    }
    if (target >= maxScroll) {
      body.scrollTop = maxScroll;
      return -1;
    }
    body.scrollTop = target;
    return target / maxScroll;
  }

  function checkTap(x, y) {
    var root = document.getElementById('reader-root');
    var rect = root.getBoundingClientRect();
    var localX = x - rect.left;
    var localY = y - rect.top;
    var el = document.elementFromPoint(localX, localY);
    if (el && el.tagName === 'IMG') {
      notifyImageTap(el.src, el.getBoundingClientRect());
      return;
    }
    notifyTap(x, y);
  }

  // ============ Dart 通信 ============
  function notifyPageCountReady() {
    var count = getPageCount();
    var cw = getColumnWidth();
    var sw = contentA ? contentA.scrollWidth : 0;
    console.log('[reader] pageCountReady', 'count=' + count,
      'scrollWidth=' + sw, 'columnWidth=' + cw,
      'vw=' + window.innerWidth, 'vh=' + window.innerHeight);
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
