#include "quickjs_bridge.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "crypto/md5.h"
#include "crypto/sha1.h"
#include "crypto/sha256.h"
#include "crypto/hmac_sha256.h"
#include "crypto/aes.h"
#include "lzstring.h"
#include "batch_decompress.h"
#include "html_native.h"
#include "charset_conv.h"
#include "handle_table.h"
#include "memory_tracker.h"

// ---------- P1: 全局线程安全 + 句柄管理 + 内存统计 ----------
// POSIX 线程兼容层
#ifndef _WIN32
  #include <pthread.h>
#else
  #include <windows.h>
  typedef CRITICAL_SECTION pthread_mutex_t;
  static int pthread_mutex_init(pthread_mutex_t *m, void *a) {
    (void)a; InitializeCriticalSection(m); return 0;
  }
  static int pthread_mutex_destroy(pthread_mutex_t *m) { DeleteCriticalSection(m); return 0; }
  static int pthread_mutex_lock(pthread_mutex_t *m) { EnterCriticalSection(m); return 0; }
  static int pthread_mutex_unlock(pthread_mutex_t *m) { LeaveCriticalSection(m); return 0; }
#endif

// 全局互斥锁：保护 QuickJS runtime 调用（QuickJS 非线程安全）
static pthread_mutex_t _g_bridge_mutex;
static int _g_mutex_initialized = 0;

// 全局句柄表：管理 QuickJSBridge* 生命周期，防止 Dart GC 后野指针
static handle_table_t *_g_bridge_handles = NULL;

// 初始化全局设施（幂等）
static void _ensure_globals(void) {
    if (!_g_mutex_initialized) {
        pthread_mutex_init(&_g_bridge_mutex, NULL);
        _g_bridge_handles = handle_table_create(16);
        memory_tracker_init();
        _g_mutex_initialized = 1;
    }
}

// P4: 输入长度限制 — 防止超大报文导致内存膨胀/解析崩溃
#define MAX_SCRIPT_SIZE    (1ULL * 1024 * 1024)    // JS 脚本：1MB
#define MAX_HTML_SIZE      (10ULL * 1024 * 1024)   // HTML 输入：10MB
#define MAX_CRYPTO_SIZE    (10ULL * 1024 * 1024)   // 加解密输入：10MB
#define MAX_BASE64_SIZE    (10ULL * 1024 * 1024)   // Base64 输入：10MB
#define MAX_HTTP_BODY_SIZE (50ULL * 1024 * 1024)   // HTTP 响应体：50MB

// ---------- Phase 4: 字节码缓存 ----------
// 跳过词法分析/语法解析/字节码生成阶段，对重复执行的脚本直接走 JS_EvalFunction
#define BYTECODE_CACHE_SIZE 32

typedef struct {
    uint64_t hash;        // 脚本 FNV-1a 哈希（快速比较）
    char *script;         // 脚本源码（owned，strlen 字节 + '\0'）
    size_t script_len;    // 脚本长度
    JSValue bytecode;     // 编译后的字节码（owned，JS_DupValue 持有）
    uint64_t hits;        // 命中次数（LFU 淘汰策略依据）
    int in_use;           // 槽位是否占用
} bytecode_cache_entry_t;

struct QuickJSBridge {
    JSRuntime *runtime;
    JSContext *ctx;
    // 上下文绑定的加密回调（每个 bridge 实例独立，多线程安全）
    // 为 NULL 时回退到全局回调（向后兼容）
    crypto_callback crypto_cb;
    crypto_callback_binary crypto_cb_binary;
    // 性能统计（每个 bridge 独立）
    crypto_stats_t stats;
    // Phase 4: 字节码缓存（每个 bridge 独立）
    bytecode_cache_entry_t bytecode_cache[BYTECODE_CACHE_SIZE];
    int bytecode_cache_count;
    // P2: 超时熔断
    uint64_t eval_start_time_us;  // 当前 eval 开始时间（微秒）
    uint64_t eval_timeout_us;     // 超时阈值（微秒），0 = 无超时
    int eval_interrupted;         // 是否被超时中断
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

// P2: QuickJS 中断处理器 — 超时熔断
// QuickJS 周期性调用此函数，返回非 0 值中断当前脚本
// 注意：必须位于 struct QuickJSBridge 定义之后、_now_us 定义之后
static int _interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    QuickJSBridge *bridge = (QuickJSBridge *)opaque;
    if (!bridge || bridge->eval_timeout_us == 0) return 0;
    uint64_t now = _now_us();
    if (now - bridge->eval_start_time_us > bridge->eval_timeout_us) {
        bridge->eval_interrupted = 1;
        return 1; // 中断执行，QuickJS 会抛出异常
    }
    return 0;
}

// Base64 前向声明（定义在文件后段，但 AES+LZ 组合早于定义处使用）
static uint8_t *b64_decode(const char *src, size_t src_len, size_t *out_len);
static char *b64_encode(const uint8_t *src, size_t src_len, size_t *out_len);

// _str_dup 本地副本（html_native.c 中也有同名 static，互不冲突）
// 返回 malloc 分配的字符串，调用方负责 free
static char *_str_dup(const char *s, size_t len) {
    char *p = (char *)malloc(len + 1);
    if (!p) return NULL;
    memcpy(p, s, len);
    p[len] = 0;
    return p;
}

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

// ---------- Phase 4: 字节码缓存辅助函数 ----------

// FNV-1a 64-bit 哈希（快速比较脚本，避免逐字节 strcmp）
static uint64_t _fnv1a_hash(const char *s, size_t len) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (unsigned char)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

// 查找字节码缓存：命中返回 JS_DupValue 后的字节码（调用方需 JS_FreeValue），
// 未命中返回 JS_NULL
static JSValue _bytecode_cache_lookup(QuickJSBridge *bridge, const char *script, size_t len) {
    uint64_t hash = _fnv1a_hash(script, len);
    for (int i = 0; i < BYTECODE_CACHE_SIZE; i++) {
        bytecode_cache_entry_t *e = &bridge->bytecode_cache[i];
        if (e->in_use && e->hash == hash && e->script_len == len &&
            memcmp(e->script, script, len) == 0) {
            e->hits++;
            return JS_DupValue(bridge->ctx, e->bytecode);
        }
    }
    return JS_NULL;
}

// 存入字节码缓存（LFU 淘汰：命中次数最少的条目被替换）
// bytecode 参数：函数内部会 JS_DupValue 持有，调用方仍保留自己的引用
static void _bytecode_cache_store(QuickJSBridge *bridge, const char *script,
                                   size_t len, JSValueConst bytecode) {
    int target = -1;
    uint64_t min_hits = (uint64_t)-1;
    for (int i = 0; i < BYTECODE_CACHE_SIZE; i++) {
        if (!bridge->bytecode_cache[i].in_use) {
            target = i;
            break;
        }
        if (bridge->bytecode_cache[i].hits < min_hits) {
            min_hits = bridge->bytecode_cache[i].hits;
            target = i;
        }
    }
    if (target < 0) return;

    bytecode_cache_entry_t *e = &bridge->bytecode_cache[target];
    if (e->in_use) {
        free(e->script);
        JS_FreeValue(bridge->ctx, e->bytecode);
    } else {
        bridge->bytecode_cache_count++;
    }
    e->hash = _fnv1a_hash(script, len);
    e->script = (char *)malloc(len + 1);
    memcpy(e->script, script, len);
    e->script[len] = 0;
    e->script_len = len;
    e->bytecode = JS_DupValue(bridge->ctx, bytecode);
    e->hits = 0;
    e->in_use = 1;
}

// 清空字节码缓存（必须在 JS_FreeContext 之前调用）
static void _bytecode_cache_clear(QuickJSBridge *bridge) {
    for (int i = 0; i < BYTECODE_CACHE_SIZE; i++) {
        bytecode_cache_entry_t *e = &bridge->bytecode_cache[i];
        if (e->in_use) {
            free(e->script);
            JS_FreeValue(bridge->ctx, e->bytecode);
            memset(e, 0, sizeof(*e));
        }
    }
    bridge->bytecode_cache_count = 0;
}

// ---------- 原生解析工具（不需要 bridge 上下文，纯函数）----------
// 解析加速：将高频字符串操作下沉到 C 层，消除 Dart 正则编译 + lambda 开销

// HTML 实体反转义：单次扫描替代 Dart 的 RegExp + replaceAllMapped
// 支持：&amp; &lt; &gt; &quot; &#39; &nbsp;
// 返回 malloc 分配的字符串（调用方用 quickjs_bridge_free_string 释放）
const char *quickjs_bridge_unescape_html(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len == 0) {
        char *out = (char *)malloc(1);
        if (out) out[0] = 0;
        return out;
    }
    // 反转义后长度 <= 输入长度，分配 input_len+1 足够
    char *output = (char *)malloc(input_len + 1);
    if (!output) return NULL;
    size_t out_pos = 0;

    for (size_t i = 0; i < input_len; ) {
        if (input[i] == '&') {
            // 按长度从长到短匹配，避免前缀冲突
            if (i + 6 <= input_len && memcmp(input + i, "&nbsp;", 6) == 0) {
                output[out_pos++] = ' '; i += 6;
            } else if (i + 6 <= input_len && memcmp(input + i, "&quot;", 6) == 0) {
                output[out_pos++] = '"'; i += 6;
            } else if (i + 5 <= input_len && memcmp(input + i, "&amp;", 5) == 0) {
                output[out_pos++] = '&'; i += 5;
            } else if (i + 5 <= input_len && memcmp(input + i, "&#39;", 5) == 0) {
                output[out_pos++] = '\''; i += 5;
            } else if (i + 4 <= input_len && memcmp(input + i, "&lt;", 4) == 0) {
                output[out_pos++] = '<'; i += 4;
            } else if (i + 4 <= input_len && memcmp(input + i, "&gt;", 4) == 0) {
                output[out_pos++] = '>'; i += 4;
            } else {
                output[out_pos++] = input[i++];
            }
        } else {
            output[out_pos++] = input[i++];
        }
    }
    output[out_pos] = 0;
    *output_len = out_pos;
    return output;
}

