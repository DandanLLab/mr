import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_parser.dart';

void main() {
  test('对比 xsjj/zzsm 的 richContent 结构', () {
    final f = File(
        r'D:\Program Files\Netease\GameViewer\Download\【多看插图版】《这游戏也太真实了》 作者：晨星LL（全本）V1.0【书眸精制】 - 晨星LL(1).epub');
    final book = EpubParser.parseFromBytes(f.readAsBytesSync());
    for (final title in ['书籍简介', '制作说明']) {
      final ch = book.chapters.firstWhere((c) => c.title == title);
      final rc = ch.richContent ?? '';
      final hasCss = rc.contains('[[EPUB_CSS]]');
      final hasBody = rc.contains('[[EPUB_BODY]]');
      final cssStart = rc.indexOf('[[EPUB_CSS]]');
      final cssEnd = rc.indexOf('[[/EPUB_CSS]]');
      final cssLen = (cssStart >= 0 && cssEnd > cssStart) ? cssEnd - cssStart : -1;
      final hasShujia = rc.contains('shujia');
      final hasBacktop = rc.contains('backtop');
      print('$title: len=${rc.length} EPUB_CSS=$hasCss(cssLen=$cssLen) BODY=$hasBody '
          'shujia=$hasShujia backtop=$hasBacktop');
      print('  head200: ${rc.substring(0, rc.length > 200 ? 200 : rc.length).replaceAll("\n", " ")}');
    }
  }, timeout: Timeout(Duration(minutes: 3)));
}
