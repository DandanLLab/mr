/// EPUB 核心模块 barrel export
///
/// 移植自 JRead/Legado 的 epubcore 包
///
/// 模块清单：
/// - EpubPath：路径规范化 + resolve + fragment + percent-escape 解码
/// - EpubPackage / EpubPackageParser：OPF 结构化解析
/// - EpubTocParser：三级回退目录解析
/// - EpubPublisherStyles：link→style 内联 + url() 重写 + @import 递归
/// - EpubFontFace / EpubFontFaceParser / EpubFontCatalog：@font-face 提取
/// - EpubViewportParser：fixed-layout 检测与视口解析
/// - EpubFootnoteSupport：脚注 JS 注入 + payload 解析
///
/// 注意：EpubCssProcessor 位于上级目录（lib/services/local_book/epub_css_processor.dart），
/// 由调用方直接 import，不通过本 barrel re-export，避免相对路径混乱。
library;

export 'epub_path.dart';
export 'epub_package.dart';
export 'epub_package_parser.dart';
export 'epub_toc_parser.dart';
export 'epub_publisher_styles.dart';
export 'epub_font.dart';
export 'epub_viewport_parser.dart';
export 'epub_footnote_support.dart';
