// 批量解压：多线程分片并发
//
// 核心思想：将 N 个独立解压任务按 CPU 核心数切分为 K 个连续分片，
// 每片投放至独立工作线程并发执行。LZString 与 AES 解密均为纯 C 计算，
// 无 JS 上下文依赖，线程安全。
//
// 跨平台线程：
//   - POSIX（Android/Linux/iOS）：pthread
//   - Windows：CreateThread / WaitForSingleObject
//
// SIMD 备注：LZString 的 LZW 解压数据依赖性强（字典前向引用），
// 难以向量化；AES-CBC 解密链式依赖 IV，单条无法并行。
// 多线程已充分利用多核，SIMD 优化留作未来针对 base64 解码热点展开。

#include "batch_decompress.h"
#include "lzstring.h"
#include "crypto/aes.h"
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32) || defined(_WIN64)
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

// ---------- 平台工具 ----------
int get_cpu_count(void) {
#if defined(_WIN32) || defined(_WIN64)
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (int)si.dwNumberOfProcessors;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 1;
#endif
}

// ---------- Base64 解码（批量路径内部使用）----------
// 与 quickjs_bridge.c 中的 b64_decode 同实现，独立副本避免跨编译单元耦合
static uint8_t *b64_decode_local(const char *src, size_t src_len, size_t *out_len) {
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

// ---------- 跨平台线程抽象 ----------
#if defined(_WIN32) || defined(_WIN64)
typedef HANDLE thread_t;
static int thread_create(thread_t *t, void *(*fn)(void *), void *arg) {
    *t = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)fn, arg, 0, NULL);
    return *t ? 0 : -1;
}
static int thread_join(thread_t t) {
    DWORD r = WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
    return r == WAIT_FAILED ? -1 : 0;
}
#else
typedef pthread_t thread_t;
static int thread_create(thread_t *t, void *(*fn)(void *), void *arg) {
    return pthread_create(t, NULL, fn, arg);
}
static int thread_join(thread_t t) {
    return pthread_join(t, NULL);
}
#endif

// ---------- LZString 批量解压 ----------
typedef struct {
    const char **inputs;
    const size_t *input_lens;
    char **outputs;
    size_t *out_lens;
    size_t start;
    size_t end;
} lz_batch_ctx_t;

static void *lz_batch_worker(void *arg) {
    lz_batch_ctx_t *ctx = (lz_batch_ctx_t *)arg;
    size_t i;
    for (i = ctx->start; i < ctx->end; i++) {
        ctx->outputs[i] = lz_decompress_from_base64(
            ctx->inputs[i], ctx->input_lens[i], &ctx->out_lens[i]);
    }
    return NULL;
}

int lz_decompress_batch(const char **inputs, const size_t *input_lens, size_t count,
                        char ***out_results, size_t **out_lens) {
    if (count == 0) {
        *out_results = NULL;
        *out_lens = NULL;
        return 0;
    }

    *out_results = (char **)calloc(count, sizeof(char *));
    *out_lens = (size_t *)calloc(count, sizeof(size_t));
    if (!*out_results || !*out_lens) {
        free(*out_results);
        free(*out_lens);
        *out_results = NULL;
        *out_lens = NULL;
        return -1;
    }

    int nthreads = get_cpu_count();
    if (nthreads < 1) nthreads = 1;
    if (nthreads > (int)count) nthreads = (int)count;

    if (nthreads == 1) {
        lz_batch_ctx_t ctx = { inputs, input_lens, *out_results, *out_lens, 0, count };
        lz_batch_worker(&ctx);
        return 0;
    }

    thread_t *threads = (thread_t *)malloc(nthreads * sizeof(thread_t));
    lz_batch_ctx_t *ctxs = (lz_batch_ctx_t *)malloc(nthreads * sizeof(lz_batch_ctx_t));
    if (!threads || !ctxs) {
        free(threads);
        free(ctxs);
        // 回退单线程
        lz_batch_ctx_t ctx = { inputs, input_lens, *out_results, *out_lens, 0, count };
        lz_batch_worker(&ctx);
        return 0;
    }

    size_t per = count / nthreads;
    size_t rem = count % nthreads;
    size_t pos = 0;
    int i;
    int ok = 1;

    for (i = 0; i < nthreads; i++) {
        ctxs[i].inputs = inputs;
        ctxs[i].input_lens = input_lens;
        ctxs[i].outputs = *out_results;
        ctxs[i].out_lens = *out_lens;
        ctxs[i].start = pos;
        pos += per + (i < (int)rem ? 1 : 0);
        ctxs[i].end = pos;
        if (thread_create(&threads[i], lz_batch_worker, &ctxs[i]) != 0) {
            // 创建失败，该片在主线程直接跑
            lz_batch_worker(&ctxs[i]);
            threads[i] = 0;
            ok = 0;
        }
    }

    for (i = 0; i < nthreads; i++) {
        if (ok && threads[i] != 0) {
            thread_join(threads[i]);
        }
    }

    free(threads);
    free(ctxs);
    return 0;
}

