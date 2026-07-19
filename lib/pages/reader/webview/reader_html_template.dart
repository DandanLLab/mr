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
    required int chapterIndex,
  }) {
    final css = _generateCss(provider, isScrollMode);
    final js = _readerJs();
    final paragraphsHtml = buildParagraphsHtml(content, provider);
    final titleHtml = buildTitleHtml(title, provider, chapterIndex);
    // 滚动模式：初始章节标题放进 #reader-content-a 内部第一个位置
    // - prependChapter 才能正确插入到初始标题之前，避免顶部出现两个标题
    //   （否则初始标题在 #reader-root 顶部「悬浮」，prepend 的新章节标题在
    //    #reader-content-a 内，滚到顶部时两个标题同时可见）
    // - initChapterObserver 用 contentA.querySelectorAll 查找标题，放进去后
    //   初始章节标题才能被 IntersectionObserver 注册，滚动时正确触发
    //   onChapterVisible 回调
    // 分页模式：保持原结构（标题在 #reader-root 顶部，#reader-stage 外），
    //   因为 #reader-content-a 是 absolute 定位的 column 容器，标题放进去
    //   会被当成 column 内容影响分页计算
    final contentAInner =
        isScrollMode ? '$titleHtml\n        $paragraphsHtml' : paragraphsHtml;
    final rootTitle = isScrollMode ? '' : titleHtml;

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <meta name="format-detection" content="telephone=no, email=no, address=no">
  <style>
    $css
  </style>
</head>
<body>
  <div id="reader-root">
    $rootTitle
    <div id="reader-stage">
      <div id="reader-content-a" class="reader-content">
        $contentAInner
      </div>
      <div id="reader-content-b" class="reader-content">
        $paragraphsHtml
      </div>
    </div>
  </div>
  <!-- 文字选择浮动菜单：JS 监听 selectionchange 后填充菜单项并定位显示 -->
  <div id="reader-selection-menu" role="menu"></div>
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
    // Phase 3.3：菜单毛玻璃主题色（按背景亮度自动切换亮/暗菜单）
    // - 用 computeLuminance() 判断：暗色背景 → 深色菜单 + 浅字；亮色背景 → 白底 + 深字
    // - 不再用 var(--reader-text-color) 反色风格（与毛玻璃不搭）
    final isDarkBg = provider.backgroundColor.computeLuminance() < 0.5;
    final menuBg = isDarkBg ? 'rgba(38, 38, 38, 0.78)' : 'rgba(255, 255, 255, 0.82)';
    final menuText = isDarkBg ? '#FAFAFA' : '#1A1A1A';
    final menuDivider = isDarkBg ? 'rgba(255, 255, 255, 0.16)' : 'rgba(0, 0, 0, 0.10)';
    final menuShadow = isDarkBg
        ? '0 6px 24px rgba(0, 0, 0, 0.45), 0 2px 6px rgba(0, 0, 0, 0.28)'
        : '0 6px 24px rgba(0, 0, 0, 0.18), 0 2px 6px rgba(0, 0, 0, 0.10)';

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
  /* Phase 3.3：菜单专用变量（按阅读器背景亮度自动适配亮/暗） */
  --reader-menu-bg: $menuBg;
  --reader-menu-text: $menuText;
  --reader-menu-divider: $menuDivider;
  --reader-menu-shadow: $menuShadow;
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

/* ============ 文字选择菜单 CSS ============ */
/* 自定义浮动菜单：选区上方/下方显示，替代 Android 默认 ActionMode（更美观、统一） */
/* Phase 3.3：毛玻璃 + 淡入缩放动画（opacity + transform 过渡替代 display 切换） */
#reader-selection-menu {
  position: fixed;
  /* 用 opacity + pointer-events 控制可见性，保留 display:flex 让 transform 生效 */
  display: flex;
  opacity: 0;
  transform: scale(0.92);
  pointer-events: none;
  flex-direction: row;
  align-items: center;
  padding: 0 4px;
  /* 毛玻璃：半透明背景 + backdrop-filter 模糊
     - Android WebView 5+ / iOS WKWebView 都支持 backdrop-filter
     - 不支持时降级到半透明背景（仍是可用样式） */
  background-color: var(--reader-menu-bg);
  -webkit-backdrop-filter: blur(14px) saturate(180%);
  backdrop-filter: blur(14px) saturate(180%);
  border-radius: 12px;
  /* 1px 内边框增加质感（亮暗都用低对比白） */
  border: 1px solid rgba(255, 255, 255, 0.10);
  box-shadow: var(--reader-menu-shadow);
  z-index: 9999;
  /* 避免 long-press 系统菜单与本菜单同时弹出 */
  -webkit-touch-callout: none;
  /* will-change 提示浏览器合成层加速（替代原 translateZ(0)） */
  will-change: transform, opacity;
  /* 防止菜单自身被选中导致选区变化 */
  user-select: none;
  -webkit-user-select: none;
  max-width: 90vw;
  overflow: hidden;
  /* 淡入缩放过渡 */
  transition: opacity 120ms ease-out, transform 120ms ease-out;
  /* transform-origin 顶部居中：缩放从选区上方展开 */
  transform-origin: center top;
}

#reader-selection-menu.visible {
  opacity: 1;
  transform: scale(1);
  pointer-events: auto;
}

#reader-selection-menu .menu-item {
  display: flex;
  align-items: center;
  padding: 8px 14px;
  background: transparent;
  border: none;
  color: var(--reader-menu-text);
  font-size: 14px;
  font-family: var(--reader-font-family);
  cursor: pointer;
  white-space: nowrap;
  -webkit-tap-highlight-color: transparent;
}

