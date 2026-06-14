package com.mr.app

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/**
 * 内置 Node.js 运行时管理器
 *
 * 构建时：Node.js 二进制伪装为 libnode.so 放入 jniLibs/
 *   → Android 安装 APK 时自动解压到 /data/data/.../lib/arm64/libnode.so
 *   → 自动设置可执行权限，无需运行时解压
 *
 * 运行时：直接找到 libnode.so 并启动，零额外开销
 *
 * JS 脚本：首次运行从 assets 解压到内部存储并缓存，后续直接使用
 */
class NodeRuntime(private val context: Context) {

    companion object {
        private const val TAG = "NodeRuntime"
        private const val SCRIPTS_DIR = "node_scripts"
        private const val SCRIPTS_VERSION = "v1" // 脚本版本，变更时重新解压
    }

    private var nodeProcess: Process? = null
    private var proxyPort: Int = 0
    private var apiPort: Int = 0

    val isRunning: Boolean
        get() = nodeProcess?.isAlive == true

    val currentProxyPort: Int
        get() = proxyPort

    val currentApiPort: Int
        get() = apiPort

    /**
     * 获取 Node.js 可执行文件路径
     *
     * Android 安装 APK 时自动将 jniLibs/arm64-v8a/libnode.so
     * 解压到 /data/data/com.mr.app/lib/arm64/libnode.so
     * 并设置可执行权限，直接使用即可
     */
    fun getNodePath(): String? {
        // 方法1：从 applicationInfo.nativeLibraryDir 获取（推荐）
        val nativeLibDir = context.applicationInfo.nativeLibraryDir
        val libNode = File(nativeLibDir, "libnode.so")
        if (libNode.exists() && libNode.canExecute()) {
            Log.i(TAG, "Node.js 二进制: ${libNode.absolutePath}")
            return libNode.absolutePath
        }

        // 方法2：遍历 lib 目录查找
        val libDir = File(context.applicationInfo.dataDir, "lib")
        if (libDir.exists()) {
            val found = libDir.walk().find { it.name == "libnode.so" && it.canExecute() }
            if (found != null) {
                Log.i(TAG, "Node.js 二进制 (遍历): ${found.absolutePath}")
                return found.absolutePath
            }
        }

        Log.w(TAG, "Node.js 二进制未找到（libnode.so 不存在）")
        return null
    }

