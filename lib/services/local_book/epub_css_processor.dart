/// EPUB CSS 规则
///
/// 移植自 JRead/Legado 的 EpubCss.kt Rule 数据类。
class EpubCssRule {
  final String selector;
  final List<EpubCssDeclaration> declarations;
  final int specificity;
  final int order;

  EpubCssRule({
    required this.selector,
    required this.declarations,
    required this.specificity,
    required this.order,
  });
}

/// EPUB CSS 声明
///
/// 移植自 JRead/Legado 的 EpubCss.kt Declaration 数据类。
class EpubCssDeclaration {
  final String name;
  final String value;
  final bool important;
  final int order;

  EpubCssDeclaration({
    required this.name,
    required this.value,
    required this.important,
    required this.order,
  });

  EpubCssDeclaration copyWith({
    String? name,
    String? value,
    bool? important,
    int? order,
  }) {
    return EpubCssDeclaration(
      name: name ?? this.name,
      value: value ?? this.value,
      important: important ?? this.important,
      order: order ?? this.order,
    );
  }
}

/// EPUB CSS 解析器
///
/// 移植自 JRead/Legado 的 EpubCss.kt，用结构化解析替换正则拼接。
///
/// 核心能力：
/// 1. CSS 规则解析（选择器 + 声明块）
/// 2. shorthand 展开（font/margin/padding/border/background 等）
/// 3. @media/@supports 拍平（嵌套规则展开为顶层）
/// 4. 选择器净化（剥离 :hover 等不支持伪类）
/// 5. duokan-text-indent 兼容（映射为 text-indent）
/// 6. supportedProperties 白名单过滤
///
/// 与原始正则方案的区别：
/// - 正则方案在 margin: 45% auto 20% auto 上只替换第一个百分比
/// - 本解析器先展开 shorthand 为 margin-top/margin-right/margin-bottom/margin-left，
///   再逐个属性做值改写，不会遗漏
class EpubCssProcessor {
  EpubCssProcessor._();

  /// 解析 CSS 文本为规则列表
  ///
  /// 步骤：
  /// 1. 移除注释
  /// 2. 展开 @media/@supports
  /// 3. 逐规则解析选择器 + 声明块
  /// 4. 展开 shorthand 属性
  /// 5. 过滤 supportedProperties 白名单
  static List<EpubCssRule> parseRules(String css) {
    if (css.trim().isEmpty) return [];

    // 1. 移除注释
    var cleanCss = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

    // 2. 展开 @media/@supports
    cleanCss = _expandSupportedAtRules(cleanCss);

    final rules = <EpubCssRule>[];
    var order = 0;
    var index = 0;

    while (index < cleanCss.length) {
      final start = cleanCss.indexOf('{', index);
      if (start < 0) break;
      final end = _findMatchingBrace(cleanCss, start);
      if (end < 0) break;

      final selectorText = cleanCss.substring(index, start).trim();

      // @keyframes 等：含嵌套块，parseDeclarations 无法处理，跳过
      // （之前被 _expandSupportedAtRules 丢弃，此处保持不处理）
      if (selectorText.startsWith('@keyframes') ||
          selectorText.startsWith('@-webkit-keyframes') ||
          selectorText.startsWith('@font-feature-values')) {
        index = end + 1;
        continue;
      }

      // @font-face：保留全部声明（含 src，不在白名单中），跳过选择器净化
      if (selectorText.startsWith('@font-face')) {
        final declarations = _parseDeclarations(cleanCss.substring(start + 1, end));
        if (declarations.isNotEmpty) {
          rules.add(EpubCssRule(
            selector: selectorText,
            declarations: declarations,
            specificity: 0,
            order: order,
          ));
          order++;
        }
        index = end + 1;
        continue;
      }

      final declarations = _parseDeclarations(cleanCss.substring(start + 1, end))
          .where((d) => _supportedProperties.contains(d.name))
          .toList();
      if (declarations.isNotEmpty) {
        for (final selector in selectorText.split(',')) {
          final trimmed = selector.trim();
          final supported = _toSupportedSelector(trimmed);
          if (supported != null && supported.isNotEmpty) {
            rules.add(EpubCssRule(
              selector: supported,
              declarations: declarations,
              specificity: _cssSpecificity(supported),
              order: order,
            ));
          }
        }
        order++;
      }
      index = end + 1;
    }

    return rules;
  }

  /// 将规则列表序列化回 CSS 文本
  static String serialize(List<EpubCssRule> rules) {
    final buf = StringBuffer();
    for (final rule in rules) {
      if (rule.declarations.isEmpty) continue;
      buf.write(rule.selector);
      buf.write(' { ');
      for (final decl in rule.declarations) {
        buf.write(decl.name);
        buf.write(': ');
        buf.write(decl.value);
        if (decl.important) buf.write(' !important');
        buf.write('; ');
      }
      buf.write('}\n');
    }
    return buf.toString();
  }

