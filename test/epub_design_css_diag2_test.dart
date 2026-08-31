// 诊断：序列化后的完整 CSS 里 design 段长什么样
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_css_processor.dart';

void main() {
  test('design 段序列化产物', () {
    final css = File(
      'D:/OpenClaw/.openclaw/workspace/mr/.tmp/newbook/extract/OEBPS/Styles/Style0001.css',
    ).readAsStringSync();
    final rules = EpubCssProcessor.parseRules(css);
    final out = EpubCssProcessor.serialize(rules);
    final i = out.indexOf('design-content');
    print(out.substring(i - 100, i + 400));
    final j = out.indexOf('design-box');
    print('=====');
    print(out.substring(j - 60, j + 500));
    expect(out.contains('design-content'), true);
  });
}
