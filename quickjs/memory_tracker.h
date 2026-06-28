#ifndef MEMORY_TRACKER_H
#define MEMORY_TRACKER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 全局内存统计 — 线程安全单例
 *
 * 记录 C 层所有 malloc/free 的累计统计：
 * - 分配次数 / 释放次数
 * - 分配字节数 / 释放字节数
 * - 当前持有字节数 / 峰值字节数
 * - 分配失败次数
 *
 * 通过 FFI 接口暴露给 Dart 做线上监控。
 */

typedef struct {
    uint64_t total_allocs;       // 总分配次数
    uint64_t total_frees;        // 总释放次数
    uint64_t total_bytes_alloc;  // 总分配字节数
    uint64_t total_bytes_free;   // 总释放字节数
    int64_t  current_bytes;      // 当前持有字节数（alloc - free）
    uint64_t peak_bytes;         // 峰值字节数
    uint64_t alloc_failures;     // 分配失败次数
} memory_stats_t;

/// 初始化全局内存统计（幂等，可多次调用）
void memory_tracker_init(void);

/// 记录一次分配
void memory_tracker_record_alloc(size_t bytes);

/// 记录一次释放
void memory_tracker_record_free(size_t bytes);

/// 记录一次分配失败
void memory_tracker_record_failure(void);

/// 获取当前统计快照（拷贝）
memory_stats_t memory_tracker_get_stats(void);

/// 重置统计
void memory_tracker_reset_stats(void);

#ifdef __cplusplus
}
#endif

#endif /* MEMORY_TRACKER_H */