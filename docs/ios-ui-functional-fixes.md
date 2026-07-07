# iOS Flutter UI/功能交互修复说明

## 范围

本次 PR 基于 `DandanLLab/mr:master` 新建独立分支，只整理用户反馈的阅读、搜索、书架、导入和 TXT 本地书籍相关交互问题。

未改动范围：
- `quickjs/`
- `lib/services/native/`
- Android / macOS / Windows / Linux / Web 平台目录
- 原生桥接和核心 JS 引擎
- 书源解析核心链路

## 修复内容

1. 书源搜索
   - 修复从单书源测试入口进入后，普通搜索仍沿用单书源范围，导致只显示单个书源结果的问题。
   - 优化深色模式下搜索结果的分类、最新章节、暂无章节等文字对比度。

2. 书架搜索入口
   - 将书架顶部搜索入口改为整块可点击的搜索控件。
   - 修复只点搜索图标才进入搜索页、搜索框本身无响应的问题。
   - 提升浅色主题下搜索框背景和边框可见度。

3. 阅读器正文与设置
   - 覆盖翻页模式不再复用滑动 PageView，改为覆盖/淡入呈现，避免“覆盖”和“滑动”表现相同。
   - 滑动模式跨章节时显示加载边界页，并在切章时进入加载态，降低卡住风险。
   - 阅读信息实时显示并分散布局：时间在左下，章节/页码进度在右下。
   - 缩进配置统一归一为全角空格缩进，同时同步历史数字配置，保证正文段落缩进一致。
   - 目录打开后自动定位当前章节，并提高深色模式下当前章节的高亮可读性。
   - 夜间模式下设置开关使用更明确的开启/关闭色彩；手动亮度滑条在深色模式下轨道和滑块更清晰。

4. 书源导入提示
   - 导入结果和错误 SnackBar 展示前清理旧提示。
   - 页面返回或销毁时清理当前 SnackBar，避免返回上页后底部提示残留。

5. TXT 导入
   - 增加 GBK / GB2312 / GB18030 TXT 解码支持。
   - 保留 UTF-8、UTF-16LE、UTF-16BE 处理，改善部分中文 TXT 打开乱码的问题。

## 依赖变化

新增 Dart 依赖：
- `charset: ^2.0.1`

用途：只用于 TXT 本地书籍 GBK 系列编码解码。未替换 QuickJS/native/桥接依赖。

## 验证

已执行：

```powershell
flutter --no-version-check analyze --no-fatal-infos --no-fatal-warnings
flutter --no-version-check test test/book_source_compat_test.dart test/widget_test.dart
flutter --no-version-check test test/txt_decode_temp_test.dart
```

结果：
- `analyze`：无 error；仍有主仓库既有 warning/info。
- 指定可跑测试：通过。
- 临时 TXT GBK/UTF-8 解码测试：通过，测试文件已删除，未进入 PR。

完整 `flutter test` 当前未通过，失败来自本地环境/既有核心测试：
- `crypto_native_test` 缺少 `quickjs_c_bridge.dll`，属于 native/quickjs 禁区。
- `legado_rule_test` 有 source_engine 规则期望不一致，属于本次不触碰的核心解析范围。

## 回滚方式

本次 PR 会整理为单独分支上的独立提交。若合入后需要撤销，可使用：

```bash
git revert <本次提交 SHA>
```

如果尚未合入，直接关闭 PR 或删除分支即可，不影响 `DandanLLab/mr:master`。
