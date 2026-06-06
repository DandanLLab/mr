plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// ===== Node.js 内置运行时配置 =====
val nodeVersion = "v25.9.0"
val nodeBuildDir = layout.buildDirectory.dir("node-runtime").get().asFile
val jniLibsDir = file("src/main/jniLibs")
val assetsNodeDir = file("src/main/assets/node")
val projectRoot = file("../..")

// Node.js for Android 预编译二进制下载地址
// 优先使用 unofficial-builds 的 musl 版本（静态链接，Android 兼容性更好）
// 官方 linux-arm64 依赖 glibc，Android 上可能缺库；musl 版本无此问题
// armeabi-v7a (32位ARM) 官方和非官方均不提供，旧设备不支持
val nodeDownloadUrls = mapOf(
    "arm64-v8a" to "https://unofficial-builds.nodejs.org/download/release/${nodeVersion}/node-${nodeVersion}-linux-arm64-musl.tar.xz",
    "x86_64" to "https://unofficial-builds.nodejs.org/download/release/${nodeVersion}/node-${nodeVersion}-linux-x64-musl.tar.xz",
)

android {
    namespace = "com.example.dan_shenqi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = "21"
    }

    defaultConfig {
        applicationId = "com.example.dan_shenqi"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

    // 确保 jniLibs 中的 Node.js 二进制不被压缩
    aaptOptions {
        noCompress.add("so")
    }
}

