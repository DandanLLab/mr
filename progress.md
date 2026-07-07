## 2026-07-08 - Task: iOS Flutter UI/功能交互修复 PR 准备

### What was done
- 基于 `DandanLLab/mr:master` 的干净分支整理交互修复，避免把旧本地分支历史带入主仓库。
- 修复搜索结果深色模式可读性、单书源测试后普通搜索范围残留、书架搜索入口点击区域和浅色主题搜索框辨识度。
- 修复阅读器覆盖/滑动模式表现混同、滑动跨章加载卡住、阅读信息布局、目录定位和当前章节深色高亮、缩进配置同步、设置开关/亮度滑条深色显示。
- 修复书源导入 SnackBar 返回后残留问题。
- 增加 TXT GBK 系列编码解码支持，改善本地 TXT 打开乱码。
- 新增协作文档说明本次 PR 范围、依赖、验证和回滚方式。

### Testing
- `flutter --no-version-check analyze --no-fatal-infos --no-fatal-warnings`：通过，无 error；仍存在主仓库既有 warning/info。
- `flutter --no-version-check test test/book_source_compat_test.dart test/widget_test.dart`：通过。
- 临时执行 `flutter --no-version-check test test/txt_decode_temp_test.dart` 验证 GBK/UTF-8 TXT 解码：通过，临时测试文件已删除。
- `flutter --no-version-check test`：未通过；失败来自 `crypto_native_test` 缺少 `quickjs_c_bridge.dll` 以及 `legado_rule_test` 的 source_engine 既有规则期望，本次未改 native/quickjs/source_engine 核心路径。

### Notes
- Modified files:
  - `lib/providers/search_provider.dart`：增加单书源入口状态恢复，避免普通搜索被单书源测试范围污染。
  - `lib/pages/search/search_page.dart`：调整搜索页单/多书源初始化和深色模式结果文字颜色。
  - `lib/pages/bookshelf/bookshelf_page.dart`：优化书架搜索入口点击区域和搜索框视觉。
  - `lib/pages/profile/book_source_import_page.dart`：清理导入提示 SnackBar 生命周期。
  - `lib/widgets/reader/reader_settings_sheet.dart`：优化夜间模式开关和滑条颜色。
  - `lib/providers/reader_provider.dart`：统一阅读缩进配置的字符串/数字同步。
  - `lib/pages/reader/novel_reader_page.dart`：优化覆盖/滑动翻页、跨章加载、阅读信息、目录定位和当前章节高亮。
  - `lib/services/local_book/txt_parser.dart`：增加 GBK / GB2312 / GB18030 TXT 解码支持。
  - `pubspec.yaml` / `pubspec.lock`：新增 `charset` 依赖用于 TXT 解码。
  - `docs/ios-ui-functional-fixes.md`：记录本次 PR 范围、验证和回滚方式。
  - `progress.md`：追加本轮进度记录。
- Rollback: 合入后执行 `git revert <本次提交 SHA>`；合入前关闭 PR 或删除 `codex/pr-ios-ui-functional-fixes` 分支即可。
