plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mr.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    // 使用 compilerOptions DSL（kotlinOptions 已在 Kotlin 2.2+ 废弃）
    // 但 android kotlinOptions 仍在 android {} 块内可用，保留兼容
    kotlinOptions {
        jvmTarget = "21"
    }

    defaultConfig {
        applicationId = "com.mr.app"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只保留 ARM 架构，移除 x86/x86_64（模拟器用，减少约 40% .so 体积）
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
    }

    // 排除重复/冗余文件，减小 APK 体积
    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/license.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/notice.txt",
                "META-INF/*.kotlin_module",
            )
        }
        // .so 文件不压缩（Android 6+ 直接 mmap，压缩反而浪费 CPU）
        jniLibs {
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isShrinkResources = true
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    // Kotlin 标准库（显式声明版本，确保 Android Studio 能解析）
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.2.20")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // OkHttp（HTTP 客户端）
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    // Jsoup（HTML 解析 + 内置 XPath selectXpath()）
    implementation("org.jsoup:jsoup:1.22.2")
    // JsonPath（JSON 解析）
    implementation("com.jayway.jsonpath:json-path:2.9.0")
    // Commons Text（HTML 反转义）
    implementation("org.apache.commons:commons-text:1.12.0")
    // Rhino（JS 引擎）
    implementation("org.mozilla:rhino:1.9.1")
    // Java 8+ API 脱糖
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
