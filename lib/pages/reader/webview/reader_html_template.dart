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
  ///
  /// [isRichHtml]：是否为 EPUB 富 HTML 内容。
  /// - true：content 应为 `[[EPUB_CSS]]<style>...</style>[[/EPUB_CSS]]
  ///   [[EPUB_BODY]]<p>...</p>[[/EPUB_BODY]]` 包裹格式，由
  ///   EpubParser.parseFromBytes 在导入时预生成。
  ///   解析后 EPUB CSS 注入到 <style>，body HTML 直接放入 #reader-content-a
  ///   （不走 buildParagraphsHtml 段落包裹，保留 EPUB 原始标签结构）。
  /// - false（默认）：content 视为纯文本，按行切分成 <p class="reader-p">。
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
    bool isRichHtml = false,
    bool isFixedLayout = false,
    double? fixedLayoutWidth,
    double? fixedLayoutHeight,
  }) {
    final css = _generateCss(provider, isScrollMode, isRichHtml);
    final js = _readerJs();

    // 富 HTML（EPUB）：解析 [[EPUB_CSS]]/[[EPUB_BODY]] 包裹格式
    // - epubCss: EPUB 自带 CSS（注入到 <style>，让 EPUB 排版生效）
    // - bodyHtml: EPUB 章节正文 HTML（保留 <p>/<h1>/<img>/<blockquote> 等标签）
    // - 不走 buildParagraphsHtml，避免破坏 EPUB 原始标签结构
    //
    // EPUB 标题处理：默认隐藏应用自身的 `.reader-title`，保留 EPUB 作者设定的
    // 标题格式（如 .chapter-title / .other-title / .volume-title 等）。
    // 但滚动模式下 IntersectionObserver 依赖 [data-chapter-index] 监测章节切换，
    // 所以在 EPUB body 外包一层不可见的 wrapper div 携带 data-chapter-index。
    final String paragraphsHtml;
    String? epubCss;
    String titleHtml;
    if (isRichHtml) {
      final parsed = _parseRichHtmlContent(content);
      epubCss = parsed.$1;
      // 用不可见 wrapper 携带 data-chapter-index，让 IntersectionObserver 仍能监测
      // 章节切换（滚动模式下生效；分页模式下无副作用，因为每章独立显示）
      paragraphsHtml =
          '<div data-chapter-index="$chapterIndex" style="display:block">${parsed.$2}</div>';
      // EPUB 模式：不生成应用自身标题，让 EPUB 自带标题（h1.chapter-title 等）展示
      titleHtml = '';
    } else {
      paragraphsHtml = buildParagraphsHtml(content, provider);
      titleHtml = buildTitleHtml(title, provider, chapterIndex);
    }

    // EPUB CSS 追加到主 CSS 之后（优先级高于阅读器默认样式，
    // 让 EPUB 自带排版生效；但低于 #reader-stage 等布局 CSS 的 !important 规则）
    // EPUB 富 HTML 模式下内容直接放入 #reader-content-a，不走 .reader-p 包裹，
    // 所以 .reader-p img 等样式不会作用于 EPUB 内容，需要单独兜底
    final epubFallbackCss = isRichHtml ? _epubRichHtmlFallbackCss() : '';

    // ★ 三段式 CSS 注入（参考 Readium Kotlin-toolkit 的 ReadiumCssInjector）★
    //
    // 1. before（基础重置 + 图片约束 + 阅读器变量）：$css + $epubFallbackCss
    //    - 阅读器 :root 变量（字号/行距/颜色/安全区等）
    //    - 图片/媒体约束（break-inside:avoid + max-height:safe-height）
    //    - 标题不切分等兜底规则
    //
    // 2. 原作 CSS：$epubCss
    //    - EPUB 作者的视觉样式（字体/颜色/边距等）
    //    - 保留作者创意，让排版忠于原作
    //
    // 3. after（分页 + 用户设置覆盖）：_epubAfterCss() 或 _fixedLayoutCss()
    //    - reflowable：column 分页 + 用户设置覆盖
    //    - fixed-layout：viewport scale 等比缩放（不做 column 分页）
    //
    // 关键：after 在原作之后，确保分页布局不被原作破坏
    // （原作可能有 overflow-x:hidden 或 width:100% 破坏 column 布局）
    final afterCss = isRichHtml
        ? (isFixedLayout
            ? _fixedLayoutCss(viewWidth, viewHeight, fixedLayoutWidth, fixedLayoutHeight)
            : _epubAfterCss())
        : '';
    final fullCss = epubCss != null && epubCss.isNotEmpty
        ? '$css\n$epubFallbackCss\n/* === EPUB 自带 CSS === */\n$epubCss\n/* === After CSS（${isFixedLayout ? "fixed-layout" : "分页+覆盖"}）=== */\n$afterCss'
        : (isRichHtml ? '$css\n$epubFallbackCss\n$afterCss' : css);

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
    // EPUB 模式：titleHtml 为空（不显示应用标题），paragraphsHtml 已含
    //   data-chapter-index wrapper，章节监测不受影响
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
    $fullCss
  </style>
</head>
<body${isRichHtml ? ' data-epub="1"' : ''}>
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
        /* 借鉴 lumina：固定 128px 列间距，与 CSS column-gap 保持一致。
           原值 0 会导致 getPageCount 算不准（scrollWidth 无 gap 时亚像素误差大），
           翻页 step 也算不准（step=columnWidth+gap=columnWidth，多列时偏移不足）。 */
        columnGap: 128,
        pageAnimDurationMs: $pageAnimDurationMs,
        pageModeIndex: $pageModeIndex
      });
    });
  </script>
