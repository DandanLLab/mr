import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../services/local_book/epub_parser.dart';

/// EPUB 多看画廊页面渲染器
///
/// ★ 基于多看阅读器反汇编全面移植 ★
///
/// 多看画廊渲染分两层（反汇编证据见 .tmp/gallery_full_disasm_report.md）：
/// 1. native 层（libddlayoutkit.so）：CBookRender::RenderGallery 把原作竖向
///    gallery.xhtml 转成 HTML snippet（slider/slide_group/slide/msg 结构）
/// 2. UI 层（dex）：DocImagesView 横向滑动翻页；点击图片进入
///    DocImageWatchingView（ZoomView + MultiTouchImageView）全屏预览
///
/// 我们的移植方案：
/// - 非全屏画廊：InAppWebView 加载对齐多看 HTML snippet 的页面
///   （slider > slide_group(dotted + btn_l + btn_r) + slide(msg)）
/// - 全屏预览：Flutter 原生 PageView + InteractiveViewer
///   （对应多看 ZoomView + MultiTouchImageView 的双指/双击缩放）
class EpubGalleryPage extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final String chapterTitle;
  final Color backgroundColor;
  final Color textColor;

  /// 阅读器基础字号（px），作为 EPUB CSS em 值的基准
  final double baseFontSize;

  /// 画廊章节级样式（含 rawCss 原始 CSS 全文、背景图、gallery-title 等）
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
  late final WebUri? _baseUrl;
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();
    _html = _buildGalleryHtml();
    _baseUrl = _computeBaseUrl();
  }

  /// 生成非全屏画廊 HTML
  ///
  /// ★ 1:1 对齐多看 CGalleryHtmlSnippetOutputSystem 生成的 HTML snippet ★
  ///
  /// 反汇编 0x1d65c0-0x1d6dd8 证实多看生成的 HTML 结构：
  /// ```html
  /// <div class="slider" style="position: absolute; left:%dpx; top:%dpx;
  ///                            width:%dpx; height:%dpx;">
  ///   <div class="slide_group">
  ///     <div class="dotted" style="position: absolute; ...">
  ///       <span></span>  × N（N = 图片数量）
  ///     </div>
  ///     <div class="btn btn_l">left</div>
  ///     <div class="btn btn_r">right</div>
  ///   </div>
  ///   <div class="slide">
  ///     <div class="msg" style="position: absolute; ...">
  ///       <img/> + maintitle + subtitle
  ///     </div>
  ///     ...
  ///   </div>
  /// </div>
  /// ```
  ///
  /// 我们用 `position: relative` + `flex` 让 slider 占满可用空间，
  /// 多看用 `position: absolute` + 精确像素，效果一致。
  ///
  /// msg 内部保留原作的 `duokan-image-gallery-cell` / `gallery-pic` class，
  /// 让原作 CSS（border/box-shadow/img width）原样生效。
  String _buildGalleryHtml() {
    final cs = widget.chapterStyle;
    final rawCss = cs?.rawCss ?? '';

    // 背景色：优先用 chapterStyle.backgroundColor，否则用阅读器背景色
    final bgColor = cs?.backgroundColor != null
        ? _argbIntToCss(cs!.backgroundColor!)
        : _colorToCss(widget.backgroundColor);

    // 默认文字色（被 rawCss 的 class 规则覆盖）
    final textColor = _colorToCss(widget.textColor);

    // 点点点颜色：跟随 textColor
    final textRgb = _colorToRgb(widget.textColor);
    final dotInactiveColor = 'rgba($textRgb, 0.3)';
    final dotActiveColor = 'rgba($textRgb, 0.9)';

    // 背景图
    final bgSize = cs?.backgroundSize ?? 'cover';
    final bgPosition = cs?.backgroundPosition ?? 'center center';
    final bgRepeat = cs?.backgroundRepeat ?? 'no-repeat';
    String bodyBgStyle = '';
    final bgSrc = cs?.backgroundImageSrc;
    if (bgSrc != null && bgSrc.isNotEmpty) {
      final url = _srcToWebViewUrl(bgSrc);
      bodyBgStyle = 'background-image: url("$url");';
    }

    // 画廊标题
    final galleryTitleHtml = (cs?.galleryTitle != null &&
            cs!.galleryTitle!.isNotEmpty)
        ? '<h3 class="gallery-title">${_escapeHtml(cs.galleryTitle!)}</h3>'
        : '';

    // slide 内的 msg HTML（每张图片一个 msg）
    final msgsHtml = widget.images.asMap().entries.map((entry) {
      final i = entry.key;
      final img = entry.value;
      final src = _srcToWebViewUrl(img.src);
      final maintitleHtml = img.maintitle.isNotEmpty
          ? '<p class="duokan-image-maintitle">${_escapeHtml(img.maintitle)}</p>'
          : '';
      final subtitleHtml = img.subtitle.isNotEmpty
          ? '<p class="duokan-image-subtitle">${_escapeHtml(img.subtitle)}</p>'
          : '';
      return '''
      <div class="msg duokan-image-gallery-cell gallery-pic" data-index="$i">
        <img alt="" src="$src"/>
        $maintitleHtml
        $subtitleHtml
      </div>''';
    }).join('\n');

    // 底部提示
    final galleryTxtHtml = (cs?.galleryTxt != null && cs!.galleryTxt!.isNotEmpty)
        ? '<p class="gallery-txt">${_escapeHtml(cs.galleryTxt!)}</p>'
        : '';

    // 初始 index
    final initialIdx =
        widget.initialPageToEnd ? widget.images.length - 1 : 0;
    final initialPageToEndJs = widget.initialPageToEnd ? 'true' : 'false';

    // 点点点 HTML（N 张图 N 个 span，initialIdx 时初始 active）
    final dotsHtml = widget.images.isEmpty
        ? ''
        : List.generate(widget.images.length, (i) {
            return i == initialIdx
                ? '<span class="active"></span>'
                : '<span></span>';
          }).join('');

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
$rawCss

/* === 3. 布局覆盖（对齐多看 slider/slide_group/slide/msg 结构）===
   反汇编 CGalleryHtmlSnippetOutputSystem 证实多看生成的 HTML：
   - 所有元素 position: absolute + overflow: hidden
   - slider 是容器，slide_group 是覆盖层（dotted + btn），slide 是图片层
   - 我们用 relative + flex 让 slider 占满，内部用 absolute + scroll-snap */

html, body {
  margin: 0 !important;
  padding: 0 !important;
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
  background-color: $bgColor !important;
  background-size: $bgSize !important;
  background-position: $bgPosition !important;
  background-repeat: $bgRepeat !important;
}
.gallery-title {
  flex: 0 0 auto !important;
}
.gallery-txt {
  flex: 0 0 auto !important;
}

/* === slider 容器（对齐多看 <div class="slider">）===
   多看用 position:absolute + 精确像素，我们用 relative + flex 占满 */
.slider {
  flex: 1 1 auto !important;
  min-height: 0 !important;
  position: relative !important;
  overflow: hidden !important;
}

/* === slide_group 覆盖层（对齐多看 <div class="slide_group">）===
   放 dotted + btn，不拦截触摸 */
.slide_group {
  position: absolute !important;
  inset: 0 !important;
  pointer-events: none !important;
  z-index: 10 !important;
}

/* === dotted 指示器（对齐多看 <div class="dotted">）===
   反汇编 setGalleryScrollRect 证实：dotted 用 position:absolute 定位 */
.dotted {
  position: absolute !important;
  bottom: calc(12px + env(safe-area-inset-bottom)) !important;
  left: 0 !important;
  right: 0 !important;
  display: flex !important;
  justify-content: center !important;
  align-items: center !important;
  pointer-events: none !important;
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

/* === btn_l/btn_r（对齐多看 HTML 生成，但 CSS 隐藏）===
   反汇编 0x4d7499 证实多看确实生成这两个按钮的 HTML
   但截图里看不到，说明 CSS 隐藏了，我们也隐藏 */
.btn {
  display: none !important;
}

/* === slide 图片滑动层（对齐多看 <div class="slide">）=== */
.slide {
  position: absolute !important;
  inset: 0 !important;
  overflow-x: auto !important;
  overflow-y: hidden !important;
  scroll-snap-type: x mandatory !important;
  -webkit-overflow-scrolling: touch;
  display: flex !important;
}
.slide::-webkit-scrollbar { display: none; }
.slide { -ms-overflow-style: none; scrollbar-width: none; }

/* === msg 单张图片容器（对齐多看 <div class="msg">）===
   反汇编 endOutputGallery 证实 msg 用 position:absolute + 精确像素
   我们用 flex: 0 0 100% + scroll-snap 让每张图占满一屏
   ★ 保留原作 duokan-image-gallery-cell class（border/box-shadow 生效）
   ★ 保留原作 gallery-pic class（.gallery-pic img { width:100% } 生效）*/
.msg {
  scroll-snap-align: center !important;
  flex: 0 0 100% !important;
  width: 100% !important;
  height: 100% !important;
  display: flex !important;
  flex-direction: column !important;
  align-items: center !important;
  justify-content: center !important;
  box-sizing: border-box !important;
  /* 覆盖原作 margin: 10px 0（flex 子项不需要）*/
  margin: 0 !important;
  /* 保留原作 border-style: solid; border-width: 1px; box-shadow: 5px 5px 5px #888 */
  overflow: hidden !important;
  padding: 0 !important;
  position: relative !important;
}

/* === img（对齐多看 IsFullScreenImage 非全屏路径）===
   原作 .gallery-pic img { width: 100% } 让图片占满 cell 宽度
   多看全屏判定：0.601 < ratio < 0.799（反汇编 0x1d13bc）
   画廊图片通常不满足这个比例，走非全屏路径，保留原作装饰 */
.msg img {
  width: 100% !important;
  max-width: 100% !important;
  max-height: 100% !important;
  height: auto !important;
  object-fit: contain !important;
  flex: 1 1 auto !important;
  min-height: 0 !important;
}

/* === maintitle/subtitle（保留原作样式）===
   ★ 不覆盖 margin/font/color，让原作 CSS 生效 ★
   仅覆盖 flex 让标题固定在底部 */
.duokan-image-maintitle,
.duokan-image-subtitle {
  flex: 0 0 auto !important;
  max-width: 100% !important;
  overflow: hidden !important;
}
</style>
</head>
<body class="video-bg" style="$bodyBgStyle">
  $galleryTitleHtml
  <div class="slider">
    <div class="slide_group">
      <div class="dotted" id="dotted">
        $dotsHtml
      </div>
      <div class="btn btn_l">left</div>
      <div class="btn btn_r">right</div>
    </div>
    <div class="slide" id="slide">
      $msgsHtml
    </div>
  </div>
  $galleryTxtHtml
  <script>
    (function() {
      var slide = document.getElementById('slide');
      var dotted = document.getElementById('dotted');
      if (!slide) return;

      var total = slide.children.length;
      var isFullscreen = false;

      function callHandler(name, arg) {
        try {
          if (window.flutter_inappwebview) {
            window.flutter_inappwebview.callHandler(name, arg);
          }
        } catch(e) {}
      }

      function getCurrentIndex() {
        return Math.round(slide.scrollLeft / slide.clientWidth);
      }

      function updateDotted() {
        if (!dotted) return;
        var idx = getCurrentIndex();
        var dots = dotted.querySelectorAll('span');
        for (var i = 0; i < dots.length; i++) {
          dots[i].classList.toggle('active', i === idx);
        }
      }

      // 滚动监听（rAF 节流）
      var rafId = 0;
      slide.addEventListener('scroll', function() {
        if (rafId) return;
        rafId = requestAnimationFrame(function() {
          rafId = 0;
          updateDotted();
        });
      }, {passive: true});

      // 图片点击 → 全屏预览
      var msgs = slide.querySelectorAll('.msg');
      for (var i = 0; i < msgs.length; i++) {
        (function(index) {
          msgs[index].addEventListener('click', function(e) {
            e.preventDefault();
            callHandler('onGalleryImageTap', index);
          });
        })(i);
      }

      // 边界章节切换
      var touchStartX = 0;
      var touchStartY = 0;
      document.addEventListener('touchstart', function(e) {
        if (e.touches.length > 0) {
          touchStartX = e.touches[0].clientX;
          touchStartY = e.touches[0].clientY;
        }
      }, {passive: true});
      document.addEventListener('touchend', function(e) {
        var maxScroll = slide.scrollWidth - slide.clientWidth;
        var dx = 0, dy = 0;
        if (e.changedTouches.length > 0) {
          dx = e.changedTouches[0].clientX - touchStartX;
          dy = e.changedTouches[0].clientY - touchStartY;
        }
        if (Math.abs(dx) <= Math.abs(dy)) return;
        if (Math.abs(dx) < 50) return;
        if (slide.scrollLeft <= 0 && dx > 0) {
          callHandler('onGalleryPreviousChapter', null);
          return;
        }
        if (slide.scrollLeft >= maxScroll - 1 && dx < 0) {
          callHandler('onGalleryNextChapter', null);
          return;
        }
      }, {passive: true});

      // 初始化
      window.addEventListener('load', function() {
        if ($initialPageToEndJs) {
          slide.scrollLeft = slide.scrollWidth - slide.clientWidth;
        }
        updateDotted();
      });
    })();
  </script>
</body>
</html>
''';
  }

  /// 计算 WebView 加载用的 baseUrl（解析 rawCss 中的相对 url()）
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

  String _colorToCss(Color c) {
    final argb = c.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  String _argbIntToCss(int argb) {
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '#${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  String _colorToRgb(Color c) {
    final argb = c.toARGB32();
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return '$r, $g, $b';
  }

  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  Color _resolveBgColor() {
    final bgClr = widget.chapterStyle?.backgroundColor;
    if (bgClr != null) return Color(bgClr);
    return widget.backgroundColor;
  }

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
  /// ★ 对齐多看 DocImageWatchingView（ZoomView + MultiTouchImageView）★
  /// 反汇编 dex 报告证实多看全屏预览：
  /// - 不是独立 Activity，是阅读器内 View 切换
  /// - ZoomView（Matrix + 状态机 IDLE/PINCH/SMOOTH）支持双指缩放
  /// - MultiTouchImageView 支持双击缩放（setDoubleTap）
  /// - 横向滑动翻页（mWatchingAdapter 管理多张图片）
  /// - 下拉关闭（setPullingDown）
  ///
  /// 我们用 Flutter 原生实现：
  /// - PageView 横向滑动翻页（对应 mWatchingAdapter）
  /// - InteractiveViewer 双指缩放（对应 ZoomView）
  /// - GestureDetector 双击缩放（对应 MultiTouchImageView.setDoubleTap）
  /// - 黑色背景（对应 reading__large_image_view__image_bg）
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
            backgroundColor: Colors.black,
            textColor: widget.textColor,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
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
        Positioned.fill(child: ColoredBox(color: _resolveBgColor())),
        Positioned.fill(
          child: InAppWebView(
            initialData: InAppWebViewInitialData(
              data: _html,
              mimeType: 'text/html',
              encoding: 'utf-8',
              baseUrl: _baseUrl ?? WebUri('about:blank'),
            ),
            initialSettings: InAppWebViewSettings(
              transparentBackground: true,
              useHybridComposition: false,
              supportZoom: false,
              builtInZoomControls: false,
              displayZoomControls: false,
              javaScriptEnabled: true,
              allowFileAccessFromFileURLs: true,
              allowUniversalAccessFromFileURLs: true,
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

/// 全屏预览查看器（Flutter 原生实现）
///
/// ★ 对齐多看 DocImageWatchingView（ZoomView + MultiTouchImageView）★
///
/// 反汇编 dex 报告证实多看全屏预览的交互：
/// - ZoomView：Matrix 变换 + IDLE/PINCH/SMOOTH 状态机 + 双指缩放
/// - MultiTouchImageView：setDoubleTap 双击缩放 + setScale 手势
/// - PageAnimationMode：FADE_IN/HSCROLL/VSCROLL/OVERLAP/THREE_DIMEN/NONE
/// - setPullingDown：下拉关闭
/// - reading__large_image_view__image_bg：黑色背景
/// - reading__seek_page_view__page_num：页码指示器
///
/// Flutter 移植：
/// - PageView：横向滑动翻页（对应 HSCROLL + mWatchingAdapter）
/// - InteractiveViewer：双指缩放 + 平移（对应 ZoomView）
/// - GestureDetector 双击：切换 1x/2.5x 缩放（对应 setDoubleTap）
/// - 黑色背景 + 顶部页码指示器 + 关闭按钮
class _GalleryFullScreenViewer extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final int initialIndex;
  final Color backgroundColor;
  final Color textColor;

  const _GalleryFullScreenViewer({
    required this.images,
    required this.initialIndex,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  State<_GalleryFullScreenViewer> createState() =>
      _GalleryFullScreenViewerState();
}

class _GalleryFullScreenViewerState extends State<_GalleryFullScreenViewer> {
  late PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.backgroundColor,
      body: Stack(
        children: [
          // PageView 横向滑动翻页
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.images.length,
              onPageChanged: _onPageChanged,
              // 允许预加载相邻页（对应多看 reading__large_image_view_newer/older）
              allowImplicitScrolling: true,
              itemBuilder: (context, index) {
                return _FullScreenImage(
                  image: widget.images[index],
                  onTap: () => Navigator.of(context).pop(),
                );
              },
            ),
          ),
          // 顶部：页码指示器 + 关闭按钮
          _buildTopBar(),
          // 底部：图片描述（如果有的话）
          if (widget.images[_currentIndex].maintitle.isNotEmpty ||
              widget.images[_currentIndex].subtitle.isNotEmpty)
            _buildBottomDescription(),
        ],
      ),
    );
  }

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

  Widget _buildBottomDescription() {
    final img = widget.images[_currentIndex];
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (img.maintitle.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    img.maintitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (img.subtitle.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    img.subtitle,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏单张图片查看器（支持双指缩放 + 双击缩放）
///
/// ★ 对齐多看 MultiTouchImageView ★
/// - setDoubleTap(MotionEvent) → 我们用 GestureDetector.onDoubleTap
/// - setScale(ScaleGestureDetector) → InteractiveViewer 自动处理
/// - PageScaleType.MATCH_INSIDE → BoxFit.contain
class _FullScreenImage extends StatefulWidget {
  final EpubGalleryImage image;
  final VoidCallback onTap;

  const _FullScreenImage({
    required this.image,
    required this.onTap,
  });

  @override
  State<_FullScreenImage> createState() => _FullScreenImageState();
}

class _FullScreenImageState extends State<_FullScreenImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late AnimationController _animController;
  Animation<Matrix4>? _scaleAnimation;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        if (_scaleAnimation != null) {
          _controller.value = _scaleAnimation!.value;
        }
      });
  }

  @override
  void dispose() {
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 双击切换缩放（对应多看 MultiTouchImageView.setDoubleTap）
  void _handleDoubleTap() {
    if (_isZoomed) {
      // 缩回 1x
      _scaleAnimation = Matrix4Tween(
        begin: _controller.value,
        end: Matrix4.identity(),
      ).animate(CurvedAnimation(
        parent: _animController,
        curve: Curves.easeOutCubic,
      ));
      _animController.forward(from: 0);
      _isZoomed = false;
    } else {
      // 放大到 2.5x
      _scaleAnimation = Matrix4Tween(
        begin: _controller.value,
        end: Matrix4.diagonal3Values(2.5, 2.5, 1.0),
      ).animate(CurvedAnimation(
        parent: _animController,
        curve: Curves.easeOutCubic,
      ));
      _animController.forward(from: 0);
      _isZoomed = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        // 对齐多看 ZoomView 的缩放范围
        minScale: 1.0,
        maxScale: 4.0,
        // 对齐多看 PageScaleType.MATCH_INSIDE（contain）
        boundaryMargin: const EdgeInsets.all(double.infinity),
        clipBehavior: Clip.none,
        onInteractionEnd: (details) {
          // 缩放结束后更新状态
          final scale = _controller.value.getMaxScaleOnAxis();
          _isZoomed = scale > 1.01;
        },
        child: Center(
          child: _buildImage(),
        ),
      ),
    );
  }

  Widget _buildImage() {
    final src = widget.image.src;
    if (src.startsWith('data:')) {
      // data: URI
      return Image.memory(
        _parseDataUri(src),
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }
    // 本地文件路径
    final file = File(src);
    return Image.file(
      file,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        return const Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 64,
        );
      },
    );
  }

  /// 解析 data: URI 为 Uint8List
  Uint8List _parseDataUri(String dataUri) {
    // data:image/jpeg;base64,XXXX
    final commaIdx = dataUri.indexOf(',');
    if (commaIdx < 0) return Uint8List(0);
    final base64Str = dataUri.substring(commaIdx + 1);
    return base64Decode(base64Str);
  }
}
