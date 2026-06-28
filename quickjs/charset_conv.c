#include "charset_conv.h"
#include "gbk_table.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// 跨平台 _strcasecmp（Windows _stricmp，其他平台 strcasecmp）
#if defined(_WIN32) || defined(_WIN64)
#define _strcasecmp _stricmp
#else
#define _strcasecmp strcasecmp
#endif

// ========== 二分查找辅助 ==========

// 在 gbk_to_unicode_table 中查找 gbk_code
// 返回 unicode，未找到返回 0
static int _gbk_to_unicode(uint16_t gbk_code) {
    int lo = 0, hi = GBK_TABLE_SIZE - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        uint16_t val = gbk_to_unicode_table[mid][0];
        if (val == gbk_code) return gbk_to_unicode_table[mid][1];
        if (val < gbk_code) lo = mid + 1;
        else hi = mid - 1;
    }
    return 0; // 未找到
}

// 在 unicode_to_gbk_table 中查找 unicode
// 返回 gbk_code，未找到返回 0
static uint16_t _unicode_to_gbk(int unicode) {
    int lo = 0, hi = GBK_TABLE_SIZE - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        int val = unicode_to_gbk_table[mid][0];
        if (val == unicode) return unicode_to_gbk_table[mid][1];
        if (val < unicode) lo = mid + 1;
        else hi = mid - 1;
    }
    return 0; // 未找到
}

// ========== UTF-8 → GBK 转换（逐个字符）==========

typedef struct {
    uint8_t *buf;
    size_t cap;
    size_t len;
} _bytebuf_t;

static void _bytebuf_init(_bytebuf_t *b, size_t initial) {
    b->buf = (uint8_t *)malloc(initial);
    b->cap = initial;
    b->len = 0;
}

static int _bytebuf_append(_bytebuf_t *b, uint8_t byte) {
    if (b->len + 1 >= b->cap) {
        size_t new_cap = b->cap * 2;
        uint8_t *new_buf = (uint8_t *)realloc(b->buf, new_cap);
        if (!new_buf) return -1;
        b->buf = new_buf;
        b->cap = new_cap;
    }
    b->buf[b->len++] = byte;
    return 0;
}

static int _bytebuf_append2(_bytebuf_t *b, uint8_t b1, uint8_t b2) {
    if (b->len + 2 >= b->cap) {
        size_t new_cap = b->cap * 2 + 2;
        uint8_t *new_buf = (uint8_t *)realloc(b->buf, new_cap);
        if (!new_buf) return -1;
        b->buf = new_buf;
        b->cap = new_cap;
    }
    b->buf[b->len++] = b1;
    b->buf[b->len++] = b2;
    return 0;
}

static void _bytebuf_free(_bytebuf_t *b) {
    free(b->buf);
    b->buf = NULL;
    b->cap = 0;
    b->len = 0;
}

// UTF-8 解码一个字符
// 返回 Unicode 码点，-1 表示非法序列
// *seq_len 输出 UTF-8 字节数
static int _utf8_decode_char(const uint8_t *s, size_t max_len, int *seq_len) {
    if (max_len == 0) { *seq_len = 0; return -1; }
    uint8_t b0 = s[0];
    if (b0 <= 0x7F) {
        *seq_len = 1;
        return b0;
    } else if (b0 >= 0xC2 && b0 <= 0xDF) {
        if (max_len < 2) { *seq_len = 0; return -1; }
        uint8_t b1 = s[1];
        if ((b1 & 0xC0) != 0x80) { *seq_len = 1; return -1; }
        *seq_len = 2;
        return ((int)(b0 & 0x1F) << 6) | (b1 & 0x3F);
    } else if (b0 >= 0xE0 && b0 <= 0xEF) {
        if (max_len < 3) { *seq_len = 0; return -1; }
        uint8_t b1 = s[1], b2 = s[2];
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) { *seq_len = 1; return -1; }
        if (b0 == 0xE0 && b1 < 0xA0) { *seq_len = 1; return -1; }
        if (b0 == 0xED && b1 > 0x9F) { *seq_len = 1; return -1; }
        *seq_len = 3;
        return ((int)(b0 & 0x0F) << 12) | ((int)(b1 & 0x3F) << 6) | (b2 & 0x3F);
    } else if (b0 >= 0xF0 && b0 <= 0xF4) {
        if (max_len < 4) { *seq_len = 0; return -1; }
        uint8_t b1 = s[1], b2 = s[2], b3 = s[3];
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) { *seq_len = 1; return -1; }
        if (b0 == 0xF0 && b1 < 0x90) { *seq_len = 1; return -1; }
        if (b0 == 0xF4 && b1 > 0x8F) { *seq_len = 1; return -1; }
        *seq_len = 4;
        return ((int)(b0 & 0x07) << 18) | ((int)(b1 & 0x3F) << 12) | ((int)(b2 & 0x3F) << 6) | (b3 & 0x3F);
    }
    *seq_len = 1;
    return -1;
}

