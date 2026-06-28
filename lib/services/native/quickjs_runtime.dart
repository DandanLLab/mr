import 'dart:ffi';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
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

// ---------- 原生加密通用回调签名（字符串路径）----------
// C 侧: const char* (*)(int op, const char* a, const char* b, const char* c, int* is_error)
typedef _CryptoCallbackC = Pointer<Utf8> Function(
    Int32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>);

// C 侧: void (*)(crypto_callback)
typedef _SetCryptoCallbackC
    = Void Function(Pointer<NativeFunction<_CryptoCallbackC>>);
typedef _SetCryptoCallbackDart
    = void Function(Pointer<NativeFunction<_CryptoCallbackC>>);

// ---------- 原生加密通用回调签名（ArrayBuffer 零拷贝路径）----------
// C 侧: const uint8_t* (*)(int op,
//        const uint8_t* data0, size_t len0,
//        const uint8_t* data1, size_t len1,
//        const uint8_t* data2, size_t len2,
//        size_t* out_len, int* is_error)
typedef _CryptoCallbackBinaryC = Pointer<Uint8> Function(
    Int32,
    Pointer<Uint8>, IntPtr,
    Pointer<Uint8>, IntPtr,
    Pointer<Uint8>, IntPtr,
    Pointer<IntPtr>, Pointer<Int32>);

typedef _SetCryptoCallbackBinaryC
    = Void Function(Pointer<NativeFunction<_CryptoCallbackBinaryC>>);
typedef _SetCryptoCallbackBinaryDart
    = void Function(Pointer<NativeFunction<_CryptoCallbackBinaryC>>);

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

// ---------- Phase 6: 性能统计 FFI 绑定 ----------
// C 结构体 crypto_stats_t 的 Dart 镜像（内存布局与 C 一致）
// 用于直接接收 quickjs_bridge_get_crypto_stats 的返回值，零拷贝读取
final class CryptoStatsNative extends Struct {
  @Uint64()
  external int totalCalls;
  @Uint64()
  external int totalBytesIn;
  @Uint64()
  external int totalBytesOut;
  @Uint64()
  external int totalUs;
  @Uint64()
  external int maxUs;
  @Uint64()
  external int minUs;
}

// C: crypto_stats_t quickjs_bridge_get_crypto_stats(QuickJSBridge*)
typedef _GetCryptoStatsC = CryptoStatsNative Function(Pointer<Void>);
typedef _GetCryptoStatsDart = CryptoStatsNative Function(Pointer<Void>);

// C: void quickjs_bridge_reset_crypto_stats(QuickJSBridge*)
typedef _ResetCryptoStatsC = Void Function(Pointer<Void>);
typedef _ResetCryptoStatsDart = void Function(Pointer<Void>);

final _GetCryptoStatsDart _getCryptoStats = _qjsLib
    .lookup<NativeFunction<_GetCryptoStatsC>>('quickjs_bridge_get_crypto_stats')
    .asFunction<_GetCryptoStatsDart>();

final _ResetCryptoStatsDart _resetCryptoStats = _qjsLib
    .lookup<NativeFunction<_ResetCryptoStatsC>>('quickjs_bridge_reset_crypto_stats')
    .asFunction<_ResetCryptoStatsDart>();

// ---------- Phase 4: 字节码缓存 FFI 绑定 ----------
// C: int quickjs_bridge_precompile(QuickJSBridge*, const char* script)
// 返回 0 成功，-1 失败（语法错误等）
typedef _BridgePrecompileC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _BridgePrecompileDart = int Function(Pointer<Void>, Pointer<Utf8>);

// C: void quickjs_bridge_clear_bytecode_cache(QuickJSBridge*)
typedef _BridgeClearBytecodeCacheC = Void Function(Pointer<Void>);
typedef _BridgeClearBytecodeCacheDart = void Function(Pointer<Void>);

final _BridgePrecompileDart _bridgePrecompile = _qjsLib
    .lookup<NativeFunction<_BridgePrecompileC>>('quickjs_bridge_precompile')
    .asFunction<_BridgePrecompileDart>();

