#ifndef QUICKJS_BRIDGE_H
#define QUICKJS_BRIDGE_H

#include "quickjs.h"

#ifdef __cplusplus
extern "C" {
#endif

// 简化的 QuickJS 桥接 API
// Swift 通过这些函数调用 QuickJS，避免直接处理 JSValue
typedef struct QuickJSBridge QuickJSBridge;

// 创建 QuickJS 运行时
QuickJSBridge *quickjs_bridge_create(void);

// 执行 JS 脚本，返回字符串结果
// 返回的字符串需要调用者用 free() 释放
// is_error: 0=成功, 1=异常
const char *quickjs_bridge_eval(QuickJSBridge *bridge, const char *script, int *is_error);

// 释放 QuickJS 运行时
void quickjs_bridge_dispose(QuickJSBridge *bridge);

// 释放 eval 返回的字符串
void quickjs_bridge_free_string(const char *str);

// ---------- 原生加密桥接（通用回调）----------
// 一个回调支持所有加解密操作，通过 op 区分
// 返回的 const char* 由 Dart 端管理（环形缓冲区），C 层不释放

// 加密操作类型
//   0 = AES-CBC-PKCS7 解密  args: (data_b64, key_utf8, iv_utf8)
//   1 = AES-CBC-PKCS7 加密  args: (data_utf8, key_utf8, iv_utf8) -> base64
//   2 = MD5                  args: (data_utf8, NULL, NULL)
//   3 = SHA256               args: (data_utf8, NULL, NULL)
//   4 = HMAC-SHA256          args: (data_utf8, key_utf8, NULL)
//   5 = SHA1                 args: (data_utf8, NULL, NULL)
typedef const char *(*crypto_callback)(int op, const char *a, const char *b, const char *c, int *is_error);

// 注册加密回调（全局，所有 runtime 共享）
void quickjs_bridge_set_crypto_callback(crypto_callback cb);

#ifdef __cplusplus
}
#endif

#endif /* QUICKJS_BRIDGE_H */
