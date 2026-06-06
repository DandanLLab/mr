import 'dart:convert';

class LegadoJsonPath {
  static dynamic read(dynamic input, String path) {
    dynamic data = input;
    if (data is String) data = jsonDecode(data);

    // 借鉴 legado：替换 {$.rule} 内嵌规则
    // 使用平衡组方法处理嵌套花括号
    var processedPath = path.trim();
    processedPath = _replaceInnerRules(processedPath, data);

    final tokens = _tokenize(processedPath);
    var current = <dynamic>[data];
    for (final token in tokens) {
      current = _apply(current, token);
      if (current.isEmpty) return null;
    }
    return current.length == 1 ? current.first : current;
  }

  /// 替换 {$.rule} 内嵌规则（借鉴 legado 的 RuleAnalyzer.innerRule）
  /// 例如: {$.data.nested} → 实际值
  static String _replaceInnerRules(String path, dynamic data) {
    // 检查是否包含 {$. 模式
    if (!path.contains('{\$.') && !path.contains('{\$.')) return path;

    final result = StringBuffer();
    var i = 0;

    while (i < path.length) {
      // 查找 {$.
      if (i + 2 < path.length && path[i] == '{' && path[i + 1] == '\$' && path[i + 2] == '.') {
        final start = i;
        i += 1; // 跳过 {

        // 找到匹配的 }
        var depth = 1;
        var inSingleQuote = false;
        var inDoubleQuote = false;
        final contentStart = i;

        while (i < path.length && depth > 0) {
          final ch = path[i];
          if (ch == '\\' && i + 1 < path.length) { i += 2; continue; }
          if (ch == "'" && !inDoubleQuote) inSingleQuote = !inSingleQuote;
          if (ch == '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote;
          if (!inSingleQuote && !inDoubleQuote) {
            if (ch == '{') {
              depth++;
            } else if (ch == '}') {
              depth--;
              if (depth == 0) {
                final innerPath = path.substring(contentStart, i).trim();
                try {
                  final value = _readRaw(data, innerPath);
                  if (value != null) {
                    result.write(value is String ? value : jsonEncode(value));
                  }
                } catch (_) {
                  result.write(path.substring(start, i + 1));
                }
                i++;
                break;
              }
            }
          }
          i++;
        }

        if (depth > 0) {
          // 没有匹配的 }，保留原文
          result.write(path.substring(start));
          break;
        }
      } else {
        result.write(path[i]);
        i++;
      }
    }

    return result.toString();
  }

  /// 原始读取（不递归替换内嵌规则）
  static dynamic _readRaw(dynamic input, String path) {
    dynamic data = input;
    if (data is String) data = jsonDecode(data);
    final tokens = _tokenize(path.startsWith(r'$') ? path.substring(1) : path);
    var current = <dynamic>[data];
    for (final token in tokens) {
      current = _apply(current, token);
      if (current.isEmpty) return null;
    }
    return current.length == 1 ? current.first : current;
  }

  static List<dynamic> readList(dynamic input, String path) {
    final value = read(input, path);
    if (value == null) return [];
    return value is List ? value : [value];
  }

  static List<_JsonToken> _tokenize(String path) {
    final result = <_JsonToken>[];
    var index = path.startsWith(r'$') ? 1 : 0;
    while (index < path.length) {
      if (path.startsWith('..', index)) {
        index += 2;
        final end = _propertyEnd(path, index);
        result.add(_JsonToken.recursive(path.substring(index, end)));
        index = end;
      } else if (path[index] == '.') {
        index++;
        final end = _propertyEnd(path, index);
        result.add(_JsonToken.property(path.substring(index, end)));
        index = end;
      } else if (path[index] == '[') {
        final end = _balancedEnd(path, index, '[', ']');
        result.add(_JsonToken.bracket(path.substring(index + 1, end)));
        index = end + 1;
      } else {
        final end = _propertyEnd(path, index);
        result.add(_JsonToken.property(path.substring(index, end)));
        index = end;
      }
    }
    return result.where((token) => token.value.isNotEmpty).toList();
  }

  static int _propertyEnd(String path, int start) {
    var index = start;
    while (index < path.length && path[index] != '.' && path[index] != '[') {
      index++;
    }
    return index;
  }

  static int _balancedEnd(String value, int start, String open, String close) {
    var depth = 0;
    String? quote;
    for (var i = start; i < value.length; i++) {
      final char = value[i];
      if (quote != null) {
        if (char == quote && value[i - 1] != r'\') quote = null;
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == open) {
        depth++;
      } else if (char == close && --depth == 0) {
        return i;
      }
    }
    throw FormatException('Unclosed JSONPath bracket: $value');
  }

  static List<dynamic> _apply(List<dynamic> values, _JsonToken token) {
    final result = <dynamic>[];
    for (final value in values) {
      switch (token.type) {
        case _JsonTokenType.property:
          _property(value, token.value, result);
        case _JsonTokenType.recursive:
          _recursive(value, token.value, result);
        case _JsonTokenType.bracket:
          _bracket(value, token.value, result);
      }
    }
    return result;
  }

  static void _property(dynamic value, String key, List<dynamic> result) {
    if (key == '*') {
      if (value is Map) result.addAll(value.values);
      if (value is List) result.addAll(value);
    } else if (value is Map && value.containsKey(key)) {
      result.add(value[key]);
    } else if (value is List) {
      for (final item in value) {
        if (item is Map && item.containsKey(key)) result.add(item[key]);
      }
    }
  }

  static void _recursive(dynamic value, String key, List<dynamic> result) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (key == '*' || '${entry.key}' == key) result.add(entry.value);
        _recursive(entry.value, key, result);
      }
    } else if (value is List) {
      for (final item in value) {
        _recursive(item, key, result);
      }
    }
  }

  static void _bracket(dynamic value, String expression, List<dynamic> result) {
    final expr = expression.trim();
    if (expr == '*') {
      _property(value, '*', result);
      return;
    }
    if (expr.startsWith('?(') && expr.endsWith(')') && value is List) {
      final filter = expr.substring(2, expr.length - 1);
      result.addAll(value.where((item) => _matches(item, filter)));
      return;
    }
    if (expr.contains(':') && value is List) {
      result.addAll(_slice(value, expr));
      return;
    }
    final parts = _splitComma(expr);
    for (final part in parts) {
      final normalized = part.trim().replaceAll(RegExp(r'''^['"]|['"]$'''), '');
      final index = int.tryParse(normalized);
      if (index != null && value is List) {
        final fixed = index < 0 ? value.length + index : index;
        if (fixed >= 0 && fixed < value.length) result.add(value[fixed]);
      } else {
        _property(value, normalized, result);
      }
    }
  }

  static List<String> _splitComma(String value) {
    final result = <String>[];
    var start = 0;
    String? quote;
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (quote != null) {
        if (char == quote && value[i - 1] != r'\') quote = null;
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char == ',') {
        result.add(value.substring(start, i));
        start = i + 1;
      }
    }
    result.add(value.substring(start));
    return result;
  }

  static Iterable<dynamic> _slice(
      List<dynamic> value, String expression) sync* {
    final parts = expression.split(':');
    var start = int.tryParse(parts.first) ?? 0;
    var end = parts.length > 1 && parts[1].isNotEmpty
        ? int.tryParse(parts[1]) ?? value.length
        : value.length;
    var step = parts.length > 2 ? int.tryParse(parts[2]) ?? 1 : 1;
    if (step == 0) step = 1;
    if (start < 0) start += value.length;
    if (end < 0) end += value.length;
    if (step > 0) {
      start = start.clamp(0, value.length);
      end = end.clamp(0, value.length);
      for (var i = start; i < end; i += step) {
        yield value[i];
      }
    } else {
      start = start.clamp(0, value.length - 1);
      end = end.clamp(-1, value.length - 1);
      for (var i = start; i > end; i += step) {
        yield value[i];
      }
    }
  }

  static bool _matches(dynamic item, String expression) {
    final match = RegExp(
      r'''^\s*@(?:\.([A-Za-z0-9_\-$]+)|\[['"]([^'"]+)['"]\])\s*(?:(==|!=|>=|<=|>|<|=~)\s*(.+))?\s*$''',
    ).firstMatch(expression);
    if (match == null) return false;
    final key = match.group(1) ?? match.group(2)!;
    final actual = item is Map ? item[key] : null;
    final op = match.group(3);
    if (op == null) return actual != null && actual != false;
    final expectedText = match.group(4)!.trim();
    if (op == '=~') {
      final regex = RegExp(r'^/(.*?)/([ims]*)$').firstMatch(expectedText);
      if (regex == null) return false;
      return RegExp(
        regex.group(1)!,
        caseSensitive: !regex.group(2)!.contains('i'),
        multiLine: regex.group(2)!.contains('m'),
        dotAll: regex.group(2)!.contains('s'),
      ).hasMatch('$actual');
    }
    final expected = _literal(expectedText);
    return switch (op) {
      '==' => actual == expected || '$actual' == '$expected',
      '!=' => actual != expected && '$actual' != '$expected',
      '>' => _number(actual) > _number(expected),
      '<' => _number(actual) < _number(expected),
      '>=' => _number(actual) >= _number(expected),
      '<=' => _number(actual) <= _number(expected),
      _ => false,
    };
  }

  static dynamic _literal(String value) {
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }
    if (value == 'true') return true;
    if (value == 'false') return false;
    if (value == 'null') return null;
    return num.tryParse(value) ?? value;
  }

  static num _number(dynamic value) =>
      value is num ? value : num.tryParse('$value') ?? 0;
}

enum _JsonTokenType { property, recursive, bracket }

class _JsonToken {
  final _JsonTokenType type;
  final String value;

  const _JsonToken(this.type, this.value);
  const _JsonToken.property(String value)
      : this(_JsonTokenType.property, value);
  const _JsonToken.recursive(String value)
      : this(_JsonTokenType.recursive, value);
  const _JsonToken.bracket(String value) : this(_JsonTokenType.bracket, value);
}