final _BridgeClearBytecodeCacheDart _bridgeClearBytecodeCache = _qjsLib
    .lookup<NativeFunction<_BridgeClearBytecodeCacheC>>(
        'quickjs_bridge_clear_bytecode_cache')
    .asFunction<_BridgeClearBytecodeCacheDart>();

/// 性能统计快照（Dart 侧纯数据类，便于 UI 消费与序列化）
class CryptoStats {
  final int totalCalls;
  final int totalBytesIn;
  final int totalBytesOut;
  final int totalUs;
  final int maxUs;
  final int minUs;

  const CryptoStats({
    required this.totalCalls,
    required this.totalBytesIn,
    required this.totalBytesOut,
    required this.totalUs,
    required this.maxUs,
    required this.minUs,
  });

  factory CryptoStats.zero() => const CryptoStats(
        totalCalls: 0,
        totalBytesIn: 0,
        totalBytesOut: 0,
        totalUs: 0,
        maxUs: 0,
        minUs: 0,
      );

  factory CryptoStats.fromNative(CryptoStatsNative n) => CryptoStats(
        totalCalls: n.totalCalls,
        totalBytesIn: n.totalBytesIn,
        totalBytesOut: n.totalBytesOut,
        totalUs: n.totalUs,
        maxUs: n.maxUs,
        minUs: n.minUs,
      );

  /// 平均单次耗时（微秒），无调用时为 0
  double get avgUs => totalCalls == 0 ? 0.0 : totalUs / totalCalls;

  /// 吞吐率（输入字节/秒），无调用时为 0
  double get throughputMBps =>
      totalUs == 0 ? 0.0 : (totalBytesIn / 1024 / 1024) / (totalUs / 1000000);

  /// 压缩/解压比（输出/输入），无输入时为 0
  double get ratio =>
      totalBytesIn == 0 ? 0.0 : totalBytesOut / totalBytesIn;

  @override
  String toString() => 'CryptoStats(calls=$totalCalls, '
      'in=${(totalBytesIn / 1024).toStringAsFixed(1)}KB, '
      'out=${(totalBytesOut / 1024).toStringAsFixed(1)}KB, '
      'avg=${avgUs.toStringAsFixed(1)}us, '
      'max=${maxUs}us, min=${minUs}us)';
}

// 注册加密通用回调（字符串路径，全局）
final _SetCryptoCallbackDart _setCryptoCallback = _qjsLib
    .lookup<NativeFunction<_SetCryptoCallbackC>>(
        'quickjs_bridge_set_crypto_callback')
    .asFunction<_SetCryptoCallbackDart>();

// 注册加密通用回调（ArrayBuffer 零拷贝路径，全局）
final _SetCryptoCallbackBinaryDart _setCryptoCallbackBinary = _qjsLib
    .lookup<NativeFunction<_SetCryptoCallbackBinaryC>>(
        'quickjs_bridge_set_crypto_callback_binary')
    .asFunction<_SetCryptoCallbackBinaryDart>();

// ---------- Phase 5: 上下文绑定回调（per-bridge，多实例并发安全）----------
// C: void quickjs_bridge_set_crypto_callback_for(QuickJSBridge*, crypto_callback)
typedef _SetCryptoCallbackForC = Void Function(Pointer<Void>, Pointer<NativeFunction<_CryptoCallbackC>>);
typedef _SetCryptoCallbackForDart = void Function(Pointer<Void>, Pointer<NativeFunction<_CryptoCallbackC>>);

// C: void quickjs_bridge_set_crypto_callback_binary_for(QuickJSBridge*, crypto_callback_binary)
typedef _SetCryptoCallbackBinaryForC = Void Function(Pointer<Void>, Pointer<NativeFunction<_CryptoCallbackBinaryC>>);
typedef _SetCryptoCallbackBinaryForDart = void Function(Pointer<Void>, Pointer<NativeFunction<_CryptoCallbackBinaryC>>);

final _SetCryptoCallbackForDart _setCryptoCallbackFor = _qjsLib
    .lookup<NativeFunction<_SetCryptoCallbackForC>>(
        'quickjs_bridge_set_crypto_callback_for')
    .asFunction<_SetCryptoCallbackForDart>();