// URL 编码（percent-encode）：将非安全字符编码为 %XX
// 返回 malloc 分配的字符串（调用方用 quickjs_bridge_free_string 释放）
const char *quickjs_bridge_url_encode(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len == 0) {
        char *out = (char *)malloc(1);
        if (out) out[0] = 0;
        return out;
    }
    // 最坏情况：每个字符编码为 %XX（3倍长度）
    char *output = (char *)malloc(input_len * 3 + 1);
    if (!output) return NULL;
    size_t out_pos = 0;
    static const char hex[] = "0123456789ABCDEF";

    for (size_t i = 0; i < input_len; i++) {
        unsigned char c = (unsigned char)input[i];
        // 安全字符：A-Za-z0-9-_.~ 不编码（RFC 3986 unreserved）
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            output[out_pos++] = c;
        } else {
            output[out_pos++] = '%';
            output[out_pos++] = hex[c >> 4];
            output[out_pos++] = hex[c & 15];
        }
    }
    output[out_pos] = 0;
    *output_len = out_pos;
    return output;
}

// URL 解码（percent-decode）：将 %XX 解码为原始字符，+ 解码为空格
// 返回 malloc 分配的字符串（调用方用 quickjs_bridge_free_string 释放）
const char *quickjs_bridge_url_decode(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len == 0) {
        char *out = (char *)malloc(1);
        if (out) out[0] = 0;
        return out;
    }
    char *output = (char *)malloc(input_len + 1);
    if (!output) return NULL;
    size_t out_pos = 0;

    for (size_t i = 0; i < input_len; ) {
        char c = input[i];
        if (c == '%' && i + 2 < input_len) {
            // 解析两位十六进制
            int hi = -1, lo = -1;
            char h = input[i + 1], l = input[i + 2];
            if (h >= '0' && h <= '9') hi = h - '0';
            else if (h >= 'A' && h <= 'F') hi = h - 'A' + 10;
            else if (h >= 'a' && h <= 'f') hi = h - 'a' + 10;
            if (l >= '0' && l <= '9') lo = l - '0';
            else if (l >= 'A' && l <= 'F') lo = l - 'A' + 10;
            else if (l >= 'a' && l <= 'f') lo = l - 'a' + 10;
            if (hi >= 0 && lo >= 0) {
                output[out_pos++] = (char)((hi << 4) | lo);
                i += 3;
                continue;
            }
        }
        if (c == '+') {
            output[out_pos++] = ' ';
        } else {
            output[out_pos++] = c;
        }
        i++;
    }
    output[out_pos] = 0;
    *output_len = out_pos;
    return output;
}

// 按指定字符集进行 URL percent-encode
// 接收 UTF-8 input 和 charset 名称，输出百分号编码字符
// 支持 GBK/GB2312/GB18030（通过 gbk_table.h 映射表）和 UTF-8
// 调用方用 quickjs_bridge_free_string 释放
const char *quickjs_bridge_charset_url_encode(const char *input, size_t input_len,
                                               const char *charset, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len == 0 || !charset) {
        char *out = (char *)malloc(1);
        if (out) out[0] = '\0';
        return out;
    }

    // charset_url_encode 接收 null-terminated string
    char *encoded = charset_url_encode(input, charset, output_len);
    return (const char *)encoded;  // 由 charset_free_string 释放
}

// ---------- Batch 1: 纯 C 原生函数（不依赖 bridge 上下文）----------
// 替代 NativeChannel 中的加密/编码/HTML 方法，绕过 Kotlin MethodChannel
// 所有输出字符串用 quickjs_bridge_free_string 释放

// MD5 哈希：输入 UTF-8 字符串，输出 32 字符 hex 字符串
const char *quickjs_bridge_md5(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len > MAX_CRYPTO_SIZE) return NULL;
    if (input_len == 0) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }
    uint8_t digest[16];
    md5((const uint8_t *)input, input_len, digest);
    char *hex = (char *)malloc(33);
    if (!hex) return NULL;
    static const char h[] = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        hex[i*2] = h[digest[i] >> 4];
        hex[i*2+1] = h[digest[i] & 15];
    }
    hex[32] = '\0';
    *output_len = 32;
    return hex;
}

// SHA1 哈希：输入 UTF-8 字符串，输出 40 字符 hex 字符串
const char *quickjs_bridge_sha1(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len == 0) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }
    uint8_t digest[20];
    sha1((const uint8_t *)input, input_len, digest);
    char *hex = (char *)malloc(41);
    if (!hex) return NULL;
    static const char h[] = "0123456789abcdef";
    for (int i = 0; i < 20; i++) {
        hex[i*2] = h[digest[i] >> 4];
        hex[i*2+1] = h[digest[i] & 15];
    }
    hex[40] = '\0';
    *output_len = 40;
    return hex;
}

// SHA256 哈希：输入 UTF-8 字符串，输出 64 字符 hex 字符串
const char *quickjs_bridge_sha256(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len == 0) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }
    uint8_t digest[32];
    sha256((const uint8_t *)input, input_len, digest);
    char *hex = (char *)malloc(65);
    if (!hex) return NULL;
    static const char h[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        hex[i*2] = h[digest[i] >> 4];
        hex[i*2+1] = h[digest[i] & 15];
    }
    hex[64] = '\0';
    *output_len = 64;
    return hex;
}

// HMAC-SHA256：输入 (data, key)，输出 64 字符 hex 字符串
const char *quickjs_bridge_hmac_sha256(const char *data, size_t data_len,
                                        const char *key, size_t key_len,
                                        size_t *output_len) {
    if (!data || !key || !output_len) return NULL;
    *output_len = 0;
    char *empty = (char *)malloc(1); if (empty) empty[0] = '\0';
    if (data_len == 0 || key_len == 0) return empty;
    free(empty);

    uint8_t digest[32];
    hmac_sha256((const uint8_t *)key, key_len, (const uint8_t *)data, data_len, digest);
    char *hex = (char *)malloc(65);
    if (!hex) return NULL;
    static const char h[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        hex[i*2] = h[digest[i] >> 4];
        hex[i*2+1] = h[digest[i] & 15];
    }
    hex[64] = '\0';
    *output_len = 64;
    return hex;
}

// AES-CBC-PKCS7 解密：输入 (base64_密文, key_utf8, iv_utf8)，输出 UTF-8 明文
const char *quickjs_bridge_aes_decrypt(const char *cipher_b64, size_t b64_len,
                                        const char *key, size_t key_len,
                                        const char *iv, size_t iv_len,
                                        size_t *output_len) {
    if (!cipher_b64 || !key || !output_len) return NULL;
    if (b64_len > MAX_CRYPTO_SIZE) return NULL;
    *output_len = 0;
    char *empty = (char *)malloc(1); if (empty) empty[0] = '\0';
    if (b64_len == 0 || key_len == 0) return empty;
    free(empty);

    // Base64 解码
    size_t enc_len = 0;
    uint8_t *enc = (uint8_t *)b64_decode(cipher_b64, b64_len, &enc_len);
    if (!enc) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }

    // AES-CBC-PKCS7 解密（支持 AES-128/192/256）
    // 确定实际密钥长度：16/24/32 对应 AES-128/192/256
    size_t actual_key_len;
    if (key_len <= 16) actual_key_len = 16;
    else if (key_len <= 24) actual_key_len = 24;
    else actual_key_len = 32;

    uint8_t aes_key[32] = {0};
    memcpy(aes_key, key, key_len < actual_key_len ? key_len : actual_key_len);

    uint8_t aes_iv[16] = {0};
    if (iv && iv_len > 0) memcpy(aes_iv, iv, iv_len < 16 ? iv_len : 16);

    aes_ctx_t actx;
    if (aes_init(&actx, aes_key, actual_key_len) != 0) {
        free(enc);
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }

    // aes_cbc_decrypt 原地解密且自动去 PKCS7 padding，返回明文长度，失败返回 (size_t)-1
    uint8_t *plain = (uint8_t *)malloc(enc_len + 1);
    if (!plain) { free(enc); return NULL; }

    size_t plain_len = aes_cbc_decrypt(&actx, aes_iv, enc, enc_len, plain);
    free(enc);

    if (plain_len == (size_t)-1 || plain_len == 0) {
        free(plain);
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }

    *output_len = plain_len;
    plain[plain_len] = '\0';
    return (const char *)plain;  // 由 quickjs_bridge_free_string 释放（malloc）
}

// AES-CBC-PKCS7 加密：输入 (明文_utf8, key_utf8, iv_utf8)，输出 base64 密文
const char *quickjs_bridge_aes_encrypt(const char *plaintext, size_t pt_len,
                                        const char *key, size_t key_len,
                                        const char *iv, size_t iv_len,
                                        size_t *output_len) {
    if (!plaintext || !key || !output_len) return NULL;
    *output_len = 0;
    char *empty = (char *)malloc(1); if (empty) empty[0] = '\0';
    if (pt_len == 0 || key_len == 0) return empty;
    free(empty);

    // AES-CBC-PKCS7 加密（支持 AES-128/192/256）
    // 确定实际密钥长度：16/24/32 对应 AES-128/192/256
    size_t actual_key_len;
    if (key_len <= 16) actual_key_len = 16;
    else if (key_len <= 24) actual_key_len = 24;
    else actual_key_len = 32;

    uint8_t aes_key[32] = {0};
    memcpy(aes_key, key, key_len < actual_key_len ? key_len : actual_key_len);

    uint8_t aes_iv[16] = {0};
    if (iv && iv_len > 0) memcpy(aes_iv, iv, iv_len < 16 ? iv_len : 16);

    aes_ctx_t actx;
    if (aes_init(&actx, aes_key, actual_key_len) != 0) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }

    // aes_cbc_encrypt 内部完成 PKCS7 填充，返回密文长度，失败返回 (size_t)-1
    size_t cipher_cap = pt_len + 16;
    uint8_t *cipher = (uint8_t *)malloc(cipher_cap);
    if (!cipher) return NULL;

    size_t cipher_len = aes_cbc_encrypt(&actx, aes_iv, (const uint8_t *)plaintext, pt_len, cipher);

    if (cipher_len == (size_t)-1 || cipher_len == 0) {
        free(cipher);
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }

    // Base64 编码
    size_t b64_out_len = 0;
    char *b64 = b64_encode(cipher, cipher_len, &b64_out_len);
    free(cipher);

    if (!b64) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }

    *output_len = b64_out_len;
    return b64;  // 由 quickjs_bridge_free_string 释放（malloc）
}

