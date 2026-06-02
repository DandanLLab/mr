# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Hive
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-dontwarn com.google.protobuf.**

# Keep model classes for JSON serialization
-keep class com.example.dan_shenqi.models.** { *; }

# Keep all serialization-related methods
-keepclassmembers class * {
    *** fromJson(...);
    *** toJson(...);
}
