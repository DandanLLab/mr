#ifndef CRYPTO_MD5_H
#define CRYPTO_MD5_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// MD5 上下文
typedef struct {
    uint32_t state[4];    // A, B, C, D
    uint64_t count;       // 已处理比特数
    uint8_t buffer[64];   // 输入缓冲
} md5_ctx_t;

// 初始化
void md5_init(md5_ctx_t *ctx);
// 更新
void md5_update(md5_ctx_t *ctx, const uint8_t *data, size_t len);
// 完成，输出 16 字节摘要
void md5_final(md5_ctx_t *ctx, uint8_t digest[16]);
// 一次性计算
void md5(const uint8_t *data, size_t len, uint8_t digest[16]);

#ifdef __cplusplus
}
#endif

#endif /* CRYPTO_MD5_H */
