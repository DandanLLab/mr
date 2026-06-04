import 'package:dan_shenqi/models/book_source.dart';
import 'package:dan_shenqi/services/book_source_import_service.dart';
import 'package:dan_shenqi/services/book_source_locator.dart';
import 'package:dan_shenqi/services/source_engine/analyze_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnalyzeUrl', () {
    test('parses legado page rules, variables, options and relative URLs', () {
      final parsed = AnalyzeUrl.parse(
        'search/<1,2,3>?q={{key}}, {"method":"POST","body":{"page":"{{page}}"}}',
        baseUrl: 'https://example.com/root/',
        keyword: '三体',
        page: 4,
      );

      expect(
          parsed.url, 'https://example.com/root/search/3?q=%E4%B8%89%E4%BD%93');
      expect(parsed.option?.method, 'POST');
      expect(parsed.option?.body, '{"page":"4"}');
    });
  });

  group('BookSource import compatibility', () {
    test('restores nested rules from Hive-style dynamic maps', () {
      final source = BookSource.fromJson(<String, dynamic>{
        'bookSourceUrl': 'https://a.example',
        'bookSourceName': 'A',
        'ruleSearch': <dynamic, dynamic>{
          'bookList': '.book',
          'name': '.name@text',
        },
      });

      expect(source.ruleSearch?.bookList, '.book');
      expect(source.ruleSearch?.name, '.name@text');
    });

    test('parses sourceUrls recursively and deduplicates by source URL',
        () async {
      final responses = <String, String>{
        'https://example.com/a.json':
            '[{"bookSourceUrl":"https://a.example","bookSourceName":"A"}]',
        'https://example.com/b.json':
            '{"bookSourceUrl":"https://a.example","bookSourceName":"A2"}',
      };
      final service = BookSourceImportService(
        fetchText: (url, withoutUserAgent) async => responses[url]!,
      );

      final sources = await service.parseText(
        '{"sourceUrls":["https://example.com/a.json","https://example.com/b.json"]}',
      );

      expect(sources, hasLength(1));
      expect(sources.single.bookSourceName, 'A2');
    });

    test('accepts string encoded numeric and boolean fields', () async {
      final service = BookSourceImportService();
      final sources = await service.parseText(
        '{"bookSourceUrl":"https://a.example","bookSourceName":"A",'
        '"bookSourceType":"2","enabled":"false","weight":"9"}',
      );

      expect(sources.single.bookSourceType, BookSourceType.image);
      expect(sources.single.enabled, isFalse);
      expect(sources.single.weight, 9);
    });
  });

  test('locates sources by bookUrlPattern and orders by weight', () {
    const low = BookSource(
      bookSourceUrl: 'https://fallback.example',
      bookSourceName: 'low',
      bookUrlPattern: r'https://books\.example/\d+',
      weight: 1,
    );
    const high = BookSource(
      bookSourceUrl: 'https://other.example',
      bookSourceName: 'high',
      bookUrlPattern: r'https://books\.example/\d+',
      weight: 10,
    );

    final matches = BookSourceLocator.locate(
      'https://books.example/123, {"headers":{"x":"y"}}',
      const [low, high],
    );

    expect(matches.map((source) => source.bookSourceName), ['high', 'low']);
  });
}