</body>
</html>
''';
  }

  /// 解析 EPUB 富 HTML 内容的包裹格式
  ///
  /// 输入格式（由 EpubParser.parseFromBytes 在导入时预生成）：
  /// ```
  /// [[EPUB_CSS]]<style>...</style>[[/EPUB_CSS]][[EPUB_BODY]]<p>...</p>[[/EPUB_BODY]]
  /// ```
  ///
  /// 返回 (epubCss, epubBody)：
  /// - epubCss: 提取出的 CSS 文本（已去掉外层 <style> 标签），可能为空字符串
  /// - epubBody: EPUB 章节正文 HTML（保留原始标签结构）
  ///
  /// 容错：
  /// - 缺少 [[EPUB_CSS]] 块时 epubCss 返回空字符串
  /// - 缺少 [[EPUB_BODY]] 块时 epubBody 返回原始 content（兜底）
  /// - 包裹标记格式错误时尝试容错解析，仍失败则返回 (null, content)
  static (String?, String) _parseRichHtmlContent(String content) {
    String? epubCss;
    String epubBody = content;

    try {
      // 1. 提取 EPUB CSS：[[EPUB_CSS]]...[[/EPUB_CSS]]
      final cssPattern = RegExp(
        r'\[\[EPUB_CSS\]\]([\s\S]*?)\[\[/EPUB_CSS\]\]',
      );
      final cssMatch = cssPattern.firstMatch(content);
      if (cssMatch != null) {
        var cssContent = cssMatch.group(1) ?? '';
        // 去掉外层 <style>...</style> 包裹（LocalBookService 包了一层）
        // 仅当首尾完整匹配时才剥离，避免误删
        final styleWrapper = RegExp(
          r'^\s*<style[^>]*>([\s\S]*?)</style>\s*$',
          caseSensitive: false,
        );
        final styleMatch = styleWrapper.firstMatch(cssContent);
        if (styleMatch != null) {
          cssContent = styleMatch.group(1) ?? '';
        }
        epubCss = cssContent.trim();
      }

      // 2. 提取 EPUB BODY：[[EPUB_BODY]]...[[/EPUB_BODY]]
      final bodyPattern = RegExp(
        r'\[\[EPUB_BODY\]\]([\s\S]*?)\[\[/EPUB_BODY\]\]',
      );
      final bodyMatch = bodyPattern.firstMatch(content);
      if (bodyMatch != null) {
        epubBody = (bodyMatch.group(1) ?? '').trim();
      } else {
        // 兜底：没有 [[EPUB_BODY]] 包裹时，去掉 [[EPUB_CSS]] 块后用剩余内容
        epubBody = content
            .replaceAll(cssPattern, '')
            .replaceAll(
              RegExp(r'\[\[/?EPUB_(?:CSS|BODY)\]\]'),
              '',
            )
            .trim();
      }
    } catch (_) {
      // 解析失败：保持原始 content 作为 body，不注入 CSS
      return (null, content);
    }

    return (epubCss, epubBody);
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
  static String _generateCss(ReaderProvider provider, bool isScrollMode, bool isRichHtml) {
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
  /* KT 对齐：链接/选择高亮颜色变量（移植 Readium CSS --USER__* 系列） */
  --reader-link-color: ${_linkColor(textColor, isDarkBg)};
  --reader-visited-color: ${_visitedColor(isDarkBg)};
  --reader-selection-bg: ${_selectionBg(isDarkBg)};
  --reader-selection-text: $textColor;
  /* KT 对齐：图片夜间模式变暗（不做反相，反相会破坏彩色图片） */
  --reader-darken-images: ${isDarkBg ? '0.85' : '1'};
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

/* 3-9. EPUB 特殊章节全屏背景：当章节含 .epub-chapter-bg 背景容器时，
   覆盖 padding 变量为 0，让 --reader-safe-width = viewport width，
   #reader-root/#reader-stage 铺满 viewport，背景图/背景色铺满全屏。
   - 正文章节（.epub-chapter-plain）不受影响，保留阅读器 padding
   - 所有 .epub-chapter-bg 都零 padding：body 有 class/style/bgcolor 才会被
     标记为 .epub-chapter-bg，说明原作者需要特殊布局，padding=0 让背景铺满
   - :has() 在 Chrome/WebView 105+ 支持，低版本不生效但不会比现在更差 */
html:has(.epub-chapter-bg) {
  --reader-padding-top: 0px;
  --reader-padding-bottom: 0px;
  --reader-padding-left: 0px;
  --reader-padding-right: 0px;
}

/* 3-9b.（已并入 4a-3g）卡片章顶部 57px 用 wrapper padding-top 实现，
   不占 html padding——html padding 会推走背景容器露出底色带。 */

* {
  box-sizing: border-box;
  -webkit-tap-highlight-color: transparent;
  -webkit-touch-callout: default;
  -webkit-user-select: text;
  user-select: text;
}

/* 借鉴 lumina：全局排版优化，减少孤行寡行，改善分栏断行 */
.reader-content {
  orphans: 1;
  widows: 1;
  word-break: break-word;
  overflow-wrap: break-word;
}

/* KT 对齐：链接/选择高亮颜色（移植 Readium CSS --USER__* 系列）
   原作 <a> 默认蓝色在夜间模式太刺眼，用变量统一控制 */
a:link, a:link * {
  color: var(--reader-link-color);
}
a:visited, a:visited * {
  color: var(--reader-visited-color);
}
::selection {
  color: var(--reader-selection-text);
  background-color: var(--reader-selection-bg);
}
::-moz-selection {
  color: var(--reader-selection-text);
  background-color: var(--reader-selection-bg);
}

/* KT 对齐：CJK 语言适配（移植 Readium CSS cjk-horizontal 的 :lang() 规则）
   - 断字规则：CJK 严格断行（line-break: strict）
   - 字体族：按语言指定系统字体（PingFang/Hiragino/Noto CJK 等）
   - 行高补偿：CJK 字符较高，1.167x 补偿避免行距过紧
   - 链接：CJK 链接默认无下划线（对齐原作习惯） */
:lang(zh), :lang(ja), :lang(ko) {
  word-wrap: break-word;
  -webkit-line-break: strict;
  -epub-line-break: strict;
  line-break: strict;
}
:lang(zh) {
  --reader-cjk-font: "PingFang SC", "Heiti SC", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif;
}
:lang(zh-Hant), :lang(zh-TW) {
  --reader-cjk-font: "PingFang TC", "Heiti TC", "Microsoft JhengHei", "Noto Sans CJK TC", sans-serif;
}
:lang(ja) {
  --reader-cjk-font: "Hiragino Sans", "Yu Gothic", "Meiryo", "Noto Sans CJK JP", sans-serif;
}
:lang(ko) {
  --reader-cjk-font: "Apple SD Gothic Neo", "Malgun Gothic", "Noto Sans CJK KR", sans-serif;
}
:lang(zh) body, :lang(ja) body, :lang(ko) body {
  font-family: var(--reader-cjk-font), var(--reader-font-family);
  line-height: calc(var(--reader-line-height) * 1.167);
}
:lang(zh) a, :lang(ja) a, :lang(ko) a {
  text-decoration: none;
}

/* 参考 lumina：html 用 --reader-vh，body 用 100%，padding 放 html 上
   100vw/100vh 在 InAppWebView 里可能等于屏幕尺寸而非 widget 尺寸，
   所以用 --reader-vw/vh（JS 注入 window.innerWidth/innerHeight）替代。
   ★ 关键：html 和 body 的 height 必须不同 ★
   - html: height = var(--reader-vh)（JS 注入的实际视口高度），
     box-sizing:border-box + padding → content area = safe-height
   - body: height = 100%（相对 html content area = safe-height）
     之前 html,body 都设 var(--reader-vh)，body 高度 = vh > html content area，
     body 竖向溢出被 html overflow:hidden 裁剪，高度链断裂，
     #reader-stage flex:1 拿不到正确高度 → column 容器高度 0/错误 → 第二页空白 */
html {
  margin: 0;
  padding: 0;
  height: var(--reader-vh);
  background-color: var(--reader-bg-color);
  color: var(--reader-text-color);
}
body {
  /* ★ 2026-09-02 v2：margin 恢复清零（padding 仍交给原书）★
     实测 26.0902.4~6：body margin(原书10px/UA8px) 会顶开 #reader-root，
     root < safe-width=100vw → 背景章右缘露缝，且多层版心叠加无法对账。
     epub.js 同款 margin:0 !important；百分比基准不受 margin 影响
     （30.5% 的包含块是 content width，由 html padding 决定）。
     版心唯一来源 = html --reader-padding-*：
       正文章 20px / 背景章 0(has 清零) / 卡片章直接子元素 10px(4a-3g) */
  margin: 0 !important;
  ${isRichHtml ? '' : 'padding: 0;'}
  /* 不设置 width：body 默认 width=auto 填满 html content area = safe-width */
  height: 100%;
  /* ★ EPUB 模式：让作者字体样式优先 ★
     ★ 2026-09-02 二次修复：EPUB 根基准对齐多看 ★
     实测像素：多看 EPUB 根基准 ≈ 11.2px（zzsm design-content 60% 落点
     13 物理px 反推），UA 默认 16px 仍偏大 45%。
     EPUB 模式：html font-size = 11px 锁定（多看等效基准），
     原书百分比链在此基准上解析 = 作者相对意图 + 多看绝对基准。
     用户字号：EPUB 模式不直接驱动根字号，而是 JS 检测原书无声明时
     内联注入 body（见 updateStyle），字号调整按倍率叠加。
     非 EPUB 模式：保持原逻辑，用户字号直接驱动 */
  ${isRichHtml ? 'font-size: 11px;' : 'font-size: var(--reader-font-size);'}
  ${isRichHtml ? '' : 'font-family: var(--reader-font-family);'}
  ${isRichHtml ? '' : 'line-height: var(--reader-line-height);'}
  ${isRichHtml ? '' : 'letter-spacing: var(--reader-letter-spacing);'}
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
   关键：必须设明确的 width = safe-width（单页宽度），让 column 布局在
   固定宽度内分列。内容超出单页高度后流向第二列（水平方向），scrollWidth
   返回所有列的总宽度（= pageCount * (columnWidth + gap) - gap）。
   对齐 lumina（body height:safe-height + column-width:safe-width）、
   readium-kotlin（:root width/height 明确）、JRead（root width:PAGE_W）。
   之前不设 width 依赖 absolute shrink-to-fit，导致 column 布局宽度
   不可预测，内容无法正确流向第二列 → 第二页空白。
   高度用 top:0 + bottom:0 撑满 stage。
   裁剪由 #reader-stage 的 overflow:hidden 负责。 */
body.reader-paged .reader-content {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  width: var(--reader-safe-width);
  column-width: var(--reader-safe-width);
  /* 借鉴 lumina：固定 128px 列间距，消除亚像素误差，确保 getPageCount 算准。
     必须与 JS config.columnGap 保持一致，否则翻页 step 与实际列宽不符。 */
  column-gap: 128px;
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

/* 图片样式：借鉴 lumina 加 break-inside:avoid 防止图片被分栏切分到两页，
   max-height 限制不超高内容区，object-fit:contain 等比缩放 */
.reader-p img {
  max-width: 100%;
  max-height: var(--reader-safe-height);
  height: auto;
  object-fit: contain;
  display: block;
  margin: var(--reader-paragraph-spacing) auto;
  break-inside: avoid;
  page-break-inside: avoid;
}

/* 滚动条隐藏 */
::-webkit-scrollbar {
  display: none;
  width: 0;
  height: 0;
}
''';
  }

  /// EPUB 富 HTML 模式下的兜底 CSS
  ///
  /// EPUB 章节内容直接放入 #reader-content-a，不走 .reader-p 段落包裹，
  /// 所以阅读器针对 .reader-p 的样式（如 .reader-p img）不会作用于 EPUB 内容。
  /// 此方法提供 HTML5 标签的合理默认渲染 + 通用适配规则（不依赖具体 class 名）。
  ///
  /// 兜底 CSS 在 EPUB 自带 CSS 之前，EPUB CSS 可覆盖这些默认值。
  /// WebView user agent 样式表优先级最低，作者 CSS（含本兜底）都会覆盖它。
  ///
  /// 设计原则：
  /// - **通用适配**：所有规则基于 HTML5 标签或通用属性，不硬编码 EPUB class 名
  /// - **响应式优先**：图片/视频/SVG/表格不溢出容器
  /// - **分栏友好**：块级容器尽量不分页断开，背景容器填满整页
  /// - **与 EpubParser._rewriteCssValuesForReader 配合**：
  ///   EPUB CSS 的 position:absolute→static、float→none、height:100%→auto 等
  ///   已在解析时改写，这里提供合理的默认布局兜底
  static String _epubRichHtmlFallbackCss() {
    return '''
/* === EPUB 富 HTML 兜底 CSS（通用，不依赖具体 class 名）=== */

/* 1. 标题不切分：h1-h6 不应被分栏切断（避免标题与后续内容分离）
    - 图片/视频/SVG 不设 break-inside:avoid：
      大图片 + 文字混合时 break-inside:avoid 会把图片推到下一栏，
      若图片高度接近 safe-height 则无栏可放 → 图片消失
    - 三重保险：break-inside + column-break-inside + page-break-inside */
#reader-content-a h1,
#reader-content-a h2,
#reader-content-a h3,
#reader-content-a h4,
#reader-content-a h5,
#reader-content-a h6 {
  break-inside: avoid;
  column-break-inside: avoid;
  page-break-inside: avoid;
}

/* 1a. table/pre：限制最大高度，超过则允许切分
   - table 和 pre 可能包含超长内容（大表格、长代码块）
   - max-height 限制为 safe-height 的 90%（留出 margin 空间）
   - 不设 break-inside:avoid，允许浏览器自由切分大表格/长代码块
   - 小表格/短代码块（< 90% safe-height）自然在一页内显示
   - overflow-x:auto 让超宽表格横向滚动，不撑宽 column */
#reader-content-a table,
#reader-content-a pre {
  max-width: 100%;
  max-height: calc(var(--reader-safe-height) * 0.9);
  overflow: auto;
  /* 不设 break-inside:avoid，允许大表格/长代码块被切分到多页 */
}

/* 1b. 防止子元素水平溢出 column：
   - EPUB 原作者 CSS 可能给子元素设了固定 width（如 540px），
     超过 column-width 时会溢出到相邻 column，导致"页面 2 溢出第一页"
   - max-width:100% 限制子元素不超过 column 宽度
   - 用 !important 确保覆盖 EPUB CSS 的固定宽度
   - 不影响 .epub-chapter-bg 内部的装饰元素（它们有单独规则） */
#reader-content-a p,
#reader-content-a div,
#reader-content-a figure,
#reader-content-a blockquote,
#reader-content-a section,
#reader-content-a article,
#reader-content-a li {
  max-width: 100%;
  overflow-wrap: break-word;
  word-break: break-word;
}

/* 2. 所有图片/视频/SVG/canvas 响应式：最大宽度 100%，不溢出
   覆盖 EPUB 中固定 px 宽度的资源（EpubParser 已把 >300px 固定宽度改写为
   max-width:100%，这里作为兜底确保万无一失）
   - 不设 object-fit：让 EPUB 原作者的 img CSS（如 width:100%）正常生效，
     object-fit:contain 会让图片在容器内居中且留白，破坏原作者排版
   - 不设 break-inside:avoid：大图片+文字混合时 break-inside:avoid 会把
     图片推到下一栏，若图片高度接近 safe-height 则无栏可放 → 图片消失
   - max-height 限制图片不超高内容区，但允许和文字一起被分栏切分 */
#reader-content-a img,
#reader-content-a video,
#reader-content-a canvas {
  max-width: 100%;
  max-height: var(--reader-safe-height);
  height: auto;
}

/* 3. SVG 封面图：填满容器（EPUB 常用 SVG 做矢量封面） */
#reader-content-a svg {
  width: 100%;
  max-height: calc(var(--reader-safe-height) - 2em);
}
#reader-content-a svg image {
  width: 100%;
  height: auto;
}

/* 3a. 封面图全屏（对齐 lumina applyCenteringStyles + Readium CSS object-fit:contain）：
   EPUB 封面章常见结构：
   <svg width="100%" height="100%" viewBox="0 0 1000 1333"
        preserveAspectRatio="xMidYMid meet"><image .../></svg>
   - :has(svg[width="100%"][height="100%"]) 给背景容器显式 height：
     svg height:100% 才能解析成整页高度（仅 min-height 不参与百分比基准，
     会退回 auto 导致 svg 高度按 viewBox 比例算，封面不能铺满整屏）
   - preserveAspectRatio 已由 EpubParser 确保为 meet（对齐 lumina）：
     meet 等比缩放完整显示封面，不裁边（可能有上下/左右留白）
   - 显式 height + meet 组合实现封面等比缩放全屏（contain 模式）
   - 仅命中全屏封面 svg，不影响正文内普通 svg */
#reader-content-a .epub-chapter-bg:has(svg[width="100%"][height="100%"]) {
  height: var(--reader-safe-height);
}
#reader-content-a .epub-chapter-bg svg[width="100%"][height="100%"] {
  width: 100% !important;
  height: 100% !important;
  max-height: none !important;
}
#reader-content-a .epub-chapter-bg svg[width="100%"][height="100%"] image {
  width: 100% !important;
  height: 100% !important;
}

/* 4. 章节级背景容器（EPUB body class/style 的 wrapper div，由 EpubParser
   标记 .epub-chapter-bg）：
   - min-height: var(--reader-safe-height) 让背景图/背景色填满整页。
     不用 100% 是因为 column 子元素的百分比高度在某些 WebView 上解析不一致
     （可能相对 column 容器的 content height，也可能被 column-fill:auto 影响）。
     用 JS 注入的 --reader-safe-height（实际像素值）最可靠，背景必铺满整页。
   - box-sizing: border-box 让 EPUB body 的 padding 包含在高度内，不溢出
   - break-inside: avoid 防止被分页切断（视频页/卷头页/序号页等整页显示）
   - background-attachment 的 fixed 已在 EpubParser 通用修正为 scroll
   关键：column-break-inside:avoid 防止容器被 column 布局切分到多列（多页） */

/* 4-0. EPUB 模式下 HTML 结构是
   #reader-content-a (column 容器)
     └ div[data-chapter-index] (column 直接子元素 ← 这里！)
         └ div.epub-chapter-bg (特殊章节) / div.epub-chapter-plain (正文章节)
             └ p, h1, img, ... (EPUB 原作者 body innerHTML)

   关键修复：正文章节不设 break-inside:avoid 和 min-height
   - 正文章节内容通常超过一页，break-inside:avoid 会阻止浏览器切分，
     导致整个 wrapper 被推到下一栏，第一栏（第一页）留空白缝隙，
     wrapper 高度 > 一页又溢出第二页 → "页面 2 切分不对，溢出"
   - min-height 也不需要：正文不需要强制整页高度
   - 只有 .epub-chapter-bg（特殊章节）才需要 break-inside:avoid + min-height，
     在下方 4a 单独设置
   - 滚动模式下此 wrapper 只用于 IntersectionObserver 监测，无需布局约束 */
#reader-content-a > [data-chapter-index] {
  /* 不设 break-inside:avoid，允许浏览器自由切分正文内容到多栏（多页） */
  /* 不设 min-height，让内容自然展开 */
}

/* 4-0a. 正文章节 wrapper（.epub-chapter-plain）布局约束
   - max-width:100% 防止 wrapper 溢出 column 边界
   - 不设 break-inside:avoid，允许浏览器自由切分正文到多栏（多页）
   - 不设 min-height，让内容自然展开
   - 与 .epub-chapter-bg（特殊章节）区分，后者需要整页显示 */
#reader-content-a .epub-chapter-plain {
  max-width: 100%;
  /* 不设 break-inside:avoid，允许正文自由切分 */
}

#reader-content-a .epub-chapter-bg {
  min-height: var(--reader-safe-height);
  box-sizing: border-box;
  break-inside: avoid;
  column-break-inside: avoid;
  page-break-inside: avoid;
}

/* 4a-1. 封面章节（EpubParser 标记 epub-chapter-bg epub-cover）：
   - 固定一屏高（height 而非 min-height），svg meet 等比缩放铺满整屏
   - break-inside: avoid + overflow: hidden 双保险，封面绝不跨屏
   - 不依赖 :has() 选择器（低版本 WebView 也生效）
   - html:has(.epub-chapter-bg) 已把 padding 清零，safe-height = 视口高
   - 对齐 lumina：preserveAspectRatio=meet 完整显示不裁边 */
#reader-content-a .epub-cover {
  position: relative; /* svg absolute 定位基准 */
  height: var(--reader-safe-height);
  box-sizing: border-box;
  overflow: hidden;
  break-inside: avoid;
  column-break-inside: avoid;
  page-break-inside: avoid;
}
/* svg 直接父级是内层 div（如 <div style="text-align:center">），高度 auto，
   svg height:100% 相对它无效 → 用 absolute 相对 wrapper 铺满整屏 */
#reader-content-a .epub-cover svg[width="100%"][height="100%"] {
  position: absolute;
  top: 0;
  left: 0;
  width: 100% !important;
  height: 100% !important;
  max-height: none !important;
}
#reader-content-a .epub-cover svg[width="100%"][height="100%"] image {
  width: 100% !important;
  height: 100% !important;
}
/* 4a-2. 封面章节 img 兜底（对齐 lumina img + Readium CSS object-fit:contain）：
   - 部分封面章用 <img> 而非 <svg>，需 object-fit:contain 等比缩放完整显示
   - max-width/max-height:100% 限制不溢出封面容器
   - 不强制 width:100%（保留作者图片尺寸，小图居中显示） */
#reader-content-a .epub-cover img {
  max-width: 100% !important;
  max-height: 100% !important;
  object-fit: contain !important;
}

/* 4b. EPUB 特殊章节原作者 CSS 用百分比 margin 做垂直占位：
   .book-title { margin: 45% auto }
   .book-author { margin: 45% auto 20% auto }
   .book-line { margin-bottom: 6% }
   .volume-title { margin: 30% auto 0 auto }
   .volume-first { margin: 90% auto }
   .intro-box { margin: 45% auto }
   .video-title { margin: 50% 0 1em 0 }

   ★ 垂直 margin 基准选择 ★
   CSS 规范：margin 百分比始终相对包含块 width（非 height）。
   但多看阅读器对特殊章节（卷首/版权/介绍）的百分比 margin 实际按 height 处理，
   原作者 CSS 是针对多看设计的，所以视觉意图是相对 height 的垂直距离。

   方案：垂直 margin 用 calc(var(--reader-safe-height) * 比例) 还原多看视觉意图。
   比例经溢出实测调优（copyright 页含 book-title + book-author + book-line +
   book-creator + book-link + footnote，累计高度需 < safe-height）：

   各章节溢出分析（safe-height≈700px，margin 折叠后）：
   - copyright: book-title(0.1×700=70 top + 42字 + 70折叠) + book-author(70折叠共享 + 16字 + 35) + book-line(28) + creator(16) + link(16) + footnote(80) ≈ 273px < 700 ✓
   - volume-bg: volume-pic img(50%×700=350) + volume-title margin-top(30%×700=210) + 标题(60) = 620px < 700 ✓
   - serial-num: intro-box margin(0.1×700=70 上下) + 内容(50+300+16) = 506px < 700 ✓

   .volume-first 原作者 margin:90% auto 上下各 90%=180% 必溢出，
   改成 margin-top:70% safe-height 无下 margin（文字靠下显示，不溢出）。 */
#reader-content-a .epub-chapter-bg .book-title {
  margin: calc(var(--reader-safe-height) * 0.1) auto !important;
}
#reader-content-a .epub-chapter-bg .book-author {
  margin: calc(var(--reader-safe-height) * 0.1) auto calc(var(--reader-safe-height) * 0.05) auto !important;
}
#reader-content-a .epub-chapter-bg .book-line {
  margin-bottom: calc(var(--reader-safe-height) * 0.04) !important;
}
#reader-content-a .epub-chapter-bg .volume-title {
  margin: calc(var(--reader-safe-height) * 0.3) auto 0 auto !important;
}
#reader-content-a .epub-chapter-bg .volume-first {
  margin: calc(var(--reader-safe-height) * 0.7) auto 0 auto !important;
}
#reader-content-a .epub-chapter-bg .intro-box {
  margin: calc(var(--reader-safe-height) * 0.1) auto !important;
}
#reader-content-a .epub-chapter-bg .video-title {
  margin: calc(var(--reader-safe-height) * 0.35) 0 1em 0 !important;
}

/* 4b-2. volume-title 竖排还原：
   原作者 .volume-title { width: 35px; padding: 10px 5px;
     font-size: 1.3em; line-height: 1.2em; text-align: center;
     border: 3px solid rgba(40,40,40,0.5); border-radius: 10px;
     background-color: rgba(255,255,255,0.9) }
   width:35px 是故意的！35px 宽度下中文字符会每行1字垂直排列，
   配合 border+border-radius+background 形成竖条盒子装饰。
   如"序列途径"4字竖排显示在带边框圆角的白色竖条里。
   1:1 还原原作者排版，不覆盖 width/padding/font-size。

   ★ 字号自动获取作者设定（不固定）★
   用户字号默认 15px，其他设置由系统自动获取。
   原作者 font-size:1.3em 相对阅读器基准字号（15px 基准下 = 19.5px），
   35px 宽 - 5px*2 padding - 3px*2 border = 19px 内容宽度，
   19.5px 中文字符仍可每行1字竖排，盒子紧凑美观。
   不覆盖 font-size，让作者 em 单位跟随阅读器字号自动缩放。 */

/* 4b-3. 特殊章节盒子宽度修复：
   A. illustration(.box-bg)：.box { margin: 0em 50% 0em 0em; padding: 3px }
      原作者 margin-right:50% 是让盒子只占左半屏（多看特殊处理）。
      修复：用 width:fit-content 让盒子宽度由内容决定，margin:0 auto 居中。
      加 min-width:280px 确保盒子不会太小（box-txt 文本需要足够宽度换行）。
      padding 还原原作者 3px（1:1 还原）。

   B. serial-num(.intro-box)：.intro-box { margin: 45% auto; padding: 8px }
      原作者 .intro-box 是块级元素默认 width:100%（填满），但多看渲染时
      会 shrink-to-fit 让宽度由内容（table.role）决定。
      修复：用 width:fit-content 让盒子宽度由 table 决定，配合 margin auto 居中。
      加 min-width:280px 确保盒子不会太小（table 内容短时盒子太窄）。
      padding 还原原作者 8px。

   C. volume-bg：volume-pic img width:100% 高度可能很大
      + volume-title margin-top 30%(210px) → 溢出。
      修复：volume-pic img max-height 限制为 50% safe-height，为 volume-title 留出空间。

   D. gallery(.video-bg)：duokan-image-gallery margin:8em 0(128px)
      gallery-title margin:2em auto(32px)
      8em margin 在 gallery 容器外，与 title margin 累加导致整体偏下。
      修复：gallery margin-top 减小到 1em。 */
#reader-content-a .epub-chapter-bg .box {
  margin: calc(var(--reader-safe-height) * 0.1) auto !important;
  padding: 3px !important;
  width: fit-content !important;
  min-width: 280px !important;
  max-width: 90% !important;
}
#reader-content-a .epub-chapter-bg .intro-box {
  margin: calc(var(--reader-safe-height) * 0.1) auto !important;
  padding: 8px !important;
  width: fit-content !important;
  min-width: 280px !important;
  max-width: 90% !important;
}
#reader-content-a .epub-chapter-bg .volume-pic img {
  max-height: calc(var(--reader-safe-height) * 0.5) !important;
  object-fit: contain !important;
  /* 置顶：原作 .volume-pic 有 duokan-bleed:lefttopright（贴左/上/右边），
     但 duokan-bleed 是多看私有属性不在 CSS 白名单内被丢弃。
     通用 img 规则（section 15）的 margin-top:1em 会在图片上方留 1em 缝隙，
     阻碍卷头图贴顶显示。这里 margin-top:0 还原多看 bleed:top 的贴顶意图 */
  margin-top: 0 !important;
}
#reader-content-a .epub-chapter-bg .duokan-image-gallery {
  margin: 1em 0 0.5em 0 !important;
}

/* 4b-5. book-title 字号还原原作者设定（copyright 页）：
   原作者 .book-title { margin: 45% auto; font-size: 2.4em }
   4b 已将 margin 改为 safe-height * 0.1（解决溢出）。
   字号保持原作者 2.4em，不额外放大，1:1 还原原作者排版。 */
#reader-content-a .epub-chapter-bg .book-title {
  font-size: 2.4em !important;
}

/* 4c. EPUB 章节背景容器：留在 column 流里，背景才能铺满单页。
   根因（之前 position:absolute 方案错在哪里）：
   - #reader-content-a 自身是 position:absolute（见上方 .reader-content 规则），
     且只设了 left:0 没设 right:0，所以它的 width 是 auto，由 column 布局自动
     扩展为"多页总宽度"（= pageCount * (columnWidth + gap)）。
   - 若 .epub-chapter-bg 也用 position:absolute，它的最近 positioned 祖先
     是 #reader-content-a（不是 #reader-stage），width:100% 会变成"多页总宽度"。
   - 于是 background-size:cover 相对这个超宽容器缩放，背景图被拉伸到巨大尺寸，
     用户在单页 viewport 里只能看到背景中间一小块——这就是"居中框框"现象。
   正确修复：让 .epub-chapter-bg 留在 column 流，作为 column 子元素：
   - width 自动 = column-width = 单页宽度（不需要显式 width）
   - min-height:100%（4a 已设）= #reader-content-a 高度 = stage 高度，占满一整页
   - break-inside:avoid（4a 已设）防止容器被切分到多列（多页）
   - background-size:cover 相对"单页宽度 × stage 高度"正确铺满
   - overflow:hidden 防止内部内容溢出 + 阻止 4b 的 vh margin 穿透到容器外
   匹配规则：
   - .volume-bg/.box-bg/.video-bg：原作者 class 标记的背景容器
   - [style*="background"]：EpubParser 把 body bgcolor/style 转成 inline style，
     copyright(白底 #fff) 和 foreword1(黑底 #000) 等无 class 但有背景色的章节也能匹配。
     正文章节 body 通常无背景属性，不受影响。 */
#reader-content-a .epub-chapter-bg {
  /* 默认裁剪：空内容整页背景章（人物卡 renwu0-11/卷首页 VOL/封底 qmpfengdi）
     正文只有隐藏 h2 + 空 p，多看里严格单页。若 overflow:visible，wrapper
     内容高度微超一栏 → 分栏器把章拆成 1/2+2/2 两页且第 2 页全空白
     （2026-08-31 装机实测回归）。hidden 时内容被裁、wrapper 恰好一栏。 */
  overflow: hidden;
}

/* 4c-2. 手册章（body.jieshao，含 div.zhangyue-bg 白卡）保持 visible：
   白卡超高分栏内容需完整可见，且白卡 margin:0 -5px 出血边不能被裁。
   （4a-3b 已把白卡改回正常流；p18h/p20~p51 逐屏扫页验证此组合正确） */
#reader-content-a .epub-chapter-bg[class*="jieshao"] {
  overflow: visible;
}

/* 4a-3. 整页 CSS 背景章（body.renwu0/renwu1/.../VOL01/.../qmpfengdi 等）：
   作者用 body class 的 background-image 做整页背景（《这游戏也太真实了》
   人物卡/卷首页/封底——正文仅隐藏 h1/h2 + 空 p）。
   多看按"整页背景 + 可选标题"渲染，全屏铺满无留白。
   作者 CSS 的 body.renwu0 选择器在 WebView 里不命中（body class 已被
   EpubParser 移到 wrapper div .epub-chapter-bg），解析器已把 body 规则
   改写到 wrapper：作者自带的 cover/center/no-repeat/attachment 全部存活。
   ★ 2026-09-03 降噪（用户指出"暴力重写破坏原书 CSS"）：删掉与作者声明
   冲突的 4 条 background !important——尤其 background-position: top center
   曾强压作者的 center center，导致背景几何与多看（按原书渲染）错位。
   仅保留尺寸兜底：width:100% + min-height 撑满视口（wrapper 是普通 div）。 */
#reader-content-a .epub-chapter-bg[class*="renwu"],
#reader-content-a .epub-chapter-bg[class*="VOL"],
#reader-content-a .epub-chapter-bg[class*="qmpfengdi"],
#reader-content-a .epub-chapter-bg[class*="qmpzpxg"],
#reader-content-a .epub-chapter-bg[class*="zhizuosm"],
#reader-content-a .epub-chapter-bg[class*="jieshao"],
#reader-content-a .epub-chapter-bg[class*="kuaijie"] {
  background-size: cover !important;
  width: 100% !important;
  min-height: var(--reader-safe-height) !important;
}

/* 4a-3g. 卡片版面章（zhizuosm/jieshao/kuaijie）保留原书 body 版心：
   真机对比（2026-09-02）：多看制作说明页卡片左右有 10px 版心
   （卡框 x45..674物理 = 22.5..337 CSS），MR 卡片全宽无版心。
   根因：原书 body margin:0 10px 的语义在 wrapper 上丢失
   （4a-3 的 width:100% + html:has 清 padding 把版心抹了）。
   renwu/VOL/qmp* 是真全屏 bleed 章不受此规则影响。
   ★ padding-top 57px（2026-09-03 实测对齐多看页面上边距 57.5 CSS）：
   多看手册白卡顶 115 物理/制作说明框顶 150 物理（含框内留白）。
   放 wrapper 盒内——背景照常铺满 padding 区（全屏出血），仅子元素
   （白卡/封面/卡框）下移；html padding 方案会把背景推走露出底色带。 */
#reader-content-a .epub-chapter-bg[class*="zhizuosm"],
#reader-content-a .epub-chapter-bg[class*="jieshao"],
#reader-content-a .epub-chapter-bg[class*="kuaijie"] {
  padding-top: 57px;
  /* ★ 背景按屏取景对齐多看（2026-09-03）：多看分页每屏重绘 body 背景
     （手册页 p2 背景与 p1 同为艺术图顶部——实测），而 wrapper 在 multicol
     里跨页连续，cover 按"内容全高"取景 → 构图与多看错位（制作说明页
     实拍：多看是塔楼构图、MR 是武士构图）。fixed = 背景相对视口取景，
     每屏一致。作者未声明 attachment（renwu/VOL 系作者自带 fixed），
     此条是对多看渲染行为的等效复刻，非覆盖作者声明。 */
  background-attachment: fixed !important;
  /* 版心缩进打在直接子元素上（多看等价：body 背景全屏 + body margin
     10px 让子元素缩进。EpubParser 把 body 语义搬到 wrapper 后，body 的
     margin 语义 = wrapper 的直接子元素缩进）。直接子选择器避免影响
     卡片内部元素自身的布局 */
}
#reader-content-a .epub-chapter-bg[class*="zhizuosm"] > *,
#reader-content-a .epub-chapter-bg[class*="jieshao"] > *,
#reader-content-a .epub-chapter-bg[class*="kuaijie"] > * {
  /* 18px = 原书 body margin 10px + 多看阅读器默认页边距 8px
     （反推自多看实拍封面 173 物理：30.5% 包含块 = 283.6 CSS） */
  margin-left: 18px !important;
  margin-right: 18px !important;
}

/* 4a-3b. 手册页白卡（.jieshao 章 div.zhangyue-bg，height:300% 作者意图
   白卡盖满多屏）正常流分页修复：
   - 白卡 height:auto 随内容（column 分页按内容高度切页，多看看同款）
   - 白卡半透明背景保留（rgba 0.8）
   - 手册章 wrapper 裁剪已由 4c-2 单独放开（其他章仍 hidden） */
#reader-content-a .epub-chapter-bg div.zhangyue-bg {
  height: auto !important;
  min-height: 0 !important;
  max-height: none !important;
  overflow: visible !important;
  break-inside: auto !important;
  column-break-inside: auto !important;
  page-break-inside: auto !important;
  /* 2026-09-03 对齐多看实测：白卡左右缘 x30..690 物理 = 15..345 CSS
     （= 原书 body margin 10px + 多看页边距 5px）。
     旧值 0 -5px 是负出血，把 4a-3g 的 18px 版心抵成 5px，卡几乎全宽 */
  margin: 0 15px !important;
}

/* 4a-3c. 【2026-09-02 已撤销缩放】 制作说明章（body.zhizuosm）字号基准对齐多看：
   实测（2026-08-31 装机 720px 截图行投影）：同一段面板正文多看折 3 行、
   字形 13 物理px；MR 折 5 行、18 物理px，面板变高 1.4 倍导致二维码+
   搜一搜被挤到第 2 屏（多看整页 1 屏）。
   根因：作者用 font-size:100%/120%/60% 百分比链，多看落点基准 ≈11px，
   MR 落在用户字号 15px 上，同比放大 1.38 倍。
   修法：整章基准缩到用户字号的 0.72（15→10.8px），作者的百分比链
   （design-box 100%/design-title 120%/design-content 60%）随之等比
   缩小，面板+二维码收回 1 屏，恢复多看版面比例。
   用户调整字号时按比例同步，保持 1:1 视觉关系。 */
#reader-content-a .epub-chapter-bg[class*="zhizuosm"] {
  /* 2026-09-02: 0.72 缩放撤销。html font-size 基准锁定已移除，
     原书 body 97% 链落在 UA 16px 与多看等效，补丁不再需要 */
}

/* 4a-3e. duokan-bleed 兜底语义（贴边出血）：
   原书 div.logo / img.logo2 / div.fenge 用 duokan-bleed:lefttopright 声明
   「图片贴左/上/右边出血」（多看私有属性，章节页眉装饰图用）。
   多看渲染：贴边零留白。MR 正文页眉由 reader 框架接管（章内 h2.head 的
   logo 图仅装饰），这里对特殊背景章内的 .logo/.logo2/.fenge 还原贴边意图：
   margin 清零 + 负 margin 抵消 wrapper padding（3-9 已把整章 padding 清零，
   此处再对 img 自身的默认 margin 1em 兜底清零，防止贴边图被推离页边）。 */
#reader-content-a .epub-chapter-bg .logo,
#reader-content-a .epub-chapter-bg .logo img,
#reader-content-a .epub-chapter-bg img.logo2,
#reader-content-a .epub-chapter-bg .fenge,
#reader-content-a .epub-chapter-bg img.fenge {
  margin-top: 0 !important;
  margin-left: 0 !important;
  margin-right: 0 !important;
}

/* 4a-3d. 制作说明章（zhizuosm）多看脚注容器净化：
   原书用 duokan-footnote 机制把"二维码大图"塞进 <ol class="duokan-footnote-content">
   （多看在章末以脚注弹层展示，正文页不占位）。WebView 无此机制，两个 ol
   会当作普通列表渲染，把二维码图撑到制作说明卡之后的下一屏，导致
   「卡片 + 二维码 + 搜一搜」无法同屏（多看整章 1 屏）。
   对齐多看实拍（dk_zzsm_clean.png）：整章 1 屏含卡片区 + 二维码区，
   脚注 ol 不额外占位 → 折叠脚注容器；首个带 hr class 的空 ol 高度为 0。
   二维码本体（li 里的 img）由 .shumou 区块的同款图（shumouss.png）呈现，
   多看正文页显示的正是 .shumou 区块，脚注弹层里的 shumouewm.jpg 不参与正文排版。 */
#reader-content-a .epub-chapter-bg[class*="zhizuosm"] ol.duokan-footnote-content {
  display: none !important;
}
/* 4a-3f. 简介页（xsjj）封面对齐多看：
   真机像素对比（2026-09-02）：多看封面居中在木架上（中心 x=359.5/720），
   MR 封面贴左上角（中心 x=137/720）且顶部越过木架。
   根因：15 号兜底规则 #reader-content-a img { display:block; margin-top:1em }
   破坏了原书 div.feng { margin:-68% auto } + 行内 img 的布局语义：
   - img 变 block 后不再受父级 text-align:center 控制 → margin:auto 失效 → 贴左
   - 额外 margin-top:1em 把封面下推，与 -68% 上移抵消出偏差 → 越过木架
   修法：恢复行内语义（inline-block 受 text-align 控制），清掉兜底 margin。
   宽度保持原书 30.5% 链路不变。 */
#reader-content-a .epub-chapter-bg div.feng {
  text-align: center !important;
}
#reader-content-a .epub-chapter-bg div.feng img {
  display: inline-block !important;
  margin-top: 0 !important;
  margin-bottom: 0 !important;
}
/* 4a-4. 封面/整页背景章正文若为空（隐藏 h1 + 空 p），wrapper 高度已经由
   4a-3 的 min-height 顶满；无需额外高度兜底。 */

/* 4d. EPUB 原作者用 width:35px/.content-matrix width:540px 等固定宽度做装饰。
   保留原作者的 width（装饰元素需要固定尺寸），只加 max-width:100% 防止溢出。
   不再用 width:auto 覆盖，避免破坏 .volume-title 装饰框和 .content-matrix 视频尺寸。
   .box/.intro-box 等容器原本用 margin 做占位，flex 居中后自动归正。 */
#reader-content-a .epub-chapter-bg .box,
#reader-content-a .epub-chapter-bg .intro-box,
#reader-content-a .epub-chapter-bg .volume-title,
#reader-content-a .epub-chapter-bg .gallery-title,
#reader-content-a .epub-chapter-bg .video-title,
#reader-content-a .epub-chapter-bg .book-title,
#reader-content-a .epub-chapter-bg .book-author,
#reader-content-a .epub-chapter-bg .book-creator,
#reader-content-a .epub-chapter-bg .book-link,
#reader-content-a .epub-chapter-bg .volume-first,
#reader-content-a .epub-chapter-bg .chapter-title,
#reader-content-a .epub-chapter-bg .other-title,
#reader-content-a .epub-chapter-bg .preface,
#reader-content-a .epub-chapter-bg .content-matrix {
  max-width: 100% !important;
}

/* 4d-2. .content-matrix 原作者固定 width:540px height:360px（视频海报）。
   max-width:100% 会把 540px 压到屏幕宽度，但 height:360px 不变 → 视频被压扁。
   必须同时设 height:auto 保持 3:2 比例。
   max-height 限制为 safe-height 的 50%，留出 video-title margin(50%) 空间，
   防止 margin + 视频高度超过一页导致下方溢出。 */
#reader-content-a .epub-chapter-bg .content-matrix {
  height: auto !important;
  max-height: calc(var(--reader-safe-height) * 0.5) !important;
}

/* 4e. 保留 EPUB 原作者链接颜色（a: #ff0000, a:hover: #ff00ff）。
   阅读器 html,body 设了 color: var(--reader-text-color)，会通过继承影响链接。
   原作者 CSS 的 a 选择器优先级更高，但为防止阅读器 CSS 变量干扰，显式保留。 */
#reader-content-a .epub-chapter-bg a {
  color: #ff0000;
}
#reader-content-a .epub-chapter-bg a:hover {
  color: #ff00ff;
}

/* 5. 多看画廊（duokan-image-gallery）：
   画廊章节已由 Flutter EpubGalleryPage 接管渲染（PageView 横向滑动），
   不再走 WebView。此处不再设置降级 CSS。
   若画廊识别失败（cell < 2）仍走 WebView，按默认 column 分页处理。 */

/* 6. 表格自适应：不溢出 */
#reader-content-a table {
  max-width: 100%;
  border-collapse: collapse;
  word-break: break-word;
}

/* 7. 段落默认样式（EPUB 的 <p> 不走 .reader-p，这里兜底）
   只提供 EPUB 原作者 CSS 不会设的属性（word-break/overflow-wrap），
   不覆盖 margin/text-indent/font-family/line-height 等，
   让 EPUB 原作者 p { text-indent:2em; margin:0.5em 0; line-height:1.5em } 正常生效。
   用 .epub-chapter-bg p（class 选择器）而非 #reader-content-a p（ID 选择器），
   避免 ID 选择器优先级过高覆盖 EPUB CSS。 */
.epub-chapter-bg p {
  word-break: break-word;
  overflow-wrap: break-word;
}
.epub-chapter-bg p:last-child { margin-bottom: 0; }

/* 8. 标题样式：只提供 font-weight:bold（兜底，EPUB 原作者一般也会设 bold），
   不覆盖 margin/font-family/font-size/color/line-height 等，
   让 EPUB 原作者 h3.chapter-title { margin:1em 0 2.5em; font-family:"fzjt";
   font-size:1.6em; color:#272729; line-height:1.2em } 正常生效。
   用 .epub-chapter-bg（class 选择器）而非 #reader-content-a（ID 选择器），
   避免 ID 选择器优先级过高覆盖 EPUB CSS。
   关键修复：移除 line-height:var(--reader-line-height)，
   之前会覆盖原作者的 line-height（如 .volume-title 的 1.2em），
   破坏原作者的排版意图 */
.epub-chapter-bg h1,
.epub-chapter-bg h2,
.epub-chapter-bg h3,
.epub-chapter-bg h4,
.epub-chapter-bg h5,
.epub-chapter-bg h6 {
  font-weight: bold;
  /* 不设 line-height，让 EPUB 原作者的 line-height 生效 */
}

/* 8a. 标题 max-width 兜底：防止 EPUB 原作者的固定宽度标题溢出 column
   - max-width:100% 只限制最大宽度，不改变 width
   - 原作者的 width:35px（窄宽度竖排标题）仍生效，max-width:100% 不影响
   - 原作者的 width:540px（已被 EpubParser 改为 auto）由 max-width:100% 兜底
   - 之前注释说"让窄宽度标题自动放宽到容器宽度"是错的：
     max-width:100% 不会把 35px 变成 100%，只会限制最大不超过 100% */
#reader-content-a h1,
#reader-content-a h2,
#reader-content-a h3 {
  max-width: 100%;
}

/* 8b. 视频响应式宽高比：EPUB 原作者常用固定 width×height（如 540×360）
   做视频尺寸。EpubParser 已把 >300px 宽度改写为 max-width:100%，
   但 height 仍是固定值，会导致视频变形。
   借鉴 lumina：用 max-width:100% 而非 width:100%!important，避免小视频被拉满 */
#reader-content-a video {
  max-width: 100%;
  height: auto !important;
  max-height: calc(var(--reader-safe-height) - 2em);
  object-fit: contain;
}

/* 9. 引用块：用 .epub-chapter-bg（class 选择器），让 EPUB 原作者 blockquote
   CSS 正常生效（如有）。无 EPUB CSS 时作为合理默认。 */
.epub-chapter-bg blockquote {
  margin: 0 0 var(--reader-paragraph-spacing) 0;
  padding: 0 1em;
  border-left: 3px solid currentColor;
  opacity: 0.85;
}

/* 10. 列表：用 .epub-chapter-bg（class 选择器），让 EPUB 原作者 ul/ol/li
   CSS 正常生效（如有）。无 EPUB CSS 时作为合理默认。 */
.epub-chapter-bg ul,
.epub-chapter-bg ol {
  margin: 0 0 var(--reader-paragraph-spacing) 0;
  padding-left: 1.5em;
}
.epub-chapter-bg li { margin: 0.2em 0; }

/* 11. 分隔线：用 .epub-chapter-bg（class 选择器），让 EPUB 原作者 hr CSS
   正常生效（如 .book-line { border-color: #ff0000 }）。 */
.epub-chapter-bg hr {
  border: none;
  border-top: 1px solid currentColor;
  opacity: 0.3;
  margin: 1em 0;
}

/* 12. 链接：只提供下划线，颜色交给 EPUB 原作者 CSS（a { color: #ff0000 }）。
   用 .epub-chapter-bg a（class 选择器）而非 #reader-content-a a（ID 选择器），
   避免 ID 选择器优先级过高覆盖 EPUB CSS 的链接颜色。
   4e 已显式保留 .epub-chapter-bg a { color: #ff0000 }，这里只补充下划线。 */
.epub-chapter-bg a {
  text-decoration: underline;
  text-underline-offset: 2px;
}

/* 13. sup/sub/ruby 等 HTML5 内联标签：保留原生样式
   WebView user agent 默认已渲染，此处显式声明避免被重置 */
#reader-content-a sup {
  vertical-align: super;
  font-size: smaller;
  line-height: 0;
}
#reader-content-a sub {
  vertical-align: sub;
  font-size: smaller;
  line-height: 0;
}
#reader-content-a ruby { ruby-position: over; }
#reader-content-a rt { font-size: smaller; }
#reader-content-a mark {
  background-color: rgba(255, 235, 59, 0.4);
  color: inherit;
}

/* 14. 代码块 */
#reader-content-a code,
#reader-content-a pre {
  font-family: monospace;
  font-size: 0.9em;
  white-space: pre-wrap;
  word-break: break-word;
}
#reader-content-a pre {
  margin: 0 0 var(--reader-paragraph-spacing) 0;
  padding: 0.5em;
  background-color: rgba(128, 128, 128, 0.1);
  border-radius: 4px;
}

/* 14b. figure 兜底（对齐 lumina figure 规则）：
   - margin:0; padding:0 清除浏览器默认 margin（不同浏览器 figure 默认 margin 不一致）
   - break-inside:avoid 在 _epubAfterCss 第 6 条已设，这里不重复 */
#reader-content-a figure {
  margin: 0;
  padding: 0;
}

/* 14c. 链接禁用指针（对齐 lumina a 规则）：
   - cursor:default 防止链接显示手型光标（阅读器内链接不跳转外部浏览器）
   - 不设 pointer-events:none（需要保留点击事件供 Dart 侧拦截） */
#reader-content-a a {
  cursor: default !important;
}

/* 14d. dl/dd 兜底（对齐 Readium before.css dd 规则）：
   - dd 默认 margin-left:40px（浏览器默认），用 1.5em 跟随字号缩放 */
#reader-content-a dd {
  margin-left: 1.5em;
}

/* 14e. pre tab-size（对齐 Readium before.css pre 规则）：
   - tab-size:2 让代码块 Tab 缩进 2 字符宽（浏览器默认 8 字符太宽） */
#reader-content-a pre {
  -webkit-tab-size: 2;
  -moz-tab-size: 2;
  tab-size: 2;
}

/* 15. 图片对齐语义保护（2026-09-02 深夜重灾区清理）：
   ★ 旧版此处的 float:none!/display:block/margin:1em 三件套是破坏源：
     - float:none !important 灭掉文绕图（EPUB 常见 float 排版全废）
     - display:block 把行内小图标逼成独占一行
     - margin:1em 强加间距破坏紧凑排版
   epub.js / Readium 均不碰这些属性。全撤。
   防溢出由 After CSS 第 5 条负责（max-width:safe-width + height:auto），
   对齐由原书 CSS + text-align 继承链负责。 */
#reader-content-a img {
  max-width: 100%;
}
/* 图片容器居中规则已撤（2026-09-03）：
   多看不改作者对齐——原书 div.logo00 { text-align:left } 的 logo 顶部
   左置，本规则的 ID 级特异性强压原书 left，logo 被居中（多看/实拍对照）。
   作者需要居中时会自己写 text-align:center，与多看行为一致 */

/* 16. 多看行距/段距对齐（2026-09-03 双章实测校准）：
   多看阅读器对 EPUB 应用自身"行距"设置覆盖原书声明——
   实测两章交叉验证：手册页 p.fs2 行距 39.1 物理px（19.55 CSS），
   制作说明 60% 段落同比 ≈1.8×字号；原书 body/p 声明 line-height:130%
   （10.67px 字号 → 13.9 CSS），多看落点 19.55/10.67 = 1.83。
   MR 之前遵循原书 130% → 每页容纳量比多看大 40%（上下对齐失准主因）。
   p 垂直 margin 同理：多看段间距 ≈0（缩进标段首），MR 是 UA 默认 1em。
   不带 !important 的 p margin 让原书 p.mark{margin:1em} 等显式声明照常生效 */
#reader-content-a p,
#reader-content-a div,
#reader-content-a li,
#reader-content-a h1,
#reader-content-a h2,
#reader-content-a h3,
#reader-content-a h4,
#reader-content-a h5,
#reader-content-a h6 {
  line-height: 1.83 !important;
}
#reader-content-a p {
  margin-top: 0;
  margin-bottom: 0;
}
''';
  }

  /// KT 对齐：链接颜色（移植 Readium CSS --USER__linkColor 策略）
  ///
  /// 日间：经典蓝色 #0000EE（Readium 默认）
  /// 夜间：浅蓝 #6FB7FF（降低对比度，避免刺眼）
  static String _linkColor(String textColor, bool isDarkBg) {
    return isDarkBg ? '#6FB7FF' : '#0000EE';
  }

  /// KT 对齐：已访问链接颜色（移植 Readium CSS --USER__visitedColor）
  ///
  /// 日间：紫色 #551A8B（Readium 默认）
  /// 夜间：浅紫 #B98FFF
  static String _visitedColor(bool isDarkBg) {
    return isDarkBg ? '#B98FFF' : '#551A8B';
  }

  /// KT 对齐：选择高亮背景色（移植 Readium CSS --USER__selectionBackgroundColor）
  ///
  /// 日间：浅蓝 #B4D8FE（Readium 默认）
  /// 夜间：深蓝 #1A56DB（夜间背景上更醒目）
  static String _selectionBg(bool isDarkBg) {
    return isDarkBg ? '#1A56DB' : '#B4D8FE';
  }

  /// EPUB After CSS（三段式注入的第三段）
  ///
  /// 参考 Readium Kotlin-toolkit 的 ReadiumCSS-after.css：
  /// 在原作 CSS 之后注入，用 !important 确保分页布局和用户设置
  /// 不被原作 CSS 破坏。
  ///
  /// 核心职责：
  /// 1. 修复原作可能破坏分页的 CSS（overflow-x:hidden / width:100% 等）
  /// 2. 确保 column 布局优先（column-width/column-gap !important）
  /// 3. html/body 布局约束（height:100vh + overflow:hidden）
  /// 4. #reader-content-a 的 absolute 定位 + transform
  static String _epubAfterCss() {
    return '''
/* === After CSS（分页+覆盖，参考 ReadiumCSS-after.css + lumina main.css）=== */

/* 1. html 布局约束（对齐 lumina html + Readium :root 规则）
   - box-sizing: border-box 确保 padding 含在尺寸内
   - height/max-height 固定视口高度（column 分页必需）
   - overflow: hidden 防止内容溢出视口（visible 会破坏分页）
   - touch-action: manipulation 允许点击禁用双击缩放
   - text-size-adjust: none 防止 WebView 自动调整字号
   ★ 2026-09-02 样式破坏修复：移除 font-size/color/bg !important
   原书 body 常有 font-size:97% / 色彩体系（本例《这游戏也太真实了》body
   font-size:97%），html font-size !important 会锚死基准、原书百分比链落点全偏
   （多看基准 ≈11px，咱 15px，全书字大 1.38 倍 → 才需要 0.72 补丁）。
   学 epub.js：阅读器只注入布局骨架，不碰排版属性；
   用户字号走 JS 内联注入（见 _epubUserOverrides），仅当原书无声明时生效 */
html {
  box-sizing: border-box !important;
  height: var(--reader-vh) !important;
  max-height: var(--reader-vh) !important;
  overflow: hidden !important;
  touch-action: manipulation !important;
  -webkit-text-size-adjust: none !important;
  text-size-adjust: none !important;
}

/* 2. body 布局约束
   ★ 2026-09-02 样式破坏修复：不再 margin/padding:0 !important
   原书 body margin 左右各 10px（内容宽 = 屏宽-20），margin:0 清零后
   百分比基准变大 → 封面/木架/卡片全部偏大，与多看对比持续偏差。
   学 epub.js columns()：body 只保留分页必需的约束，
   margin/padding 交给原书 CSS；
   overflow:hidden 保留（防溢出破坏 column 视口约束） */
body {
  width: 100% !important;
  height: 100% !important;
  box-sizing: border-box !important;
  overflow: hidden !important;
}

/* 3. #reader-content-a column 布局强制（!important 防原作破坏）
   保留 _generateCss 的布局：
   - position: absolute; top: 0; bottom: 0; left: 0; width: safe-width
   - column-width = safe-width（单列宽度 = 单页宽度）
   - column-gap = 128px（固定间距消除亚像素误差，与 JS config 一致）
   - height = safe-height（column-fill:auto 需要明确高度）
   ★ 不设 overflow:hidden：裁剪由 #reader-stage 的 overflow:hidden 负责。
     multicol 容器自身设 overflow:hidden 在部分 Android WebView 上会
     抑制超出可视区域的列的创建，导致只生成 1 列 → 第二页空白 */
#reader-content-a {
  column-width: var(--reader-safe-width) !important;
  column-gap: 128px !important;
  column-fill: auto !important;
  height: var(--reader-safe-height) !important;
}

/* 4. ★ 全局元素宽度约束（2026-09-02 样式破坏修复：收窄打击面）
   原先 #reader-content-a * { max-width: safe-width !important }
   会压塌原书装饰元素（绝对定位装饰框、负 margin 出血元素）。
   epub.js 不给内容元素加任何全局约束，只锁 iframe 宽度。
   咱们把 max-width 收窄到真实需要防溢出的媒体元素（第 5 条），
   文字溢出由 word-break 保证，块级元素本身不会超 column 宽 */
#reader-content-a * {
  orphans: 1 !important;
  widows: 1 !important;
  word-break: break-word !important;
  overflow-wrap: break-word !important;
}

/* 5. 媒体元素约束（对齐 lumina img/svg/video 规则）
   - max-width: safe-width 防止图片撑破分栏（原全局 * 规则收窄到这里）
   - max-height: safe-height 防止图片/视频超高
   - height: auto + object-fit: contain 等比缩放
   - break-inside: avoid 防止图片被分栏切断
   ★ object-fit 只加在 img/video 上：svg 原书常用 width/height 控制不加 contain */
#reader-content-a img,
#reader-content-a video {
  max-width: var(--reader-safe-width) !important;
  max-height: var(--reader-safe-height) !important;
  height: auto !important;
  object-fit: contain !important;
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
  page-break-inside: avoid !important;
}
#reader-content-a svg {
  max-width: var(--reader-safe-width) !important;
  max-height: var(--reader-safe-height) !important;
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
  page-break-inside: avoid !important;
}

/* 5b. 表格防溢出（2026-09-02 真实容器细节调整）：
   只约束 max-width 防撑破分栏，不强制 table-layout（保留原书表格排版）。
   长内容靠 td 继承的 word-break 折行 */
#reader-content-a table {
  max-width: var(--reader-safe-width) !important;
}

/* 6. 不可分切元素（对齐 Readium CSS before.css break-inside 规则）
   标题/figure/tr/pre 不应被分栏切断（避免标题与后续内容分离）
   ★ 不含 table：大表格可能超一页，break-inside:avoid 会导致整表推到下一栏
     若表格高度接近 safe-height 则无栏可放 → 表格消失 */
#reader-content-a h1, #reader-content-a h2, #reader-content-a h3,
#reader-content-a h4, #reader-content-a h5, #reader-content-a h6,
#reader-content-a figure, #reader-content-a tr, #reader-content-a pre {
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
  page-break-inside: avoid !important;
}

/* 7. 标题/分页符避免后面断行（对齐 Readium CSS before.css break-after 规则）
   标题后不应立即分栏断行（避免标题独自留在页尾） */
#reader-content-a h2, #reader-content-a h3, #reader-content-a h4,
#reader-content-a h5, #reader-content-a h6, #reader-content-a dt,
#reader-content-a hr, #reader-content-a caption {
  break-after: avoid !important;
  -webkit-column-break-after: avoid !important;
  page-break-after: avoid !important;
}

/* 8. 隐藏滚动条（对齐 lumina ::-webkit-scrollbar 规则）
   分页模式下不应有滚动条，原作可能显示滚动条干扰翻页 */
::-webkit-scrollbar,
::-webkit-scrollbar:horizontal,
::-webkit-scrollbar:vertical {
  -webkit-appearance: none !important;
  background-color: transparent !important;
  display: none !important;
  height: 0 !important;
  width: 0 !important;
}
body::-webkit-scrollbar,
body::-webkit-scrollbar:horizontal,
body::-webkit-scrollbar:vertical {
  -webkit-appearance: none !important;
  background-color: transparent !important;
  display: none !important;
  height: 0 !important;
  width: 0 !important;
}
''';
  }

  /// fixed-layout 章节的 After CSS
  ///
  /// 移植自 Readium Kotlin-toolkit 的 FixedLayoutInterceptor：
  /// - 不做 column 分页，整页等比缩放显示
  /// - fitContain 策略：scale = min(viewW/contentW, viewH/contentH)
  /// - body 固定为原始尺寸，用 transform: scale() 缩放到视口
  /// - transform-origin: top left 确保从左上角对齐
  ///
  /// 与 [_epubAfterCss] 的区别：
  /// - 不设置 column-width/column-gap（不分页）
  /// - body 宽高固定为原始内容尺寸（而非 auto）
  /// - 用 transform scale 替代 column 分页
  static String _fixedLayoutCss(
    double viewWidth,
    double viewHeight,
    double? fixedLayoutWidth,
    double? fixedLayoutHeight,
  ) {
    // 兜底：尺寸未知时用视口尺寸（1:1 不缩放）
    final contentW = (fixedLayoutWidth != null && fixedLayoutWidth > 0)
        ? fixedLayoutWidth
        : viewWidth;
    final contentH = (fixedLayoutHeight != null && fixedLayoutHeight > 0)
        ? fixedLayoutHeight
        : viewHeight;

    // fitContain：等比缩放使内容完全包含在视口内（不裁切、不溢出）
    // 取宽高缩放比中较小者，确保两个方向都不溢出
    final scaleX = viewWidth / contentW;
    final scaleY = viewHeight / contentH;
    final scale = scaleX < scaleY ? scaleX : scaleY;

    // 缩放后居中：计算偏移量让内容在视口中居中显示
    final offsetX = (viewWidth - contentW * scale) / 2;
    final offsetY = (viewHeight - contentH * scale) / 2;

    return '''
/* === After CSS（fixed-layout 等比缩放，参考 Readium FixedLayoutInterceptor）=== */
/* fixed-layout 章节（漫画/画册）：不做 column 分页，整页等比缩放显示 */

/* 1. html/body 固定为原始内容尺寸，禁用滚动 */
html, body {
  width: ${contentW}px !important;
  height: ${contentH}px !important;
  margin: 0 !important;
  padding: 0 !important;
  overflow: hidden !important;
}

/* 2. body 应用 fitContain 等比缩放 + 居中偏移
   - transform: scale(scale) translate(offset) 顺序：先缩放再平移
   - transform-origin: top left 确保缩放基准点在左上角
   - position:absolute 脱离文档流，避免影响视口尺寸计算 */
body {
  position: absolute !important;
  top: 0 !important;
  left: 0 !important;
  transform: scale($scale) !important;
  transform-origin: top left !important;
  /* 居中偏移：通过 margin 实现（transform 后 margin 仍按原始尺寸计算，
     用 margin-left/top 偏移到居中位置） */
  margin-left: ${offsetX / scale}px !important;
  margin-top: ${offsetY / scale}px !important;
}

/* 3. 禁用 #reader-content-a 的 column 分页（fixed-layout 不分页）
   - position: static 让内容正常流动
   - column-width: auto 取消分栏
   - overflow: visible 让 body 的 transform 生效 */
#reader-content-a {
  position: static !important;
  width: auto !important;
  height: auto !important;
  column-width: auto !important;
  column-gap: 0 !important;
  column-fill: auto !important;
  overflow: visible !important;
  top: auto !important;
  left: auto !important;
}

/* 4. 确保图片/SVG 等媒体元素填满原始内容区
   fixed-layout 漫画通常是单张图片或 SVG 占满整页 */
img, svg, video {
  max-width: 100% !important;
  max-height: 100% !important;
  width: 100% !important;
  height: 100% !important;
  object-fit: contain !important;
}

/* 5. 用户文字颜色/背景色仍生效（夜间模式需要） */
html {
  color: var(--reader-text-color) !important;
  background-color: var(--reader-bg-color) !important;
}

/* 6. KT 对齐：图片夜间模式变暗（移植 Readium CSS --USER__darkenImages）
   - darken: 夜间模式降低图片亮度（避免白底图片刺眼）
   - 不做反相（invert 会破坏彩色图片和漫画）
   日间模式 darken=1，filter 无视觉效果 */
img {
  -webkit-filter: brightness(var(--reader-darken-images)) !important;
  filter: brightness(var(--reader-darken-images)) !important;
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

  /// 构建 EPUB 富 HTML 段落（滚动模式追加章节用）
  ///
  /// 与 [buildParagraphsHtml] 对称，专门用于 EPUB 富 HTML 内容：
  /// - 解析 `[[EPUB_CSS]]...[[/EPUB_CSS]][[EPUB_BODY]]...[[/EPUB_BODY]]` 包裹格式
  /// - 在 body 外包一层 `<div data-chapter-index="...">` 供 IntersectionObserver 监测
  /// - 不生成应用自身标题（EPUB 自带标题由作者设定，应保留）
  ///
  /// 滚动模式下用户滚到底部时，[novel_reader_page._appendNextChapter] 调用此方法
  /// 生成段落 HTML，再通过 [ReaderWebViewController.appendChapter] 追加到 DOM。
  static String buildEpubParagraphsHtml(String richContent, int chapterIndex) {
    final parsed = _parseRichHtmlContent(richContent);
    final bodyHtml = parsed.$2;
    return '<div data-chapter-index="$chapterIndex" style="display:block">$bodyHtml</div>';
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

/* ★ 多看式按页背景（2026-09-03）：把 .epub-chapter-bg 的作者背景搬到
   position:fixed 底层元素。
   为什么：Duokan 分页每屏重绘 body 背景（背景相对视口取景）；wrapper 在
   multicol 里跨页连续，cover 按"内容全高"取景 → 构图与多看错位
   （制作说明页实拍：多看塔楼构图 / MR 武士构图）；background-attachment:
   fixed 在 multicol+transform 环境下 WebView 不生效。
   做法：computed style 原值拷贝（background-image/size/position/repeat，
   不修改作者声明，只换绘制层）→ wrapper 背景清空防双重绘制。 */
(function() {
  function mountFixedBg() {
    var w = document.querySelector('.epub-chapter-bg');
    if (!w || document.getElementById('reader-fixed-bg')) return;
    var cs = window.getComputedStyle(w);
    if (!cs.backgroundImage || cs.backgroundImage === 'none') return;
    var under = document.createElement('div');
    under.id = 'reader-fixed-bg';
    under.style.cssText = 'position:fixed;left:0;top:0;width:100%;height:100%;'
      + 'z-index:0;pointer-events:none;'
      + 'background-image:' + cs.backgroundImage
      + ';background-size:' + cs.backgroundSize
      + ';background-position:' + cs.backgroundPosition
      + ';background-repeat:' + cs.backgroundRepeat
      + ';background-color:' + cs.backgroundColor;
    document.body.insertBefore(under, document.body.firstChild);
    w.style.backgroundImage = 'none';
    w.style.backgroundColor = 'transparent';
    // 内容层抬到背景之上（wrapper 在 multicol 流内）
    w.style.position = 'relative';
    w.style.zIndex = '1';
  }
  if (document.querySelector('.epub-chapter-bg')) {
    mountFixedBg();
  } else {
    window.addEventListener('DOMContentLoaded', mountFixedBg);
  }
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

  // === 建议4：菜单召唤 touchstart 预判 ===
  // 记录单指 touchstart 的位置和时间戳，touchend 时判定是否为 tap
  // - 主路径：touchend 判定为 tap → 立即 notifyTap（比 click 快 ~100ms）
  // - 防冲突：touchend 触发 tap 后设置标志位，click handler 跳过避免双触发
  // - 排除长按选文字：touchend 时检查 window.getSelection()，有选区则不触发 tap
  // - 排除滑动翻页：移动距离 > 10px 时不触发 tap
  var touchStartX = 0;
  var touchStartY = 0;
  var touchStartTime = 0;
  var touchStartActive = false;  // 是否有未决的 touchstart（单指）
  var lastTapFromTouchEnd = false;  // touchend 已触发 tap，click 跳过

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

    // 绑定 click 监听器（兜底：touchend 已触发 tap 时跳过，避免重复）
    // - 主路径走 touchend 预判（见下方 touchstart/touchend），比 click 快 ~100ms
    // - click 仅在 touchend 未触发时兜底（如鼠标点击、辅助功能点击）
    document.addEventListener('click', function(e) {
      if (isAnimating) {
        console.log('[reader] click ignored (animating)');
        return;
      }
      if (e.target && e.target.tagName === 'IMG') {
        notifyImageTap(e.target.src, e.target.getBoundingClientRect());
        return;
      }
      // touchend 已触发过 tap → 跳过（避免双触发）
      if (lastTapFromTouchEnd) {
        lastTapFromTouchEnd = false;
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

    // ★ CSS polyfill（移植自 lumina CssPolyfillManager）★
    // 对齐 lumina 的 CSS 后处理，补全 EPUB 原作 CSS 的兼容问题：
    // 1. font-size/line-height px 值 → 注入 var(--reader-font-size) 主题驱动
    // 2. break-before/after → webkit-column-break 兼容（旧 WebView 不支持 CSS3 break-*）
    // background-color 不覆盖：保留原作者设定的原始背景色
    polyfillEpubCss();

    // ★ polyfill 后强制 reflow：polyfill 修改 font-size/line-height 会改变
    //   文本宽度，column 布局需要重新流动内容到各列。不强制 reflow 的话，
    //   后续 rAF 读 scrollWidth 可能拿到重排前的旧值（只 1 列）→ 第二页空白。
    if (contentA) void contentA.offsetHeight;

    // 等待 DOM 渲染完成后通知 Dart 侧
    // 首次通知：rAF 三帧后通知，让 column 布局充分重排完成。
    // 之前用双帧在部分 Android WebView 上不足以完成 multicol 重排，
    // polyfill 修改 font-size 后文本宽度变化需要更多时间流动到第二列。
    requestAnimationFrame(function() {
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
        installImageLoadRepaginate();
        dumpDomSnapshot('chapter');
      });
    }).catch(function() {
      // 兜底：异常时也通知一次
      requestAnimationFrame(function() {
        notifyPageCountReady();
        installImageLoadRepaginate();
        dumpDomSnapshot('chapter');
      });
    });
  }

  // 图片加载完成后的分页重算（借鉴 epub.js imageLoadListeners → EXPAND 机制：
  // contents.js:557-568 对 naturalWidth===0 的 img 挂 onload→expand；
  // iframe.js 据此 reformat 重新分页。MR 的 notifyPageCountReadyWhenStable
  // 已覆盖「整章加载完成后通知 Dart」，此钩子补齐「单图晚到 → 立即重排」：
  // 强制 contentA 重排一帧并重新通知 pageCount，防止图片加载晚于首帧
  // 导致 pageCount 偏小、跳页 translate3d 落点错误（出现"翻页空白页"）。
  function installImageLoadRepaginate() {
    var imgs = document.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      (function(img) {
        if (img.complete) return;
        var handler = function() {
          img.removeEventListener('load', handler);
          img.removeEventListener('error', handler);
          requestAnimationFrame(function() {
            notifyPageCountReady();
          });
        };
        img.addEventListener('load', handler);
        img.addEventListener('error', handler);
      })(imgs[i]);
    }
  }
  // ★ DOM 快照导出（排版诊断）★
  // 遍历渲染后的 DOM 树，提取每个元素的标签/class/计算样式/布局矩形，
  // 通过 console 桥输出到 Flutter logcat。用于与多看渲染结果逐节点对比
  // 排版值（font-size/line-height/margin/对齐/图片尺寸等）。
  // 节点上限 400、深度上限 8，超长 JSON 按 1400 字符分块输出。
  function dumpDomSnapshot(reason) {
    try {
      var props = ['display', 'position', 'width', 'height', 'font-size',
        'line-height', 'text-align', 'text-indent', 'margin', 'padding',
        'color', 'background-color', 'font-weight', 'float', 'border-radius',
        'white-space', 'vertical-align'];
      function styleOf(el) {
        var s = getComputedStyle(el);
        var o = {};
        for (var i = 0; i < props.length; i++) o[props[i]] = s.getPropertyValue(props[i]);
        return o;
      }
      var nodes = [];
      function walk(el, depth) {
        if (nodes.length >= 400 || !el || el.nodeType !== 1) return;
        var r = el.getBoundingClientRect();
        var n = {
          t: el.tagName.toLowerCase(),
          c: (el.className && typeof el.className === 'string') ? el.className : '',
          d: depth,
          s: styleOf(el),
          x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height)
        };
        for (var k = 0; k < el.childNodes.length; k++) {
          var cn = el.childNodes[k];
          if (cn.nodeType === 3 && cn.textContent && cn.textContent.trim()) {
            n.txt = cn.textContent.trim().slice(0, 40);
            break;
          }
        }
        if (el.tagName === 'IMG') {
          n.src = String(el.currentSrc || el.src || '').split('/').pop();
          n.nat = el.naturalWidth + 'x' + el.naturalHeight;
        }
        nodes.push(n);
        if (depth < 8) {
          for (var j = 0; j < el.children.length; j++) walk(el.children[j], depth + 1);
        }
      }
      if (document.body) walk(document.body, 0);
      var json = JSON.stringify(nodes);
      var chunk = 1400;
      for (var p = 0; p < json.length; p += chunk) {
        console.log('[reader] domDump ' + reason + ' ' + json.slice(p, p + chunk));
      }
      console.log('[reader] domDump done ' + reason + ' nodes=' + nodes.length + ' chars=' + json.length);
    } catch (e) {
      console.error('[reader] domDump failed: ' + e);
    }
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
    // - JS 端先移除视觉标记（收集被删除 span 的 data-highlight-id），
    //   再通知 Dart 删除持久化记录（按 ids 精确删除，避免 selectedText 重复误删）
    if (action === 'removeHighlight') {
      var rmResultJson = removeHighlightInSelection();
      var rmIds = [];
      try { rmIds = JSON.parse(rmResultJson).ids || []; } catch (e) {}
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler(
          'onSelectionAction', 'removeHighlight', text, rl, rt, rw, rh,
          JSON.stringify(rmIds));
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
  //   此路径下精确记录 startContainer/endContainer 的 XPath 和 offset，
  //   schemaVersion=2，重启后可按 XPath+offset 精确恢复
  // - 跨元素选区：surroundContents 会抛 DOMException，fallback 到
  //   document.execCommand('hiliteColor')，仅做背景色
  //   此路径无法记录精确位置，schemaVersion=1，重启后按 selectedText 文本匹配
  //
  // 返回 JSON 字符串：
  //   成功（单元素）：'{"success":true,"schemaVersion":2,"selectedText":"...",
  //                   "startContainerXPath":"...","endContainerXPath":"...",
  //                   "startOffset":N,"endOffset":N,"chapterContentHash":"..."}'
  //   成功（跨元素）：'{"success":true,"schemaVersion":1,"selectedText":"..."}'
  //   失败：'{"success":false}'
  // Dart 侧 JSON 解析后按 schemaVersion 走不同持久化路径
  function highlightSelection(colorIndex, styleIndex) {
    var failJson = '{"success":false}';
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) {
      hideSelectionMenu();
      return failJson;
    }
    var range = sel.getRangeAt(0);
    if (range.collapsed) {
      hideSelectionMenu();
      return failJson;
    }

    var colors = ['#FFF176', '#A5D6A7', '#90CAF9', '#F48FB1', '#FFCC80', '#CE93D8'];
    var color = colors[colorIndex] || colors[0];
    var textDecoration = styleIndex === 1
      ? 'underline'
      : (styleIndex === 2 ? 'line-through' : (styleIndex === 3 ? 'underline wavy' : ''));

    // 在 surroundContents 之前抓取选区元数据（surroundContents 会修改 DOM 结构）
    var startContainer = range.startContainer;
    var endContainer = range.endContainer;
    var startOffset = range.startOffset;
    var endOffset = range.endOffset;
    var selectedText = sel.toString();
    var schemaVersion = 1;
    var startXPath = null;
    var endXPath = null;

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
        // 单元素选区：surroundContents 成功 → 记录 XPath + offset（v2）
        range.surroundContents(mark);
        success = true;
        startXPath = getNodeXPath(startContainer);
        endXPath = getNodeXPath(endContainer);
        // XPath 计算成功才标记为 v2；否则降级 v1 走文本匹配
        if (startXPath && endXPath) {
          schemaVersion = 2;
        }
      } catch (e) {
        // 跨元素选区（如跨段落）：surroundContents 会抛
        // DOMException: The boundary points of a Range are not valid
        // fallback 到 execCommand('hiliteColor')，仅做背景色
        // 此路径无法精确恢复 → 保持 schemaVersion=1
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

    // 构造返回 JSON
    var hash = computeChapterHash();
    var result = {
      success: success,
      schemaVersion: schemaVersion,
      selectedText: selectedText,
      startContainerXPath: startXPath,
      endContainerXPath: endXPath,
      startOffset: startOffset,
      endOffset: endOffset,
      chapterContentHash: hash
    };
    return JSON.stringify(result);
  }

  // === Range+偏移序列化辅助函数（schemaVersion=2）===

  // 计算文本节点相对于 contentA 的 XPath
  // 返回形如 '/div[1]/p[3]/text()' 的路径；node 不在 contentA 内时返回 null
  function getNodeXPath(node) {
    if (!node || !contentA) return null;
    var parts = [];
    var cur = node;
    while (cur && cur !== contentA) {
      var parent = cur.parentNode;
      if (!parent) return null;
      // 计算同类型 + 同 nodeName 兄弟中的索引（XPath 标准：1-based）
      var idx = 1;
      var sibling = cur.previousSibling;
      while (sibling) {
        if (sibling.nodeType === cur.nodeType && sibling.nodeName === cur.nodeName) {
          idx++;
        }
        sibling = sibling.previousSibling;
      }
      var part;
      if (cur.nodeType === Node.TEXT_NODE) {
        part = 'text()';
      } else if (cur.nodeType === Node.ELEMENT_NODE) {
        part = cur.nodeName.toLowerCase();
      } else {
        // 注释节点等不处理
        return null;
      }
      parts.unshift(part + '[' + idx + ']');
      cur = parent;
    }
    if (cur !== contentA) return null;
    return '/' + parts.join('/');
  }

  // 按 XPath 在 contentA 下查找节点
  // 支持 '/div[1]/p[3]/text()' 格式，找不到返回 null
  function resolveXPath(xpath) {
    if (!xpath || !contentA) return null;
    if (xpath.charAt(0) !== '/') return null;
    // 去掉开头的 '/'，按 '/' 分段
    var parts = xpath.substring(1).split('/');
    var cur = contentA;
    for (var i = 0; i < parts.length; i++) {
      if (!cur) return null;
      var part = parts[i];
      // 解析 'name[idx]' 或 'text()[idx]'
      var m = part.match(/^([^\[]+)\[(\d+)\]$/);
      if (!m) return null;
      var name = m[1];
      var idx = parseInt(m[2], 10);
      var matched = 0;
      var found = null;
      var child = cur.firstChild;
      while (child) {
        var childName;
        if (child.nodeType === Node.TEXT_NODE) {
          childName = 'text()';
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          childName = child.nodeName.toLowerCase();
        } else {
          child = child.nextSibling;
          continue;
        }
        if (childName === name) {
          matched++;
          if (matched === idx) {
            found = child;
            break;
          }
        }
        child = child.nextSibling;
      }
      if (!found) return null;
      cur = found;
    }
    return cur;
  }

  // FNV-1a 32 位哈希
  function fnv1a(str) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < str.length; i++) {
      hash ^= str.charCodeAt(i);
      hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
    }
    return hash.toString(16);
  }

  // 计算章节正文前 2000 字的 FNV-1a 哈希
  // 用于换源后内容变化检测：哈希不一致时降级到文本匹配
  function computeChapterHash() {
    if (!contentA) return '';
    var text = contentA.textContent || '';
    if (text.length > 2000) text = text.substring(0, 2000);
    return fnv1a(text);
  }

  // 按 Range+offset 恢复单条高亮（schemaVersion=2）
  // 返回 true 表示恢复成功；失败时调用方应 fallback 到文本匹配
  function restoreHighlightByRange(item) {
    if (!contentA) return false;
    if (!item.startContainerXPath || !item.endContainerXPath) return false;
    var startNode = resolveXPath(item.startContainerXPath);
    var endNode = resolveXPath(item.endContainerXPath);
    if (!startNode || !endNode) return false;
    if (startNode.nodeType !== Node.TEXT_NODE) return false;
    if (endNode.nodeType !== Node.TEXT_NODE) return false;

    var startOffset = item.startOffset || 0;
    var endOffset = item.endOffset || 0;
    // 边界检查（换源后内容可能变短）
    if (startOffset > startNode.nodeValue.length) return false;
    if (endOffset > endNode.nodeValue.length) return false;

    var colors = ['#FFF176', '#A5D6A7', '#90CAF9', '#F48FB1', '#FFCC80', '#CE93D8'];
    var colorIndex = item.color || 0;
    var styleIndex = item.style || 0;
    var color = colors[colorIndex] || colors[0];
    var textDecoration = styleIndex === 1 ? 'underline'
      : (styleIndex === 2 ? 'line-through' : (styleIndex === 3 ? 'underline wavy' : ''));

    try {
      var r = document.createRange();
      r.setStart(startNode, startOffset);
      r.setEnd(endNode, endOffset);
      var mark = document.createElement('span');
      mark.className = 'sel-hl';
      if (item.id) mark.setAttribute('data-highlight-id', item.id);
      mark.style.backgroundColor = styleIndex === 0 ? color : 'transparent';
      if (textDecoration) {
        mark.style.textDecoration = textDecoration;
        mark.style.textDecorationColor = color;
        mark.style.textDecorationThickness = '2px';
        mark.style.webkitTextDecorationColor = color;
      }
      r.surroundContents(mark);
      return true;
    } catch (e) {
      // surroundContents 失败（边界跨元素等），交回 fallback
      return false;
    }
  }

  // Phase 3.1：删除当前选区命中的 .sel-hl 元素
  //
  // 实现：
  // - 用 TreeWalker 遍历选区公共祖先下所有 .sel-hl 元素
  // - 通过 range.intersectsNode 验证与当前选区有交集
  // - 把命中的 .sel-hl span 内容（文本节点）提到父级，移除 span
  //
  // 返回 JSON 字符串：'{ "count": N, "ids": ["id1","id2",...] }'
  // - count：删除的 .sel-hl 数量（用于 SnackBar 提示）
  // - ids：被删除 span 的 data-highlight-id 列表（无 id 的不计入）
  //   Dart 侧按 ids 精确删除持久化记录，避免 selectedText 重复误删
  function removeHighlightInSelection() {
    var failJson = '{"count":0,"ids":[]}';
    var sel = window.getSelection();
    if (!sel || sel.rangeCount === 0) return failJson;
    var range = sel.getRangeAt(0);
    if (range.collapsed) return failJson;

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

    // 移除每个 .sel-hl span，把内部子节点提到父级；同时收集 id
    var ids = [];
    for (var j = toRemove.length - 1; j >= 0; j--) {
      var m = toRemove[j];
      var hid = m.getAttribute('data-highlight-id');
      if (hid) ids.push(hid);
      var parent = m.parentNode;
      while (m.firstChild) {
        parent.insertBefore(m.firstChild, m);
      }
      parent.removeChild(m);
    }
    return JSON.stringify({ count: toRemove.length, ids: ids });
  }

  // Phase 3.2：恢复持久化高亮（Dart 在章节加载后传入 JSON 列表）
  //
  // 参数 list: [{ id, selectedText, color, style, note, schemaVersion, ... }]
  // - schemaVersion=2（新格式）：优先按 XPath+offset 精确恢复
  //   失败时（节点找不到/offset 越界/哈希不一致）自动 fallback 到文本匹配
  // - schemaVersion=1（旧格式 / 跨元素高亮）：按 selectedText 文本匹配
  // - 同时给 mark 加 data-highlight-id 属性，便于按 id 删除
  function restoreHighlights(list) {
    if (!list || !list.length) return;
    if (!contentA) return;
    var colors = ['#FFF176', '#A5D6A7', '#90CAF9', '#F48FB1', '#FFCC80', '#CE93D8'];
    // 当前章节哈希（用于 v2 校验，不一致则 fallback）
    var currentHash = computeChapterHash();
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

        // v2 路径：哈希一致 + XPath/offset 齐全 → 精确恢复
        if (item.schemaVersion === 2
            && item.startContainerXPath
            && item.endContainerXPath
            && (!item.chapterContentHash || item.chapterContentHash === currentHash)) {
          if (restoreHighlightByRange(item)) return;
          // 精确恢复失败 → fallback 到文本匹配
        }

        // v1 路径 / v2 fallback：用 TreeWalker 找文本节点中第一次匹配
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

  // 按 data-highlight-id 删除视觉高亮（持久化由 Dart 侧处理）
  // - 精确匹配 id，避免 selectedText 重复时误删
  // 返回 true 表示找到并删除了对应 span
  function removeHighlightById(id) {
    if (!id || !contentA) return false;
    var mark = contentA.querySelector('.sel-hl[data-highlight-id="' + id + '"]');
    if (!mark) return false;
    var parent = mark.parentNode;
    while (mark.firstChild) {
      parent.insertBefore(mark.firstChild, mark);
    }
    parent.removeChild(mark);
    return true;
  }

  // 给最近一次 surroundContents 创建的 .sel-hl span 设置 data-highlight-id
  // 调用时机：Dart 端持久化高亮拿到 id 后立即调用，把 id 回写到 span
  // 实现：找 contentA 内最后一个没有 data-highlight-id 的 .sel-hl，
  //       设置 id（surroundContents 路径下单元素选区只产生一个 span）
  // 返回 true 表示设置成功
  function setLastHighlightId(id) {
    if (!id || !contentA) return false;
    var marks = contentA.querySelectorAll('.sel-hl');
    for (var i = marks.length - 1; i >= 0; i--) {
      var m = marks[i];
      if (!m.getAttribute('data-highlight-id')) {
        m.setAttribute('data-highlight-id', id);
        return true;
      }
    }
    return false;
  }

  // Phase 3.2：按 selectedText 删除视觉高亮（旧路径，保留兼容）
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
    // ★ 强制 reflow：CSS 变量更新后，multicol 容器的 height/column-width
    //   依赖这些变量（通过 calc），但部分 WebView 不会立即重排 column 布局。
    //   读取 offsetHeight 触发同步 reflow，确保 --reader-safe-height
    //   重新计算并应用到 #reader-content-a，内容才能正确流向第二列。
    //   不加此行时初始 --reader-vh=100vh（屏幕高度）偏大，第一列能容纳
    //   所有内容不产生第二列 → getPageCount 返回 1 → 第二页空白。
    if (contentA) void contentA.offsetHeight;
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
    // 同时记录单指 touchstart 位置和时间戳，供 touchend 判定 tap
    document.addEventListener('touchstart', function(e) {
      if (e.touches.length > 1) {
        e.preventDefault();
        // 多指触摸 → 取消 tap 预判（避免双指操作误触发菜单）
        touchStartActive = false;
        return;
      }
      // 单指 touchstart → 记录位置和时间，供 touchend 判定 tap
      var t = e.changedTouches[0];
      if (t) {
        touchStartX = t.clientX;
        touchStartY = t.clientY;
        touchStartTime = Date.now();
        touchStartActive = true;
      }
    }, { passive: false });

    // touchmove 多指也拦截（双保险）
    // 关键：必须 passive:true，否则浏览器在每次 touchmove 都要同步执行 JS，
    // 会阻塞主线程的滚动响应，导致滚动模式严重卡顿（passive:false 是滚动卡顿元凶）
    // supportZoom:false + viewport user-scalable=no 已禁用缩放，多指时即便不
    // preventDefault 也不会触发缩放
    // 同时：
    // - touchmove 超过阈值 → 取消 tap 预判（识别为滑动翻页/滚动）
    // - 用户主动滚动 → 取消进行中的平滑滚动动画（让用户立即接管）
    document.addEventListener('touchmove', function(e) {
      if (e.touches.length > 1) {
        e.preventDefault();
        touchStartActive = false;
        cancelSmoothScroll();
        return;
      }
      // 移动距离 > 10px → 取消 tap 预判（滑动翻页或滚动）
      if (touchStartActive) {
        var t = e.changedTouches[0];
        if (t) {
          var dx = t.clientX - touchStartX;
          var dy = t.clientY - touchStartY;
          if (dx * dx + dy * dy > 100) {  // 10^2 = 100
            touchStartActive = false;
            // 用户开始主动滚动 → 取消平滑滚动动画
            cancelSmoothScroll();
          }
        }
      }
    }, { passive: true });

    // 鼠标滚轮：用户主动滚动 → 取消平滑滚动动画
    document.addEventListener('wheel', function(e) {
      if (e.ctrlKey) {
        e.preventDefault();
        return;
      }
      // 非缩放滚轮 → 用户主动滚动，取消动画
      cancelSmoothScroll();
    }, { passive: false });

    // 双击检测 + tap 预判 + onTouchEnd 通知
    // - tap 预判：单指 + 未移动 + 时间 < 500ms + 无选区 → notifyTap
    // - 双击检测：仅记录时间戳，不 preventDefault
    // - onTouchEnd：通知 Dart 即时销毁翻页动画覆盖层
    var lastTouchEnd = 0;
    document.addEventListener('touchend', function(e) {
      var now = Date.now();
      if (now - lastTouchEnd <= 300) {
        // 双击：不阻止默认行为（缩放已禁），仅日志
        console.log('[reader] double tap detected');
        // 双击 → 取消 tap 预判
        touchStartActive = false;
      }
      lastTouchEnd = now;

      // 建议4：tap 预判
      // - 仅在 touchStartActive（单指 + 未移动）时触发
      // - 时间 < 500ms（长按选文字不算 tap）
      // - 无活动选区（避免与长按选文字冲突）
      // - 非动画中
      // 满足条件 → 立即 notifyTap，并设置标志位让 click handler 跳过
      if (touchStartActive && !isAnimating) {
        var elapsed = now - touchStartTime;
        var hasSelection = window.getSelection && window.getSelection().toString().length > 0;
        if (elapsed < 500 && !hasSelection) {
          var t = e.changedTouches[0];
          var tapX = t ? t.clientX : touchStartX;
          var tapY = t ? t.clientY : touchStartY;
          // 检查点击目标是否为图片（图片走 onImageTap，不走 tap）
          var root = document.getElementById('reader-root');
          var rect = root ? root.getBoundingClientRect() : null;
          if (rect) {
            var localX = tapX - rect.left;
            var localY = tapY - rect.top;
            var el = document.elementFromPoint(localX, localY);
            if (el && el.tagName === 'IMG') {
              notifyImageTap(el.src, el.getBoundingClientRect());
            } else {
              notifyTap(tapX, tapY);
            }
          } else {
            notifyTap(tapX, tapY);
          }
          lastTapFromTouchEnd = true;
        }
      }
      touchStartActive = false;

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
    /* 借鉴 lumina：用 Math.round 替代 Math.ceil，减少浮点误差。
       ceil 在亚像素误差下会多算一个空白页（scrollWidth 比 N*(columnWidth+gap)
       多 0.5px 时 ceil 进位成 N+1）；round 容差更好，配合 column-gap:128px
       固定值，分页计算稳定。 */
    var pageCount = Math.round((scrollWidth + gap) / (columnWidth + gap));
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

  // 滚动模式平滑滚动动画状态
  // - 同一时刻只允许一个滚动动画，新滚动请求会取消旧动画
  // - 用户主动滚动（touchmove/wheel）时也会取消动画（见 touchmove handler）
  var smoothScrollRafId = 0;
  var smoothScrollStartTime = 0;
  var smoothScrollFrom = 0;
  var smoothScrollTo = 0;
  var smoothScrollDuration = 300;  // ms，与翻页动画时长对齐
  var smoothScrollOnDone = null;

  // easeInOutQuad 缓动函数：起步慢、中间快、结束慢，适合阅读器翻页
  function easeInOutQuad(t) {
    return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;
  }

  // requestAnimationFrame 驱动的平滑滚动
  // - 取消进行中的动画，避免冲突
  // - 边界（0/maxScroll）立即跳转，不做动画
  // - 完成后回调 onDone（用于 Dart 侧进度回调）
  function smoothScrollTo(target, onDone) {
    if (!config.isScrollMode) {
      if (onDone) onDone();
      return;
    }
    var viewport = body.clientHeight;
    var maxScroll = body.scrollHeight - viewport;
    if (maxScroll <= 0) {
      if (onDone) onDone();
      return;
    }
    // clamp target
    if (target <= 0) target = 0;
    if (target >= maxScroll) target = maxScroll;

    // 取消进行中的动画
    if (smoothScrollRafId) {
      cancelAnimationFrame(smoothScrollRafId);
      smoothScrollRafId = 0;
    }

    var from = body.scrollTop || 0;
    // 距离很小或已在目标位置 → 立即跳转
    if (Math.abs(target - from) < 2) {
      body.scrollTop = target;
      if (onDone) onDone();
      return;
    }

    smoothScrollFrom = from;
    smoothScrollTo = target;
    smoothScrollStartTime = Date.now();
    smoothScrollOnDone = onDone;

    function step() {
      var now = Date.now();
      var elapsed = now - smoothScrollStartTime;
      var t = Math.min(1, elapsed / smoothScrollDuration);
      var eased = easeInOutQuad(t);
      var next = smoothScrollFrom + (smoothScrollTo - smoothScrollFrom) * eased;
      body.scrollTop = next;
      if (t < 1) {
        smoothScrollRafId = requestAnimationFrame(step);
      } else {
        smoothScrollRafId = 0;
        body.scrollTop = smoothScrollTo;  // 确保精确到目标
        var cb = smoothScrollOnDone;
        smoothScrollOnDone = null;
        if (cb) cb();
      }
    }
    smoothScrollRafId = requestAnimationFrame(step);
  }

  // 取消进行中的平滑滚动（用户主动滚动时调用）
  function cancelSmoothScroll() {
    if (smoothScrollRafId) {
      cancelAnimationFrame(smoothScrollRafId);
      smoothScrollRafId = 0;
      smoothScrollOnDone = null;
    }
  }

  function scrollByViewport(direction) {
    if (!config.isScrollMode) return -1;
    // 用 body.clientHeight 而非 window.innerHeight（同 getScrollProgress）
    var viewport = body.clientHeight;
    var maxScroll = body.scrollHeight - viewport;
    if (maxScroll <= 0) return -1;
    var current = body.scrollTop || 0;
    var target = current + direction * viewport * 0.9;
    var clamped = Math.max(0, Math.min(maxScroll, target));
    // 平滑滚动到目标位置，完成后返回进度比例
    // 边界（0/maxScroll）也走动画，让用户感知到「滚到头了」
    smoothScrollTo(clamped, null);
    return clamped / maxScroll;
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
    // 对齐 lumina：直接用 scrollWidth 计算页数，不需要虚拟列补齐。
    // 之前的 appendVirtualColumnIfNeeded 操作 document.body，但 column 容器
    // 是 #reader-content-a，虚拟列加到 body 不影响 contentA 的 scrollWidth，
    // 且 html 上无 column-count 属性导致函数一直 return false，从未生效。
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
    // 排版诊断：章节内容插入后导出 DOM 快照
    requestAnimationFrame(function() { dumpDomSnapshot('append'); });
  }

  // ★ CSS polyfill（移植自 lumina CssPolyfillManager）★
  //
  // 对齐 lumina 的 CSS 后处理机制，补全 EPUB 原作 CSS 的兼容问题：
  //
  // 1. font-size/line-height px 值缩放：
  //    EPUB 原作常写 `font-size: 16px` / `line-height: 1.5`，固定 px 不随用户
  //    字号设置变化。lumina 用 calc(value * var(--lumina-zoom)) polyfill，
  //    咱们改成注入 var(--reader-font-size) 让用户字号生效。
  //    - font-size: Npx → var(--reader-font-size)（完全由用户字号驱动）
  //    - line-height: N（无单位）保留（相对值，不破坏作者行距意图）
  //    - line-height: Npx → calc(Npx * 1em)（随字号等比缩放）
  //
  // 2. break-before/after → webkit-column-break 兼容：
  //    旧版 Android WebView 不支持 CSS3 break-before/after，
  //    需转换为 -webkit-column-break-before/after。
  //    - page/right/left → always
  //    - avoid → avoid
  //    - auto → auto
  //
  // 注意：
  // - 只处理 EPUB 富 HTML 模式（纯文本模式无原作 CSS，无需 polyfill）
  // - background-color 不做覆盖：保留原作者设定的原始背景色，
  //   按原作者意图渲染（作者设什么背景色就显示什么背景色）
  //
  function polyfillEpubCss() {
    var doc = document;
    var sheets = doc.styleSheets;
    if (!sheets) return;

    for (var i = 0; i < sheets.length; i++) {
      var sheet = sheets[i];
      var rules;
      try {
        rules = sheet.cssRules || sheet.rules;
      } catch (e) {
        // 跨域样式表无法访问 cssRules，跳过（lumina 同样处理）
        console.warn('[reader] polyfill: stylesheet ' + i + ' blocked: ' + e);
        continue;
      }
      if (!rules) continue;

      for (var j = 0; j < rules.length; j++) {
        var rule = rules[j];
        if (rule.type !== 1) continue; // 只处理 CSSStyleRule (type=1)
        var style = rule.style;
        if (!style) continue;

        // 1. font-size polyfill
        polyfillFontSize(style);

        // 2. line-height polyfill
        polyfillLineHeight(style);

        // 3. break-before/after → webkit-column-break 兼容
        polyfillBreakRules(style);
      }
    }

    console.log('[reader] polyfillEpubCss done, sheets=' + sheets.length);
  }

  // font-size px 值 → var(--reader-font-size)
  function polyfillFontSize(style) {
    // ★ 2026-09-02 样式破坏修复：撤销 px 字号替换
    // 原书 font-size:Npx 是作者明确意图（多看按原书 px 渲染），
    // 替换成用户字号会破坏 px 声明章节的排版。
    // em/rem/百分比链在 html 基准修复后已回到作者意图，无需 polyfill。
  }

  // line-height px 值 → calc(Npx * 1em)（随字号缩放）
  function polyfillLineHeight(style) {
    var val = style.getPropertyValue('line-height');
    if (!val || val.indexOf('calc') !== -1 || val.indexOf('var(') !== -1) return;
    var match = val.trim().toLowerCase().match(/^(\d+(?:\.\d+)?)(px|pt)$/);
    if (match) {
      var num = match[1];
      var unit = match[2];
      // px/pt 固定行距 → 转为 em 相对值，随字号缩放
      style.setProperty('line-height', 'calc(' + num + unit + ' * 1em)',
        style.getPropertyPriority('line-height'));
    }
    // 无单位数字（如 1.5）保留（相对值，作者意图）
  }

  // break-before/after → -webkit-column-break-before/after
  function polyfillBreakRules(style) {
    var wk = style;
    // break-before
    var breakBefore = style.getPropertyValue('break-before');
    if (breakBefore) {
      wk.webkitColumnBreakBefore = convertToColumnBreak(breakBefore);
    } else {
      var pageBreakBefore = style.getPropertyValue('page-break-before');
      if (pageBreakBefore) {
        wk.webkitColumnBreakBefore = convertToColumnBreak(pageBreakBefore);
      }
    }
    // break-after
    var breakAfter = style.getPropertyValue('break-after');
    if (breakAfter && breakAfter !== 'auto') {
      wk.webkitColumnBreakAfter = convertToColumnBreak(breakAfter);
    } else {
      var pageBreakAfter = style.getPropertyValue('page-break-after');
      if (pageBreakAfter && pageBreakAfter !== 'auto') {
        wk.webkitColumnBreakAfter = convertToColumnBreak(pageBreakAfter);
      }
    }
  }

  // break-* 值 → webkit-column-break 值
  function convertToColumnBreak(value) {
    var v = value.trim().toLowerCase();
    switch (v) {
      case 'page':
      case 'right':
      case 'left':
        return 'always';
      case 'avoid':
        return 'avoid';
      case 'auto':
      default:
        return 'auto';
    }
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

  // CSS 变量热更新：Dart 侧样式变化时调用，无需 reload WebView
  // 接收一个对象，key 为 CSS 变量名（如 '--reader-font-size'），value 为变量值
  // 同时处理菜单颜色（基于 backgroundColor 亮度自动计算）
  function updateStyle(vars) {
    var root = document.documentElement;
    for (var key in vars) {
      if (key.charAt(0) === '-' && key.charAt(1) === '-') {
        root.style.setProperty(key, vars[key]);
      }
    }
    // ★ 2026-09-02 用户字号内联注入（学 epub.js Themes.override）：
    // EPUB 模式 html 不再锁 font-size 基准（原书 97% 链回到作者意图），
    // 用户字号改走 body 内联 style：仅当原书 body 无 font-size 声明时生效。
    // 检测方式：临时清 body 内联 → 读 computed 是否等于 UA 默认 16px。
    // 原书有声明（如 97%）时不注入，用户字号仅影响无声明章节（EPUB 模式下
    // 正文章无 body font-size 时仍可用），保证作者意图优先。
    var fs = vars['--reader-font-size'];
    if (fs && document.body && document.body.dataset.epub === '1') {
      // EPUB 模式：根基准 11px 对齐多看，用户字号按 15 默认值倍率缩放
      // 仅当原书 body 无 font-size 声明时生效（有声明 = 作者定死字号链）
      if (!document.body.dataset.authorFontSize) {
        var inlineFs = document.body.style.fontSize;
        document.body.style.fontSize = '';
        var computed = parseFloat(getComputedStyle(document.body).fontSize);
        if (Math.abs(computed - 16) < 0.51) {
          document.body.dataset.authorFontSize = '0';
        } else {
          document.body.dataset.authorFontSize = '1';
          if (inlineFs) document.body.style.fontSize = inlineFs;
        }
      }
      if (document.body.dataset.authorFontSize === '0') {
        document.documentElement.style.fontSize =
          (11 * parseFloat(fs) / 15.0).toFixed(2) + 'px';
      }
    } else if (fs && document.body && !document.body.dataset.authorFontSize) {
      var inlineFs = document.body.style.fontSize;
      document.body.style.fontSize = '';
      var computed = parseFloat(getComputedStyle(document.body).fontSize);
      if (Math.abs(computed - 16) < 0.51) {
        // 原书无声明（UA 默认 16px）→ 用户字号内联生效
        document.body.style.fontSize = fs;
        document.body.dataset.authorFontSize = '0';
      } else {
        // 原书有声明 → 尊重作者，不再改
        document.body.dataset.authorFontSize = '1';
        if (inlineFs) document.body.style.fontSize = inlineFs;
      }
    }
    // 菜单颜色随背景色亮度自动适配
    var bgColor = vars['--reader-bg-color'];
    if (bgColor) {
      var hex = bgColor.replace('#', '');
      if (hex.length === 6) {
        var r = parseInt(hex.substr(0,2), 16);
        var g = parseInt(hex.substr(2,2), 16);
        var b = parseInt(hex.substr(4,2), 16);
        var luminance = (0.299*r + 0.587*g + 0.114*b) / 255;
        var isDark = luminance < 0.5;
        root.style.setProperty('--reader-menu-bg', isDark ? 'rgba(38,38,38,0.78)' : 'rgba(255,255,255,0.82)');
        root.style.setProperty('--reader-menu-text', isDark ? '#FAFAFA' : '#1A1A1A');
        root.style.setProperty('--reader-menu-divider', isDark ? 'rgba(255,255,255,0.16)' : 'rgba(0,0,0,0.10)');
        root.style.setProperty('--reader-menu-shadow', isDark ? '0 6px 24px rgba(0,0,0,0.45), 0 2px 6px rgba(0,0,0,0.28)' : '0 6px 24px rgba(0,0,0,0.18), 0 2px 6px rgba(0,0,0,0.10)');
      }
    }
  }

  return {
    init: init,
    updateStyle: updateStyle,
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
    removeHighlightById: removeHighlightById,
    setLastHighlightId: setLastHighlightId,
    searchText: searchText,
    scrollToSearchResult: scrollToSearchResult
  };
})();
''';
  }
}
