import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_parser.dart';

void main() {
  test('目录 dup 排查：dump 废土生存手册附近章节', () {
    final f = File(
        r'D:\Program Files\Netease\GameViewer\Download\【多看插图版】《这游戏也太真实了》 作者：晨星LL（全本）V1.0【书眸精制】 - 晨星LL(1).epub');
    if (!f.existsSync()) {
      print('epub 不存在，跳过');
      return;
    }
    final bytes = f.readAsBytesSync();
    final book = EpubParser.parseFromBytes(bytes);
    final chs = book.chapters;
    print('总章节数: ${chs.length}');
    for (var i = 0; i < chs.length && i < 45; i++) {
      final c = chs[i];
      print('[$i] vol=${c.isVolume} depth=${c.depth} parent=${c.parentId} '
          'spine=${c.spineIndex} | ${c.title}');
    }
  }, timeout: Timeout(Duration(minutes: 3)));
}