    /**
     * 确保 JS 脚本已解压到内部存储（首次运行时执行，后续跳过）
     */
    fun ensureScriptsReady(): String? {
        val scriptsDir = File(context.filesDir, SCRIPTS_DIR)
        val versionFile = File(scriptsDir, ".version")

        // 检查脚本是否已解压且版本匹配
        if (scriptsDir.exists() && versionFile.exists() && versionFile.readText().trim() == SCRIPTS_VERSION) {
            val proxyScript = File(scriptsDir, "cors-proxy.js")
            if (proxyScript.exists()) {
                Log.i(TAG, "JS 脚本已缓存，跳过解压")
                return scriptsDir.absolutePath
            }
        }

        // 首次运行：从 assets 解压脚本
        Log.i(TAG, "首次运行，解压 JS 脚本...")
        try {
            scriptsDir.mkdirs()
            copyAssetDir("node/scripts", scriptsDir)
            versionFile.writeText(SCRIPTS_VERSION)
            Log.i(TAG, "JS 脚本解压完成: ${scriptsDir.absolutePath}")
            return scriptsDir.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "JS 脚本解压失败: ${e.message}")
            return null
        }
    }

    /**
     * 启动 CORS 代理服务
     * 直接启动 Node.js，无需解压二进制
     */
    fun startProxy(): Boolean {
        if (nodeProcess?.isAlive == true) {
            Log.w(TAG, "Node.js 已在运行")
            return true
        }

        try {
            // 获取 Node.js 路径（Android 已自动解压，直接用）
            val nodePath = getNodePath()
            if (nodePath == null) {
                Log.e(TAG, "Node.js 二进制未找到，无法启动")
                return false
            }

            // 确保 JS 脚本已就绪
            val scriptsPath = ensureScriptsReady()
            if (scriptsPath == null) {
                Log.e(TAG, "JS 脚本未就绪，无法启动")
                return false
            }

            val proxyScript = File(scriptsPath, "cors-proxy.js")
            if (!proxyScript.exists()) {
                Log.e(TAG, "cors-proxy.js 不存在: ${proxyScript.absolutePath}")
                return false
            }

            Log.i(TAG, "启动 Node.js: $nodePath ${proxyScript.absolutePath}")

            val processBuilder = ProcessBuilder(nodePath, proxyScript.absolutePath)
            processBuilder.environment()["HOME"] = context.filesDir.absolutePath
            processBuilder.environment()["NODE_PATH"] = scriptsPath
            processBuilder.redirectErrorStream(false)

            nodeProcess = processBuilder.start()

            // 监听 stderr 解析端口
            Thread {
                try {
                    nodeProcess!!.errorStream.bufferedReader().use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            val trimmed = line?.trim() ?: continue
                            if (trimmed.startsWith("PROXY_PORT:")) {
                                proxyPort = trimmed.substring(11).toIntOrNull() ?: 0
                                Log.i(TAG, "代理端口: $proxyPort")
                            } else if (trimmed.startsWith("API_PORT:")) {
                                apiPort = trimmed.substring(9).toIntOrNull() ?: 0
                                Log.i(TAG, "API 端口: $apiPort")
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "stderr 读取失败: ${e.message}")
                }
            }.start()

            // 监听 stdout
            Thread {
                try {
                    nodeProcess!!.inputStream.bufferedReader().use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            Log.d(TAG, "[Node] $line")
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "stdout 读取失败: ${e.message}")
                }
            }.start()

            // 等待端口就绪（最多 5 秒）
            for (i in 1..50) {
                Thread.sleep(100)
                if (proxyPort > 0 && apiPort > 0) {
                    Log.i(TAG, "Node.js 就绪: proxy=$proxyPort, api=$apiPort")
                    return true
                }
            }

            Log.w(TAG, "Node.js 启动超时，进程状态: alive=${nodeProcess?.isAlive}")
            return nodeProcess?.isAlive == true
        } catch (e: Exception) {
            Log.e(TAG, "Node.js 启动失败: ${e.message}")
            return false
        }
    }

    /**
     * 停止 Node.js 进程
     */
    fun stop() {
        try {
            nodeProcess?.destroy()
            nodeProcess = null
            proxyPort = 0
            apiPort = 0
            Log.i(TAG, "Node.js 已停止")
        } catch (e: Exception) {
            Log.e(TAG, "Node.js 停止失败: ${e.message}")
        }
    }

    // ===== 辅助方法 =====

    /**
     * 递归复制 asset 目录到目标目录
     */
    private fun copyAssetDir(assetDir: String, targetDir: File) {
        val files: Array<String>? = try {
            context.assets.list(assetDir)
        } catch (e: Exception) {
            null
        }

        if (files == null || files.isEmpty()) {
            // 可能是文件
            if (assetDir.contains("/")) {
                val fileName = assetDir.substringAfterLast("/")
                val targetFile = File(targetDir, fileName)
                try {
                    copyAssetFile(assetDir, targetFile)
                } catch (e: Exception) {
                    Log.w(TAG, "跳过: $assetDir")
                }
            }
            return
        }

        for (file in files) {
            val assetFilePath = "$assetDir/$file"
            val targetFile = File(targetDir, file)

            val subFiles = try {
                context.assets.list(assetFilePath)
            } catch (e: Exception) {
                null
            }

            if (subFiles != null && subFiles.isNotEmpty()) {
                targetFile.mkdirs()
                copyAssetDir(assetFilePath, targetFile)
            } else {
                try {
                    copyAssetFile(assetFilePath, targetFile)
                } catch (e: Exception) {
                    Log.w(TAG, "跳过: $assetFilePath")
                }
            }
        }
    }

    private fun copyAssetFile(assetPath: String, target: File) {
        context.assets.open(assetPath).use { input ->
            FileOutputStream(target).use { output ->
                input.copyTo(output)
            }
        }
    }

    /**
     * 初始化 Node.js 运行环境（获取二进制路径 + 确保脚本就绪）
     * @return Node.js 可执行文件路径，失败返回 null
     */
    fun setup(): String? {
        val nodePath = getNodePath()
        if (nodePath == null) {
            Log.w(TAG, "Node.js 二进制未找到，setup 失败")
            return null
        }
        val scriptsPath = ensureScriptsReady()
        if (scriptsPath == null) {
            Log.w(TAG, "JS 脚本未就绪，setup 失败")
            return null
        }
        Log.i(TAG, "Node.js 环境就绪: node=$nodePath, scripts=$scriptsPath")
        return nodePath
    }
}
