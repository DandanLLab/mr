/**
 * image_native.c — C 原生图片像素操作实现
 *
 * 使用 stb_image 解码图片 → 条带重排 → stb_image_write 编码为 PNG
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

/* stb_image: 图片解码（JPEG/PNG/BMP/GIF/PSD/TGA/PGM/PPM） */
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

uint8_t *image_scramble_restore(const uint8_t *image_data, size_t image_len,
                                int num, size_t *out_len) {
    if (!image_data || image_len == 0 || !out_len) return NULL;
    *out_len = 0;

    /* 解码图片为 RGB 像素 */
    int w, h, channels;
    /* 强制 3 通道（RGB），简化条带重排逻辑 */
    unsigned char *img = stbi_load_from_memory(image_data, (int)image_len,
                                                &w, &h, &channels, 3);
    if (!img) {
        /* 解码失败（可能是不支持的格式如 WebP） */
        return NULL;
    }

    /* 条带重排（对应 Python decode_and_save） */
    if (num > 0 && h >= num) {
        int over = h % num;
        int move_base = (int)floor((double)h / num);
        /* 分配新像素缓冲区 */
        unsigned char *img_decoded = (unsigned char *)malloc((size_t)w * h * 3);
        if (!img_decoded) {
            stbi_image_free(img);
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

            /* 从源图 crop 条带到目标图 paste */
            /* crop(0, y_src, w, y_src+move) → paste(0, y_dst, w, y_dst+move) */
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

        stbi_image_free(img);
        img = img_decoded;
    }

    /* 编码为 PNG（内存写入） */
    _png_write_ctx wctx = {0};
    wctx.cap = image_len * 2 + 8192; /* 预分配：原始大小 * 2 + 余量 */
    wctx.buf = (uint8_t *)malloc(wctx.cap);
    if (!wctx.buf) {
        stbi_image_free(img);
        return NULL;
    }

    int ok = stbi_write_png_to_func(_png_write_func, &wctx,
                                     w, h, 3, img, w * 3);
    stbi_image_free(img);

    if (!ok || wctx.len == 0) {
        free(wctx.buf);
        return NULL;
    }

    *out_len = wctx.len;
    return wctx.buf;
}
