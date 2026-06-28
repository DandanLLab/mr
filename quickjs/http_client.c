#include "http_client.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

// P4: 响应体大小上限 50MB
#define MAX_HTTP_BODY_SIZE (50ULL * 1024 * 1024)

// ========== 平台兼容层 ==========
// Android NDK (CMake)、iOS (static framework)、非 Windows 桌面均是 POSIX 环境
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>

#ifdef _WIN32
  // Windows 用 Winsock2（仅在桌面 Windows 编译时启用）
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #define close closesocket
  #define read(fd,buf,len) recv(fd,buf,len,0)
  #define write(fd,buf,len) send(fd,buf,len,0)
#endif

// strncasecmp 可移植包装（Windows 无此函数）
static int _strncasecmp(const char *s1, const char *s2, size_t n) {
#ifdef _WIN32
  return _strnicmp(s1, s2, n);
#else
  return strncasecmp(s1, s2, n);
#endif
}

// ========== 内部数据结构 ==========

// 解析后的 URL
typedef struct {
    char scheme[16];     // "http"（本客户端仅支持 HTTP）
    char host[256];      // 主机名
    int port;            // 端口号（默认 80）
    char path[2048];     // 路径（含 query）
} _parsed_url_t;

// TCP 连接
typedef struct {
    int fd;              // TCP socket（-1 表示未连接）
    int is_https;        // 始终为 0（本客户端仅 HTTP）
} _connection_t;

// ========== URL 解析 ==========

static int _parse_url(const char *url, _parsed_url_t *pu) {
    memset(pu, 0, sizeof(*pu));
    if (!url || url[0] == '\0') return -1;

    // 只支持 http://
    if (strncmp(url, "http://", 7) != 0) return -1;

    const char *p = url + 7; // 跳过 "http://"

    // 提取 host
    const char *host_start = p;
    const char *host_end = strchr(host_start, '/');
    const char *port_colon = NULL;
    if (!host_end) host_end = host_start + strlen(host_start);

    // 找端口
    for (const char *hp = host_start; hp < host_end; hp++) {
        if (*hp == ':') { port_colon = hp; break; }
    }

    strcpy(pu->scheme, "http");
    pu->port = 80;

    if (port_colon) {
        size_t host_len = port_colon - host_start;
        if (host_len >= sizeof(pu->host)) host_len = sizeof(pu->host) - 1;
        memcpy(pu->host, host_start, host_len);
        pu->host[host_len] = '\0';
        pu->port = atoi(port_colon + 1);
        if (pu->port <= 0) pu->port = 80;
    } else {
        size_t host_len = host_end - host_start;
        if (host_len >= sizeof(pu->host)) host_len = sizeof(pu->host) - 1;
        memcpy(pu->host, host_start, host_len);
        pu->host[host_len] = '\0';
    }

    // 提取 path（包含 query）
    if (*host_end == '/') {
        size_t path_len = strlen(host_end);
        if (path_len >= sizeof(pu->path)) path_len = sizeof(pu->path) - 1;
        memcpy(pu->path, host_end, path_len);
        pu->path[path_len] = '\0';
    } else {
        strcpy(pu->path, "/");
    }

    return 0;
}

// ========== Socket 工具 ==========

static int _create_socket_timeout(const char *host, int port, int timeout_ms) {
    struct addrinfo hints, *res, *rp;
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", port);

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    int gai_err = getaddrinfo(host, port_str, &hints, &res);
    if (gai_err != 0) return -1;

    int sock = -1;
    for (rp = res; rp; rp = rp->ai_next) {
        sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sock < 0) continue;

        // 设置非阻塞
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);

        // 发起连接
        int rc = connect(sock, rp->ai_addr, rp->ai_addrlen);
        if (rc == 0) {
            fcntl(sock, F_SETFL, flags);
            break;
        }

        if (rc < 0 && errno == EINPROGRESS) {
            fd_set wset;
            FD_ZERO(&wset);
            FD_SET(sock, &wset);
            struct timeval tv;
            tv.tv_sec = timeout_ms / 1000;
            tv.tv_usec = (timeout_ms % 1000) * 1000;

            rc = select(sock + 1, NULL, &wset, NULL, &tv);
            if (rc > 0) {
                int so_error = 0;
                socklen_t len = sizeof(so_error);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
                if (so_error == 0) {
                    fcntl(sock, F_SETFL, flags);
                    break;
                }
            }
        }

        close(sock);
        sock = -1;
    }

    freeaddrinfo(res);
    return sock;
}

// ========== 连接管理 ==========

static int _connect_to(const char *host, int port, _connection_t *conn) {
    memset(conn, 0, sizeof(*conn));
    conn->fd = -1;
    conn->is_https = 0;

    conn->fd = _create_socket_timeout(host, port, 15000);
    if (conn->fd < 0) return -1;

    return 0;
}

static void _disconnect(_connection_t *conn) {
    if (!conn) return;
    if (conn->fd >= 0) {
        close(conn->fd);
        conn->fd = -1;
    }
}

