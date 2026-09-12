import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'epub_parser.dart';
import 'epub/epub.dart' as epub_core;

/// EPUB 富内容持久化存储
///
/// ★ 解决「导入后时间长了数据被销毁 / 系统清缓存丢数据」★
/// 解析产物（每章 richContent、画廊数据、章节标志、合并 CSS）落在
/// **应用文档目录**（documents/epub_rich/<hash>/，非 cache 目录，
/// 系统清理缓存不清除、卸载才销毁），冷启动直接读盘免重解析：
/// - 导入时：全量解析后一次性落盘（后台，不阻塞 UI）
/// - 打开时：manifest 校验通过 → 秒开结构（不生成富内容），
///   阅读某章时按需读该章 .rich 文件（毫秒级）
/// - 校验失败（EPUB 变更/解析器版本升级）→ 回退全量解析并重建存储
///
/// 目录结构：
/// ```
/// epub_rich/<hash>/
///   manifest.json   {"pv": 解析器版本, "bytes": EPUB 字节数, "n": 章节数}
///   style.css       合并 CSS（EpubBook.inlinedCss）
///   meta.json       章节特殊标志（画廊/整页背景/fixed-layout/多看标签）
///   <index>.rich    每章 richContent（[[EPUB_BODY]]...[[/EPUB_BODY]]）
/// ```
class EpubRichStore {
  /// 解析器版本号：富内容生成逻辑变化时 +1，使旧缓存失效
  static const int parserVersion = 1;

  final String dirPath;

  EpubRichStore._(this.dirPath);

  /// 按书籍 EPUB 路径构建存储（与 epub_extract 同 hash 规则，一一对应）
  static Future<EpubRichStore> forBook(String epubFilePath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final hash =
        epubFilePath.hashCode.toRadixString(16).replaceAll('-', 'n');
    return EpubRichStore._('${appDir.path}/epub_rich/$hash');
  }

  File _file(String name) => File('$dirPath/$name');

  /// 存储是否有效（manifest 存在且解析器版本/EPUB 字节数匹配）
  Future<bool> isValid(int epubBytesLen) async {
    try {
      final f = _file('manifest.json');
      if (!await f.exists()) return false;
      final m =
          jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return m['pv'] == parserVersion && m['bytes'] == epubBytesLen;
    } catch (e) {
      debugPrint('[EPUB存储] manifest 校验失败: $e');
      return false;
    }
  }

