#include "memory_tracker.h"
#include <string.h>

// POSIX 线程
#ifndef _WIN32
  #include <pthread.h>
#else
  #include <windows.h>
  typedef CRITICAL_SECTION pthread_mutex_t;
  static int pthread_mutex_init(pthread_mutex_t *m, void *a) {
    (void)a; InitializeCriticalSection(m); return 0;
  }
  static int pthread_mutex_destroy(pthread_mutex_t *m) { DeleteCriticalSection(m); return 0; }
  static int pthread_mutex_lock(pthread_mutex_t *m) { EnterCriticalSection(m); return 0; }
  static int pthread_mutex_unlock(pthread_mutex_t *m) { LeaveCriticalSection(m); return 0; }
#endif

// 全局单例
static memory_stats_t _g_stats;
static pthread_mutex_t _g_mutex;
static int _g_initialized = 0;

void memory_tracker_init(void) {
    if (_g_initialized) return;
    pthread_mutex_init(&_g_mutex, NULL);
    memset(&_g_stats, 0, sizeof(_g_stats));
    _g_initialized = 1;
}

void memory_tracker_record_alloc(size_t bytes) {
    if (!_g_initialized) memory_tracker_init();
    pthread_mutex_lock(&_g_mutex);
    _g_stats.total_allocs++;
    _g_stats.total_bytes_alloc += bytes;
    _g_stats.current_bytes += (int64_t)bytes;
    if ((uint64_t)_g_stats.current_bytes > _g_stats.peak_bytes) {
        _g_stats.peak_bytes = (uint64_t)_g_stats.current_bytes;
    }
    pthread_mutex_unlock(&_g_mutex);
}

void memory_tracker_record_free(size_t bytes) {
    if (!_g_initialized) memory_tracker_init();
    pthread_mutex_lock(&_g_mutex);
    _g_stats.total_frees++;
    _g_stats.total_bytes_free += bytes;
    _g_stats.current_bytes -= (int64_t)bytes;
    pthread_mutex_unlock(&_g_mutex);
}

void memory_tracker_record_failure(void) {
    if (!_g_initialized) memory_tracker_init();
    pthread_mutex_lock(&_g_mutex);
    _g_stats.alloc_failures++;
    pthread_mutex_unlock(&_g_mutex);
}

memory_stats_t memory_tracker_get_stats(void) {
    if (!_g_initialized) memory_tracker_init();
    pthread_mutex_lock(&_g_mutex);
    memory_stats_t snapshot = _g_stats;
    pthread_mutex_unlock(&_g_mutex);
    return snapshot;
}

void memory_tracker_reset_stats(void) {
    if (!_g_initialized) memory_tracker_init();
    pthread_mutex_lock(&_g_mutex);
    memset(&_g_stats, 0, sizeof(_g_stats));
    pthread_mutex_unlock(&_g_mutex);
}