#reader-selection-menu .menu-item:active {
  background-color: rgba(128, 128, 128, 0.18);
  border-radius: 8px;
}

#reader-selection-menu .menu-item .menu-icon {
  font-size: 16px;
  line-height: 1;
}

#reader-selection-menu .menu-divider {
  width: 1px;
  height: 18px;
  background-color: var(--reader-menu-divider);
  margin: 0 2px;
  flex-shrink: 0;
}

/* Phase 3.4：搜索结果高亮样式 */
.sel-hl-search {
  background-color: #FFEB3B !important;
  color: #000 !important;
  border-radius: 2px;
}

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
  /* scroll-behavior: auto 让滚动 1:1 跟手
     - smooth 会让滚动有缓动效果，但用户停止滑动后还会继续滚一段，
       造成「惯性停不下来」的视觉感受
     - auto 模式下，滚动完全跟随手势，停手即停滚（浏览器原生物理惯性仍存在，
       但不会有额外的 JS/CSS 缓动叠加）
     - 这是用户反馈「惯性停不下来」的修复 */
  scroll-behavior: auto;
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
  ///
  /// 改为 public（原 _buildParagraphsHtml）以支持滚动模式无缝衔接：
  /// novel_reader_page 加载下一章后，调用此方法生成段落 HTML，
  /// 再通过 controller.appendChapter 追加到 WebView DOM，
  /// 避免整页 reload 丢失当前滚动位置。
  static String buildParagraphsHtml(
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
  ///
  /// 改为 public（原 _buildTitleHtml）以支持滚动模式无缝衔接：
  /// 与 buildParagraphsHtml 配合使用，生成下章标题 HTML 供 appendChapter 追加。
  static String buildTitleHtml(String title, ReaderProvider provider, int chapterIndex) {
    if (!provider.showChapterTitle || title.isEmpty) return '';
    if (provider.titleMode == 2) return '';
    // 加 data-chapter-index 属性供 IntersectionObserver 监测
    // 滚动模式下用户滚到此标题时 Dart 侧 _onChapterVisible 触发更新 UI
    return '<h1 id="reader-title" class="reader-title" data-chapter-index="$chapterIndex">${_escapeHtml(title)}</h1>';
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
  // 滚动模式无缝衔接：是否已通知「接近底部」
  // - 触发后置 true 避免重复通知，Flutter 加载下章调 appendChapter 后会重置为 false
  // - 用户主动滚回顶部区域（remaining > threshold*1.5）也会重置，允许下次触发
  var nearEndNotified = false;
  // 滚动模式向上衔接：是否已通知「接近顶部」
  // - 与 nearEndNotified 对称，触发后置 true，prependChapter 后重置为 false
  // - 用户主动滚回下方（scrollTop > threshold*2）也会重置，允许下次触发
  var nearStartNotified = false;
  // 滚动模式无缝衔接：追加的章节数（用于 Dart 侧查询当前已加载到第几章）
  var appendedChapterCount = 0;
  // 滚动模式向上衔接：向前插入的章节数
  var prependedChapterCount = 0;

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
      // 进度回调走 200ms 防抖（避免高频 setState）；
      // 接近底部/顶部检测每次 scroll 都执行（nearEndNotified / nearStartNotified 防重入）。
      //
      // 关键修复：原版把接近检测也放在 200ms 防抖回调里，用户持续滚动时
      // scrollTimer 被不断 clearTimeout + setTimeout 重置，回调永远不执行
      // → onScrollNearEnd / onScrollNearStart 永远不触发 → 用户滚到末尾看到空白
      // → 章节内容"晚一拍冒出来"形成视觉跳动。
      // 拆出来后每次 scroll 都检测，配合 nearEndNotified / nearStartNotified
      // 防重入标志，能及时触发预加载。
      var scrollTimer = null;
      body.addEventListener('scroll', function() {
        // 1. 即时检测：接近底部/顶部（每次 scroll 都执行，防重入靠标志位）
        var viewport = body.clientHeight;
        var scrollTop = body.scrollTop || 0;
        var remaining = body.scrollHeight - scrollTop - viewport;
        var threshold = viewport * 2.0;

        // 无缝衔接：检测是否接近底部，触发 onScrollNearEnd 让 Dart 加载下一章
        // - threshold = 2.0 * clientHeight（约 2 屏）：提前加载给章节拉取留时间
        // - 触发后 nearEndNotified=true 防止重复通知；appendChapter 后会重置
        // - 用户滚回上方（remaining > threshold*2）也会重置，允许下次触发
        if (remaining < threshold && !nearEndNotified) {
          nearEndNotified = true;
          if (window.flutter_inappwebview) {
            window.flutter_inappwebview.callHandler('onScrollNearEnd');
          }
        } else if (remaining > threshold * 2 && nearEndNotified) {
          nearEndNotified = false;
        }

        // 向上衔接：检测是否接近顶部，触发 onScrollNearStart 让 Dart 加载上一章
        // - 与接近底部对称，threshold = 2.0 * clientHeight
        // - 触发后 nearStartNotified=true 防止重复通知；prependChapter 后会重置
        // - 用户滚回下方（scrollTop > threshold*2）也会重置，允许下次触发
        if (scrollTop < threshold && !nearStartNotified) {
          nearStartNotified = true;
          if (window.flutter_inappwebview) {
            window.flutter_inappwebview.callHandler('onScrollNearStart');
          }
        } else if (scrollTop > threshold * 2 && nearStartNotified) {
          nearStartNotified = false;
        }

        // 2. 防抖回调：进度通知（避免高频 setState 让 UI 卡顿）
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

    // 初始化文字选择菜单（替代 Android 默认 ActionMode）
    // - 监听 selectionchange 防抖显示菜单
    // - 监听 scroll/touchstart 隐藏菜单
    initSelectionMenu();

    // 滚动模式：初始化章节边界观察器
    // - 监听所有 [data-chapter-index] 元素（初始标题 + appendChapter 追加的标题）
    // - 进入屏幕中部 10% 区域时回调 Dart 侧 onChapterVisible(chapterIndex)
    // - 让 UI 章节标题/进度条实时跟随用户滚动更新
    initChapterObserver();

    // 等待 DOM 渲染完成后通知 Dart 侧
    // 首次通知：rAF 双帧后立即通知，让 Dart 尽快拿到初步 pageCount 启动渲染
    // （避免首次通知延迟导致首屏白屏）
    requestAnimationFrame(function() {
      requestAnimationFrame(function() {
        notifyPageCountReady();
        // 二次通知：等图片和字体加载完成后再通知一次（M1 修复）
        // - 图片加载会改变段落高度，触发 column 布局重排，pageCount 可能变化
        // - 字体加载完成后文本宽度变化，pageCount 可能变化
        // - 如果不二次通知，Dart 侧拿到的是旧 pageCount，jumpToPage 用错页数
        // - Dart 侧 _onWebviewPageCountReady 会判断 isUpdate=true 走更新分支，
        //   只更新 _webviewPageCount + clamp 当前页，不重新恢复进度
        notifyPageCountReadyWhenStable();
      });
    });
  }

  // 等图片和字体加载完成后通知 pageCount 更新（M1 修复）
  function notifyPageCountReadyWhenStable() {
    var imgPromises = [];
    var imgs = document.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      (function(img) {
        if (!img.complete) {
          imgPromises.push(new Promise(function(resolve) {
            img.addEventListener('load', resolve, { once: true });
            img.addEventListener('error', resolve, { once: true });
          }));
        }
      })(imgs[i]);
    }
    // document.fonts.ready：等所有字体加载完成（含 web font）
    // 旧 WebView 不支持 document.fonts 则跳过（用 Promise.resolve 兜底）
    var fontPromise = (document.fonts && document.fonts.ready)
      ? document.fonts.ready
      : Promise.resolve();
    Promise.all(imgPromises.concat([fontPromise])).then(function() {
      // 加载完成后等一帧让 column 布局重排完成
      requestAnimationFrame(function() {
        notifyPageCountReady();
      });
    }).catch(function() {
      // 兜底：异常时也通知一次
      requestAnimationFrame(function() {
        notifyPageCountReady();
      });
    });
  }

  // ============ 文字选择菜单 ============
  // 替代 Android 默认 ActionMode（系统菜单样式不统一）。
  // - 监听 selectionchange 防抖 250ms 显示菜单
  // - 监听 scroll/touchstart 隐藏菜单
  // - 菜单项 click 时通过 callHandler 通知 Dart 处理
  // 配套：reader_webview.dart 中 disableContextMenu=true 禁用系统菜单
  var selMenuEl = null;
  var selShowTimer = null;
  var selLastText = '';

  function initSelectionMenu() {
    selMenuEl = document.getElementById('reader-selection-menu');
    if (!selMenuEl) {
      console.warn('[reader] selection menu element not found');
      return;
    }
    buildSelectionMenuItems();

    // 防抖显示菜单：选区频繁变化时只在稳定后显示
    document.addEventListener('selectionchange', function() {
      if (selShowTimer) clearTimeout(selShowTimer);
      selShowTimer = setTimeout(showSelectionMenu, 250);
    });

    // 滚动时隐藏菜单（选区可能跟随滚动，菜单位置会错乱）
    window.addEventListener('scroll', hideSelectionMenu, { passive: true });
    body.addEventListener('scroll', hideSelectionMenu, { passive: true });

    // 视口变化时隐藏菜单
    window.addEventListener('resize', hideSelectionMenu, { passive: true });
  }

  function buildSelectionMenuItems() {
    if (!selMenuEl) return;
    selMenuEl.innerHTML = '';
    var items = [
      { label: '复制', action: 'copy' },
      { label: '高亮', action: 'highlight' },
      { label: '查词', action: 'lookup' },
      { label: '分享', action: 'share' },
      { label: '全选', action: 'selectAll' },
      { label: '删高亮', action: 'removeHighlight' },
      { label: '搜索', action: 'search' }
    ];
    items.forEach(function(item, idx) {
      if (idx > 0) {
        var div = document.createElement('div');
        div.className = 'menu-divider';
        selMenuEl.appendChild(div);
      }
      var btn = document.createElement('button');
      btn.className = 'menu-item';
      btn.type = 'button';
      btn.textContent = item.label;
      // 用 pointerdown 而非 click：避免 button 点击导致 selection 被清除
      // （Android WebView 中点击 button 会清除 window.getSelection()）
      btn.addEventListener('pointerdown', function(e) {
        e.stopPropagation();
        e.preventDefault();
        onSelectionMenuItemClick(item.action);
      });
      selMenuEl.appendChild(btn);
    });
  }

  // ============ Phase 4：长按段落菜单（已移除，统一走文字选择菜单） ============

  function getSelectionText() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return '';
    var text = sel.toString();
    // 去掉首尾空白后判断长度（避免全是空格的「假选区」）
    return text;
  }

  function getSelectionRect() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return null;
    var range = sel.getRangeAt(0);
    var rect = range.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return null;
    return rect;
  }

  function positionSelectionMenu(rect) {
    if (!selMenuEl) return;
    var menuH = 40;
    var menuW = selMenuEl.offsetWidth || 240;
    var margin = 8;
    var top;
    if (rect.top - menuH - margin >= 0) {
      top = rect.top - menuH - margin;
    } else {
      top = rect.bottom + margin;
    }
    if (top + menuH > window.innerHeight) {
      top = window.innerHeight - menuH - margin;
    }
    if (top < 0) top = margin;
    var left = rect.left + rect.width / 2 - menuW / 2;
    if (left < margin) left = margin;
    if (left + menuW > window.innerWidth - margin) {
      left = window.innerWidth - menuW - margin;
    }
    selMenuEl.style.top = top + 'px';
    selMenuEl.style.left = left + 'px';
  }

  function showSelectionMenu() {
    if (!selMenuEl) return;
    var text = getSelectionText();
    if (!text || text.trim().length === 0) {
      hideSelectionMenu();
      return;
    }
    var rect = getSelectionRect();
    if (!rect) {
      hideSelectionMenu();
      return;
    }
    selLastText = text;
    positionSelectionMenu(rect);
    selMenuEl.classList.add('visible');
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler(
        'onSelectionReady', text,
        rect.left, rect.top, rect.width, rect.height);
    }
  }

  function hideSelectionMenu() {
    if (!selMenuEl) return;
    if (!selMenuEl.classList.contains('visible')) return;
    selMenuEl.classList.remove('visible');
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler('onHideSelectionMenu');
    }
  }

  function onSelectionMenuItemClick(action) {
    var text = selLastText || getSelectionText();
    var rect = getSelectionRect();
    var rl = rect ? rect.left : 0;
    var rt = rect ? rect.top : 0;
    var rw = rect ? rect.width : 0;
    var rh = rect ? rect.height : 0;

    // Phase 3.1：全选 - JS 直接处理，扩展 Range 到 #reader-content-a 全文
    // - 不调 Dart（纯前端操作）
    // - 选区变化后 selectionchange 监听会触发 showSelectionMenu 重新定位
    if (action === 'selectAll') {
      var contentAll = document.getElementById('reader-content-a') || contentA;
      if (contentAll) {
        var rangeAll = document.createRange();
        rangeAll.selectNodeContents(contentAll);
        var selAll = window.getSelection();
        if (selAll) {
          selAll.removeAllRanges();
          selAll.addRange(rangeAll);
        }
      }
      return;
    }

    // Phase 3.1：删除当前选区命中的 .sel-hl 元素
    // - JS 端先移除视觉标记，再通知 Dart 删除持久化记录
    if (action === 'removeHighlight') {
      removeHighlightInSelection();
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler(
          'onSelectionAction', 'removeHighlight', text, rl, rt, rw, rh);
      }
      var selRm = window.getSelection();
      if (selRm) selRm.removeAllRanges();
      hideSelectionMenu();
      return;
    }

    // Phase 3.1：全文搜索 - Dart 弹 BottomSheet
    if (action === 'search') {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler(
          'onSelectionAction', 'search', text, rl, rt, rw, rh);
      }
      var selS = window.getSelection();
      if (selS) selS.removeAllRanges();
      hideSelectionMenu();
      return;
    }

    // 原有 copy / highlight / lookup / share 分支
    if (!text) {
      hideSelectionMenu();
      return;
    }
    if (window.flutter_inappwebview) {
      window.flutter_inappwebview.callHandler(
        'onSelectionAction', action, text, rl, rt, rw, rh);
    }
    // 复制：JS 直接处理（Clipboard API），同时 Dart 也会处理（兜底）
    if (action === 'copy') {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(function(e) {
          console.warn('[reader] clipboard write failed:', e);
        });
      }
      var sel1 = window.getSelection();
      if (sel1) sel1.removeAllRanges();
      hideSelectionMenu();
    } else if (action === 'lookup' || action === 'share') {
      // 查词/分享：Dart 处理后清除选区
      var sel2 = window.getSelection();
      if (sel2) sel2.removeAllRanges();
      hideSelectionMenu();
    }
    // highlight：不清除选区，等 Dart 处理后调 hideSelectionMenu
  }

  // 高亮当前选区（Dart 弹颜色选择器后调用）
  //
  // 参数：
  // - colorIndex：颜色索引（0=黄/1=绿/2=蓝/3=粉/4=橙/5=紫）
  // - styleIndex：样式索引（0=背景色/1=下划线/2=删除线/3=波浪线）
  //
  // 实现：
  // - 单元素选区：用 range.surroundContents 包到 <span class="sel-hl"> 里
  // - 跨元素选区：surroundContents 会抛 DOMException，fallback 到
  //   document.execCommand('hiliteColor')（兼容跨段落选区）
  //
  // 注：本函数仅做即时视觉标记，不会持久化到 StorageService（持久化需
  // startIndex/endIndex，选区高亮系统将在后续迭代完善）。
  // 重启 WebView 后 mark 标签丢失。
  function highlightSelection(colorIndex, styleIndex) {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) {
      hideSelectionMenu();
      return false;
    }
    var range = sel.getRangeAt(0);
    if (range.collapsed) {
      hideSelectionMenu();
      return false;
    }

    var colors = ['#FFF176', '#A5D6A7', '#90CAF9', '#F48FB1', '#FFCC80', '#CE93D8'];
    var color = colors[colorIndex] || colors[0];
    var textDecoration = styleIndex === 1
      ? 'underline'
      : (styleIndex === 2 ? 'line-through' : (styleIndex === 3 ? 'underline wavy' : ''));

    var success = false;
    try {
      var mark = document.createElement('span');
      mark.className = 'sel-hl';
      mark.style.backgroundColor = styleIndex === 0 ? color : 'transparent';
      if (textDecoration) {
        mark.style.textDecoration = textDecoration;
        mark.style.textDecorationColor = color;
        mark.style.textDecorationThickness = '2px';
        mark.style.webkitTextDecorationColor = color;
      }
      try {
        range.surroundContents(mark);
        success = true;
      } catch (e) {
        // 跨元素选区（如跨段落）：surroundContents 会抛
        // DOMException: The boundary points of a Range are not valid
        // fallback 到 execCommand('hiliteColor')，仅做背景色
        try { document.execCommand('styleWithCSS', false, true); } catch (e2) {}
        success = document.execCommand('hiliteColor', false, color);
      }
    } catch (e) {
      console.warn('[reader] highlightSelection exception:', e);
    }

    if (success) {
      sel.removeAllRanges();
      hideSelectionMenu();
    }
    return success;
  }

  // Phase 3.1：删除当前选区命中的 .sel-hl 元素
  //
  // 实现：
  // - 用 TreeWalker 遍历选区公共祖先下所有 .sel-hl 元素
  // - 通过 range.intersectsNode 验证与当前选区有交集
  // - 把命中的 .sel-hl span 内容（文本节点）提到父级，移除 span
  //
  // 返回：删除的 .sel-hl 数量（用于 SnackBar 提示，由 Dart 侧通过持久化查询确认）
  function removeHighlightInSelection() {
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return 0;
    var range = sel.getRangeAt(0);
    if (range.collapsed) return 0;

    // 收集选区命中的 .sel-hl 元素
    var toRemove = [];
    var marks = contentA
      ? contentA.querySelectorAll('.sel-hl')
      : document.querySelectorAll('.sel-hl');
    for (var i = 0; i < marks.length; i++) {
      var mark = marks[i];
      if (range.intersectsNode(mark)) {
        toRemove.push(mark);
      }
    }

    // 移除每个 .sel-hl span，把内部子节点提到父级
    for (var j = toRemove.length - 1; j >= 0; j--) {
      var m = toRemove[j];
      var parent = m.parentNode;
      while (m.firstChild) {
        parent.insertBefore(m.firstChild, m);
      }
      parent.removeChild(m);
    }
    return toRemove.length;
  }

  // Phase 3.2：恢复持久化高亮（Dart 在章节加载后传入 JSON 列表）
  //
  // 参数 list: [{ id, selectedText, color, style, note, ... }]
  // - 用 TreeWalker 遍历 #reader-content-a 文本节点，查找 selectedText 第一次出现位置
  // - 用 range.surroundContents 包到 .sel-hl 里（跨段落匹配跳过，surroundContents 不支持）
  // - 同时给 mark 加 data-highlight-id 属性，便于按 id 删除
  function restoreHighlights(list) {
    if (!list || !list.length) return;
    if (!contentA) return;
    var colors = ['#FFF176', '#A5D6A7', '#90CAF9', '#F48FB1', '#FFCC80', '#CE93D8'];
    list.forEach(function(item) {
      try {
        var text = item.selectedText;
        if (!text || text.length === 0) return;
        var colorIndex = item.color || 0;
        var styleIndex = item.style || 0;
        var color = colors[colorIndex] || colors[0];
        var textDecoration = styleIndex === 1 ? 'underline'
          : (styleIndex === 2 ? 'line-through' : (styleIndex === 3 ? 'underline wavy' : ''));

        // 跳过已经恢复过的（按 data-highlight-id 防重复）
        if (item.id) {
          var exists = contentA.querySelector('[data-highlight-id="' + item.id + '"]');
          if (exists) return;
        }

        // 用 TreeWalker 找文本节点中第一次匹配
        var walker = document.createTreeWalker(contentA, NodeFilter.SHOW_TEXT, null);
        var found = false;
        while (walker.nextNode() && !found) {
          var node = walker.currentNode;
          var idx = node.nodeValue.indexOf(text);
          if (idx >= 0) {
            var r = document.createRange();
            r.setStart(node, idx);
            r.setEnd(node, idx + text.length);
            var mark = document.createElement('span');
            mark.className = 'sel-hl';
            if (item.id) mark.setAttribute('data-highlight-id', item.id);
            mark.style.backgroundColor = styleIndex === 0 ? color : 'transparent';
            if (textDecoration) {
              mark.style.textDecoration = textDecoration;
              mark.style.textDecorationColor = color;
              mark.style.webkitTextDecorationColor = color;
            }
            try {
              r.surroundContents(mark);
              found = true;
            } catch (e) {
              // 跨元素，跳过该文本节点继续找下一个
            }
          }
        }
      } catch (e) {
        console.warn('[reader] restoreHighlights item failed:', e);
      }
    });
  }

  // Phase 3.2：按 selectedText 删除视觉高亮（持久化由 Dart 侧处理）
  // - 遍历 #reader-content-a 下所有 .sel-hl
  // - textContent 完全匹配的移除 span（把内部子节点提到父级）
  function removeHighlightByText(text) {
    if (!text || !contentA) return 0;
    var marks = contentA.querySelectorAll('.sel-hl');
    var removed = 0;
    for (var i = marks.length - 1; i >= 0; i--) {
      var mark = marks[i];
      if (mark.textContent === text) {
        var parent = mark.parentNode;
        while (mark.firstChild) {
          parent.insertBefore(mark.firstChild, mark);
        }
        parent.removeChild(mark);
        removed++;
      }
    }
    return removed;
  }

  // Phase 3.4：全文搜索
  //
  // 遍历 #reader-content-a 下所有文本节点，查找 query 出现的所有位置。
  // - chapterIndex 通过查找祖先 [data-chapter-index] 或 .chapter-append-wrap 推断
  // - snippet 取匹配前后 20 字符作为预览
  // - 缓存到 searchResultsCache，供 scrollToSearchResult 复用
  //
  // 返回 JSON 字符串：[{ idx, chapterIndex, offset, length, snippet, top }]
  var searchResultsCache = [];
  function searchText(query) {
    searchResultsCache = [];
    if (!query || query.length === 0) return '[]';
    if (!contentA) return '[]';
    var results = [];
    var walker = document.createTreeWalker(contentA, NodeFilter.SHOW_TEXT, null);
    var idx = 0;
    while (walker.nextNode()) {
      var node = walker.currentNode;
      var text = node.nodeValue;
      var pos = 0;
      while (true) {
        var found = text.indexOf(query, pos);
        if (found < 0) break;
        // 推断 chapterIndex：找最近的 [data-chapter-index] 祖先或 .chapter-append-wrap
        var chapterIdx = -1;
        var parent = node.parentNode;
        while (parent && parent !== contentA) {
          if (parent.getAttribute && parent.getAttribute('data-chapter-index')) {
            chapterIdx = parseInt(parent.getAttribute('data-chapter-index'), 10);
            break;
          }
          if (parent.classList && parent.classList.contains('chapter-append-wrap')) {
            var title = parent.querySelector('[data-chapter-index]');
            if (title) {
              chapterIdx = parseInt(title.getAttribute('data-chapter-index'), 10);
            }
            break;
          }
          parent = parent.parentNode;
        }
        // 取前后 20 字符作为 snippet
        var snipStart = Math.max(0, found - 20);
        var snipEnd = Math.min(text.length, found + query.length + 20);
        var snippet = text.substring(snipStart, snipEnd);
        // 计算该位置在文档中的 top（用于结果列表展示）
        var rectRange = document.createRange();
        rectRange.setStart(node, found);
        rectRange.setEnd(node, found + query.length);
        var rect = rectRange.getBoundingClientRect();
        results.push({
          idx: idx,
          chapterIndex: chapterIdx,
          offset: found,
          length: query.length,
          snippet: snippet,
          top: rect.top + (window.scrollY || 0)
        });
        searchResultsCache.push({
          node: node,
          found: found,
          length: query.length
        });
        idx++;
        pos = found + query.length;
      }
    }
    return JSON.stringify(results);
  }

  // Phase 3.4：滚动到第 idx 个搜索结果并高亮
  // - 清除上次搜索高亮（lastSearchMark）
  // - 重新创建 range（旧 range 可能因 DOM 变化失效）
  // - 用 .sel-hl-search class 包裹，黄底黑字突出
  // - smooth 滚动到该位置（视口居中）
  var lastSearchMark = null;
  function scrollToSearchResult(idx) {
    if (idx < 0 || idx >= searchResultsCache.length) return false;
    // 清除上次高亮
    if (lastSearchMark && lastSearchMark.parentNode) {
      try {
        var parent = lastSearchMark.parentNode;
        while (lastSearchMark.firstChild) {
          parent.insertBefore(lastSearchMark.firstChild, lastSearchMark);
        }
        parent.removeChild(lastSearchMark);
      } catch (e) {
        console.warn('[reader] clear lastSearchMark failed:', e);
      }
      lastSearchMark = null;
    }
    var item = searchResultsCache[idx];
    var r = document.createRange();
    try {
      r.setStart(item.node, item.found);
      r.setEnd(item.node, item.found + item.length);
      var mark = document.createElement('span');
      mark.className = 'sel-hl sel-hl-search';
      mark.style.backgroundColor = '#FFEB3B';
      mark.style.color = '#000';
      r.surroundContents(mark);
      lastSearchMark = mark;
      // 滚动到该位置（视口居中）
      var rect = mark.getBoundingClientRect();
      var targetY = (window.scrollY || 0) + rect.top - window.innerHeight / 2;
      window.scrollTo({ top: targetY, behavior: 'smooth' });
      return true;
    } catch (e) {
      console.warn('[reader] scrollToSearchResult failed:', e);
      return false;
    }
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
      // 通知 Dart 端用户手指已离开 WebView
      // InAppWebView 是 PlatformView，会吞掉 Flutter 的 PointerUpEvent，
      // 导致 ReaderPageView._onPointerUp 不被调用，翻页动画覆盖层无法及时
      // 销毁（原靠 600ms 兜底 timer，用户感觉"要再点一次才能销毁动画"）
      // 通过 touchend handler 即时通知 Dart 触发 _finalizeTurn
      try {
        window.flutter_inappwebview.callHandler('onTouchEnd');
      } catch (e) {
        console.log('[reader] callHandler onTouchEnd 失败:', e);
      }
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

  // ============ 滚动模式无缝衔接 ============
  // 在 #reader-content-a 末尾追加章节标题 + 段落 HTML，不触发整页 reload
  // - 滚动模式下 .reader-content 是普通 div（column-width:auto），appendChild 即可
  // - 标题用 createElement + textContent 创建，避免 XSS
  // - 段落 HTML 由 Dart 侧 ReaderHtmlTemplate.buildParagraphsHtml 生成，可信
  // - 追加后重置 nearEndNotified，允许下次接近底部时再次触发
  // - 给章节标题元素加 data-chapter-index，供 IntersectionObserver 监测当前可见章节
  //
  // 关键：不要用 transform/opacity 淡入动画
  // - body.reader-scroll 有 `transform: translateZ(0); will-change: scroll-position`
  //   让 body 成为合成层
  // - wrap 元素 append 后立即占布局空间，body.scrollHeight 立即增加
  // - 如果 wrap 自身有 transform，会创建嵌套合成层，部分 Android WebView 上
  //   合成层在 scrollHeight 变化时可能重新计算 scroll 位置 → 用户看到「画面跳」
  // - 直接显示内容（无动画），用户在原滚动位置看到新内容从下方冒出，视觉无跳动
  function appendChapter(title, paragraphsHtml, chapterIndex) {
    if (!contentA) {
      console.warn('[reader] appendChapter: contentA is null');
      return;
    }
    // 包裹层：仅用于把章节分隔符 + 标题 + 段落组成一组，不做动画
    var wrap = document.createElement('div');
    wrap.className = 'chapter-append-wrap';

    // 章节分隔符：视觉提示用户进入新章节（32px 间距）
    var sep = document.createElement('div');
    sep.className = 'chapter-separator';
    sep.style.cssText = 'height: 32px; width: 100%;';
    wrap.appendChild(sep);

    // 章节标题（textContent 避免 XSS）
    // - 加 data-chapter-index 属性供 IntersectionObserver 监测
    // - 用属性选择器 [data-chapter-index] 即可获取所有追加章节标题
    if (title && title.length > 0) {
      var h1 = document.createElement('h1');
      h1.className = 'reader-title';
      h1.setAttribute('data-chapter-index', String(chapterIndex));
      h1.textContent = title;
      wrap.appendChild(h1);
      // 注册到章节观察器（追加后立即可被 IntersectionObserver 跟踪）
      if (chapterObserver && h1) {
        chapterObserver.observe(h1);
      }
    }

    // 段落（用临时 div 解析 HTML 字符串，再 append 移到 wrap）
    if (paragraphsHtml && paragraphsHtml.length > 0) {
      var tmp = document.createElement('div');
      tmp.innerHTML = paragraphsHtml;
      while (tmp.firstChild) {
        wrap.appendChild(tmp.firstChild);
      }
    }

    contentA.appendChild(wrap);

    appendedChapterCount++;
    nearEndNotified = false; // 重置以允许下次触发
    console.log('[reader] appendChapter: idx=' + chapterIndex +
      ' title=' + title + ' appendedCount=' + appendedChapterCount);
  }

  // 章节观察器：监听 [data-chapter-index] 元素，进入屏幕中部 20% 区域时
  // 回调 Dart 侧 onChapterVisible(chapterIndex)，让 UI 章节标题实时跟随滚动更新。
  //
  // 主导章节策略（避免短章节场景下多标题同时进入判定区导致 UI 闪烁）：
  // - 不再 forEach 全部触发回调（否则短章节边界附近 A、B 两标题同时进入 20% 横条
  //   会依次回调 onChapterVisible(A) → onChapterVisible(B)，Dart 侧 setState 两次
  //   → UI 章节标题先变 A 再变 B → 视觉闪烁）
  // - 改为从 entries 中选 boundingClientRect.top 最接近视口中线的那个（"主导章节"）
  //   只回调一次，保证 UI 标题稳定
  // - 仅处理 isIntersecting=true（不处理离开），保证单向切换
  //
  // - rootMargin: -40% 0px -40% 0px → 中部 20% 横条
  // - threshold: 0 → 元素任意像素进入判定区即触发
  // - 仅滚动模式启用，分页模式不需要（每次只显示一章）
  var chapterObserver = null;
  function initChapterObserver() {
    if (!config.isScrollMode) return;
    if (typeof IntersectionObserver === 'undefined') {
      console.warn('[reader] IntersectionObserver not supported, chapter UI 不会跟随更新');
      return;
    }
    chapterObserver = new IntersectionObserver(function(entries) {
      // 收集所有当前进入判定区的章节标题，选最接近视口中线的作为主导
      var best = null;        // { idx, dist }
      var viewportMid = body.clientHeight / 2;
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (!entry.isIntersecting) continue;
        var idxAttr = entry.target.getAttribute('data-chapter-index');
        if (idxAttr === null) continue;
        var idx = parseInt(idxAttr, 10);
        if (isNaN(idx)) continue;
        // entry.boundingClientRect.top 是相对视口顶部的坐标
        // 取标题中心点与视口中线的距离，越小越"主导"
        var rect = entry.boundingClientRect;
        var titleCenter = rect.top + rect.height / 2;
        var dist = Math.abs(titleCenter - viewportMid);
        if (best === null || dist < best.dist) {
          best = { idx: idx, dist: dist };
        }
      }
      if (best !== null && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('onChapterVisible', best.idx);
      }
    }, {
      root: null,
      // 章节捕捉判定区：屏幕中部 20% 横条
      // - 原 -50%/-40% → 中部 10% 太窄，用户在章节边界附近来回滚动时
      //   章节标题频繁进出，UI 章节标题频繁切换让用户感觉"捕捉不稳定"
      // - 改为 -40%/-40% → 中部 20%，章节标题进入更稳定的判定区才触发
      //   减少边界附近的频繁切换；同时配合下方 IntersectionObserver 只
      //   处理 isIntersecting=true（不处理离开），保证单向切换
      rootMargin: '-40% 0px -40% 0px',
      threshold: 0
    });
    // 初始章节标题（contentA 中已有的第一个 .reader-title）也注册
    var titles = contentA
      ? contentA.querySelectorAll('[data-chapter-index]')
      : [];
    for (var i = 0; i < titles.length; i++) {
      chapterObserver.observe(titles[i]);
    }
  }

  // 获取已追加的章节数（用于 Dart 侧查询当前已加载到第几章）
  function getAppendedChapterCount() {
    return appendedChapterCount;
  }

  // 重置 nearEndNotified 标志（Dart 侧 _appendNextChapter 失败/空内容时调用）
  // 不重置的话 nearEndNotified=true 永远保持，用户必须滚回上方 2*threshold
  // 才能再次触发 onScrollNearEnd，期间用户看到底部空白无法继续加载（A3 Bug）
  function resetNearEndNotify() {
    nearEndNotified = false;
  }

  // ============ 滚动模式向上衔接 ============
  // 在 #reader-content-a 顶部插入章节标题 + 段落 HTML，不触发整页 reload
  // - 与 appendChapter 对称，用于「滚动到顶部时加载上一章」
  // - 关键：插入后必须调整 body.scrollTop 保持视觉位置
  //   否则新内容会"覆盖"用户当前看到的内容（scrollTop 不变但 DOM 整体下移）
  // - 调整量 = 新增内容的实际渲染高度（scrollHeight 增量）
  // - 异步补偿：上一章可能含图片/Web 字体等异步资源，加载完成后段落高度变化
  //   会导致 scrollHeight 二次增加，scrollTop 不再补偿 → 用户看到内容向上漂移
  //   用 ResizeObserver 监听 wrap 高度变化，在 2 秒内持续补偿 scrollTop
  function prependChapter(title, paragraphsHtml, chapterIndex) {
    if (!contentA) {
      console.warn('[reader] prependChapter: contentA is null');
      return;
    }
    // 包裹层：仅用于把章节分隔符 + 标题 + 段落组成一组
    var wrap = document.createElement('div');
    wrap.className = 'chapter-prepend-wrap';

    // 章节标题（textContent 避免 XSS）
    if (title && title.length > 0) {
      var h1 = document.createElement('h1');
      h1.className = 'reader-title';
      h1.setAttribute('data-chapter-index', String(chapterIndex));
      h1.textContent = title;
      wrap.appendChild(h1);
      if (chapterObserver && h1) {
        chapterObserver.observe(h1);
      }
    }

    // 段落
    if (paragraphsHtml && paragraphsHtml.length > 0) {
      var tmp = document.createElement('div');
      tmp.innerHTML = paragraphsHtml;
      while (tmp.firstChild) {
        wrap.appendChild(tmp.firstChild);
      }
    }

    // 章节分隔符（在末尾，与 appendChapter 对称：分隔符在两章之间）
    var sep = document.createElement('div');
    sep.className = 'chapter-separator';
    sep.style.cssText = 'height: 32px; width: 100%;';
    wrap.appendChild(sep);

    // 关键：记录插入前的 scrollHeight 和 scrollTop
    // 插入后 scrollHeight 增加，需要把 scrollTop 也增加相同量
    // 否则用户看到的内容会被新章节"顶下去"（视觉跳动）
    var oldScrollHeight = body.scrollHeight;
    var oldScrollTop = body.scrollTop || 0;

    // 插入到 contentA 的第一个子元素之前
    if (contentA.firstChild) {
      contentA.insertBefore(wrap, contentA.firstChild);
    } else {
      contentA.appendChild(wrap);
    }

    // 计算新增内容的高度，同步调整 scrollTop 保持视觉位置
    var newScrollHeight = body.scrollHeight;
    var heightAdded = newScrollHeight - oldScrollHeight;
    if (heightAdded > 0) {
      body.scrollTop = oldScrollTop + heightAdded;
    }

    // 异步高度补偿：监听 wrap 高度变化（图片加载、字体替换导致段落高度变化）
    // - 每次高度增加 delta，同步增加 scrollTop 保持视觉位置
    // - 2 秒后自动断开（避免长期监听浪费资源；多数图片/字体在 2 秒内加载完成）
    // - 用户主动滚动时不补偿（避免与用户操作冲突）
    if (typeof ResizeObserver !== 'undefined') {
      var lastWrapHeight = wrap.offsetHeight;
      var userScrolled = false;
      var onUserScroll = function() { userScrolled = true; };
      body.addEventListener('scroll', onUserScroll, { passive: true });
      var ro = new ResizeObserver(function(entries) {
        if (userScrolled) {
          ro.disconnect();
          return;
        }
        for (var i = 0; i < entries.length; i++) {
          var newH = entries[i].contentRect.height;
          var delta = newH - lastWrapHeight;
          if (delta > 0.5) {
            // wrap 高度增加 delta → scrollTop 也增加 delta 保持视觉位置
            body.scrollTop = (body.scrollTop || 0) + delta;
            lastWrapHeight = newH;
          } else if (delta < -0.5) {
            // 高度减少（罕见，如图片加载失败回退）：更新基准但不调整 scrollTop
            lastWrapHeight = newH;
          }
        }
      });
      ro.observe(wrap);
      // 2 秒后自动断开 + 移除 scroll 监听
      setTimeout(function() {
        ro.disconnect();
        body.removeEventListener('scroll', onUserScroll);
      }, 2000);
    }

    prependedChapterCount++;
    nearStartNotified = false; // 重置以允许下次触发
  }

  // 重置 nearStartNotified 标志（Dart 侧 _prependPrevChapter 失败/空内容时调用）
  function resetNearStartNotify() {
    nearStartNotified = false;
  }

  // 获取向前插入的章节数
  function getPrependedChapterCount() {
    return prependedChapterCount;
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
    checkTap: checkTap,
    appendChapter: appendChapter,
    prependChapter: prependChapter,
    getAppendedChapterCount: getAppendedChapterCount,
    getPrependedChapterCount: getPrependedChapterCount,
    resetNearEndNotify: resetNearEndNotify,
    resetNearStartNotify: resetNearStartNotify,
    hideSelectionMenu: hideSelectionMenu,
    highlightSelection: highlightSelection,
    // Phase 3.1 / 3.2 / 3.4 新增
    removeHighlightInSelection: removeHighlightInSelection,
    restoreHighlights: restoreHighlights,
    removeHighlightByText: removeHighlightByText,
    searchText: searchText,
    scrollToSearchResult: scrollToSearchResult
  };
})();
''';
  }
}
