import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../services/local_book/epub_parser.dart';

/// EPUB 多看画廊页面渲染器（WebView 渲染模式）
///
/// 用于渲染含 `.duokan-image-gallery` 的章节。这类章节原本是多看阅读器的
/// 横向滑动画廊，标准 EPUB 阅读器无法用 column 分页正确处理。
///
/// 渲染方案：InAppWebView 加载生成的 HTML，HTML 内联原作者原始 CSS
/// （`chapterStyle.rawCss`），让浏览器原生渲染所有 CSS 属性，实现 1:1
/// 对齐多看阅读器排版（多看本身就是 HTML snippet + WebView 渲染）。
///
/// 设计要点：
/// - InAppWebView 加载 HTML（含 rawCss + scroll-snap 覆盖 CSS）
/// - 横向 scroll-snap 滑动翻页，每页一张图
/// - 点击图片弹出全屏预览（InteractiveViewer 支持双指缩放）
/// - 滑到第一张继续往前 → onPreviousChapter 回调
/// - 滑到最后张继续往后 → onNextChapter 回调
/// - 图片 src 支持本地绝对路径（转 file://）和 data: URI
/// - 翻页指示器（点点点）由 HTML+CSS+JS 渲染，跟随 textColor 变色
class EpubGalleryPage extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final String chapterTitle;
  final Color backgroundColor;
  final Color textColor;

  /// 阅读器基础字号（px），作为 EPUB CSS em 值的基准
  /// 原作者 CSS 用 em 单位（如 font-size: 1.5em），em 相对根字号，
  /// 这里传入阅读器的 provider.fontSize 设为 html { font-size }，
  /// 让 em 计算与阅读器一致
  final double baseFontSize;

  /// 画廊章节级样式（含 rawCss 原始 CSS 全文、背景图、gallery-title 等）
  /// 从 EPUB CSS 提取，null 时用兜底样式（白底 + 无标题）
  final EpubGalleryChapterStyle? chapterStyle;

  /// 是否从章节末尾进入（用于从下一章往前翻到本章最后一张）
  final bool initialPageToEnd;

  /// 滑到第一张继续往前时触发（由 NovelReaderPage 切换到上一章）
  final VoidCallback onPreviousChapter;

  /// 滑到最后一张继续往后时触发（由 NovelReaderPage 切换到下一章）
  final VoidCallback onNextChapter;

  const EpubGalleryPage({
    super.key,
    required this.images,
    required this.chapterTitle,
    required this.backgroundColor,
    required this.textColor,
    this.baseFontSize = 18.0,
    this.chapterStyle,
    this.initialPageToEnd = false,
    required this.onPreviousChapter,
    required this.onNextChapter,
  });

  @override
  State<EpubGalleryPage> createState() => _EpubGalleryPageState();
}

class _EpubGalleryPageState extends State<EpubGalleryPage> {
  late final String _html;
  late final WebUri _baseUrl;
  bool _isNavigating = false; // 防止章节切换重复触发

  @override
  void initState() {
    super.initState();
    _html = _buildGalleryHtml();
    _baseUrl = _computeBaseUrl() ?? WebUri('about:blank');
  }

