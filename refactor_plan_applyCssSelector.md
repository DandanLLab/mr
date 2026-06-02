# 重构方案：消除 _applyCssSelector 方法中的重复代码模式

## 1. 问题分析

### 1.1 当前代码状态

在 `lib/services/source_engine/analyze_rule.dart` 文件的 `_applyCssSelector` 方法（263-318行）中，虽然已经提取了 `_extractAttribute`、`_extractText`、`_extractHtml`、`_extractOuterHtml` 等方法，但仍然存在重复的 List 和 Element 处理模式。

### 1.2 重复代码模式

以下模式在方法中重复出现了 4 次：

```dart
if (content is List) {
  return content.map((e) => _extractXxx(e)).toList();
}
return _extractXxx(content);
```

具体位置：
- **271-274行**：属性提取
  ```dart
  if (content is List) {
    return content.map((e) => _extractAttribute(e, attrName)).toList();
  }
  return _extractAttribute(content, attrName);
  ```

- **279-282行**：文本提取
  ```dart
  if (content is List) {
    return content.map((e) => _extractText(e)).toList();
  }
  return _extractText(content);
  ```

- **286-289行**：HTML提取
  ```dart
  if (content is List) {
    return content.map((e) => _extractHtml(e)).toList();
  }
  return _extractHtml(content);
  ```

- **293-296行**：outerHtml提取
  ```dart
  if (content is List) {
    return content.map((e) => _extractOuterHtml(e)).toList();
  }
  return _extractOuterHtml(content);
  ```

### 1.3 问题影响

1. **违反 DRY 原则**：相同的 List/Element 分发逻辑重复多次
2. **维护成本高**：如果需要修改分发逻辑（如添加日志、错误处理），需要在 4 个地方同步修改
3. **可读性降低**：核心逻辑被重复的分发代码掩盖

## 2. 重构方案

### 2.1 核心思路

提取一个通用的 `_applyExtractor` 方法，封装 List 和 Element 的分发逻辑，接收一个提取函数作为参数。

### 2.2 重构步骤

#### 步骤 1：添加通用分发方法

在 `_applyCssSelector` 方法之前添加以下方法：

```dart
/// 通用的内容提取分发方法
///
/// 根据 content 类型自动分发到 List 或单个元素处理
/// [content] 要处理的内容（可能是 List、Element 或其他类型）
/// [extractor] 提取函数，接收 Element 并返回提取结果
/// 返回提取结果（List<String> 或 String）
dynamic _applyExtractor(
  dynamic content,
  String Function(dynamic) extractor,
) {
  if (content is List) {
    return content.map((e) => extractor(e)).toList();
  }
  return extractor(content);
}
```

#### 步骤 2：重构 _applyCssSelector 方法

将原来的重复代码替换为调用 `_applyExtractor`：

```dart
dynamic _applyCssSelector(dynamic content, String selector, {bool isList = false}) {
  // 转换 legados 语法
  String cssSelector = _convertLegadoRule(selector);

  // 处理属性提取 @href, @src, @text 等
  if (cssSelector.startsWith('@')) {
    final attrName = cssSelector.substring(1);
    return _applyExtractor(content, (e) => _extractAttribute(e, attrName));
  }

  // 处理 text() 和 html()
  if (cssSelector == 'text' || cssSelector == 'text()') {
    return _applyExtractor(content, _extractText);
  }

  if (cssSelector == 'html' || cssSelector == 'html()') {
    return _applyExtractor(content, _extractHtml);
  }

  if (cssSelector == 'outerHtml') {
    return _applyExtractor(content, _extractOuterHtml);
  }

  // 处理选择器
  if (content is List) {
    final results = <dynamic>[];
    for (final item in content) {
      final elements = _selectElements(item, cssSelector);
      if (isList) {
        results.addAll(elements);
      } else if (elements.isNotEmpty) {
        results.add(elements.first);
      }
    }
    return results;
  }

  final elements = _selectElements(content, cssSelector);
  if (isList) {
    return elements;
  }
  return elements.isNotEmpty ? elements.first : null;
}
```

### 2.3 重构前后对比

#### 重构前（56行）

