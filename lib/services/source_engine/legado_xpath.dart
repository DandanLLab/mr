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

  static XmlDocument _toXml(dynamic input) {
    if (input is XmlDocument) return input;
    if (input is XmlNode) return XmlDocument([input.copy()]);
    final element = input is dom.Element
        ? input
        : input is dom.Document
            ? input.documentElement
            : html_parser.parse('$input').documentElement;
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0"');
    _writeNode(builder, element!);
    return builder.buildDocument();
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

  static String stringValue(dynamic value) {
    if (value is XmlAttribute) return value.value;
    if (value is XmlText) return value.value;
    if (value is XmlNode) return value.innerText;
    return '$value';
  }
}