  /// 解析声明块字符串为 Declaration 列表（含 shorthand 展开）
  static List<EpubCssDeclaration> _parseDeclarations(String style) {
    final declarations = <EpubCssDeclaration>[];
    for (final item in _splitDeclarations(style)) {
      final colonIndex = item.indexOf(':');
      if (colonIndex <= 0) continue;

      final name = item.substring(0, colonIndex).trim().toLowerCase();
      var rawValue = item.substring(colonIndex + 1);

      // 处理 !important
      final importantIndex = rawValue.toLowerCase().indexOf('!important');
      final important = importantIndex >= 0;
      if (importantIndex >= 0) {
        rawValue = rawValue.substring(0, importantIndex);
      }
      final value = rawValue.trim().replaceAll('"', "'");

      if (name.isEmpty || value.isEmpty) continue;

      // duokan-text-indent 兼容
      final normalizedName = name == 'duokan-text-indent' ? 'text-indent' : name;

      declarations.add(EpubCssDeclaration(
        name: normalizedName,
        value: value,
        important: important,
        order: declarations.length,
      ));
    }

    // 展开 shorthand
    return declarations
        .map(_expandFontShorthand)
        .expand((d) => d)
        .map(_expandBoxShorthand)
        .expand((d) => d)
        .map(_expandBorderShorthand)
        .expand((d) => d)
        .map(_expandBorderRadiusShorthand)
        .expand((d) => d)
        .map(_expandBackgroundShorthand)
        .expand((d) => d)
        .map(_expandListStyleShorthand)
        .expand((d) => d)
        .map(_expandTextDecorationShorthand)
        .expand((d) => d)
        .toList();
  }

  // ============ @media/@supports 展开 ============

  static String _expandSupportedAtRules(String css) {
    final buf = StringBuffer();
    var index = 0;

    while (index < css.length) {
      final at = css.indexOf('@', index);
      if (at < 0) {
        buf.write(css.substring(index));
        break;
      }
      buf.write(css.substring(index, at));

      final nameEnd = css.indexOf(RegExp(r'[\s\t\r\n{;]'), at + 1);
      final actualNameEnd = nameEnd >= 0 ? nameEnd : css.length;
      final name = css.substring(at + 1, actualNameEnd).trim().toLowerCase();

      final blockStart = css.indexOf('{', actualNameEnd);
      final semicolon = css.indexOf(';', actualNameEnd);

      if (blockStart < 0 || (semicolon >= 0 && semicolon < blockStart)) {
        index = (semicolon >= 0 ? semicolon : actualNameEnd) + 1;
        continue;
      }

      final blockEnd = _findMatchingBrace(css, blockStart);
      if (blockEnd < 0) break;

      // media/supports：展开内部规则到顶层
      if (name == 'media' || name == 'supports') {
        buf.write(css.substring(blockStart + 1, blockEnd));
      } else if (name == 'font-face' || name == 'keyframes' ||
          name == 'font-feature-values') {
        // @font-face / @keyframes / @font-feature-values：原样保留
        // 这些 at-rule 含特殊声明（src/font-family 等），不能被白名单过滤
        buf.write(css.substring(at, blockEnd + 1));
        buf.write('\n');
      }
      // @page：跳过（reader 无效）
      // @import：在 EpubPublisherStyles 中处理

      index = blockEnd + 1;
    }

    return buf.toString();
  }

  // ============ 选择器处理 ============

  /// 净化选择器：剥离不支持的伪类，转换命名空间
  static String? _toSupportedSelector(String selector) {
    var s = selector.trim();
    s = _dropUnsupportedPseudo(s);
    s = s.replaceAll('|', r'\:');
    if (s.isEmpty) return null;
    // 排除含 { } ; 的无效选择器
    if (RegExp(r'[{};]').hasMatch(s)) return null;
    return s;
  }

