// 特殊章识别诊断：Chapter2/3/4 + 17~24 的 isGallery/isFixedLayout/背景
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_parser.dart';

void main() {
  final bytes = File(
    'D:/OpenClaw/.openclaw/workspace/mr/.tmp/newbook/game.epub',
  ).readAsBytesSync();

  test('特殊章解析诊断', () {
    final book = EpubParser.parseFromBytes(bytes);
    for (var i = 0; i < book.chapters.length; i++) {
      final c = book.chapters[i];
      if (i >= 0 && i < 6 || (i >= 15 && i <= 25)) {
        print('spine[$i] title="${c.title}" '
            'isGallery=${c.isGallery} isFixed=${c.isFixedLayout} '
            'href=${c.href}');
      }
    }
    expect(book.chapters.isNotEmpty, true);
  });
}
