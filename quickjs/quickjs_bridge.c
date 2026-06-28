#include "quickjs_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "crypto/md5.h"
#include "crypto/sha1.h"
#include "crypto/sha256.h"
#include "crypto/hmac_sha256.h"
#include "crypto/aes.h"

struct QuickJSBridge {
    JSRuntime *runtime;
    JSContext *ctx;
    // 上下文绑定的加密回调（每个 bridge 实例独立，多线程安全）
    // 为 NULL 时回退到全局回调（向后兼容）
    crypto_callback crypto_cb;
    crypto_callback_binary crypto_cb_binary;
    // 性能统计（每个 bridge 独立）
    crypto_stats_t stats;
};

// ---------- 性能统计辅助 ----------
#if defined(_WIN32) || defined(_WIN64)
#include <windows.h>
static uint64_t _now_us(void) {
    static LARGE_INTEGER freq = {0};
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (uint64_t)(now.QuadPart * 1000000 / freq.QuadPart);
}
#else
static uint64_t _now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}
#endif

static void _stats_update(crypto_stats_t *s, uint64_t bytes_in, uint64_t bytes_out, uint64_t elapsed_us) {
    s->total_calls++;
    s->total_bytes_in += bytes_in;
    s->total_bytes_out += bytes_out;
    s->total_us += elapsed_us;
    if (elapsed_us > s->max_us) s->max_us = elapsed_us;
    if (s->min_us == 0 || elapsed_us < s->min_us) s->min_us = elapsed_us;
}

crypto_stats_t quickjs_bridge_get_crypto_stats(QuickJSBridge *bridge) {
    if (!bridge) {
        crypto_stats_t empty = {0};
        return empty;
    }
    return bridge->stats;
}

void quickjs_bridge_reset_crypto_stats(QuickJSBridge *bridge) {
    if (bridge) memset(&bridge->stats, 0, sizeof(crypto_stats_t));
}

// ---------- 全局回调（向后兼容，作为默认值）----------
static crypto_callback g_crypto_cb = NULL;
static crypto_callback_binary g_crypto_cb_binary = NULL;

void quickjs_bridge_set_crypto_callback(crypto_callback cb) {
    g_crypto_cb = cb;
}

void quickjs_bridge_set_crypto_callback_binary(crypto_callback_binary cb) {
    g_crypto_cb_binary = cb;
}

// ---------- 上下文绑定回调（每个 bridge 实例独立）----------
void quickjs_bridge_set_crypto_callback_for(QuickJSBridge *bridge, crypto_callback cb) {
    if (bridge) bridge->crypto_cb = cb;
}

void quickjs_bridge_set_crypto_callback_binary_for(QuickJSBridge *bridge, crypto_callback_binary cb) {
    if (bridge) bridge->crypto_cb_binary = cb;
}

// 获取生效的回调（优先 bridge 实例，回退全局）
static crypto_callback get_crypto_cb(JSContext *ctx) {
    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    if (bridge && bridge->crypto_cb) return bridge->crypto_cb;
    return g_crypto_cb;
}

static crypto_callback_binary get_crypto_cb_binary(JSContext *ctx) {
    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    if (bridge && bridge->crypto_cb_binary) return bridge->crypto_cb_binary;
    return g_crypto_cb_binary;
}

