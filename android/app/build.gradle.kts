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
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    implementation("org.jsoup:jsoup:1.18.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.mozilla:rhino:1.9.1")
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

            // 检查是否已下载且版本匹配
            if (libNode.exists() && versionFile.exists() && versionFile.readText().trim() == nodeVersion) {
                logger.lifecycle("[Node.js] ${abi} 已存在 (v${nodeVersion})，跳过下载")
                continue
            }

            abiDir.mkdirs()
            val tarFile = File(abiDir, "node.tar.xz")

            logger.lifecycle("[Node.js] 下载 ${abi}: ${url}")

            // 下载
            ant.withGroovyBuilder {
                "get"("src" to url, "dest" to tarFile, "verbose" to true)
            }

            // 解压（musl 版本目录名: node-v25.9.0-linux-arm64-musl/bin/node）
            logger.lifecycle("[Node.js] 解压 ${abi}...")
            val muslSuffix = if (abi == "arm64-v8a") "arm64-musl" else "x64-musl"
            val proc = ProcessBuilder(
                "tar", "-xJf", tarFile.absolutePath,
                "-C", abiDir.absolutePath,
                "--strip-components=2",
                "node-${nodeVersion}-linux-${muslSuffix}/bin/node"
            )
                .directory(abiDir)
                .redirectErrorStream(true)
                .start()
            proc.inputStream.bufferedReader().use { it.lines().forEach { line -> logger.lifecycle(line) } }
            val exitCode = proc.waitFor()

            // 清理 tar
            tarFile.delete()

            if (exitCode != 0) {
                // 如果精确路径解压失败，尝试全量解压
                logger.lifecycle("[Node.js] 精确解压失败，尝试全量解压...")
                if (!File(abiDir, "node").exists()) {
                    val tarFile2 = File(abiDir, "node.tar.xz")
                    ant.withGroovyBuilder {
                        "get"("src" to url, "dest" to tarFile2, "verbose" to true)
                    }
                    val proc2 = ProcessBuilder("tar", "-xJf", tarFile2.absolutePath, "-C", abiDir.absolutePath)
                        .directory(abiDir)
                        .redirectErrorStream(true)
                        .start()
                    proc2.inputStream.bufferedReader().use { it.lines().forEach { line -> logger.lifecycle(line) } }
                    proc2.waitFor()
                    tarFile2.delete()
                }
            }

            // 找到解压出来的 node 二进制，重命名为 libnode.so
            val extractedNode = File(abiDir, "node")
            if (extractedNode.exists()) {
                extractedNode.renameTo(libNode)
                logger.lifecycle("[Node.js] 重命名 node → libnode.so")
            } else {
                // 可能在子目录中
                abiDir.walk().find { it.name == "node" && it.isFile }?.let { found ->
                    found.copyTo(libNode, overwrite = true)
                    found.delete()
                    logger.lifecycle("[Node.js] 找到并重命名 node → libnode.so")
                }
            }

            if (!libNode.exists()) {
                throw GradleException("[Node.js] ${abi} 二进制未找到，请检查下载和解压")
            }

            // 写入版本标记
            versionFile.writeText(nodeVersion)

            // 清理多余文件
            abiDir.listFiles()?.filter { it.name != "libnode.so" && it.name != ".node_version" }?.forEach {
                if (it.isDirectory) it.deleteRecursively() else it.delete()
            }

            logger.lifecycle("[Node.js] ${abi} 完成: ${libNode.absolutePath} (${libNode.length() / 1024 / 1024}MB)")
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
