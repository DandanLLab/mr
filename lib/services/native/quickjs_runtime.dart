import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'package:ffi/ffi.dart';
import 'package:encrypt/encrypt.dart';
import 'package:crypto/crypto.dart' as crypto;

/// QuickJS 评估结果
/// 兼容 flutter_js 的 JsEvalResult 接口
class JsEvalResult {
  final String stringResult;
  final bool isError;

  JsEvalResult(this.stringResult, this.isError);
}

// ---------- C 函数签名 ----------
typedef _BridgeCreateC = Pointer<Void> Function();
typedef _BridgeEvalC = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Int32>);
typedef _BridgeFreeStringC = Void Function(Pointer<Utf8>);
typedef _BridgeDisposeC = Void Function(Pointer<Void>);

// ---------- Dart 函数签名 ----------
typedef _BridgeCreateDart = Pointer<Void> Function();
typedef _BridgeEvalDart = Pointer<Utf8> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Int32>);
typedef _BridgeFreeStringDart = void Function(Pointer<Utf8>);
typedef _BridgeDisposeDart = void Function(Pointer<Void>);

// ---------- 原生加密通用回调签名 ----------
// C 侧: const char* (*)(int op, const char* a, const char* b, const char* c, int* is_error)
typedef _CryptoCallbackC = Pointer<Utf8> Function(
    Int32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>);

// C 侧: void (*)(crypto_callback)
typedef _SetCryptoCallbackC
    = Void Function(Pointer<NativeFunction<_CryptoCallbackC>>);
typedef _SetCryptoCallbackDart
    = void Function(Pointer<NativeFunction<_CryptoCallbackC>>);

// 加密操作类型常量（对齐 C 层 quickjs_bridge.h）
const int _CRYPTO_OP_AES_DECRYPT = 0;
const int _CRYPTO_OP_AES_ENCRYPT = 1;
const int _CRYPTO_OP_MD5 = 2;
const int _CRYPTO_OP_SHA256 = 3;
const int _CRYPTO_OP_HMAC_SHA256 = 4;
const int _CRYPTO_OP_SHA1 = 5;

/// 加载 QuickJS 动态库
///
/// 全端加载策略：
/// - iOS/macOS: podspec 配置 static_framework，符号链接到主程序 → DynamicLibrary.process()
/// - Android: NDK 编译为 libquickjs_c_bridge.so → DynamicLibrary.open()
/// - Windows: CMake 编译为 quickjs_c_bridge.dll → DynamicLibrary.open()
/// - Linux: CMake 编译为 libquickjs_c_bridge.so → DynamicLibrary.open()
DynamicLibrary _loadQuickJsLib() {
  if (Platform.isIOS || Platform.isMacOS) {
    return DynamicLibrary.process();
  } else if (Platform.isAndroid) {
    return DynamicLibrary.open('libquickjs_c_bridge.so');
  } else if (Platform.isWindows) {
    return DynamicLibrary.open('quickjs_c_bridge.dll');
  } else if (Platform.isLinux) {
    return DynamicLibrary.open('libquickjs_c_bridge.so');
  }
  throw UnsupportedError('QuickJS 不支持当前平台: ${Platform.operatingSystem}');
}

final DynamicLibrary _qjsLib = _loadQuickJsLib();

// ---------- FFI 绑定 ----------
// C 桥接层定义在 ios/QuickJS/quickjs_bridge.h
// 创建运行时：QuickJSBridge *quickjs_bridge_create(void)
final _BridgeCreateDart _bridgeCreate = _qjsLib
    .lookup<NativeFunction<_BridgeCreateC>>('quickjs_bridge_create')
    .asFunction<_BridgeCreateDart>();

// 执行脚本：const char *quickjs_bridge_eval(bridge, script, &is_error)
// 返回的字符串需调用 quickjs_bridge_free_string 释放
final _BridgeEvalDart _bridgeEval = _qjsLib
    .lookup<NativeFunction<_BridgeEvalC>>('quickjs_bridge_eval')
    .asFunction<_BridgeEvalDart>();

// 释放 eval 返回的字符串
final _BridgeFreeStringDart _bridgeFreeString = _qjsLib
    .lookup<NativeFunction<_BridgeFreeStringC>>('quickjs_bridge_free_string')
    .asFunction<_BridgeFreeStringDart>();

// 释放运行时：void quickjs_bridge_dispose(bridge)
final _BridgeDisposeDart _bridgeDispose = _qjsLib
    .lookup<NativeFunction<_BridgeDisposeC>>('quickjs_bridge_dispose')
    .asFunction<_BridgeDisposeDart>();

