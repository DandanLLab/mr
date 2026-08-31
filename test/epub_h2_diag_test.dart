// 诊断：h2.design-title 规则逐属性存活
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_css_processor.dart';

void main() {
  test('h2.design-title 逐属性诊断', () {
    final mini = """
h2.design-title {
  margin-top: 1em;
  margin-left: auto;
  margin-bottom: 1em;
  margin-right: auto;
  padding-top: 0;
  padding-left: 4px;
  padding-bottom: 0;
  padding-right: 4px;
  font-family: "zt3";
  font-size: 120%;
  color: #333;
  text-align: center;
}
""";
    final rules = EpubCssProcessor.parseRules(mini);
    print('mini rules: ' + rules.length.toString());
    for (final r in rules) {
      print('SEL: ' + r.selector);
      for (final d in r.declarations) {
        print('   ' + d.name + ': ' + d.value);
      }
    }
    final css = File(
      'D:/OpenClaw/.openclaw/workspace/mr/.tmp/newbook/extract/OEBPS/Styles/Style0001.css',
    ).readAsStringSync();
    final rules2 = EpubCssProcessor.parseRules(css);
    final hit = rules2.where((r) => r.selector.contains('design-title')).toList();
    print('=== file design-title rules: ' + hit.length.toString());
    for (final r in hit) {
      print('SEL: ' + r.selector);
      for (final d in r.declarations) {
        print('   ' + d.name + ': ' + d.value);
      }
    }
    expect(rules2, isNotEmpty);
  });
}
