#ifndef CRYPTO_SHA1_H
#define CRYPTO_SHA1_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t state[5];
    uint64_t count;
    uint8_t buffer[64];
} sha1_ctx_t;

void sha1_init(sha1_ctx_t *ctx);
void sha1_update(sha1_ctx_t *ctx, const uint8_t *data, size_t len);
void sha1_final(sha1_ctx_t *ctx, uint8_t digest[20]);
void sha1(const uint8_t *data, size_t len, uint8_t digest[20]);

#ifdef __cplusplus
}
#endif

#endif /* CRYPTO_SHA1_H */