// ---------- 字符串路径 ----------
// 通用加密调度：调用 Dart 回调，返回 JSValue
// 失败抛 JS 异常，成功返回字符串
static JSValue js_call_crypto(JSContext *ctx, int op, int argc, JSValueConst *argv,
                              int min_args, const char *fn_name) {
    crypto_callback cb = get_crypto_cb(ctx);
    if (!cb) {
        return JS_ThrowTypeError(ctx, "%s: native crypto not registered", fn_name);
    }
    if (argc < min_args) {
        return JS_ThrowTypeError(ctx, "%s requires %d arguments, got %d", fn_name, min_args, argc);
    }

    const char *a = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
    const char *b = argc > 1 ? JS_ToCString(ctx, argv[1]) : NULL;
    const char *c = argc > 2 ? JS_ToCString(ctx, argv[2]) : NULL;

    if (min_args > 0 && (!a)) {
        if (a) JS_FreeCString(ctx, a);
        if (b) JS_FreeCString(ctx, b);
        if (c) JS_FreeCString(ctx, c);
        return JS_ThrowTypeError(ctx, "%s: argument 1 must be a string", fn_name);
    }
    if (min_args > 1 && (!b)) {
        if (a) JS_FreeCString(ctx, a);
        if (b) JS_FreeCString(ctx, b);
        if (c) JS_FreeCString(ctx, c);
        return JS_ThrowTypeError(ctx, "%s: argument 2 must be a string", fn_name);
    }
    if (min_args > 2 && (!c)) {
        if (a) JS_FreeCString(ctx, a);
        if (b) JS_FreeCString(ctx, b);
        if (c) JS_FreeCString(ctx, c);
        return JS_ThrowTypeError(ctx, "%s: argument 3 must be a string", fn_name);
    }

    int is_error = 0;
    const char *result = cb(op, a ? a : "", b ? b : "", c ? c : "", &is_error);

    if (a) JS_FreeCString(ctx, a);
    if (b) JS_FreeCString(ctx, b);
    if (c) JS_FreeCString(ctx, c);

    if (is_error || !result) {
        return JS_ThrowTypeError(ctx, "%s: %s", fn_name, result ? result : "failed");
    }

    // JS_NewString 会复制字符串到 QuickJS 的内存
    JSValue ret = JS_NewString(ctx, result);
    return ret;
}

// ---------- ArrayBuffer 零拷贝路径 ----------
// 用于大数据：JS 传 Uint8Array/ArrayBuffer，C 侧直接取指针
// 返回 Uint8Array（JS_NewArrayBufferCopy 会复制，但只复制一次）
static JSValue js_call_crypto_binary(JSContext *ctx, int op, int argc, JSValueConst *argv,
                                     int min_args, const char *fn_name) {
    crypto_callback_binary cb = get_crypto_cb_binary(ctx);
    if (!cb) {
        return JS_ThrowTypeError(ctx, "%s: native crypto binary not registered", fn_name);
    }
    if (argc < min_args) {
        return JS_ThrowTypeError(ctx, "%s requires %d arguments, got %d", fn_name, min_args, argc);
    }

    size_t len0 = 0, len1 = 0, len2 = 0;
    const uint8_t *data0 = NULL, *data1 = NULL, *data2 = NULL;

    // JS_GetArrayBuffer 直接返回内部指针，零拷贝
    if (argc > 0) {
        data0 = JS_GetArrayBuffer(ctx, &len0, argv[0]);
        if (!data0 && min_args > 0) {
            return JS_ThrowTypeError(ctx, "%s: argument 1 must be an ArrayBuffer/Uint8Array", fn_name);
        }
    }
    if (argc > 1) {
        data1 = JS_GetArrayBuffer(ctx, &len1, argv[1]);
        if (!data1 && min_args > 1) {
            return JS_ThrowTypeError(ctx, "%s: argument 2 must be an ArrayBuffer/Uint8Array", fn_name);
        }
    }
    if (argc > 2) {
        data2 = JS_GetArrayBuffer(ctx, &len2, argv[2]);
        if (!data2 && min_args > 2) {
            return JS_ThrowTypeError(ctx, "%s: argument 3 must be an ArrayBuffer/Uint8Array", fn_name);
        }
    }

    size_t out_len = 0;
    int is_error = 0;
    const uint8_t *result = cb(op,
        data0, len0, data1, len1, data2, len2,
        &out_len, &is_error);

    if (is_error || !result) {
        return JS_ThrowTypeError(ctx, "%s: %s", fn_name, "binary failed");
    }

    // JS_NewArrayBufferCopy 会复制数据到 QuickJS 管理的内存
    // 这是唯一一次拷贝（从 Dart 环形缓冲区到 JS）
    JSValue ret = JS_NewArrayBufferCopy(ctx, result, out_len);
    return ret;
}

