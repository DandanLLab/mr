# MR — 多媒体阅读器

> 一款基于 Flutter 的跨平台多媒体阅读器，完全兼容[阅读（Legado）](https://github.com/gedoor/legado)书源规则体系，支持小说、漫画、音频、视频与本地书。

---

## 特性

### Legado 规则兼容

- **完整语法支持**：CSS/JSoup 选择器、JSONPath、XPath、JavaScript、正则替换、模板规则
- **JS 引擎**：QuickJS（C 原生 FFI，ES2020）
- **加密兼容**：`CryptoJS` API + `java.*` 桥接加密方法，底层统一走 C 原生实现（AES/MD5/SHA/HMAC）
- **TypeScript 编译**：`@ts:` 前缀自动编译为 JS 后由 QuickJS 执行（本应用独有）
- **书源管理**：兼容 Legado JSON 导入/导出，支持书源调试 + 执行追踪树

### 阅读器矩阵

| 类型 | 功能 |
|------|------|
| 小说阅读器 | 仿真翻页 / 滚动 / 滑动 / TTS 朗读 / 自定义主题 |
| 漫画阅读器 | 竖向滚动 / 左右翻页 / 双页模式 |
| 音频播放器 | 后台播放 / 定时停止 / 播放列表 |
| 视频播放器 | 内置播放页 / 横竖屏切换 |

### 跨平台

- Android / iOS / Web / Windows / Linux / macOS 同一代码库
- Web 平台自动启动 CORS 代理（`ProxyService.instance.start()`）
- 书源无需针对平台修改

---

## 技术架构

### 分层概览

| 层 | 技术 | 路径 |
|----|------|------|
| UI 框架 | Flutter 3.x | `lib/` |
| 状态管理 | Provider（6 个 Provider） | `lib/providers/` |
| 本地存储 | Hive | `lib/services/storage_service.dart` |
| HTTP 客户端 | Dio + OkHttp（Android 原生通道） | `lib/services/source_engine/` |
| JS 引擎 | QuickJS（C FFI，ES2020） | `lib/services/native/` |
| 规则引擎 | 自定义解析器 | `lib/services/source_engine/` |
| HTML 解析 | `package:html`（CSS 选择器） | 规则引擎内部 |
| HTML 解析（C） | lexbor（C99 HTML 解析器） | `quickjs/lexbor/` |
| 加密 | C 原生实现 | `quickjs/crypto/` |
| 路由 | 自定义 `AppPageRoute`（250ms 淡入 + 上滑过渡） | `lib/routes/app_routes.dart` |

### 项目结构

```
mr/
├── lib/                          # Dart 源码
│   ├── main.dart                 # 入口：初始化 Hive/Storage/JsEngine/CoverConfig
│   ├── models/                   # 数据模型
│   │   ├── book.dart / book_source.dart / chapter.dart
│   │   └── rules/                # 六类规则模型（search/explore/bookInfo/toc/content/review）
│   ├── pages/                    # 13 个页面子目录（含 settings、web 等）
│   │   ├── bookshelf/            # 书架
│   │   ├── reader/               # 小说和漫画阅读器
│   │   ├── player/               # 音频和视频播放器
│   │   ├── detail/               # 书籍详情 + 章节列表
│   │   ├── search/               # 搜索
│   │   ├── discovery/explore/    # 发现 / 发现详情
│   │   ├── miniprogram/          # 小程序
│   │   ├── web/                  # 内置浏览器
│   │   ├── debug/                # 书源调试 + 加密性能统计 + JS 内存监控面板
│   │   ├── profile/              # 设置中心（12 个子页）
│   │   ├── settings/             # 主题 / AI 设置
│   │   └── main/                 # 主框架页
│   ├── providers/                # 6 个状态 Provider
│   ├── routes/app_routes.dart    # 集中路由表
│   ├── services/
│   │   ├── source_engine/        # 规则引擎核心
│   │   │   ├── analyze_rule.dart       # 规则解析器（CSS/JSON/XPath/JS/正则/模板）
│   │   │   ├── analyze_url.dart        # URL 解析（含 Legado 选项）
│   │   │   ├── web_book.dart           # 网络书籍抓取引擎
│   │   │   ├── legado_json_path.dart   # JSONPath 实现
│   │   │   ├── legado_xpath.dart       # XPath 实现
│   │   │   ├── dan_file.dart           # .dan 打包文件解析
│   │   │   ├── charset_utils.dart      # 字符集转换
│   │   │   ├── proxy_service.dart      # CORS 代理
│   │   │   └── web_proxy*.dart         # Web 请求代理（平台分支）
│   │   ├── native/              # 原生桥接层
│   │   │   ├── js_engine.dart          # JsEngine 主入口 + 引擎调度（QuickJS 单引擎）
│   │   │   ├── quickjs_runtime.dart    # QuickJS FFI 绑定（Android/iOS/桌面）
│   │   │   ├── quickjs_runtime_stub.dart # QuickJS Web 平台 stub
│   │   │   ├── shared_js_scope.dart    # 跨引擎共享作用域
│   │   │   ├── js_advanced_service.dart # 高级 JS（WebView 注入）
│   │   │   └── platform_channel.dart   # Android/iOS 原生通道
│   │   ├── local_book/          # 本地书解析（EPUB / TXT）
│   │   ├── storage_service.dart
│   │   ├── book_data_provider.dart
│   │   ├── book_source_import_service.dart
│   │   ├── book_source_locator.dart
│   │   ├── chapter_cache_service.dart
│   │   ├── chapter_prefetch_service.dart
│   │   ├── source_debug_service.dart
│   │   ├── reader_bookmark_service.dart
│   │   ├── reader_tts_manager.dart
│   │   ├── read_record_service.dart
│   │   ├── cookie_service.dart
│   │   ├── cover_config_service.dart
│   │   ├── share_service.dart
│   │   └── app_logger.dart
│   ├── themes/                  # 主题配置
│   ├── utils/                   # 设计令牌 / 常量
│   └── widgets/                 # 公共组件 + reader 子组件
├── quickjs/                     # QuickJS C 源码（Android 编译为 .so，iOS 编译为 .a）
│   ├── quickjs.c / quickjs.h    # QuickJS 引擎核心
│   ├── quickjs_bridge.c/h      # C 桥接层 — 所有 FFI 导出符号
│   ├── handle_table.c/h        # P1: 句柄表（id→指针映射，ABA 防护）
│   ├── memory_tracker.c/h      # P1: 全局内存追踪器
│   ├── quickjs-c-atomics.h     # P1: 跨编译器 C11 原子操作兼容层
│   ├── crypto/                  # 加密实现
│   │   ├── md5.c/h / sha1.c/h / sha256.c/h
│   │   ├── aes.c/h / hmac_sha256.c/h
│   ├── html_native.c/h         # HTML 解析 C 原生加速
│   ├── http_client.c/h         # C HTTP 客户端（curl wrapper）
│   ├── charset_conv.c/h        # 字符集转换
│   ├── lzstring.c              # LZ 字符串压缩
│   ├── batch_decompress.c/h    # 批量解压
│   └── lexbor/                 # lexbor HTML 解析器（C99）
├── android/app/src/main/cpp/   # Android CMakeLists + 符号映射
│   ├── CMakeLists.txt          # C 源码编译配置（体积优化 + LTO + gc-sections）
│   └── quickjs_bridge.map      # 版本脚本（仅导出 quickjs_bridge_*）
├── ios/                        # iOS Runner + Podfile + NativePlugin.swift
├── assets/templates/           # 书源模板 + 帮助文档
└── tools/cors-proxy.js         # Web CORS 代理脚本
```

### 架构硬化（P1–P5）

| 优先级 | 模块 | 功能 | 文件 |
|--------|------|------|------|
| P1 | 内存所有权 | 句柄表（id→指针）+ 版本号 ABA 防护 + 自由链复用 + 自动扩容 | `handle_table.c/h` |
| P1 | 内存追踪 | 全局线程安全 malloc/free 计数 + 峰值 + 失败计数 | `memory_tracker.c/h` |
| P1 | 原子操作兼容 | GCC <4.9 回退到 __sync 内建函数 | `quickjs-c-atomics.h` |
| P2 | 超时熔断 | `JS_SetInterruptHandler` + 5s 默认超时 + OC 熔断标记 | `quickjs_bridge.c` |
| P2 | GC 阈值 | `JS_SetGCThreshold(memory_limit/4)` | `quickjs_bridge.c` |
| P2 | 字节码剥离 | `JS_SetStripInfo(JS_STRIP_SOURCE \| JS_STRIP_DEBUG)` | `quickjs_bridge.c` |
| P3 | 线程安全 | `pthread_mutex_t` 保护所有 QuickJS 调用（多 Isolate 防崩溃） | `quickjs_bridge.c` |
| P4 | 输入验证 | 脚本 1MB / HTML 10MB / HTTP 50MB / Base64 10MB / 加密 10MB | `quickjs_bridge.c` |
| P4 | 8KB 行限制 | HTTP 逐行读取行缓冲上限 | `http_client.c` |
| P5 | 引擎内存监控 | `JS_ComputeMemoryUsage` 25 字段全量暴露 | `quickjs_bridge.c` |
| P5 | 调试面板 | JS 内存卡片 + GC 按钮 + Promise 状态监控 + JS 值打印 | `crypto_stats_panel.dart` |
| P5 | 降级回退 | 所有 C 调用 try-catch 包裹 | `quickjs_runtime.dart` |

---

## 规则引擎兼容性

| 规则类型 | 状态 | 说明 |
|----------|------|------|
| CSS/JSoup 选择器 | ✅ | `class.xxx` / `tag.xxx` / `@css:` / 索引切片 |
| JSONPath | ✅ | `$.xxx` / `$[n]` / `$..xxx` / 过滤器 |
| XPath | ✅ | `//div[@class]` / `@xpath:` / HTML 自动补全 |
| JavaScript | ✅ | `@js:` / `<js>` / 全局 JS 执行 |
| 正则替换 | ✅ | `##regex##replacement` / `###` |
| 模板规则 | ✅ | `{{@@.xxx@text}}` / `{{$.xxx}}` |
| 变量系统 | ✅ | `@put` / `@get` / `java.put/getStr` |
| CryptoJS | ✅ | AES / MD5 / SHA / HMAC 全支持 |
| java.* 桥接 | ✅ | HTTP / 加密 / 解析 / 缓存 / 日志 |
| TypeScript | ➕ | `@ts:` 前缀自动编译（本应用独有） |

> 详见 [书源规则帮助](assets/templates/book_source_help.md) 与 [JS 开发文档](assets/templates/book_source_js_help.md)。

---

## 开发

### 环境要求

- Flutter 3.41+（项目内置 `flutter.bat`，默认指向 `D:\flutter_windows_3.41.7-stable`，可设 `FLUTTER_ROOT` 覆盖）
- Android NDK 28.x（编译 C 桥接层时需 CMake + NDK clang）
- CMake 3.22+

### 常用命令

```bash
flutter pub get                  # 安装依赖
flutter run                      # 运行
flutter build apk                # 构建 Android APK（含 C 编译）
flutter build ios                # 构建 iOS（含 C 编译）
flutter analyze                  # 静态分析 + lint
flutter test                     # 运行 test/ 全部测试
```

> `flutter.bat` 已预设国内镜像（`pub.flutter-io.cn` / `storage.flutter-io.cn`）与本地 pub-cache。

### 测试

`test/` 目录：

| 文件 | 内容 | 运行命令 |
|------|------|----------|
| `widget_test.dart` | 占位测试 | `flutter test` |
| `legado_rule_test.dart` | CSS/JSoup 链式选择器规则 | `flutter test test/legado_rule_test.dart` |
| `book_source_compat_test.dart` | 书源导入、URL 解析、元数据合并、源定位 | `flutter test test/book_source_compat_test.dart` |
| `crypto_native_test.dart` | C 原生加密对比（需 Android 真机/模拟器加载 .so） | `flutter test test/crypto_native_test.dart` |

CI 不跑测试与 lint。

### Lint 规则

`analysis_options.yaml`（`.gitignore` 忽略）：`avoid_print`、`prefer_single_quotes`、`sort_child_properties_last`、`use_key_in_widget_constructors`、`prefer_const_constructors`、`prefer_final_fields/locals`、`prefer_const_declarations`。

使用 `debugPrint` 替代 `print`（`avoid_print` 强制）。

---

## 约定

- 全项目使用**中文注释与中文标识符**
- 路由使用 `Map<String, dynamic>?` 参数（见 `app_routes.dart`）
- 路由参数可能是 `Map`（动态）或 `Map<String, dynamic>` — 代码通过 `is Map` 检查兼容两者
- 序列化：`Book.fromJson` / `BookSource.fromJson`

---

## 持续集成

`.github/workflows/main.yml` — push 时自动将所有分支合并到 `master`（冲突 → 自动创建 PR）。

`.github/workflows/build.yml` — Android + iOS 构建验证。

---

## 许可证

MIT License