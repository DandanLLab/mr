#ifndef HTTP_CLIENT_H
#define HTTP_CLIENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * C 原生 HTTP 客户端
 *
 * 纯 C 实现 HTTP/1.1 GET/POST 请求。
 * 仅支持 HTTP（http://），HTTPS 请使用平台级 SDK（Dio/OkHttp）。
 *
 * 所有输出字符串用 free() 释放。
 */

/// HTTP 响应
typedef struct {
    int status_code;        // HTTP 状态码（200, 404 等），0 表示连接/超时失败
    char *body;             // malloc 分配的响应体（UTF-8），失败时为 NULL
    size_t body_len;        // 响应体长度
    char *headers_raw;      // malloc 分配的原始响应头，失败时为 NULL
    int is_https;           // 始终为 0（本客户端仅 HTTP）
    char error_msg[256];    // 错误消息（失败时填充）
} http_response_t;

/**
 * HTTP GET 请求
 *
 * @param url         完整 URL（http:// 开头）
 * @param headers     headers 字符串，格式 "Key1: Value1\r\nKey2: Value2\r\n"，NULL 表示无额外头
 * @param timeout_ms  超时毫秒，0 表示 15000ms
 * @return            分配的 http_response_t，调用方用 http_response_free() 释放
 */
http_response_t *http_get(const char *url, const char *headers, int timeout_ms);

/**
 * HTTP POST 请求
 *
 * @param url         完整 URL（http:// 开头）
 * @param headers     headers 字符串
 * @param body        POST body
 * @param body_len    body 长度
 * @param timeout_ms  超时毫秒
 * @return            分配的 http_response_t，调用方用 http_response_free() 释放
 */
http_response_t *http_post(const char *url, const char *headers,
                            const uint8_t *body, size_t body_len, int timeout_ms);

/**
 * 释放 http_response_t
 */
void http_response_free(http_response_t *resp);

#ifdef __cplusplus
}
#endif

#endif /* HTTP_CLIENT_H */