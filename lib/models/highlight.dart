import 'package:flutter/material.dart';

enum HighlightStyle {
  background,
  underline,
  strikethrough,
  wavy,
}

enum HighlightColor {
  yellow,
  green,
  blue,
  pink,
  orange,
  purple,
}

extension HighlightColorExtension on HighlightColor {
  Color get color {
    switch (this) {
      case HighlightColor.yellow:
        return const Color(0xFFFFF176);
      case HighlightColor.green:
        return const Color(0xFFA5D6A7);
      case HighlightColor.blue:
        return const Color(0xFF90CAF9);
      case HighlightColor.pink:
        return const Color(0xFFF48FB1);
      case HighlightColor.orange:
        return const Color(0xFFFFCC80);
      case HighlightColor.purple:
        return const Color(0xFFCE93D8);
    }
  }
}

class Highlight {
  final String id;
  final String bookUrl;
  final int chapterIndex;
  final int startIndex;
  final int endIndex;
  final String selectedText;
  final HighlightStyle style;
  final HighlightColor color;
  final String? note;
  final DateTime createdAt;
  final DateTime? updatedAt;

  Highlight({
    required this.id,
    required this.bookUrl,
    required this.chapterIndex,
    required this.startIndex,
    required this.endIndex,
    required this.selectedText,
    required this.style,
    required this.color,
    this.note,
    required this.createdAt,
    this.updatedAt,
  });

  factory Highlight.fromJson(Map<String, dynamic> json) {
    return Highlight(
      id: json['id'] as String,
      bookUrl: json['bookUrl'] as String,
      chapterIndex: json['chapterIndex'] as int,
      startIndex: json['startIndex'] as int,
      endIndex: json['endIndex'] as int,
      selectedText: json['selectedText'] as String,
      style: HighlightStyle.values[json['style'] as int],
      color: HighlightColor.values[json['color'] as int],
      note: json['note'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'bookUrl': bookUrl,
      'chapterIndex': chapterIndex,
      'startIndex': startIndex,
      'endIndex': endIndex,
      'selectedText': selectedText,
      'style': style.index,
      'color': color.index,
      if (note != null) 'note': note,
      'createdAt': createdAt.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }

  Highlight copyWith({
    String? id,
    String? bookUrl,
    int? chapterIndex,
    int? startIndex,
    int? endIndex,
    String? selectedText,
    HighlightStyle? style,
    HighlightColor? color,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Highlight(
      id: id ?? this.id,
      bookUrl: bookUrl ?? this.bookUrl,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      startIndex: startIndex ?? this.startIndex,
      endIndex: endIndex ?? this.endIndex,
      selectedText: selectedText ?? this.selectedText,
      style: style ?? this.style,
      color: color ?? this.color,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class HighlightRule {
  final String id;
  final String name;
  final String pattern;
  final HighlightStyle style;
  final HighlightColor color;
  final bool enabled;
  final bool isBuiltIn;
  final int serialNumber;

  HighlightRule({
    required this.id,
    required this.name,
    required this.pattern,
    required this.style,
    required this.color,
    required this.enabled,
    required this.isBuiltIn,
    required this.serialNumber,
  });

  factory HighlightRule.fromJson(Map<String, dynamic> json) {
    return HighlightRule(
      id: json['id'] as String,
      name: json['name'] as String,
      pattern: json['pattern'] as String,
      style: HighlightStyle.values[json['style'] as int],
      color: HighlightColor.values[json['color'] as int],
      enabled: json['enabled'] as bool,
      isBuiltIn: json['isBuiltIn'] as bool,
      serialNumber: json['serialNumber'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'pattern': pattern,
      'style': style.index,
      'color': color.index,
      'enabled': enabled,
      'isBuiltIn': isBuiltIn,
      'serialNumber': serialNumber,
    };
  }

  static List<HighlightRule> builtInRules() {
    return [
      HighlightRule(
        id: 'builtin_dialog',
        name: '对话',
        pattern: r'「[^」]+」|"[^"]+"',
        style: HighlightStyle.background,
        color: HighlightColor.yellow,
        enabled: true,
        isBuiltIn: true,
        serialNumber: 0,
      ),
      HighlightRule(
        id: 'builtin_paren_note',
        name: '括号注释',
        pattern: r'（[^）]+）|\([^)]+\)',
        style: HighlightStyle.background,
        color: HighlightColor.green,
        enabled: true,
        isBuiltIn: true,
        serialNumber: 1,
      ),
      HighlightRule(
        id: 'builtin_ellipsis',
        name: '省略号',
        pattern: r'…{2,}|\. {3,}',
        style: HighlightStyle.underline,
        color: HighlightColor.orange,
        enabled: true,
        isBuiltIn: true,
        serialNumber: 2,
      ),
      HighlightRule(
        id: 'builtin_separator',
        name: '分隔线',
        pattern: r'^[-—]{3,}$|^[*]{3,}$',
        style: HighlightStyle.underline,
        color: HighlightColor.purple,
        enabled: true,
        isBuiltIn: true,
        serialNumber: 3,
      ),
    ];
  }
}

enum NoteStyle {
  background,
  underline,
  wavy,
  strikethrough,
}
