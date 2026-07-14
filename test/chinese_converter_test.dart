import 'package:flutter_test/flutter_test.dart';
import 'package:mr/utils/chinese_converter.dart';

void main() {
  group('ChineseConverter', () {
    test('不转换时保留原文', () {
      const text = '简体與繁體 mixed 😀';
      expect(ChineseConverter.convert(text, 0), text);
    });

    test('简转繁优先处理一对多短语', () {
      expect(
        ChineseConverter.toTraditional('爱国发展后台里面，皇后在干杯，老板看手表。'),
        '愛國發展後臺裡面，皇后在乾杯，老闆看手錶。',
      );
      expect(ChineseConverter.toTraditional('头发干燥，表面平整。'), '頭髮乾燥，表面平整。');
    });

    test('繁转简合并繁体异体字', () {
      expect(
        ChineseConverter.toSimplified('愛國發展後臺裡面，皇后在乾杯，老闆看手錶。'),
        '爱国发展后台里面，皇后在干杯，老板看手表。',
      );
      expect(ChineseConverter.toSimplified('牆裡有圓桌。'), '墙里有圆桌。');
    });

    test('保留非中文 Unicode 字符', () {
      expect(ChineseConverter.toTraditional('测试😀A1'), '測試😀A1');
    });
  });
}
