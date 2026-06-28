#ifndef QUICKJS_BRIDGE_H
#define QUICKJS_BRIDGE_H

#include "quickjs.h"
#include "memory_tracker.h"
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

// ---------- 原生解析工具（不需要 bridge 上下文，纯函数）----------
// 解析加速：高频字符串操作下沉到 C 层
// 返回的字符串用 quickjs_bridge_free_string 释放

// HTML 实体反转义：&amp; &lt; &gt; &quot; &#39; &nbsp;
const char *quickjs_bridge_unescape_html(const char *input, size_t input_len, size_t *output_len);

// URL 编码（percent-encode，RFC 3986）
const char *quickjs_bridge_url_encode(const char *input, size_t input_len, size_t *output_len);

// URL 解码（percent-decode，+ 解码为空格）
const char *quickjs_bridge_url_decode(const char *input, size_t input_len, size_t *output_len);

// ---------- Batch 1: 纯 C 原生函数（不依赖 bridge 上下文）----------
// 替代 NativeChannel 中的加密/编码/HTML 方法，绕过 Kotlin MethodChannel
// 所有输出字符串用 quickjs_bridge_free_string 释放
//
// 注意：这些函数不接收 bridge 参数，不依赖 QuickJS 运行时，
//       纯 C 计算后返回 malloc 字符串。
//       适合 Dart FFI 直接调用，全程绕过 MethodChannel。

// MD5 哈希：输入 UTF-8 字符串，输出 32 字符 hex 字符串
const char *quickjs_bridge_md5(const char *input, size_t input_len, size_t *output_len);

// SHA1 哈希：输入 UTF-8 字符串，输出 40 字符 hex 字符串
const char *quickjs_bridge_sha1(const char *input, size_t input_len, size_t *output_len);

// SHA256 哈希：输入 UTF-8 字符串，输出 64 字符 hex 字符串
const char *quickjs_bridge_sha256(const char *input, size_t input_len, size_t *output_len);

// HMAC-SHA256：输入 (data, key)，输出 64 字符 hex 字符串
const char *quickjs_bridge_hmac_sha256(const char *data, size_t data_len,
                                        const char *key, size_t key_len,
                                        size_t *output_len);

// AES-CBC-PKCS7 解密：输入 (base64_密文, key_utf8, iv_utf8)，输出 UTF-8 明文
const char *quickjs_bridge_aes_decrypt(const char *cipher_b64, size_t b64_len,
                                        const char *key, size_t key_len,
                                        const char *iv, size_t iv_len,
                                        size_t *output_len);

// AES-CBC-PKCS7 加密：输入 (明文_utf8, key_utf8, iv_utf8)，输出 base64 密文
const char *quickjs_bridge_aes_encrypt(const char *plaintext, size_t pt_len,
                                        const char *key, size_t key_len,
                                        const char *iv, size_t iv_len,
                                        size_t *output_len);

// Base64 编码：输入 UTF-8 字符串，输出 Base64 字符串
const char *quickjs_bridge_base64_encode(const char *input, size_t input_len, size_t *output_len);

// Base64 解码：输入 Base64 字符串，输出 UTF-8 字符串
const char *quickjs_bridge_base64_decode(const char *input, size_t input_len, size_t *output_len);

// ---------- C 原生 HTML 解析 + CSS 选择器引擎 ----------
// 解析加速：替代 Dart html 包的 querySelectorAll，消除多层 fallback 开销
// 原子调用：HTML 解析 + CSS 查询 + 属性提取 一次完成
//
// html/html_len: HTML 字符串
// selector: CSS 选择器（支持 tag .class #id [attr] [attr=val] descendant(空格) child(>) :nth-child :eq）
// attr: 提取的属性名，特殊值: "@text"=文本, "@html"=内部HTML, "@outerHtml"=外部HTML, "@tag"=标签名
// list_mode: 1=返回 JSON 数组 ["v1","v2"], 0=返回第一个匹配的纯字符串
// is_error: 输出参数，0=成功, 1=失败
// 返回: malloc 分配的字符串，调用方用 quickjs_bridge_free_string 释放
const char *quickjs_bridge_html_query_extract(
    const char *html, size_t html_len,
    const char *selector,
    const char *attr,
    int list_mode,
    int *is_error);

