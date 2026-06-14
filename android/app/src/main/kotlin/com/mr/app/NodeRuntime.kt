package com.mr.app

// Node.js 运行时已禁用 — 减少包体积，移除 libnode.so 和相关脚本
// 如需恢复，取消注释下方代码并运行 ./gradlew :app:assembleNodeRuntime

/*
import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream

class NodeRuntime(private val context: Context) {

    companion object {
        private const val TAG = "NodeRuntime"
        private const val SCRIPTS_DIR = "node_scripts"
        private const val SCRIPTS_VERSION = "v1"
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

    fun getNodePath(): String? {
        val nativeLibDir = context.applicationInfo.nativeLibraryDir
        val libNode = File(nativeLibDir, "libnode.so")
        if (libNode.exists() && libNode.canExecute()) {
            Log.i(TAG, "Node.js 二进制: ${libNode.absolutePath}")
            return libNode.absolutePath
        }
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

    fun ensureScriptsReady(): String? {
        val scriptsDir = File(context.filesDir, SCRIPTS_DIR)
        val versionFile = File(scriptsDir, ".version")
        if (scriptsDir.exists() && versionFile.exists() && versionFile.readText().trim() == SCRIPTS_VERSION) {
            val proxyScript = File(scriptsDir, "cors-proxy.js")
            if (proxyScript.exists()) {
                Log.i(TAG, "JS 脚本已缓存，跳过解压")
                return scriptsDir.absolutePath
            }
        }
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

    fun startProxy(): Boolean {
        if (nodeProcess?.isAlive == true) {
            Log.w(TAG, "Node.js 已在运行")
            return true
        }
        try {
            val nodePath = getNodePath()
            if (nodePath == null) {
                Log.e(TAG, "Node.js 二进制未找到，无法启动")
                return false
            }
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

    private fun copyAssetDir(assetDir: String, targetDir: File) {
        val files: Array<String>? = try {
            context.assets.list(assetDir)
        } catch (e: Exception) {
            null
        }
        if (files == null || files.isEmpty()) {
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
*/
