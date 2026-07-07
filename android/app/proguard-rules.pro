# Flutter 引擎核心类（必须保留，R8 不应裁剪）
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.view.** { *; }

# Flutter Play Store Split (不需要但R8会检查)
-dontwarn com.google.android.play.core.**

# Hive (Hive 不依赖 protobuf，无需 keep GeneratedMessageLite)
-dontwarn com.google.protobuf.**

# flutter_js (QuickJS FFI 绑定，Android 没有 java.beans 包)
-dontwarn java.beans.**

# 以下库 R8 在 fullMode 下可自动分析使用情况，无需保守 keep：
# - Dio：主工程 HTTP 客户端，R8 能跟踪
# - flutter_inappwebview：WebView 组件
# - 序列化：fromJson/toJson 通过反射调用，必须保留
-keepclassmembers class * {
    *** fromJson(...);
    *** toJson(...);
}