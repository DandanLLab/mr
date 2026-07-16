/**
 * image_native.c — C 原生图片像素操作实现
 *
 * 使用 stb_image/libwebp 解码图片 → 条带重排 → stb_image_write 编码为 PNG
 *
 * 支持格式: JPEG, PNG, BMP, GIF (stb_image) + WebP (libwebp)
 *
 * 条带重排算法（对应 Python JmImageTool.decode_and_save）:
 *   将图片按高度切成 num 个条带，重新排列顺序。
 *   over = h % num
 *   每个条带高度 move = floor(h / num)
 *   第 0 个条带高度 = move + over
 *   其他条带高度 = move
 *   源条带从底部开始取，目标条带从顶部开始放
 */

#include "image_native.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* stb_image: 图片解码（JPEG/PNG/BMP/GIF） */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_LINEAR
#include "stb_image.h"

/* stb_image_write: 图片编码（PNG/JPEG/BMP/TGA） */
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

/* libwebp: WebP 图片解码 */
#include "webp/decode.h"

/* PNG 写入回调上下文 */
typedef struct {
    uint8_t *buf;
    size_t len;
    size_t cap;
} _png_write_ctx;

static void _png_write_func(void *ctx, void *data, int size) {
    _png_write_ctx *wctx = (_png_write_ctx *)ctx;
    if (size <= 0) return;
    if (wctx->len + (size_t)size > wctx->cap) {
        size_t new_cap = wctx->cap * 2;
        if (new_cap < wctx->len + (size_t)size) new_cap = wctx->len + (size_t)size;
        uint8_t *new_buf = (uint8_t *)realloc(wctx->buf, new_cap);
        if (!new_buf) return; /* OOM，丢弃数据 */
        wctx->buf = new_buf;
        wctx->cap = new_cap;
    }
    memcpy(wctx->buf + wctx->len, data, (size_t)size);
    wctx->len += (size_t)size;
}

/* 检测 WebP 格式: RIFF....WEBP */
static int is_webp(const uint8_t *data, size_t len) {
    return len >= 12 &&
           data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F' &&
           data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P';
}

uint8_t *image_scramble_restore(const uint8_t *image_data, size_t image_len,
                                int num, size_t *out_len) {
    if (!image_data || image_len == 0 || !out_len) return NULL;
    *out_len = 0;

    int w, h, channels;
    unsigned char *img = NULL;
    int use_webp = 0;

    if (is_webp(image_data, image_len)) {
        /* WebP 格式: 使用 libwebp 解码为 RGB */
        img = WebPDecodeRGB(image_data, image_len, &w, &h);
        if (!img) return NULL;
        channels = 3;
        use_webp = 1;
    } else {
        /* 其他格式: 使用 stb_image 解码为 RGB */
        img = stbi_load_from_memory(image_data, (int)image_len,
                                    &w, &h, &channels, 3);
        if (!img) return NULL;
    }

    /* 条带重排（对应 Python decode_and_save） */
    if (num > 0 && h >= num) {
        int over = h % num;
        int move_base = (int)floor((double)h / num);
        unsigned char *img_decoded = (unsigned char *)malloc((size_t)w * h * 3);
        if (!img_decoded) {
            free(img);
            return NULL;
        }

        int i;
        for (i = 0; i < num; i++) {
            int move = move_base;
            int y_src = h - (move * (i + 1)) - over;
            int y_dst = move * i;

            if (i == 0) {
                move += over;
            } else {
                y_dst += over;
            }

            int row;
            for (row = 0; row < move; row++) {
                int src_y = y_src + row;
                int dst_y = y_dst + row;
                if (src_y < 0 || src_y >= h || dst_y < 0 || dst_y >= h) continue;
                memcpy(img_decoded + (size_t)dst_y * w * 3,
                       img + (size_t)src_y * w * 3,
                       (size_t)w * 3);
            }
        }

        free(img);
        img = img_decoded;
        /* img 已指向 malloc 分配的 img_decoded，重置标记使后续走 free 分支 */
        use_webp = 0;
    }

    /* 编码为 PNG（内存写入） */
    _png_write_ctx wctx = {0};
    wctx.cap = image_len * 2 + 8192;
    wctx.buf = (uint8_t *)malloc(wctx.cap);
    if (!wctx.buf) {
        free(img);
        return NULL;
    }

    int ok = stbi_write_png_to_func(_png_write_func, &wctx,
                                     w, h, 3, img, w * 3);
    free(img);

    if (!ok || wctx.len == 0) {
        free(wctx.buf);
        return NULL;
    }

    *out_len = wctx.len;
    return wctx.buf;
}
