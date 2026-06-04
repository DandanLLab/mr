package com.example.dan_shenqi

import android.content.Context
import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.logging.HttpLoggingInterceptor
import org.jsoup.Jsoup
import org.jsoup.select.Elements
import org.json.JSONObject
import java.io.IOException
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Android 原生桥接插件
 * 集成 OkHttp（HTTP客户端）+ Jsoup（HTML解析）+ 加解密 + 数据持久化
 */
class NativePlugin(private val context: Context) {

    companion object {
        private const val CHANNEL = "com.example.dan_shenqi/native"
        private const val TAG = "NativePlugin"
        private const val PREFS_NAME = "native_plugin_data"

        fun register(flutterEngine: FlutterEngine, context: Context) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler(NativePlugin(context).handler)
        }
    }

    // 协程作用域：网络请求在 IO 线程执行，避免阻塞主线程
    private val coroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // 内置 Node.js 运行时
    private val nodeRuntime by lazy { NodeRuntime(context) }

    // SharedPreferences 用于键值对存储
    private val sharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // OkHttp 客户端（带缓存和日志）
    private val okHttpClient: OkHttpClient by lazy {
        val loggingInterceptor = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BASIC
        }

        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .addInterceptor(loggingInterceptor)
            .cache(Cache(context.cacheDir.resolve("okhttp_cache"), 50 * 1024 * 1024))
            .build()
    }

    // 带缓存的 OkHttp 客户端
    private val cachedClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .cache(Cache(context.cacheDir.resolve("okhttp_cache"), 50 * 1024 * 1024))
            .build()
    }

    val handler = { call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result ->
        when (call.method) {
            "httpGet" -> httpGet(call, result)
            "httpPost" -> httpPost(call, result)
            "httpGetWithCache" -> httpGetWithCache(call, result)
            "jsoupSelect" -> jsoupSelect(call, result)
            "jsoupSelectAll" -> jsoupSelectAll(call, result)
            "jsoupGetAttr" -> jsoupGetAttr(call, result)
            "jsoupClean" -> jsoupClean(call, result)
            "evaluateJavaRule" -> evaluateJavaRule(call, result)
            "jsoupParseUrl" -> jsoupParseUrl(call, result)
            "jsoupGetLinks" -> jsoupGetLinks(call, result)
            "httpDownload" -> httpDownload(call, result)
            "aesEncrypt" -> aesEncrypt(call, result)
            "aesDecrypt" -> aesDecrypt(call, result)
            "md5" -> md5(call, result)
            "base64Encode" -> base64Encode(call, result)
            "base64Decode" -> base64Decode(call, result)
            "executeScript" -> executeScript(call, result)
            "putData" -> putData(call, result)
            "getData" -> getData(call, result)
            "deleteData" -> deleteData(call, result)
            // 内置 Node.js 运行时
            "nodeSetup" -> nodeSetup(call, result)
            "nodeStartProxy" -> nodeStartProxy(call, result)
            "nodeStop" -> nodeStop(call, result)
            "nodeStatus" -> nodeStatus(call, result)
            else -> result.notImplemented()
        }
    }

    // ===== OkHttp 方法 =====

    private fun httpGet(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 10000

        coroutineScope.launch {
            try {
                val requestBuilder = Request.Builder().url(url)
                headers.forEach { (key, value) -> requestBuilder.addHeader(key, value) }

                val client = okHttpClient.newBuilder()
                    .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                    .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                    .followRedirects(true)
                    .followSslRedirects(true)
                    .build()

                val response = client.newCall(requestBuilder.build()).execute()
                val responseBody = response.body?.string()
                Log.d(TAG, "httpGet: $url → ${response.code} (${responseBody?.length ?: 0} chars)")
                withContext(Dispatchers.Main) {
                    if (response.isSuccessful || responseBody != null) {
                        result.success(responseBody ?: "")
                    } else {
                        result.success("")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "httpGet failed: $url → ${e.message}")
                withContext(Dispatchers.Main) {
                    result.success("")
                }
            }
        }
    }

    private fun httpPost(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val body = call.argument<String>("body") ?: ""
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 10000

        coroutineScope.launch {
            try {
                val contentType = headers["Content-Type"]?.toMediaType()
                    ?: "application/x-www-form-urlencoded".toMediaType()
                val requestBody = body.toRequestBody(contentType)
                val requestBuilder = Request.Builder().url(url).post(requestBody)
                headers.forEach { (key, value) -> requestBuilder.addHeader(key, value) }

                val client = okHttpClient.newBuilder()
                    .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                    .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                    .followRedirects(true)
                    .followSslRedirects(true)
                    .build()

                val response = client.newCall(requestBuilder.build()).execute()
                val responseBody = response.body?.string()
                Log.d(TAG, "httpPost: $url → ${response.code} (${responseBody?.length ?: 0} chars)")
                withContext(Dispatchers.Main) {
                    if (response.isSuccessful || responseBody != null) {
                        result.success(responseBody ?: "")
                    } else {
                        result.success("")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "httpPost failed: $url → ${e.message}")
                withContext(Dispatchers.Main) {
                    result.success("")
                }
            }
        }
    }

    private fun httpGetWithCache(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()

        coroutineScope.launch {
            try {
                val requestBuilder = Request.Builder().url(url)
                    .cacheControl(CacheControl.Builder().maxStale(3600, TimeUnit.SECONDS).build())
                headers.forEach { (key, value) -> requestBuilder.addHeader(key, value) }

                val response = cachedClient.newCall(requestBuilder.build()).execute()
                val responseBody = response.body?.string()
                withContext(Dispatchers.Main) {
                    if (response.isSuccessful) {
                        result.success(responseBody ?: "")
                    } else {
                        result.success("")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "httpGetWithCache failed: $url → ${e.message}")
                withContext(Dispatchers.Main) {
                    result.success("")
                }
            }
        }
    }

    // ===== Jsoup 方法 =====

    private fun jsoupSelect(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)
            val selector = call.argument<String>("selector") ?: return result.error("ERROR", "selector is required", null)

            val doc = Jsoup.parse(html)
            val element = doc.selectFirst(selector)
            result.success(element?.text())
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun jsoupSelectAll(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)
            val selector = call.argument<String>("selector") ?: return result.error("ERROR", "selector is required", null)

            val doc = Jsoup.parse(html)
            val elements = doc.select(selector)
            result.success(elements.map { it.text() })
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun jsoupGetAttr(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)
            val selector = call.argument<String>("selector") ?: return result.error("ERROR", "selector is required", null)
            val attr = call.argument<String>("attr") ?: return result.error("ERROR", "attr is required", null)

            val doc = Jsoup.parse(html)
            val element = doc.selectFirst(selector)
            result.success(element?.attr(attr))
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun jsoupClean(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)

            val doc = Jsoup.parse(html)
            // 移除脚本和样式
            doc.select("script, style, noscript").remove()
            // 移除隐藏元素
            doc.select("[style*=\"display:none\"], [style*=\"display: none\"]").remove()
            result.success(doc.body()?.html())
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== 新增桥接方法 =====

    /**
     * 执行 Java 规则代码
     * 通过 Jsoup + OkHttp 组合执行书源规则，支持反射调用
     */
    private fun evaluateJavaRule(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        val code = call.argument<String>("code")
        if (code.isNullOrEmpty()) {
            result.error("ERROR", "code is required", null)
            return
        }
        val existingResult = call.argument<String>("result") ?: ""
        val env = call.argument<Map<String, Any>>("env") ?: emptyMap()

        coroutineScope.launch {
            try {
                // 构建规则执行环境
                val url = env["url"] as? String
                val html = env["html"] as? String
                val selector = env["selector"] as? String

                var ruleResult = existingResult

                // 如果提供了 URL，先获取 HTML
                val targetHtml = if (!html.isNullOrEmpty()) {
                    html
                } else if (!url.isNullOrEmpty()) {
                    try {
                        val request = Request.Builder().url(url).build()
                        val response = okHttpClient.newCall(request).execute()
                        response.body?.string() ?: ""
                    } catch (e: Exception) {
                        Log.e(TAG, "evaluateJavaRule: failed to fetch url", e)
                        ""
                    }
                } else {
                    ""
                }

                // 解析规则代码：支持简单的选择器规则
                val doc = if (targetHtml.isNotEmpty()) Jsoup.parse(targetHtml) else null

                ruleResult = when {
                    code.startsWith("@css:") -> {
                        val cssSelector = code.substring(5).trim()
                        doc?.selectFirst(cssSelector)?.text() ?: ""
                    }
                    code.startsWith("@text:") -> {
                        val textSelector = code.substring(6).trim()
                        doc?.select(textSelector)?.map { it.text() }?.joinToString("\n") ?: ""
                    }
                    code.startsWith("@attr:") -> {
                        val parts = code.substring(6).trim().split("|")
                        val sel = parts.getOrNull(0) ?: ""
                        val attrName = parts.getOrNull(1) ?: ""
                        doc?.selectFirst(sel)?.attr(attrName) ?: ""
                    }
                    code.startsWith("@js:") || code.startsWith("javascript:") -> {
                        val jsCode = if (code.startsWith("@js:")) code.substring(4) else code.substring(11)
                        executeJsRule(jsCode, targetHtml, ruleResult, env)
                    }
                    code.startsWith("java:") -> {
                        val className = code.substring(5).trim()
                        try {
                            val clazz = Class.forName(className)
                            val method = clazz.getMethod("evaluate", String::class.java, Map::class.java)
                            method.invoke(null, targetHtml, env) as? String ?: ""
                        } catch (e: Exception) {
                            Log.e(TAG, "evaluateJavaRule: reflection failed", e)
                            ""
                        }
                    }
                    else -> {
                        doc?.selectFirst(code)?.text() ?: existingResult
                    }
                }

                withContext(Dispatchers.Main) {
                    result.success(ruleResult)
                }
            } catch (e: Exception) {
                Log.e(TAG, "evaluateJavaRule failed: ${e.message}")
                withContext(Dispatchers.Main) {
                    result.success("")
                }
            }
        }
    }

    /**
     * 简易 JS 规则执行（通过 Rhino 引擎）
     */
    private fun executeJsRule(jsCode: String, html: String, currentResult: String, env: Map<String, Any>): String {
        // 基础变量替换
        var code = jsCode
            .replace("\${result}", currentResult)
            .replace("\${html}", html)
        env.forEach { (key, value) ->
            code = code.replace("\${$key}", value.toString())
        }

        // 通过 Rhino 执行 JS
        try {
            val cx = org.mozilla.javascript.Context.enter()
            val scope = cx.initStandardObjects()
            org.mozilla.javascript.ScriptableObject.putProperty(scope, "result", currentResult)
            org.mozilla.javascript.ScriptableObject.putProperty(scope, "html", html)
            env.forEach { (key, value) ->
                org.mozilla.javascript.ScriptableObject.putProperty(scope, key, value)
            }
            val evalResult = cx.evaluateString(scope, code, "<jsRule>", 1, null)
            return org.mozilla.javascript.Context.toString(evalResult)
        } catch (e: Exception) {
            Log.w(TAG, "executeJsRule: rhino eval failed", e)
        } finally {
            org.mozilla.javascript.Context.exit()
        }

        // 降级：返回替换后的字符串
        return code
    }

    /**
     * 从 URL 直接解析 HTML（Jsoup.connect）
     */
    private fun jsoupParseUrl(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val selector = call.argument<String>("selector")

        coroutineScope.launch {
            try {
                val connection = Jsoup.connect(url)
                    .userAgent("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Mobile Safari/537.36")
                    .timeout(15000)
                    .ignoreContentType(true)

                headers.forEach { (key, value) -> connection.header(key, value) }

                val doc = connection.get()

                val parseResult = if (!selector.isNullOrEmpty()) {
                    val elements = doc.select(selector)
                    elements.map { it.outerHtml() }.joinToString("\n")
                } else {
                    doc.html()
                }

                withContext(Dispatchers.Main) {
                    result.success(parseResult)
                }
            } catch (e: Exception) {
                Log.w(TAG, "jsoupParseUrl failed: $url → ${e.message}")
                withContext(Dispatchers.Main) {
                    result.success("")
                }
            }
        }
    }

    /**
     * 获取所有链接
     */
    private fun jsoupGetLinks(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)
            val baseUrl = call.argument<String>("baseUrl") ?: ""

            val doc = Jsoup.parse(html)
            if (baseUrl.isNotEmpty()) {
                doc.setBaseUri(baseUrl)
            }

            val links = doc.select("a[href]").map { el ->
                el.attr("abs:href")
            }.filter { it.isNotEmpty() }

            result.success(links)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * 下载文件到本地
     */
    private fun httpDownload(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val url = call.argument<String>("url") ?: return result.error("ERROR", "url is required", null)
            val savePath = call.argument<String>("savePath") ?: return result.error("ERROR", "savePath is required", null)
            val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()

            val requestBuilder = Request.Builder().url(url)
            headers.forEach { (key, value) -> requestBuilder.addHeader(key, value) }

            val response = okHttpClient.newCall(requestBuilder.build()).execute()
            if (!response.isSuccessful) {
                return result.error("HTTP_ERROR", "HTTP ${response.code}", null)
            }

            val body = response.body ?: return result.error("ERROR", "Empty response body", null)
            val file = File(savePath)
            file.parentFile?.mkdirs()
            file.outputStream().use { output ->
                body.byteStream().use { input ->
                    val buffer = ByteArray(8192)
                    var bytesRead: Int
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                    }
                }
            }

            result.success(file.absolutePath)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * AES 加密
     * 支持 AES-CBC（带 IV）和 AES-ECB（无 IV）
     */
    private fun aesEncrypt(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val data = call.argument<String>("data") ?: return result.error("ERROR", "data is required", null)
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)
            val iv = call.argument<String>("iv")

            val keyBytes = padKey(key.toByteArray(Charsets.UTF_8))
            val secretKeySpec = SecretKeySpec(keyBytes, "AES")

            val cipher = if (!iv.isNullOrEmpty()) {
                val ivBytes = padKey(iv.toByteArray(Charsets.UTF_8))
                Cipher.getInstance("AES/CBC/PKCS5Padding").apply {
                    init(Cipher.ENCRYPT_MODE, secretKeySpec, IvParameterSpec(ivBytes))
                }
            } else {
                Cipher.getInstance("AES/ECB/PKCS5Padding").apply {
                    init(Cipher.ENCRYPT_MODE, secretKeySpec)
                }
            }

            val encrypted = cipher.doFinal(data.toByteArray(Charsets.UTF_8))
            result.success(Base64.encodeToString(encrypted, Base64.NO_WRAP))
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * AES 解密
     * 支持 AES-CBC（带 IV）和 AES-ECB（无 IV）
     */
    private fun aesDecrypt(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val data = call.argument<String>("data") ?: return result.error("ERROR", "data is required", null)
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)
            val iv = call.argument<String>("iv")

            val keyBytes = padKey(key.toByteArray(Charsets.UTF_8))
            val secretKeySpec = SecretKeySpec(keyBytes, "AES")

            val cipher = if (!iv.isNullOrEmpty()) {
                val ivBytes = padKey(iv.toByteArray(Charsets.UTF_8))
                Cipher.getInstance("AES/CBC/PKCS5Padding").apply {
                    init(Cipher.DECRYPT_MODE, secretKeySpec, IvParameterSpec(ivBytes))
                }
            } else {
                Cipher.getInstance("AES/ECB/PKCS5Padding").apply {
                    init(Cipher.DECRYPT_MODE, secretKeySpec)
                }
            }

            val decoded = Base64.decode(data, Base64.NO_WRAP)
            val decrypted = cipher.doFinal(decoded)
            result.success(String(decrypted, Charsets.UTF_8))
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * 将 key/iv 字节数组填充到 16 字节（AES-128）
     */
    private fun padKey(keyBytes: ByteArray): ByteArray {
        val padded = ByteArray(16)
        val copyLen = minOf(keyBytes.size, 16)
        System.arraycopy(keyBytes, 0, padded, 0, copyLen)
        return padded
    }

    /**
     * MD5 哈希
     */
    private fun md5(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val data = call.argument<String>("data") ?: return result.error("ERROR", "data is required", null)

            val digest = MessageDigest.getInstance("MD5")
            val hashBytes = digest.digest(data.toByteArray(Charsets.UTF_8))
            val hexString = hashBytes.joinToString("") { "%02x".format(it) }
            result.success(hexString)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * Base64 编码
     */
    private fun base64Encode(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val data = call.argument<String>("data") ?: return result.error("ERROR", "data is required", null)

            val encoded = Base64.encodeToString(data.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            result.success(encoded)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * Base64 解码
     */
    private fun base64Decode(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val data = call.argument<String>("data") ?: return result.error("ERROR", "data is required", null)

            val decoded = Base64.decode(data, Base64.NO_WRAP)
            result.success(String(decoded, Charsets.UTF_8))
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * 执行 JavaScript 脚本（通过 Rhino 引擎）
     */
    private fun executeScript(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val script = call.argument<String>("script") ?: return result.error("ERROR", "script is required", null)
            val bindings = call.argument<Map<String, Any>>("bindings") ?: emptyMap()

            val cx = org.mozilla.javascript.Context.enter()
            try {
                val scope = cx.initStandardObjects()
                bindings.forEach { (key, value) ->
                    org.mozilla.javascript.ScriptableObject.putProperty(scope, key, value)
                }
                val evalResult = cx.evaluateString(scope, script, "<script>", 1, null)
                result.success(org.mozilla.javascript.Context.toString(evalResult))
            } finally {
                org.mozilla.javascript.Context.exit()
            }
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== SharedPreferences 键值对存储 =====

    /**
     * 存储键值对
     */
    private fun putData(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)
            val value = call.argument<String>("value") ?: return result.error("ERROR", "value is required", null)

            sharedPreferences.edit().putString(key, value).apply()
            result.success(null)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * 读取键值对
     */
    private fun getData(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)
            val defaultValue = call.argument<String>("defaultValue") ?: ""

            val value = sharedPreferences.getString(key, defaultValue)
            result.success(value)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    /**
     * 删除键值对
     */
    private fun deleteData(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)

            sharedPreferences.edit().remove(key).apply()
            result.success(null)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== 内置 Node.js 运行时 =====

    /**
     * 初始化 Node.js 运行环境（解压二进制 + 脚本）
     */
    private fun nodeSetup(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val nodePath = nodeRuntime.setup()
            if (nodePath != null) {
                result.success(nodePath)
            } else {
                result.error("NODE_ERROR", "Node.js 初始化失败", null)
            }
        } catch (e: Exception) {
            result.error("NODE_ERROR", e.message, null)
        }
    }

    /**
     * 启动内置 Node.js 代理服务（直接启动，无需解压二进制）
     */
    private fun nodeStartProxy(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            val success = nodeRuntime.startProxy()
            if (success) {
                result.success(mapOf(
                    "proxyPort" to nodeRuntime.currentProxyPort,
                    "apiPort" to nodeRuntime.currentApiPort,
                    "running" to true
                ))
            } else {
                result.error("NODE_ERROR", "Node.js 代理启动失败", null)
            }
        } catch (e: Exception) {
            result.error("NODE_ERROR", e.message, null)
        }
    }

    /**
     * 停止内置 Node.js 进程
     */
    private fun nodeStop(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            nodeRuntime.stop()
            result.success(true)
        } catch (e: Exception) {
            result.error("NODE_ERROR", e.message, null)
        }
    }

    /**
     * 获取内置 Node.js 运行状态
     */
    private fun nodeStatus(call: io.flutter.plugin.common.MethodCall, result: io.flutter.plugin.common.MethodChannel.Result) {
        try {
            result.success(mapOf(
                "running" to nodeRuntime.isRunning,
                "proxyPort" to nodeRuntime.currentProxyPort,
                "apiPort" to nodeRuntime.currentApiPort
            ))
        } catch (e: Exception) {
            result.error("NODE_ERROR", e.message, null)
        }
    }
}