// ---------- 原生 C 实现（零 Dart 回调，纯 C 计算）----------
// 这些函数直接在 C 层调用 crypto 库，完全消除跨语言往返
// 接受 ArrayBuffer，返回 ArrayBuffer（原始字节）

// 辅助：从 JSValue 取 ArrayBuffer 指针
static const uint8_t *get_ab(JSContext *ctx, JSValueConst val, size_t *len, const char *fn_name, int arg_idx) {
    const uint8_t *p = JS_GetArrayBuffer(ctx, len, val);
    if (!p) {
        JS_ThrowTypeError(ctx, "%s: argument %d must be an ArrayBuffer/Uint8Array", fn_name, arg_idx);
    }
    return p;
}

// MD5：输入 data ArrayBuffer，输出 16 字节摘要
static JSValue js_native_md5(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "md5Native requires 1 argument, got %d", argc);
    size_t len;
    const uint8_t *data = get_ab(ctx, argv[0], &len, "md5Native", 1);
    if (!data) return JS_EXCEPTION;

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    uint8_t digest[16];
    md5(data, len, digest);

    if (bridge) _stats_update(&bridge->stats, len, 16, _now_us() - t0);
    return JS_NewArrayBufferCopy(ctx, digest, 16);
}

// SHA1：输入 data ArrayBuffer，输出 20 字节摘要
static JSValue js_native_sha1(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "sha1Native requires 1 argument, got %d", argc);
    size_t len;
    const uint8_t *data = get_ab(ctx, argv[0], &len, "sha1Native", 1);
    if (!data) return JS_EXCEPTION;

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    uint8_t digest[20];
    sha1(data, len, digest);

    if (bridge) _stats_update(&bridge->stats, len, 20, _now_us() - t0);
    return JS_NewArrayBufferCopy(ctx, digest, 20);
}

// SHA256：输入 data ArrayBuffer，输出 32 字节摘要
static JSValue js_native_sha256(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "sha256Native requires 1 argument, got %d", argc);
    size_t len;
    const uint8_t *data = get_ab(ctx, argv[0], &len, "sha256Native", 1);
    if (!data) return JS_EXCEPTION;

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    uint8_t digest[32];
    sha256(data, len, digest);

    if (bridge) _stats_update(&bridge->stats, len, 32, _now_us() - t0);
    return JS_NewArrayBufferCopy(ctx, digest, 32);
}

// HMAC-SHA256：输入 (data, key) ArrayBuffer，输出 32 字节摘要
static JSValue js_native_hmac_sha256(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "hmacSHA256Native requires 2 arguments, got %d", argc);
    size_t data_len, key_len;
    const uint8_t *data = get_ab(ctx, argv[0], &data_len, "hmacSHA256Native", 1);
    if (!data) return JS_EXCEPTION;
    const uint8_t *key = get_ab(ctx, argv[1], &key_len, "hmacSHA256Native", 2);
    if (!key) return JS_EXCEPTION;

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    uint8_t digest[32];
    hmac_sha256(key, key_len, data, data_len, digest);

    if (bridge) _stats_update(&bridge->stats, data_len + key_len, 32, _now_us() - t0);
    return JS_NewArrayBufferCopy(ctx, digest, 32);
}

