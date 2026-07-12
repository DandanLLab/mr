// HMAC-SHA256 - RFC 2104
#include "hmac_sha256.h"
#include "sha256.h"
#include <string.h>

void hmac_sha256(const uint8_t *key, size_t key_len,
                 const uint8_t *data, size_t data_len,
                 uint8_t digest[32]) {
    uint8_t k_ipad[64];
    uint8_t k_opad[64];
    uint8_t tk[32];
    sha256_ctx_t ctx;

    // 密钥超过块大小（64 字节）则先 hash
    if (key_len > 64) {
        sha256(key, key_len, tk);
        key = tk;
        key_len = 32;
    }

    // 密钥填充到块大小
    memset(k_ipad, 0, 64);
    memset(k_opad, 0, 64);
    memcpy(k_ipad, key, key_len);
    memcpy(k_opad, key, key_len);

    // XOR
    for (int i = 0; i < 64; i++) {
        k_ipad[i] ^= 0x36;
        k_opad[i] ^= 0x5c;
    }

    // 内层 hash：H((K^ipad) || data)
    sha256_init(&ctx);
    sha256_update(&ctx, k_ipad, 64);
    sha256_update(&ctx, data, data_len);
    uint8_t inner_digest[32];
    sha256_final(&ctx, inner_digest);

    // 外层 hash：H((K^opad) || inner)
    sha256_init(&ctx);
    sha256_update(&ctx, k_opad, 64);
    sha256_update(&ctx, inner_digest, 32);
    sha256_final(&ctx, digest);
}
