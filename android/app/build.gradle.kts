plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// ===== Node.js 内置运行时配置（已禁用 — 减少包体积）=====
// 如需恢复，取消注释并运行 ./gradlew :app:assembleNodeRuntime
/*
val nodeVersion = "v25.9.0"
val nodeBuildDir = layout.buildDirectory.dir("node-runtime").get().asFile
val jniLibsDir = file("src/main/jniLibs")
val assetsNodeDir = file("src/main/assets/node")
val projectRoot = file("../..")

val nodeDownloadUrls = mapOf(
    "arm64-v8a" to "https://unofficial-builds.nodejs.org/download/release/${nodeVersion}/node-${nodeVersion}-linux-arm64-musl.tar.xz",
    "x86_64" to "https://unofficial-builds.nodejs.org/download/release/${nodeVersion}/node-${nodeVersion}-linux-x64-musl.tar.xz",
)
*/

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

    // Node.js 已禁用，不再需要 noCompress
    // aaptOptions {
    //     noCompress.add("so")
    // }
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

// ===== Node.js 构建任务（已禁用 — 减少包体积）=====
// 如需恢复，取消注释并运行 ./gradlew :app:assembleNodeRuntime
/*
tasks.register("downloadNodeBinaries") { ... }
tasks.register("copyNodeScripts") { ... }
tasks.register("assembleNodeRuntime") { ... }
*/

// 保留原始任务定义供恢复参考（已注释）
/*
tasks.register("downloadNodeBinaries") {
    group = "node-runtime"
    description = "下载 Node.js 二进制到 jniLibs（伪装为 libnode.so）"
    outputs.upToDateWhen { true }

    doLast {
        val targetAbis = listOf("arm64-v8a")

        for (abi in targetAbis) {
            val url = nodeDownloadUrls[abi] ?: continue
            val abiDir = File(jniLibsDir, abi)
            val libNode = File(abiDir, "libnode.so")
            val versionFile = File(abiDir, ".node_version")

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

                if (tarFile.exists() && tarFile.length() > 0) {
                    logger.lifecycle("[Node.js] ${abi} 本地已存在 node.tar.xz (${tarFile.length() / 1024 / 1024}MB)，跳过下载，直接解压")
                } else {
                    logger.lifecycle("[Node.js] 下载 ${abi}: ${url}")
                    ant.withGroovyBuilder {
                        "get"("src" to url, "dest" to tarFile, "verbose" to true)
                    }
                }

                if (!tarFile.exists() || tarFile.length() == 0L) {
                    logger.warn("[Node.js] ${abi} 下载失败，跳过")
                    continue
                }

                logger.lifecycle("[Node.js] 解压 ${abi}...")
                val muslSuffix = if (abi == "arm64-v8a") "arm64-musl" else "x64-musl"
                val innerPath = "node-${nodeVersion}-linux-${muslSuffix}/bin/node"
                var extracted = false

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

                if (!extracted) {
                    try {
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

                tarFile.delete()

                if (!extracted) {
                    val foundNode = abiDir.walk().find { it.name == "node" && it.isFile && it.length() > 1000000 }
                    if (foundNode != null) {
                        extracted = true
                    }
                }

                val directNode = File(abiDir, "node")
                if (directNode.exists() && directNode.isFile) {
                    directNode.renameTo(libNode)
                    logger.lifecycle("[Node.js] 重命名 node → libnode.so")
                } else {
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
                    continue
                }

                versionFile.writeText(nodeVersion)

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
            }
        }
    }
}

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

// tasks.named("preBuild") {
//     dependsOn("assembleNodeRuntime")
// }
*/
