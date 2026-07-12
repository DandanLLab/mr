#ifndef CRYPTO_SHA256_H
#define CRYPTO_SHA256_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t buffer[64];
} sha256_ctx_t;

void sha256_init(sha256_ctx_t *ctx);
void sha256_update(sha256_ctx_t *ctx, const uint8_t *data, size_t len);
void sha256_final(sha256_ctx_t *ctx, uint8_t digest[32]);
void sha256(const uint8_t *data, size_t len, uint8_t digest[32]);

#ifdef __cplusplus
}
#endif

#endif /* CRYPTO_SHA256_H */