```dart
dynamic _applyCssSelector(dynamic content, String selector, {bool isList = false}) {
  String cssSelector = _convertLegadoRule(selector);

  // 处理属性提取 @href, @src, @text 等
  if (cssSelector.startsWith('@')) {
    final attrName = cssSelector.substring(1);

    if (content is List) {
      return content.map((e) => _extractAttribute(e, attrName)).toList();
    }
    return _extractAttribute(content, attrName);
  }

  // 处理 text() 和 html()
  if (cssSelector == 'text' || cssSelector == 'text()') {
    if (content is List) {
      return content.map((e) => _extractText(e)).toList();
    }
    return _extractText(content);
  }

  if (cssSelector == 'html' || cssSelector == 'html()') {
    if (content is List) {
      return content.map((e) => _extractHtml(e)).toList();
    }
    return _extractHtml(content);
  }

  if (cssSelector == 'outerHtml') {
    if (content is List) {
      return content.map((e) => _extractOuterHtml(e)).toList();
    }
    return _extractOuterHtml(content);
  }

  // 处理选择器
  if (content is List) {
    final results = <dynamic>[];
    for (final item in content) {
      final elements = _selectElements(item, cssSelector);
      if (isList) {
        results.addAll(elements);
      } else if (elements.isNotEmpty) {
        results.add(elements.first);
      }
    }
    return results;
  }

  final elements = _selectElements(content, cssSelector);
  if (isList) {
    return elements;
  }
  return elements.isNotEmpty ? elements.first : null;
}
```

#### 重构后（48行 + 11行辅助方法 = 59行）

```dart
/// 通用的内容提取分发方法
dynamic _applyExtractor(
  dynamic content,
  String Function(dynamic) extractor,
) {
  if (content is List) {
    return content.map((e) => extractor(e)).toList();
  }
  return extractor(content);
}

dynamic _applyCssSelector(dynamic content, String selector, {bool isList = false}) {
  String cssSelector = _convertLegadoRule(selector);

  // 处理属性提取 @href, @src, @text 等
  if (cssSelector.startsWith('@')) {
    final attrName = cssSelector.substring(1);
    return _applyExtractor(content, (e) => _extractAttribute(e, attrName));
  }

  // 处理 text() 和 html()
  if (cssSelector == 'text' || cssSelector == 'text()') {
    return _applyExtractor(content, _extractText);
  }

  if (cssSelector == 'html' || cssSelector == 'html()') {
    return _applyExtractor(content, _extractHtml);
  }

  if (cssSelector == 'outerHtml') {
    return _applyExtractor(content, _extractOuterHtml);
  }

  // 处理选择器
  if (content is List) {
    final results = <dynamic>[];
    for (final item in content) {
      final elements = _selectElements(item, cssSelector);
      if (isList) {
        results.addAll(elements);
      } else if (elements.isNotEmpty) {
        results.add(elements.first);
      }
    }
    return results;
  }

  final elements = _selectElements(content, cssSelector);
  if (isList) {
    return elements;
  }
  return elements.isNotEmpty ? elements.first : null;
}
```

## 3. 收益分析

### 3.1 代码质量提升

| 指标 | 重构前 | 重构后 | 改进 |
|------|--------|--------|------|
| 代码行数 | 56行 | 59行（48+11） | 略微增加（但结构更清晰） |
| 重复代码块 | 4个 | 0个 | **消除100%重复** |
| 条件分支 | 8个if | 4个if | **减少50%** |
| 可维护性 | 低 | 高 | **显著提升** |

### 3.2 维护成本降低

- **单一职责**：`_applyExtractor` 专注于 List/Element 分发逻辑
- **易于扩展**：添加新的提取类型只需一行代码
- **统一修改点**：修改分发逻辑只需改一处

### 3.3 可读性提升

重构后的代码意图更加清晰：
```dart
// 重构前：需要阅读 4 行才能理解意图
if (content is List) {
  return content.map((e) => _extractText(e)).toList();
}
return _extractText(content);

// 重构后：1 行代码，意图明确
return _applyExtractor(content, _extractText);
```

## 4. 测试策略

### 4.1 单元测试覆盖

需要确保以下场景的测试覆盖：