final _SetCryptoCallbackBinaryForDart _setCryptoCallbackBinaryFor = _qjsLib
    .lookup<NativeFunction<_SetCryptoCallbackBinaryForC>>(
        'quickjs_bridge_set_crypto_callback_binary_for')
    .asFunction<_SetCryptoCallbackBinaryForDart>();

// ---------- 批量解压 FFI 绑定（Phase 2/3：多线程分片并发）----------
// C: int get_cpu_count(void)
typedef _GetCpuCountC = Int32 Function();
typedef _GetCpuCountDart = int Function();

// C: int lz_decompress_batch(const char **inputs, const size_t *input_lens,
//                            size_t count, char ***out_results, size_t **out_lens)
typedef _LzDecompressBatchC = Int32 Function(
    Pointer<Pointer<Utf8>>, Pointer<IntPtr>, IntPtr,
    Pointer<Pointer<Pointer<Utf8>>>, Pointer<Pointer<IntPtr>>);
typedef _LzDecompressBatchDart = int Function(
    Pointer<Pointer<Utf8>>, Pointer<IntPtr>, int,
    Pointer<Pointer<Pointer<Utf8>>>, Pointer<Pointer<IntPtr>>);

// C: int aes_decrypt_lz_batch(const char **b64_inputs, const size_t *b64_lens,
//                             size_t count, const char *key_utf8, size_t key_len,
//                             char ***out_results, size_t **out_lens)
typedef _AesDecryptLzBatchC = Int32 Function(
    Pointer<Pointer<Utf8>>, Pointer<IntPtr>, IntPtr,
    Pointer<Utf8>, IntPtr,
    Pointer<Pointer<Pointer<Utf8>>>, Pointer<Pointer<IntPtr>>);
typedef _AesDecryptLzBatchDart = int Function(
    Pointer<Pointer<Utf8>>, Pointer<IntPtr>, int,
    Pointer<Utf8>, int,
    Pointer<Pointer<Pointer<Utf8>>>, Pointer<Pointer<IntPtr>>);

final _GetCpuCountDart _getCpuCount = _qjsLib
    .lookup<NativeFunction<_GetCpuCountC>>('get_cpu_count')
    .asFunction<_GetCpuCountDart>();

final _LzDecompressBatchDart _lzDecompressBatch = _qjsLib
    .lookup<NativeFunction<_LzDecompressBatchC>>('lz_decompress_batch')
    .asFunction<_LzDecompressBatchDart>();

final _AesDecryptLzBatchDart _aesDecryptLzBatch = _qjsLib
    .lookup<NativeFunction<_AesDecryptLzBatchC>>('aes_decrypt_lz_batch')
    .asFunction<_AesDecryptLzBatchDart>();

/// 获取 CPU 逻辑核心数（来自 C 层，用于面板显示与策略决策）
int nativeGetCpuCount() => _getCpuCount();

/// 批量 LZString 解压（多线程分片并发，Phase 2/3）
///
/// 输入 [inputs] 字符串列表（null 元素对应 JS null 语义 → 返回空串）
/// 返回解压结果列表（null 表示对应输入解压失败或空串输入）
List<String?> lzDecompressBatch(List<String?> inputs) {
  if (inputs.isEmpty) return [];
  final count = inputs.length;
  final inputsPtr = malloc<Pointer<Utf8>>(count);
  final lensPtr = malloc<IntPtr>(count);
  final outResultsPtr = malloc<Pointer<Pointer<Utf8>>>();
  final outLensPtr = malloc<Pointer<IntPtr>>();
  try {
    for (var i = 0; i < count; i++) {
      final s = inputs[i];
      if (s == null) {
        inputsPtr[i] = nullptr;
        lensPtr[i] = 0;
      } else {
        final bytes = utf8.encode(s);
        final ptr = malloc<Uint8>(bytes.length + 1);
        for (var j = 0; j < bytes.length; j++) ptr[j] = bytes[j];
        ptr[bytes.length] = 0;
        inputsPtr[i] = ptr.cast();
        lensPtr[i] = bytes.length;
      }
    }
    final rc = _lzDecompressBatch(inputsPtr, lensPtr, count, outResultsPtr, outLensPtr);
    if (rc != 0) return List<String?>.filled(count, null);
    final outResults = outResultsPtr.value;
    final outLens = outLensPtr.value;
    final results = <String?>[];
    for (var i = 0; i < count; i++) {
      final ptr = outResults[i];
      if (ptr.address == 0) {
        results.add(null);
      } else {
        final len = outLens[i];
        if (len == 0) {
          results.add('');
        } else {
          final bytes = ptr.cast<Uint8>().asTypedList(len);
          results.add(utf8.decode(bytes, allowMalformed: true));
        }
        malloc.free(ptr.cast());
      }
    }
    malloc.free(outResults.cast());
    malloc.free(outLens);
    return results;
  } finally {
    for (var i = 0; i < count; i++) {
      if (inputsPtr[i].address != 0) malloc.free(inputsPtr[i].cast());
    }
    malloc.free(inputsPtr);
    malloc.free(lensPtr);
    malloc.free(outResultsPtr);
    malloc.free(outLensPtr);
  }
}

