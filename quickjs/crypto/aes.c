// AES-128/192/256 + CBC + PKCS7 - 基于 kokke/tiny-AES-c（公开领域 BSD 许可）
// 简化版：仅实现 AES-CBC + PKCS7，适配书源场景
#include "aes.h"
#include <string.h>
#include <stdlib.h>

// ---------- AES S-Box 和逆 S-Box ----------
static const uint8_t sbox[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
};

static const uint8_t rsbox[256] = {
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d
};

// 轮常量
static const uint8_t Rcon[11] = {
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36
};

// ---------- GF(2^8) 乘法 ----------
static uint8_t xtime(uint8_t x) {
    return (uint8_t)((x << 1) ^ ((x >> 7) * 0x1b));
}

static uint8_t gf_mul(uint8_t a, uint8_t b) {
    uint8_t p = 0;
    for (int i = 0; i < 8; i++) {
        if (b & 1) p ^= a;
        a = xtime(a);
        b >>= 1;
    }
    return p;
}

// ---------- 密钥扩展 ----------
static int aes_key_expansion(aes_ctx_t *ctx, const uint8_t *key, size_t key_len) {
    int Nk, Nr;
    switch (key_len) {
        case 16: Nk = 4; Nr = 10; break;
        case 24: Nk = 6; Nr = 12; break;
        case 32: Nk = 8; Nr = 14; break;
        default: return -1;  // 无效密钥长度
    }
    ctx->rounds = Nr;

    // 轮密钥字总数 = 4 * (Nr + 1)
    int total_words = 4 * (Nr + 1);
    uint8_t *rk = ctx->round_key;

    // 前 Nk 个字直接复制密钥
    memcpy(rk, key, key_len);

    // 扩展后续字
    for (int i = Nk; i < total_words; i++) {
        uint8_t temp[4];
        temp[0] = rk[(i-1)*4 + 0];
        temp[1] = rk[(i-1)*4 + 1];
        temp[2] = rk[(i-1)*4 + 2];
        temp[3] = rk[(i-1)*4 + 3];

        if (i % Nk == 0) {
            // RotWord
            uint8_t t = temp[0];
            temp[0] = temp[1];
            temp[1] = temp[2];
            temp[2] = temp[3];
            temp[3] = t;
            // SubWord
            temp[0] = sbox[temp[0]];
            temp[1] = sbox[temp[1]];
            temp[2] = sbox[temp[2]];
            temp[3] = sbox[temp[3]];
            // Rcon
            temp[0] ^= Rcon[i / Nk];
        } else if (Nk > 6 && i % Nk == 4) {
            // 仅 AES-256
            temp[0] = sbox[temp[0]];
            temp[1] = sbox[temp[1]];
            temp[2] = sbox[temp[2]];
            temp[3] = sbox[temp[3]];
        }

        rk[i*4 + 0] = rk[(i-Nk)*4 + 0] ^ temp[0];
        rk[i*4 + 1] = rk[(i-Nk)*4 + 1] ^ temp[1];
        rk[i*4 + 2] = rk[(i-Nk)*4 + 2] ^ temp[2];
        rk[i*4 + 3] = rk[(i-Nk)*4 + 3] ^ temp[3];
    }
    return 0;
}

// ---------- SubBytes / InvSubBytes ----------
static void sub_bytes(uint8_t state[16]) {
    for (int i = 0; i < 16; i++) state[i] = sbox[state[i]];
}
static void inv_sub_bytes(uint8_t state[16]) {
    for (int i = 0; i < 16; i++) state[i] = rsbox[state[i]];
}

// ---------- ShiftRows / InvShiftRows ----------
// state 按列存储：state[col*4 + row]
static void shift_rows(uint8_t s[16]) {
    uint8_t t;
    // Row 1: 左移 1
    t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t;
    // Row 2: 左移 2
    t = s[2]; s[2] = s[10]; s[10] = t;
    t = s[6]; s[6] = s[14]; s[14] = t;
    // Row 3: 左移 3（即右移 1）
    t = s[3]; s[3] = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = t;
}
static void inv_shift_rows(uint8_t s[16]) {
    uint8_t t;
    // Row 1: 右移 1
    t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
    // Row 2: 右移 2
    t = s[2]; s[2] = s[10]; s[10] = t;
    t = s[6]; s[6] = s[14]; s[14] = t;
    // Row 3: 右移 3（即左移 1）
    t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
}