  /// 生成完整 HTML 文档
  ///
  /// 结构 1:1 对齐原作者 gallery.xhtml + 多看阅读器渲染模板：
  /// ```
  /// <body class="video-bg">
  ///   <h3 class="gallery-title">画廊图</h3>
  ///   <div class="duokan-image-gallery gallery-pic">...cells...</div>
  ///   <p class="gallery-txt">滑动切换，点击放大</p>
  ///   <div class="dotted">...点点点...</div>  ← body 最后一个 flex item
  /// </body>
  /// ```
  ///
  /// CSS 分四层（仅覆盖布局，保留原作视觉样式）：
  /// 1. html { font-size } — 阅读器基准字号，让 rawCss 的 em 跟随阅读器
  /// 2. rawCss — 原作者原始 CSS（原样内联，浏览器原生渲染所有视觉属性：
  ///    color/font-family/font-size/margin/border/box-shadow/text-shadow 等）
  /// 3. 布局覆盖 — scroll-snap 横向滑动 + flex 布局
  ///    （仅用 !important 覆盖影响横向滑动布局的 display/overflow/flex/margin，
  ///    保留原作的 border/box-shadow/color/font 等视觉样式）
  /// 4. 点点点指示器 — body 最后一个 flex item（和排版在一起，非 fixed 浮动）
  String _buildGalleryHtml() {
    final cs = widget.chapterStyle;
    final rawCss = cs?.rawCss ?? '';

    // 背景色：优先用 chapterStyle.backgroundColor，否则用阅读器背景色
    final bgColor = cs?.backgroundColor != null
        ? _argbIntToCss(cs!.backgroundColor!)
        : _colorToCss(widget.backgroundColor);

    // 默认文字色（element 级，被 rawCss 的 class 规则覆盖）
    final textColor = _colorToCss(widget.textColor);

    // 点点点颜色：跟随 textColor（深色背景→浅色点，浅色背景→深色点）
    // 用 rgba(r,g,b,alpha) 形式：未激活 30% 透明，激活 90% 透明
    final textRgb = _colorToRgb(widget.textColor);
    final dotInactiveColor = 'rgba($textRgb, 0.3)';
    final dotActiveColor = 'rgba($textRgb, 0.9)';

    // 背景图尺寸/位置/重复（从 chapterStyle 提取值，!important 覆盖 rawCss）
    final bgSize = cs?.backgroundSize ?? 'cover';
    final bgPosition = cs?.backgroundPosition ?? 'center center';
    final bgRepeat = cs?.backgroundRepeat ?? 'no-repeat';

    // body 内联背景图（最高优先级，覆盖 rawCss 的 url() 相对路径）
    String bodyBgStyle = '';
    final bgSrc = cs?.backgroundImageSrc;
    if (bgSrc != null && bgSrc.isNotEmpty) {
      final url = _srcToWebViewUrl(bgSrc);
      bodyBgStyle = 'background-image: url("$url");';
    }

    // 画廊标题 HTML
    final galleryTitleHtml =
        (cs?.galleryTitle != null && cs!.galleryTitle!.isNotEmpty)
            ? '<h3 class="gallery-title">${_escapeHtml(cs.galleryTitle!)}</h3>'
            : '';

    // 画廊 cells HTML（每个 cell：图片 + maintitle + subtitle）
    final cellsHtml = widget.images.map((img) {
      final src = _srcToWebViewUrl(img.src);
      final maintitleHtml = img.maintitle.isNotEmpty
          ? '<p class="duokan-image-maintitle">${_escapeHtml(img.maintitle)}</p>'
          : '';
      final subtitleHtml = img.subtitle.isNotEmpty
          ? '<p class="duokan-image-subtitle">${_escapeHtml(img.subtitle)}</p>'
          : '';
      return '''
      <div class="duokan-image-gallery-cell">
        <img alt="" src="$src"/>
        $maintitleHtml
        $subtitleHtml
      </div>''';
    }).join('\n');

    // 底部提示 HTML
    final galleryTxtHtml =
        (cs?.galleryTxt != null && cs!.galleryTxt!.isNotEmpty)
            ? '<p class="gallery-txt">${_escapeHtml(cs.galleryTxt!)}</p>'
            : '';

    // 点点点 HTML（N 张图 N 个 span，initialPageToEnd 时初始 active 是最后一个）
    final initialActiveIndex =
        widget.initialPageToEnd ? widget.images.length - 1 : 0;
    final dotsHtml = widget.images.isEmpty
        ? ''
        : List.generate(widget.images.length, (i) {
            return i == initialActiveIndex
                ? '<span class="active"></span>'
                : '<span></span>';
          }).join('');

    // initialPageToEnd 的 JS 布尔字面量
    final initialPageToEndJs = widget.initialPageToEnd ? 'true' : 'false';

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">
<meta name="format-detection" content="telephone=no, email=no, address=no">
<style>
/* === 1. 阅读器基准字号（让 rawCss 的 em 单位跟随阅读器字号）=== */
html {
  font-size: ${widget.baseFontSize}px;
}

/* === 2. 原作者原始 CSS（原样内联，浏览器原生渲染所有视觉属性）=== */
/* 保留原作的 color/font-family/font-size/margin/border/box-shadow/
   text-shadow/text-align/line-height/text-indent 等全部视觉样式 */
$rawCss

/* === 3. 布局覆盖（仅覆盖影响横向滑动布局的属性，保留视觉样式）=== */
html, body {
  margin: 0 !important;
  padding: 0 !important;  /* 覆盖原作 body { padding: 0.5em } */
  height: 100vh !important;
  width: 100vw !important;
  overflow: hidden !important;
  -webkit-user-select: none;
  user-select: none;
  -webkit-touch-callout: none;
}
body {
  display: flex !important;
  flex-direction: column !important;
  box-sizing: border-box !important;
  color: $textColor;
  /* 背景属性：chapterStyle 提取值兜底，!important 确保覆盖 rawCss 中的
     .video-bg（因 rawCss 的 url() 是相对路径，需 bodyBgStyle 内联纠正）*/
  background-color: $bgColor !important;
  background-size: $bgSize !important;
  background-position: $bgPosition !important;
  background-repeat: $bgRepeat !important;
}
/* gallery-title: 保留原作 margin: 2em auto, 仅加 flex 标记 */
.gallery-title {
  flex: 0 0 auto !important;
}
/* duokan-image-gallery: 横向滑动容器
   覆盖原作 margin: 8em 0 0.5em 0（8em 顶部 margin 在 flex 布局中会
   占用大量空间，让 gallery 被挤压；横向滑动模式下不需要这个间距）*/
.duokan-image-gallery {
  flex: 1 1 auto !important;
  min-height: 0 !important;
  display: flex !important;
  overflow-x: auto !important;
  overflow-y: hidden !important;
  scroll-snap-type: x mandatory !important;
  -webkit-overflow-scrolling: touch;
  margin: 0 !important;
}
/* cell: 横向滑动项
   保留原作 border-style: solid; border-width: 1px; box-shadow: 5px 5px 5px #888
   覆盖原作 margin: 10px 0（cell 在 flex 布局中是 100% 高度，
   margin 会导致超出容器）*/
.duokan-image-gallery-cell {
  scroll-snap-align: center !important;
  flex: 0 0 100% !important;
  width: 100% !important;
  height: 100% !important;
  display: flex !important;
  flex-direction: column !important;
  align-items: center !important;
  justify-content: center !important;
  box-sizing: border-box !important;
  margin: 0 !important;
}
/* img: 覆盖原作 .gallery-pic img { width: 100% }
   横向滑动模式下图片应按比例缩放到适合 cell 的尺寸，而非占满宽度 */
.duokan-image-gallery-cell img {
  max-width: 90% !important;
  max-height: 70vh !important;
  width: auto !important;
  height: auto !important;
  object-fit: contain !important;
}
/* 隐藏滚动条 */
.duokan-image-gallery::-webkit-scrollbar { display: none; }
.duokan-image-gallery { -ms-overflow-style: none; scrollbar-width: none; }
/* gallery-txt: 保留原作 margin: 1em auto, 仅加 flex 标记 */
.gallery-txt {
  flex: 0 0 auto !important;
}

/* === 4. 点点点指示器（body 最后一个 flex item, 和排版在一起）=== */
/* 对齐多看阅读器渲染：dotted 在 slide_group 内部，和排版流一起
   （非 position:fixed 浮动），作为 body 最后一个 flex item */
.dotted {
  flex: 0 0 auto !important;
  display: flex !important;
  justify-content: center !important;
  align-items: center !important;
  padding: 8px 0 !important;
  padding-bottom: calc(8px + env(safe-area-inset-bottom)) !important;
}
.dotted span {
  display: inline-block;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  margin: 0 3px;
  background-color: $dotInactiveColor;
  box-shadow: 0 1px 1px rgba(255,255,255,0.5);
}
.dotted span.active {
  background-color: $dotActiveColor;
}
</style>
</head>
<body class="video-bg" style="$bodyBgStyle">
  $galleryTitleHtml
  <div class="duokan-image-gallery gallery-pic">
    $cellsHtml
  </div>
  $galleryTxtHtml
  <div class="dotted" id="dotted">
    $dotsHtml
  </div>
  <script>
    (function() {
      var gallery = document.querySelector('.duokan-image-gallery');
      var dotted = document.getElementById('dotted');
      if (!gallery || !dotted) return;

      function callHandler(name, arg) {
        try {
          if (window.flutter_inappwebview) {
            window.flutter_inappwebview.callHandler(name, arg);
          }
        } catch(e) {}
      }

      // 更新点点点指示器的 active 状态
      // idx = 当前页索引（scrollLeft / cellWidth 四舍五入）
      function updateDotted() {
        var idx = Math.round(gallery.scrollLeft / gallery.clientWidth);
        var dots = dotted.querySelectorAll('span');
        for (var i = 0; i < dots.length; i++) {
          dots[i].classList.toggle('active', i === idx);
        }
      }

      // 滚动监听（rAF 节流，避免高频 scroll 事件刷屏）
      var rafId = 0;
      gallery.addEventListener('scroll', function() {
        if (rafId) return;
        rafId = requestAnimationFrame(function() {
          rafId = 0;
          updateDotted();
        });
      }, {passive: true});

      // 图片点击 → 全屏预览
      var imgs = gallery.querySelectorAll('.duokan-image-gallery-cell img');
      for (var i = 0; i < imgs.length; i++) {
        (function(index) {
          imgs[index].addEventListener('click', function(e) {
            e.preventDefault();
            callHandler('onGalleryImageTap', index);
          });
        })(i);
      }

      // 边界章节切换（touchstart/touchend 检测边界拖动意图）
      // 在最左边界继续向右滑 → 上一章；最右边界继续向左滑 → 下一章
      var touchStartX = 0;
      var touchStartY = 0;
      document.addEventListener('touchstart', function(e) {
        if (e.touches.length > 0) {
          touchStartX = e.touches[0].clientX;
          touchStartY = e.touches[0].clientY;
        }
      }, {passive: true});
      document.addEventListener('touchend', function(e) {
        var maxScroll = gallery.scrollWidth - gallery.clientWidth;
        var dx = 0, dy = 0;
        if (e.changedTouches.length > 0) {
          dx = e.changedTouches[0].clientX - touchStartX;
          dy = e.changedTouches[0].clientY - touchStartY;
        }
        // 仅水平方向拖动触发（避免纵向滚动误触）
        if (Math.abs(dx) <= Math.abs(dy)) return;
        // 位移阈值 50px（避免点击/小幅拖动误触）
        if (Math.abs(dx) < 50) return;
        // 最左边界 + 向右滑 → 上一章
        if (gallery.scrollLeft <= 0 && dx > 0) {
          callHandler('onGalleryPreviousChapter', null);
          return;
        }
        // 最右边界 + 向左滑 → 下一章
        if (gallery.scrollLeft >= maxScroll - 1 && dx < 0) {
          callHandler('onGalleryNextChapter', null);
          return;
        }
      }, {passive: true});

      // 加载完成后初始化：initialPageToEnd 时滚动到最后一张，并更新点点点
      window.addEventListener('load', function() {
        if ($initialPageToEndJs) {
          gallery.scrollLeft = gallery.scrollWidth - gallery.clientWidth;
        }
        updateDotted();
      });
    })();
  </script>
</body>
</html>
''';
  }

  /// 计算 WebView 加载用的 baseUrl
  ///
  /// 以 `chapterStyle.backgroundImageSrc` 的父目录为 baseUrl，让 rawCss 中
  /// 的相对 url()（如 `url(../Images/x.jpg)`）按此目录解析。EPUB 常见结构中
  /// CSS 和图片是同级目录（OEBPS/CSS/、OEBPS/Images/），`../X/Y` 相对任一
  /// 同级目录解析结果一致，故用图片父目录作为 baseUrl 可正确解析。
  ///
  /// 无背景图或 data: URI 背景时返回 null（用 about:blank 兜底）。
  WebUri? _computeBaseUrl() {
    final bgSrc = widget.chapterStyle?.backgroundImageSrc;
    if (bgSrc == null || bgSrc.isEmpty) return null;
    if (bgSrc.startsWith('data:')) return null;
    final normalized = bgSrc.replaceAll('\\', '/');
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash < 0) return null;
    final dir = normalized.substring(0, lastSlash + 1);
    if (dir.startsWith('/')) {
      return WebUri('file://$dir');
    }
    if (RegExp(r'^[A-Za-z]:/').hasMatch(dir)) {
      return WebUri('file:///$dir');
    }
    return null;
  }

  /// 将图片 src 转为 WebView 可访问的 URL
  ///
  /// - `data: URI` → 直接用
  /// - `file://` 开头 → 直接用
  /// - Unix 绝对路径（`/...`）→ `file://...`
  /// - Windows 绝对路径（`D:/...`）→ `file:///D:/...`
  /// - 其他 → 原样返回（相对路径，靠 baseUrl 解析）
  String _srcToWebViewUrl(String src) {
    if (src.startsWith('data:')) return src;
    if (src.startsWith('file://')) return src;
    final normalized = src.replaceAll('\\', '/');
    if (normalized.startsWith('/')) {
      return 'file://$normalized';
    }
    if (RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
      return 'file:///$normalized';
    }
    return src;
  }

  /// 将 Color 转为 CSS 十六进制色值（#rrggbb）
  String _colorToCss(Color c) {
    final argb = c.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  /// 将 ARGB int 色值转为 CSS 十六进制色值（#rrggbb）
  String _argbIntToCss(int argb) {
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  /// 将 Color 转为 CSS rgb 分量字符串（"r, g, b"，用于 rgba() 函数）
  ///
  /// 点点点指示器颜色用 rgba(r,g,b,alpha) 形式，未激活 30% 透明，激活 90%。
  /// 跟随 textColor：深色背景→浅色点，浅色背景→深色点。
  String _colorToRgb(Color c) {
    final argb = c.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '$r, $g, $b';
  }

  /// HTML 转义（标题/副标题文本，防止 < > & " ' 破坏 HTML 结构）
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// 解析背景色：优先用 chapterStyle.backgroundColor，否则用阅读器 backgroundColor
  Color _resolveBgColor() {
    final bgClr = widget.chapterStyle?.backgroundColor;
    if (bgClr != null) return Color(bgClr);
    return widget.backgroundColor;
  }

  /// 注册 JS handler（JS → Dart 回调）
  ///
  /// 点点点指示器的 active 状态由 JS 内部更新（updateDotted 函数），
  /// 不需要回调 Flutter，因此不注册 onGalleryPageChanged handler。
  void _setupJsHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onGalleryImageTap',
      callback: (args) {
        if (args.isNotEmpty && args[0] is num) {
          final idx = (args[0] as num).toInt();
          if (idx >= 0 && idx < widget.images.length && mounted) {
            _showFullScreenPreview(idx);
          }
        }
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onGalleryPreviousChapter',
      callback: (args) {
        if (_isNavigating) return;
        _isNavigating = true;
        widget.onPreviousChapter();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onGalleryNextChapter',
      callback: (args) {
        if (_isNavigating) return;
        _isNavigating = true;
        widget.onNextChapter();
      },
    );
  }

  /// 点击图片弹出全屏预览
  ///
  /// 进入动画：ScaleTransition(0.92→1.0) + FadeTransition，
  /// 全屏预览支持横向滑动切换、双指缩放、双击切换缩放、Hero 动画。
  void _showFullScreenPreview(int initialIndex) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (context, animation, secondaryAnimation) {
          return _GalleryFullScreenViewer(
            images: widget.images,
            initialIndex: initialIndex,
            baseFontSize: widget.baseFontSize,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final scaleAnimation = Tween<double>(
            begin: 0.92,
            end: 1.0,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ));
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: scaleAnimation,
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return Container(
        color: _resolveBgColor(),
        alignment: Alignment.center,
        child: Text('画廊无图片', style: TextStyle(color: widget.textColor)),
      );
    }

    return Stack(
      children: [
        // 背景兜底（WebView CSS 加载前可见，避免白屏闪烁）
        Positioned.fill(child: ColoredBox(color: _resolveBgColor())),
        // WebView 主体：InAppWebView 加载生成的 HTML
        // 点点点指示器、画廊内容、边界切章全部由 HTML+CSS+JS 渲染处理
        Positioned.fill(
          child: InAppWebView(
            initialData: InAppWebViewInitialData(
              data: _html,
              mimeType: 'text/html',
              encoding: 'utf-8',
              baseUrl: _baseUrl,
            ),
            initialSettings: InAppWebViewSettings(
              transparentBackground: true,
              // 必须为 false：Hybrid Composition 模式下 WebView 由 Android
              // 原生绘制到独立 Surface，Flutter 截图会空白
              useHybridComposition: false,
              supportZoom: false,
              builtInZoomControls: false,
              displayZoomControls: false,
              javaScriptEnabled: true,
              allowFileAccessFromFileURLs: true,
              allowUniversalAccessFromFileURLs: true,
              // 画廊只横向滑动：禁用 body 纵向滚动，允许横向滚动
              disableVerticalScroll: true,
              disableHorizontalScroll: false,
              verticalScrollBarEnabled: false,
              horizontalScrollBarEnabled: false,
              overScrollMode: OverScrollMode.NEVER,
            ),
            onWebViewCreated: (controller) {
              _setupJsHandlers(controller);
            },
          ),
        ),
      ],
    );
  }
}

/// 全屏预览查看器
///
/// 支持多图横向滑动切换 + 双指缩放 + 拖动查看细节。
///
/// 交互设计：
/// - PageView 横向滑动切换图片（scale == 1.0 时启用）
///   - BouncingScrollPhysics：iOS 风格弹性滑动，更顺滑
///   - 预加载相邻图片：initState 中 precacheImage 前后图片
///   - KeepAlive：子页面保持状态，避免重建和重新解码
/// - InteractiveViewer 双指缩放（1-4x）+ 拖动查看细节（scale > 1.0 时）
/// - 双击切换缩放（1.0 ↔ 2.5x），缩放后双击复位
/// - 右下角信息面板（AnimatedSwitcher 淡入淡出 + 上滑动画）
/// - 顶部页码指示器 + 关闭按钮
class _GalleryFullScreenViewer extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final int initialIndex;

  /// 阅读器基础字号（px），作为 EPUB CSS em 值的基准
  final double baseFontSize;

  const _GalleryFullScreenViewer({
    required this.images,
    required this.initialIndex,
    this.baseFontSize = 18.0,
  });

  @override
  State<_GalleryFullScreenViewer> createState() =>
      _GalleryFullScreenViewerState();
}

class _GalleryFullScreenViewerState extends State<_GalleryFullScreenViewer> {
  late PageController _pageController;
  late TransformationController _transformCtrl;
  int _currentIndex = 0;
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _transformCtrl = TransformationController();
    // 预加载相邻图片，避免滑动时白屏等待
    _precacheAdjacentImages(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  /// 预加载相邻图片（前一张和后一张）
  ///
  /// 在切换页面前预先解码图片，滑动时直接显示已缓存的图片，
  /// 避免白屏等待。
  void _precacheAdjacentImages(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = this.context;
      // 前一张
      if (index > 0) {
        final provider = _getImageProvider(widget.images[index - 1]);
        if (provider != null) {
          precacheImage(provider, context);
        }
      }
      // 后一张
      if (index < widget.images.length - 1) {
        final provider = _getImageProvider(widget.images[index + 1]);
        if (provider != null) {
          precacheImage(provider, context);
        }
      }
    });
  }

  /// 根据图片 src 获取 ImageProvider（用于 precacheImage）
  ImageProvider? _getImageProvider(EpubGalleryImage image) {
    final src = image.src;
    if (src.startsWith('data:')) {
      final bytes = _decodeDataUri(src);
      if (bytes != null) return MemoryImage(bytes);
      return null;
    }
    final filePath = src.startsWith('file://') ? src.substring(7) : src;
    if (filePath.contains('/') || filePath.contains('\\')) {
      return FileImage(File(filePath));
    }
    return NetworkImage(src);
  }

  /// 重置缩放到 1.0
  void _resetZoom() {
    _transformCtrl.value = Matrix4.identity();
    if (_currentScale != 1.0) {
      setState(() => _currentScale = 1.0);
    }
  }

  /// 双击切换缩放
  void _onDoubleTap() {
    if (_currentScale > 1.05) {
      _resetZoom();
    } else {
      _transformCtrl.value = Matrix4.diagonal3Values(2.5, 2.5, 1.0);
      setState(() => _currentScale = 2.5);
    }
  }

  void _onPageChanged(int index) {
    // 切换页时重置缩放，避免上一页的缩放状态影响下一页
    _resetZoom();
    setState(() => _currentIndex = index);
    // 预加载新的相邻图片
    _precacheAdjacentImages(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 主体：PageView 横向滑动 + InteractiveViewer 缩放
          PageView.builder(
            controller: _pageController,
            itemCount: widget.images.length,
            onPageChanged: _onPageChanged,
            // scale > 1.0 时禁用 PageView 滑动，让 InteractiveViewer 处理拖动
            // scale == 1.0 时启用 PageView 滑动切换图片
            physics: _currentScale > 1.05
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemBuilder: (context, index) {
              return _buildZoomableImage(widget.images[index], index);
            },
          ),
          // 顶部：页码指示器 + 关闭按钮
          _buildTopBar(),
          // 右下角：主标题 + 副标题信息面板（从下到上滑出动画）
          _buildInfoPanel(),
        ],
      ),
    );
  }

  /// 构建可缩放的单张图片（全屏预览）
  ///
  /// 全屏预览只显示图片，标题/副标题由右下角自定义信息面板展示。
  /// - AutomaticKeepAliveClientMixin：保持页面状态，避免滑出视图后被销毁
  /// - GestureDetector 检测双击缩放
  /// - InteractiveViewer 处理双指缩放和拖动
  Widget _buildZoomableImage(EpubGalleryImage image, int index) {
    return _KeepAliveImage(
      child: GestureDetector(
        onDoubleTap: _onDoubleTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: InteractiveViewer(
            transformationController: _transformCtrl,
            minScale: 1.0,
            maxScale: 4.0,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            onInteractionEnd: (_) {
              final scale = _transformCtrl.value.getMaxScaleOnAxis();
              if ((scale - _currentScale).abs() > 0.01) {
                setState(() => _currentScale = scale);
              }
            },
            child: _buildImage(image),
          ),
        ),
      ),
    );
  }

  /// 右下角信息面板：主标题 + 副标题，从下到上滑出动画
  ///
  /// 自定义样式（非原作者格式），全屏预览专用：
  /// - 白色文字（确保在黑底图片上可见）
  /// - 主标题：18px FontWeight.w600
  /// - 副标题：13px FontWeight.w400 半透明
  /// - 切换图片时面板重新从下方滑出（SlideTransition + FadeTransition）
  Widget _buildInfoPanel() {
    final image = widget.images[_currentIndex];
    final hasTitle =
        image.maintitle.isNotEmpty || image.subtitle.isNotEmpty;
    if (!hasTitle) return const SizedBox.shrink();

    return Positioned(
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final offset = Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ));
            return SlideTransition(
              position: offset,
              child: FadeTransition(
                opacity: animation,
                child: child,
              ),
            );
          },
          child: Container(
            key: ValueKey(_currentIndex),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (image.maintitle.isNotEmpty)
                  Text(
                    image.maintitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                if (image.subtitle.isNotEmpty) ...[
                  if (image.maintitle.isNotEmpty) const SizedBox(height: 4),
                  Text(
                    image.subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部栏：页码指示器（左）+ 关闭按钮（右）
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              // 页码指示器
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    '${_currentIndex + 1} / ${widget.images.length}',
                    key: ValueKey(_currentIndex),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // 关闭按钮
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 根据图片 src 类型选择渲染方式
  Widget _buildImage(EpubGalleryImage image) {
    final src = image.src;
    if (src.startsWith('data:')) {
      final bytes = _decodeDataUri(src);
      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
      }
      return const Icon(Icons.broken_image, color: Colors.white54, size: 64);
    }
    final filePath = src.startsWith('file://') ? src.substring(7) : src;
    if (filePath.contains('/') || filePath.contains('\\')) {
      return Image.file(
        File(filePath),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image, color: Colors.white54, size: 64),
      );
    }
    return Image.network(
      src,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          const Icon(Icons.broken_image, color: Colors.white54, size: 64),
    );
  }

  Uint8List? _decodeDataUri(String dataUri) {
    try {
      final commaIdx = dataUri.indexOf(',');
      if (commaIdx < 0) return null;
      return base64Decode(dataUri.substring(commaIdx + 1));
    } catch (_) {
      return null;
    }
  }
}

/// 保持 PageView 子页面状态的包装组件
///
/// AutomaticKeepAliveClientMixin 让 PageView 子页面在滑出视图后不被销毁，
/// 避免重新构建和重新解码图片。这对大图画廊尤为重要，能显著提升滑动流畅度。
class _KeepAliveImage extends StatefulWidget {
  final Widget child;

  const _KeepAliveImage({required this.child});

  @override
  State<_KeepAliveImage> createState() => _KeepAliveImageState();
}

class _KeepAliveImageState extends State<_KeepAliveImage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