  /// 剥离不支持的选择器伪类（:hover, :nth-child 等）
  ///
  /// 保留 ::before / ::after / :before / :after 伪元素（WebView 原生支持，
  /// 配合 content 属性实现装饰文字、首字下沉等效果）。
  /// 保留 :first-child / :last-child / :first-of-type / :last-of-type /
  /// :only-child / :only-of-type（WebView 原生支持，用于首尾段间距控制）。
  static String _dropUnsupportedPseudo(String selector) {
    final buf = StringBuffer();
    var index = 0;
    var bracketDepth = 0;

    /// WebView 原生支持的伪类/伪元素白名单
    const supportedPseudos = {
      'before', 'after', 'first-line', 'first-letter',
      'first-child', 'last-child', 'first-of-type', 'last-of-type',
      'only-child', 'only-of-type', 'root', 'empty',
      'placeholder', 'selection',
    };

    while (index < selector.length) {
      final char = selector[index];
      if (char == '[') {
        bracketDepth++;
        buf.write(char);
        index++;
      } else if (char == ']') {
        if (bracketDepth > 0) bracketDepth--;
        buf.write(char);
        index++;
      } else if (char == ':' && bracketDepth == 0) {
        // 检查是否为双冒号伪元素 ::before
        final isDoubleColon = index + 1 < selector.length &&
            selector[index + 1] == ':';
        final nameStart = isDoubleColon ? index + 2 : index + 1;
        var nameEnd = nameStart;
        while (nameEnd < selector.length &&
            RegExp(r'[a-zA-Z0-9\-_]').hasMatch(selector[nameEnd])) {
          nameEnd++;
        }
        final pseudoName = selector
            .substring(nameStart, nameEnd)
            .toLowerCase();
        if (supportedPseudos.contains(pseudoName)) {
          // 保留支持的伪类/伪元素
          buf.write(isDoubleColon ? '::' : ':');
          buf.write(selector.substring(nameStart, nameEnd));
          index = nameEnd;
        } else {
          // 跳过不支持的伪类名
          index = nameEnd;
          // 跳过伪类参数 (...)
          if (index < selector.length && selector[index] == '(') {
            final end = _findMatchingParen(selector, index);
            index = end >= 0 ? end + 1 : selector.length;
          }
        }
      } else {
        buf.write(char);
        index++;
      }
    }

    return buf.toString().trim();
  }

  /// 计算选择器特异性（ID*100 + class*10 + tag）
  static int _cssSpecificity(String selector) {
    final ids = '#'.allMatches(selector).length;
    final classes = '.'.allMatches(selector).length +
        '['.allMatches(selector).length;
    final tags = selector
        .split(RegExp(r'[\s>+~]+'))
        .where((part) =>
            part.isNotEmpty &&
            !part.startsWith('.') &&
            !part.startsWith('#') &&
            part != '*')
        .length;
    return ids * 100 + classes * 10 + tags;
  }

  // ============ shorthand 展开 ============

  /// 展开 font shorthand
  ///
  /// CSS font shorthand 语法：
  /// `font: font-style font-variant font-weight font-stretch font-size/line-height font-family`
  /// 旧实现只展开 style/weight/size/line-height/family，丢失 variant/stretch。
  static List<EpubCssDeclaration> _expandFontShorthand(EpubCssDeclaration decl) {
    final expanded = [decl];
    if (decl.name != 'font') return expanded;

    final tokens = _splitValueList(decl.value);
    var sizeIndex = -1;

    for (var i = 0; i < tokens.length; i++) {
      final lower = tokens[i].toLowerCase();
      if (lower == 'italic' || lower == 'oblique') {
        expanded.add(decl.copyWith(
            name: 'font-style', value: lower, order: expanded.length));
      } else if (lower == 'small-caps' ||
          lower == 'all-small-caps' || lower == 'petite-caps' ||
          lower == 'all-petite-caps' || lower == 'unicase' ||
          lower == 'titling-caps') {
        expanded.add(decl.copyWith(
            name: 'font-variant', value: lower, order: expanded.length));
      } else if (lower == 'bold' ||
          lower == 'bolder' ||
          lower == 'lighter' ||
          lower == 'normal' ||
          int.tryParse(lower) != null) {
        expanded.add(decl.copyWith(
            name: 'font-weight', value: lower, order: expanded.length));
      } else if (_fontStretchKeywords.contains(lower)) {
        expanded.add(decl.copyWith(
            name: 'font-stretch', value: lower, order: expanded.length));
      } else if (sizeIndex < 0 && _containsFontSizeToken(lower)) {
        sizeIndex = i;
        final parts = lower.split('/');
        expanded.add(decl.copyWith(
            name: 'font-size', value: parts[0], order: expanded.length));
        if (parts.length > 1 && parts[1].isNotEmpty) {
          expanded.add(decl.copyWith(
              name: 'line-height', value: parts[1], order: expanded.length));
        }
      }
    }

    if (sizeIndex >= 0 && sizeIndex + 1 < tokens.length) {
      expanded.add(decl.copyWith(
          name: 'font-family',
          value: tokens.sublist(sizeIndex + 1).join(' '),
          order: expanded.length));
    }

    return expanded;
  }

  static const _fontStretchKeywords = {
    'ultra-condensed', 'extra-condensed', 'condensed',
    'semi-condensed', 'normal', 'semi-expanded', 'expanded',
    'extra-expanded', 'ultra-expanded',
  };