#### 测试用例 1：属性提取（@href, @src 等）
```dart
test('属性提取 - List 输入', () {
  final html = '<a href="link1">Text1</a><a href="link2">Text2</a>';
  final rule = AnalyzeRule().setContent(html);
  final result = rule.getStringList('@css:a@href');
  expect(result, equals(['link1', 'link2']));
});

test('属性提取 - 单个元素输入', () {
  final html = '<a href="link1">Text1</a>';
  final rule = AnalyzeRule().setContent(html);
  final result = rule.getString('@css:a@href');
  expect(result, equals('link1'));
});
```

#### 测试用例 2：文本提取（text, text()）
```dart
test('文本提取 - List 输入', () {
  final html = '<p>Text1</p><p>Text2</p>';
  final rule = AnalyzeRule().setContent(html);
  final result = rule.getStringList('@css:p@text');
  expect(result, equals(['Text1', 'Text2']));
});

test('文本提取 - 单个元素输入', () {
  final html = '<p>Text1</p>';
  final rule = AnalyzeRule().setContent(html);
  final result = rule.getString('@css:p@text');
  expect(result, equals('Text1'));
});
```

#### 测试用例 3：HTML 提取（html, html()）
```dart
test('HTML 提取 - List 输入', () {
  final html = '<div><span>Inner1</span></div><div><span>Inner2</span></div>';
  final rule = AnalyzeRule().setContent(html);
  final result = rule.getStringList('@css:div@html');
  expect(result, equals(['<span>Inner1</span>', '<span>Inner2</span>']));
});
```

#### 测试用例 4：outerHtml 提取
```dart
test('outerHtml 提取 - List 输入', () {
  final html = '<div>Content1</div><div>Content2</div>';
  final rule = AnalyzeRule().setContent(html);
  final result = rule.getStringList('@css:div@outerHtml');
  expect(result, equals(['<div>Content1</div>', '<div>Content2</div>']));
});
```

#### 测试用例 5：边界情况
```dart
test('空 List 输入', () {
  final rule = AnalyzeRule().setContent('');
  final result = rule.getStringList('@css:a@href');
  expect(result, equals([]));
});

test('null 元素处理', () {
  final rule = AnalyzeRule().setContent(null);
  final result = rule.getString('@css:a@href');
  expect(result, equals(''));
});
```

### 4.2 回归测试重点

1. **CSS 选择器功能**：确保所有 CSS 选择器功能正常工作
2. **List 和 Element 处理**：验证 List 和单个元素的提取结果一致
3. **特殊属性**：验证 @text、@html、@outerHtml、@hrefUrl、@srcUrl 等特殊属性
4. **错误处理**：验证空值、无效输入的处理逻辑

## 5. 实施计划

### 5.1 实施步骤

1. **添加 `_applyExtractor` 方法**（5分钟）
   - 在 `_applyCssSelector` 方法之前添加新方法
   - 添加详细的文档注释

2. **重构 `_applyCssSelector` 方法**（10分钟）
   - 替换 4 处重复代码
   - 保持原有逻辑不变

3. **运行测试**（5分钟）
   - 运行现有单元测试确保功能正常
   - 添加新的测试用例覆盖边界情况

4. **代码审查**（5分钟）
   - 检查代码风格一致性
   - 确认文档注释完整

### 5.2 风险评估

| 风险 | 影响 | 可能性 | 缓解措施 |
|------|------|--------|----------|
| 功能回归 | 高 | 低 | 完整的单元测试覆盖 |
| 性能影响 | 低 | 极低 | 方法调用开销可忽略 |
| 代码冲突 | 中 | 低 | 确保没有其他修改 |

### 5.3 回滚计划

如果发现问题，可以快速回滚到重构前的代码：
1. 删除 `_applyExtractor` 方法
2. 恢复 `_applyCssSelector` 方法的原始实现
3. 重新运行测试验证

## 6. 总结

本次重构通过提取通用的 `_applyExtractor` 方法，消除了 `_applyCssSelector` 方法中的重复代码模式。重构后的代码：

- ✅ **消除 100% 的重复代码**
- ✅ **提高代码可维护性**
- ✅ **增强代码可读性**
- ✅ **降低未来维护成本**
- ✅ **保持功能完全一致**

这是一个典型的"提取方法"重构案例，符合 DRY 原则和单一职责原则，是提升代码质量的有效手段。