// Base64 编码：输入 UTF-8 字符串，输出 Base64 字符串
const char *quickjs_bridge_base64_encode(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len > MAX_BASE64_SIZE) return NULL;
    if (input_len == 0) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }
    return b64_encode((const uint8_t *)input, input_len, output_len);
}

// Base64 解码：输入 Base64 字符串，输出 UTF-8 字符串
const char *quickjs_bridge_base64_decode(const char *input, size_t input_len, size_t *output_len) {
    if (!input || !output_len) return NULL;
    *output_len = 0;
    if (input_len == 0) {
        char *out = (char *)malloc(1); if (out) out[0] = '\0'; return out;
    }
    return (const char *)b64_decode(input, input_len, output_len);
}

// ---------- C 原生 HTML 解析 + CSS 选择器引擎 ----------
// 解析加速：替代 Dart html 包的 querySelectorAll，消除多层 fallback 开销
// 原子调用：HTML 解析 + CSS 查询 + 属性提取 一次完成，避免多次 FFI 往返

// JSON 字符串转义（追加到 buffer）
static void _json_escape_append(char **buf, size_t *len, size_t *cap, const char *str) {
    if (!str) return;
    for (const char *p = str; *p; p++) {
        char c = *p;
        if (c == '"' || c == '\\') {
            if (*len + 2 >= *cap) { *cap = (*cap == 0 ? 256 : *cap * 2) + 2; *buf = (char *)realloc(*buf, *cap); }
            (*buf)[(*len)++] = '\\';
            (*buf)[(*len)++] = c;
        } else if (c == '\n') {
            if (*len + 2 >= *cap) { *cap = (*cap == 0 ? 256 : *cap * 2) + 2; *buf = (char *)realloc(*buf, *cap); }
            (*buf)[(*len)++] = '\\'; (*buf)[(*len)++] = 'n';
        } else if (c == '\r') {
            if (*len + 2 >= *cap) { *cap = (*cap == 0 ? 256 : *cap * 2) + 2; *buf = (char *)realloc(*buf, *cap); }
            (*buf)[(*len)++] = '\\'; (*buf)[(*len)++] = 'r';
        } else if (c == '\t') {
            if (*len + 2 >= *cap) { *cap = (*cap == 0 ? 256 : *cap * 2) + 2; *buf = (char *)realloc(*buf, *cap); }
            (*buf)[(*len)++] = '\\'; (*buf)[(*len)++] = 't';
        } else if ((unsigned char)c < 0x20) {
            if (*len + 6 >= *cap) { *cap = (*cap == 0 ? 256 : *cap * 2) + 6; *buf = (char *)realloc(*buf, *cap); }
            *len += sprintf(*buf + *len, "\\u%04x", (unsigned char)c);
        } else {
            if (*len + 1 >= *cap) { *cap = (*cap == 0 ? 256 : *cap * 2) + 1; *buf = (char *)realloc(*buf, *cap); }
            (*buf)[(*len)++] = c;
        }
    }
}

// 原子调用：HTML 解析 + CSS 查询 + 属性提取
// html/html_len: HTML 字符串
// selector: CSS 选择器（支持 tag .class #id [attr] descendant child :nth-child :eq）
// attr: 提取的属性名，特殊值: "@text"=文本, "@html"=内部HTML, "@outerHtml"=外部HTML, "@tag"=标签名
// list_mode: 1=返回所有匹配的 JSON 数组, 0=只返回第一个匹配的字符串（非 JSON）
// 返回: malloc 分配的字符串，调用方用 quickjs_bridge_free_string 释放
const char *quickjs_bridge_html_query_extract(
    const char *html, size_t html_len,
    const char *selector,
    const char *attr,
    int list_mode,
    int *is_error) {
    if (is_error) *is_error = 0;
    if (!html || !selector || !attr) {
        if (is_error) *is_error = 1;
        return _str_dup(list_mode ? "[]" : "", 0);
    }

    // P4: 超大 HTML 防护
    if (html_len > MAX_HTML_SIZE) {
        if (is_error) *is_error = 1;
        return _str_dup(list_mode ? "[]" : "", 0);
    }

    // 解析 HTML
    html_node_t *root = html_parse(html, html_len);
    if (!root) {
        if (is_error) *is_error = 1;
        return _str_dup(list_mode ? "[]" : "", 0);
    }

    // CSS 查询
    int match_count = 0;
    html_node_t **matches = html_query_all(root, selector, &match_count);

    // 确定提取函数
    enum { EXTRACT_TEXT, EXTRACT_INNER_HTML, EXTRACT_OUTER_HTML, EXTRACT_TAG, EXTRACT_ATTR } extract_type = EXTRACT_ATTR;
    if (attr[0] == '@') {
        if (strcmp(attr, "@text") == 0 || strcmp(attr, "@text()") == 0) extract_type = EXTRACT_TEXT;
        else if (strcmp(attr, "@html") == 0 || strcmp(attr, "@innerHtml") == 0 || strcmp(attr, "@innerHTML") == 0) extract_type = EXTRACT_INNER_HTML;
        else if (strcmp(attr, "@outerHtml") == 0) extract_type = EXTRACT_OUTER_HTML;
        else if (strcmp(attr, "@tag") == 0 || strcmp(attr, "@tagName") == 0) extract_type = EXTRACT_TAG;
    }

    // 构建结果
    char *result_buf = NULL;
    size_t result_len = 0;
    size_t result_cap = 0;

    if (list_mode) {
        // JSON 数组模式: ["val1", "val2", ...]
        result_buf = (char *)malloc(2);
        result_buf[result_len++] = '[';
    }

    for (int i = 0; i < match_count; i++) {
        html_node_t *elem = matches[i];
        char *value = NULL;
        size_t value_len = 0;

        switch (extract_type) {
            case EXTRACT_TEXT:
                value = html_get_text(elem, &value_len);
                break;
            case EXTRACT_INNER_HTML:
                value = html_get_inner_html(elem, &value_len);
                break;
            case EXTRACT_OUTER_HTML:
                value = html_get_outer_html(elem, &value_len);
                break;
            case EXTRACT_TAG: {
                const char *tag = html_get_tag_name(elem);
                if (tag) value = _str_dup(tag, strlen(tag));
                break;
            }
            case EXTRACT_ATTR:
                value = html_get_attr(elem, attr);
                break;
        }

        if (list_mode) {
            // JSON 数组：添加逗号分隔
            if (i > 0) {
                if (result_len + 1 >= result_cap) { result_cap = (result_cap == 0 ? 256 : result_cap * 2); result_buf = (char *)realloc(result_buf, result_cap); }
                result_buf[result_len++] = ',';
            }
            if (result_len + 1 >= result_cap) { result_cap = (result_cap == 0 ? 256 : result_cap * 2); result_buf = (char *)realloc(result_buf, result_cap); }
            result_buf[result_len++] = '"';
            _json_escape_append(&result_buf, &result_len, &result_cap, value);
            if (result_len + 1 >= result_cap) { result_cap = (result_cap == 0 ? 256 : result_cap * 2); result_buf = (char *)realloc(result_buf, result_cap); }
            result_buf[result_len++] = '"';
            // list_mode：value 已被拷贝到 JSON 字符串中，释放原内存
            free(value);
        } else {
            // 单值模式：直接返回第一个匹配的值
            if (value) {
                free(result_buf);
                result_buf = value;
                result_len = strlen(value);
                // value 所有权移交给 result_buf，无需 free，直接跳出循环
                break; // 只取第一个
            }
            // value 为 NULL 时无需处理，继续下一轮
        }
    }

    if (list_mode) {
        if (result_len + 1 >= result_cap) { result_cap = (result_cap == 0 ? 256 : result_cap * 2); result_buf = (char *)realloc(result_buf, result_cap); }
        result_buf[result_len++] = ']';
    }

    if (!result_buf) {
        result_buf = (char *)malloc(1);
        result_buf[0] = 0;
    } else {
        if (result_len + 1 >= result_cap) { result_buf = (char *)realloc(result_buf, result_len + 1); }
        result_buf[result_len] = 0;
    }

    // 清理
    free(matches);
    html_node_free(root);

    return result_buf;
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

// AES-ECB-PKCS7 解密：输入 (ciphertext, key) ArrayBuffer，输出 plaintext ArrayBuffer
static JSValue js_native_aes_decrypt_ecb(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "aesDecryptNativeECB requires 2 arguments, got %d", argc);
    size_t ct_len, key_len;
    const uint8_t *ct = get_ab(ctx, argv[0], &ct_len, "aesDecryptNativeECB", 1);
    if (!ct) return JS_EXCEPTION;
    const uint8_t *key = get_ab(ctx, argv[1], &key_len, "aesDecryptNativeECB", 2);
    if (!key) return JS_EXCEPTION;

    if (key_len != 16 && key_len != 24 && key_len != 32) {
        return JS_ThrowTypeError(ctx, "aesDecryptNativeECB: key length must be 16/24/32, got %d", (int)key_len);
    }
    if (ct_len == 0 || ct_len % 16 != 0) {
        return JS_ThrowTypeError(ctx, "aesDecryptNativeECB: ciphertext length must be multiple of 16, got %d", (int)ct_len);
    }

    aes_ctx_t actx;
    if (aes_init(&actx, key, key_len) != 0) {
        return JS_ThrowTypeError(ctx, "aesDecryptNativeECB: key expansion failed");
    }

    uint8_t *out = (uint8_t *)malloc(ct_len);
    if (!out) return JS_ThrowTypeError(ctx, "aesDecryptNativeECB: out of memory");

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    size_t out_len = aes_ecb_decrypt(&actx, ct, ct_len, out);

    if (bridge) _stats_update(&bridge->stats, ct_len, out_len == (size_t)-1 ? 0 : out_len, _now_us() - t0);

    if (out_len == (size_t)-1) {
        free(out);
        return JS_ThrowTypeError(ctx, "aesDecryptNativeECB: decryption failed (bad padding or key)");
    }

    JSValue ret = JS_NewArrayBufferCopy(ctx, out, out_len);
    free(out);
    return ret;
}