// 注册加密通用回调
final _SetCryptoCallbackDart _setCryptoCallback = _qjsLib
    .lookup<NativeFunction<_SetCryptoCallbackC>>(
        'quickjs_bridge_set_crypto_callback')
    .asFunction<_SetCryptoCallbackDart>();

// ---------- 原生加密回调实现 ----------
// 环形缓冲区：管理 Dart 分配的回调结果内存
// QuickJS 同步执行，回调返回后 C 层会立即 JS_NewString 复制走，所以缓冲区只用于兜底释放
// 最多缓存 16 个结果，超过时释放最老的（防止极端情况下内存泄漏）
final List<Pointer<Utf8>> _cryptoResultBuffer = [];
const int _maxCryptoBufferSize = 16;

bool _cryptoCallbackRegistered = false;

void _ensureCryptoCallbackRegistered() {
  if (_cryptoCallbackRegistered) return;
  _cryptoCallbackRegistered = true;
  // 注意：Pointer.fromFunction 当返回类型为 Pointer 时，不能传 exceptionalReturn
  // （Dart FFI 规范：void/Handle/Pointer 返回类型自动用 nullptr 兜底）
  // 回调内部必须用 try-catch 捕获所有异常，避免进程被 terminate
  _setCryptoCallback(
    Pointer.fromFunction<_CryptoCallbackC>(_nativeCryptoCallback),
  );
}

/// 安全解码 UTF-8 字符串
///
/// `Pointer<Utf8>.toDartString()` 不接受 `allowMalformed` 参数，遇非法字节会抛
/// FormatException。这里手动解码并允许 malformed，把非法字节替换为 U+FFFD。
/// 用于：
///   - evaluate 返回的乱码（AES 解密失败时的非法 UTF-8）
///   - 加密回调里 JS 层传入的 data/key/iv（理论上都是合法 UTF-8，保险起见）
String _safeToDartString(Pointer<Utf8> ptr) {
  // ffi 包的 Pointer<Utf8>.length 扩展：内部走 strlen
  final length = ptr.length;
  if (length == 0) return '';
  // asTypedList 创建堆内存视图（不复制），utf8.decode 时会复制到 Dart 端
  final bytes = ptr.cast<Uint8>().asTypedList(length);
  return utf8.decode(bytes, allowMalformed: true);
}

/// 把结果字符串写入环形缓冲区并返回 Pointer
Pointer<Utf8> _returnCryptoResult(String result) {
  final resultPtr = result.toNativeUtf8();
  _cryptoResultBuffer.add(resultPtr);
  if (_cryptoResultBuffer.length > _maxCryptoBufferSize) {
    // 释放最老的结果（toNativeUtf8 默认用 malloc 分配，对应 malloc.free）
    final old = _cryptoResultBuffer.removeAt(0);
    malloc.free(old.cast());
  }
  return resultPtr;
}

/// 加密通用回调（top-level，被 C 层通过函数指针同步调用）
///
/// 不能抛异常，异常时返回 nullptr 并设置 is_error=1
///
/// 内存管理：返回的 Pointer<Utf8> 由 _cryptoResultBuffer 持有，
/// C 层用 JS_NewString 复制后立即可被释放，
/// 但 Dart 不知道 C 何时复制完，所以延迟到下次调用或 dispose 时释放
Pointer<Utf8> _nativeCryptoCallback(
  int op,
  Pointer<Utf8> aPtr,
  Pointer<Utf8> bPtr,
  Pointer<Utf8> cPtr,
  Pointer<Int32> isErrorPtr,
) {
  try {
    final a = _safeToDartString(aPtr);
    final b = _safeToDartString(bPtr);
    final c = _safeToDartString(cPtr);

    String result;
    switch (op) {
      case _CRYPTO_OP_AES_DECRYPT:
        result = _performAesDecrypt(a, b, c);
        break;
      case _CRYPTO_OP_AES_ENCRYPT:
        result = _performAesEncrypt(a, b, c);
        break;
      case _CRYPTO_OP_MD5:
        result = crypto.md5.convert(utf8.encode(a)).toString();
        break;
      case _CRYPTO_OP_SHA256:
        result = crypto.sha256.convert(utf8.encode(a)).toString();
        break;
      case _CRYPTO_OP_HMAC_SHA256:
        result = crypto.Hmac(crypto.sha256, utf8.encode(b))
            .convert(utf8.encode(a))
            .toString();
        break;
      case _CRYPTO_OP_SHA1:
        result = crypto.sha1.convert(utf8.encode(a)).toString();
        break;
      default:
        isErrorPtr.value = 1;
        return nullptr;
    }

    isErrorPtr.value = 0;
    return _returnCryptoResult(result);
  } catch (e) {
    isErrorPtr.value = 1;
    return nullptr;
  }
}

