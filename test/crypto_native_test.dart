// CryptoJS polyfill 对比测试
// 验证 crypto-js.js polyfill 的输出与 Dart crypto 包完全一致
//
// 测试策略：
// 1. 在 JS 中调用 CryptoJS.MD5 / SHA1 / SHA256 / HmacSHA256 / AES 等 API
// 2. 在 Dart 中用 crypto 包计算相同输入
// 3. 比较两者输出是否一致
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'dart:convert';
import 'package:mr/services/native/js_engine.dart';

void main() {
  group('CryptoJS polyfill 对比测试', () {
    late JsEngine jsEngine;

    setUpAll(() async {
      jsEngine = JsEngine.instance;
      await jsEngine.init();
    });

    test('MD5: CryptoJS vs Dart crypto 包', () {
      const testCases = [
        '',
        'hello',
        'Hello, World!',
        '你好，世界！',
      ];

      for (final input in testCases) {
        final dartResult = crypto.md5.convert(utf8.encode(input)).toString();
        final jsResult = jsEngine.evaluate(
          'CryptoJS.MD5(${_jsString(input)}).toString()',
        ) as String;
        expect(jsResult, dartResult, reason: 'MD5("$input") 不一致');
      }
    });

    test('SHA1: CryptoJS vs Dart crypto 包', () {
      const testCases = [
        '',
        'hello',
        'Hello, World!',
        '你好，世界！',
      ];

      for (final input in testCases) {
        final dartResult = crypto.sha1.convert(utf8.encode(input)).toString();
        final jsResult = jsEngine.evaluate(
          'CryptoJS.SHA1(${_jsString(input)}).toString()',
        ) as String;
        expect(jsResult, dartResult, reason: 'SHA1("$input") 不一致');
      }
    });

    test('SHA256: CryptoJS vs Dart crypto 包', () {
      const testCases = [
        '',
        'hello',
        'Hello, World!',
        '你好，世界！',
      ];

      for (final input in testCases) {
        final dartResult = crypto.sha256.convert(utf8.encode(input)).toString();
        final jsResult = jsEngine.evaluate(
          'CryptoJS.SHA256(${_jsString(input)}).toString()',
        ) as String;
        expect(jsResult, dartResult, reason: 'SHA256("$input") 不一致');
      }
    });

    test('HMAC-SHA256: CryptoJS vs Dart crypto 包', () {
      const testCases = [
        ('data', 'key'),
        ('Hello, World!', 'secret'),
        ('你好', '密钥'),
      ];

      for (final (data, key) in testCases) {
        final dartResult = crypto.Hmac(crypto.sha256, utf8.encode(key))
            .convert(utf8.encode(data))
            .toString();
        final jsResult = jsEngine.evaluate(
          'CryptoJS.HmacSHA256(${_jsString(data)}, ${_jsString(key)}).toString()',
        ) as String;
        expect(jsResult, dartResult, reason: 'HMAC-SHA256("$data", "$key") 不一致');
      }
    });

    test('AES-CBC-PKCS7 加解密: CryptoJS 自洽', () {
      // 测试 AES 加密后解密能还原原文
      const testCases = [
        ('Hello, World!', '1234567890123456', '1234567890123456'),  // AES-128
        ('你好，世界！', '1234567890123456', '1234567890123456'),
      ];

      for (final (plaintext, key, iv) in testCases) {
        // 加密
        final cipherB64 = jsEngine.evaluate(
          'CryptoJS.AES.encrypt(${_jsString(plaintext)}, ${_jsString(key)}, '
          '{iv: ${_jsString(iv)}, mode: CryptoJS.mode.CBC}).toString()',
        ) as String;

        expect(cipherB64.isNotEmpty, true, reason: 'AES 加密失败');

        // 解密
        final decrypted = jsEngine.evaluate(
          'CryptoJS.AES.decrypt(${_jsString(cipherB64)}, ${_jsString(key)}, '
          '{iv: ${_jsString(iv)}, mode: CryptoJS.mode.CBC}).toString()',
        ) as String;

        expect(decrypted, plaintext, reason: 'AES 加解密不自洽');
      }
    });
  });
}

/// 将 Dart 字符串转为 JS 字符串字面量（带引号）
String _jsString(String s) {
  final escaped = s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r');
  return "'$escaped'";
}