// AES-CBC-PKCS7 加密：输入 (plaintext, key, iv) ArrayBuffer，输出 ciphertext ArrayBuffer
static JSValue js_native_aes_encrypt(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "aesEncryptNative requires 3 arguments, got %d", argc);
    size_t pt_len, key_len, iv_len;
    const uint8_t *pt = get_ab(ctx, argv[0], &pt_len, "aesEncryptNative", 1);
    if (!pt) return JS_EXCEPTION;
    const uint8_t *key = get_ab(ctx, argv[1], &key_len, "aesEncryptNative", 2);
    if (!key) return JS_EXCEPTION;
    const uint8_t *iv = get_ab(ctx, argv[2], &iv_len, "aesEncryptNative", 3);
    if (!iv) return JS_EXCEPTION;

    if (key_len != 16 && key_len != 24 && key_len != 32) {
        return JS_ThrowTypeError(ctx, "aesEncryptNative: key length must be 16/24/32, got %d", (int)key_len);
    }
    if (iv_len != 16) {
        return JS_ThrowTypeError(ctx, "aesEncryptNative: iv length must be 16, got %d", (int)iv_len);
    }

    aes_ctx_t actx;
    if (aes_init(&actx, key, key_len) != 0) {
        return JS_ThrowTypeError(ctx, "aesEncryptNative: key expansion failed");
    }

    // 密文长度 = 明文长度向上取 16 的倍数 + padding
    size_t max_out = pt_len + 16;
    uint8_t *out = (uint8_t *)malloc(max_out);
    if (!out) return JS_ThrowTypeError(ctx, "aesEncryptNative: out of memory");

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    size_t out_len = aes_cbc_encrypt(&actx, iv, pt, pt_len, out);

    if (bridge) _stats_update(&bridge->stats, pt_len, out_len == (size_t)-1 ? 0 : out_len, _now_us() - t0);

    if (out_len == (size_t)-1) {
        free(out);
        return JS_ThrowTypeError(ctx, "aesEncryptNative: encryption failed");
    }

    JSValue ret = JS_NewArrayBufferCopy(ctx, out, out_len);
    free(out);
    return ret;
}

// AES-CBC-PKCS7 解密：输入 (ciphertext, key, iv) ArrayBuffer，输出 plaintext ArrayBuffer
static JSValue js_native_aes_decrypt(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "aesDecryptNative requires 3 arguments, got %d", argc);
    size_t ct_len, key_len, iv_len;
    const uint8_t *ct = get_ab(ctx, argv[0], &ct_len, "aesDecryptNative", 1);
    if (!ct) return JS_EXCEPTION;
    const uint8_t *key = get_ab(ctx, argv[1], &key_len, "aesDecryptNative", 2);
    if (!key) return JS_EXCEPTION;
    const uint8_t *iv = get_ab(ctx, argv[2], &iv_len, "aesDecryptNative", 3);
    if (!iv) return JS_EXCEPTION;

    if (key_len != 16 && key_len != 24 && key_len != 32) {
        return JS_ThrowTypeError(ctx, "aesDecryptNative: key length must be 16/24/32, got %d", (int)key_len);
    }
    if (iv_len != 16) {
        return JS_ThrowTypeError(ctx, "aesDecryptNative: iv length must be 16, got %d", (int)iv_len);
    }
    if (ct_len == 0 || ct_len % 16 != 0) {
        return JS_ThrowTypeError(ctx, "aesDecryptNative: ciphertext length must be multiple of 16, got %d", (int)ct_len);
    }

    aes_ctx_t actx;
    if (aes_init(&actx, key, key_len) != 0) {
        return JS_ThrowTypeError(ctx, "aesDecryptNative: key expansion failed");
    }

    uint8_t *out = (uint8_t *)malloc(ct_len);
    if (!out) return JS_ThrowTypeError(ctx, "aesDecryptNative: out of memory");

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    size_t out_len = aes_cbc_decrypt(&actx, iv, ct, ct_len, out);

    if (bridge) _stats_update(&bridge->stats, ct_len, out_len == (size_t)-1 ? 0 : out_len, _now_us() - t0);

    if (out_len == (size_t)-1) {
        free(out);
        return JS_ThrowTypeError(ctx, "aesDecryptNative: decryption failed (bad padding or key)");
    }

    JSValue ret = JS_NewArrayBufferCopy(ctx, out, out_len);
    free(out);
    return ret;
}

