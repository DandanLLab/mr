import 'dart:convert';
import 'dart:typed_data';
import 'package:charset/charset.dart';

import '../storage_service.dart';

class TxtTocRule {
  final String name;
  final String rule;
  final String? replacement;
  final bool enabled;
  final int serialNumber;

  const TxtTocRule({
    required this.name,
    required this.rule,
    this.replacement,
    this.enabled = true,
    this.serialNumber = 0,
  });
}

class TxtParser {
  static const int maxLengthWithNoToc = 10 * 1024;
  static const int maxLengthWithToc = 102400;

  static const List<TxtTocRule> defaultTocRules = [
    TxtTocRule(name: '第X章', rule: r'^第[零一二三四五六七八九十百千万\d]+章'),
    TxtTocRule(name: '第X节', rule: r'^第[零一二三四五六七八九十百千万\d]+节'),
    TxtTocRule(name: '第X回', rule: r'^第[零一二三四五六七八九十百千万\d]+回'),
    TxtTocRule(name: '第X卷', rule: r'^第[零一二三四五六七八九十百千万\d]+卷'),
    TxtTocRule(name: 'Chapter', rule: r'^[Cc]hapter\s+\d+'),
    TxtTocRule(name: '卷X', rule: r'^卷[零一二三四五六七八九十百千万\d]+'),
    TxtTocRule(name: '数字顿号', rule: r'^[零一二三四五六七八九十百千万\d]+[、.]'),
    TxtTocRule(name: '第X部分', rule: r'^第[零一二三四五六七八九十百千万\d]+部分'),
    TxtTocRule(name: '第X篇', rule: r'^第[零一二三四五六七八九十百千万\d]+篇'),
    TxtTocRule(name: '第X集', rule: r'^第[零一二三四五六七八九十百千万\d]+集'),
    TxtTocRule(name: '第X部', rule: r'^第[零一二三四五六七八九十百千万\d]+部'),
    TxtTocRule(name: '序/前言/引言', rule: r'^(序[言章]?|前言|引言|楔子|尾声|后记|番外)'),
    TxtTocRule(name: '卷标', rule: r'^[上中下]卷'),
    TxtTocRule(name: 'Chapter+标题', rule: r'^[Cc]hapter\s+\d+.*'),
    TxtTocRule(name: '第X章+标题', rule: r'^第[零一二三四五六七八九十百千万\d]+章\s*\S+'),
    TxtTocRule(name: 'Part', rule: r'^[Pp]art\s+\d+'),
  ];

  static List<TxtChapter> parse(String content, {String fileName = '', bool splitLongChapter = true, List<TxtTocRule>? customRules}) {
    // 合并自定义规则和默认规则
    final allRules = [...defaultTocRules];
    if (customRules != null) {
      allRules.addAll(customRules.where((r) => r.enabled));
    }
    final rule = _findBestRule(content, allRules);
    if (rule != null) {
      return _parseWithRule(content, rule, fileName, splitLongChapter);
    }
    return _parseWithoutRule(content, fileName);
  }

  static TxtTocRule? _findBestRule(String content, [List<TxtTocRule>? rules]) {
    final previewContent = content.length > 512000 ? content.substring(0, 512000) : content;
    final lines = previewContent.split(RegExp(r'\n'));

    TxtTocRule? bestRule;
    int maxMatchCount = -1;
    const int overRuleCount = 2;

    for (final rule in (rules ?? defaultTocRules)) {
      if (!rule.enabled) continue;
      final pattern = RegExp(rule.rule, caseSensitive: false, multiLine: true);
      int matchCount = 0;
      int errorCount = 0;
      int lastMatchEnd = 0;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.length > 50) continue;
        if (pattern.hasMatch(trimmed)) {
          final contentLength = trimmed.length - lastMatchEnd;
          if (lastMatchEnd == 0 || contentLength > 1000) {
            matchCount++;
          } else if (contentLength < 100) {
            errorCount++;
          }
          lastMatchEnd = trimmed.length;
        }
      }

