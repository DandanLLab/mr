package com.mr.app

import android.app.Activity
import android.content.Context
import android.os.Build
import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import okhttp3.Cache
import okhttp3.CacheControl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.logging.HttpLoggingInterceptor
import org.jsoup.Jsoup
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Android 原生桥接插件
 * 集成 OkHttp（HTTP客户端）+ Jsoup（HTML解析）+ 加解密 + 数据持久化
 *
 * JS 引擎已统一使用 QuickJS（Dart 侧 flutter_js），Rhino 引擎已移除。
 * 本插件仅提供原生桥接能力（HTTP/Jsoup/加密/设备/WebView），供 Dart 侧预缓存调用。
 */
@Suppress("SpellCheckingInspection", "ECBEncryption", "SetJavaScriptEnabled")
class NativePlugin(private val context: Context) {

    companion object {
        private const val CHANNEL = "com.mr.app/native"
        private const val TAG = "NativePlugin"
        private const val PREFS_NAME = "native_plugin_data"

        fun register(flutterEngine: FlutterEngine, context: Context) {
            MethodChannel(flutterEngine.dartExecutor as BinaryMessenger, CHANNEL)
                .setMethodCallHandler(NativePlugin(context).handler)
        }
    }

    // 协程作用域：网络请求在 IO 线程执行，避免阻塞主线程
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

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