// ---------- JS 函数注册 ----------
// 字符串路径（小数据，< 1KB）
static JSValue js_crypto_aes_decrypt(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 0, argc, argv, 3, "aesDecrypt");
}
static JSValue js_crypto_aes_encrypt(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 1, argc, argv, 3, "aesEncrypt");
}
static JSValue js_crypto_md5(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 2, argc, argv, 1, "md5");
}
static JSValue js_crypto_sha256(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 3, argc, argv, 1, "sha256");
}
static JSValue js_crypto_hmac_sha256(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 4, argc, argv, 2, "hmacSHA256");
}
static JSValue js_crypto_sha1(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 5, argc, argv, 1, "sha1");
}

// ArrayBuffer 路径（大数据，>= 1KB）
static JSValue js_crypto_aes_decrypt_bin(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto_binary(ctx, 0, argc, argv, 3, "aesDecryptBin");
}
static JSValue js_crypto_aes_encrypt_bin(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto_binary(ctx, 1, argc, argv, 3, "aesEncryptBin");
}
static JSValue js_crypto_md5_bin(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    return js_call_crypto_binary(ctx, 2, argc, argv, 1, "md5Bin");
}
static JSValue js_crypto_sha256_bin(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    return js_call_crypto_binary(ctx, 3, argc, argv, 1, "sha256Bin");
}
static JSValue js_crypto_hmac_sha256_bin(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto_binary(ctx, 4, argc, argv, 2, "hmacSHA256Bin");
}
static JSValue js_crypto_sha1_bin(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    return js_call_crypto_binary(ctx, 5, argc, argv, 1, "sha1Bin");
}

QuickJSBridge *quickjs_bridge_create(void) {
    return quickjs_bridge_create_with_config(0, 0);
}