  /// 展开 margin/padding shorthand → top/right/bottom/left
  static List<EpubCssDeclaration> _expandBoxShorthand(EpubCssDeclaration decl) {
    final expanded = [decl];
    if (decl.name != 'margin' && decl.name != 'padding') return expanded;

    final values = _splitValueList(decl.value);
    if (values.isEmpty) return expanded;

    final top = values[0];
    final right = values.length > 1 ? values[1] : top;
    final bottom = values.length > 2 ? values[2] : top;
    final left = values.length > 3 ? values[3] : right;

    expanded.add(decl.copyWith(
        name: '${decl.name}-top', value: top, order: expanded.length));
    expanded.add(decl.copyWith(
        name: '${decl.name}-right', value: right, order: expanded.length));
    expanded.add(decl.copyWith(
        name: '${decl.name}-bottom', value: bottom, order: expanded.length));
    expanded.add(decl.copyWith(
        name: '${decl.name}-left', value: left, order: expanded.length));

    return expanded;
  }

  /// 展开 border shorthand
  static List<EpubCssDeclaration> _expandBorderShorthand(EpubCssDeclaration decl) {
    final expanded = [decl];
    final sides = switch (decl.name) {
      'border' => ['top', 'right', 'bottom', 'left'],
      'border-top' => ['top'],
      'border-right' => ['right'],
      'border-bottom' => ['bottom'],
      'border-left' => ['left'],
      _ => <String>[],
    };
    if (sides.isEmpty) return expanded;

    final tokens = _splitValueList(decl.value);
    final width = tokens
        .where((t) => _isCssLengthToken(t) || _borderWidthKeywords.contains(t))
        .firstOrNull;
    final style = tokens
        .where((t) => _borderStyles.contains(t.toLowerCase()))
        .firstOrNull;
    final color = tokens.where(_isCssColorToken).firstOrNull;

    for (final side in sides) {
      if (width != null) {
        expanded.add(decl.copyWith(
            name: 'border-$side-width',
            value: width,
            order: expanded.length));
      }
      if (style != null) {
        expanded.add(decl.copyWith(
            name: 'border-$side-style',
            value: style,
            order: expanded.length));
      }
      if (color != null) {
        expanded.add(decl.copyWith(
            name: 'border-$side-color',
            value: color,
            order: expanded.length));
      }
    }

    return expanded;
  }

  /// 展开 border-radius shorthand
  static List<EpubCssDeclaration> _expandBorderRadiusShorthand(EpubCssDeclaration decl) {
    final expanded = [decl];
    if (decl.name != 'border-radius') return expanded;

    final beforeSlash = decl.value.split('/')[0];
    final values = _splitValueList(beforeSlash);
    if (values.isEmpty) return expanded;

    final topLeft = values[0];
    final topRight = values.length > 1 ? values[1] : topLeft;
    final bottomRight = values.length > 2 ? values[2] : topLeft;
    final bottomLeft = values.length > 3 ? values[3] : topRight;

    expanded.add(decl.copyWith(
        name: 'border-top-left-radius',
        value: topLeft,
        order: expanded.length));
    expanded.add(decl.copyWith(
        name: 'border-top-right-radius',
        value: topRight,
        order: expanded.length));
    expanded.add(decl.copyWith(
        name: 'border-bottom-right-radius',
        value: bottomRight,
        order: expanded.length));
    expanded.add(decl.copyWith(
        name: 'border-bottom-left-radius',
        value: bottomLeft,
        order: expanded.length));

    return expanded;
  }

  /// 展开 background shorthand
  static List<EpubCssDeclaration> _expandBackgroundShorthand(EpubCssDeclaration decl) {
    final expanded = [decl];
    if (decl.name != 'background') return expanded;

    final color = _extractCssColor(decl.value);
    if (color != null) {
      expanded.add(decl.copyWith(
          name: 'background-color', value: color, order: expanded.length));
    }

    final url = _extractCssUrl(decl.value);
    if (url != null) {
      expanded.add(decl.copyWith(
          name: 'background-image',
          value: "url('$url')",
          order: expanded.length));
    }

    final tokens = _splitValueList(decl.value);

    // 处理 position / size（CSS3 background shorthand: "position / size"）
    // 例：background: url(...) center/cover → position=center, size=cover
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (token.contains('/')) {
        final parts = token.split('/');
        if (parts.length == 2) {
          expanded.add(decl.copyWith(
              name: 'background-position',
              value: parts[0].trim(),
              order: expanded.length));
          if (parts[1].isNotEmpty) {
            expanded.add(decl.copyWith(
                name: 'background-size',
                value: parts[1].trim(),
                order: expanded.length));
          }
          continue;
        }
      }
      if (_backgroundRepeatTokens.contains(token.toLowerCase())) {
        expanded.add(decl.copyWith(
            name: 'background-repeat',
            value: token,
            order: expanded.length));
      } else if (_backgroundSizeTokens.contains(token.toLowerCase())) {
        expanded.add(decl.copyWith(
            name: 'background-size',
            value: token,
            order: expanded.length));
      } else if (_backgroundAttachmentTokens.contains(token.toLowerCase())) {
        expanded.add(decl.copyWith(
            name: 'background-attachment',
            value: token,
            order: expanded.length));
      } else if (_backgroundPositionTokens.contains(token.toLowerCase())) {
        // 单个 position keyword（center/top/bottom/left/right）
        expanded.add(decl.copyWith(
            name: 'background-position',
            value: token,
            order: expanded.length));
      }
    }

