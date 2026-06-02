# mmr 

一款支持小说、漫画、视频、音频的多媒体阅读器应用。

## 功能特性

### 📚 书架管理
- 本地书籍导入（支持 txt、epub、pdf 等格式）
- 在线书籍收藏
- 分组管理
- 阅读进度同步

### 🔍 发现页
- 基于书源的内容发现
- 多种分类（推荐、小说、漫画、视频、音频）
- 榜单推荐
- 瀑布流展示

### 📖 阅读器
- 小说阅读器（仿真翻页、滚动、滑动模式）
- 漫画浏览器（竖向滚动、左右翻页）
- 视频播放器（倍速播放、线路切换）
- 音频播放器（后台播放、定时停止）

### 🔧 扩展系统
- 书源管理（.dan 文件格式）
- 小程序支持
- 插件系统

## 技术栈

- **框架**: Flutter 3.x
- **状态管理**: Provider
- **本地存储**: Hive
- **网络请求**: Dio
- **图片缓存**: cached_network_image

## 项目结构

```
lib/
├── main.dart                 # 应用入口
├── models/                   # 数据模型
│   ├── book.dart
│   ├── chapter.dart
│   ├── book_source.dart
│   ├── miniprogram.dart
│   └── plugin.dart
├── providers/                # 状态管理
│   ├── app_provider.dart
│   ├── bookshelf_provider.dart
│   ├── discovery_provider.dart
│   └── reader_provider.dart
├── services/                 # 服务层
│   ├── storage_service.dart
│   ├── nojs_engine.dart
│   └── network_service.dart
├── pages/                    # 页面
│   ├── splash/
│   ├── main/
│   ├── bookshelf/
│   ├── discovery/
│   ├── miniprogram/
│   ├── profile/
│   ├── search/
│   ├── detail/
│   ├── reader/
│   └── player/
├── widgets/                  # 公共组件
├── utils/                    # 工具类
├── routes/                   # 路由配置
└── themes/                   # 主题配置
```

## 开始使用

### 环境要求

- Flutter SDK >= 3.0.0
- Dart SDK >= 3.0.0

### 安装依赖

```bash
flutter pub get
```

### 运行应用

```bash
flutter run
```

### 构建应用

```bash
# Android
flutter build apk

# iOS
flutter build ios

# Web
flutter build web
```

## .dan 文件格式

.dan 文件是本应用的扩展格式，用于封装：

- **书源规则**: 定义网络内容的获取与解析规则
- **小程序**: 独立的小工具应用
- **插件**: 系统功能扩展钩子

## 开发说明

### 添加新书源

1. 在"我的"页面进入"书源管理"
2. 点击右上角"+"按钮
3. 选择本地 .dan 文件或输入网络地址

### 开发小程序

小程序运行在 nojs.py 解释器提供的沙盒环境中，可以：
- 打开新视图（WebView 或原生风格界面）
- 访问系统 API
- 与主应用交互

### 开发插件

插件用于增强阅读器/播放器或系统行为：
- 小说阅读器 TTS 增强
- 漫画自动切边处理
- 视频播放器手势增强
- 全局字体替换

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！
