// C 原生加密对比测试
// 验证 quickjs/crypto/ 下的 C 实现输出与 Dart pointycastle 完全一致
//
// 测试策略：
// 1. 在 JS 中调用 __nativeCrypto.md5Native 等 C 原生函数
// 2. 在 Dart 中用 pointycastle/crypto 包计算相同输入
// 3. 比较两者输出是否字节级一致
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'dart:convert';
import 'package:mr/services/native/js_engine.dart';

void main() {
  group('C 原生加密对比测试', () {
    late JsEngine jsEngine;

    setUpAll(() async {
      jsEngine = JsEngine.instance;
      await jsEngine.init();
    });

    test('MD5: C 原生 vs Dart crypto 包', () {
      const testCases = [
        '',
        'hello',
        'Hello, World!',
        '你好，世界！',
      ];

      for (final input in testCases) {
        final dartResult = crypto.md5.convert(utf8.encode(input)).toString();
        final jsResult = jsEngine.evaluate(
          '(function(){ var u8 = _strToU8(${_jsString(input)}); '
          'var r8 = __nativeCrypto.md5Native(u8); '
          'return _u8ToHex(r8); })()'
        ) as String;
        expect(jsResult, dartResult, reason: 'MD5("$input") 不一致');
      }
    });

    test('SHA1: C 原生 vs Dart crypto 包', () {
      const testCases = [
        '',
        'hello',
        'Hello, World!',
        '你好，世界！',
      ];

      for (final input in testCases) {
        final dartResult = crypto.sha1.convert(utf8.encode(input)).toString();
        final jsResult = jsEngine.evaluate(
          '(function(){ var u8 = _strToU8(${_jsString(input)}); '
          'var r8 = __nativeCrypto.sha1Native(u8); '
          'return _u8ToHex(r8); })()'
        ) as String;
        expect(jsResult, dartResult, reason: 'SHA1("$input") 不一致');
      }
    });

    test('SHA256: C 原生 vs Dart crypto 包', () {
      const testCases = [
        '',
        'hello',
        'Hello, World!',
        '你好，世界！',
      ];

      for (final input in testCases) {
        final dartResult = crypto.sha256.convert(utf8.encode(input)).toString();
        final jsResult = jsEngine.evaluate(
          '(function(){ var u8 = _strToU8(${_jsString(input)}); '
          'var r8 = __nativeCrypto.sha256Native(u8); '
          'return _u8ToHex(r8); })()'
        ) as String;
        expect(jsResult, dartResult, reason: 'SHA256("$input") 不一致');
      }
    });

    test('HMAC-SHA256: C 原生 vs Dart crypto 包', () {
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
          '(function(){ '
          'var d = _strToU8(${_jsString(data)}); '
          'var k = _strToU8(${_jsString(key)}); '
          'var r8 = __nativeCrypto.hmacSHA256Native(d, k); '
          'return _u8ToHex(r8); })()'
        ) as String;
        expect(jsResult, dartResult, reason: 'HMAC-SHA256("$data", "$key") 不一致');
      }
    });

    test('AES-CBC-PKCS7 加解密: C 原生自洽', () {
      // 测试 AES 加密后解密能还原原文
      const testCases = [
        ('Hello, World!', '1234567890123456', '1234567890123456'),  // AES-128
        ('你好，世界！', '1234567890123456', '1234567890123456'),
      ];

      for (final (plaintext, key, iv) in testCases) {
        // 加密
        final cipherB64 = jsEngine.evaluate(
          '(function(){ '
          'var p = _strToU8(${_jsString(plaintext)}); '
          'var k = _strToU8(${_jsString(key)}); '
          'var iv = _strToU8(${_jsString(iv)}); '
          'var c = __nativeCrypto.aesEncryptNative(p, k, iv); '
          'return _u8ToB64(c); })()'
        ) as String;

        expect(cipherB64.isNotEmpty, true, reason: 'AES 加密失败');

        // 解密
        final decrypted = jsEngine.evaluate(
          '(function(){ '
          'var c = _b64ToU8(${_jsString(cipherB64)}); '
          'var k = _strToU8(${_jsString(key)}); '
          'var iv = _strToU8(${_jsString(iv)}); '
          'var p = __nativeCrypto.aesDecryptNative(c, k, iv); '
          'return _u8ToStr(p); })()'
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
