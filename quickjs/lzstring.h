#ifndef LZSTRING_H
#define LZSTRING_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// LZString 解压缩（C 实现，替代 QuickJS 纯 JS 版本）
//
// 算法：LZW 解压 + Base64 索引输入
// 对应 JS：LZString.decompressFromBase64(input)
//
// 参数：
//   input     - Base64 编码的压缩字符串（UTF-8，ASCII 字符）
//   input_len - input 的字节长度
//   out_len   - 输出参数，返回结果字符串的字节长度
//
// 返回值：
//   - input 为 NULL：返回空字符串 ""（malloc 分配，1 字节）
//   - input 为空串（len=0）：返回 NULL（对应 JS 的 null）
//   - 解压成功：返回 UTF-8 字符串（malloc 分配，*out_len 为长度，不含 \0）
//   - 解压失败（非法流）：返回 NULL
//
// 内存管理：
//   返回的非 NULL 指针由调用者用 free() 释放
char *lz_decompress_from_base64(const char *input, size_t input_len, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* LZSTRING_H */