// ---------- P1: 句柄化 API（替代裸指针，防止野指针）----------
// 上层 Dart 只持有 uint32_t 句柄，操作时查表拿指针
// 旧裸指针 API 保留向后兼容，新代码优先使用句柄 API

uint32_t quickjs_bridge_create_handle(void);
uint32_t quickjs_bridge_create_handle_with_config(uint64_t memory_limit, uint64_t stack_size);
const char *quickjs_bridge_eval_handle(uint32_t handle, const char *script, int *is_error);
int quickjs_bridge_precompile_handle(uint32_t handle, const char *script);
void quickjs_bridge_dispose_handle(uint32_t handle);
void quickjs_bridge_clear_cache_handle(uint32_t handle);

// ---------- P1: 内存统计 API ----------
// 全局内存分配/释放统计，通过 FFI 暴露给 Dart 做线上监控

memory_stats_t quickjs_bridge_get_memory_stats(void);
void quickjs_bridge_reset_memory_stats(void);
int quickjs_bridge_get_active_handle_count(void);

// ---------- 参考 quickjs-ng：JS 引擎内部内存统计 + GC 控制 ----------
// 暴露 QuickJS 内部的 JSMemoryUsage（20 个分项统计）

void quickjs_bridge_get_js_memory_stats(QuickJSBridge *bridge, JSMemoryUsage *out);
void quickjs_bridge_get_js_memory_stats_handle(uint32_t handle, JSMemoryUsage *out);
void quickjs_bridge_run_gc(QuickJSBridge *bridge);
void quickjs_bridge_run_gc_handle(uint32_t handle);

// ---------- 参考 quickjs-ng/quickjs-zh：高价值 API 暴露 ----------

/// 检测源码是否为 ES 模块（参考 quickjs-zh JS_DetectModule）
int quickjs_bridge_detect_module(const char *input, size_t input_len);

/// 检查当前 context 是否有异常（参考 quickjs-zh JS_HasException）
int quickjs_bridge_has_exception(QuickJSBridge *bridge);

/// 设置 Atomics.wait 可用性（参考 quickjs-ng JS_SetCanBlock）
void quickjs_bridge_set_can_block(QuickJSBridge *bridge, int can_block);

/// 流式打印 JS 值（参考 quickjs-zh JS_PrintValue）
/// 返回 malloc 字符串，需用 quickjs_bridge_free_string 释放
const char *quickjs_bridge_print_value(QuickJSBridge *bridge, const char *js_expr,
                                        int max_depth, int max_string_length);

/// 获取 Promise 状态（参考 quickjs-zh JS_PromiseState）
/// 返回: 0=非Promise, 1=pending, 2=fulfilled, 3=rejected
int quickjs_bridge_promise_state(QuickJSBridge *bridge, const char *var_name);

/// 设置不可捕获异常（参考 quickjs-zh JS_SetUncatchableException）
void quickjs_bridge_set_uncatchable_exception(QuickJSBridge *bridge, int flag);

/// 获取 QuickJS 版本字符串
const char *quickjs_bridge_get_version(void);

// ---------- P2: 超时熔断 API ----------
// 防止 JS 死循环/无限递归阻塞 C 调度线程
// 设置超时后，eval 超时会中断 QuickJS 上下文并返回 "ScriptTimeoutError"

void quickjs_bridge_set_eval_timeout(QuickJSBridge *bridge, uint64_t timeout_ms);
void quickjs_bridge_set_eval_timeout_handle(uint32_t handle, uint64_t timeout_ms);
int quickjs_bridge_was_eval_interrupted(QuickJSBridge *bridge);

#ifdef __cplusplus
}
#endif

#endif /* QUICKJS_BRIDGE_H */