    val handler = { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
            // HTTP 请求
            "httpGet" -> httpGet(call, result)
            "httpPost" -> httpPost(call, result)
            "httpGetWithCache" -> httpGetWithCache(call, result)
            "httpDownload" -> httpDownload(call, result)
            // Jsoup HTML 解析
            "jsoupSelect" -> jsoupSelect(call, result)
            "jsoupSelectAll" -> jsoupSelectAll(call, result)
            "jsoupGetAttr" -> jsoupGetAttr(call, result)
            "jsoupClean" -> jsoupClean(call, result)
            "jsoupParseUrl" -> jsoupParseUrl(call, result)
            "jsoupGetLinks" -> jsoupGetLinks(call, result)
            // 加解密
            "aesEncrypt" -> aesEncrypt(call, result)
            "aesDecrypt" -> aesDecrypt(call, result)
            "md5" -> md5(call, result)
            "base64Encode" -> base64Encode(call, result)
            "base64Decode" -> base64Decode(call, result)
            // 数据存储
            "putData" -> putData(call, result)
            "getData" -> getData(call, result)
            "deleteData" -> deleteData(call, result)
            // 设备信息
            "getDeviceInfo" -> getDeviceInfo(call, result)
            // 屏幕亮度
            "getScreenBrightness" -> getScreenBrightness(result)
            "setScreenBrightness" -> setScreenBrightness(call, result)
            // WebView JS 执行
            "executeWebViewJs" -> executeWebViewJs(call, result)
            // Native lib 完整性验证
            "checkNativeLib" -> checkNativeLib(call, result)
            else -> result.notImplemented()
        }
    }

    // ===== 屏幕亮度 =====

    private fun getScreenBrightness(result: MethodChannel.Result) {
        val activity = context as? Activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity is unavailable", null)
            return
        }
        activity.runOnUiThread {
            result.success(activity.window.attributes.screenBrightness.toDouble())
        }
    }

    private fun setScreenBrightness(call: MethodCall, result: MethodChannel.Result) {
        val activity = context as? Activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "Activity is unavailable", null)
            return
        }
        val value = call.argument<Number>("value")?.toFloat()
        if (value == null) {
            result.error("INVALID_VALUE", "value is required", null)
            return
        }
        activity.runOnUiThread {
            val attributes = activity.window.attributes
            attributes.screenBrightness = value.coerceIn(-1f, 1f)
            activity.window.attributes = attributes
            result.success(true)
        }
    }

    // ===== OkHttp 方法 =====

    private fun httpGet(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 10000

        pluginScope.launch {
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
                    result.success(responseBody ?: "")
                }
            } catch (e: Exception) {
                Log.w(TAG, "httpGet failed: $url → ${e.message}")
                withContext(Dispatchers.Main) {
                    result.success("")
                }
            }
        }
    }

    private fun httpPost(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val body = call.argument<String>("body") ?: ""
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 10000

        pluginScope.launch {
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
                    result.success(responseBody ?: "")
                }
            } catch (e: Exception) {
                Log.w(TAG, "httpPost failed: $url → ${e.message}")
                withContext(Dispatchers.Main) {
                    result.success("")
                }
            }
        }
    }

    private fun httpGetWithCache(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()

        pluginScope.launch {
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

    private fun jsoupSelect(call: MethodCall, result: MethodChannel.Result) {
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

    private fun jsoupSelectAll(call: MethodCall, result: MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)
            val selector = call.argument<String>("selector") ?: return result.error("ERROR", "selector is required", null)

            val doc = Jsoup.parse(html)
            val elements = doc.select(selector)
            result.success(elements.map { it.outerHtml() })
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun jsoupGetAttr(call: MethodCall, result: MethodChannel.Result) {
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

    private fun jsoupClean(call: MethodCall, result: MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)

            val doc = Jsoup.parse(html)
            doc.select("script, style, noscript").remove()
            doc.select("[style*=\"display:none\"], [style*=\"display: none\"]").remove()
            result.success(doc.body()?.html())
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun jsoupParseUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("ERROR", "url is required", null)
            return
        }
        val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()

        pluginScope.launch {
            try {
                val connection = Jsoup.connect(url)
                    .userAgent("Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Mobile Safari/537.36")
                    .timeout(15000)
                    .ignoreContentType(true)

                headers.forEach { (key, value) -> connection.header(key, value) }

                val doc = connection.get()

                val selector = call.argument<String>("selector")
                val parseResult = if (!selector.isNullOrEmpty()) {
                    doc.select(selector).joinToString("\n") { it.outerHtml() }
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

    private fun jsoupGetLinks(call: MethodCall, result: MethodChannel.Result) {
        try {
            val html = call.argument<String>("html") ?: return result.error("ERROR", "html is required", null)
            val baseUrl = call.argument<String>("baseUrl") ?: ""

            val doc = Jsoup.parse(html)
            if (baseUrl.isNotEmpty()) {
                doc.setBaseUri(baseUrl)
            }

            val links = doc.select("a[href]")
                .map { it.attr("abs:href") }
                .filter { it.isNotEmpty() }

            result.success(links)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== 文件下载 =====

    private fun httpDownload(call: MethodCall, result: MethodChannel.Result) {
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
            body.byteStream().use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var bytesRead = input.read(buffer)
                    while (bytesRead != -1) {
                        output.write(buffer, 0, bytesRead)
                        bytesRead = input.read(buffer)
                    }
                }
            }

            result.success(file.absolutePath)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== 加解密 =====

    private fun aesEncrypt(call: MethodCall, result: MethodChannel.Result) {
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

    private fun aesDecrypt(call: MethodCall, result: MethodChannel.Result) {
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

    private fun padKey(keyBytes: ByteArray): ByteArray {
        val padded = ByteArray(16)
        val copyLen = minOf(keyBytes.size, 16)
        System.arraycopy(keyBytes, 0, padded, 0, copyLen)
        return padded
    }

    private fun md5(call: MethodCall, result: MethodChannel.Result) {
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

    private fun base64Encode(call: MethodCall, result: MethodChannel.Result) {
        try {
            val data = call.argument<String>("data") ?: return result.error("ERROR", "data is required", null)

            val encoded = Base64.encodeToString(data.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            result.success(encoded)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun base64Decode(call: MethodCall, result: MethodChannel.Result) {
        try {
            val data = call.argument<String>("data") ?: return result.error("ERROR", "data is required", null)

            val decoded = Base64.decode(data, Base64.NO_WRAP)
            result.success(String(decoded, Charsets.UTF_8))
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== SharedPreferences 键值对存储 =====

    @Suppress("ApplySharedPref")
    private fun putData(call: MethodCall, result: MethodChannel.Result) {
        try {
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)
            val value = call.argument<String>("value") ?: return result.error("ERROR", "value is required", null)

            sharedPreferences.edit().putString(key, value).apply()
            result.success(null)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    private fun getData(call: MethodCall, result: MethodChannel.Result) {
        try {
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)
            val defaultValue = call.argument<String>("defaultValue") ?: ""

            val value = sharedPreferences.getString(key, defaultValue)
            result.success(value)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    @Suppress("ApplySharedPref")
    private fun deleteData(call: MethodCall, result: MethodChannel.Result) {
        try {
            val key = call.argument<String>("key") ?: return result.error("ERROR", "key is required", null)

            sharedPreferences.edit().remove(key).apply()
            result.success(null)
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== 设备信息 =====

    @Suppress("UNUSED_PARAMETER")
    private fun getDeviceInfo(call: MethodCall, result: MethodChannel.Result) {
        try {
            result.success(mapOf(
                "sdkInt" to Build.VERSION.SDK_INT,
                "release" to Build.VERSION.RELEASE,
                "brand" to Build.BRAND,
                "model" to Build.MODEL,
                "manufacturer" to Build.MANUFACTURER
            ))
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== WebView JS 执行（借鉴 legado 的 BackstageWebView）=====

    private fun executeWebViewJs(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: ""
        val jsCode = call.argument<String>("jsCode") ?: "document.documentElement.outerHTML"
        val sourceRegex = call.argument<String>("sourceRegex")
        val html = call.argument<String>("html")
        val delayTime = call.argument<Int>("delayTime") ?: 200

        if (url.isEmpty() && html.isNullOrEmpty()) {
            result.error("ERROR", "url or html is required", null)
            return
        }

        CoroutineScope(Dispatchers.Main).launch {
            try {
                val jsResult = withTimeoutOrNull(30000L) {
                    suspendCancellableCoroutine<String?> { cont ->
                        val webView = android.webkit.WebView(context).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            @Suppress("DEPRECATION")
                            settings.databaseEnabled = true
                            settings.loadWithOverviewMode = true
                            settings.useWideViewPort = true
                            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                        }

                        var isCompleted = false

                        webView.webViewClient = object : android.webkit.WebViewClient() {
                            override fun shouldInterceptRequest(
                                view: android.webkit.WebView?,
                                request: android.webkit.WebResourceRequest?
                            ): android.webkit.WebResourceResponse? {
                                if (!sourceRegex.isNullOrEmpty()) {
                                    val resUrl = request?.url?.toString() ?: ""
                                    try {
                                        if (resUrl.matches(Regex(sourceRegex))) {
                                            if (!isCompleted) {
                                                isCompleted = true
                                                CoroutineScope(Dispatchers.Main).launch {
                                                    webView.destroy()
                                                    cont.resumeWith(Result.success(resUrl))
                                                }
                                            }
                                        }
                                    } catch (e: Exception) {
                                        Log.w(TAG, "sourceRegex匹配失败: $e")
                                    }
                                }
                                return super.shouldInterceptRequest(view, request)
                            }

                            override fun onPageFinished(view: android.webkit.WebView?, pageUrl: String?) {
                                super.onPageFinished(view, pageUrl)
                                CoroutineScope(Dispatchers.Main).launch {
                                    delay(delayTime.toLong())
                                    if (!isCompleted) {
                                        webView.evaluateJavascript(jsCode) { evalResult ->
                                            isCompleted = true
                                            webView.destroy()
                                            if (evalResult != null && evalResult != "null") {
                                                val cleanResult = evalResult
                                                    .trimStart('"')
                                                    .trimEnd('"')
                                                    .replace("\\u003C", "<")
                                                    .replace("\\u003E", ">")
                                                    .replace("\\/", "/")
                                                    .replace("\\n", "\n")
                                                    .replace("\\t", "\t")
                                                    .replace("\\\"", "\"")
                                                cont.resumeWith(Result.success(cleanResult))
                                            } else {
                                                cont.resumeWith(Result.success(null))
                                            }
                                        }
                                    }
                                }
                            }

                            override fun onReceivedError(
                                view: android.webkit.WebView?,
                                request: android.webkit.WebResourceRequest?,
                                error: android.webkit.WebResourceError?
                            ) {
                                super.onReceivedError(view, request, error)
                                if (!isCompleted) {
                                    isCompleted = true
                                    webView.destroy()
                                    cont.resumeWith(Result.success(null))
                                }
                            }
                        }

                        if (!html.isNullOrEmpty()) {
                            webView.loadDataWithBaseURL(url, html, "text/html", "UTF-8", url)
                        } else {
                            webView.loadUrl(url)
                        }
                    }
                }
                result.success(jsResult)
            } catch (e: Exception) {
                result.error("WEBVIEW_ERROR", e.message, null)
            }
        }
    }

    // ===== Native lib 完整性验证（安全，不执行 FFI）=====

    @Suppress("UNUSED_PARAMETER")
    private fun checkNativeLib(call: MethodCall, result: MethodChannel.Result) {
        val libName = call.argument<String>("libName") ?: "quickjs_c_bridge"
        try {
            // 1. 文件系统检查：.so 是否存在于 nativeLibraryDir
            val nativeDir = context.applicationInfo.nativeLibraryDir
            val libFile = File(nativeDir, "lib${libName}.so")
            if (!libFile.exists()) {
                result.success(false)
                return
            }

            // 2. loadLibrary 安全验证（Java try/catch 可捕获 UnsatisfiedLinkError）
            System.loadLibrary(libName)
            result.success(true)
        } catch (e: UnsatisfiedLinkError) {
            Log.w(TAG, "native lib $libName 加载失败: ${e.message}")
            result.success(false)
        } catch (e: Exception) {
            Log.w(TAG, "checkNativeLib $libName 异常: ${e.message}")
            result.success(false)
        }
    }
}
