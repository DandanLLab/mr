#ifndef QUICKJS_BRIDGE_H
#define QUICKJS_BRIDGE_H

#include "quickjs.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 简化的 QuickJS 桥接 API
// Swift 通过这些函数调用 QuickJS，避免直接处理 JSValue
typedef struct QuickJSBridge QuickJSBridge;

// ---------- 性能统计 ----------
// 累计统计 C 原生加密函数的调用情况
typedef struct {
    uint64_t total_calls;      // 总调用次数
    uint64_t total_bytes_in;   // 总输入字节数
    uint64_t total_bytes_out;  // 总输出字节数
    uint64_t total_us;         // 总耗时（微秒）
    uint64_t max_us;           // 单次最大耗时（微秒）
    uint64_t min_us;           // 单次最小耗时（微秒，0 表示未初始化）
} crypto_stats_t;

// 创建 QuickJS 运行时
QuickJSBridge *quickjs_bridge_create(void);

// 创建 QuickJS 运行时（带配置）
// memory_limit: 内存上限（字节），0 表示默认 256MB
// stack_size: 栈大小（字节），0 表示默认 256KB
QuickJSBridge *quickjs_bridge_create_with_config(uint64_t memory_limit, uint64_t stack_size);

// 执行 JS 脚本，返回字符串结果
// 返回的字符串需要调用者用 free() 释放
// is_error: 0=成功, 1=异常
const char *quickjs_bridge_eval(QuickJSBridge *bridge, const char *script, int *is_error);

// 释放 QuickJS 运行时
void quickjs_bridge_dispose(QuickJSBridge *bridge);

// 释放 eval 返回的字符串
void quickjs_bridge_free_string(const char *str);

// ---------- Phase 4: 字节码缓存 ----------
// 预编译脚本到字节码缓存（不执行），后续 eval 同一脚本时跳过词法/语法分析
// 返回 0 成功，-1 失败（语法错误等）
int quickjs_bridge_precompile(QuickJSBridge *bridge, const char *script);

// 清空字节码缓存（书源切换、内存压力场景）
void quickjs_bridge_clear_bytecode_cache(QuickJSBridge *bridge);

// 获取 C 原生加密的性能统计（累计，每个 bridge 独立）
// 返回当前 stats 的快照（拷贝）
crypto_stats_t quickjs_bridge_get_crypto_stats(QuickJSBridge *bridge);

// 重置统计计数器
void quickjs_bridge_reset_crypto_stats(QuickJSBridge *bridge);

// ---------- 原生加密桥接（字符串路径）----------
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

// 注册字符串加密回调（全局，所有 runtime 共享）
void quickjs_bridge_set_crypto_callback(crypto_callback cb);

// 注册字符串加密回调（绑定到指定 bridge 实例，多线程安全）
void quickjs_bridge_set_crypto_callback_for(QuickJSBridge *bridge, crypto_callback cb);

// ---------- 原生加密桥接（ArrayBuffer 零拷贝路径）----------
// 用于大数据（>=1KB）：JS 传 Uint8Array，C 侧直接取指针，零拷贝
// 返回的 uint8_t* 由 Dart 端管理（环形缓冲区），C 层不释放
//
// 参数：op, data0/len0, data1/len1, data2/len2, out_len(输出), is_error(输出)
typedef const uint8_t *(*crypto_callback_binary)(
    int op,
    const uint8_t *data0, size_t len0,
    const uint8_t *data1, size_t len1,
    const uint8_t *data2, size_t len2,
    size_t *out_len, int *is_error);

// 注册二进制加密回调（全局，所有 runtime 共享）
void quickjs_bridge_set_crypto_callback_binary(crypto_callback_binary cb);

// 注册二进制加密回调（绑定到指定 bridge 实例，多线程安全）
void quickjs_bridge_set_crypto_callback_binary_for(QuickJSBridge *bridge, crypto_callback_binary cb);

#ifdef __cplusplus
}
#endif

#endif /* QUICKJS_BRIDGE_H */
