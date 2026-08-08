/// 多看 EPUB 扩展标签识别
///
/// 借鉴多看 libdkkernel.so 的扩展标签注册表：
/// - DKE_BLOCK_TYPE（FUN_00310338）：duokan_image_* 图片块类型
/// - HTML_CUSTOMTAG_TYPE（FUN_00311058）：duokan_footnote/video/audio/3dmodel 自定义标签
/// - DKE_INPUT_TYPE（FUN_00310228）：duokan_droplist 表单类型
///
/// 多看在标准 EPUB 基础上扩展了以下自定义标签/类名：
/// 1. 图片类：duokan-image-static/single/multiframe/crosspage/gallery/callout
/// 2. 脚注类：duokan-footnote/footnote-content/footnote-item
/// 3. 媒体类：duokan-video/audio/3dmodel
/// 4. 交互类：duokan-droplist/interactive/exercise
///
/// 本模块提供标签识别和 CSS 选择器映射，供 EpubParser 和阅读器使用。
library;

/// 多看图片块类型（对应 native DKE_BLOCK_TYPE）
///
/// 从 FUN_00310338 反编译提取，映射 duokan-image-* class → 块类型枚举。
enum DuokanImageBlockType {
  /// 未知/非多看图片
  none(0),

  /// .duokan-image-static — 静态图片（不可交互）
  staticImage(1),

  /// .duokan-image-single — 单图（可点击放大）
  single(2),

  /// .duokan-image-multiframe — 多帧图（动图/GIF）
  multiframe(3),

  /// .duokan-image-crosspage — 跨页图（横跨左右页）
  crosspage(4),

  /// .duokan-image-gallery — 图库（横向滑动浏览）
  gallery(5),

  /// .duokan-image-gallery-cell — 图库单元格
  galleryCell(6),

  /// .duokan-image-multicallout — 多图注
  multicallout(7),

  /// .duokan-image-base — 图片基底（图注的基底图）
  base(8),

  /// .duokan-image-callout — 图注
  callout(9);

  final int nativeValue;
  const DuokanImageBlockType(this.nativeValue);

  /// 从 CSS class 字符串识别图片块类型
  static DuokanImageBlockType fromClass(String className) {
    final lower = className.toLowerCase();
    if (lower.contains('duokan-image-gallery-cell')) {
      return DuokanImageBlockType.galleryCell;
    }
    if (lower.contains('duokan-image-gallery')) {
      return DuokanImageBlockType.gallery;
    }
    if (lower.contains('duokan-image-multicallout')) {
      return DuokanImageBlockType.multicallout;
    }
    if (lower.contains('duokan-image-callout')) {
      return DuokanImageBlockType.callout;
    }
    if (lower.contains('duokan-image-crosspage')) {
      return DuokanImageBlockType.crosspage;
    }
    if (lower.contains('duokan-image-multiframe')) {
      return DuokanImageBlockType.multiframe;
    }
    if (lower.contains('duokan-image-single')) {
      return DuokanImageBlockType.single;
    }
    if (lower.contains('duokan-image-static')) {
      return DuokanImageBlockType.staticImage;
    }
    if (lower.contains('duokan-image-base')) {
      return DuokanImageBlockType.base;
    }
    return DuokanImageBlockType.none;
  }
}

/// 多看自定义标签类型（对应 native HTML_CUSTOMTAG_TYPE）
///
/// 从 FUN_00311058 反编译提取，映射 CSS 选择器 → 自定义标签枚举。
/// 多看用标准 HTML 标签 + duokan-* class 实现自定义语义。
enum DuokanCustomTagType {
  /// 未知/非多看自定义标签
  none(0),

  /// duokan-footnote / a.duokan-footnote — 脚注引用
  footnote(1),

  /// ol.duokan-footnote-content — 脚注内容列表
  footnoteContent(2),

  /// li.duokan-footnote-item — 脚注条目
  footnoteItem(3),

  /// video.duokan-video / object.duokan-video — 视频
  video(4),

  /// audio.duokan-audio / object.duokan-audio — 音频
  audio(5),

  /// object.duokan-3dmodel — 3D 模型
  model3d(6),

  /// duokan-interactive — 交互内容
  interactive(7),

  /// duokan-exercise — 练习题
  exercise(8),

  /// duokan-formula — 公式
  formula(9);

  final int nativeValue;
  const DuokanCustomTagType(this.nativeValue);
}

/// 多看扩展标签识别器
class DuokanTagRecognizer {
  DuokanTagRecognizer._();