// UTF-8 编码一个 Unicode 码点
// 写入 buf（至少 4 字节），返回写入的字节数
static int _utf8_encode_char(uint8_t *buf, int cp) {
    if (cp <= 0x7F) {
        buf[0] = (uint8_t)cp;
        return 1;
    } else if (cp <= 0x7FF) {
        buf[0] = (uint8_t)(0xC0 | (cp >> 6));
        buf[1] = (uint8_t)(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp <= 0xFFFF) {
        buf[0] = (uint8_t)(0xE0 | (cp >> 12));
        buf[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (uint8_t)(0x80 | (cp & 0x3F));
        return 3;
    } else if (cp <= 0x10FFFF) {
        buf[0] = (uint8_t)(0xF0 | (cp >> 18));
        buf[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = (uint8_t)(0x80 | (cp & 0x3F));
        return 4;
    }
    buf[0] = 0xEF; buf[1] = 0xBF; buf[2] = 0xBD; // U+FFFD
    return 3;
}

// UTF-8 → GBK 字节序列
// 返回 malloc 分配的 GBK 字节序列，*out_len 输出长度
static uint8_t *_utf8_to_gbk(const uint8_t *utf8, size_t utf8_len, size_t *out_len) {
    _bytebuf_t buf;
    _bytebuf_init(&buf, utf8_len + 4);

    size_t i = 0;
    while (i < utf8_len) {
        int seq_len;
        int cp = _utf8_decode_char(utf8 + i, utf8_len - i, &seq_len);
        if (cp < 0) {
            // 非法 UTF-8：插入 U+FFFD（GBK 中为 0xA1 0xA4 = · 中间点）
            _bytebuf_append2(&buf, 0xA1, 0xA4);
            i += (seq_len > 0 ? seq_len : 1);
            continue;
        }
        i += seq_len;

        if (cp <= 0x7F) {
            // ASCII 直接映射
            _bytebuf_append(&buf, (uint8_t)cp);
        } else {
            uint16_t gbk = _unicode_to_gbk(cp);
            if (gbk != 0) {
                _bytebuf_append(&buf, (uint8_t)(gbk >> 8));
                _bytebuf_append(&buf, (uint8_t)(gbk & 0xFF));
            } else {
                // 不在 GBK 中的字符 → U+FFFD
                _bytebuf_append2(&buf, 0xA1, 0xA4);
            }
        }
    }

    *out_len = buf.len;
    return buf.buf; // 所有权转移
}

// GBK 字节序列 → UTF-8
// 返回 malloc 分配的 UTF-8 字符串
static uint8_t *_gbk_to_utf8(const uint8_t *gbk, size_t gbk_len, size_t *out_len) {
    _bytebuf_t buf;
    // UTF-8 最大是 GBK 的 1.5 倍（3 字节 UTF-8 对应 2 字节 GBK）
    _bytebuf_init(&buf, gbk_len * 3 / 2 + 4);
    uint8_t utf8_tmp[4];

    size_t i = 0;
    while (i < gbk_len) {
        uint8_t b0 = gbk[i];
        if (b0 <= 0x7F) {
            // 单字节 ASCII
            _bytebuf_append(&buf, b0);
            i++;
        } else if (b0 >= 0x81 && b0 <= 0xFE && i + 1 < gbk_len) {
            // 双字节 GBK
            uint8_t b1 = gbk[i + 1];
            if (b1 >= 0x40 && b1 <= 0xFE && b1 != 0x7F) {
                uint16_t gbk_code = ((uint16_t)b0 << 8) | b1;
                int unicode = _gbk_to_unicode(gbk_code);
                if (unicode != 0) {
                    int n = _utf8_encode_char(utf8_tmp, unicode);
                    for (int j = 0; j < n; j++) _bytebuf_append(&buf, utf8_tmp[j]);
                } else {
                    // GBK 代码点无效 → U+FFFD
                    _bytebuf_append(&buf, 0xEF);
                    _bytebuf_append(&buf, 0xBF);
                    _bytebuf_append(&buf, 0xBD);
                }
            } else {
                // 非 GBK 双字节尾 → U+FFFD
                _bytebuf_append(&buf, 0xEF);
                _bytebuf_append(&buf, 0xBF);
                _bytebuf_append(&buf, 0xBD);
            }
            i += 2;
        } else if (b0 >= 0x81 && b0 <= 0xFE && i + 1 >= gbk_len) {
            // 不完整的双字节
            _bytebuf_append(&buf, 0xEF);
            _bytebuf_append(&buf, 0xBF);
            _bytebuf_append(&buf, 0xBD);
            i++;
        } else {
            // 其他单字节 → U+FFFD
            _bytebuf_append(&buf, 0xEF);
            _bytebuf_append(&buf, 0xBF);
            _bytebuf_append(&buf, 0xBD);
            i++;
        }
    }

    // NULL 终止
    _bytebuf_append(&buf, 0);
    *out_len = buf.len > 0 ? buf.len - 1 : 0;
    return buf.buf;
}

// ========== URL percent-encoding ==========

static int _is_unreserved(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '_' ||
           c == '.' || c == '~';
}

// 字节流 → percent-encoded ASCII 字符串
static char *_percent_encode(const uint8_t *data, size_t data_len, size_t *out_len) {
    if (!data || data_len == 0) {
        char *r = (char *)malloc(1);
        if (r) r[0] = '\0';
        if (out_len) *out_len = 0;
        return r;
    }
    size_t cap = data_len * 3 + 1;
    char *result = (char *)malloc(cap);
    if (!result) return NULL;
    size_t pos = 0;
    for (size_t i = 0; i < data_len; i++) {
        unsigned char c = (unsigned char)data[i];
        if (_is_unreserved((char)c)) {
            if (pos + 1 >= cap) { cap = cap * 2 + 1; result = (char *)realloc(result, cap); if (!result) return NULL; }
            result[pos++] = (char)c;
        } else {
            if (pos + 3 >= cap) { cap = cap * 2 + 3; result = (char *)realloc(result, cap); if (!result) return NULL; }
            int n = snprintf(result + pos, 4, "%%%02X", c);
            if (n > 0) pos += n;
        }
    }
    result[pos] = '\0';
    if (out_len) *out_len = pos;
    return result;
}

// ========== 公开 API ==========

char *charset_url_encode(const char *str, const char *charset, size_t *out_len) {
    if (!str || !charset) return NULL;
    if (str[0] == '\0') {
        char *r = (char *)malloc(1);
        if (r) r[0] = '\0';
        if (out_len) *out_len = 0;
        return r;
    }

    size_t src_len = strlen(str);

    // UTF-8：直接 percent-encode UTF-8 字节
    if (_strcasecmp(charset, "UTF-8") == 0 || _strcasecmp(charset, "UTF8") == 0) {
        return _percent_encode((const uint8_t *)str, src_len, out_len);
    }

    // GBK/GB2312/GB18030：先转码再 percent-encode
    if (strncasecmp(charset, "GB", 2) == 0) {
        size_t gbk_len = 0;
        uint8_t *gbk = _utf8_to_gbk((const uint8_t *)str, src_len, &gbk_len);
        if (gbk) {
            char *result = _percent_encode(gbk, gbk_len, out_len);
            free(gbk);
            return result;
        }
        // 转码失败回退 UTF-8
    }

    // 不支持/不可识别的编码 → UTF-8 percent-encode
    return _percent_encode((const uint8_t *)str, src_len, out_len);
}

char *charset_decode_to_utf8(const uint8_t *data, size_t data_len,
                             const char *charset, size_t *out_len) {
    if (!data || data_len == 0 || !charset) {
        if (out_len) *out_len = 0;
        char *r = (char *)malloc(1);
        if (r) r[0] = '\0';
        return r;
    }

    if (_strcasecmp(charset, "UTF-8") == 0 || _strcasecmp(charset, "UTF8") == 0) {
        char *r = (char *)malloc(data_len + 1);
        if (!r) return NULL;
        memcpy(r, data, data_len);
        r[data_len] = '\0';
        if (out_len) *out_len = data_len;
        return r;
    }

    if (strncasecmp(charset, "GB", 2) == 0) {
        return (char *)_gbk_to_utf8(data, data_len, out_len);
    }

    // 未知编码 → U+FFFD 填充
    size_t out_cap = data_len * 3 + 4;
    char *r = (char *)malloc(out_cap);
    if (!r) return NULL;
    size_t pos = 0;
    for (size_t i = 0; i < data_len; i++) {
        uint8_t b = data[i];
        if (b <= 0x7F) {
            r[pos++] = (char)b;
        } else {
            if (pos + 3 >= out_cap) { out_cap = out_cap * 2 + 3; r = (char *)realloc(r, out_cap); if (!r) return NULL; }
            r[pos++] = (char)0xEF;
            r[pos++] = (char)0xBF;
            r[pos++] = (char)0xBD;
        }
    }
    r[pos] = '\0';
    if (out_len) *out_len = pos;
    return r;
}

// 大小写不敏感比较辅助
static int _istreq(const char *a, const char *b) {
    while (*a && *b) {
        if ((*a & ~0x20) != (*b & ~0x20)) return 0;
        a++; b++;
    }
    return *a == *b;
}

char *charset_detect_from_html(const char *html, size_t *out_len) {
    if (!html || html[0] == '\0') return NULL;
    size_t html_len = strlen(html);
    size_t search_len = html_len < 4096 ? html_len : 4096;
    const char *end = html + search_len;

    // 1. HTML5: <meta charset="xxx"> / <meta charset='xxx'> / <meta charset=xxx>
    for (const char *p = html; p < end - 12; ) {
        // 查找 <meta
        const char *meta = p;
        while (meta < end - 12) {
            if ((meta[0] == '<' || meta[0] == '<') &&
                (meta[1] == 'm' || meta[1] == 'M') &&
                (meta[2] == 'e' || meta[2] == 'E') &&
                (meta[3] == 't' || meta[3] == 'T') &&
                (meta[4] == 'a' || meta[4] == 'A')) break;
            meta++;
        }
        if (meta >= end - 12) break;

        const char *tag_end = strchr(meta, '>');
        if (!tag_end || tag_end > end) break;

        // 在 tag 内搜索 charset=
        const char *cs = meta;
        while (cs < tag_end - 7) {
            if ((cs[0] == 'c' || cs[0] == 'C') &&
                (cs[1] == 'h' || cs[1] == 'H') &&
                (cs[2] == 'a' || cs[2] == 'A') &&
                (cs[3] == 'r' || cs[3] == 'R') &&
                (cs[4] == 's' || cs[4] == 'S') &&
                (cs[5] == 'e' || cs[5] == 'E') &&
                (cs[6] == 't' || cs[6] == 'T')) break;
            cs++;
        }
        if (cs >= tag_end - 7) { p = tag_end + 1; continue; }

        cs += 7;
        while (cs < tag_end && (*cs == ' ' || *cs == '\t')) cs++;
        if (cs >= tag_end || *cs != '=') { p = tag_end + 1; continue; }
        cs++;
        while (cs < tag_end && (*cs == ' ' || *cs == '\t')) cs++;
        if (cs >= tag_end) { p = tag_end + 1; continue; }

        const char *val_start;
        const char *val_end = NULL;
        if (*cs == '"' || *cs == '\'') {
            char quote = *cs;
            val_start = cs + 1;
            val_end = strchr(val_start, quote);
        } else {
            val_start = cs;
            val_end = val_start;
            while (val_end < tag_end && *val_end != ' ' &&
                   *val_end != '\t' && *val_end != '>') val_end++;
        }
        if (val_end && val_end > val_start) {
            size_t vl = val_end - val_start;
            char *r = (char *)malloc(vl + 1);
            if (!r) return NULL;
            memcpy(r, val_start, vl);
            r[vl] = '\0';
            if (out_len) *out_len = vl;
            return r;
        }
        p = tag_end + 1;
    }

    // 2. HTML4: 搜索 Content-Type
    const char *ct = NULL;
    for (const char *p = html; p < end - 12; p++) {
        if ((p[0] == 'C' || p[0] == 'c') &&
            (p[1] == 'o' || p[1] == 'O') &&
            (p[2] == 'n' || p[2] == 'N') &&
            (p[3] == 't' || p[3] == 'T') &&
            (p[4] == 'e' || p[4] == 'E') &&
            (p[5] == 'n' || p[5] == 'N') &&
            (p[6] == 't' || p[6] == 'T') &&
            p[7] == '-' &&
            (p[8] == 'T' || p[8] == 't') &&
            (p[9] == 'y' || p[9] == 'Y') &&
            (p[10] == 'p' || p[10] == 'P') &&
            (p[11] == 'e' || p[11] == 'E')) {
            ct = p;
            break;
        }
    }
    if (ct) {
        const char *search_end = ct + 200 < end ? ct + 200 : end;
        const char *scan = ct;
        while (scan < search_end - 7) {
            if ((scan[0] == 'c' || scan[0] == 'C') &&
                (scan[1] == 'h' || scan[1] == 'H') &&
                (scan[2] == 'a' || scan[2] == 'A') &&
                (scan[3] == 'r' || scan[3] == 'R') &&
                (scan[4] == 's' || scan[4] == 'S') &&
                (scan[5] == 'e' || scan[5] == 'E') &&
                (scan[6] == 't' || scan[6] == 'T')) break;
            scan++;
        }
        if (scan < search_end - 7) {
            scan += 7;
            while (scan < search_end && (*scan == ' ' || *scan == '\t')) scan++;
            if (scan < search_end && *scan == '=') {
                scan++;
                while (scan < search_end && (*scan == ' ' || *scan == '\t')) scan++;
                const char *vs = scan;
                const char *ve = NULL;
                if (*scan == '"' || *scan == '\'') {
                    char q = *scan; vs++; ve = strchr(vs, q);
                } else {
                    ve = vs;
                    while (ve < search_end && *ve != ' ' && *ve != '\t' && *ve != '>' && *ve != '"') ve++;
                }
                if (ve && ve > vs) {
                    size_t vl = ve - vs;
                    char *r = (char *)malloc(vl + 1);
                    if (!r) return NULL;
                    memcpy(r, vs, vl);
                    r[vl] = '\0';
                    if (out_len) *out_len = vl;
                    return r;
                }
            }
        }
    }

    return NULL;
}

char *charset_detect_from_content_type(const char *content_type, size_t *out_len) {
    if (!content_type || content_type[0] == '\0') return NULL;

    const char *p = content_type;
    while (*p) {
        if ((p[0] == 'c' || p[0] == 'C') &&
            (p[1] == 'h' || p[1] == 'H') &&
            (p[2] == 'a' || p[2] == 'A') &&
            (p[3] == 'r' || p[3] == 'R') &&
            (p[4] == 's' || p[4] == 'S') &&
            (p[5] == 'e' || p[5] == 'E') &&
            (p[6] == 't' || p[6] == 'T')) {
            p += 7;
            while (*p && (*p == ' ' || *p == '\t')) p++;
            if (*p == '=') {
                p++;
                while (*p && (*p == ' ' || *p == '\t')) p++;
                const char *vs = p;
                const char *ve = NULL;
                if (*p == '"' || *p == '\'') {
                    char q = *p; vs++; ve = strchr(vs, q);
                } else {
                    ve = vs;
                    while (*ve && *ve != ' ' && *ve != ';' && *ve != '\t' && *ve != '\r' && *ve != '\n') ve++;
                }
                if (ve && ve > vs) {
                    size_t vl = ve - vs;
                    char *r = (char *)malloc(vl + 1);
                    if (!r) return NULL;
                    memcpy(r, vs, vl);
                    r[vl] = '\0';
                    if (out_len) *out_len = vl;
                    return r;
                }
            }
            break;
        }
        p++;
    }
    return NULL;
}

void charset_free_string(char *s) {
    free(s);
}