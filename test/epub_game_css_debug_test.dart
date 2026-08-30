// CSS 改写诊断：renwu0 背景是否保留
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CSS body.renwu0 改写保留', () {
    final css = File(
      'D:/OpenClaw/.openclaw/workspace/mr/.tmp/newbook/extract/OEBPS/Styles/Style0001.css',
    ).readAsStringSync();
    // 用 @Env 模拟结构化处理——但 _processEpubCssStructured 是私有方法，
    // 先直接检查原 CSS 的 renwu0 规则与 4a-3 的匹配
    print('=== CSS 含 body.renwu0=${css.contains('body.renwu0')} '
        'renwu0.jpg=${css.contains('renwu0.jpg')}');
    final seg = css.substring(css.indexOf('body.renwu0'),
        css.indexOf('body.renwu0') + 200);
    print('=== 规则片段: $seg');
    // 验证 rewriteSelector 逻辑：body.renwu0 → .epub-chapter-bg.renwu0
    final rewritten = css.replaceAllMapped(
      RegExp(r'^(?:html\s+)?body\.', multiLine: true),
      (m) => '.epub-chapter-bg.',
    );
    expect(rewritten.contains('.epub-chapter-bg.renwu0'), true);
  });
}