    // 检测相邻的 position keyword 对（如 "top center" / "left top"）
    for (var i = 0; i < tokens.length - 1; i++) {
      final t1 = tokens[i].toLowerCase();
      final t2 = tokens[i + 1].toLowerCase();
      if (_backgroundPositionTokens.contains(t1) &&
          _backgroundPositionTokens.contains(t2)) {
        expanded.add(decl.copyWith(
            name: 'background-position',
            value: '${tokens[i]} ${tokens[i + 1]}',
            order: expanded.length));
        break;
      }
    }

    return expanded;
  }

  /// 展开 list-style shorthand
  static List<EpubCssDeclaration> _expandListStyleShorthand(EpubCssDeclaration decl) {
    final expanded = [decl];
    if (decl.name != 'list-style') return expanded;

    final tokens = _splitValueList(decl.value);
    for (final token in tokens) {
      final lower = token.toLowerCase();
      if (_listStyleTypes.contains(lower)) {
        expanded.add(decl.copyWith(
            name: 'list-style-type', value: token, order: expanded.length));
      } else if (_listStylePositions.contains(lower)) {
        expanded.add(decl.copyWith(
            name: 'list-style-position',
            value: token,
            order: expanded.length));
      }
    }

    return expanded;
  }

  /// 展开 text-decoration shorthand
  static List<EpubCssDeclaration> _expandTextDecorationShorthand(EpubCssDeclaration decl) {
    final expanded = [decl];
    if (decl.name != 'text-decoration') return expanded;

    final tokens = _splitValueList(decl.value);
    final lines = tokens
        .where((t) => _textDecorationLines.contains(t.toLowerCase()))
        .join(' ');
    if (lines.isNotEmpty) {
      expanded.add(decl.copyWith(
          name: 'text-decoration-line',
          value: lines,
          order: expanded.length));
    }

    return expanded;
  }

  // ============ 工具方法 ============

  static String? _extractCssUrl(String value) {
    final start = value.toLowerCase().indexOf('url(');
    if (start < 0) return null;
    final end = value.indexOf(')', start + 4);
    if (end < 0) return null;
    final raw =
        value.substring(start + 4, end).trim().replaceAll("'", '').replaceAll('"', '').trim();
    if (raw.isEmpty || raw.toLowerCase() == 'none') return null;
    return raw;
  }

  static String? _extractCssColor(String value) {
    final clean = value.trim();
    if (clean.startsWith('#') || clean.toLowerCase().startsWith('rgb')) {
      return clean;
    }
    for (final token in _splitValueList(clean)) {
      if (_isCssColorToken(token)) return token;
    }
    return null;
  }

  static bool _containsFontSizeToken(String value) {
    final sizePart = value.split('/')[0];
    return _isCssLengthToken(sizePart) ||
        sizePart.endsWith('%') ||
        _fontSizeKeywords.contains(sizePart) ||
        double.tryParse(sizePart) != null;
  }

  static bool _isCssLengthToken(String value) {
    final lower = value.toLowerCase();
    return lower.endsWith('px') ||
        lower.endsWith('em') ||
        lower.endsWith('rem') ||
        lower.endsWith('pt') ||
        lower.endsWith('pc') ||
        lower.endsWith('in') ||
        lower.endsWith('cm') ||
        lower.endsWith('mm') ||
        lower.endsWith('vw') ||
        lower.endsWith('vh');
  }

  static bool _isCssColorToken(String value) {
    final lower = value.toLowerCase();
    return lower.startsWith('#') ||
        lower.startsWith('rgb') ||
        lower == 'transparent' ||
        _namedColors.contains(lower);
  }

  /// 按空格分割 CSS 值列表（尊重引号和括号）
  static List<String> _splitValueList(String value) {
    final result = <String>[];
    String? quote;
    var parenDepth = 0;
    var start = 0;

    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (quote != null) {
        if (char == quote && (i == 0 || value[i - 1] != r'\')) {
          quote = null;
        }
        continue;
      }
      if (char == "'" || char == '"') {
        quote = char;
      } else if (char == '(') {
        parenDepth++;
      } else if (char == ')') {
        if (parenDepth > 0) parenDepth--;
      } else if (char == ' ' ||
          char == '\t' ||
          char == '\r' ||
          char == '\n') {
        if (parenDepth == 0) {
          final part = value.substring(start, i).trim();
          if (part.isNotEmpty) result.add(part);
          start = i + 1;
        }
      }
    }
    final last = value.substring(start).trim();
    if (last.isNotEmpty) result.add(last);
    return result;
  }

  /// 按分号分割 CSS 声明（尊重引号和括号）
  static List<String> _splitDeclarations(String style) {
    final result = <String>[];
    String? quote;
    var parenDepth = 0;
    var start = 0;

    for (var i = 0; i < style.length; i++) {
      final char = style[i];
      if (quote != null) {
        if (char == quote && (i == 0 || style[i - 1] != r'\')) {
          quote = null;
        }
        continue;
      }
      if (char == "'" || char == '"') {
        quote = char;
      } else if (char == '(') {
        parenDepth++;
      } else if (char == ')') {
        if (parenDepth > 0) parenDepth--;
      } else if (char == ';' && parenDepth == 0) {
        result.add(style.substring(start, i));
        start = i + 1;
      }
    }
    if (start <= style.length - 1) {
      result.add(style.substring(start));
    }
    return result;
  }

  /// 找匹配的闭合大括号
  static int _findMatchingBrace(String css, int start) {
    var depth = 0;
    String? quote;
    for (var i = start; i < css.length; i++) {
      final char = css[i];
      if (quote != null) {
        if (char == quote && (i == 0 || css[i - 1] != r'\')) {
          quote = null;
        }
        continue;
      }
      if (char == "'" || char == '"') {
        quote = char;
      } else if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  /// 找匹配的闭合小括号
  static int _findMatchingParen(String str, int start) {
    var depth = 0;
    String? quote;
    for (var i = start; i < str.length; i++) {
      final char = str[i];
      if (quote != null) {
        if (char == quote && (i == 0 || str[i - 1] != r'\')) {
          quote = null;
        }
        continue;
      }
      if (char == "'" || char == '"') {
        quote = char;
      } else if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  // ============ 常量 ============

  /// 支持的 CSS 属性白名单
  /// ★ 1:1 对齐多看阅读器 libddlayoutkit.so 支持的 CSS 属性清单 ★
  ///
  /// 多看二进制中提取到的完整 CSS 属性集合（87 个标准属性 + 1 个 EPUB 归一化属性）。
  /// 逆向来源：libddlayoutkit.so 的 .rodata 段 CSS 属性名字符串表。
  /// 多看阅读器原生支持这些属性，WebView 也全部原生支持，无需特殊处理。
  ///
  /// 分类（按多看二进制中的字符串顺序）：
  /// - 文本：color/text-align/text-indent/text-decoration/text-shadow/
  ///   text-transform/text-overflow/text-justify/text-wrap
  /// - 字体：font/font-family/font-size/font-style/font-weight
  /// - 行距字距：line-height/letter-spacing/word-spacing/word-break/word-wrap/
  ///   overflow-wrap/hyphens/tab-size
  /// - 背景：background/background-color/background-image/background-repeat/
  ///   background-position/background-size/background-attachment/background-clip/
  ///   background-origin
  /// - 边框：border/border-*/border-radius/border-collapse/border-spacing
  /// - 盒模型：margin/margin-*/padding/padding-*/width/height/min-*/max-*/
  ///   box-shadow/box-sizing/box-model
  /// - 定位：position/top/right/bottom/left/z-index/clear/float/vertical-align
  /// - 溢出：overflow/overflow-x/overflow-y
  /// - 显示：display/visibility/opacity/overflow
  /// - 分页：page-break-before/page-break-after/page-break-inside/
  ///   break-before/break-after/break-inside
  /// - 多栏：column-count/column-gap/column-width/column-rule
  /// - 弹性盒：flex/flex-direction/flex-wrap/flex-flow/justify-content/
  ///   align-items/align-content/align-self/order/flex-grow/flex-shrink/flex-basis
  /// - 列表：list-style/list-style-type/list-style-position/list-style-image
  /// - 表格：table-layout/caption-side/empty-cells
  /// - 轮廓：outline/outline-width/outline-style/outline-color
  /// - 内容：content/quotes/counter-reset/counter-increment
  /// - 变换：transform/transform-origin/transition
  /// - 书写方向：direction/unicode-bidi/writing-mode
  /// - 滚动捕捉：scroll-snap-type/scroll-snap-align
  /// - 对象适配：object-fit/object-position
  /// - 其他：cursor
  static const _supportedProperties = {
    // === 文本 ===
    'color', 'text-align', 'text-decoration', 'text-decoration-line',
    'text-decoration-color', 'text-decoration-style', 'text-decoration-thickness',
    'text-indent', 'text-transform', 'text-shadow', 'text-overflow',
    'text-justify', 'text-wrap', 'white-space', 'word-spacing',
    // === 字体 ===
    'font', 'font-family', 'font-size', 'font-style', 'font-weight',
    'font-variant', 'font-stretch', 'font-feature-settings', 'font-kerning',
    'font-variant-ligatures', 'font-variant-caps', 'font-variant-numeric',
    // === 行距字距 ===
    'line-height', 'letter-spacing', 'word-break',
    'word-wrap', 'overflow-wrap', 'hyphens', 'tab-size',
    // === 背景 ===
    'background', 'background-color', 'background-image',
    'background-repeat', 'background-position', 'background-size',
    'background-attachment', 'background-clip', 'background-origin',
    // === 边框 ===
    'border', 'border-top', 'border-right', 'border-bottom', 'border-left',
    'border-width', 'border-style', 'border-color',
    'border-top-width', 'border-top-style', 'border-top-color',
    'border-right-width', 'border-right-style', 'border-right-color',
    'border-bottom-width', 'border-bottom-style', 'border-bottom-color',
    'border-left-width', 'border-left-style', 'border-left-color',
    'border-radius', 'border-top-left-radius', 'border-top-right-radius',
    'border-bottom-left-radius', 'border-bottom-right-radius',
    'border-collapse', 'border-spacing',
    // === 盒模型 ===
    'margin', 'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
    'padding', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
    'width', 'height', 'max-width', 'max-height', 'min-width', 'min-height',
    'box-shadow', 'box-sizing', 'box-model',
    // === 定位 ===
    'position', 'top', 'right', 'bottom', 'left', 'z-index',
    'clear', 'float', 'vertical-align',
    // === 溢出 ===
    'overflow', 'overflow-x', 'overflow-y',
    // === 显示 ===
    'display', 'visibility', 'opacity',
    // === 分页 ===
    'page-break-before', 'page-break-after', 'page-break-inside',
    'break-before', 'break-after', 'break-inside',
    // === 多栏 ===
    'column-count', 'column-gap', 'column-width', 'column-rule',
    // === 弹性盒 ===
    'flex', 'flex-direction', 'flex-wrap', 'flex-flow',
    'justify-content', 'align-items', 'align-content', 'align-self',
    'order', 'flex-grow', 'flex-shrink', 'flex-basis',
    // === 列表 ===
    'list-style', 'list-style-type', 'list-style-position', 'list-style-image',
    // === 表格 ===
    'table-layout', 'caption-side', 'empty-cells',
    // === 轮廓 ===
    'outline', 'outline-width', 'outline-style', 'outline-color',
    // === 内容 ===
    'content', 'quotes', 'counter-reset', 'counter-increment',
    // === 变换 ===
    'transform', 'transform-origin', 'transition',
    // === 书写方向 ===
    'direction', 'unicode-bidi', 'writing-mode',
    // === 滚动捕捉 ===
    'scroll-snap-type', 'scroll-snap-align',
    // === 对象适配 ===
    'object-fit', 'object-position',
    // === 其他 ===
    'cursor',
    // === EPUB 特有（已归一化） ===
    // 借鉴多看 libdkkernel.so 的 CSS_DECLNAME_TYPE 注册表（FUN_002cfca8），
    // 支持多看私有 CSS 属性，避免被白名单过滤丢弃。
    // 这些属性在 WebView 中会作为未知属性被忽略，但保留在 CSS 中
    // 可供阅读器的 JS 层做自定义渲染（如 duokan-drop-caps-style 首字下沉）。
    'duokan-text-indent', 'src', 'unicode-range',
    // 多看私有属性（从 FUN_002cfca8 反编译提取）
    'duokan-text-decoration-width', 'duokan-text-decoration-color',
    'duokan-border-length-topleft', 'duokan-border-length-topright',
    'duokan-border-length-righttop', 'duokan-border-length-rightbottom',
    'duokan-border-length-bottomleft', 'duokan-border-length-bottomright',
    'duokan-border-length-lefttop', 'duokan-border-length-leftbottom',
    'duokan-list-image-width', 'duokan-list-image-height',
    'duokan-list-style-char', 'duokan-list-start',
    'duokan-polygon-left', 'duokan-polygon-right',
    'duokan-drop-caps-style', 'duokan-bleed',
    'duokan-divide-type', 'duokan-divide-style',
    'duokan-divide-line', 'duokan-divide-ratio',
    'duokan-hanging-style',
  };

  static const _borderStyles = {
    'none', 'hidden', 'dotted', 'dashed', 'solid', 'double',
    'groove', 'ridge', 'inset', 'outset',
  };

  static const _borderWidthKeywords = {'thin', 'medium', 'thick'};

  static const _backgroundRepeatTokens = {
    'repeat', 'no-repeat', 'repeat-x', 'repeat-y',
  };

  static const _backgroundSizeTokens = {
    'cover', 'contain', 'auto',
  };

  static const _backgroundAttachmentTokens = {
    'fixed', 'scroll', 'local',
  };

  static const _backgroundPositionTokens = {
    'left', 'right', 'top', 'bottom', 'center',
  };

  static const _listStylePositions = {'inside', 'outside'};

  static const _listStyleTypes = {
    'none', 'disc', 'circle', 'square', 'decimal',
    'lower-alpha', 'upper-alpha', 'lower-latin', 'upper-latin',
    'lower-roman', 'upper-roman',
  };

  static const _textDecorationLines = {
    'none', 'underline', 'overline', 'line-through',
  };

  static const _fontSizeKeywords = {
    'xx-small', 'x-small', 'small', 'medium', 'large',
    'x-large', 'xx-large', 'smaller', 'larger',
  };

  /// CSS 命名颜色表
  ///
  /// 借鉴多看 libdkkernel.so 的颜色名注册表（FUN_0029fd94），
  /// 包含 CSS Level 1/2/3 的全部 140 个命名颜色。
  /// WebView 原生支持这些颜色名的渲染，此处仅用于颜色值识别。
  static const _namedColors = {
    // CSS Level 1（16 基础色 + orange）
    'black', 'white', 'red', 'green', 'blue', 'cyan', 'aqua',
    'magenta', 'fuchsia', 'yellow', 'gray', 'grey', 'silver',
    'maroon', 'purple', 'teal', 'navy', 'orange',
    // CSS Level 2 扩展（新增）
    'lime', 'olive',
    // CSS Level 3 — 粉色系
    'pink', 'lightpink', 'hotpink', 'deeppink', 'palevioletred',
    'mediumvioletred',
    // 红色系
    'lightsalmon', 'salmon', 'darksalmon', 'lightcoral', 'indianred',
    'crimson', 'firebrick', 'darkred',
    // 橙色系
    'coral', 'tomato', 'orangered', 'darkorange',
    // 黄色系
    'gold', 'khaki', 'darkkhaki', 'lemonchiffon', 'lightgoldenrodyellow',
    'lightyellow',
    // 绿色系
    'lawngreen', 'chartreuse', 'limegreen', 'forestgreen', 'darkgreen',
    'greenyellow', 'yellowgreen', 'springgreen', 'mediumspringgreen',
    'lightgreen', 'palegreen', 'darkseagreen', 'mediumseagreen',
    'seagreen', 'darkolivegreen', 'olivedrab',
    // 青色系
    'mediumaquamarine', 'aquamarine', 'turquoise', 'lightseagreen',
    'mediumturquoise', 'darkturquoise', 'cadetblue', 'darkcyan',
    // 蓝色系
    'lightsteelblue', 'powderblue', 'lightblue', 'skyblue',
    'lightskyblue', 'deepskyblue', 'dodgerblue', 'cornflowerblue',
    'steelblue', 'royalblue', 'mediumblue', 'darkblue',
    'midnightblue', 'lavender', 'thistle', 'plum', 'violet',
    'orchid', 'mediumorchid', 'darkorchid', 'darkviolet', 'blueviolet',
    'mediumpurple', 'mediumslateblue', 'slateblue', 'darkslateblue',
    'indigo',
    // 棕色系
    'cornsilk', 'blanchedalmond', 'bisque', 'navajowhite', 'wheat',
    'burlywood', 'tan', 'rosybrown', 'sandybrown', 'goldenrod',
    'darkgoldenrod', 'peru', 'chocolate', 'saddlebrown', 'sienna',
    'brown',
    // 白色系
    'snow', 'seashell', 'oldlace', 'floralwhite', 'ivory', 'azure',
    'mintcream', 'honeydew', 'aliceblue', 'ghostwhite', 'whitesmoke',
    'beige', 'linen', 'lavenderblush', 'mistyrose',
    // 灰色系
    'gainsboro', 'lightgray', 'lightgrey', 'darkgray',
    'darkgrey', 'dimgray', 'dimgrey', 'slategray',
    'slategrey', 'darkslategray', 'darkslategrey',
    // 透明
    'transparent',
  };
}