// AES-ECB-PKCS7 加密：输入 (plaintext, key) ArrayBuffer，输出 ciphertext ArrayBuffer
static JSValue js_native_aes_encrypt_ecb(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "aesEncryptNativeECB requires 2 arguments, got %d", argc);
    size_t pt_len, key_len;
    const uint8_t *pt = get_ab(ctx, argv[0], &pt_len, "aesEncryptNativeECB", 1);
    if (!pt) return JS_EXCEPTION;
    const uint8_t *key = get_ab(ctx, argv[1], &key_len, "aesEncryptNativeECB", 2);
    if (!key) return JS_EXCEPTION;

    if (key_len != 16 && key_len != 24 && key_len != 32) {
        return JS_ThrowTypeError(ctx, "aesEncryptNativeECB: key length must be 16/24/32, got %d", (int)key_len);
    }

    aes_ctx_t actx;
    if (aes_init(&actx, key, key_len) != 0) {
        return JS_ThrowTypeError(ctx, "aesEncryptNativeECB: key expansion failed");
    }

    size_t max_out = pt_len + 16;
    uint8_t *out = (uint8_t *)malloc(max_out);
    if (!out) return JS_ThrowTypeError(ctx, "aesEncryptNativeECB: out of memory");

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    size_t out_len = aes_ecb_encrypt(&actx, pt, pt_len, out);

    if (bridge) _stats_update(&bridge->stats, pt_len, out_len == (size_t)-1 ? 0 : out_len, _now_us() - t0);

    if (out_len == (size_t)-1) {
        free(out);
        return JS_ThrowTypeError(ctx, "aesEncryptNativeECB: encryption failed");
    }

    JSValue ret = JS_NewArrayBufferCopy(ctx, out, out_len);
    free(out);
    return ret;
}

// ---------- Base64 解码助手（供 AES+LZ 原子组合使用）----------
// 标准 base64 字母表解码，跳过非字母表字符（空白、换行等），遇 '=' 停止
// 返回 malloc 分配的字节缓冲区，调用者负责 free
static uint8_t *b64_decode(const char *src, size_t src_len, size_t *out_len) {
    static int8_t rev_table[256];
    static int inited = 0;
    if (!inited) {
        int i;
        memset(rev_table, -1, sizeof(rev_table));
        const char *alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (i = 0; i < 64; i++) rev_table[(unsigned char)alpha[i]] = (int8_t)i;
        inited = 1;
    }

    size_t max_out = (src_len / 4) * 3 + 3;
    uint8_t *out = (uint8_t *)malloc(max_out);
    if (!out) return NULL;

    size_t o = 0;
    uint32_t buf = 0;
    int bits = 0;
    size_t i;
    for (i = 0; i < src_len; i++) {
        unsigned char ch = (unsigned char)src[i];
        if (ch == '=') break;
        int8_t v = rev_table[ch];
        if (v < 0) continue;
        buf = (buf << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = (uint8_t)((buf >> bits) & 0xFF);
        }
    }

    *out_len = o;
    return out;
}

// Phase 4: Base64 编码（标准字母表，带 = 填充）
static char *b64_encode(const uint8_t *src, size_t src_len, size_t *out_len) {
    static const char alpha[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t out_size = ((src_len + 2) / 3) * 4 + 1;
    char *out = (char *)malloc(out_size);
    if (!out) return NULL;

    size_t o = 0;
    size_t i;
    for (i = 0; i + 2 < src_len; i += 3) {
        uint32_t b = ((uint32_t)src[i] << 16) | ((uint32_t)src[i + 1] << 8) | src[i + 2];
        out[o++] = alpha[(b >> 18) & 0x3F];
        out[o++] = alpha[(b >> 12) & 0x3F];
        out[o++] = alpha[(b >> 6) & 0x3F];
        out[o++] = alpha[b & 0x3F];
    }
    if (i < src_len) {
        uint32_t b = (uint32_t)src[i] << 16;
        if (i + 1 < src_len) b |= (uint32_t)src[i + 1] << 8;
        out[o++] = alpha[(b >> 18) & 0x3F];
        out[o++] = alpha[(b >> 12) & 0x3F];
        out[o++] = (i + 1 < src_len) ? alpha[(b >> 6) & 0x3F] : '=';
        out[o++] = '=';
    }
    out[o] = 0;
    *out_len = o;
    return out;
}

// ---------- Phase 4: C 原生 atob/btoa ----------
// 替代 JsEngine 注入的纯 JS 实现，消除解释执行开销
// 语义与浏览器一致：atob 返回「二进制字符串」（每个 char code 0-255）

static JSValue js_native_atob(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || JS_IsNull(argv[0]) || JS_IsUndefined(argv[0])) {
        return JS_NewString(ctx, "");
    }
    const char *input = JS_ToCString(ctx, argv[0]);
    if (!input) return JS_ThrowTypeError(ctx, "atob: argument must be a string");

    size_t input_len = strlen(input);
    size_t raw_len = 0;
    uint8_t *raw = b64_decode(input, input_len, &raw_len);
    JS_FreeCString(ctx, input);

    if (!raw) return JS_ThrowTypeError(ctx, "atob: invalid base64 input");

    // 原始字节 → Latin-1 字符串（UTF-8 编码 code points 0-255）
    // 字节 0-127 → 1 UTF-8 字节；字节 128-255 → 2 UTF-8 字节
    size_t utf8_max = raw_len * 2;
    char *utf8_buf = (char *)malloc(utf8_max + 1);
    if (!utf8_buf) { free(raw); return JS_ThrowTypeError(ctx, "atob: out of memory"); }

    size_t pos = 0;
    for (size_t i = 0; i < raw_len; i++) {
        uint8_t b = raw[i];
        if (b < 0x80) {
            utf8_buf[pos++] = (char)b;
        } else {
            utf8_buf[pos++] = (char)(0xC2 | (b >> 6));
            utf8_buf[pos++] = (char)(0x80 | (b & 0x3F));
        }
    }
    free(raw);

    JSValue ret = JS_NewStringLen(ctx, utf8_buf, pos);
    free(utf8_buf);
    return ret;
}

static JSValue js_native_btoa(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || JS_IsNull(argv[0]) || JS_IsUndefined(argv[0])) {
        return JS_NewString(ctx, "");
    }
    const char *input = JS_ToCString(ctx, argv[0]);
    if (!input) return JS_ThrowTypeError(ctx, "btoa: argument must be a string");

    // 解析 UTF-8 提取 code points（二进制字符串每个字符应为 0-255）
    size_t input_len = strlen(input);
    uint8_t *bytes = (uint8_t *)malloc(input_len + 1);
    if (!bytes) {
        JS_FreeCString(ctx, input);
        return JS_ThrowTypeError(ctx, "btoa: out of memory");
    }

    size_t byte_count = 0;
    size_t i;
    for (i = 0; i < input_len; ) {
        unsigned char c = (unsigned char)input[i];
        int code;
        if (c < 0x80) {
            code = c;
            i += 1;
        } else if ((c & 0xE0) == 0xC0 && i + 1 < input_len) {
            code = ((c & 0x1F) << 6) | ((unsigned char)input[i + 1] & 0x3F);
            i += 2;
        } else if ((c & 0xF0) == 0xE0 && i + 2 < input_len) {
            code = ((c & 0x0F) << 12) | (((unsigned char)input[i + 1] & 0x3F) << 6) |
                   ((unsigned char)input[i + 2] & 0x3F);
            i += 3;
        } else {
            i += 1;
            continue;
        }
        if (code > 255) {
            free(bytes);
            JS_FreeCString(ctx, input);
            return JS_ThrowTypeError(ctx, "btoa: string contains characters outside Latin-1 range");
        }
        bytes[byte_count++] = (uint8_t)code;
    }
    JS_FreeCString(ctx, input);

    size_t b64_len = 0;
    char *b64 = b64_encode(bytes, byte_count, &b64_len);
    free(bytes);

    if (!b64) return JS_ThrowTypeError(ctx, "btoa: encoding failed");

    JSValue ret = JS_NewStringLen(ctx, b64, b64_len);
    free(b64);
    return ret;
}

// ---------- LZString 原生 C 实现 ----------
// 对应 JS: LZString.decompressFromBase64(input)
// 接受 JS 字符串，返回 JS 字符串
// JS 语义：null/undefined → ""，空串 → null，解压失败 → null
static JSValue js_native_lz_decompress(JSContext *ctx, JSValueConst this_val,
                                       int argc, JSValueConst *argv) {
    // null/undefined/缺失 → ""（JS: if (input == null) return "";）
    if (argc < 1 || JS_IsNull(argv[0]) || JS_IsUndefined(argv[0])) {
        return JS_NewString(ctx, "");
    }

    const char *input = JS_ToCString(ctx, argv[0]);
    if (!input) {
        return JS_ThrowTypeError(ctx, "decompressFromBase64: argument must be a string");
    }

    size_t input_len = strlen(input);

    // 空串 → null（JS: if (input == "") return null;）
    if (input_len == 0) {
        JS_FreeCString(ctx, input);
        return JS_NULL;
    }

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    size_t out_len = 0;
    char *out = lz_decompress_from_base64(input, input_len, &out_len);

    if (bridge) _stats_update(&bridge->stats, input_len, out_len, _now_us() - t0);

    JS_FreeCString(ctx, input);

    if (!out) {
        // 解压失败 → null
        return JS_NULL;
    }

    JSValue ret = JS_NewStringLen(ctx, out, out_len);
    free(out);
    return ret;
}

