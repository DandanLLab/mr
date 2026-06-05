import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';
import 'package:xml/xpath.dart';

class LegadoXPath {
  static dynamic read(dynamic input, String xpath, {required bool listMode}) {
    try {
      final document = _toXml(input);
      final sequence = document.xpath(xpath).toList();
      if (listMode) return sequence;
      return sequence
          .map(stringValue)
          .where((value) => value.isNotEmpty)
          .join('\n');
    } catch (_) {
      return listMode ? <dynamic>[] : null;
    }
  }

  /// 转换为 XML 文档
  /// 借鉴 legado 的 strToJXDocument，支持 HTML 片段自动补全和 XML 解析模式
  static XmlDocument _toXml(dynamic input) {
    if (input is XmlDocument) return input;
    if (input is XmlNode) return XmlDocument([input.copy()]);

    String htmlStr;
    if (input is dom.Element) {
      htmlStr = input.outerHtml;
    } else if (input is dom.Document) {
      htmlStr = input.documentElement?.outerHtml ?? '';
    } else {
      htmlStr = '$input';
    }

    // 借鉴 legado：检测 XML 内容
    final trimmed = htmlStr.trim();
    if (trimmed.startsWith('<?xml') || trimmed.startsWith('<xml')) {
      // XML 解析模式：直接解析为 XML
      try {
        return XmlDocument.parse(trimmed);
      } catch (_) {
        // XML 解析失败，降级到 HTML→XML 转换
      }
    }

    // 借鉴 legado：HTML 片段自动补全
    htmlStr = _autoCompleteHtml(htmlStr);

    final element = html_parser.parse(htmlStr).documentElement;
    if (element == null) {
      return XmlDocument([]);
    }

    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0"');
    _writeNode(builder, element);
    return builder.buildDocument();
  }

  /// HTML 片段自动补全（借鉴 legado 的 strToJXDocument）
  /// 不完整的 HTML 片段需要包裹父标签才能正确解析
  static String _autoCompleteHtml(String html) {
    final trimmed = html.trim();

    // </td> 结尾 → 包裹 <tr>...</tr>
    if (trimmed.endsWith('</td>') || trimmed.endsWith('</th>')) {
      return '<table><tbody><tr>$trimmed</tr></tbody></table>';
    }

    // </tr> 或 </tbody> 结尾 → 包裹 <table>...</table>
    if (trimmed.endsWith('</tr>') || trimmed.endsWith('</tbody>')) {
      return '<table>$trimmed</table>';
    }

    // </li> 结尾 → 包裹 <ul>...</ul>
    if (trimmed.endsWith('</li>')) {
      return '<ul>$trimmed</ul>';
    }

    // </option> 结尾 → 包裹 <select>...</select>
    if (trimmed.endsWith('</option>')) {
      return '<select>$trimmed</select>';
    }

    return html;
  }

  static void _writeNode(XmlBuilder builder, dom.Node node) {
    if (node is dom.Text) {
      builder.text(node.data);
    } else if (node is dom.Element) {
      builder.element(
        node.localName ?? 'node',
        attributes:
            node.attributes.map((key, value) => MapEntry('$key', value)),
        nest: () {
          for (final child in node.nodes) {
            _writeNode(builder, child);
          }
        },
      );
    }
  }

  /// 获取节点的字符串值
  /// 借鉴 legado 的 asString()，支持更多节点类型
  static String stringValue(dynamic value) {
    if (value is XmlAttribute) return value.value;
    if (value is XmlText) return value.value;
    if (value is XmlCDATA) return value.value;
    if (value is XmlComment) return ''; // 注释节点返回空
    if (value is XmlNode) return value.innerText;
    return '$value';
  }
}
