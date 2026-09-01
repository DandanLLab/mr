// 导出 MR 管线实际产出的 CSS + 章节 HTML，供 Chrome 对比渲染
// 用法: flutter test test/epub_dump_pipeline_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_parser.dart';

void main() {
  final bytes = File(
    'D:/OpenClaw/.openclaw/workspace/mr/.tmp/verify/youxi.epub',
  ).readAsBytesSync();

  test('导出 MR 管线 CSS + 代表章节 HTML', () {
    final book = EpubParser.parseFromBytes(bytes);
    expect(book.chapters.isNotEmpty, true);

    final outDir = Directory(
      'D:/OpenClaw/.openclaw/workspace/mr/.tmp/pipeline_dump',
    );
    outDir.createSync(recursive: true);

    // 1. 导出书籍级 CSS（MR 实际注入 WebView 的）
    File('${outDir.path}/mr_inlined.css')
        .writeAsStringSync(book.inlinedCss);
    print('CSS 大小: ${book.inlinedCss.length}');

    // 2. 导出代表章节的 richContent（去掉包裹标记）
    final picks = <int, String>{
      0: 'cover',
      1: 'zzsm',
      2: 'xsjj',
      3: 'renwu0', // Section0001
      24: 'chap0001', // Chapter0001 kuaijie
      25: 'chap0002', // Chapter0002 VOL01
    };
    // 手册章 Section0015 在 spine[18]
    for (var i = 0; i < book.chapters.length && i < 30; i++) {
      final c = book.chapters[i];
      final href = c.href ?? '';
      if (href.contains('Section0015')) picks[i] = 'manual15';
      if (href.contains('Section0016')) picks[i] = 'manual16';
      if (href.contains('Chapter0010')) picks[i] = 'chap0010';
    }
    picks.forEach((idx, name) {
      if (idx >= book.chapters.length) return;
      final c = book.chapters[idx];
      final rich = c.richContent ?? '(null)';
      File('${outDir.path}/chapter_$name.html').writeAsStringSync(rich);
      print('spine[$idx] $name href=${c.href} len=${rich.length} '
          'isGallery=${c.isGallery} isFullPageBg=${c.isFullPageBg} '
          'isFixed=${c.isFixedLayout}');
    });
  });
}