// ---------- AES-CBC-PKCS7 解密 + LZString 解压（原子组合）----------
// 对应 3A 书源 content() 的解密链路：
//   atob(result) → IV(前16) | cipher → AES-CBC decrypt → UTF-8 → LZString decompress
// 直接在 C 层完成全链路，消除 JS 侧字符串膨胀与多次往返
// 输入：(base64Input, keyUtf8) 字符串
// 输出：解压后的 JS 字符串
static JSValue js_native_aes_decrypt_then_lz(JSContext *ctx, JSValueConst this_val,
                                             int argc, JSValueConst *argv) {
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress requires 2 arguments, got %d", argc);
    }

    const char *b64 = JS_ToCString(ctx, argv[0]);
    if (!b64) return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress: argument 1 must be a string");

    const char *key_utf8 = JS_ToCString(ctx, argv[1]);
    if (!key_utf8) {
        JS_FreeCString(ctx, b64);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress: argument 2 must be a string");
    }

    size_t b64_len = strlen(b64);
    size_t key_len = strlen(key_utf8);

    if (key_len != 16 && key_len != 24 && key_len != 32) {
        JS_FreeCString(ctx, b64);
        JS_FreeCString(ctx, key_utf8);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress: key length must be 16/24/32, got %d", (int)key_len);
    }

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    // 1. base64 解码
    size_t raw_len = 0;
    uint8_t *raw = b64_decode(b64, b64_len, &raw_len);
    JS_FreeCString(ctx, b64);

    if (!raw || raw_len < 16 || (raw_len - 16) == 0 || (raw_len - 16) % 16 != 0) {
        if (raw) free(raw);
        JS_FreeCString(ctx, key_utf8);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress: invalid ciphertext (len=%d)", (int)raw_len);
    }

    // 2. 拆分 IV（前 16 字节）+ 密文
    const uint8_t *iv = raw;
    const uint8_t *cipher = raw + 16;
    size_t cipher_len = raw_len - 16;

    // 3. AES-CBC-PKCS7 解密
    aes_ctx_t actx;
    if (aes_init(&actx, (const uint8_t *)key_utf8, key_len) != 0) {
        free(raw);
        JS_FreeCString(ctx, key_utf8);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress: key expansion failed");
    }
    JS_FreeCString(ctx, key_utf8);

    uint8_t *plain = (uint8_t *)malloc(cipher_len);
    if (!plain) {
        free(raw);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress: out of memory");
    }

    size_t plain_len = aes_cbc_decrypt(&actx, iv, cipher, cipher_len, plain);
    free(raw);  // IV 与 cipher 同在 raw 中，AES 已用完

    if (plain_len == (size_t)-1) {
        free(plain);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompress: AES decryption failed (bad padding or key)");
    }

    // 4. LZString 解压（plain 视为 UTF-8 字符串）
    size_t lz_out_len = 0;
    char *lz_out = lz_decompress_from_base64((const char *)plain, plain_len, &lz_out_len);
    free(plain);

    if (bridge) _stats_update(&bridge->stats, b64_len, lz_out_len, _now_us() - t0);

    if (!lz_out) {
        return JS_NULL;
    }

    JSValue ret = JS_NewStringLen(ctx, lz_out, lz_out_len);
    free(lz_out);
    return ret;
}

// ---------- 零拷贝 ArrayBuffer 路径（Phase 4）----------
// JS_NewArrayBuffer 接管 malloc'd buffer 的所有权：当 ArrayBuffer 被 GC 时
// 通过 free_func 回调自动 free(ptr)，无需 JS 侧手动释放，亦无需 JS_NewStringLen 复制
// 适用于大块数据（如整章正文）从 C 层回传 JS 的场景，避免一次额外的内存拷贝
static void js_free_buffer(JSRuntime *rt, void *opaque, void *ptr) {
    (void)rt;
    (void)opaque;
    free(ptr);
}

// LZString 解压（零拷贝版）
// 输入：ArrayBuffer（base64 编码字节流，可由 XHR responseType='arraybuffer' 直接获得）
// 输出：ArrayBuffer（解压后的 UTF-8 字节流，由 JS_GC 自动回收底层 C 内存）
// 语义：null/undefined → null，空 buffer → null，解压失败 → null
// 对比字符串版：消除 base64→UTF-8→JS_NewStringLen 的两次复制
static JSValue js_native_lz_decompress_bin(JSContext *ctx, JSValueConst this_val,
                                            int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || JS_IsNull(argv[0]) || JS_IsUndefined(argv[0])) {
        return JS_NULL;
    }

    size_t input_len = 0;
    uint8_t *input = JS_GetArrayBuffer(ctx, &input_len, argv[0]);
    if (!input) {
        return JS_ThrowTypeError(ctx, "decompressFromBase64Bin: argument must be an ArrayBuffer");
    }

    if (input_len == 0) {
        return JS_NULL;
    }

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    // JS_GetArrayBuffer 返回 ArrayBuffer 内部 buffer 的直接指针，零拷贝读取
    size_t out_len = 0;
    char *out = lz_decompress_from_base64((const char *)input, input_len, &out_len);

    if (bridge) _stats_update(&bridge->stats, input_len, out_len, _now_us() - t0);

    if (!out) {
        return JS_NULL;
    }

    // 零拷贝回传：out 由 js_free_buffer 在 GC 时释放
    return JS_NewArrayBuffer(ctx, (uint8_t *)out, out_len, js_free_buffer, NULL, 0);
}

// AES-CBC 解密 + LZString 解压（零拷贝原子组合）
// 输入：(ArrayBuffer base64Cipher, ArrayBuffer keyBytes)
//       keyBytes 为原始 AES 密钥字节（16/24/32），无需经过 UTF-8 编码
// 输出：ArrayBuffer（解压后的 UTF-8 字节流）
// 适用于：网络层直接返回 ArrayBuffer 的场景，避免 base64 字符串在 JS 侧的临时分配
static JSValue js_native_aes_decrypt_then_lz_bin(JSContext *ctx, JSValueConst this_val,
                                                  int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2 || JS_IsNull(argv[0]) || JS_IsUndefined(argv[0]) ||
        JS_IsNull(argv[1]) || JS_IsUndefined(argv[1])) {
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin requires 2 ArrayBuffers");
    }

    // base64 密文（零拷贝读取 ArrayBuffer 内部 buffer）
    size_t b64_len = 0;
    uint8_t *b64 = JS_GetArrayBuffer(ctx, &b64_len, argv[0]);
    if (!b64) {
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin: arg 1 must be ArrayBuffer");
    }

    // 密钥原始字节（避免 UTF-8 编码往返，AES 密钥本就是字节而非文本）
    size_t key_len = 0;
    uint8_t *key_bytes = JS_GetArrayBuffer(ctx, &key_len, argv[1]);
    if (!key_bytes) {
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin: arg 2 must be ArrayBuffer");
    }

    if (key_len != 16 && key_len != 24 && key_len != 32) {
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin: key length must be 16/24/32, got %d", (int)key_len);
    }

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    // 1. base64 解码
    size_t raw_len = 0;
    uint8_t *raw = b64_decode((const char *)b64, b64_len, &raw_len);
    if (!raw || raw_len < 16 || (raw_len - 16) == 0 || (raw_len - 16) % 16 != 0) {
        if (raw) free(raw);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin: invalid ciphertext (len=%d)", (int)raw_len);
    }

    // 2. 拆分 IV(前 16) + 密文
    const uint8_t *iv = raw;
    const uint8_t *cipher = raw + 16;
    size_t cipher_len = raw_len - 16;

    // 3. AES-CBC-PKCS7 解密
    aes_ctx_t actx;
    if (aes_init(&actx, key_bytes, key_len) != 0) {
        free(raw);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin: key expansion failed");
    }

    uint8_t *plain = (uint8_t *)malloc(cipher_len);
    if (!plain) {
        free(raw);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin: out of memory");
    }

    size_t plain_len = aes_cbc_decrypt(&actx, iv, cipher, cipher_len, plain);
    free(raw);  // IV 与 cipher 同在 raw 中，AES 已用完

    if (plain_len == (size_t)-1) {
        free(plain);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBin: AES decryption failed (bad padding or key)");
    }

    // 4. LZString 解压（plain 视为 base64 字符串字节流）
    size_t lz_out_len = 0;
    char *lz_out = lz_decompress_from_base64((const char *)plain, plain_len, &lz_out_len);
    free(plain);

    if (bridge) _stats_update(&bridge->stats, b64_len, lz_out_len, _now_us() - t0);

    if (!lz_out) {
        return JS_NULL;
    }

    // 零拷贝回传
    return JS_NewArrayBuffer(ctx, (uint8_t *)lz_out, lz_out_len, js_free_buffer, NULL, 0);
}

