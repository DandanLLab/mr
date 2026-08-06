# MR EPUB 渲染架构

> 本文档说明本仓库 EPUB 阅读器的完整架构与渲染机制，供后续维护参考。
> 对齐目标：1:1 还原作者排版（对齐多看阅读器渲染效果）。

## 总体架构

```
EPUB 文件 (.epub)
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  EpubParser.parseFromBytes()  (lib/services/local_book/) │
│  ──────────────────────────────────────────────────────  │
│  · ZIP 解压（package:archive）                            │
│  · OPF/NCX/NAV 解析（epub/ 子目录）                       │
│  · CSS 合并 + 白名单过滤（EpubCssProcessor）              │
│  · 章节正文 HTML 保留原始标签                              │
│  · 图片转 base64 data URI 内嵌                            │
│  · 识别画廊章节（.duokan-image-gallery）                  │
│  · 预生成 richContent：[[EPUB_CSS]]...[[EPUB_BODY]]...    │
└──────────────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  LocalBookService  (lib/services/local_book/)            │
│  ──────────────────────────────────────────────────────  │
│  · 导入时调用 EpubParser，结果存 Hive                      │
│  · richContent 字段持久化，阅读时直接返回                  │
└──────────────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│  NovelReaderPage  (lib/pages/reader/)                    │
│  ──────────────────────────────────────────────────────  │
│  · 章节调度：分页/滚动模式切换                             │
│  · 路由分流：                                              │
│    - isGallery=true → EpubGalleryPage（横向滑动画廊）     │
│    - 其他 → ReaderWebView（column 分栏 / scroll 滚动）    │
└──────────────────────────────────────────────────────────┘
    │
    ├─────────────────┬───────────────────────────────────
    ▼                 ▼
普通章节           画廊章节
```

## 普通章节渲染（ReaderWebView）

**文件**：`lib/pages/reader/webview/reader_html_template.dart` + `reader_webview.dart`

### 渲染方案
- **InAppWebView** 加载生成的 HTML 文档
- **CSS Multi-column Layout** 原生分栏分页（`column-width` + `column-gap`）
- **CSS 变量驱动样式**：字号/行距/颜色等通过 `--reader-*` 变量热更新，无需 reload
- **JS 计算页数**：`Math.round((scrollWidth + gap) / (columnWidth + gap))`

### 内容格式
```
[[EPUB_CSS]]<style>原作者 CSS</style>[[/EPUB_CSS]]
[[EPUB_BODY]]<p>章节正文 HTML</p>[[/EPUB_BODY]]
```
- 导入时由 `EpubParser.parseFromBytes` 预生成并持久化
- 阅读时 `ReaderHtmlTemplate.generate` 解析此格式，CSS 注入 `<style>`，body 放入 `#reader-content-a`

### 翻页动画
- **双层容器**：`#reader-content-a`（主层，可交互）+ `#reader-content-b`（动画层，默认隐藏）
- **三种模式**：slide（平移）/ cover（覆盖）/ simulation（3D 翻折）
- 动画期间 b 层显示并做动画，结束后 a 跳到目标页，b 隐藏

### 滚动模式
- 无缝章节续接：`appendChapter` 追加新章节到 DOM，不 reload
- `IntersectionObserver` 监测当前可见章节，更新顶栏标题
- 接近底部 1.5 视口高度时触发预加载下一章

### CSS 白名单（对齐多看）
- 位置：`lib/services/local_book/epub_css_processor.dart` → `_supportedProperties`
- 数量：**88 个 CSS 属性**（87 标准属性 + 1 个 `duokan-text-indent` EPUB 归一化）
- 逆向自多看 `libddlayoutkit.so` 的 `.rodata` 段 CSS 属性名字符串表
- 涵盖：文本/字体/行距字距/背景/边框/盒模型/定位/溢出/显示/分页/多栏/弹性盒/列表/表格/轮廓/内容/变换/书写方向/滚动捕捉/对象适配

## 画廊章节渲染（EpubGalleryPage）

**文件**：`lib/pages/reader/epub_gallery_page.dart`

### 触发条件
- 章节正文含 `<div class="duokan-image-gallery">` → `EpubChapter.isGallery = true`
- 解析时提取每张图片的 `src` / `maintitle` / `subtitle` 到 `galleryImages`
- 章节级样式（背景图、gallery-title、cell 边框阴影等）提取到 `galleryChapterStyle.rawCss`