// ---------- GF(2^8) 预计算查表（消除 gf_mul 循环，8x 加速 MixColumns）----------
static int _gf_tables_inited = 0;
static uint8_t gf2[256];   // 乘 2
static uint8_t gf3[256];   // 乘 3
static uint8_t gf9[256];   // 乘 9
static uint8_t gf11[256];  // 乘 0x0b
static uint8_t gf13[256];  // 乘 0x0d
static uint8_t gf14[256];  // 乘 0x0e

static void _init_gf_tables(void) {
    for (int i = 0; i < 256; i++) {
        uint8_t x = (uint8_t)i;
        gf2[i] = xtime(x);
        gf3[i] = x ^ xtime(x);
        gf9[i] = gf_mul(x, 0x09);
        gf11[i] = gf_mul(x, 0x0b);
        gf13[i] = gf_mul(x, 0x0d);
        gf14[i] = gf_mul(x, 0x0e);
    }
    _gf_tables_inited = 1;
}

// ---------- MixColumns / InvMixColumns ----------
static void mix_columns(uint8_t s[16]) {
    if (!_gf_tables_inited) _init_gf_tables();
    for (int c = 0; c < 4; c++) {
        uint8_t *col = &s[c*4];
        uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3];
        col[0] = gf2[a0] ^ gf3[a1] ^ a2 ^ a3;
        col[1] = a0 ^ gf2[a1] ^ gf3[a2] ^ a3;
        col[2] = a0 ^ a1 ^ gf2[a2] ^ gf3[a3];
        col[3] = gf3[a0] ^ a1 ^ a2 ^ gf2[a3];
    }
}
static void inv_mix_columns(uint8_t s[16]) {
    if (!_gf_tables_inited) _init_gf_tables();
    for (int c = 0; c < 4; c++) {
        uint8_t *col = &s[c*4];
        uint8_t a0 = col[0], a1 = col[1], a2 = col[2], a3 = col[3];
        col[0] = gf14[a0] ^ gf11[a1] ^ gf13[a2] ^ gf9[a3];
        col[1] = gf9[a0] ^ gf14[a1] ^ gf11[a2] ^ gf13[a3];
        col[2] = gf13[a0] ^ gf9[a1] ^ gf14[a2] ^ gf11[a3];
        col[3] = gf11[a0] ^ gf13[a1] ^ gf9[a2] ^ gf14[a3];
    }
}

// ---------- AddRoundKey ----------
static void add_round_key(uint8_t s[16], const uint8_t *rk) {
    for (int i = 0; i < 16; i++) s[i] ^= rk[i];
}

// ---------- 单块加密 / 解密 ----------
static void aes_encrypt_block(const aes_ctx_t *ctx, const uint8_t in[16], uint8_t out[16]) {
    uint8_t state[16];
    memcpy(state, in, 16);

    add_round_key(state, ctx->round_key);

    for (int round = 1; round < ctx->rounds; round++) {
        sub_bytes(state);
        shift_rows(state);
        mix_columns(state);
        add_round_key(state, ctx->round_key + round * 16);
    }

    sub_bytes(state);
    shift_rows(state);
    add_round_key(state, ctx->round_key + ctx->rounds * 16);

    memcpy(out, state, 16);
}

static void aes_decrypt_block(const aes_ctx_t *ctx, const uint8_t in[16], uint8_t out[16]) {
    uint8_t state[16];
    memcpy(state, in, 16);

    add_round_key(state, ctx->round_key + ctx->rounds * 16);

    for (int round = ctx->rounds - 1; round >= 1; round--) {
        inv_shift_rows(state);
        inv_sub_bytes(state);
        add_round_key(state, ctx->round_key + round * 16);
        inv_mix_columns(state);
    }

    inv_shift_rows(state);
    inv_sub_bytes(state);
    add_round_key(state, ctx->round_key);

    memcpy(out, state, 16);
}

// ---------- 公共 API ----------
int aes_init(aes_ctx_t *ctx, const uint8_t *key, size_t key_len) {
    return aes_key_expansion(ctx, key, key_len);
}