// ---------- AES+LZ 批量解密解压 ----------
typedef struct {
    const char **b64_inputs;
    const size_t *b64_lens;
    const char *key_utf8;
    size_t key_len;
    char **outputs;
    size_t *out_lens;
    size_t start;
    size_t end;
} aes_lz_batch_ctx_t;

static void *aes_lz_batch_worker(void *arg) {
    aes_lz_batch_ctx_t *ctx = (aes_lz_batch_ctx_t *)arg;
    size_t i;
    for (i = ctx->start; i < ctx->end; i++) {
        const char *b64 = ctx->b64_inputs[i];
        size_t b64_len = ctx->b64_lens[i];

        // 1. base64 解码
        size_t raw_len = 0;
        uint8_t *raw = b64_decode_local(b64, b64_len, &raw_len);
        if (!raw || raw_len < 16 || (raw_len - 16) == 0 || (raw_len - 16) % 16 != 0) {
            if (raw) free(raw);
            ctx->outputs[i] = NULL;
            ctx->out_lens[i] = 0;
            continue;
        }

        // 2. 拆分 IV + 密文
        const uint8_t *iv = raw;
        const uint8_t *cipher = raw + 16;
        size_t cipher_len = raw_len - 16;

        // 3. AES-CBC-PKCS7 解密
        aes_ctx_t actx;
        if (aes_init(&actx, (const uint8_t *)ctx->key_utf8, ctx->key_len) != 0) {
            free(raw);
            ctx->outputs[i] = NULL;
            ctx->out_lens[i] = 0;
            continue;
        }

        uint8_t *plain = (uint8_t *)malloc(cipher_len);
        if (!plain) {
            free(raw);
            ctx->outputs[i] = NULL;
            ctx->out_lens[i] = 0;
            continue;
        }

        size_t plain_len = aes_cbc_decrypt(&actx, iv, cipher, cipher_len, plain);
        free(raw);

        if (plain_len == (size_t)-1) {
            free(plain);
            ctx->outputs[i] = NULL;
            ctx->out_lens[i] = 0;
            continue;
        }

        // 4. LZString 解压
        size_t lz_out_len = 0;
        char *lz_out = lz_decompress_from_base64((const char *)plain, plain_len, &lz_out_len);
        free(plain);

        ctx->outputs[i] = lz_out;  // 可能为 NULL（解压失败）
        ctx->out_lens[i] = lz_out_len;
    }
    return NULL;
}

int aes_decrypt_lz_batch(const char **b64_inputs, const size_t *b64_lens, size_t count,
                         const char *key_utf8, size_t key_len,
                         char ***out_results, size_t **out_lens) {
    if (count == 0) {
        *out_results = NULL;
        *out_lens = NULL;
        return 0;
    }

    // key 长度校验
    if (key_len != 16 && key_len != 24 && key_len != 32) {
        return -2;
    }

    *out_results = (char **)calloc(count, sizeof(char *));
    *out_lens = (size_t *)calloc(count, sizeof(size_t));
    if (!*out_results || !*out_lens) {
        free(*out_results);
        free(*out_lens);
        *out_results = NULL;
        *out_lens = NULL;
        return -1;
    }

    int nthreads = get_cpu_count();
    if (nthreads < 1) nthreads = 1;
    if (nthreads > (int)count) nthreads = (int)count;

    if (nthreads == 1) {
        aes_lz_batch_ctx_t ctx = {
            b64_inputs, b64_lens, key_utf8, key_len,
            *out_results, *out_lens, 0, count
        };
        aes_lz_batch_worker(&ctx);
        return 0;
    }

    thread_t *threads = (thread_t *)malloc(nthreads * sizeof(thread_t));
    aes_lz_batch_ctx_t *ctxs = (aes_lz_batch_ctx_t *)malloc(nthreads * sizeof(aes_lz_batch_ctx_t));
    if (!threads || !ctxs) {
        free(threads);
        free(ctxs);
        aes_lz_batch_ctx_t ctx = {
            b64_inputs, b64_lens, key_utf8, key_len,
            *out_results, *out_lens, 0, count
        };
        aes_lz_batch_worker(&ctx);
        return 0;
    }

    size_t per = count / nthreads;
    size_t rem = count % nthreads;
    size_t pos = 0;
    int i;
    int ok = 1;

    for (i = 0; i < nthreads; i++) {
        ctxs[i].b64_inputs = b64_inputs;
        ctxs[i].b64_lens = b64_lens;
        ctxs[i].key_utf8 = key_utf8;
        ctxs[i].key_len = key_len;
        ctxs[i].outputs = *out_results;
        ctxs[i].out_lens = *out_lens;
        ctxs[i].start = pos;
        pos += per + (i < (int)rem ? 1 : 0);
        ctxs[i].end = pos;
        if (thread_create(&threads[i], aes_lz_batch_worker, &ctxs[i]) != 0) {
            aes_lz_batch_worker(&ctxs[i]);
            threads[i] = 0;
            ok = 0;
        }
    }

    for (i = 0; i < nthreads; i++) {
        if (ok && threads[i] != 0) {
            thread_join(threads[i]);
        }
    }

    free(threads);
    free(ctxs);
    return 0;
}