      if (matchCount >= errorCount * 3 && matchCount > maxMatchCount + overRuleCount) {
        maxMatchCount = matchCount;
        bestRule = rule;
        if (maxMatchCount > 70) break;
      }
    }

    return bestRule;
  }

  static List<TxtChapter> _parseWithRule(
    String content,
    TxtTocRule rule,
    String fileName,
    bool splitLongChapter,
  ) {
    final pattern = RegExp(rule.rule, caseSensitive: false, multiLine: true);
    final chapters = <TxtChapter>[];
    final lines = content.split(RegExp(r'\n'));

    String? currentTitle;
    final buffer = StringBuffer();
    int chapterIndex = 0;

    for (int i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (_isChapterTitleByRule(trimmed, pattern)) {
        if (currentTitle != null) {
          final chapterContent = buffer.toString().trim();
          if (splitLongChapter && chapterContent.length > maxLengthWithToc) {
            final subChapters = _splitLongChapter(
              currentTitle,
              chapterContent,
              chapterIndex,
            );
            chapters.addAll(subChapters);
            chapterIndex += subChapters.length;
          } else {
            chapters.add(TxtChapter(
              index: chapterIndex++,
              title: _cleanTitle(currentTitle),
              content: chapterContent,
            ));
          }
          buffer.clear();
        }
        currentTitle = trimmed;
      } else if (currentTitle != null) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(lines[i]);
      } else {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(lines[i]);
      }
    }

    if (currentTitle != null) {
      final chapterContent = buffer.toString().trim();
      if (splitLongChapter && chapterContent.length > maxLengthWithToc) {
        final subChapters = _splitLongChapter(
          currentTitle,
          chapterContent,
          chapterIndex,
        );
        chapters.addAll(subChapters);
      } else {
        chapters.add(TxtChapter(
          index: chapterIndex,
          title: _cleanTitle(currentTitle),
          content: chapterContent,
        ));
      }
    } else if (buffer.isNotEmpty) {
      final chapterContent = buffer.toString().trim();
      if (splitLongChapter && chapterContent.length > maxLengthWithToc) {
        final subChapters = _splitLongChapter(
          fileName.isNotEmpty ? fileName : '正文',
          chapterContent,
          0,
        );
        chapters.addAll(subChapters);
      } else {
        chapters.add(TxtChapter(
          index: 0,
          title: fileName.isNotEmpty ? fileName : '正文',
          content: chapterContent,
        ));
      }
    }

    return chapters;
  }

  static List<TxtChapter> _parseWithoutRule(String content, String fileName) {
    final chapters = <TxtChapter>[];
    final lines = content.split(RegExp(r'\n'));

    final buffer = StringBuffer();
    int chapterIndex = 0;
    int currentLength = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line);
      currentLength += line.length;

      if (currentLength >= maxLengthWithNoToc) {
        final chapterContent = buffer.toString().trim();
        chapters.add(TxtChapter(
          index: chapterIndex++,
          title: '第$chapterIndex部分',
          content: chapterContent,
        ));
        buffer.clear();
        currentLength = 0;
      }
    }

    if (buffer.isNotEmpty) {
      final chapterContent = buffer.toString().trim();
      if (chapterContent.length > 100 || chapters.isEmpty) {
        chapters.add(TxtChapter(
          index: chapterIndex,
          title: chapters.isEmpty
              ? (fileName.isNotEmpty ? fileName : '正文')
              : '第${chapterIndex + 1}部分',
          content: chapterContent,
        ));
      } else if (chapters.isNotEmpty) {
        chapters.last = TxtChapter(
          index: chapters.last.index,
          title: chapters.last.title,
          content: '${chapters.last.content}\n\n$chapterContent',
        );
      }
    }

    return chapters;
  }

  static List<TxtChapter> _splitLongChapter(
    String title,
    String content,
    int startIndex,
  ) {
    final chapters = <TxtChapter>[];
    final lines = content.split(RegExp(r'\n'));
    final buffer = StringBuffer();
    int currentLength = 0;
    int subIndex = 1;

    for (final line in lines) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line);
      currentLength += line.length;

      if (currentLength >= maxLengthWithNoToc) {
        chapters.add(TxtChapter(
          index: startIndex + chapters.length,
          title: '$title($subIndex)',
          content: buffer.toString().trim(),
        ));
        buffer.clear();
        currentLength = 0;
        subIndex++;
      }
    }

    if (buffer.isNotEmpty) {
      chapters.add(TxtChapter(
        index: startIndex + chapters.length,
        title: '$title($subIndex)',
        content: buffer.toString().trim(),
      ));
    }

    return chapters;
  }

  static bool _isChapterTitleByRule(String line, RegExp pattern) {
    if (line.isEmpty || line.length > 50) return false;
    return pattern.hasMatch(line);
  }

  static bool _isChapterTitle(String line) {
    if (line.isEmpty || line.length > 50) return false;
    for (final rule in defaultTocRules) {
      if (!rule.enabled) continue;
      if (RegExp(rule.rule, caseSensitive: false).hasMatch(line)) {
        return true;
      }
    }
    return false;
  }

  static String _cleanTitle(String title) {
    return title
        .replaceAll(RegExp(r'^[\s　]+'), '')
        .replaceAll(RegExp(r'[\s　]+$'), '')
        .replaceAll(RegExp(r'[\s　]{2,}'), ' ')
        .trim();
  }

  /// 从 TXT 内容中提取简介
  static String extractIntro(String content) {
    final lines = content.split(RegExp(r'\n'));
    final buffer = StringBuffer();
    int charCount = 0;
    const int maxIntroLength = 500;

    for (int i = 0; i < lines.length && charCount < maxIntroLength; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      // 如果遇到第一章标题，停止提取
      if (_isChapterTitle(line)) break;

      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line);
      charCount += line.length;
    }

    return _cleanIntroText(buffer.toString());
  }

  /// 清理简介文本
  static String _cleanIntroText(String text) {
    return text
        .replaceAll(RegExp(r'^[\s　]+', multiLine: true), '')
        .replaceAll(RegExp(r'[\s　]+$', multiLine: true), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// 加载自定义正则规则
  static List<TxtTocRule> loadCustomRules() {
    final storage = StorageService.instance;
    final rulesData = storage.getCachedData('customTocRules');
    if (rulesData == null) return [];

    try {
      final list = rulesData as List;
      return list.map((e) {
        final map = e as Map<String, dynamic>;
        return TxtTocRule(
          name: map['name'] as String,
          rule: map['rule'] as String,
          replacement: map['replacement'] as String?,
          enabled: map['enabled'] as bool? ?? true,
          serialNumber: map['serialNumber'] as int? ?? 0,
        );
      }).toList();
    } catch (e) {
      return [];
    }
  }

  /// 保存自定义正则规则
  static Future<void> saveCustomRules(List<TxtTocRule> rules) async {
    final data = rules.map((r) => {
      'name': r.name,
      'rule': r.rule,
      'replacement': r.replacement,
      'enabled': r.enabled,
      'serialNumber': r.serialNumber,
    }).toList();
    await StorageService.instance.cacheData('customTocRules', data);
  }

  /// 验证正则规则是否有效
  static bool validateRule(String pattern) {
    try {
      RegExp(pattern, multiLine: true);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 测试正则规则，返回匹配结果
  static List<String> testRule(String content, String pattern) {
    try {
      final regex = RegExp(pattern, multiLine: true);
      final matches = regex.allMatches(content);
      return matches.map((m) => m.group(0) ?? '').take(20).toList();
    } catch (e) {
      return [];
    }
  }

  static String detectEncoding(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return 'utf-8';
    }
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) return 'utf-16le';
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) return 'utf-16be';
    }
    String? utf8Text;
    try {
      utf8Text = utf8.decode(bytes);
    } catch (_) {
      return 'gbk';
    }

    if (!bytes.any((byte) => byte >= 0x80)) {
      return 'utf-8';
    }

    try {
      final gbkText = const GbkCodec().decode(bytes);
      final utf8Score = _decodeScore(utf8Text);
      final gbkScore = _decodeScore(gbkText);
      final threshold = (bytes.length / 80).clamp(8, 32).round();
      if (gbkScore > utf8Score + threshold) {
        return 'gbk';
      }
    } catch (_) {
      // Keep UTF-8 when strict GBK decoding fails.
    }

    return 'utf-8';
  }

  static String decodeBytes(Uint8List bytes, {String? encoding}) {
    encoding ??= detectEncoding(bytes);
    switch (encoding.toLowerCase()) {
      case 'utf-8':
        return utf8.decode(bytes, allowMalformed: true);
      case 'utf-16le':
        return _decodeUtf16(bytes, littleEndian: true);
      case 'utf-16be':
        return _decodeUtf16(bytes, littleEndian: false);
      case 'gbk':
      case 'gb2312':
      case 'gb18030':
        return const GbkCodec(allowMalformed: true).decode(bytes);
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static int _decodeScore(String text) {
    var score = 0;
    for (final rune in text.runes) {
      if (rune == 0xFFFD) {
        score -= 20;
      } else if (_isCjkRune(rune)) {
        score += 3;
      } else if (_isCommonTextRune(rune)) {
        score += 1;
      } else if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) {
        score -= 6;
      } else {
        score -= 1;
      }
    }
    return score;
  }

  static bool _isCjkRune(int rune) {
    return (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0x20000 && rune <= 0x2A6DF);
  }

  static bool _isCommonTextRune(int rune) {
    return (rune >= 0x20 && rune <= 0x7E) ||
        rune == 0x09 ||
        rune == 0x0A ||
        rune == 0x0D ||
        (rune >= 0x3000 && rune <= 0x303F) ||
        (rune >= 0xFF00 && rune <= 0xFFEF);
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final codeUnits = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final codeUnit = littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1];
      if (codeUnit != 0xFEFF) {
        codeUnits.add(codeUnit);
      }
    }
    return String.fromCharCodes(codeUnits);
  }

  static String analyzeNameAuthor(String fileName) {
    final name = fileName.replaceAll(RegExp(r'\.(txt|epub|pdf|umd|mobi)$', caseSensitive: false), '');

    final patterns = [
      RegExp(r'《(.+?)》.*?作者[：:]\s*(.+)'),
      RegExp(r'《(.+?)》'),
      RegExp(r'(.+?)\s+作者[：:]\s*(.+)'),
      RegExp(r'(.+?)\s+[bB][yY]\s*(.+)'),
      RegExp(r'(.+?)[-_\s]+(.+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(name);
      if (match != null) {
        return match.group(1)!.trim();
      }
    }

    return _formatBookName(name);
  }

  static String _formatBookName(String name) {
    return name
        .replaceAll(RegExp(r'[_\-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static (String name, String? author) extractNameAndAuthor(String fileName) {
    final name = fileName.replaceAll(RegExp(r'\.(txt|epub|pdf|umd|mobi)$', caseSensitive: false), '');

    final patterns = [
      RegExp(r'《(.+?)》.*?作者[：:]\s*(.+)'),
      RegExp(r'(.+?)\s+作者[：:]\s*(.+)'),
      RegExp(r'(.+?)\s+[bB][yY]\s*(.+)'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(name);
      if (match != null) {
        return (match.group(1)!.trim(), match.group(2)!.trim());
      }
    }

    final bookPattern = RegExp(r'《(.+?)》');
    final bookMatch = bookPattern.firstMatch(name);
    if (bookMatch != null) {
      return (bookMatch.group(1)!.trim(), null);
    }

    return (_formatBookName(name), null);
  }
}

class TxtChapter {
  final int index;
  final String title;
  final String content;
  final int wordCount;

  const TxtChapter({
    required this.index,
    required this.title,
    required this.content,
    int? wordCount,
  }) : wordCount = wordCount ?? content.length;
}
