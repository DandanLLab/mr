// 验证 design 面板相关规则的属性存活
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_css_processor.dart';

void main() {
  test('design 面板属性存活验证', () {
    final css = File(
      'D:/OpenClaw/.openclaw/workspace/mr/.tmp/newbook/extract/OEBPS/Styles/Style0001.css',
    ).readAsStringSync();
    final rules = EpubCssProcessor.parseRules(css);
    final out = EpubCssProcessor.serialize(rules);
    // 关键属性存活检查
    final checks = {
      'div.design-box line-height:125%': RegExp(r'div\.design-box\s*{[^}]*line-height:\s*125%'),
      'div.design-box background kuang.png': RegExp(r'div\.design-box[^}]*kuang\.png'),
      'p.design-content font-size:60%': RegExp(r'p\.design-content\s*{[^}]*font-size:\s*60%'),
      'h2.design-title font-size:120%': RegExp(r'h2\.design-title\s*{[^}]*font-size:\s*120%'),
      'img.design-icon-bk width:20px': RegExp(r'img\.design-icon-bk[^}]*width:\s*20px'),
      'duokan-text-indent 转写': out.contains('duokan-text-indent') == false,
      '.shumou img margin': RegExp(r'\.shumou img[^}]*margin'),
    };
    checks.forEach((k, v) {
      final bool ok = (v is RegExp) ? v.hasMatch(out) : (v == true);
      print((ok ? '[OK] ' : '[LOST] ') + k);
    });
    expect(out.isNotEmpty, true);
  });
}
