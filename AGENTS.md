# MR — 多媒体阅读器（Flutter）

> 本文档为 AI 协作代理（agentic coding）提供的项目工作约定，与 `README.md` 互补。

## 命令

```bash
flutter pub get          # 安装依赖
flutter run              # 在连接的设备/模拟器上运行
flutter build apk        # 构建 Android APK（触发 QuickJS C 桥接 CMake 编译）
flutter test             # 运行 test/ 下全部测试
flutter analyze          # lint + 静态分析
```

> 项目根的 `flutter.bat` 已预设国内镜像并指向 `D:\flutter_windows_3.41.7-stable`，可设 `FLUTTER_ROOT` 覆盖。
> 若 `C:` 盘空间不足，可设 `$env:TEMP` 指向项目下临时目录再运行 `flutter test`。

## 测试

`test/` 下四个测试文件：
- `widget_test.dart` — 占位，恒通过
- `legado_rule_test.dart` — CSS/JSoup 链式选择器规则
- `book_source_compat_test.dart` — 书源导入、URL 解析、元数据合并、源定位
- `crypto_native_test.dart` — C 原生加密对比（需 Android 真机/模拟器加载 `libquickjs_c_bridge.so`，桌面测试运行器会失败）

```bash
flutter test test/legado_rule_test.dart
flutter test test/book_source_compat_test.dart
```

CI 不跑测试，仅本地运行。

## 架构

| 层 | 技术 |
|----|------|
| 状态管理 | Provider（`lib/providers/` 6 个） |
| 存储 | Hive（`main.dart` 初始化） |
| HTTP | Dio（Web 走 `ProxyService` 启动的 CORS 代理） |
| JS | 双引擎：QuickJS（`flutter_js` + FFI）+ Rhino（Android 原生），由 `EngineDispatcher` 调度 |
| 路由 | 自定义 `AppPageRoute` + `PageRouteBuilder`，零时长切换，定义于 `lib/routes/app_routes.dart` |

入口：`lib/main.dart` — 依次初始化 Hive、`StorageService`、`JsEngine`、`CoverConfigService`，再运行 `DanShenqiApp`。

### 关键目录

```
lib/
  services/source_engine/   # Legado 规则引擎核心（analyze_rule / web_book / legado_json_path / legado_xpath / js_engine / proxy_service）
  services/native/          # JS 引擎调度、QuickJS FFI 绑定、平台通道
  models/                   # BookSource / Book / Chapter 等及 rules/ 子模型
  pages/                    # 13 个子目录：bookshelf / reader(comic+novel) / player(audio+video) / debug / detail / search / discovery / explore / miniprogram / web / profile / settings / main
  providers/                # App / Bookshelf / Discovery / Reader / Search / ExploreShow
  routes/
  utils/                    # design_tokens 等工具
  widgets/                  # 公共组件 + reader/ 子组件
  themes/                   # 主题配置 + 圆角徽标
```

## Web 平台

`kIsWeb` 时由 `main.dart` 中 `ProxyService.instance.start()` 自动启动 CORS 代理。工具脚本：`tools/cors-proxy.js`。

## 原生 C 桥接

- 源码：`quickjs/`（含 `crypto/`、`lexbor/` 等子目录）
- 编译产物：`libquickjs_c_bridge.so`（Android）/ `quickjs_c_bridge.dll`（Windows）
- 构建脚本：`android/app/src/main/cpp/CMakeLists.txt` + `quickjs_bridge.map`
- 入口绑定：`lib/services/native/quickjs_runtime.dart`（FFI）+ `quickjs_runtime_stub.dart`（Web 桩）

## 静态分析

`analysis_options.yaml`（被 `.gitignore` 忽略）规则：`avoid_print` / `prefer_single_quotes` / `sort_child_properties_last` / `use_key_in_widget_constructors` / `prefer_const_constructors` / `prefer_final_fields/locals` / `prefer_const_declarations`。

由 `avoid_print` 强制：使用 `debugPrint` 替代 `print`。

## 持续集成

`.github/workflows/main.yml` — push 时自动将所有分支合并到 `master`（冲突 → 自动创建 PR 回退）。CI 不跑测试与 lint。

## 约定

- 全项目使用中文注释与中文标识符
- 路由参数使用 `Map<String, dynamic>?`（见 `app_routes.dart` 模式）
- 路由参数可能是 `Map`（动态）或 `Map<String, dynamic>` — 代码通过 `is Map` 检查兼容两种
- 通过 `Book.fromJson` / `BookSource.fromJson` 进行序列化
- 删除文件时同步清理 barrel export（`source_engine.dart` 等）