/// 批量 AES+LZ 解密解压（多线程分片并发，原子组合，Phase 2/3）
///
/// 输入 [b64Inputs] base64 密文列表，[key] AES 密钥（16/24/32 字节）
/// 流程：base64 decode → IV(前16)|cipher → AES-CBC-PKCS7 decrypt → LZString decompress
/// 返回解压结果列表（null 表示对应输入解密/解压失败）
List<String?> aesDecryptLzBatch(List<String> b64Inputs, String key) {
  if (b64Inputs.isEmpty) return [];
  final keyBytes = utf8.encode(key);
  if (keyBytes.length != 16 && keyBytes.length != 24 && keyBytes.length != 32) {
    throw ArgumentError('AES key length must be 16/24/32, got ${keyBytes.length}');
  }
  final count = b64Inputs.length;
  final inputsPtr = malloc<Pointer<Utf8>>(count);
  final lensPtr = malloc<IntPtr>(count);
  final keyPtr = malloc<Uint8>(keyBytes.length + 1);
  final outResultsPtr = malloc<Pointer<Pointer<Utf8>>>();
  final outLensPtr = malloc<Pointer<IntPtr>>();
  try {
    for (var i = 0; i < count; i++) {
      final bytes = utf8.encode(b64Inputs[i]);
      final ptr = malloc<Uint8>(bytes.length + 1);
      for (var j = 0; j < bytes.length; j++) ptr[j] = bytes[j];
      ptr[bytes.length] = 0;
      inputsPtr[i] = ptr.cast();
      lensPtr[i] = bytes.length;
    }
    for (var i = 0; i < keyBytes.length; i++) keyPtr[i] = keyBytes[i];
    keyPtr[keyBytes.length] = 0;
    final rc = _aesDecryptLzBatch(
        inputsPtr, lensPtr, count, keyPtr.cast(), keyBytes.length, outResultsPtr, outLensPtr);
    if (rc != 0) return List<String?>.filled(count, null);
    final outResults = outResultsPtr.value;
    final outLens = outLensPtr.value;
    final results = <String?>[];
    for (var i = 0; i < count; i++) {
      final ptr = outResults[i];
      if (ptr.address == 0) {
        results.add(null);
      } else {
        final len = outLens[i];
        if (len == 0) {
          results.add('');
        } else {
          final bytes = ptr.cast<Uint8>().asTypedList(len);
          results.add(utf8.decode(bytes, allowMalformed: true));
        }
        malloc.free(ptr.cast());
      }
    }
    malloc.free(outResults.cast());
    malloc.free(outLens);
    return results;
  } finally {
    for (var i = 0; i < count; i++) {
      if (inputsPtr[i].address != 0) malloc.free(inputsPtr[i].cast());
    }
    malloc.free(inputsPtr);
    malloc.free(lensPtr);
    malloc.free(keyPtr);
    malloc.free(outResultsPtr);
    malloc.free(outLensPtr);
  }
}

