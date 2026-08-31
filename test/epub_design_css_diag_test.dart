// 诊断：design-content 60% 字号在 CSS 处理链后的产物
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_css_processor.dart';

void main() {
  test('design-content 字号链诊断', () {
    final css = File(
      'D:/OpenClaw/.openclaw/workspace/mr/.tmp/newbook/extract/OEBPS/Styles/Style0001.css',
    ).readAsStringSync();
    final rules = EpubCssProcessor.parseRules(css);
    for (final r in rules) {
      if (r.selector.contains('design-content') ||
          r.selector.contains('design-box') ||
          r.selector.contains('design-ad') ||
          r.selector.contains('zhizuosm')) {
        print('SEL: ' + r.selector);
        for (final d in r.declarations) {
          if (d.name.contains('font') ||
              d.name.contains('size') ||
              d.name.contains('width') ||
              d.name.contains('margin') ||
              d.name.contains('padding')) {
            print('   ' + d.name + ': ' + d.value);
          }
        }
        print('---');
      }
    }
    expect(rules, isNotEmpty);
  });
}