dependencies {
    // Kotlin 标准库（显式声明版本，确保 Android Studio 能解析）
    implementation("org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.2.20")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // OkHttp（HTTP 客户端）
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    // Jsoup（HTML 解析）
    implementation("org.jsoup:jsoup:1.18.1")
    // Rhino（JS 引擎）
    implementation("org.mozilla:rhino:1.9.1")
    // Java 8+ API 脱糖
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

// ===== Node.js 硬编构建任务 =====
// 核心思路：将 Node.js 二进制重命名为 libnode.so 放入 jniLibs/
// Android 安装 APK 时自动解压 native libs 到 /data/data/.../lib/
// 并设置可执行权限，运行时直接启动，无需额外解压

/**
 * 下载 Node.js 预编译二进制，重命名为 libnode.so 放入 jniLibs
 *
 * 跨平台兼容：Windows/macOS/Linux 均可
 * 不阻塞构建：下载/解压失败只警告，不抛异常
 */
tasks.register("downloadNodeBinaries") {
    group = "node-runtime"
    description = "下载 Node.js 二进制到 jniLibs（伪装为 libnode.so）"

    outputs.dir(jniLibsDir)

    doLast {
        val targetAbis = listOf("arm64-v8a")

        for (abi in targetAbis) {
            val url = nodeDownloadUrls[abi] ?: continue
            val abiDir = File(jniLibsDir, abi)
            val libNode = File(abiDir, "libnode.so")
            val versionFile = File(abiDir, ".node_version")

            // 本地目录已有 libnode.so 就直接跳过下载
            if (libNode.exists() && libNode.length() > 0) {
                logger.lifecycle("[Node.js] ${abi} 本地已存在 libnode.so (${libNode.length() / 1024 / 1024}MB)，跳过下载")
                if (!versionFile.exists()) {
                    versionFile.writeText(nodeVersion)
                }
                continue
            }

            abiDir.mkdirs()

            try {
                val tarFile = File(abiDir, "node.tar.xz")

                // 本地已有 node.tar.xz 就跳过下载，直接解压
                if (tarFile.exists() && tarFile.length() > 0) {
                    logger.lifecycle("[Node.js] ${abi} 本地已存在 node.tar.xz (${tarFile.length() / 1024 / 1024}MB)，跳过下载，直接解压")
                } else {
                    logger.lifecycle("[Node.js] 下载 ${abi}: ${url}")
                    // 下载
                    ant.withGroovyBuilder {
                        "get"("src" to url, "dest" to tarFile, "verbose" to true)
                    }
                }

                if (!tarFile.exists() || tarFile.length() == 0L) {
                    logger.warn("[Node.js] ${abi} 下载失败，跳过")
                    continue
                }

                // 解压（跨平台：优先用系统 tar，失败则用 7z/PowerShell）
                logger.lifecycle("[Node.js] 解压 ${abi}...")
                val muslSuffix = if (abi == "arm64-v8a") "arm64-musl" else "x64-musl"
                val innerPath = "node-${nodeVersion}-linux-${muslSuffix}/bin/node"
                var extracted = false

                // 方法1：系统 tar（Linux/macOS/Git Bash）
                if (!extracted) {
                    try {
                        val proc = ProcessBuilder(
                            "tar", "-xJf", tarFile.absolutePath,
                            "-C", abiDir.absolutePath,
                            "--strip-components=2",
                            innerPath
                        )
                            .redirectErrorStream(true)
                            .start()
                        proc.inputStream.bufferedReader().use { it.lines().forEach { line -> logger.lifecycle(line) } }
                        val exitCode = proc.waitFor()
                        if (exitCode == 0) extracted = true
                    } catch (e: Exception) {
                        logger.lifecycle("[Node.js] tar 不可用: ${e.message}")
                    }
                }

                // 方法2：7z（Windows 常见）
                if (!extracted) {
                    try {
                        // 先全量解压
                        val proc = ProcessBuilder("7z", "x", tarFile.absolutePath, "-o${abiDir.absolutePath}", "-y")
                            .redirectErrorStream(true)
                            .start()
                        proc.inputStream.bufferedReader().use { it.lines().forEach { line -> logger.lifecycle(line) } }
                        val exitCode = proc.waitFor()
                        if (exitCode == 0) extracted = true
                    } catch (e: Exception) {
                        logger.lifecycle("[Node.js] 7z 不可用: ${e.message}")
                    }
                }

                // 方法3：PowerShell Expand-Archive（Windows，但只支持 zip）
                // xz 格式不支持，跳过

                // 清理 tar
                tarFile.delete()

                if (!extracted) {
                    // 检查是否有部分解压的文件
                    val foundNode = abiDir.walk().find { it.name == "node" && it.isFile && it.length() > 1000000 }
                    if (foundNode != null) {
                        extracted = true
                    }
                }

                // 找到解压出来的 node 二进制，重命名为 libnode.so
                val directNode = File(abiDir, "node")
                if (directNode.exists() && directNode.isFile) {
                    directNode.renameTo(libNode)
                    logger.lifecycle("[Node.js] 重命名 node → libnode.so")
                } else {
                    // 在子目录中查找
                    abiDir.walk().find { it.name == "node" && it.isFile && it.length() > 1000000 }?.let { found ->
                        found.copyTo(libNode, overwrite = true)
                        found.delete()
                        logger.lifecycle("[Node.js] 找到并重命名 node → libnode.so")
                    }
                }

                if (!libNode.exists() || libNode.length() == 0L) {
                    logger.warn("[Node.js] ${abi} 二进制未找到，Node.js 功能将不可用")
                    logger.warn("[Node.js] 请手动下载 ${url}")
                    logger.warn("[Node.js] 解压后提取 bin/node 重命名为 libnode.so 放入 ${abiDir.absolutePath}")
                    // 不抛异常，不阻塞构建
                    continue
                }

                // 写入版本标记
                versionFile.writeText(nodeVersion)

                // 清理多余文件
                abiDir.walk().filter { it.isFile && it.name != "libnode.so" && it.name != ".node_version" }.forEach {
                    it.delete()
                }
                abiDir.walk().filter { it.isDirectory && it.name != abi && it.listFiles()?.isEmpty() != false }.forEach {
                    it.deleteRecursively()
                }

                logger.lifecycle("[Node.js] ${abi} 完成: ${libNode.absolutePath} (${libNode.length() / 1024 / 1024}MB)")
            } catch (e: Exception) {
                logger.warn("[Node.js] ${abi} 处理失败: ${e.message}")
                logger.warn("[Node.js] Node.js 功能将不可用，不影响其他功能")
                // 不抛异常，不阻塞构建
            }
        }
    }
}

/**
 * 复制 JS 脚本到 assets（首次运行时解压到内部存储并缓存）
 */
tasks.register("copyNodeScripts") {
    group = "node-runtime"
    description = "复制 JS 脚本到 Android assets 目录"

    val scriptsDestDir = File(assetsNodeDir, "scripts")
    outputs.dir(scriptsDestDir)

    doLast {
        val proxySrc = File(projectRoot, "tools/cors-proxy.js")
        val proxyDest = File(scriptsDestDir, "cors-proxy.js")
        if (proxySrc.exists()) {
            proxyDest.parentFile.mkdirs()
            proxySrc.copyTo(proxyDest, overwrite = true)
            logger.lifecycle("[Node.js] 复制 cors-proxy.js")
        }

        val indexSrc = File(projectRoot, "tools/native-proxy/index.js")
        val indexDest = File(scriptsDestDir, "native-proxy/index.js")
        if (indexSrc.exists()) {
            indexDest.parentFile.mkdirs()
            indexSrc.copyTo(indexDest, overwrite = true)
            logger.lifecycle("[Node.js] 复制 native-proxy/index.js")
        }

        val nodeModuleSrc = File(projectRoot, "tools/native-proxy/native-proxy.node")
        val nodeModuleDest = File(scriptsDestDir, "native-proxy/native-proxy.node")
        if (nodeModuleSrc.exists()) {
            nodeModuleDest.parentFile.mkdirs()
            nodeModuleSrc.copyTo(nodeModuleDest, overwrite = true)
            logger.lifecycle("[Node.js] 复制 native-proxy.node")
        } else {
            logger.lifecycle("[Node.js] native-proxy.node 未编译，使用 JS 降级模式")
        }
    }
}

/**
 * 组装 Node.js 运行时
 */
tasks.register("assembleNodeRuntime") {
    group = "node-runtime"
    description = "组装 Node.js 运行时（二进制→jniLibs + 脚本→assets）"

    dependsOn("downloadNodeBinaries", "copyNodeScripts")

    doLast {
        logger.lifecycle("[Node.js] 运行时组装完成!")
        logger.lifecycle("[Node.js] 二进制: jniLibs/arm64-v8a/libnode.so (Android 自动解压)")
        logger.lifecycle("[Node.js] 脚本: assets/node/scripts/ (首次运行缓存)")
    }
}

// 在 preBuild 之前自动执行
tasks.named("preBuild") {
    dependsOn("assembleNodeRuntime")
}
