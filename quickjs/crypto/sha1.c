// SHA-1 算法 - FIPS PUB 180-4
#include "sha1.h"
#include <string.h>

#define SHA1_BLOCK_SIZE 64

#define ROTLEFT(a, b) (((a) << (b)) | ((a) >> (32 - (b))))

static void sha1_transform(uint32_t state[5], const uint8_t block[64]) {
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3], e = state[4];
    uint32_t w[80];

    // 前 16 个字：小端解码
    for (int i = 0; i < 16; i++) {
        w[i] =  ((uint32_t)block[i*4] << 24)
             |  ((uint32_t)block[i*4+1] << 16)
             |  ((uint32_t)block[i*4+2] << 8)
             |   (uint32_t)block[i*4+3];
    }
    // 后 64 个字扩展
    for (int i = 16; i < 80; i++) {
        w[i] = ROTLEFT(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
    }

    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20) {
            f = (b & c) | (~b & d);
            k = 0x5A827999;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }
        uint32_t temp = ROTLEFT(a, 5) + f + e + k + w[i];
        e = d;
        d = c;
        c = ROTLEFT(b, 30);
        b = a;
        a = temp;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
}

static void sha1_encode_be(uint8_t *out, const uint32_t *in, size_t len) {
    for (size_t i = 0, j = 0; j < len; i++, j += 4) {
        out[j]   = (uint8_t)((in[i] >> 24) & 0xff);
        out[j+1] = (uint8_t)((in[i] >> 16) & 0xff);
        out[j+2] = (uint8_t)((in[i] >> 8) & 0xff);
        out[j+3] = (uint8_t)(in[i] & 0xff);
    }
}

void sha1_init(sha1_ctx_t *ctx) {
    ctx->count = 0;
    ctx->state[0] = 0x67452301;
    ctx->state[1] = 0xEFCDAB89;
    ctx->state[2] = 0x98BADCFE;
    ctx->state[3] = 0x10325476;
    ctx->state[4] = 0xC3D2E1F0;
}

void sha1_update(sha1_ctx_t *ctx, const uint8_t *data, size_t len) {
    size_t index = (size_t)((ctx->count >> 3) & 0x3F);
    ctx->count += (uint64_t)len << 3;

    size_t part_len = SHA1_BLOCK_SIZE - index;
    size_t i = 0;

    if (len >= part_len) {
        memcpy(&ctx->buffer[index], data, part_len);
        sha1_transform(ctx->state, ctx->buffer);
        i = part_len;
        while (i + SHA1_BLOCK_SIZE <= len) {
            sha1_transform(ctx->state, &data[i]);
            i += SHA1_BLOCK_SIZE;
        }
        index = 0;
    }

    if (i < len) {
        memcpy(&ctx->buffer[index], &data[i], len - i);
    }
}

void sha1_final(sha1_ctx_t *ctx, uint8_t digest[20]) {
    uint8_t bits[8];
    sha1_encode_be(bits, (uint32_t *)&ctx->count, 8);

    size_t index = (size_t)((ctx->count >> 3) & 0x3F);
    size_t pad_len = (index < 56) ? (56 - index) : (120 - index);

    static const uint8_t padding[64] = {
        0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    };

    sha1_update(ctx, padding, pad_len);
    sha1_update(ctx, bits, 8);

    sha1_encode_be(digest, ctx->state, 20);
}

void sha1(const uint8_t *data, size_t len, uint8_t digest[20]) {
    sha1_ctx_t ctx;
    sha1_init(&ctx);
    sha1_update(&ctx, data, len);
    sha1_final(&ctx, digest);
}
