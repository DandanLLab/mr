import 'dart:convert';
import 'dart:typed_data';

import '../../services/storage_service.dart';

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

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'rule': rule,
      'replacement': replacement,
      'enabled': enabled,
      'serialNumber': serialNumber,
    };
  }

  factory TxtTocRule.fromJson(Map<String, dynamic> json) {
    return TxtTocRule(
      name: json['name'] as String? ?? '',
      rule: json['rule'] as String? ?? '',
      replacement: json['replacement'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      serialNumber: json['serialNumber'] as int? ?? 0,
    );
  }
}

class TxtParser {
  static const int maxLengthWithNoToc = 10 * 1024;
  static const int maxLengthWithToc = 102400;
  static const String customTocRulesKey = 'customTocRules';

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
    final rule = _findBestRule(content, customRules: customRules);
    if (rule != null) {
      return _parseWithRule(content, rule, fileName, splitLongChapter);
    }
    return _parseWithoutRule(content, fileName);
  }

  static TxtTocRule? _findBestRule(String content, {List<TxtTocRule>? customRules}) {
    final previewContent = content.length > 512000 ? content.substring(0, 512000) : content;
    final lines = previewContent.split(RegExp(r'\n'));

    const int overRuleCount = 2;

    (TxtTocRule?, int) evaluateRules(List<TxtTocRule> rules) {
      TxtTocRule? localBestRule;
      int localMaxMatchCount = -1;

      for (final rule in rules) {
        if (!rule.enabled) continue;
        final pattern = RegExp(rule.rule, caseSensitive: false, multiLine: true);
        int matchCount = 0;
        int errorCount = 0;
        int lastMatchOffset = 0;
        int currentOffset = 0;

        for (final line in lines) {
          currentOffset += line.length + 1; // +1 for newline character
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.length > 50) continue;
          if (pattern.hasMatch(trimmed)) {
            final distance = lastMatchOffset == 0 ? 0 : currentOffset - lastMatchOffset;
            if (lastMatchOffset == 0 || distance > 1000) {
              matchCount++;
            } else if (distance < 100) {
              errorCount++;
            }
            lastMatchOffset = currentOffset;
          }
        }

        if (matchCount >= errorCount * 3 && matchCount > localMaxMatchCount + overRuleCount) {
          localMaxMatchCount = matchCount;
          localBestRule = rule;
          if (localMaxMatchCount > 70) break;
        }
      }

      return (localBestRule, localMaxMatchCount > 0 ? localMaxMatchCount : 0);
    }

    // First try custom rules (they have higher priority)
    if (customRules != null && customRules.isNotEmpty) {
      final (customBest, customCount) = evaluateRules(customRules);
      if (customBest != null && customCount >= 2) {
        return customBest;
      }
    }

    // Fall back to default rules
    final (defaultBest, _) = evaluateRules(defaultTocRules);
    return defaultBest;
  }

  static String? validateRule(String pattern) {
    if (pattern.isEmpty) {
      return '正则表达式不能为空';
    }
    try {
      RegExp(pattern);
      return null;
    } catch (e) {
      return '无效的正则表达式: $e';
    }
  }

  static int testRule(String content, String rulePattern) {
    final validationError = validateRule(rulePattern);
    if (validationError != null) return 0;

    final previewContent = content.length > 512000 ? content.substring(0, 512000) : content;
    final lines = previewContent.split(RegExp(r'\n'));
    final pattern = RegExp(rulePattern, caseSensitive: false, multiLine: true);

    int count = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.length > 50) continue;
      if (pattern.hasMatch(trimmed)) {
        count++;
      }
    }
    return count;
  }

  static Future<void> saveCustomRules(List<TxtTocRule> rules) async {
    final jsonList = rules.map((r) => r.toJson()).toList();
    await StorageService.instance.setSetting(customTocRulesKey, jsonEncode(jsonList));
  }

  static List<TxtTocRule> loadCustomRules() {
    final raw = StorageService.instance.getSetting(customTocRulesKey);
    if (raw == null) return [];
    try {
      final List<dynamic> jsonList = jsonDecode(raw as String);
      return jsonList
          .map((e) => TxtTocRule.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
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

  static String _cleanTitle(String title) {
    return title
        .replaceAll(RegExp(r'^[\s　]+'), '')
        .replaceAll(RegExp(r'[\s　]+$'), '')
        .replaceAll(RegExp(r'[\s　]{2,}'), ' ')
        .trim();
  }

  static String detectEncoding(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return 'utf-8';
    }
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) return 'utf-16le';
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) return 'utf-16be';
    }
    try {
      utf8.decode(bytes);
      return 'utf-8';
    } catch (_) {
      return 'gbk';
    }
  }

  static String decodeBytes(Uint8List bytes, {String? encoding}) {
    encoding ??= detectEncoding(bytes);
    switch (encoding.toLowerCase()) {
      case 'utf-8':
        return utf8.decode(bytes, allowMalformed: true);
      case 'utf-16le':
        return String.fromCharCodes(bytes.buffer.asUint16List().where((c) => c != 0xFEFF));
      case 'utf-16be':
        return String.fromCharCodes(bytes.buffer.asUint16List().where((c) => c != 0xFFFE));
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
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

  /// Extracts introduction/description from TXT content.
  /// Looks for preface, foreword, or text before the first chapter.
  static String extractIntro(String content, {int maxChars = 500}) {
    if (content.isEmpty) return '';

    // Patterns for preface/intro sections
    final prefacePattern = RegExp(
      r'^(序[言章]?|前言|引言|楔子|引子|导言|写在前面|写在卷首)',
      multiLine: true,
    );

    // Pattern for first chapter
    final firstChapterPattern = RegExp(
      r'^第[零一二三四五六七八九十百千万\d]+[章节回卷]|^[Cc]hapter\s+\d+',
      multiLine: true,
    );

    // Check if there's a preface before the first chapter
    final prefaceMatch = prefacePattern.firstMatch(content);
    final firstChapterMatch = firstChapterPattern.firstMatch(content);

    // If there's text before the first chapter, that's the intro
    if (firstChapterMatch != null) {
      final beforeFirstChapter = content.substring(0, firstChapterMatch.start).trim();

      if (beforeFirstChapter.isNotEmpty) {
        // If there's a preface marker, use the preface section
        if (prefaceMatch != null && prefaceMatch.start < firstChapterMatch.start) {
          // Find the end of the preface section (next blank line or first chapter)
          final prefaceEnd = firstChapterMatch.start;
          final prefaceText = content.substring(prefaceMatch.start, prefaceEnd).trim();
          if (prefaceText.length <= maxChars * 2) {
            return _cleanIntroText(prefaceText, maxChars);
          }
        }

        // Use text before first chapter as intro
        return _cleanIntroText(beforeFirstChapter, maxChars);
      }
    }

    // No chapter pattern found - use the first few paragraphs
    final paragraphs = content.split(RegExp(r'\n\s*\n'));
    final introBuffer = StringBuffer();
    int charCount = 0;

    for (final para in paragraphs) {
      final trimmed = para.trim();
      if (trimmed.isEmpty) continue;
      if (charCount + trimmed.length > maxChars) {
        introBuffer.write(trimmed.substring(0, maxChars - charCount));
        introBuffer.write('...');
        break;
      }
      if (introBuffer.isNotEmpty) introBuffer.write('\n\n');
      introBuffer.write(trimmed);
      charCount += trimmed.length;
    }

    return introBuffer.toString();
  }

  static String _cleanIntroText(String text, int maxChars) {
    // Remove the title line (e.g., "前言" or "序言") if it's short
    final lines = text.split('\n');
    final cleanedLines = <String>[];
    bool skippedTitle = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (!skippedTitle && trimmed.length <= 6 && trimmed.isNotEmpty) {
        // Skip short title lines like "前言", "序"
        final titlePattern = RegExp(r'^(序[言章]?|前言|引言|楔子|引子|导言)$');
        if (titlePattern.hasMatch(trimmed)) {
          skippedTitle = true;
          continue;
        }
      }
      cleanedLines.add(trimmed);
    }

    var result = cleanedLines.where((l) => l.isNotEmpty).join('\n');
    if (result.length > maxChars) {
      result = '${result.substring(0, maxChars)}...';
    }
    return result;
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