/// AES-CBC-PKCS7 解密
///
/// - data: Base64 编码的密文
/// - key: UTF-8 字符串密钥（16/24/32 字节对应 AES-128/192/256）
/// - iv: UTF-8 字符串 IV（16 字节）
/// 返回解密后的 UTF-8 明文
String _performAesDecrypt(String dataB64, String key, String iv) {
  final keyBytes = utf8.encode(key);
  final ivBytes = utf8.encode(iv);

  final encrypter = Encrypter(AES(Key(keyBytes), mode: AESMode.cbc));
  final encrypted = Encrypted.fromBase64(dataB64);

  return encrypter.decrypt(encrypted, iv: IV(ivBytes));
}

/// AES-CBC-PKCS7 加密
///
/// - data: UTF-8 明文
/// - key: UTF-8 字符串密钥（16/24/32 字节对应 AES-128/192/256）
/// - iv: UTF-8 字符串 IV（16 字节）
/// 返回 Base64 编码的密文
String _performAesEncrypt(String data, String key, String iv) {
  final keyBytes = utf8.encode(key);
  final ivBytes = utf8.encode(iv);

  final encrypter = Encrypter(AES(Key(keyBytes), mode: AESMode.cbc));
  final encrypted = encrypter.encrypt(data, iv: IV(ivBytes));

  return encrypted.base64;
}

/// QuickJS 运行时
///
/// 从 C 源码编译的 QuickJS，通过 dart:ffi 直接调用 C API。
/// 替代 flutter_js 的 JavascriptRuntime。
///
/// 关键：evaluate() 保持同步调用（FFI 调用是同步的），
/// 这样 js_engine.dart 中 13 处同步方法无需改为 async。
///
/// 原生加密：构造时自动注册 __nativeCrypto 全局对象到 JS runtime
/// JS 代码可调用 __nativeCrypto.aesDecrypt/aesEncrypt/md5/sha256/hmacSHA256/sha1
/// 失败回退到纯 JS 的 CryptoJS
class JavascriptRuntime {
  Pointer<Void>? _bridge;
  bool _disposed = false;

  JavascriptRuntime() {
    // 注册原生 AES 回调（全局只注册一次）
    _ensureCryptoCallbackRegistered();

    _bridge = _bridgeCreate();
    if (_bridge == null || _bridge!.address == 0) {
      throw StateError('QuickJS 运行时创建失败');
    }
  }

  /// 执行 JS 脚本（同步）
  ///
  /// 通过 FFI 直接调用 C 函数 quickjs_bridge_eval，同步返回结果。
  /// 这与 flutter_js 的 QuickJsRuntime2.evaluate() 行为一致。
  ///
  /// 关键修复：用 allowMalformed: true 解码 UTF-8，避免 JS 返回乱码
  /// （如 AES 解密失败产生的非法字节）导致 FormatException 崩溃
  JsEvalResult evaluate(String script) {
    if (_disposed || _bridge == null) {
      return JsEvalResult('', true);
    }
    final scriptPtr = script.toNativeUtf8();
    final isErrorPtr = malloc<Int32>();
    try {
      isErrorPtr.value = 0;
      final resultPtr = _bridgeEval(_bridge!, scriptPtr, isErrorPtr);
      final isError = isErrorPtr.value != 0;
      if (resultPtr == nullptr) {
        return JsEvalResult('', isError);
      }
      // allowMalformed: 把非法 UTF-8 字节替换为 U+FFFD，不再抛 FormatException
      final result = _safeToDartString(resultPtr);
      _bridgeFreeString(resultPtr);
      return JsEvalResult(result, isError);
    } catch (e) {
      return JsEvalResult(e.toString(), true);
    } finally {
      malloc.free(scriptPtr);
      malloc.free(isErrorPtr);
    }
  }

  /// 异步执行 JS 脚本
  ///
  /// QuickJS 本身是同步执行的，这里包装为 Future 保持接口兼容。
  /// 对应 js_engine.dart 中的 evaluateAsync 调用。
  Future<JsEvalResult> evaluateAsync(String script) async {
    return evaluate(script);
  }

  /// 释放资源
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_bridge != null) {
      _bridgeDispose(_bridge!);
      _bridge = null;
    }
    // 注意：_cryptoResultBuffer 是全局的，不在单个 runtime dispose 时清理
    // 由进程退出或手动调用 _cleanupCryptoResults() 清理
  }
}

/// 创建 QuickJS 运行时
/// 兼容 flutter_js 的 getJavascriptRuntime 接口
JavascriptRuntime getJavascriptRuntime() {
  return JavascriptRuntime();
}
