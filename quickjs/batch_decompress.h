#ifndef BATCH_DECOMPRESS_H
#define BATCH_DECOMPRESS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 获取 CPU 逻辑核心数
int get_cpu_count(void);

// 批量 LZString 解压（多线程分片并发）
//
// 输入：count 个 base64 字符串（inputs[i] 长度为 input_lens[i]）
// 输出：count 个解压结果
//   - *out_results 指向 char* 数组，每个元素由 malloc 分配，调用者负责 free
//   - *out_lens 指向 size_t 数组，记录每个结果长度，调用者负责 free
//
// 线程模型：根据 CPU 核心数切分为 N 个连续分片，每片独立线程并发处理
// 返回：0 成功，非 0 失败（内存不足等）
int lz_decompress_batch(const char **inputs, const size_t *input_lens, size_t count,
                        char ***out_results, size_t **out_lens);

// 批量 AES-CBC 解密 + LZString 解压（多线程分片并发，原子组合）
//
// 对应 3A 书源 content() 的解密链路，批量版本：
//   每个 input 经 atob → IV(前16)|cipher → AES-CBC-PKCS7 decrypt → UTF-8 → LZString decompress
//
// 输入：
//   b64_inputs / b64_lens - count 个 base64 密文字符串
//   key_utf8 / key_len    - AES 密钥（16/24/32 字节）
// 输出：同 lz_decompress_batch
//
// 返回：0 成功，非 0 失败
int aes_decrypt_lz_batch(const char **b64_inputs, const size_t *b64_lens, size_t count,
                         const char *key_utf8, size_t key_len,
                         char ***out_results, size_t **out_lens);

#ifdef __cplusplus
}
#endif

#endif /* BATCH_DECOMPRESS_H */
