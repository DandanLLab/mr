// LZString 解压缩 C 实现
// 精确移植自 3A 书源 d/3a.source(1).js 第 15-204 行的 LZString.decompressFromBase64
//
// 核心算法：LZW 解压，输入为 Base64 字母表索引流
// 字典存储 UTF-8 字符串（JS 原版为 UTF-16 code unit，此处转为 UTF-8 以便 QuickJS 直接使用）

#include "lzstring.h"
#include <stdlib.h>
#include <string.h>

// Base64 字母表（与 JS keyStrBase64 一致）
static const char kKeyStrBase64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";

// Base64 反向查找表（ASCII 字符 → 6 位索引），-1 表示无效
static int g_base64_reverse[128];
static int g_base64_inited = 0;

static void init_base64_reverse(void) {
    int i;
    if (g_base64_inited) return;
    for (i = 0; i < 128; i++) g_base64_reverse[i] = -1;
    for (i = 0; i < 64; i++) {
        g_base64_reverse[(unsigned char)kKeyStrBase64[i]] = i;
    }
    g_base64_inited = 1;
}

// 把 Unicode 码点（UTF-16 code unit，0-65535）编码为 UTF-8
// 对应 JS 的 String.fromCharCode(code)
// 代理对（0xD800-0xDFFF）按 CESU-8 编码（3 字节），与 JS 字符串语义一致
static int utf16_to_utf8(int code, char *buf) {
    if (code < 0) code = 0;
    if (code > 0xFFFF) code = 0xFFFD; // 超出 BMP 用替换字符兜底
    if (code < 0x80) {
        buf[0] = (char)code;
        return 1;
    } else if (code < 0x800) {
        buf[0] = (char)(0xC0 | (code >> 6));
        buf[1] = (char)(0x80 | (code & 0x3F));
        return 2;
    } else {
        buf[0] = (char)(0xE0 | (code >> 12));
        buf[1] = (char)(0x80 | ((code >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (code & 0x3F));
        return 3;
    }
}

// 返回 UTF-8 字符串首字符的字节长度（用于 LZW 的 charAt(0) 语义）
static size_t utf8_first_char_len(const char *s, size_t len) {
    unsigned char b0;
    if (len == 0) return 0;
    b0 = (unsigned char)s[0];
    if (b0 < 0x80) return 1;
    if (b0 < 0xC0) return 1;  // 非法续字节，兜底 1
    if (b0 < 0xE0) return 2;
    if (b0 < 0xF0) return 3;
    return 1;  // 4 字节 UTF-8 不应出现（JS fromCharCode 不会产生），兜底
}

// 动态字符串缓冲区
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} lz_buf_t;

static void buf_init(lz_buf_t *b) {
    b->cap = 256;
    b->len = 0;
    b->data = (char *)malloc(b->cap);
}

static void buf_ensure(lz_buf_t *b, size_t need) {
    if (b->len + need <= b->cap) return;
    while (b->len + need > b->cap) b->cap *= 2;
    b->data = (char *)realloc(b->data, b->cap);
}

static void buf_append(lz_buf_t *b, const char *s, size_t len) {
    if (len == 0) return;
    buf_ensure(b, len);
    memcpy(b->data + b->len, s, len);
    b->len += len;
}

// 字典条目：动态字符串
typedef struct {
    char *data;
    size_t len;
} lz_entry_t;

// 字典：动态数组
typedef struct {
    lz_entry_t *entries;
    size_t cap;
} lz_dict_t;

static void dict_init(lz_dict_t *d) {
    d->cap = 16;
    d->entries = (lz_entry_t *)calloc(d->cap, sizeof(lz_entry_t));
}

static void dict_ensure(lz_dict_t *d, size_t need) {
    size_t i;
    if (need <= d->cap) return;
    while (need > d->cap) d->cap *= 2;
    d->entries = (lz_entry_t *)realloc(d->entries, d->cap * sizeof(lz_entry_t));
    for (i = d->cap >> 1; i < d->cap; i++) {
        d->entries[i].data = NULL;
        d->entries[i].len = 0;
    }
}

static void dict_set(lz_dict_t *d, size_t idx, const char *s, size_t len) {
    dict_ensure(d, idx + 1);
    if (d->entries[idx].data) free(d->entries[idx].data);
    d->entries[idx].data = (char *)malloc(len + 1);
    memcpy(d->entries[idx].data, s, len);
    d->entries[idx].data[len] = '\0';
    d->entries[idx].len = len;
}

static void dict_free(lz_dict_t *d) {
    size_t i;
    for (i = 0; i < d->cap; i++) {
        if (d->entries[i].data) free(d->entries[i].data);
    }
    free(d->entries);
    d->entries = NULL;
    d->cap = 0;
}

// 读取 n bits 的宏（展开为循环）
// 对应 JS 的 while (power != maxpower) { ... } 循环
#define READ_BITS(bits_var, maxpower)                                        \
    do {                                                                     \
        bits_var = 0;                                                        \
        power = 1;                                                           \
        while (power != (maxpower)) {                                        \
            resb = data_val & data_position;                                 \
            data_position >>= 1;                                             \
            if (data_position == 0) {                                        \
                data_position = resetValue;                                  \
                data_val = (data_index < values_count) ? values[data_index] : 0; \
                data_index++;                                                \
            }                                                                \
            bits_var |= (resb > 0 ? 1 : 0) * power;                          \
            power <<= 1;                                                     \
        }                                                                    \
    } while (0)

char *lz_decompress_from_base64(const char *input, size_t input_len, size_t *out_len) {
    int *values;
    size_t values_count;
    size_t i;
    const int resetValue = 32;
    size_t length;
    int data_val;
    int data_position;
    size_t data_index;
    int enlargeIn, dictSize, numBits;
    int bits, power, resb;
    int next, c;
    char c_utf8[4];
    int c_utf8_len;
    lz_dict_t dict;
    lz_buf_t result;
    lz_entry_t w;
    char *entry_data;
    size_t entry_len;
    int entry_is_new;
    size_t first_len;
    char *new_str;
    size_t new_len;
    char *ret;

    // null → ""（JS: if (input == null) return "";）
    if (input == NULL) {
        ret = (char *)malloc(1);
        ret[0] = '\0';
        if (out_len) *out_len = 0;
        return ret;
    }
    // 空串 → NULL（JS: if (input == "") return null;）
    if (input_len == 0) {
        if (out_len) *out_len = 0;
        return NULL;
    }

    init_base64_reverse();

    // 预解码 base64 字符为索引数组（对应 getBaseValue(keyStrBase64, charAt(index))）
    values = (int *)malloc(input_len * sizeof(int));
    values_count = 0;
    for (i = 0; i < input_len; i++) {
        unsigned char ch = (unsigned char)input[i];
        if (ch >= 128) continue;  // 跳过非 ASCII
        int v = g_base64_reverse[ch];
        if (v < 0) continue;  // 跳过无效字符（如 '=' padding）
        values[values_count++] = v;
    }

    length = input_len;

    // data = {val: getNextValue(0), position: resetValue, index: 1}
    data_val = (values_count > 0) ? values[0] : 0;
    data_position = resetValue;
    data_index = 1;

    dict_init(&dict);
    buf_init(&result);

    // dictionary[0..2] = 0,1,2（JS 数字，LZW 不会访问，保持 NULL）
    enlargeIn = 4;
    dictSize = 4;
    numBits = 3;

    // 读 2 bits → next
    READ_BITS(bits, 4);
    next = bits;

    switch (next) {
        case 0:
            READ_BITS(bits, 256);
            c = bits;
            break;
        case 1:
            READ_BITS(bits, 65536);
            c = bits;
            break;
        case 2:
            // 返回 ""
            free(values);
            dict_free(&dict);
            free(result.data);
            ret = (char *)malloc(1);
            ret[0] = '\0';
            if (out_len) *out_len = 0;
            return ret;
        default:
            // 不应发生
            free(values);
            dict_free(&dict);
            free(result.data);
            if (out_len) *out_len = 0;
            return NULL;
    }

    // dictionary[3] = f(c)
    c_utf8_len = utf16_to_utf8(c, c_utf8);
    dict_set(&dict, 3, c_utf8, c_utf8_len);

    // w = c
    w.data = (char *)malloc(c_utf8_len + 1);
    memcpy(w.data, c_utf8, c_utf8_len);
    w.data[c_utf8_len] = '\0';
    w.len = c_utf8_len;

    // result.push(c)
    buf_append(&result, c_utf8, c_utf8_len);

    // 主循环
    while (1) {
        if (data_index > length) {
            // 返回 ""（JS: if (data.index > length) return "";）
            free(values);
            dict_free(&dict);
            free(w.data);
            free(result.data);
            ret = (char *)malloc(1);
            ret[0] = '\0';
            if (out_len) *out_len = 0;
            return ret;
        }

        // 读 numBits bits → c
        READ_BITS(bits, 1 << numBits);
        c = bits;

        switch (c) {
            case 0:
                READ_BITS(bits, 256);
                {
                    char tmp[4];
                    int n = utf16_to_utf8(bits, tmp);
                    dict_set(&dict, dictSize, tmp, n);
                }
                dictSize++;
                c = dictSize - 1;
                enlargeIn--;
                break;
            case 1:
                READ_BITS(bits, 65536);
                {
                    char tmp[4];
                    int n = utf16_to_utf8(bits, tmp);
                    dict_set(&dict, dictSize, tmp, n);
                }
                dictSize++;
                c = dictSize - 1;
                enlargeIn--;
                break;
            case 2:
                // 返回 result.join('')
                free(values);
                dict_free(&dict);
                free(w.data);
                buf_ensure(&result, 1);
                result.data[result.len] = '\0';
                if (out_len) *out_len = result.len;
                return result.data;
            default:
                // c 是字典索引（>= 3）
                break;
        }

        // enlargeIn == 0 → enlargeIn = 2^numBits; numBits++
        if (enlargeIn == 0) {
            enlargeIn = 1 << numBits;
            numBits++;
        }

        // entry = dictionary[c] 或 (c == dictSize ? w + w[0] : null)
        entry_data = NULL;
        entry_len = 0;
        entry_is_new = 0;

        if (c >= 0 && (size_t)c < dict.cap && dict.entries[c].data != NULL) {
            entry_data = dict.entries[c].data;
            entry_len = dict.entries[c].len;
        } else if (c == dictSize) {
            // entry = w + w.charAt(0)
            first_len = utf8_first_char_len(w.data, w.len);
            entry_len = w.len + first_len;
            entry_data = (char *)malloc(entry_len + 1);
            memcpy(entry_data, w.data, w.len);
            if (first_len > 0) memcpy(entry_data + w.len, w.data, first_len);
            entry_data[entry_len] = '\0';
            entry_is_new = 1;
        } else {
            // return null（非法流）
            free(values);
            dict_free(&dict);
            free(w.data);
            free(result.data);
            if (out_len) *out_len = 0;
            return NULL;
        }

        // result.push(entry)
        buf_append(&result, entry_data, entry_len);

        // dictionary[dictSize++] = w + entry.charAt(0)
        first_len = utf8_first_char_len(entry_data, entry_len);
        new_len = w.len + first_len;
        new_str = (char *)malloc(new_len + 1);
        memcpy(new_str, w.data, w.len);
        if (first_len > 0) memcpy(new_str + w.len, entry_data, first_len);
        new_str[new_len] = '\0';
        dict_set(&dict, dictSize, new_str, new_len);
        free(new_str);
        dictSize++;
        enlargeIn--;

        // w = entry
        free(w.data);
        w.data = (char *)malloc(entry_len + 1);
        memcpy(w.data, entry_data, entry_len);
        w.data[entry_len] = '\0';
        w.len = entry_len;

        if (entry_is_new) free(entry_data);

        if (enlargeIn == 0) {
            enlargeIn = 1 << numBits;
            numBits++;
        }
    }
}

#undef READ_BITS
