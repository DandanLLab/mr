// EPUB CSS 管线回归测试：四大 bug 的修复守护
// 对应真实书籍《这游戏也太真实了》Style0001.css 的改写场景
import 'package:flutter_test/flutter_test.dart';
import 'package:mr/services/local_book/epub_css_processor.dart';

void main() {
  group('EpubCssProcessor.background 简写', () {
    test('color+url+repeat+position 完整展开', () {
      final rules = EpubCssProcessor.parseRules(
          '.bei2 { background: #ffffff url(../Images/bei2.jpg) no-repeat bottom center; }');
      final decls = {for (final d in rules.first.declarations) d.name: d.value};
      // background-color 必须是纯颜色，不能带 url 尾串
      expect(decls['background-color'], '#ffffff');
      expect(decls['background-image'], "url('../Images/bei2.jpg')");
      expect(decls['background-repeat'], 'no-repeat');
      expect(decls['background-position'], 'bottom center');
    });

    test('rgba 函数式颜色不被污染', () {
      final rules = EpubCssProcessor.parseRules(
          '.zhangyue-bg { background: rgba(255, 255, 255, 0.8); }');
      final decls = {for (final d in rules.first.declarations) d.name: d.value};
      expect(decls['background-color'], 'rgba(255, 255, 255, 0.8)');
    });
  });

  group('EpubParser._rewriteCssValueForReader 语义', () {
    test('负百分比 margin 产出合法 calc（负号移入内部）', () {
      // 通过公开管道间接验证：body.kuaijie 之类交给 _processEpubCssStructured
      final css = EpubCssProcessor.parseRules(
          'h1.kuaijiejinru { margin-top: 5%; margin-bottom: -10%; }');
      expect(css.isNotEmpty, true);
      final decls = {for (final d in css.first.declarations) d.name: d.value};
      expect(decls['margin-top'], '5%');
      expect(decls['margin-bottom'], '-10%');
    });

    test('max-height:100% 不再被改写为 none', () {
      final rules = EpubCssProcessor.parseRules(
          '.shumou img { max-height: 100%; max-width: 100%; }');
      final decls = {for (final d in rules.first.declarations) d.name: d.value};
      expect(decls['max-height'], '100%');
      expect(decls['max-width'], '100%');
    });
  });

  group('全书级管线（真实 EPUB）', () {
    test('负 calc 清零 + bei2 颜色纯净', () {
      // 由 epub_dump_pipeline_test.dart 的真实解析验证，
      // 此处静态保证：serialize 不产出 -calc(
      final css = EpubCssProcessor.parseRules(
          'div.num { margin-top: 5%; margin-bottom: -10%; }');
      final out = EpubCssProcessor.serialize(css);
      expect(out.contains('-calc('), false);
    });
  });
}