  /// 多看自定义标签的 CSS 选择器列表（对应 native HTML_CUSTOMTAG_TYPE 注册表）
  ///
  /// 从 FUN_00311058 反编译提取的选择器映射：
  /// - duokan-footnote → 1（脚注引用）
  /// - a.duokan-footnote → 1（脚注链接）
  /// - ol.duokan-footnote-content → 2（脚注内容）
  /// - li.duokan-footnote-item → 3（脚注条目）
  /// - video.duokan-video → 4（视频）
  /// - object.duokan-video → 4（视频对象）
  /// - audio.duokan-audio → 5（音频）
  /// - object.duokan-audio → 5（音频对象）
  /// - object.duokan-3dmodel → 6（3D 模型）
  static const Map<String, DuokanCustomTagType> customTagSelectors = {
    'duokan-footnote': DuokanCustomTagType.footnote,
    'a.duokan-footnote': DuokanCustomTagType.footnote,
    'ol.duokan-footnote-content': DuokanCustomTagType.footnoteContent,
    'li.duokan-footnote-item': DuokanCustomTagType.footnoteItem,
    'video.duokan-video': DuokanCustomTagType.video,
    'object.duokan-video': DuokanCustomTagType.video,
    'audio.duokan-audio': DuokanCustomTagType.audio,
    'object.duokan-audio': DuokanCustomTagType.audio,
    'object.duokan-3dmodel': DuokanCustomTagType.model3d,
  };

  /// 多看图片块的 CSS class 列表（对应 native DKE_BLOCK_TYPE 注册表）
  ///
  /// 从 FUN_00310338 反编译提取的 class→type 映射。
  static const Map<String, DuokanImageBlockType> imageBlockClasses = {
    'duokan-image-static': DuokanImageBlockType.staticImage,
    'duokan-image-single': DuokanImageBlockType.single,
    'duokan-image-multiframe': DuokanImageBlockType.multiframe,
    'duokan-image-crosspage': DuokanImageBlockType.crosspage,
    'duokan-image-gallery': DuokanImageBlockType.gallery,
    'duokan-image-gallery-cell': DuokanImageBlockType.galleryCell,
    'duokan-image-multicallout': DuokanImageBlockType.multicallout,
    'duokan-image-base': DuokanImageBlockType.base,
    'duokan-image-callout': DuokanImageBlockType.callout,
  };

  /// 多看表单输入类型（对应 native DKE_INPUT_TYPE）
  ///
  /// 从 FUN_00310228 反编译提取：
  /// - checkbox → 1
  /// - radio → 2
  /// - reset → 3
  /// - duokan-droplist → 4
  /// - submit → 5
  static const Map<String, int> inputTypes = {
    'checkbox': 1,
    'radio': 2,
    'reset': 3,
    'duokan-droplist': 4,
    'submit': 5,
  };

  /// 检测 HTML 是否包含多看扩展标签
  ///
  /// 用于 EpubParser 在解析阶段快速判断章节是否需要特殊处理。
  static bool hasDuokanTags(String html) {
    final lower = html.toLowerCase();
    return lower.contains('duokan-image-') ||
        lower.contains('duokan-footnote') ||
        lower.contains('duokan-video') ||
        lower.contains('duokan-audio') ||
        lower.contains('duokan-3dmodel') ||
        lower.contains('duokan-interactive') ||
        lower.contains('duokan-exercise') ||
        lower.contains('duokan-formula') ||
        lower.contains('duokan-droplist');
  }

  /// 识别 HTML 中所有的多看图片块类型
  ///
  /// 返回去重后的类型列表，供阅读器决定渲染策略。
  static Set<DuokanImageBlockType> detectImageBlocks(String html) {
    final result = <DuokanImageBlockType>{};
    final lower = html.toLowerCase();
    for (final entry in imageBlockClasses.entries) {
      if (lower.contains(entry.key)) {
        result.add(entry.value);
      }
    }
    return result;
  }

  /// 识别 HTML 中所有的多看自定义标签类型
  ///
  /// 返回去重后的类型列表，供阅读器决定交互策略。
  static Set<DuokanCustomTagType> detectCustomTags(String html) {
    final result = <DuokanCustomTagType>{};
    final lower = html.toLowerCase();
    for (final entry in customTagSelectors.entries) {
      // 提取选择器中的 class 名（去掉标签名前缀）
      final selector = entry.key;
      final dotIndex = selector.indexOf('.');
      final className = dotIndex >= 0 ? selector.substring(dotIndex + 1) : selector;
      if (lower.contains(className)) {
        result.add(entry.value);
      }
    }
    return result;
  }

  /// 判断章节是否为多看图库章节
  ///
  /// 含 .duokan-image-gallery 容器的章节需要 Flutter PageView 接管渲染。
  static bool isGalleryChapter(String html) {
    return html.toLowerCase().contains('duokan-image-gallery');
  }

  /// 判断章节是否为多看跨页图章节
  ///
  /// 含 .duokan-image-crosspage 的章节需要双页对开渲染。
  static bool isCrosspageChapter(String html) {
    return html.toLowerCase().contains('duokan-image-crosspage');
  }

  /// 判断章节是否含多看脚注
  ///
  /// 含 duokan-footnote 的章节需要注入脚注拦截 JS。
  static bool hasFootnotes(String html) {
    final lower = html.toLowerCase();
    return lower.contains('duokan-footnote') ||
        lower.contains('duokan-footnote-content') ||
        lower.contains('duokan-footnote-item');
  }

  /// 判断章节是否含多看媒体内容
  ///
  /// 含 duokan-video/audio/3dmodel 的章节需要媒体播放器支持。
  static bool hasMedia(String html) {
    final lower = html.toLowerCase();
    return lower.contains('duokan-video') ||
        lower.contains('duokan-audio') ||
        lower.contains('duokan-3dmodel');
  }
}
