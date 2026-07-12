#include "handle_table.h"
#include <stdlib.h>
#include <string.h>

// POSIX 线程
#ifndef _WIN32
  #include <pthread.h>
#else
  #include <windows.h>
  typedef CRITICAL_SECTION pthread_mutex_t;
  typedef struct { pthread_mutex_t m; } pthread_mutexattr_t;
  static int pthread_mutex_init(pthread_mutex_t *m, void *a) {
    (void)a; InitializeCriticalSection(m); return 0;
  }
  static int pthread_mutex_destroy(pthread_mutex_t *m) { DeleteCriticalSection(m); return 0; }
  static int pthread_mutex_lock(pthread_mutex_t *m) { EnterCriticalSection(m); return 0; }
  static int pthread_mutex_unlock(pthread_mutex_t *m) { LeaveCriticalSection(m); return 0; }
#endif

// 句柄 id 编码：高 16 位版本号 | 低 16 位槽位索引
#define HANDLE_INDEX_MASK 0xFFFF
#define HANDLE_VERSION_SHIFT 16
#define HANDLE_MAKE_ID(version, index) (((uint32_t)(version) << HANDLE_VERSION_SHIFT) | ((uint32_t)(index) & HANDLE_INDEX_MASK))

// 槽位
typedef struct {
    void *ptr;           // 注册的指针，NULL 表示空闲
    uint16_t version;    // 版本号（每次注册递增，防止 ABA）
    uint16_t in_use;     // 1=占用, 0=空闲
} _slot_t;

struct handle_table {
    _slot_t *slots;
    int capacity;
    int count;
    int free_list_head;  // 空闲链表头（-1 表示无）
    pthread_mutex_t mutex;
};

// 空闲链表：用 slot 的 ptr 指针存储 next index（int 值强转）
static inline int _free_list_next(_slot_t *slot) {
    return slot->ptr ? (int)(intptr_t)slot->ptr : -1;
}

static inline void _free_list_set_next(_slot_t *slot, int next) {
    slot->ptr = (void *)(intptr_t)next;
}

handle_table_t *handle_table_create(int capacity) {
    if (capacity <= 0) capacity = 64;
    handle_table_t *ht = (handle_table_t *)calloc(1, sizeof(handle_table_t));
    if (!ht) return NULL;

    ht->slots = (_slot_t *)calloc(capacity, sizeof(_slot_t));
    if (!ht->slots) { free(ht); return NULL; }

    ht->capacity = capacity;
    ht->count = 0;
    pthread_mutex_init(&ht->mutex, NULL);

    // 初始化空闲链表：0 → 1 → 2 → ... → capacity-1 → -1
    ht->free_list_head = 0;
    for (int i = 0; i < capacity - 1; i++) {
        _free_list_set_next(&ht->slots[i], i + 1);
    }
    _free_list_set_next(&ht->slots[capacity - 1], -1);

    return ht;
}

void handle_table_destroy(handle_table_t *ht) {
    if (!ht) return;
    pthread_mutex_lock(&ht->mutex);
    free(ht->slots);
    ht->slots = NULL;
    ht->capacity = 0;
    ht->count = 0;
    pthread_mutex_unlock(&ht->mutex);
    pthread_mutex_destroy(&ht->mutex);
    free(ht);
}

static int _ensure_capacity(handle_table_t *ht) {
    if (ht->free_list_head != -1) return 0;

    // 扩容 2 倍
    int new_cap = ht->capacity * 2;
    _slot_t *new_slots = (_slot_t *)realloc(ht->slots, new_cap * sizeof(_slot_t));
    if (!new_slots) return -1;

    // 初始化新槽位的空闲链表
    for (int i = ht->capacity; i < new_cap - 1; i++) {
        memset(&new_slots[i], 0, sizeof(_slot_t));
        _free_list_set_next(&new_slots[i], i + 1);
    }
    memset(&new_slots[new_cap - 1], 0, sizeof(_slot_t));
    _free_list_set_next(&new_slots[new_cap - 1], -1);

    ht->free_list_head = ht->capacity;
    ht->slots = new_slots;
    ht->capacity = new_cap;
    return 0;
}

uint32_t handle_table_register(handle_table_t *ht, void *ptr) {
    if (!ht || !ptr) return 0;

    pthread_mutex_lock(&ht->mutex);

    if (_ensure_capacity(ht) != 0) {
        pthread_mutex_unlock(&ht->mutex);
        return 0;
    }

    int index = ht->free_list_head;
    _slot_t *slot = &ht->slots[index];

    ht->free_list_head = _free_list_next(slot);

    slot->ptr = ptr;
    slot->version++;
    if (slot->version == 0) slot->version = 1; // 跳过 0 版本
    slot->in_use = 1;
    ht->count++;

    uint32_t id = HANDLE_MAKE_ID(slot->version, index);

    pthread_mutex_unlock(&ht->mutex);
    return id;
}

void *handle_table_lookup(handle_table_t *ht, uint32_t id) {
    if (!ht || id == 0) return NULL;

    int index = (int)(id & HANDLE_INDEX_MASK);
    uint16_t version = (uint16_t)(id >> HANDLE_VERSION_SHIFT);

    pthread_mutex_lock(&ht->mutex);

    if (index < 0 || index >= ht->capacity) {
        pthread_mutex_unlock(&ht->mutex);
        return NULL;
    }

    _slot_t *slot = &ht->slots[index];
    void *ptr = NULL;
    if (slot->in_use && slot->version == version) {
        ptr = slot->ptr;
    }

    pthread_mutex_unlock(&ht->mutex);
    return ptr;
}

void *handle_table_unregister(handle_table_t *ht, uint32_t id) {
    if (!ht || id == 0) return NULL;

    int index = (int)(id & HANDLE_INDEX_MASK);
    uint16_t version = (uint16_t)(id >> HANDLE_VERSION_SHIFT);

    pthread_mutex_lock(&ht->mutex);

    if (index < 0 || index >= ht->capacity) {
        pthread_mutex_unlock(&ht->mutex);
        return NULL;
    }

    _slot_t *slot = &ht->slots[index];
    void *ptr = NULL;
    if (slot->in_use && slot->version == version) {
        ptr = slot->ptr;
        slot->ptr = NULL;
        slot->in_use = 0;
        ht->count--;

        // 加入空闲链表头部
        _free_list_set_next(slot, ht->free_list_head);
        ht->free_list_head = index;
    }

    pthread_mutex_unlock(&ht->mutex);
    return ptr;
}

int handle_table_count(handle_table_t *ht) {
    if (!ht) return 0;
    pthread_mutex_lock(&ht->mutex);
    int c = ht->count;
    pthread_mutex_unlock(&ht->mutex);
    return c;
}