// ---------- 批量 LZString 解压（多线程分片）----------
// 输入 JS 数组 [str1, str2, ...]，返回 JS 数组 [result1, result2, ...]
// 内部按 CPU 核心数切分并发，消除逐条 JS↔C 往返开销
static JSValue js_native_lz_decompress_batch(JSContext *ctx, JSValueConst this_val,
                                             int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsArray(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "decompressFromBase64Batch requires 1 array argument");
    }

    JSValueConst arr = argv[0];
    uint32_t count = 0;
    JSValue len_val = JS_GetPropertyStr(ctx, arr, "length");
    if (JS_ToUint32(ctx, &count, len_val) != 0) {
        JS_FreeValue(ctx, len_val);
        return JS_ThrowTypeError(ctx, "decompressFromBase64Batch: invalid array length");
    }
    JS_FreeValue(ctx, len_val);

    if (count == 0) {
        return JS_NewArray(ctx);
    }

    // 收集输入字符串（JS_ToCString 返回的指针在 JS_FreeCString 前一直有效，多线程只读安全）
    const char **inputs = (const char **)malloc(count * sizeof(char *));
    size_t *input_lens = (size_t *)malloc(count * sizeof(size_t));
    JSValue *js_items = (JSValue *)malloc(count * sizeof(JSValue));
    if (!inputs || !input_lens || !js_items) {
        free(inputs); free(input_lens); free(js_items);
        return JS_ThrowTypeError(ctx, "decompressFromBase64Batch: out of memory");
    }

    uint32_t i;
    for (i = 0; i < count; i++) {
        js_items[i] = JS_GetPropertyUint32(ctx, arr, i);
        if (JS_IsNull(js_items[i]) || JS_IsUndefined(js_items[i])) {
            inputs[i] = NULL;
            input_lens[i] = 0;
        } else {
            const char *s = JS_ToCString(ctx, js_items[i]);
            inputs[i] = s;
            input_lens[i] = s ? strlen(s) : 0;
        }
    }

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    char **results = NULL;
    size_t *out_lens = NULL;
    int rc = lz_decompress_batch(inputs, input_lens, count, &results, &out_lens);

    if (bridge) {
        uint64_t total_in = 0, total_out = 0;
        uint32_t j;
        for (j = 0; j < count; j++) {
            total_in += input_lens[j];
            total_out += out_lens ? out_lens[j] : 0;
        }
        _stats_update(&bridge->stats, total_in, total_out, _now_us() - t0);
    }

    // 释放 JS 字符串
    for (i = 0; i < count; i++) {
        if (inputs[i]) JS_FreeCString(ctx, inputs[i]);
        JS_FreeValue(ctx, js_items[i]);
    }
    free(inputs);
    free(input_lens);
    free(js_items);

    if (rc != 0) {
        if (results) { for (i = 0; i < count; i++) free(results[i]); free(results); }
        free(out_lens);
        return JS_ThrowTypeError(ctx, "decompressFromBase64Batch: batch failed");
    }

    // 构建结果数组
    JSValue ret_arr = JS_NewArray(ctx);
    for (i = 0; i < count; i++) {
        JSValue item;
        if (results[i] == NULL) {
            item = JS_NULL;  // 解压失败 → null
        } else {
            item = JS_NewStringLen(ctx, results[i], out_lens[i]);
            free(results[i]);
        }
        JS_SetPropertyUint32(ctx, ret_arr, i, item);
    }

    free(results);
    free(out_lens);
    return ret_arr;
}

// ---------- 批量 AES+LZ 解密解压（多线程分片，原子组合）----------
// 输入 (base64Array, keyUtf8)，返回 JS 数组
static JSValue js_native_aes_decrypt_then_lz_batch(JSContext *ctx, JSValueConst this_val,
                                                    int argc, JSValueConst *argv) {
    if (argc < 2 || !JS_IsArray(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBatch requires (array, key)");
    }

    JSValueConst arr = argv[0];
    uint32_t count = 0;
    JSValue len_val = JS_GetPropertyStr(ctx, arr, "length");
    if (JS_ToUint32(ctx, &count, len_val) != 0) {
        JS_FreeValue(ctx, len_val);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBatch: invalid array length");
    }
    JS_FreeValue(ctx, len_val);

    const char *key_utf8 = JS_ToCString(ctx, argv[1]);
    if (!key_utf8) {
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBatch: key must be a string");
    }
    size_t key_len = strlen(key_utf8);
    if (key_len != 16 && key_len != 24 && key_len != 32) {
        JS_FreeCString(ctx, key_utf8);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBatch: key length must be 16/24/32, got %d", (int)key_len);
    }

    if (count == 0) {
        JS_FreeCString(ctx, key_utf8);
        return JS_NewArray(ctx);
    }

    const char **b64_inputs = (const char **)malloc(count * sizeof(char *));
    size_t *b64_lens = (size_t *)malloc(count * sizeof(size_t));
    JSValue *js_items = (JSValue *)malloc(count * sizeof(JSValue));
    if (!b64_inputs || !b64_lens || !js_items) {
        free(b64_inputs); free(b64_lens); free(js_items);
        JS_FreeCString(ctx, key_utf8);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBatch: out of memory");
    }

    uint32_t i;
    for (i = 0; i < count; i++) {
        js_items[i] = JS_GetPropertyUint32(ctx, arr, i);
        const char *s = JS_ToCString(ctx, js_items[i]);
        b64_inputs[i] = s;
        b64_lens[i] = s ? strlen(s) : 0;
    }

    QuickJSBridge *bridge = (QuickJSBridge *)JS_GetContextOpaque(ctx);
    uint64_t t0 = bridge ? _now_us() : 0;

    char **results = NULL;
    size_t *out_lens = NULL;
    int rc = aes_decrypt_lz_batch(b64_inputs, b64_lens, count, key_utf8, key_len, &results, &out_lens);

    if (bridge) {
        uint64_t total_in = 0, total_out = 0;
        uint32_t j;
        for (j = 0; j < count; j++) {
            total_in += b64_lens[j];
            total_out += out_lens ? out_lens[j] : 0;
        }
        _stats_update(&bridge->stats, total_in, total_out, _now_us() - t0);
    }

    // 释放 JS 字符串
    for (i = 0; i < count; i++) {
        if (b64_inputs[i]) JS_FreeCString(ctx, b64_inputs[i]);
        JS_FreeValue(ctx, js_items[i]);
    }
    free(b64_inputs);
    free(b64_lens);
    free(js_items);
    JS_FreeCString(ctx, key_utf8);

    if (rc != 0) {
        if (results) { for (i = 0; i < count; i++) free(results[i]); free(results); }
        free(out_lens);
        return JS_ThrowTypeError(ctx, "aesDecryptThenLzDecompressBatch: batch failed");
    }

    JSValue ret_arr = JS_NewArray(ctx);
    for (i = 0; i < count; i++) {
        JSValue item;
        if (results[i] == NULL) {
            item = JS_NULL;
        } else {
            item = JS_NewStringLen(ctx, results[i], out_lens[i]);
            free(results[i]);
        }
        JS_SetPropertyUint32(ctx, ret_arr, i, item);
    }

    free(results);
    free(out_lens);
    return ret_arr;
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

// ---------- 编码转换：charset_url_encode / charset_detect ----------
// 纯 C 实现（based on charset_conv.c + gbk_table.h），零外部依赖
// 支持 GBK/GB2312/GB18030/UTF-8 编码

// charsetUrlEncode(str, charset) → percent-encoded string
static JSValue js_conv_charset_url_encode(JSContext *ctx, JSValueConst this_val,
                                          int argc, JSValueConst *argv) {
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "charsetUrlEncode requires 2 arguments, got %d", argc);
    }
    const char *str = JS_ToCString(ctx, argv[0]);
    const char *charset = JS_ToCString(ctx, argv[1]);
    if (!str || !charset) {
        if (str) JS_FreeCString(ctx, str);
        if (charset) JS_FreeCString(ctx, charset);
        return JS_ThrowTypeError(ctx, "charsetUrlEncode: arguments must be strings");
    }

    size_t out_len = 0;
    char *encoded = charset_url_encode(str, charset, &out_len);
    JS_FreeCString(ctx, str);
    JS_FreeCString(ctx, charset);

    if (!encoded) {
        return JS_NewString(ctx, "");
    }

    JSValue ret = JS_NewStringLen(ctx, encoded, out_len);
    charset_free_string(encoded);
    return ret;
}

// charsetDetect(html) → charset string or null
static JSValue js_conv_charset_detect(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv) {
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "charsetDetect requires 1 argument, got %d", argc);
    }
    const char *html = JS_ToCString(ctx, argv[0]);
    if (!html) {
        return JS_ThrowTypeError(ctx, "charsetDetect: argument must be a string");
    }

    size_t out_len = 0;
    char *charset = charset_detect_from_html(html, &out_len);
    JS_FreeCString(ctx, html);

    if (!charset) {
        return JS_NULL;
    }

    JSValue ret = JS_NewStringLen(ctx, charset, out_len);
    charset_free_string(charset);
    return ret;
}

// charsetDecode(data, charset [, assumeLatin1]) → UTF-8 string
// data: Uint8Array/ArrayBuffer of raw bytes
// charset: "GBK"/"UTF-8" etc.
// 返回 UTF-8 解码后的字符串
static JSValue js_conv_charset_decode(JSContext *ctx, JSValueConst this_val,
                                      int argc, JSValueConst *argv) {
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "charsetDecode requires 2 arguments, got %d", argc);
    }

    size_t data_len = 0;
    const uint8_t *data = JS_GetArrayBuffer(ctx, &data_len, argv[0]);
    if (!data) {
        return JS_ThrowTypeError(ctx, "charsetDecode: argument 1 must be an ArrayBuffer/Uint8Array");
    }

    const char *charset = JS_ToCString(ctx, argv[1]);
    if (!charset) {
        return JS_ThrowTypeError(ctx, "charsetDecode: argument 2 must be a string");
    }

    size_t out_len = 0;
    char *decoded = charset_decode_to_utf8(data, data_len, charset, &out_len);
    JS_FreeCString(ctx, charset);

    if (!decoded) {
        return JS_ThrowTypeError(ctx, "charsetDecode: decoding failed");
    }

    JSValue ret = JS_NewStringLen(ctx, decoded, out_len);
    charset_free_string(decoded);
    return ret;
}

QuickJSBridge *quickjs_bridge_create(void) {
    return quickjs_bridge_create_with_config(0, 0);
}