size_t aes_cbc_encrypt(const aes_ctx_t *ctx,
                       const uint8_t iv[16],
                       const uint8_t *plaintext, size_t plaintext_len,
                       uint8_t *ciphertext) {
    // PKCS7 padding
    size_t pad_len = 16 - (plaintext_len % 16);
    if (pad_len == 0) pad_len = 16;  // 即使是 16 的倍数也要 pad

    // padded 长度
    size_t padded_len = plaintext_len + pad_len;

    // 复制明文 + padding
    uint8_t *padded = (uint8_t *)malloc(padded_len);
    if (!padded) return (size_t)-1;
    memcpy(padded, plaintext, plaintext_len);
    for (size_t i = plaintext_len; i < padded_len; i++) {
        padded[i] = (uint8_t)pad_len;
    }

    // CBC 加密
    uint8_t prev[16];
    memcpy(prev, iv, 16);

    for (size_t off = 0; off < padded_len; off += 16) {
        uint8_t block[16];
        // 异或前一个密文块（或 IV）
        for (int i = 0; i < 16; i++) {
            block[i] = padded[off + i] ^ prev[i];
        }
        aes_encrypt_block(ctx, block, ciphertext + off);
        memcpy(prev, ciphertext + off, 16);
    }

    free(padded);
    return padded_len;
}

size_t aes_cbc_decrypt(const aes_ctx_t *ctx,
                       const uint8_t iv[16],
                       const uint8_t *ciphertext, size_t ciphertext_len,
                       uint8_t *plaintext) {
    // 密文长度必须是 16 的倍数
    if (ciphertext_len == 0 || ciphertext_len % 16 != 0) {
        return (size_t)-1;
    }

    uint8_t prev[16];
    memcpy(prev, iv, 16);

    for (size_t off = 0; off < ciphertext_len; off += 16) {
        uint8_t block[16];
        aes_decrypt_block(ctx, ciphertext + off, block);
        // 异或前一个密文块（或 IV）
        for (int i = 0; i < 16; i++) {
            plaintext[off + i] = block[i] ^ prev[i];
        }
        memcpy(prev, ciphertext + off, 16);
    }

    // 验证 PKCS7 padding
    uint8_t pad_len = plaintext[ciphertext_len - 1];
    if (pad_len < 1 || pad_len > 16) {
        return (size_t)-1;
    }
    // 检查所有 padding 字节
    for (size_t i = ciphertext_len - pad_len; i < ciphertext_len; i++) {
        if (plaintext[i] != pad_len) {
            return (size_t)-1;
        }
    }

    return ciphertext_len - pad_len;
}

// ---------- AES-ECB-PKCS7 解密 ----------
size_t aes_ecb_decrypt(const aes_ctx_t *ctx,
                       const uint8_t *ciphertext, size_t ciphertext_len,
                       uint8_t *plaintext) {
    // 密文长度必须是 16 的倍数
    if (ciphertext_len == 0 || ciphertext_len % 16 != 0) {
        return (size_t)-1;
    }

    for (size_t off = 0; off < ciphertext_len; off += 16) {
        aes_decrypt_block(ctx, ciphertext + off, plaintext + off);
    }

    // 验证 PKCS7 padding
    uint8_t pad_len = plaintext[ciphertext_len - 1];
    if (pad_len < 1 || pad_len > 16) {
        return (size_t)-1;
    }
    for (size_t i = ciphertext_len - pad_len; i < ciphertext_len; i++) {
        if (plaintext[i] != pad_len) {
            return (size_t)-1;
        }
    }

    return ciphertext_len - pad_len;
}

// ---------- AES-ECB-PKCS7 加密 ----------
size_t aes_ecb_encrypt(const aes_ctx_t *ctx,
                       const uint8_t *plaintext, size_t plaintext_len,
                       uint8_t *ciphertext) {
    // PKCS7 padding（直接写入 ciphertext 输出缓冲区，避免额外 malloc）
    size_t pad_len = 16 - (plaintext_len % 16);
    if (pad_len == 0) pad_len = 16;

    size_t padded_len = plaintext_len + pad_len;

    // 输出缓冲区由调用者保证 >= padded_len，直接写入
    memcpy(ciphertext, plaintext, plaintext_len);
    for (size_t i = plaintext_len; i < padded_len; i++) {
        ciphertext[i] = (uint8_t)pad_len;
    }

    for (size_t off = 0; off < padded_len; off += 16) {
        aes_encrypt_block(ctx, ciphertext + off, ciphertext + off);
    }

    return padded_len;
}
