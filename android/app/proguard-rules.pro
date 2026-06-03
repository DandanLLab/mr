# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Flutter Play Store Split (不需要但R8会检查)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# Hive (Hive 不依赖 protobuf，无需 keep GeneratedMessageLite)
-dontwarn com.google.protobuf.**

# Rhino JS引擎 (Android没有java.beans包)
-dontwarn java.beans.**
-dontwarn org.mozilla.javascript.JavaToJSONConverters

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keepclassmembers class okhttp3.** { *; }

# Jsoup
-keep class org.jsoup.** { *; }
-keepclassmembers class org.jsoup.** { *; }

# Keep model classes for JSON serialization
-keep class com.example.dan_shenqi.models.** { *; }

# Keep all serialization-related methods
-keepclassmembers class * {
    *** fromJson(...);
    *** toJson(...);
}
