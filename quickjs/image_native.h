/**
 * image_native.h — C 原生图片像素操作
 *
 * 提供图片解码 + 条带乱序恢复 + 重新编码的能力。
 * 用于 JMComic 等网站的图片 scramble 恢复。
 *
 * 依赖: stb_image.h（解码）+ stb_image_write.h（编码）
 * 支持: JPEG/PNG/BMP/GIF/PSD/TGA 解码，输出 PNG
 *
 * 算法来源: JMComic-Crawler-python 的 JmImageTool.decode_and_save
 */

#ifndef IMAGE_NATIVE_H
#define IMAGE_NATIVE_H

#include <stdint.h>
#include <stddef.h>

/**
 * 图片条带乱序恢复（scramble restore）
 *
 * 将乱序的图片字节解码为像素，按 num 条带重排，再编码为 PNG 返回。
 *
 * @param image_data   原始图片字节数组（WebP/JPEG/PNG/BMP/GIF）
 * @param image_len    图片字节长度
 * @param num          分割数（0=不需要恢复，直接返回原始字节）
 * @param out_len      输出：返回的字节长度
 *
 * @return malloc 分配的字节缓冲区，调用方负责 free()。失败返回 NULL。
 *         当 num==0 时，返回原始图片的拷贝（PNG 重新编码）。
 *         当图片格式不支持解码时，返回 NULL。
 */
uint8_t *image_scramble_restore(const uint8_t *image_data, size_t image_len,
                                int num, size_t *out_len);

#endif // IMAGE_NATIVE_H