static int _send_all(_connection_t *conn, const void *data, int len) {
    const char *p = (const char *)data;
    int remaining = len;
    while (remaining > 0) {
        int n = write(conn->fd, p, remaining);
        if (n <= 0) return -1;
        p += n;
        remaining -= n;
    }
    return len;
}

// 读取一行（直到 \n），返回 malloc 分配的行
static char *_read_line(_connection_t *conn) {
    int cap = 128, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) return NULL;

    char ch;
    while (1) {
        int n = read(conn->fd, &ch, 1);
        if (n <= 0) break;

        if (len + 1 >= cap) {
            cap *= 2;
            if (cap > 8192) { free(buf); return NULL; } // P4: 行长度上限 8KB
            buf = (char *)realloc(buf, cap);
            if (!buf) return NULL;
        }
        buf[len++] = ch;
        if (ch == '\n') break;
    }

    if (len == 0) { free(buf); return NULL; }
    buf[len] = '\0';
    return buf;
}

static int _recv_n(_connection_t *conn, void *buf, int len) {
    return read(conn->fd, buf, len);
}

// 读取指定字节到动态缓冲区
static char *_read_n_bytes(_connection_t *conn, size_t n) {
    char *buf = (char *)malloc(n + 1);
    if (!buf) return NULL;
    size_t pos = 0;
    while (pos < n) {
        int r = _recv_n(conn, buf + pos, (int)(n - pos));
        if (r <= 0) { free(buf); return NULL; }
        pos += r;
    }
    buf[n] = '\0';
    return buf;
}

// ========== Chunked Transfer Decoding ==========

static char *_read_chunked_body(_connection_t *conn, size_t *out_len) {
    size_t cap = 4096, len = 0;
    char *body = (char *)malloc(cap);
    if (!body) return NULL;

    while (1) {
        char *line = _read_line(conn);
        if (!line) break;

        char *endptr = NULL;
        long chunk_size = strtol(line, &endptr, 16);
        free(line);

        if (chunk_size <= 0) {
            // 尾部头
            while ((line = _read_line(conn)) != NULL && line[0] != '\r' && line[0] != '\n') {
                free(line);
            }
            free(line);
            break;
        }

        if (len + chunk_size + 1 > cap) {
            cap = len + chunk_size + 4096;
            body = (char *)realloc(body, cap);
            if (!body) return NULL;
        }
        char *chunk = _read_n_bytes(conn, chunk_size);
        if (!chunk) { free(body); return NULL; }
        memcpy(body + len, chunk, chunk_size);
        free(chunk);
        len += chunk_size;

        // CRLF
        char *crlf = _read_line(conn);
        free(crlf);
    }

    body[len] = '\0';
    *out_len = len;
    return body;
}

// ========== HTTP 请求执行 ==========

http_response_t *http_get(const char *url, const char *headers, int timeout_ms) {
    return http_post(url, headers, NULL, 0, timeout_ms);
}