### 渲染方案（1:1 对齐多看）
- **InAppWebView** 加载生成的 HTML
- **rawCss 原样内联**：原作者 CSS 直接放入 `<style>`，浏览器原生渲染所有视觉属性
- **横向滑动**：`scroll-snap-type: x mandatory` + `scroll-snap-align: center`
- **dotted 指示器**：body 最后一个 flex item，跟随 textColor 变色

### 多看渲染架构对齐
多看 `libddlayoutkit.so` 中 `CGalleryHtmlSnippetOutputSystem` 把原作者竖向画廊转换成横向滑动：

```
<div class="slider">
  <div class="slide_group">
    <div class="dotted"><span/><span class="active"/></div>
    <div class="btn btn_l">left</div>
    <div class="btn btn_r">right</div>
  </div>
  <div class="slide">
    <div class="msg">...</div>
  </div>
</div>
```

我们用 `scroll-snap` 实现等效横向滑动，保留原作者 `duokan-image-gallery-cell` 的 `border + box-shadow` 视觉样式。

### 全屏图片判定
对齐多看 `CBaseLayout::IsFullScreenImage`：
- 全屏图片：`object-fit: contain` 按比例缩放到适合 slide
- 非全屏图片：保留原作 `border + box-shadow`

### 章节边界衔接
- 滑到第一张继续往前 → `onPreviousChapter` 回调
- 滑到最后一张继续往后 → `onNextChapter` 回调
- `initialPageToEnd`：从下一章往前翻到本章最后一张

## 关键模块

| 模块 | 文件 | 职责 |
|------|------|------|
| EPUB 解析 | `lib/services/local_book/epub_parser.dart` | ZIP 解压 + OPF/NCX/NAV + 章节正文 + 画廊识别 |
| CSS 处理 | `lib/services/local_book/epub_css_processor.dart` | CSS 解析 + shorthand 展开 + 白名单过滤 |
| EPUB 子模块 | `lib/services/local_book/epub/` | epub.dart / epub_font / epub_toc_parser / epub_viewport_parser 等 |
| 本地书服务 | `lib/services/local_book/local_book_service.dart` | 导入流程 + Hive 持久化 |
| HTML 模板 | `lib/pages/reader/webview/reader_html_template.dart` | 生成阅读器 HTML（CSS + JS + body） |
| WebView 组件 | `lib/pages/pages/reader/webview/reader_webview.dart` | InAppWebView 封装 + 样式热更新 |
| WebView 控制器 | `lib/pages/reader/webview/reader_webview_controller.dart` | Dart→JS 调用方法 |
| 画廊页面 | `lib/pages/reader/epub_gallery_page.dart` | 画廊横向滑动渲染 + dotted 指示器 |
| 阅读器主页 | `lib/pages/reader/novel_reader_page.dart` | 章节调度 + 路由分流（画廊/普通） |
| 翻页动画 | `lib/pages/reader/page_turn/` | simulation/slide/cover 三种翻页 delegate |

## 多看逆向分析成果

逆向来源：`libddlayoutkit.so`（多看阅读器 native 库）

### HTML 模板（0x4d6850-0x4d7522）
- `wraper/border/path/image/text/svg/span/div/note/img/audio/video`
- `slider/slide_group/dotted/btn_l/btn_r/slide/msg`
- SVG 模板：`<svg><path fill="#%06x" stroke="#%06x"/></svg>`

### 渲染架构
- `IHtmlSnippetOutputSystem` — 接口层
- `CHtmlSnippetOutputSystem` — 普通章节实现
- `CGalleryHtmlSnippetOutputSystem` — 画廊专门实现
- `CBookRender::getHtmlSnippet` — 入口
- `CBaseLayout::IsFullScreenImage` — 全屏图片判定

### CSS 属性（87 个）
完整清单见 `epub_css_processor.dart` → `_supportedProperties`。

### 多看 dd-* 类名（46 个）
`dd-screenblock/dd-subscreenblock/dd-singlepage/dd-singlepara/dd-acrosspage/dd-bleedtop/dd-bleedbottom/dd-bleedleft/dd-bleedright/dd-smallimage/dd-imagecut/dd-image-cut-horizontal/dd-image-cut-vertical/dd-margin-top-inpage/dd-margin-bottom-inpage/dd-padding-top-inpage/dd-padding-bottom-inpage/dd-footnote/dd-fixedcolor/dd-fixedfontsize/dd-fullscreen/dd-noclick/dd-dropcaps/dd-drop-caps-lines/dd-vertical-align-inpage/dd-style/dd-tts/dd-sim2tra` 等。
