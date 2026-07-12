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

  // ===== 对齐 legado ElementsSingle 索引规则测试 =====
  // legado 注释：
  //   1. ':'分隔索引，!或.表示筛选方式，索引可为负数
  //      例如 tag.div.-1:10:2 或 tag.div!0:3
  //   2. []索引写法 [it,it,...] 或 [!it,it,...]
  //      区间格式为 start:end 或 start:end:step，start 为 0 可省略，end 为 -1 可省略
  //      索引，区间两端及间隔都支持负数
  //      例如 tag.div[-1, 3:-2:-10, 2]
  //   3. 特殊用法 tag.div[-1:0] 可在任意地方让列表反向

  test('legado range with step: tag.div.-1:10:2', () {
    // 10 个 div，索引 -1:10:2 表示从最后一个到第10个，步长2
    // 实际效果（legado 行为）：start=-1→9, end=10→clamp(9), step=2
    // 但因为 start(9) == end(9)，区间只有一个数，返回第9个
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div><div>i4</div>'
        '<div>i5</div><div>i6</div><div>i7</div><div>i8</div><div>i9</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div.-1:10:2');
    // legado: start=9, end=10→clamp(9), start==end，返回索引9
    expect(result, hasLength(1));
    expect((result.first as dynamic).text, 'i9');
  });

  test('legado range basic: div.0:2', () {
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div><div>i4</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div.0:2');
    expect(result, hasLength(3));
    expect((result[0] as dynamic).text, 'i0');
    expect((result[1] as dynamic).text, 'i1');
    expect((result[2] as dynamic).text, 'i2');
  });

  test('legado range with step: div.0:4:2', () {
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div><div>i4</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div.0:4:2');
    // step=2: 索引 0, 2, 4
    expect(result, hasLength(3));
    expect((result[0] as dynamic).text, 'i0');
    expect((result[1] as dynamic).text, 'i2');
    expect((result[2] as dynamic).text, 'i4');
  });

  test('legado negative step: div.4:0:-1 (list reverse)', () {
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div><div>i4</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div.4:0:-1');
    // legado: stepX=-1, len=5, -stepX=1<5, step=-1+5=4
    // start=4, end=0, end<start, 所以 start downTo end step 4
    // i=4 → add, i=0 → add, i=-4 越界停止
    // 实际：4, 0
    expect(result.length, greaterThanOrEqualTo(1));
    expect((result[0] as dynamic).text, 'i4');
  });

  test('legado list reverse special: div[-1:0]', () {
    // legado 特殊用法：[-1:0] 让列表反向
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div[-1:0]');
    // start=-1→3, end=0, step=1, end<start, 反向遍历 3,2,1,0
    expect(result, hasLength(4));
    expect((result[0] as dynamic).text, 'i3');
    expect((result[1] as dynamic).text, 'i2');
    expect((result[2] as dynamic).text, 'i1');
    expect((result[3] as dynamic).text, 'i0');
  });

  test('legado bracket multi-index: div[-1, 0, 2]', () {
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div[-1, 0, 2]');
    // -1→3, 0, 2
    expect(result, hasLength(3));
    final texts = result.map((e) => (e as dynamic).text).toList();
    expect(texts, containsAll(['i3', 'i0', 'i2']));
  });

  test('legado bracket exclude: div[!0, 1]', () {
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div[!0, 1]');
    // 排除 0 和 1，返回 i2, i3
    expect(result, hasLength(2));
    expect((result[0] as dynamic).text, 'i2');
    expect((result[1] as dynamic).text, 'i3');
  });

  test('legado dot exclude separator: tag.div!0:1', () {
    // ! 作为分隔符（legado 原生写法），排除 0:1
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('tag.div!0:1');
    // 排除 0:1，返回 i2, i3
    expect(result, hasLength(2));
    expect((result[0] as dynamic).text, 'i2');
    expect((result[1] as dynamic).text, 'i3');
  });

  test('legado negative index: div.-1', () {
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div.-1');
    expect(result, hasLength(1));
    expect((result[0] as dynamic).text, 'i3');
  });

  test('legado bracket range with step: div[0:3:2]', () {
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div><div>i4</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div[0:3:2]');
    // start=0, end=3, step=2: 0, 2
    expect(result, hasLength(2));
    expect((result[0] as dynamic).text, 'i0');
    expect((result[1] as dynamic).text, 'i2');
  });

  test('legado bracket complex: div[-1, 3:1:-1, 0]', () {
    // 混合索引：-1, 范围 3:1:-1, 0
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div[-1, 3:1:-1, 0]');
    // -1→3, 3:1:-1 (step=-1, len=4, -stepX=1<4, step=-1+4=3, start=3,end=1, 反向 step 3: 3, 0)
    // 0
    // 最终：3, 0 (去重)
    expect(result.length, greaterThanOrEqualTo(1));
    final texts = result.map((e) => (e as dynamic).text).toList();
    expect(texts, contains('i3'));
    expect(texts, contains('i0'));
  });

  test('legado range omit start: div[:2]', () {
    // start 省略表示 0
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div[:2]');
    // start=0, end=2: 0, 1, 2
    expect(result, hasLength(3));
    expect((result[0] as dynamic).text, 'i0');
    expect((result[1] as dynamic).text, 'i1');
    expect((result[2] as dynamic).text, 'i2');
  });

  test('legado range omit end: div[1:]', () {
    // end 省略表示 len-1
    const html = '<html><body>'
        '<div>i0</div><div>i1</div><div>i2</div><div>i3</div>'
        '</body></html>';
    final analyzer = AnalyzeRule().setContent(html);
    final result = analyzer.getElements('div[1:]');
    // start=1, end=3: 1, 2, 3
    expect(result, hasLength(3));
    expect((result[0] as dynamic).text, 'i1');
    expect((result[1] as dynamic).text, 'i2');
    expect((result[2] as dynamic).text, 'i3');
  });
}