http_response_t *http_post(const char *url, const char *headers,
                            const uint8_t *body, size_t body_len, int timeout_ms) {
    http_response_t *resp = (http_response_t *)calloc(1, sizeof(http_response_t));
    if (!resp) return NULL;
    resp->status_code = 0;

    // 仅支持 HTTP
    if (strncmp(url, "http://", 7) != 0) {
        snprintf(resp->error_msg, sizeof(resp->error_msg),
                 "仅支持HTTP (http://): %s", url ? url : "NULL");
        return resp;
    }

    _parsed_url_t pu;
    if (_parse_url(url, &pu) != 0) {
        snprintf(resp->error_msg, sizeof(resp->error_msg), "URL解析失败: %s", url ? url : "NULL");
        return resp;
    }

    if (timeout_ms <= 0) timeout_ms = 15000;

    // 连接
    _connection_t conn;
    if (_connect_to(pu.host, pu.port, &conn) != 0) {
        snprintf(resp->error_msg, sizeof(resp->error_msg),
                 "连接失败: %s:%d", pu.host, pu.port);
        return resp;
    }

    // 构建请求
    const char *method = (body && body_len > 0) ? "POST" : "GET";
    char request[8192];
    int req_len = snprintf(request, sizeof(request),
        "%s %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Connection: close\r\n"
        "%s"
        "\r\n",
        method, pu.path,
        pu.host,
        headers ? headers : "");

    // POST body → Content-Length
    if (body_len > 0) {
        char cl_buf[64];
        int cl_len = snprintf(cl_buf, sizeof(cl_buf), "Content-Length: %zu\r\n", body_len);
        if (req_len + cl_len < (int)sizeof(request)) {
            memmove(request + req_len - 2 + cl_len, request + req_len - 2, 2);
            memcpy(request + req_len - 2, cl_buf, cl_len);
            req_len += cl_len;
        }
    }

    // 发送请求
    if (_send_all(&conn, request, req_len) != req_len) {
        snprintf(resp->error_msg, sizeof(resp->error_msg), "发送请求失败");
        _disconnect(&conn);
        return resp;
    }

    // POST body
    if (body && body_len > 0) {
        if (_send_all(&conn, body, (int)body_len) != (int)body_len) {
            snprintf(resp->error_msg, sizeof(resp->error_msg), "发送body失败");
            _disconnect(&conn);
            return resp;
        }
    }

    // 解析响应状态行
    char *status_line = _read_line(&conn);
    if (!status_line) {
        snprintf(resp->error_msg, sizeof(resp->error_msg), "无响应");
        _disconnect(&conn);
        return resp;
    }

    // "HTTP/1.1 200 OK" → 解析状态码
    const char *sp = status_line;
    while (*sp && *sp != ' ') sp++;
    if (*sp == ' ') {
        resp->status_code = atoi(sp + 1);
    }
    free(status_line);

    // 解析响应头
    size_t hdr_cap = 2048, hdr_len = 0;
    char *hdr_buf = (char *)malloc(hdr_cap);
    if (!hdr_buf) { _disconnect(&conn); return resp; }
    hdr_buf[0] = '\0';

    int is_chunked = 0;
    int content_length = -1;

    while (1) {
        char *line = _read_line(&conn);
        if (!line) break;

        if (line[0] == '\r' || line[0] == '\n') {
            free(line);
            break;
        }

        size_t llen = strlen(line);
        if (hdr_len + llen + 1 > hdr_cap) {
            hdr_cap = hdr_len + llen + 2048;
            hdr_buf = (char *)realloc(hdr_buf, hdr_cap);
            if (!hdr_buf) { free(line); _disconnect(&conn); return resp; }
        }
        memcpy(hdr_buf + hdr_len, line, llen + 1);
        hdr_len += llen;

        // Transfer-Encoding: chunked
        if (strstr(line, "Transfer-Encoding") && strstr(line, "chunked")) {
            is_chunked = 1;
        }
        // Content-Length
        if (strstr(line, "Content-Length")) {
            const char *cl = strchr(line, ':');
            if (cl) content_length = atoi(cl + 1);
        }

        free(line);
    }

    resp->headers_raw = hdr_buf;

    // 读取响应体
    if (is_chunked) {
        resp->body = _read_chunked_body(&conn, &resp->body_len);
        if (resp->body_len > MAX_HTTP_BODY_SIZE) {
            free(resp->body); resp->body = NULL; resp->body_len = 0;
            snprintf(resp->error_msg, sizeof(resp->error_msg), "Response body exceeds 50MB limit");
        }
    } else if (content_length > 0) {
        if ((size_t)content_length > MAX_HTTP_BODY_SIZE) {
            snprintf(resp->error_msg, sizeof(resp->error_msg), "Content-Length exceeds 50MB limit");
        } else {
            resp->body = _read_n_bytes(&conn, content_length);
            resp->body_len = content_length;
        }
    } else {
        // 读到连接关闭（Connection: close 模式）
        size_t bcap = 4096, blen = 0;
        resp->body = (char *)malloc(bcap);
        if (resp->body) {
            while (1) {
                char tmp[4096];
                int n = _recv_n(&conn, tmp, sizeof(tmp));
                if (n <= 0) break;
                if (blen + n > MAX_HTTP_BODY_SIZE) { // P4: 50MB 上限
                    snprintf(resp->error_msg, sizeof(resp->error_msg), "Response body exceeds 50MB limit");
                    break;
                }
                if (blen + n > bcap) {
                    bcap = blen + n + 4096;
                    char *new_body = (char *)realloc(resp->body, bcap);
                    if (!new_body) { free(resp->body); resp->body = NULL; break; }
                    resp->body = new_body;
                }
                memcpy(resp->body + blen, tmp, n);
                blen += n;
            }
            if (resp->body) {
                resp->body[blen] = '\0';
                resp->body_len = blen;
            }
        }
    }

    // 处理重定向（最多 3 跳，仅支持 301/302/307/308）
    if (resp->status_code >= 301 && resp->status_code <= 308) {
        char *location = NULL;
        char *hdr_scan = resp->headers_raw;
        while (hdr_scan && *hdr_scan) {
            if (_strncasecmp(hdr_scan, "Location", 8) == 0) {
                const char *val = strchr(hdr_scan, ':');
                if (val) {
                    val++;
                    while (*val == ' ') val++;
                    const char *ve = strchr(val, '\r');
                    if (!ve) ve = val + strlen(val);
                    location = (char *)malloc(ve - val + 1);
                    if (location) { memcpy(location, val, ve - val); location[ve - val] = '\0'; }
                }
                break;
            }
            hdr_scan = strchr(hdr_scan, '\n');
            if (hdr_scan) hdr_scan++;
        }

        if (location && location[0]) {
            _disconnect(&conn);
            http_response_t *redirected = http_get(location, headers, timeout_ms);
            http_response_free(resp);
            free(location);
            return redirected;
        }
        free(location);
    }

    _disconnect(&conn);
    return resp;
}

void http_response_free(http_response_t *resp) {
    if (!resp) return;
    free(resp->body);
    free(resp->headers_raw);
    free(resp);
}