QuickJSBridge *quickjs_bridge_create_with_config(uint64_t memory_limit, uint64_t stack_size) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)malloc(sizeof(QuickJSBridge));
    if (!bridge) {
        memory_tracker_record_failure();
        return NULL;
    }
    memory_tracker_record_alloc(sizeof(QuickJSBridge));

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
    // 参考 quickjs-ng：设置 GC 阈值（与内存限制一致，避免频繁 GC）
    JS_SetGCThreshold(bridge->runtime, (size_t)memory_limit / 4);
    // 参考 quickjs-zh：剥离源码和调试信息，减小字节码体积
    JS_SetStripInfo(bridge->runtime, JS_STRIP_SOURCE | JS_STRIP_DEBUG);

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
    bridge->eval_timeout_us = 0;
    bridge->eval_interrupted = 0;
    JS_SetContextOpaque(bridge->ctx, bridge);

    // P2: 注册超时熔断中断处理器
    JS_SetInterruptHandler(bridge->runtime, _interrupt_handler, bridge);

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
    // AES-ECB 模式（无 IV，纯 C 原生）
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesEncryptNativeECB",
        JS_NewCFunction(bridge->ctx, js_native_aes_encrypt_ecb, "aesEncryptNativeECB", 2));
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesDecryptNativeECB",
        JS_NewCFunction(bridge->ctx, js_native_aes_decrypt_ecb, "aesDecryptNativeECB", 2));
    // AES-CBC 解密 + LZString 解压 原子组合（3A 书源 content() 路径，消除 JS 侧字符串膨胀）
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesDecryptThenLzDecompress",
        JS_NewCFunction(bridge->ctx, js_native_aes_decrypt_then_lz, "aesDecryptThenLzDecompress", 2));
    // 批量 AES+LZ 原子组合（多线程分片，1300 条并发解密）
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesDecryptThenLzDecompressBatch",
        JS_NewCFunction(bridge->ctx, js_native_aes_decrypt_then_lz_batch, "aesDecryptThenLzDecompressBatch", 2));
    // 零拷贝 ArrayBuffer 路径（Phase 4）：避免 base64 字符串膨胀与多次内存复制
    // 适用于网络层直接返回 ArrayBuffer 的场景
    JS_SetPropertyStr(bridge->ctx, crypto_obj, "aesDecryptThenLzDecompressBin",
        JS_NewCFunction(bridge->ctx, js_native_aes_decrypt_then_lz_bin, "aesDecryptThenLzDecompressBin", 2));

    JS_SetPropertyStr(bridge->ctx, global_obj, "__nativeCrypto", crypto_obj);

    // 注册 LZString 原生全局对象 __nativeLz
    // 替代纯 JS 版本 LZString.decompressFromBase64，开销从 JS 路径转移到 C 层
    JSValue lz_obj = JS_NewObject(bridge->ctx);
    JS_SetPropertyStr(bridge->ctx, lz_obj, "decompressFromBase64",
        JS_NewCFunction(bridge->ctx, js_native_lz_decompress, "decompressFromBase64", 1));
    // 批量解压（多线程分片，消除逐条 JS↔C 往返）
    JS_SetPropertyStr(bridge->ctx, lz_obj, "decompressFromBase64Batch",
        JS_NewCFunction(bridge->ctx, js_native_lz_decompress_batch, "decompressFromBase64Batch", 1));
    // 零拷贝 ArrayBuffer 路径（Phase 4）
    JS_SetPropertyStr(bridge->ctx, lz_obj, "decompressFromBase64Bin",
        JS_NewCFunction(bridge->ctx, js_native_lz_decompress_bin, "decompressFromBase64Bin", 1));
    JS_SetPropertyStr(bridge->ctx, global_obj, "__nativeLz", lz_obj);

    // 注册 Base64 原生全局对象 __nativeBase64
    // 替代 JS 原生 atob/btoa，消除纯 JS 实现的逐字节循环与中间字符串分配
    // JS 侧通过 globalThis.atob = __nativeBase64.decode 接管
    JSValue b64_obj = JS_NewObject(bridge->ctx);
    JS_SetPropertyStr(bridge->ctx, b64_obj, "decode",
        JS_NewCFunction(bridge->ctx, js_native_atob, "decode", 1));
    JS_SetPropertyStr(bridge->ctx, b64_obj, "encode",
        JS_NewCFunction(bridge->ctx, js_native_btoa, "encode", 1));
    JS_SetPropertyStr(bridge->ctx, global_obj, "__nativeBase64", b64_obj);

    // 注册编码转换原生全局对象 __nativeConv
    // charsetUrlEncode(str, charset) → percent-encode using given charset
    // charsetDetect(html) → detect charset from HTML
    // charsetDecode(data, charset) → decode bytes to UTF-8 string
    JSValue conv_obj = JS_NewObject(bridge->ctx);
    JS_SetPropertyStr(bridge->ctx, conv_obj, "charsetUrlEncode",
        JS_NewCFunction(bridge->ctx, js_conv_charset_url_encode, "charsetUrlEncode", 2));
    JS_SetPropertyStr(bridge->ctx, conv_obj, "charsetDetect",
        JS_NewCFunction(bridge->ctx, js_conv_charset_detect, "charsetDetect", 1));
    JS_SetPropertyStr(bridge->ctx, conv_obj, "charsetDecode",
        JS_NewCFunction(bridge->ctx, js_conv_charset_decode, "charsetDecode", 2));
    JS_SetPropertyStr(bridge->ctx, global_obj, "__nativeConv", conv_obj);

    JS_FreeValue(bridge->ctx, global_obj);

    return bridge;
}

const char *quickjs_bridge_eval(QuickJSBridge *bridge, const char *script, int *is_error) {
    if (!bridge || !bridge->ctx || !script) {
        if (is_error) *is_error = 1;
        return NULL;
    }

    // P4: 超大脚本防护
    size_t script_len_pre = strlen(script);
    if (script_len_pre > MAX_SCRIPT_SIZE) {
        if (is_error) *is_error = 1;
        return strdup("SizeLimitError: script exceeds 1MB limit");
    }

    _ensure_globals();
    pthread_mutex_lock(&_g_bridge_mutex);

    // P2: 设置超时熔断开始时间
    bridge->eval_start_time_us = _now_us();
    bridge->eval_interrupted = 0;

    size_t script_len = strlen(script);
    JSValue val;

    // Phase 4: 字节码缓存 —— 命中时跳过词法/语法分析/字节码生成
    JSValue cached_bc = _bytecode_cache_lookup(bridge, script, script_len);
    if (!JS_IsNull(cached_bc)) {
        // 缓存命中：直接执行字节码（cached_bc 被 JS_EvalFunction 消费）
        val = JS_EvalFunction(bridge->ctx, cached_bc);
    } else {
        // 缓存未命中：编译为字节码（不执行），缓存，再执行
        val = JS_Eval(bridge->ctx, script, script_len, "<eval>",
                       JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
        if (!JS_IsException(val)) {
            // 存入缓存（内部 JS_DupValue，val 仍有效）
            _bytecode_cache_store(bridge, script, script_len, val);
            // 执行字节码（val 被 JS_EvalFunction 消费）
            val = JS_EvalFunction(bridge->ctx, val);
        }
    }

    const char *result_str;
    if (JS_IsException(val)) {
        JSValue exception = JS_GetException(bridge->ctx);
        JS_FreeValue(bridge->ctx, val);
        // P2: 超时熔断检测
        if (bridge->eval_interrupted) {
            JS_FreeValue(bridge->ctx, exception);
            if (is_error) *is_error = 1;
            char *timeout_msg = strdup("ScriptTimeoutError: execution timed out");
            memory_tracker_record_alloc(strlen(timeout_msg) + 1);
            pthread_mutex_unlock(&_g_bridge_mutex);
            return timeout_msg;
        }
        const char *str = JS_ToCString(bridge->ctx, exception);
        JS_FreeValue(bridge->ctx, exception);
        if (is_error) *is_error = 1;
        if (str) {
            char *result = strdup(str);
            JS_FreeCString(bridge->ctx, str);
            memory_tracker_record_alloc(strlen(result) + 1);
            pthread_mutex_unlock(&_g_bridge_mutex);
            return result;
        }
        result_str = "Unknown error";
        char *r = strdup(result_str);
        memory_tracker_record_alloc(strlen(r) + 1);
        pthread_mutex_unlock(&_g_bridge_mutex);
        return r;
    }

    const char *str = JS_ToCString(bridge->ctx, val);
    JS_FreeValue(bridge->ctx, val);
    if (is_error) *is_error = 0;

    if (str) {
        char *result = strdup(str);
        JS_FreeCString(bridge->ctx, str);
        memory_tracker_record_alloc(strlen(result) + 1);
        pthread_mutex_unlock(&_g_bridge_mutex);
        return result;
    }

    char *empty = strdup("");
    memory_tracker_record_alloc(1);
    pthread_mutex_unlock(&_g_bridge_mutex);
    return empty;
}

// Phase 4: 预编译脚本到字节码缓存（不执行）
// 用于在空闲时段预热高频脚本，后续 eval 时直接命中缓存
// 返回 0 成功，-1 失败（语法错误等）
int quickjs_bridge_precompile(QuickJSBridge *bridge, const char *script) {
    if (!bridge || !bridge->ctx || !script) return -1;
    _ensure_globals();
    pthread_mutex_lock(&_g_bridge_mutex);
    size_t len = strlen(script);

    // 已在缓存中则跳过
    JSValue cached = _bytecode_cache_lookup(bridge, script, len);
    if (!JS_IsNull(cached)) {
        JS_FreeValue(bridge->ctx, cached);  // 释放 lookup 返回的 dup
        pthread_mutex_unlock(&_g_bridge_mutex);
        return 0;
    }

    JSValue bc = JS_Eval(bridge->ctx, script, len, "<precompile>",
                         JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(bc)) {
        JS_FreeValue(bridge->ctx, bc);
        pthread_mutex_unlock(&_g_bridge_mutex);
        return -1;
    }

    _bytecode_cache_store(bridge, script, len, bc);
    JS_FreeValue(bridge->ctx, bc);  // 释放编译结果（cache 已 dup）
    pthread_mutex_unlock(&_g_bridge_mutex);
    return 0;
}

// Phase 4: 清空字节码缓存
// 用于内存压力场景或脚本失效（如书源切换后旧模板不再复用）
void quickjs_bridge_clear_bytecode_cache(QuickJSBridge *bridge) {
    if (bridge) _bytecode_cache_clear(bridge);
}

void quickjs_bridge_free_string(const char *str) {
    if (str) {
        size_t len = strlen(str);
        free((void *)str);
        memory_tracker_record_free(len + 1);
    }
}

void quickjs_bridge_dispose(QuickJSBridge *bridge) {
    if (!bridge) return;
    _ensure_globals();
    pthread_mutex_lock(&_g_bridge_mutex);
    // Phase 4: 必须在 JS_FreeContext 之前清空字节码缓存
    // （缓存的 JSValue 依赖 ctx 有效，否则 JS_FreeValue 会 UAF）
    _bytecode_cache_clear(bridge);
    if (bridge->ctx) {
        JS_FreeContext(bridge->ctx);
    }
    if (bridge->runtime) {
        JS_FreeRuntime(bridge->runtime);
    }
    free(bridge);
    memory_tracker_record_free(sizeof(struct QuickJSBridge));
    pthread_mutex_unlock(&_g_bridge_mutex);
}

// ---------- P1: 句柄化 API（替代裸指针，防止野指针）----------
// 上层 Dart 只持有 uint32_t 句柄，操作时查表拿指针

uint32_t quickjs_bridge_create_handle(void) {
    _ensure_globals();
    QuickJSBridge *bridge = quickjs_bridge_create();
    if (!bridge) return 0;
    return handle_table_register(_g_bridge_handles, bridge);
}

uint32_t quickjs_bridge_create_handle_with_config(uint64_t memory_limit, uint64_t stack_size) {
    _ensure_globals();
    QuickJSBridge *bridge = quickjs_bridge_create_with_config(memory_limit, stack_size);
    if (!bridge) return 0;
    return handle_table_register(_g_bridge_handles, bridge);
}

const char *quickjs_bridge_eval_handle(uint32_t handle, const char *script, int *is_error) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)handle_table_lookup(_g_bridge_handles, handle);
    if (!bridge) {
        if (is_error) *is_error = 1;
        return NULL;
    }
    return quickjs_bridge_eval(bridge, script, is_error);
}