QuickJSBridge *quickjs_bridge_create_with_config(uint64_t memory_limit, uint64_t stack_size) {
    QuickJSBridge *bridge = (QuickJSBridge *)malloc(sizeof(QuickJSBridge));
    if (!bridge) return NULL;

    bridge->runtime = JS_NewRuntime();
    if (!bridge->runtime) {
        free(bridge);
        return NULL;
    }

    // 动态资源配置：0 表示使用默认值
    if (memory_limit == 0) memory_limit = 256ULL * 1024 * 1024;  // 256MB
    if (stack_size == 0) stack_size = 256ULL * 1024;              // 256KB
    JS_SetMemoryLimit(bridge->runtime, (size_t)memory_limit);
    JS_SetMaxStackSize(bridge->runtime, (size_t)stack_size);

    bridge->ctx = JS_NewContext(bridge->runtime);
    if (!bridge->ctx) {
        JS_FreeRuntime(bridge->runtime);
        free(bridge);
        return NULL;
    }

    // 上下文绑定：通过 opaque 指针让 JS 函数能拿到 bridge 实例
    // 用于 js_call_crypto/js_call_crypto_binary 获取上下文绑定的回调
    bridge->crypto_cb = NULL;
    bridge->crypto_cb_binary = NULL;
    memset(&bridge->stats, 0, sizeof(crypto_stats_t));
    JS_SetContextOpaque(bridge->ctx, bridge);

    // 注册原生加密全局对象 __nativeCrypto
    // 字符串路径：aesDecrypt/aesEncrypt/md5/sha256/hmacSHA256/sha1
    // ArrayBuffer 路径：aesDecryptBin/aesEncryptBin/md5Bin/sha256Bin/hmacSHA256Bin/sha1Bin
    JSValue global_obj = JS_GetGlobalObject(bridge->ctx);
    JSValue crypto_obj = JS_NewObject(bridge->ctx);

    // 字符串路径
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesDecrypt",
        JS_NewCFunction(bridge->ctx, js_crypto_aes_decrypt, "aesDecrypt", 3));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesEncrypt",
        JS_NewCFunction(bridge->ctx, js_crypto_aes_encrypt, "aesEncrypt", 3));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "md5",
        JS_NewCFunction(bridge->ctx, js_crypto_md5, "md5", 1));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "sha256",
        JS_NewCFunction(bridge->ctx, js_crypto_sha256, "sha256", 1));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "hmacSHA256",
        JS_NewCFunction(bridge->ctx, js_crypto_hmac_sha256, "hmacSHA256", 2));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "sha1",
        JS_NewCFunction(bridge->ctx, js_crypto_sha1, "sha1", 1));

    // ArrayBuffer 路径（零拷贝，大数据）
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesDecryptBin",
        JS_NewCFunction(bridge->ctx, js_crypto_aes_decrypt_bin, "aesDecryptBin", 3));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesEncryptBin",
        JS_NewCFunction(bridge->ctx, js_crypto_aes_encrypt_bin, "aesEncryptBin", 3));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "md5Bin",
        JS_NewCFunction(bridge->ctx, js_crypto_md5_bin, "md5Bin", 1));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "sha256Bin",
        JS_NewCFunction(bridge->ctx, js_crypto_sha256_bin, "sha256Bin", 1));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "hmacSHA256Bin",
        JS_NewCFunction(bridge->ctx, js_crypto_hmac_sha256_bin, "hmacSHA256Bin", 2));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "sha1Bin",
        JS_NewCFunction(bridge->ctx, js_crypto_sha1_bin, "sha1Bin", 1));

    // 原生 C 实现路径（零 Dart 回调，纯 C 计算，接受/返回 ArrayBuffer）
    // 优先于字符串/ArrayBuffer 回调路径
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "md5Native",
        JS_NewCFunction(bridge->ctx, js_native_md5, "md5Native", 1));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "sha1Native",
        JS_NewCFunction(bridge->ctx, js_native_sha1, "sha1Native", 1));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "sha256Native",
        JS_NewCFunction(bridge->ctx, js_native_sha256, "sha256Native", 1));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "hmacSHA256Native",
        JS_NewCFunction(bridge->ctx, js_native_hmac_sha256, "hmacSHA256Native", 2));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesEncryptNative",
        JS_NewCFunction(bridge->ctx, js_native_aes_encrypt, "aesEncryptNative", 3));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesDecryptNative",
        JS_NewCFunction(bridge->ctx, js_native_aes_decrypt, "aesDecryptNative", 3));

    JS_SetPropertyStr(bridge->ctx, global_obj, "__nativeCrypto", crypto_obj);
    JS_FreeValue(bridge->ctx, global_obj);

    return bridge;
}

const char *quickjs_bridge_eval(QuickJSBridge *bridge, const char *script, int *is_error) {
    if (!bridge || !bridge->ctx || !script) {
        if (is_error) *is_error = 1;
        return NULL;
    }

    JSValue val = JS_Eval(bridge->ctx, script, strlen(script), "<eval>", JS_EVAL_TYPE_GLOBAL);

    if (JS_IsException(val)) {
        JSValue exception = JS_GetException(bridge->ctx);
        const char *str = JS_ToCString(bridge->ctx, exception);
        JS_FreeValue(bridge->ctx, exception);
        JS_FreeValue(bridge->ctx, val);
        if (is_error) *is_error = 1;
        if (str) {
            char *result = strdup(str);
            JS_FreeCString(bridge->ctx, str);
            return result;
        }
        return strdup("Unknown error");
    }

    const char *str = JS_ToCString(bridge->ctx, val);
    JS_FreeValue(bridge->ctx, val);
    if (is_error) *is_error = 0;

    if (str) {
        char *result = strdup(str);
        JS_FreeCString(bridge->ctx, str);
        return result;
    }

    return strdup("");
}

void quickjs_bridge_free_string(const char *str) {
    if (str) {
        free((void *)str);
    }
}

void quickjs_bridge_dispose(QuickJSBridge *bridge) {
    if (!bridge) return;
    if (bridge->ctx) {
        JS_FreeContext(bridge->ctx);
    }
    if (bridge->runtime) {
        JS_FreeRuntime(bridge->runtime);
    }
    free(bridge);
}
