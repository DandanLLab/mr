# MR(暂时代号名称) - 多媒体阅读器

一款基于 Flutter 的跨平台多媒体阅读器，兼容阅读(Legado)书源规则，支持小说、漫画、音频等内容。

## 特性

### 兼容 Legado 书源
- 完整支持 Legado 规则语法（CSS/JSON/XPath/JS/正则/模板）
- 双 JS 引擎：QuickJS（ES2020）+ Rhino（Android 原生）
- CryptoJS / java.* 桥接 API 兼容
- TypeScript 支持（`@ts:` 前缀自动编译）

### 跨平台
- Android / iOS / Web / Desktop
- 统一规则引擎，无需针对平台修改书源

### 阅读器
- 小说阅读器（仿真翻页、滚动、滑动）
- 漫画浏览器（竖向滚动、左右翻页）
- 音频播放器（后台播放、定时停止）

### 扩展系统
- 书源管理（兼容 Legado JSON 格式）
- 书源调试（实时日志 + 源码查看 + 执行追踪树）
- 小程序 / 插件系统

## 技术架构

| 组件 | 技术 | 说明 |
|------|------|------|
| 框架 | Flutter 3.x | 跨平台 UI |
| JS 引擎 | QuickJS (flutter_js) + Rhino (Android) | 双引擎自动分流 |
| HTML 解析 | package:html | CSS 选择器（兼容 JSoup 规则） |
| JSON 解析 | 自定义 JSONPath | 递归搜索/过滤器/切片 |
| XPath 解析 | xml + xpath | HTML 自动补全 |
| HTTP | Dio + OkHttp (Android) | 双通道请求 |
| 加密 | NativeChannel (AES/MD5/SHA/HMAC) | 桥接原生加密 |
| 存储 | Hive | 本地数据库 |
| 状态管理 | Provider | 响应式 UI |

## 规则引擎兼容性

| 规则类型 | 状态 | 说明 |
|----------|------|------|
| CSS/JSoup 选择器 | ✅ | `class.xxx` / `tag.xxx` / `@css:` |
| JSONPath | ✅ | `$.xxx` / `$[n]` / `$..xxx` |
| XPath | ✅ | `//div[@class]` / `@xpath:` |
| JavaScript | ✅ | `@js:` / `<js>` / `@quickjs:` / `@rhino:` |
| 正则替换 | ✅ | `##regex##replacement` / `###` |
| 模板规则 | ✅ | `{{@@.xxx@text}}` / `{{$.xxx}}` |
| 变量系统 | ✅ | `@put` / `@get` / `java.put/getStr` |
| CryptoJS | ✅ | AES/MD5/SHA/HMAC 全支持 |
| java.* 桥接 | ✅ | HTTP/加密/解析/缓存/日志 |
| TypeScript | ➕ | `@ts:` 前缀自动编译 |

> 详见 [书源规则帮助](assets/templates/book_source_help.md) 和 [JS 开发文档](assets/templates/book_source_js_help.md)

## 项目结构

```
lib/
├── models/                   # 数据模型
├── pages/                    # 页面
│   ├── bookshelf/            # 书架
│   ├── detail/               # 书籍详情
│   ├── debug/                # 书源调试
│   ├── reader/               # 阅读器
│   ├── search/               # 搜索
│   └── profile/              # 设置
├── services/
│   ├── source_engine/        # 规则引擎核心
│   │   ├── analyze_rule.dart # 规则解析器
│   │   ├── web_book.dart     # 网络请求引擎
│   │   ├── legado_json_path.dart
│   │   └── legado_xpath.dart
│   ├── native/
│   │   └── js_engine.dart    # JS 双引擎
│   └── source_debug_service.dart
├── providers/                # 状态管理
├── widgets/                  # 公共组件
└── utils/                    # 工具类
```

## 开发

```bash
# 安装依赖
flutter pub get

# 运行
flutter run

# 构建 Android
flutter build apk
```

## 许可证

MIT License
