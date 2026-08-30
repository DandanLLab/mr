// 《这游戏也太真实了》目录标题解析诊断
// 分层定位：包解析（ncxHref）→ TOC 解析（标题）→ 全链路（parseFromBytes）
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub/epub.dart' as core;
import 'package:mr/services/local_book/epub_parser.dart';

class _TestReader implements core.EpubArchiveReader {
  final Map<String, List<int>> files;
  _TestReader(this.files);

  @override
  bool exists(String path) => files.containsKey(path);

  @override
  List<String> list() => files.keys.toList();

  @override
  List<int> readBytes(String path) => files[path]!;

  @override
  String readText(String path) => utf8.decode(files[path]!);
}

void main() {
  final bytes = File(
    'D:/OpenClaw/.openclaw/workspace/mr/.tmp/newbook/game.epub',
  ).readAsBytesSync();

  test('分层诊断：包解析 → TOC 解析', () {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, List<int>>{};
    for (final f in archive) {
      if (f.isFile) {
        files[f.name.replaceAll('\\', '/')] = f.content as List<int>;
      }
    }
    final reader = _TestReader(files);
    print('=== exists toc.ncx=${reader.exists('toc.ncx')} '
        'OEBPS/toc.ncx=${reader.exists('OEBPS/toc.ncx')}');

    final pkg = core.EpubPackageParser.parse(reader);
    print('=== ncxHref=${pkg.ncxHref} navHref=${pkg.navHref} '
        'spine=${pkg.spine.length}');

    try {
      final toc = core.EpubTocParser.parse(reader, pkg);
      print('=== toc items=${toc.length} '
          'first3=${toc.take(3).map((t) => t.title).toList()}');
    } catch (e, st) {
      print('=== toc parse EXCEPTION: $e');
      print(st.toString().split('\n').take(8).join('\n'));
    }
  });

  test('全链路：parseFromBytes 章节标题', () {
    final Uint8List bytes2 = bytes;
    final book = EpubParser.parseFromBytes(bytes2);
    print('=== chapters=${book.chapters.length} tocTree=${book.tocTree.length}');
    for (final c in book.chapters.take(6)) {
      print('  spine ${c.spineIndex}: title="${c.title}"');
    }
    expect(book.chapters.isNotEmpty, true);
  });
}
