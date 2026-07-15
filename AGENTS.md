# MR — 多媒体阅读器（Flutter）

> 本文档为 AI 协作代理（agentic coding）提供的项目工作约定，与 `README.md` 互补。
> 内容根据当前代码库真实状态编写，用于指导 AI 代理在本仓库工作时的命令、测试、架构与约定。

## 命令

```bash
flutter pub get          # 安装依赖
flutter run              # 在连接的设备/模拟器上运行
flutter build apk        # 构建 Android APK（触发 QuickJS C 桥接 CMake 编译）
flutter build ios        # 构建 iOS（需 macOS + Xcode）
flutter build hap        # 构建 HarmonyOS HAP（需鸿蒙 Flutter SDK）
flutter test             # 运行 test/ 下全部测试
flutter analyze          # lint + 静态分析
```

> 项目根的 `flutter.bat` 已预设国内镜像并指向 `D:\flutter_windows_3.41.7-stable`，可设 `FLUTTER_ROOT` 覆盖。
> 若 `C:` 盘空间不足，可设 `$env:TEMP` 指向项目下临时目录再运行 `flutter test`。

## 测试

`test/` 下五个测试文件：

| 文件 | 内容 | 备注 |
|------|------|------|
| `widget_test.dart` | 占位，恒通过 | — |
| `legado_rule_test.dart` | CSS/JSoup 链式选择器规则 | — |
| `book_source_compat_test.dart` | 书源导入、URL 解析、元数据合并、源定位 | — |
| `crypto_native_test.dart` | C 原生加密对比 | 需 Android 真机/模拟器加载 `libquickjs_c_bridge.so`，桌面测试运行器会失败 |
| `chinese_converter_test.dart` | 简繁中文转换 | — |

```bash
flutter test test/legado_rule_test.dart
flutter test test/book_source_compat_test.dart
```

CI 不跑测试，仅本地运行。

## 架构

| 层 | 技术 |
|----|------|
| 状态管理 | Provider（`lib/providers/` 6 个：App / Bookshelf / Discovery / ExploreShow / Reader / Search） |
| 存储 | Hive（`main.dart` 初始化 `Hive.initFlutter()` → `StorageService.init()`） |
| HTTP | Dio（Web 走 `ProxyService` 启动的 CORS 代理） |
| JS | QuickJS（`flutter_js` + FFI，单引擎调度） |
| 路由 | 自定义 `AppPageRoute` + `PageRouteBuilder`，零时长切换，定义于 `lib/routes/app_routes.dart` |
| 图片解密 | `DecodedImageProvider`（自定义 ImageProvider，下载→JS 解密→解码） |
| 崩溃日志 | `CrashLogService`（启动最先初始化，注册全局错误捕获） |

### 入口初始化顺序

`lib/main.dart` — 在 `runZonedGuarded` 中依次：

1. `CrashLogService.instance.init()` — 崩溃日志（最先，注册全局错误捕获）
2. `AppLogger.instance.initFileLogging()` + `enableDebugPrintCapture()` — 应用日志
3. `Hive.initFlutter()` → `StorageService.instance.init()` — 本地存储
4. `JsEngine.instance.init()` — JS 引擎
5. `CoverConfigService.instance.init()` — 封面配置
6. `ProxyService.instance.start()` — CORS 代理（仅 Web）
7. `runApp(DanShenqiApp())`

> 每个服务初始化均包裹在 try-catch 中，单个服务失败不中断启动。
> `StorageService` 未初始化时，所有同步 getter（`getAllBooks`/`getBook` 等）返回空值，避免 `HiveError` 崩溃。

### 关键目录

```
lib/
  services/source_engine/   # Legado 规则引擎核心（analyze_rule / web_book / legado_json_path / legado_xpath / proxy_service）
  services/native/          # JS 引擎调度、QuickJS FFI 绑定、平台通道、Dio SSL
  services/local_book/      # 本地书解析（EPUB / TXT）
  services/                  # storage_service / book_data_provider / chapter_cache_service / image_decode_provider / crash_log_service / app_logger 等
  models/                   # BookSource / Book / Chapter / Highlight / Miniprogram / ReplaceRule 及 rules/ 六类子模型
  pages/                    # 13 个子目录：bookshelf / reader(comic+novel) / player(audio+video) / debug / detail / search / discovery / explore / miniprogram / web / profile(11 子页) / settings / main
  providers/                # App / Bookshelf / Discovery / Reader / Search / ExploreShow
  routes/
  utils/                    # design_tokens / chinese_converter / share_helper
  widgets/                  # 公共组件 + reader/ 子组件
  themes/                   # theme_config + ui_corner
```