  /// 全量落盘（导入/全量解析后调用；后台执行不阻塞 UI）
  ///
  /// 原子性：先写全部章节文件与 meta/style，最后写 manifest（校验入口）。
  /// 中断残留（无 manifest）会被下次 [isValid] 判无效后整体重建。
  Future<void> persist({
    required int epubBytesLen,
    required EpubBook book,
  }) async {
    try {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);

      await _file('style.css').writeAsString(book.inlinedCss);

      // meta.json：只序列化非默认标志的章节（正文章不进 meta，保持小体积）
      final metaEntries = <Map<String, dynamic>>[];
      for (final c in book.chapters) {
        final entry = _chapterToMeta(c);
        if (entry != null) metaEntries.add(entry);
      }
      await _file('meta.json').writeAsString(
        jsonEncode({'c': metaEntries}),
      );

      for (final c in book.chapters) {
        final rich = c.richContent;
        if (rich == null || rich.isEmpty) continue;
        await _file('${c.index}.rich').writeAsString(rich);
      }

      await _file('manifest.json').writeAsString(jsonEncode({
        'pv': parserVersion,
        'bytes': epubBytesLen,
        'n': book.chapters.length,
      }));
      debugPrint('[EPUB存储] 落盘完成: ${book.chapters.length}章 → $dirPath');
    } catch (e, st) {
      // 落盘失败不影响本次阅读（内存中数据完整），下次打开重解析
      debugPrint('[EPUB存储] 落盘失败: $e\n$st');
    }
  }

  /// 单章富内容追加落盘（按需生成后调用）
  Future<void> saveRich(int index, String rich) async {
    try {
      await _file('$index.rich').writeAsString(rich);
    } catch (_) {}
  }

  /// 读合并 CSS（无则 null）
  Future<String?> loadCss() async {
    try {
      final f = _file('style.css');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 读某章富内容（无则 null；毫秒级文件读）
  Future<String?> loadRich(int index) async {
    try {
      final f = _file('$index.rich');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 把 meta.json 中的章节特殊标志注水到章节对象（冷启动快路径：
  /// 结构解析不生成富内容，画廊/背景/fixed-layout 标志从这里恢复）
  Future<void> hydrateFlags(List<EpubChapter> chapters) async {
    try {
      final f = _file('meta.json');
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final list = (m['c'] as List?) ?? const [];
      for (final entry in list.cast<Map<String, dynamic>>()) {
        final i = entry['i'] as int;
        if (i < 0 || i >= chapters.length) continue;
        final c = chapters[i];
        if (entry['g'] == 1) {
          c.isGallery = true;
          c.galleryImages = ((entry['gi'] as List?) ?? const [])
              .cast<Map<String, dynamic>>()
              .map(EpubRichStore._galleryImageFromMeta)
              .toList();
          if (entry['gcs'] != null) {
            c.galleryChapterStyle = _galleryStyleFromMeta(
                entry['gcs'] as Map<String, dynamic>);
          }
        }
        if (entry['fb'] == 1) c.isFullPageBg = true;
        if (entry['fx'] == 1) {
          c.isFixedLayout = true;
          c.fixedLayoutWidth =
              (entry['w'] as num?)?.toDouble();
          c.fixedLayoutHeight =
              (entry['h'] as num?)?.toDouble();
        }
        if (entry['dkb'] != null) {
          c.duokanImageBlocks = ((entry['dkb'] as List).cast<String>())
              .map((n) => epub_core.DuokanImageBlockType.values
                  .firstWhere((v) => v.name == n,
                      orElse: () => epub_core.DuokanImageBlockType.none))
              .toSet();
        }
        if (entry['dkc'] != null) {
          c.duokanCustomTags = ((entry['dkc'] as List).cast<String>())
              .map((n) => epub_core.DuokanCustomTagType.values
                  .firstWhere((v) => v.name == n,
                      orElse: () => epub_core.DuokanCustomTagType.none))
              .toSet();
        }
      }
    } catch (e) {
      debugPrint('[EPUB存储] meta 注水失败: $e');
    }
  }

  // ===== 序列化 =====

  /// 章节特殊标志 → meta 条目（全默认返回 null 不写入）
  static Map<String, dynamic>? _chapterToMeta(EpubChapter c) {
    final hasGallery = c.isGallery && c.galleryImages.isNotEmpty;
    if (!hasGallery &&
        !c.isFullPageBg &&
        !c.isFixedLayout &&
        c.duokanImageBlocks.where((v) => v != epub_core.DuokanImageBlockType.none).isEmpty &&
        c.duokanCustomTags.where((v) => v != epub_core.DuokanCustomTagType.none).isEmpty) {
      return null;
    }
    final entry = <String, dynamic>{'i': c.index};
    if (hasGallery) {
      entry['g'] = 1;
      entry['gi'] = [
        for (final img in c.galleryImages)
          {
            'src': img.src,
            'mt': img.maintitle,
            'st': img.subtitle,
            'gh': img.galleryHint,
          }
      ];
      final gcs = c.galleryChapterStyle;
      if (gcs != null) {
        entry['gcs'] = {
          'bg': gcs.backgroundImageSrc,
          'bc': gcs.backgroundColor,
          'br': gcs.backgroundRepeat,
          'bs': gcs.backgroundSize,
          'bp': gcs.backgroundPosition,
          'ba': gcs.backgroundAttachment,
          'gt': gcs.galleryTitle,
          'gx': gcs.galleryTxt,
          'rc': gcs.rawCss,
          'ef': gcs.embeddedFonts,
        };
      }
    }
    if (c.isFullPageBg) entry['fb'] = 1;
    if (c.isFixedLayout) {
      entry['fx'] = 1;
      entry['w'] = c.fixedLayoutWidth;
      entry['h'] = c.fixedLayoutHeight;
    }
    final dkb = c.duokanImageBlocks
        .where((v) => v != epub_core.DuokanImageBlockType.none)
        .map((v) => v.name)
        .toList();
    if (dkb.isNotEmpty) entry['dkb'] = dkb;
    final dkc = c.duokanCustomTags
        .where((v) => v != epub_core.DuokanCustomTagType.none)
        .map((v) => v.name)
        .toList();
    if (dkc.isNotEmpty) entry['dkc'] = dkc;
    return entry;
  }

  static EpubGalleryImage _galleryImageFromMeta(Map<String, dynamic> m) {
    return EpubGalleryImage(
      src: m['src'] as String? ?? '',
      maintitle: m['mt'] as String? ?? '',
      subtitle: m['st'] as String? ?? '',
      galleryHint: m['gh'] as String? ?? '',
    );
  }

  static EpubGalleryChapterStyle _galleryStyleFromMeta(
      Map<String, dynamic> m) {
    return EpubGalleryChapterStyle(
      backgroundImageSrc: m['bg'] as String?,
      backgroundColor: (m['bc'] as num?)?.toInt(),
      backgroundRepeat: m['br'] as String?,
      backgroundSize: m['bs'] as String?,
      backgroundPosition: m['bp'] as String?,
      backgroundAttachment: m['ba'] as String?,
      galleryTitle: m['gt'] as String?,
      galleryTxt: m['gx'] as String?,
      rawCss: m['rc'] as String?,
      embeddedFonts: ((m['ef'] as Map?) ?? const {})
          .cast<String, dynamic>()
          .map((k, v) => MapEntry(k, v as String)),
    );
  }
}