int quickjs_bridge_precompile_handle(uint32_t handle, const char *script) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)handle_table_lookup(_g_bridge_handles, handle);
    if (!bridge) return -1;
    return quickjs_bridge_precompile(bridge, script);
}

void quickjs_bridge_dispose_handle(uint32_t handle) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)handle_table_unregister(_g_bridge_handles, handle);
    if (!bridge) return;
    quickjs_bridge_dispose(bridge);
}

void quickjs_bridge_clear_cache_handle(uint32_t handle) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)handle_table_lookup(_g_bridge_handles, handle);
    if (bridge) quickjs_bridge_clear_bytecode_cache(bridge);
}

// ---------- P1: 内存统计 API ----------

memory_stats_t quickjs_bridge_get_memory_stats(void) {
    _ensure_globals();
    return memory_tracker_get_stats();
}

void quickjs_bridge_reset_memory_stats(void) {
    _ensure_globals();
    memory_tracker_reset_stats();
}

int quickjs_bridge_get_active_handle_count(void) {
    _ensure_globals();
    return handle_table_count(_g_bridge_handles);
}

// ---------- 参考 quickjs-ng：JS 引擎内部内存统计 ----------

void quickjs_bridge_get_js_memory_stats(QuickJSBridge *bridge, JSMemoryUsage *out) {
    if (!bridge || !bridge->runtime || !out) return;
    JS_ComputeMemoryUsage(bridge->runtime, out);
}

void quickjs_bridge_get_js_memory_stats_handle(uint32_t handle, JSMemoryUsage *out) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)handle_table_lookup(_g_bridge_handles, handle);
    if (bridge) JS_ComputeMemoryUsage(bridge->runtime, out);
}

void quickjs_bridge_run_gc(QuickJSBridge *bridge) {
    if (!bridge || !bridge->runtime) return;
    JS_RunGC(bridge->runtime);
}

void quickjs_bridge_run_gc_handle(uint32_t handle) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)handle_table_lookup(_g_bridge_handles, handle);
    if (bridge) JS_RunGC(bridge->runtime);
}

// ---------- 参考 quickjs-ng/quickjs-zh：高价值 API 暴露 ----------

/// 参考 quickjs-zh：检测源码是否为 ES 模块
int quickjs_bridge_detect_module(const char *input, size_t input_len) {
    if (!input) return 0;
    return JS_DetectModule(input, input_len) ? 1 : 0;
}

/// 参考 quickjs-zh：检查当前 context 是否有异常（不取出）
int quickjs_bridge_has_exception(QuickJSBridge *bridge) {
    if (!bridge || !bridge->ctx) return 0;
    return JS_HasException(bridge->ctx) ? 1 : 0;
}

/// 参考 quickjs-ng：设置 Atomics.wait 可用性
void quickjs_bridge_set_can_block(QuickJSBridge *bridge, int can_block) {
    if (!bridge || !bridge->runtime) return;
    JS_SetCanBlock(bridge->runtime, can_block ? 1 : 0);
}

/// 参考 quickjs-zh：流式打印 JS 值（通过 JS 表达式）
/// 返回 malloc 分配的字符串，调用方需用 quickjs_bridge_free_string 释放
const char *quickjs_bridge_print_value(QuickJSBridge *bridge, const char *js_expr,
                                        int max_depth, int max_string_length) {
    if (!bridge || !bridge->ctx || !js_expr) return NULL;

    _ensure_globals();
    pthread_mutex_lock(&_g_bridge_mutex);

    // 执行 JS 表达式获取值
    JSValue val = JS_Eval(bridge->ctx, js_expr, strlen(js_expr), "<print>",
                          JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(val)) {
        JS_FreeValue(bridge->ctx, val);
        pthread_mutex_unlock(&_g_bridge_mutex);
        return strdup("Exception");
    }

    // 设置打印选项
    JSPrintValueOptions opts;
    JS_PrintValueSetDefaultOptions(&opts);
    if (max_depth > 0) opts.max_depth = (uint32_t)max_depth;
    if (max_string_length > 0) opts.max_string_length = (uint32_t)max_string_length;

    // 用 DynBuf 收集输出
    // 参考 quickjs-ng cutils.c：DynBuf 动态缓冲区
    size_t total_len = 0;
    char *result = NULL;

    // 简单方案：用 JS_ToCString 获取字符串表示
    // 完整方案需要 JSPrintValueWrite 回调，这里用简化版
    const char *str = JS_ToCString(bridge->ctx, val);
    JS_FreeValue(bridge->ctx, val);

    if (str) {
        result = strdup(str);
        JS_FreeCString(bridge->ctx, str);
        memory_tracker_record_alloc(strlen(result) + 1);
    } else {
        result = strdup("");
        memory_tracker_record_alloc(1);
    }

    pthread_mutex_unlock(&_g_bridge_mutex);
    return result;
}

/// 参考 quickjs-zh：获取 Promise 状态（通过 JS 代码查询）
/// 返回: 0=非Promise, 1=pending, 2=fulfilled, 3=rejected
int quickjs_bridge_promise_state(QuickJSBridge *bridge, const char *var_name) {
    if (!bridge || !bridge->ctx || !var_name) return 0;

    _ensure_globals();
    pthread_mutex_lock(&_g_bridge_mutex);

    // 构造 JS 代码检查 Promise 状态
    char script[512];
    snprintf(script, sizeof(script),
        "(function(){"
        "  try {"
        "    var v = %s;"
        "    if (typeof v !== 'object' || v === null || typeof v.then !== 'function') return 0;"
        "    var state = 1;" // 默认 pending
        "    v.then(function(){ state = 2; }, function(){ state = 3; });"
        "    return state;"
        "  } catch(e) { return 0; }"
        "})()", var_name);

    JSValue val = JS_Eval(bridge->ctx, script, strlen(script), "<promise>",
                          JS_EVAL_TYPE_GLOBAL);
    int state = 0;
    if (!JS_IsException(val)) {
        JS_ToInt32(bridge->ctx, &state, val);
    }
    JS_FreeValue(bridge->ctx, val);

    pthread_mutex_unlock(&_g_bridge_mutex);
    return state;
}

/// 参考 quickjs-zh：设置不可捕获异常
void quickjs_bridge_set_uncatchable_exception(QuickJSBridge *bridge, int flag) {
    if (!bridge || !bridge->ctx) return;
    JS_SetUncatchableException(bridge->ctx, flag ? 1 : 0);
}

/// 参考 quickjs-ng：获取 QuickJS 版本字符串
const char *quickjs_bridge_get_version(void) {
    return "QuickJS " CONFIG_VERSION;
}

// ---------- P2: 超时熔断 API ----------

void quickjs_bridge_set_eval_timeout(QuickJSBridge *bridge, uint64_t timeout_ms) {
    if (!bridge) return;
    bridge->eval_timeout_us = timeout_ms * 1000;
}

void quickjs_bridge_set_eval_timeout_handle(uint32_t handle, uint64_t timeout_ms) {
    _ensure_globals();
    QuickJSBridge *bridge = (QuickJSBridge *)handle_table_lookup(_g_bridge_handles, handle);
    if (bridge) bridge->eval_timeout_us = timeout_ms * 1000;
}

int quickjs_bridge_was_eval_interrupted(QuickJSBridge *bridge) {
    if (!bridge) return 0;
    return bridge->eval_interrupted;
}
