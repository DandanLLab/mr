#ifndef CHARSET_CONV_H
#define CHARSET_CONV_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * charset_conv — 自包含字符集转换（零外部依赖）
 *
 * 基于嵌入式 GBK↔Unicode 映射表（gbk_table.h），
 * 通过二分查找实现 O(log N) 双向转换。
 *
 * Android NDK / iOS lib 通用，无任何系统库依赖。
 */

/**
 * URL-encode 字符串，使用指定字符集
 *
 * UTF-8 输入 → [charset] 编码字节序列 → percent-encoding
 *
 * @param str       UTF-8 输入字符串
 * @param charset   字符集名称："GBK"/"GB2312"/"UTF-8" 等
 * @param out_len   输出长度，可为 NULL
 * @return          malloc 分配的 percent-encoded 字符串，调用方 free()
 *                  失败返回 NULL
 */
char *charset_url_encode(const char *str, const char *charset, size_t *out_len);

/**
 * 将原始字节按字符集解码为 UTF-8 字符串
 *
 * 支持 GBK/GB2312/GB18030（映射表）和 UTF-8/Latin-1（原生）
 *
 * @param data      原始字节
 * @param data_len  数据长度
 * @param charset   字符集名称
 * @param out_len   输出长度，可为 NULL
 * @return          malloc 分配的 UTF-8 字符串，调用方 free()
 *                  失败返回 NULL
 */
char *charset_decode_to_utf8(const uint8_t *data, size_t data_len,
                             const char *charset, size_t *out_len);

/**
 * 从 HTML 文档中检测 charset
 *
 * 检测顺序：
 * 1. <meta charset="xxx">（HTML5）
 * 2. <meta http-equiv="Content-Type" content="...charset=xxx">（HTML4/XHTML）
 *
 * 仅在 HTML 前 4096 字节内搜索（性能考虑）
 *
 * @param html      UTF-8 编码的 HTML
 * @param out_len   输出长度，可为 NULL
 * @return          malloc 分配的 charset 名（如 "GBK"），未找到返回 NULL
 */
char *charset_detect_from_html(const char *html, size_t *out_len);

/**
 * 从 Content-Type HTTP 头中提取 charset
 *
 * 解析 "text/html; charset=GBK" 中的 charset 值
 *
 * @param content_type  Content-Type 头值
 * @param out_len       输出长度，可为 NULL
 * @return              malloc 分配的 charset 名，未找到返回 NULL
 */
char *charset_detect_from_content_type(const char *content_type, size_t *out_len);

/**
 * 释放 charset_conv 函数返回的字符串
 */
void charset_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif /* CHARSET_CONV_H */