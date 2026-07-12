#ifndef CRYPTO_AES_H
#define CRYPTO_AES_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// AES 上下文（仅加密，128/192/256 通用）
typedef struct {
    uint8_t round_key[240];  // 最多 14 轮，每轮 16 字节
    int rounds;              // 10/12/14
} aes_ctx_t;

// 初始化（key_len 必须是 16/24/32 字节）
int aes_init(aes_ctx_t *ctx, const uint8_t *key, size_t key_len);

// AES-CBC-PKCS7 加密
// 输出缓冲大小至少 plaintext_len + 16 字节（PKCS7 padding 最多 16 字节）
// 返回密文长度（plaintext_len 向上取 16 的倍数）
size_t aes_cbc_encrypt(const aes_ctx_t *ctx,
                       const uint8_t iv[16],
                       const uint8_t *plaintext, size_t plaintext_len,
                       uint8_t *ciphertext);

// AES-CBC-PKCS7 解密
// 输出缓冲大小至少 ciphertext_len - 1（去掉 padding）
// 返回明文长度，padding 错误返回 (size_t)-1
size_t aes_cbc_decrypt(const aes_ctx_t *ctx,
                       const uint8_t iv[16],
                       const uint8_t *ciphertext, size_t ciphertext_len,
                       uint8_t *plaintext);

#ifdef __cplusplus
}
#endif

// ---------- AES-ECB-PKCS7 ----------
// 输出缓冲大小至少 ciphertext_len - 1（去掉 padding）
// 返回明文长度，padding 错误返回 (size_t)-1
size_t aes_ecb_decrypt(const aes_ctx_t *ctx,
                       const uint8_t *ciphertext, size_t ciphertext_len,
                       uint8_t *plaintext);

// AES-ECB-PKCS7 加密
// 输出缓冲大小至少 plaintext_len + 16 字节（PKCS7 padding 最多 16 字节）
// 返回密文长度（plaintext_len 向上取 16 的倍数）
size_t aes_ecb_encrypt(const aes_ctx_t *ctx,
                       const uint8_t *plaintext, size_t plaintext_len,
                       uint8_t *ciphertext);

#endif /* CRYPTO_AES_H */