// ---------- 原生加密回调实现 ----------
// 环形缓冲区：管理 Dart 分配的回调结果内存
// QuickJS 同步执行，回调返回后 C 层会立即 JS_NewString 复制走，所以缓冲区只用于兜底释放
// 最多缓存 16 个结果，超过时释放最老的（防止极端情况下内存泄漏）
final List<Pointer<Utf8>> _cryptoResultBuffer = [];
const int _maxCryptoBufferSize = 16;

bool _cryptoCallbackRegistered = false;

// Phase 5: 缓存函数指针，避免每次创建 runtime 时重复构造 Pointer.fromFunction
// Pointer.fromFunction 返回的是 C 函数指针，构造开销极小但语义上应只创建一次
final Pointer<NativeFunction<_CryptoCallbackC>> _cryptoCallbackPtr =
    Pointer.fromFunction<_CryptoCallbackC>(_nativeCryptoCallback);
final Pointer<NativeFunction<_CryptoCallbackBinaryC>> _cryptoCallbackBinaryPtr =
    Pointer.fromFunction<_CryptoCallbackBinaryC>(_nativeCryptoCallbackBinary);

void _ensureCryptoCallbackRegistered() {
  if (_cryptoCallbackRegistered) return;
  _cryptoCallbackRegistered = true;
  // 注意：Pointer.fromFunction 当返回类型为 Pointer 时，不能传 exceptionalReturn
  // （Dart FFI 规范：void/Handle/Pointer 返回类型自动用 nullptr 兜底）
  // 回调内部必须用 try-catch 捕获所有异常，避免进程被 terminate
  // 全局回调作为兜底（未绑定到具体 bridge 的旧路径）
  _setCryptoCallback(_cryptoCallbackPtr);
  _setCryptoCallbackBinary(_cryptoCallbackBinaryPtr);
}