## Web 平台

`kIsWeb` 时由 `main.dart` 中 `ProxyService.instance.start()` 自动启动 CORS 代理。工具脚本：`tools/cors-proxy.js`。

## 原生 C 桥接

- 源码：`quickjs/`（含 `crypto/`、`lexbor/` 等子目录）
- 编译产物：`libquickjs_c_bridge.so`（Android）/ `quickjs_c_bridge.dll`（Windows）
- 构建脚本：`android/app/src/main/cpp/CMakeLists.txt` + `quickjs_bridge.map`
- 鸿蒙构建：`quickjs/ohos/CMakeLists.txt`（CI 注入 `ohos/entry/src/main/cpp/`）
- 入口绑定：`lib/services/native/quickjs_runtime.dart`（FFI）+ `quickjs_runtime_stub.dart`（Web 桩）

## 图片解密

`lib/services/image_decode_provider.dart` — `DecodedImageProvider`：

- `needsDecode(source, isCover)` 判断书源是否配置了 `coverDecodeJs`（封面）或 `ruleContent.imageDecode`（正文）
- 需要解密时走 `DecodedImageProvider`（下载→JS 解密→解码），否则走 `CachedNetworkImage`（享受磁盘缓存）
- 已重写 `==` 和 `hashCode`（基于 url + isCover），Flutter `ImageCache` 可正常复用

使用位置：`bookshelf_page` / `search_page` / `detail_page` / `read_record_page` / `bookmark_page` / `storage_manage_page` / `comic_reader_page`。

## 漫画阅读器缓存策略

`lib/pages/reader/comic_reader_page.dart`：

- **纯按需加载**：翻页时只加载当前页，不预缓存下一张
- **缓存按钮**：`_downloadCurrentChapter` 只缓存当前一张，`_isDownloading` 防重入，`_precachedUrls` Set 去重
- **base64 解码缓存**：`_dataImageCache` Map 避免重复解析
- **日志去重**：`_loggedImageUrls`（开始加载）和 `_loggedErrorUrls`（加载失败）独立 Set，O(1) 查找

## 静态分析

`analysis_options.yaml`（被 `.gitignore` 忽略）规则：`avoid_print` / `prefer_single_quotes` / `sort_child_properties_last` / `use_key_in_widget_constructors` / `prefer_const_constructors` / `prefer_final_fields/locals` / `prefer_const_declarations`。

由 `avoid_print` 强制：使用 `debugPrint` 替代 `print`。

## 持续集成

### `.github/workflows/main.yml` — 自动合并

push 到任意分支（非 master）时，自动将该分支合并到 master。冲突 → 自动创建 PR。

### `.github/workflows/build.yml` — 多平台构建发布

| 平台 | 触发 | 产物 | 签名 |
|------|------|------|------|
| Android | push master / 手动 | `mr_v*_dev_*.apk`（arm64） | Release 签名 |
| iOS | push master / 手动 | `mr_v*_dev_*.ipa` | 未签名（`--no-codesign`） |
| HarmonyOS | push master / 手动 | `mr_v*_dev_*.hap` | 未签名（用户自行用 DevEco Studio 签名） |

- 版本号格式：`YY.MMDD.今日提交数`（如 `25.0715.3`）
- 鸿蒙 Flutter SDK 为华为 fork（`gitcode.com/openharmony-sig/flutter_flutter`），CI 动态获取最新 release 分支
- iOS / HarmonyOS 构建允许失败（`continue-on-error: true`），不阻塞发布

CI 不跑测试与 lint。

## 约定

- 全项目使用中文注释与中文标识符
- 路由参数使用 `Map<String, dynamic>?`（见 `app_routes.dart` 模式）
- 路由参数可能是 `Map`（动态）或 `Map<String, dynamic>` — 代码通过 `is Map` 检查兼容两种
- 通过 `Book.fromJson` / `BookSource.fromJson` 进行序列化
- 删除文件时同步清理 barrel export（`source_engine.dart` 等）
- 异步操作后使用 `BuildContext` 前必须检查 `mounted`
- 空值断言 `!` 应替换为局部变量 + null 检查（类型提升）
