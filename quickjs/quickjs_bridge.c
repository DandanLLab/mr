#include "quickjs_bridge.h"
#include <stdlib.h>
#include <string.h>

struct QuickJSBridge {
    JSRuntime *runtime;
    JSContext *ctx;
};

// ---------- 原生加密回调（全局，所有 runtime 共享）----------
static crypto_callback g_crypto_cb = NULL;

void quickjs_bridge_set_crypto_callback(crypto_callback cb) {
    g_crypto_cb = cb;
}

// 通用加密调度：调用 Dart 回调，返回 JSValue
// 失败抛 JS 异常，成功返回字符串
static JSValue js_call_crypto(JSContext *ctx, int op, int argc, JSValueConst *argv,
                              int min_args, const char *fn_name) {
    if (!g_crypto_cb) {
        return JS_ThrowTypeError(ctx, "%s: native crypto not registered", fn_name);
    }
    if (argc < min_args) {
        return JS_ThrowTypeError(ctx, "%s requires %d arguments", fn_name, min_args);
    }

    const char *a = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
    const char *b = argc > 1 ? JS_ToCString(ctx, argv[1]) : NULL;
    const char *c = argc > 2 ? JS_ToCString(ctx, argv[2]) : NULL;

    if (min_args > 0 && (!a)) {
        if (a) JS_FreeCString(ctx, a);
        if (b) JS_FreeCString(ctx, b);
        if (c) JS_FreeCString(ctx, c);
        return JS_ThrowTypeError(ctx, "%s: arguments must be strings", fn_name);
    }

    int is_error = 0;
    const char *result = g_crypto_cb(op, a ? a : "", b ? b : "", c ? c : "", &is_error);

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

// JS 函数: __nativeCrypto.aesDecrypt(data_b64, key_utf8, iv_utf8)
static JSValue js_crypto_aes_decrypt(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 0, argc, argv, 3, "aesDecrypt");
}

// JS 函数: __nativeCrypto.aesEncrypt(data_utf8, key_utf8, iv_utf8) -> base64
static JSValue js_crypto_aes_encrypt(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 1, argc, argv, 3, "aesEncrypt");
}

// JS 函数: __nativeCrypto.md5(data_utf8)
static JSValue js_crypto_md5(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 2, argc, argv, 1, "md5");
}

// JS 函数: __nativeCrypto.sha256(data_utf8)
static JSValue js_crypto_sha256(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 3, argc, argv, 1, "sha256");
}

// JS 函数: __nativeCrypto.hmacSHA256(data_utf8, key_utf8)
static JSValue js_crypto_hmac_sha256(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 4, argc, argv, 2, "hmacSHA256");
}

// JS 函数: __nativeCrypto.sha1(data_utf8)
static JSValue js_crypto_sha1(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    return js_call_crypto(ctx, 5, argc, argv, 1, "sha1");
}

QuickJSBridge *quickjs_bridge_create(void) {
    QuickJSBridge *bridge = (QuickJSBridge *)malloc(sizeof(QuickJSBridge));
    if (!bridge) return NULL;

    bridge->runtime = JS_NewRuntime();
    if (!bridge->runtime) {
        free(bridge);
        return NULL;
    }

    // 设置内存限制（256MB）和栈大小（256KB）
    JS_SetMemoryLimit(bridge->runtime, 256 * 1024 * 1024);
    JS_SetMaxStackSize(bridge->runtime, 256 * 1024);

    bridge->ctx = JS_NewContext(bridge->runtime);
    if (!bridge->ctx) {
        JS_FreeRuntime(bridge->runtime);
        free(bridge);
        return NULL;
    }

    // 注册原生加密全局对象 __nativeCrypto
    // JS 代码可通过 __nativeCrypto.xxx() 调用原生加解密
    // 失败回退到纯 JS 的 CryptoJS 实现
    JSValue global_obj = JS_GetGlobalObject(bridge->ctx);
    JSValue crypto_obj = JS_NewObject(bridge->ctx);
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
