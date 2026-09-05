import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/providers/reader_provider.dart';
import 'package:mr/services/local_book/epub_parser.dart';
import 'package:mr/pages/reader/webview/reader_html_template.dart';

void main() {
  test('导出 zzsm 章渲染 HTML 供 playwright 检查', () async {
    final f = File(
        r'D:\Program Files\Netease\GameViewer\Download\【多看插图版】《这游戏也太真实了》 作者：晨星LL（全本）V1.0【书眸精制】 - 晨星LL(1).epub');
    final book = EpubParser.parseFromBytes(f.readAsBytesSync());
    final chs = book.chapters;
    final zz = chs.firstWhere((c) => c.title == '制作说明');
    final content = zz.richContent!;
    final provider = ReaderProvider();
    final html = ReaderHtmlTemplate.generate(
      provider: provider,
      content: content,
      title: zz.title,
      viewWidth: 360,
      viewHeight: 640,
      isScrollMode: false,
      pageAnimDurationMs: 300,
      pageModeIndex: 4,
      chapterIndex: 1,
      isRichHtml: true,
    );
    Directory('.tmp/pw').createSync(recursive: true);
    File('.tmp/pw/zzsm.html').writeAsStringSync(html);
    print('HTML 导出: ${html.length} 字节');
    print('0.6em 规则存在: ${html.contains('font-size: 0.6em')}');
  }, timeout: Timeout(Duration(minutes: 3)));
}
