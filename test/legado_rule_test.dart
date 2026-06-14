import 'package:mr/services/source_engine/analyze_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('supports legado jsoup chain selectors used by xiaoqiang source', () {
    const html = '''
    <html><body>
      <div class="bookbox">
        <h4><a href="/book/123.html">测试小说</a></h4>
        <span class="author">测试作者</span>
        <span class="cat">更新到： 第一章</span>
        <p>p0</p><p>p1</p><p>最新章节： 第二章</p>
      </div>
      <a href="/next.html">下一页</a>
    </body></html>
    ''';

    final analyzer = AnalyzeRule().setContent(
      html,
      baseUrl: 'http://123xiaoqiang.me/search/',
    );
    final books = analyzer.getElements('.bookbox');
    expect(books, hasLength(1));

    final item = AnalyzeRule().setContent(
      books.first,
      baseUrl: 'http://123xiaoqiang.me/search/',
    );
    expect(item.getString('h4@a.0@text'), '测试小说');
    expect(
        item.getString('h4@a.0@href'), 'http://123xiaoqiang.me/book/123.html');
    expect(item.getString('.author.0@text'), '测试作者');
    expect(item.getString('.cat@text##更新到：|.*\\s'), '第一章');
    expect(item.getString('p.2@text##最新章节：|.*\\s'), '第二章');
    expect(analyzer.getString('text.下一页@href'),
        'http://123xiaoqiang.me/next.html');
  });
}