/// Phase 5: 清理所有缓存的加密回调结果内存
/// 应在 dispose() 或进程退出前调用，根除跨语言内存泄漏
void cleanupCryptoResults() {
  for (final ptr in _cryptoResultBuffer) {
    if (ptr.address != 0) malloc.free(ptr.cast());
  }
  _cryptoResultBuffer.clear();
  for (final ptr in _cryptoBinaryResultBuffer) {
    if (ptr.address != 0) malloc.free(ptr);
  }
  _cryptoBinaryResultBuffer.clear();
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

// ---------- 二进制回调实现（ArrayBuffer 零拷贝路径）----------
// 二进制环形缓冲区：管理 Dart 分配的字节结果内存
final List<Pointer<Uint8>> _cryptoBinaryResultBuffer = [];
const int _maxCryptoBinaryBufferSize = 16;

Pointer<Uint8> _returnCryptoBinaryResult(Uint8List bytes) {
  final ptr = malloc<Uint8>(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    ptr[i] = bytes[i];
  }
  _cryptoBinaryResultBuffer.add(ptr);
  if (_cryptoBinaryResultBuffer.length > _maxCryptoBinaryBufferSize) {
    final old = _cryptoBinaryResultBuffer.removeAt(0);
    malloc.free(old);
  }
  return ptr;
}

Uint8List _pointerToBytes(Pointer<Uint8> ptr, int length) {
  if (ptr.address == 0 || length == 0) return Uint8List(0);
  return ptr.asTypedList(length);
}

/// 加密二进制回调（top-level，被 C 层通过函数指针同步调用）
///
/// 接收 ArrayBuffer 字节数据，返回字节数据
/// 用于大数据（>= 1KB）：零拷贝路径
Pointer<Uint8> _nativeCryptoCallbackBinary(
  int op,
  Pointer<Uint8> data0Ptr, int len0,
  Pointer<Uint8> data1Ptr, int len1,
  Pointer<Uint8> data2Ptr, int len2,
  Pointer<IntPtr> outLenPtr,
  Pointer<Int32> isErrorPtr,
) {
  try {
    final data0 = _pointerToBytes(data0Ptr, len0);
    final data1 = _pointerToBytes(data1Ptr, len1);
    final data2 = _pointerToBytes(data2Ptr, len2);

    Uint8List result;
    switch (op) {
      case _CRYPTO_OP_AES_DECRYPT:
        // data0=base64 密文字节, data1=key 字节, data2=iv 字节
        final dataB64 = utf8.decode(data0, allowMalformed: true);
        final key = utf8.decode(data1, allowMalformed: true);
        final iv = utf8.decode(data2, allowMalformed: true);
        final plain = _performAesDecrypt(dataB64, key, iv);
        result = Uint8List.fromList(utf8.encode(plain));
        break;
      case _CRYPTO_OP_AES_ENCRYPT:
        // data0=明文字节, data1=key 字节, data2=iv 字节
        final data = utf8.decode(data0, allowMalformed: true);
        final key = utf8.decode(data1, allowMalformed: true);
        final iv = utf8.decode(data2, allowMalformed: true);
        final cipherB64 = _performAesEncrypt(data, key, iv);
        result = Uint8List.fromList(utf8.encode(cipherB64));
        break;
      case _CRYPTO_OP_MD5:
        result = Uint8List.fromList(
            utf8.encode(crypto.md5.convert(data0).toString()));
        break;
      case _CRYPTO_OP_SHA256:
        result = Uint8List.fromList(
            utf8.encode(crypto.sha256.convert(data0).toString()));
        break;
      case _CRYPTO_OP_HMAC_SHA256:
        // data0=数据字节, data1=key 字节
        result = Uint8List.fromList(utf8.encode(
            crypto.Hmac(crypto.sha256, data1).convert(data0).toString()));
        break;
      case _CRYPTO_OP_SHA1:
        result = Uint8List.fromList(
            utf8.encode(crypto.sha1.convert(data0).toString()));
        break;
      default:
        isErrorPtr.value = 1;
        outLenPtr.value = 0;
        return nullptr;
    }

    isErrorPtr.value = 0;
    outLenPtr.value = result.length;
    return _returnCryptoBinaryResult(result);
  } catch (e) {
    isErrorPtr.value = 1;
    outLenPtr.value = 0;
    return nullptr;
  }
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
///
/// Phase 5 内存管理：
/// - 回调绑定到当前 bridge 实例（_setCryptoCallbackFor），多实例并发安全
/// - Dart Finalizer 兜底：即使调用方忘记 dispose()，GC 时也会自动释放 C 侧资源
/// - eval 结果采用「即时拷贝 + 即时释放」策略：C 字符串在 evaluate() 内部
///   完成 Dart 拷贝后立即 free，无跨语言生命周期悬挂
class JavascriptRuntime {
  Pointer<Void>? _bridge;
  bool _disposed = false;

  /// Phase 5: Dart Finalizer 兜底释放
  /// 当本对象被 GC 回收时，自动释放对应的 C 侧 QuickJSBridge
  /// 防止调用方忘记 dispose() 导致 QuickJS runtime 内存泄漏
  static final Finalizer<Pointer<Void>> _finalizer =
      Finalizer<Pointer<Void>>((bridge) {
    if (bridge.address != 0) {
      _bridgeDispose(bridge);
    }
  });

  JavascriptRuntime() {
    // 全局兜底回调（向后兼容，且确保 _cryptoCallbackPtr 已构造）
    _ensureCryptoCallbackRegistered();

    _bridge = _bridgeCreate();
    if (_bridge == null || _bridge!.address == 0) {
      throw StateError('QuickJS 运行时创建失败');
    }

    // Phase 5: 上下文绑定回调 —— 将加密回调绑定到当前 bridge 实例
    // 即使存在多个 JavascriptRuntime，每个 bridge 独立持有回调指针，
    // C 层 get_crypto_cb(ctx) 优先返回 per-bridge 回调，互不干扰
    _setCryptoCallbackFor(_bridge!, _cryptoCallbackPtr);
    _setCryptoCallbackBinaryFor(_bridge!, _cryptoCallbackBinaryPtr);

    // 注册 Finalizer：本对象 GC 时自动释放 C 侧 bridge
    _finalizer.attach(this, _bridge!, detach: this);
  }

  /// 执行 JS 脚本（同步）
  ///
  /// 通过 FFI 直接调用 C 函数 quickjs_bridge_eval，同步返回结果。
  /// 这与 flutter_js 的 QuickJsRuntime2.evaluate() 行为一致。
  ///
  /// 关键修复：用 allowMalformed: true 解码 UTF-8，避免 JS 返回乱码
  /// （如 AES 解密失败产生的非法字节）导致 FormatException 崩溃
  ///
  /// 生命周期：C 侧返回的字符串在 [evaluate] 内部即时拷贝为 Dart String，
  /// 随后立即调用 _bridgeFreeString 释放 C 内存，无悬挂指针
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
  ///
  /// 显式释放 C 侧 QuickJSBridge，并从 Finalizer 摘除
  /// 加密回调结果缓冲区为全局共享，不在此处清理；
  /// 如需彻底回收可调用顶层函数 [cleanupCryptoResults]
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_bridge != null) {
      _finalizer.detach(this);
      _bridgeDispose(_bridge!);
      _bridge = null;
    }
  }

  // ---------- Phase 6: 性能统计接口 ----------

  /// 获取 C 原生加密累计统计快照
  /// 包含所有 __nativeCrypto / __nativeLz 路径的调用：AES、MD5、SHA、LZString、AES+LZ 原子组合、批量解压
  CryptoStats getCryptoStats() {
    if (_bridge == null) return CryptoStats.zero();
    return CryptoStats.fromNative(_getCryptoStats(_bridge!));
  }

  /// 重置统计计数器（不影响运行时状态，仅清零统计）
  void resetCryptoStats() {
    if (_bridge != null) _resetCryptoStats(_bridge!);
  }

  // ---------- Phase 4: 字节码缓存接口 ----------

  /// 预编译脚本到字节码缓存（不执行）
  ///
  /// 后续 [evaluate] 同一脚本时跳过词法分析/语法解析/字节码生成阶段，
  /// 直接走 [JS_EvalFunction] 执行已缓存的字节码。
  ///
  /// 适用场景：
  /// - JsEngine 初始化时预编译核心库（nodePolyfills、AES 引擎、CryptoJS 等）
  /// - 书源规则脚本首次加载时预编译
  ///
  /// 返回 true 成功，false 失败（脚本语法错误等，可忽略继续走 evaluate 正常报错路径）
  bool precompile(String script) {
    if (_disposed || _bridge == null) return false;
    final scriptPtr = script.toNativeUtf8();
    try {
      final rc = _bridgePrecompile(_bridge!, scriptPtr);
      return rc == 0;
    } catch (_) {
      return false;
    } finally {
      malloc.free(scriptPtr);
    }
  }

  /// 清空字节码缓存
  ///
  /// 释放所有缓存条目占用的内存（脚本源码 + 字节码 JSValue）
  ///
  /// 适用场景：
  /// - 书源切换、内存压力
  /// - 调试时强制重新解析
  /// - dispose 之前的资源回收（dispose 内部已自动调用，无需手动调）
  void clearBytecodeCache() {
    if (_bridge != null) _bridgeClearBytecodeCache(_bridge!);
  }

  /// Phase 6: 动态策略切换 —— 根据数据量级选择串行 vs 并行路径
  ///
  /// 返回 true 表示应使用批量多线程路径（[lzDecompressBatch] / [aesDecryptLzBatch]），
  /// 返回 false 表示应使用串行单条路径（JS 侧逐条调用原生函数）
  ///
  /// 判据：
  /// - [count] >= [batchThreshold]（默认 64）：批量线程分片的并行收益超过线程创建开销
  /// - [totalBytes] >= [bytesThreshold]（默认 32KB）：数据量足够大时多线程才有意义
  /// - 满足任一即启用批量路径
  static bool shouldUseBatch({
    required int count,
    int totalBytes = 0,
    int batchThreshold = 64,
    int bytesThreshold = 32 * 1024,
  }) {
    if (count >= batchThreshold) return true;
    if (totalBytes >= bytesThreshold) return true;
    return false;
  }
}

/// 创建 QuickJS 运行时
/// 兼容 flutter_js 的 getJavascriptRuntime 接口
JavascriptRuntime getJavascriptRuntime() {
  return JavascriptRuntime();
}
