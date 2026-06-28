#ifndef HANDLE_TABLE_H
#define HANDLE_TABLE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 句柄表 — id → pointer 映射
 *
 * 解决跨层裸指针传递的野指针风险：
 * - C 层维护句柄表，上层（Dart/JS）只持有数字 id
 * - 操作时通过 id 查表拿指针，释放时销毁句柄
 * - 线程安全（内部 pthread_mutex）
 *
 * id 规则：
 * - 0  = 无效句柄
 * - >0 = 有效句柄
 * - 高 16 位 = 版本号（防止 ABA 问题）
 * - 低 16 位 = 槽位索引
 */

typedef struct handle_table handle_table_t;

/// 创建句柄表
/// @param capacity 初始容量（会自动扩容）
handle_table_t *handle_table_create(int capacity);

/// 销毁句柄表（不释放已注册的指针，调用方自行管理）
void handle_table_destroy(handle_table_t *ht);

/// 注册指针，返回句柄 id
/// @return >0 成功, 0 失败
uint32_t handle_table_register(handle_table_t *ht, void *ptr);

/// 查找句柄对应的指针
/// @return 指针或 NULL（句柄无效/已注销）
void *handle_table_lookup(handle_table_t *ht, uint32_t id);

/// 注销句柄（不释放指针），返回原指针
/// @return 原指针或 NULL（句柄无效/已注销）
void *handle_table_unregister(handle_table_t *ht, uint32_t id);

/// 当前活跃句柄数
int handle_table_count(handle_table_t *ht);

#ifdef __cplusplus
}
#endif

#endif /* HANDLE_TABLE_H */