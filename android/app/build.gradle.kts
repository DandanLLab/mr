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

        // 保险 #1：清除 Flutter Gradle Plugin 注入的三个 ABI，只保留 arm64-v8a
        // FlutterPlugin.kt:557-560 在 apply 阶段会 abiFilters.clear() + addAll([armeabi-v7a, arm64-v8a, x86_64])
        // 用户代码在 plugin apply 之后执行，这里再次 clear() 覆盖
        // abiFilters 是 val MutableSet<String>（无 setter），不能用 = 赋值，只能 clear() + add()
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
        // QuickJS NDK 编译配置
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    // 传递项目根目录，CMakeLists.txt 用它定位 quickjs/ 源码
                    "-DPROJECT_ROOT_DIR=${rootProject.projectDir.parentFile?.absolutePath}"
                )
                cFlags += "-D_GNU_SOURCE"
                // 显式只编译 arm64-v8a（覆盖 Flutter 注入的 ABI）
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
        }
    }

    // 注意：不能用 splits.abi，AGP 规则要求 ndk.abiFilters 和 splits.abi.filters 必须一致
    // Flutter 已注入三个 ABI 到 ndk.abiFilters，配 splits.abi 只保留 arm64-v8a 会触发
    // "Conflicting configuration ... cannot be present when splits abi filters are set"
    // 这里用 ndk.abiFilters.clear() 覆盖 Flutter 的注入，splits.abi 不启用

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
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
                "META-INF/versions/**",
                "kotlin/**",
                "kotlin-tooling-metadata.json",
                "DebugProbesKt.bin",
                "META-INF/proguard/**",
            )
        }
        // .so 文件不压缩（Android 6+ 直接 mmap，压缩反而浪费 CPU）
        jniLibs {
            useLegacyPackaging = false
            // 保险 #3：packaging 显式排除 x86_64 和 armeabi-v7a 的 .so
            // 即使上游依赖带了这些 ABI 的 .so 也会被剔除
            excludes += listOf(
                "lib/x86_64/**",
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/mips/**",
                "lib/mips64/**"
            )
        }
    }

    // QuickJS CMake 构建配置（编译 C 源码为 libquickjs_c_bridge.so）
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
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
    // Java 8+ API 脱糖
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
