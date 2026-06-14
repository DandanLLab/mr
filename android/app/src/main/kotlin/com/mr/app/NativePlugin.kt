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
import org.mozilla.javascript.BaseFunction
import org.mozilla.javascript.Context as RhinoContext
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import org.mozilla.javascript.Undefined
import org.mozilla.javascript.json.JsonParser
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

        /** 当前线程的 JS 日志缓存，供 java.log 写入，analyzeRuleGetStringList 返回时读取 */
        private val jsLogBuffer = ThreadLocal<ArrayList<String>>()
    }

    // 协程作用域：网络请求在 IO 线程执行，避免阻塞主线程
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

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

    val handler = { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
            "httpGet" -> httpGet(call, result)
            "httpPost" -> httpPost(call, result)
            "httpGetWithCache" -> httpGetWithCache(call, result)
            "jsoupSelect" -> jsoupSelect(call, result)
            "jsoupSelectAll" -> jsoupSelectAll(call, result)
            "jsoupGetAttr" -> jsoupGetAttr(call, result)
            "jsoupClean" -> jsoupClean(call, result)
            "evaluateJavaRule" -> evaluateJavaRule(call, result)
            // 解析规则桥接（直接对接 Dart AnalyzeRule）
            "analyzeRuleGetString" -> analyzeRuleGetString(call, result)
            "analyzeRuleGetStringList" -> analyzeRuleGetStringList(call, result)
            "analyzeRuleGetElements" -> analyzeRuleGetElements(call, result)
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
            "getDeviceInfo" -> getDeviceInfo(call, result)
            "getScreenBrightness" -> getScreenBrightness(result)
            "setScreenBrightness" -> setScreenBrightness(call, result)
            "executeWebViewJs" -> executeWebViewJs(call, result)
            // 内置 Node.js 运行时
            "nodeSetup" -> nodeSetup(call, result)
            "nodeStartProxy" -> nodeStartProxy(call, result)
            "nodeStop" -> nodeStop(call, result)
            "nodeStatus" -> nodeStatus(call, result)
            else -> result.notImplemented()
        }
    }

    // ===== OkHttp 方法 =====

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
            // 修正：返回 outerHtml 列表，而不是合并后的纯文本，否则后续无法进行二次提取
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
    private fun evaluateJavaRule(call: MethodCall, result: MethodChannel.Result) {
        val code = call.argument<String>("code")
        if (code.isNullOrEmpty()) {
            result.error("ERROR", "code is required", null)
            return
        }
        val existingResult = call.argument<String>("result") ?: ""
        val env = call.argument<Map<String, Any>>("env") ?: emptyMap()

        pluginScope.launch {
            try {
                // 构建规则执行环境
                val url = env["url"] as? String
                val html = env["html"] as? String

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

                // 提前返回空内容的情况，确保 doc 非空
                if (targetHtml.isEmpty()) {
                    withContext(Dispatchers.Main) {
                        result.success(existingResult)
                    }
                    return@launch
                }

                val doc = Jsoup.parse(targetHtml)

                val ruleResult = when {
                    code.startsWith("@css:") -> {
                        val cssSelector = code.substring(5).trim()
                        doc.selectFirst(cssSelector)?.text() ?: ""
                    }
                    code.startsWith("@text:") -> {
                        val textSelector = code.substring(6).trim()
                        doc.select(textSelector).joinToString("\n") { it.text() }
                    }
                    code.startsWith("@attr:") -> {
                        val parts = code.substring(6).trim().split("|")
                        val sel = parts.getOrNull(0) ?: ""
                        val attrName = parts.getOrNull(1) ?: ""
                        doc.selectFirst(sel)?.attr(attrName) ?: ""
                    }
                    code.startsWith("@js:") || code.startsWith("javascript:") -> {
                        val jsCode = if (code.startsWith("@js:")) code.substring(4) else code.substring(11)
                        executeJsRule(jsCode, targetHtml, existingResult, env)
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
                        doc.selectFirst(code)?.text() ?: existingResult
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
     * 把 JS 端传给 java.log() 的参数转成可读字符串。
     * - NativeArray：逐元素递归 stringify，包成 [a, b, c]
     * - Scriptable（普通对象）：尽量用 JSON.stringify，失败 fallback toString
     * - 其他：ScriptRuntime.toString（数字/布尔/字符串等都正常）
     * - null/undefined：显式输出 "null"/"undefined"
     */
    private fun stringifyJsArg(cx: RhinoContext, scope: Scriptable, arg: Any?): String {
        if (arg == null) return "null"
        if (arg === org.mozilla.javascript.Undefined.instance) return "undefined"
        return try {
            when (arg) {
                is org.mozilla.javascript.NativeArray -> {
                    val sb = StringBuilder("[")
                    val len = arg.length.toInt()
                    for (i in 0 until len) {
                        if (i > 0) sb.append(", ")
                        sb.append(stringifyJsArg(cx, scope, arg.get(i, arg)))
                    }
                    sb.append("]")
                    sb.toString()
                }
                is org.mozilla.javascript.NativeJavaObject -> {
                    val raw = arg.unwrap()
                    if (raw is List<*>) {
                        raw.joinToString(prefix = "[", postfix = "]") { it?.toString() ?: "null" }
                    } else raw?.toString() ?: "null"
                }
                is org.mozilla.javascript.Scriptable -> {
                    // 用 Rhino 自带 JSON.stringify
                    runCatching {
                        org.mozilla.javascript.NativeJSON.stringify(cx, scope, arg, null, null).toString()
                    }.getOrElse { org.mozilla.javascript.ScriptRuntime.toString(arg) }
                }
                else -> org.mozilla.javascript.ScriptRuntime.toString(arg)
            }
        } catch (_: Exception) {
            arg.toString()
        }
    }

    /**
     * 注入完整的 legado 风格 java 桥接对象到 Rhino 作用域
     * 借鉴 legado 的 JsExtensions，直接调用原生 JSoup 进行 HTML 解析
     */
    @Suppress("ApplySharedPref")
    private fun injectJavaBridge(
        cx: RhinoContext,
        scope: Scriptable,
        baseUrl: String = ""
    ) {
        val javaObj = cx.newObject(scope)

        // ===== 日志 =====
        val javaLogFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val sb = StringBuilder()
                for (arg in args) {
                    if (sb.isNotEmpty()) sb.append(" ")
                    sb.append(stringifyJsArg(cx, scope, arg))
                }
                val msg = sb.toString()
                Log.d("RhinoJava", msg)
                // 同步写入 JS 日志缓存，供 Dart 端 AppLogger 显示
                jsLogBuffer.get()?.add(msg)
                return Undefined.instance
            }
        }
        ScriptableObject.putProperty(javaObj, "log", javaLogFn)

        // ===== HTTP 请求 =====
        val ajaxFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val url = args.getOrNull(0)?.toString() ?: return ""
                val fullUrl = if (!url.startsWith("http") && baseUrl.isNotEmpty()) {
                    baseUrl.trimEnd('/') + "/" + url.trimStart('/')
                } else url
                return try {
                    val request = Request.Builder().url(fullUrl).build()
                    val response = okHttpClient.newCall(request).execute()
                    response.body?.string() ?: ""
                } catch (e: Exception) {
                    Log.w(TAG, "java.ajax failed: $fullUrl", e)
                    ""
                }
            }
        }
        ScriptableObject.putProperty(javaObj, "ajax", ajaxFn)
        ScriptableObject.putProperty(javaObj, "get", ajaxFn)

        val postFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val url = args.getOrNull(0)?.toString() ?: return ""
                val body = args.getOrNull(1)?.toString() ?: ""
                val fullUrl = if (!url.startsWith("http") && baseUrl.isNotEmpty()) {
                    baseUrl.trimEnd('/') + "/" + url.trimStart('/')
                } else url
                return try {
                    val contentType = "application/x-www-form-urlencoded".toMediaType()
                    val requestBody = body.toRequestBody(contentType)
                    val request = Request.Builder().url(fullUrl).post(requestBody).build()
                    val response = okHttpClient.newCall(request).execute()
                    response.body?.string() ?: ""
                } catch (e: Exception) {
                    Log.w(TAG, "java.post failed: $fullUrl", e)
                    ""
                }
            }
        }
        ScriptableObject.putProperty(javaObj, "post", postFn)

        // ===== HTML/JSON/XPath 规则解析（使用完整 AnalyzeRule 引擎）=====
        // java.getString(content, rule) 或 java.getString(rule) 单参数模式
        val getStringFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                var content: String
                var rule: String
                if (args.size < 2 || args[1] == null || args[1] == Undefined.instance) {
                    rule = args.getOrNull(0)?.toString() ?: return ""
                    content = try {
                        ScriptableObject.getProperty(scope, "result")?.toString() ?: ""
                    } catch (_: Exception) { "" }
                } else {
                    content = args.getOrNull(0)?.toString() ?: ""
                    rule = args.getOrNull(1)?.toString() ?: return content
                }
                if (rule.isEmpty()) return content
                try {
                    val analyzeRule = com.mr.app.analyzeRule.AnalyzeRule(
                        content = content,
                        baseUrl = baseUrl
                    )
                    analyzeRule.jsEvaluator = { jsStr, _ ->
                        try {
                            val cx2 = RhinoContext.enter()
                            try {
                                val scope2 = cx2.initStandardObjects()
                                ScriptableObject.putProperty(scope2, "result", content)
                                ScriptableObject.putProperty(scope2, "baseUrl", baseUrl ?: "")
                                ScriptableObject.putProperty(scope2, "java", javaObj)
                                ScriptableObject.putProperty(scope2, "source", ScriptableObject.getProperty(scope, "source"))
                                ScriptableObject.putProperty(scope2, "key", ScriptableObject.getProperty(scope, "key"))
                                val evalResult = cx2.evaluateString(scope2, jsStr, "<jsRule>", 1, null)
                                RhinoContext.toString(evalResult)
                            } finally {
                                RhinoContext.exit()
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "AnalyzeRule JS eval failed", e)
                            null
                        }
                    }
                    return analyzeRule.getString(rule) ?: ""
                } catch (e: Exception) {
                    Log.w(TAG, "java.getString AnalyzeRule failed: $rule", e)
                }
                return content
            }
        }
        ScriptableObject.putProperty(javaObj, "getString", getStringFn)
        ScriptableObject.putProperty(javaObj, "getStrResponse", getStringFn)

        // java.getElement(content, rule) 或 java.getElement(rule) 单参数模式
        val getElementFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                var content: String
                var rule: String
                if (args.size < 2 || args[1] == null || args[1] == Undefined.instance) {
                    rule = args.getOrNull(0)?.toString() ?: return ""
                    content = try {
                        ScriptableObject.getProperty(scope, "result")?.toString() ?: ""
                    } catch (_: Exception) { "" }
                } else {
                    content = args.getOrNull(0)?.toString() ?: ""
                    rule = args.getOrNull(1)?.toString() ?: return content
                }
                if (rule.isEmpty()) return content
                try {
                    val analyzeRule = com.mr.app.analyzeRule.AnalyzeRule(
                        content = content,
                        baseUrl = baseUrl
                    )
                    analyzeRule.jsEvaluator = { jsStr, _ ->
                        try {
                            val cx2 = RhinoContext.enter()
                            try {
                                val scope2 = cx2.initStandardObjects()
                                ScriptableObject.putProperty(scope2, "result", content)
                                ScriptableObject.putProperty(scope2, "baseUrl", baseUrl ?: "")
                                ScriptableObject.putProperty(scope2, "java", javaObj)
                                ScriptableObject.putProperty(scope2, "source", ScriptableObject.getProperty(scope, "source"))
                                ScriptableObject.putProperty(scope2, "key", ScriptableObject.getProperty(scope, "key"))
                                val evalResult = cx2.evaluateString(scope2, jsStr, "<jsRule>", 1, null)
                                RhinoContext.toString(evalResult)
                            } finally {
                                RhinoContext.exit()
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "AnalyzeRule JS eval failed", e)
                            null
                        }
                    }
                    val elements = analyzeRule.getElements(rule)
                    return if (elements.isNotEmpty()) elements[0].toString() else ""
                } catch (e: Exception) {
                    Log.w(TAG, "java.getElement AnalyzeRule failed: $rule", e)
                }
                return content
            }
        }
        ScriptableObject.putProperty(javaObj, "getElement", getElementFn)

        // java.getElements(content, rule) 或 java.getElements(rule) 单参数模式
        val getElementsFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                var content: String
                var rule: String
                if (args.size < 2 || args[1] == null || args[1] == Undefined.instance) {
                    rule = args.getOrNull(0)?.toString() ?: return cx.newArray(scope, 0)
                    content = try {
                        ScriptableObject.getProperty(scope, "result")?.toString() ?: ""
                    } catch (_: Exception) { "" }
                } else {
                    content = args.getOrNull(0)?.toString() ?: ""
                    rule = args.getOrNull(1)?.toString() ?: return cx.newArray(scope, 0)
                }
                if (rule.isEmpty()) return cx.newArray(scope, 0)
                try {
                    val analyzeRule = com.mr.app.analyzeRule.AnalyzeRule(
                        content = content,
                        baseUrl = baseUrl
                    )
                    analyzeRule.jsEvaluator = { jsStr, _ ->
                        try {
                            val cx2 = RhinoContext.enter()
                            try {
                                val scope2 = cx2.initStandardObjects()
                                ScriptableObject.putProperty(scope2, "result", content)
                                ScriptableObject.putProperty(scope2, "baseUrl", baseUrl ?: "")
                                ScriptableObject.putProperty(scope2, "java", javaObj)
                                ScriptableObject.putProperty(scope2, "source", ScriptableObject.getProperty(scope, "source"))
                                ScriptableObject.putProperty(scope2, "key", ScriptableObject.getProperty(scope, "key"))
                                val evalResult = cx2.evaluateString(scope2, jsStr, "<jsRule>", 1, null)
                                RhinoContext.toString(evalResult)
                            } finally {
                                RhinoContext.exit()
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "AnalyzeRule JS eval failed", e)
                            null
                        }
                    }
                    val elements = analyzeRule.getElements(rule)
                    val arr = cx.newArray(scope, elements.size)
                    for (i in elements.indices) {
                        ScriptableObject.putProperty(arr as Scriptable, i, elements[i].toString())
                    }
                    return arr
                } catch (e: Exception) {
                    Log.w(TAG, "java.getElements AnalyzeRule failed: $rule", e)
                }
                return cx.newArray(scope, 0)
            }
        }
        ScriptableObject.putProperty(javaObj, "getElements", getElementsFn)

        // ===== JSoup 直接访问 =====
        val jsoupObj = cx.newObject(scope)

        val jsoupSelectFirstFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val html = args.getOrNull(0)?.toString() ?: return ""
                val selector = args.getOrNull(1)?.toString() ?: return ""
                return try {
                    val doc = Jsoup.parse(html)
                    doc.selectFirst(selector)?.outerHtml() ?: ""
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(jsoupObj, "selectFirst", jsoupSelectFirstFn)

        val jsoupSelectAllFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val html = args.getOrNull(0)?.toString() ?: return cx.newArray(scope, 0)
                val selector = args.getOrNull(1)?.toString() ?: return cx.newArray(scope, 0)
                return try {
                    val doc = Jsoup.parse(html)
                    val elements = doc.select(selector)
                    val arr = cx.newArray(scope, elements.size)
                    for (i in 0 until elements.size) {
                        ScriptableObject.putProperty(arr as Scriptable, i, elements[i].outerHtml())
                    }
                    arr
                } catch (_: Exception) { cx.newArray(scope, 0) }
            }
        }
        ScriptableObject.putProperty(jsoupObj, "select", jsoupSelectAllFn)
        ScriptableObject.putProperty(jsoupObj, "selectAll", jsoupSelectAllFn)

        val jsoupGetAttrFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val html = args.getOrNull(0)?.toString() ?: return ""
                val selector = args.getOrNull(1)?.toString() ?: return ""
                val attr = args.getOrNull(2)?.toString() ?: return ""
                return try {
                    val doc = Jsoup.parse(html)
                    doc.selectFirst(selector)?.attr(attr) ?: ""
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(jsoupObj, "getAttr", jsoupGetAttrFn)

        val jsoupParseFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val html = args.getOrNull(0)?.toString() ?: return ""
                return try {
                    val doc = Jsoup.parse(html)
                    doc.body()?.html() ?: ""
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(jsoupObj, "parse", jsoupParseFn)

        val jsoupCleanFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val html = args.getOrNull(0)?.toString() ?: return ""
                return try {
                    val doc = Jsoup.parse(html)
                    doc.select("script, style, noscript").remove()
                    doc.body()?.html() ?: ""
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(jsoupObj, "clean", jsoupCleanFn)

        ScriptableObject.putProperty(javaObj, "jsoup", jsoupObj)

        // ===== 加解密 =====
        val aesEncodeFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val data = args.getOrNull(0)?.toString() ?: return ""
                val key = args.getOrNull(1)?.toString() ?: return ""
                val iv = args.getOrNull(2)?.toString() ?: ""
                return try {
                    val keyBytes = padKey(key.toByteArray(Charsets.UTF_8))
                    val secretKeySpec = SecretKeySpec(keyBytes, "AES")
                    val cipher = if (iv.isNotEmpty()) {
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
                    Base64.encodeToString(encrypted, Base64.NO_WRAP)
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(javaObj, "aesEncode", aesEncodeFn)
        ScriptableObject.putProperty(javaObj, "aesEncrypt", aesEncodeFn)

        val aesDecodeFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val data = args.getOrNull(0)?.toString() ?: return ""
                val key = args.getOrNull(1)?.toString() ?: return ""
                val iv = args.getOrNull(2)?.toString() ?: ""
                return try {
                    val keyBytes = padKey(key.toByteArray(Charsets.UTF_8))
                    val secretKeySpec = SecretKeySpec(keyBytes, "AES")
                    val cipher = if (iv.isNotEmpty()) {
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
                    String(decrypted, Charsets.UTF_8)
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(javaObj, "aesDecode", aesDecodeFn)
        ScriptableObject.putProperty(javaObj, "aesDecrypt", aesDecodeFn)

        val md5EncodeFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val str = args.getOrNull(0)?.toString() ?: return ""
                return try {
                    val digest = MessageDigest.getInstance("MD5")
                    val hashBytes = digest.digest(str.toByteArray(Charsets.UTF_8))
                    hashBytes.joinToString("") { "%02x".format(it) }
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(javaObj, "md5Encode", md5EncodeFn)

        val base64EncodeFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val str = args.getOrNull(0)?.toString() ?: return ""
                return Base64.encodeToString(str.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            }
        }
        ScriptableObject.putProperty(javaObj, "base64Encode", base64EncodeFn)

        val base64DecodeFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val str = args.getOrNull(0)?.toString() ?: return ""
                return try {
                    val decoded = Base64.decode(str, Base64.NO_WRAP)
                    String(decoded, Charsets.UTF_8)
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(javaObj, "base64Decode", base64DecodeFn)

        // ===== WebView（同步模式下无法真正渲染，返回空）=====
        val webViewFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                // Rhino 同步执行无法使用 WebView，返回空字符串
                // 如果需要 WebView，应通过 Dart 侧的 executeWebViewJs 方法
                return ""
            }
        }
        ScriptableObject.putProperty(javaObj, "webView", webViewFn)

        // ===== 缓存管理 =====
        val cacheObj = cx.newObject(scope)
        val cacheGetFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val key = args.getOrNull(0)?.toString() ?: return ""
                return sharedPreferences.getString("rhino_cache_$key", "") ?: ""
            }
        }
        ScriptableObject.putProperty(cacheObj, "get", cacheGetFn)
        val cachePutFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val key = args.getOrNull(0)?.toString() ?: return Undefined.instance
                val value = args.getOrNull(1)?.toString() ?: ""
                sharedPreferences.edit().putString("rhino_cache_$key", value).apply()
                return Undefined.instance
            }
        }
        ScriptableObject.putProperty(cacheObj, "put", cachePutFn)
        ScriptableObject.putProperty(javaObj, "cache", cacheObj)

        // ===== 变量存取（legado 兼容）=====
        val putFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val key = args.getOrNull(0)?.toString() ?: return Undefined.instance
                val value = args.getOrNull(1)?.toString() ?: ""
                sharedPreferences.edit().putString("rhino_var_$key", value).apply()
                return Undefined.instance
            }
        }
        ScriptableObject.putProperty(javaObj, "put", putFn)

        val getStrFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val key = args.getOrNull(0)?.toString() ?: return ""
                val default = args.getOrNull(1)?.toString() ?: ""
                return sharedPreferences.getString("rhino_var_$key", default) ?: default
            }
        }
        ScriptableObject.putProperty(javaObj, "getStr", getStrFn)

        // ===== JSON 工具 =====
        val getJsonFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val str = args.getOrNull(0)?.toString() ?: return cx.newObject(scope)
                return try {
                    JsonParser(cx, scope).parseValue(str)
                } catch (_: Exception) { cx.newObject(scope) }
            }
        }
        ScriptableObject.putProperty(javaObj, "getJson", getJsonFn)

        // ===== 时间工具 =====
        val getTimeFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                return System.currentTimeMillis()
            }
        }
        ScriptableObject.putProperty(javaObj, "getTime", getTimeFn)

        // ===== 编码工具 =====
        val encodeURIFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val str = args.getOrNull(0)?.toString() ?: return ""
                return java.net.URLEncoder.encode(str, "UTF-8")
            }
        }
        ScriptableObject.putProperty(javaObj, "encodeURI", encodeURIFn)

        // ===== hex 编码 =====
        val hexEncodeToStringFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val str = args.getOrNull(0)?.toString() ?: return ""
                return str.toByteArray(Charsets.UTF_8).joinToString("") { "%02x".format(it) }
            }
        }
        ScriptableObject.putProperty(javaObj, "hexEncodeToString", hexEncodeToStringFn)

        val hexDecodeToStringFn = object : BaseFunction() {
            override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                val hex = args.getOrNull(0)?.toString() ?: return ""
                return try {
                    val bytes = ByteArray(hex.length / 2) { i -> Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16).toByte() }
                    String(bytes, Charsets.UTF_8)
                } catch (_: Exception) { "" }
            }
        }
        ScriptableObject.putProperty(javaObj, "hexDecodeToString", hexDecodeToStringFn)

        // 注入到作用域
        ScriptableObject.putProperty(scope, "java", javaObj)
    }

    /**
     * 简易 JS 规则执行（通过 Rhino 引擎）
     */
    private fun executeJsRule(jsCode: String, html: String, currentResult: String, env: Map<String, Any>): String {
        try {
            val cx = RhinoContext.enter()
            val scope = cx.initStandardObjects()
            ScriptableObject.putProperty(scope, "result", currentResult)
            ScriptableObject.putProperty(scope, "html", html)
            env.forEach { (key, value) ->
                ScriptableObject.putProperty(scope, key, value)
            }
            // 注入 console 对象
            val consoleObj = cx.newObject(scope)
            val logFn = object : BaseFunction() {
                override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                    val sb = StringBuilder()
                    for (arg in args) { if (sb.isNotEmpty()) sb.append(" "); sb.append(arg?.toString() ?: "null") }
                    Log.d("RhinoConsole", sb.toString())
                    return Undefined.instance
                }
            }
            for (method in listOf("log", "info", "debug")) {
                ScriptableObject.putProperty(consoleObj, method, logFn)
            }
            val warnFn = object : BaseFunction() {
                override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                    val sb = StringBuilder()
                    for (arg in args) { if (sb.isNotEmpty()) sb.append(" "); sb.append(arg?.toString() ?: "null") }
                    Log.w("RhinoConsole", sb.toString())
                    return Undefined.instance
                }
            }
            ScriptableObject.putProperty(consoleObj, "warn", warnFn)
            val errorFn = object : BaseFunction() {
                override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                    val sb = StringBuilder()
                    for (arg in args) { if (sb.isNotEmpty()) sb.append(" "); sb.append(arg?.toString() ?: "null") }
                    Log.e("RhinoConsole", sb.toString())
                    return Undefined.instance
                }
            }
            ScriptableObject.putProperty(consoleObj, "error", errorFn)
            ScriptableObject.putProperty(scope, "console", consoleObj)

            // 注入完整的 java 桥接对象（使用原生 JSoup）
            val baseUrl = env["baseUrl"]?.toString() ?: ""
            injectJavaBridge(cx, scope, baseUrl)

            val evalResult = cx.evaluateString(scope, jsCode, "<jsRule>", 1, null)
            return RhinoContext.toString(evalResult)
        } catch (e: Exception) {
            Log.w(TAG, "executeJsRule: rhino eval failed", e)
        } finally {
            RhinoContext.exit()
        }
        return ""
    }

    /**
     * 从 URL 直接解析 HTML（Jsoup.connect）
     */
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

    /**
     * 获取所有链接
     */
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

    /**
     * 下载文件到本地
     */
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

    /**
     * AES 加密
     * 支持 AES-CBC（带 IV）和 AES-ECB（无 IV）
     */
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

    /**
     * AES 解密
     * 支持 AES-CBC（带 IV）和 AES-ECB（无 IV）
     */
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

    /**
     * Base64 编码
     */
    private fun base64Encode(call: MethodCall, result: MethodChannel.Result) {
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
    private fun base64Decode(call: MethodCall, result: MethodChannel.Result) {
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
    private fun executeScript(call: MethodCall, result: MethodChannel.Result) {
        try {
            val script = call.argument<String>("script") ?: return result.error("ERROR", "script is required", null)
            val bindings = call.argument<Map<String, Any>>("bindings") ?: emptyMap()

            val cx = RhinoContext.enter()
            try {
                val scope = cx.initStandardObjects()
                bindings.forEach { (key, value) ->
                    ScriptableObject.putProperty(scope, key, value)
                }
                // 注入 console 对象
                val consoleObj = cx.newObject(scope)
                val logFn = object : BaseFunction() {
                    override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                        val sb = StringBuilder()
                        for (arg in args) { if (sb.isNotEmpty()) sb.append(" "); sb.append(arg?.toString() ?: "null") }
                        Log.d("RhinoConsole", sb.toString())
                        return Undefined.instance
                    }
                }
                for (method in listOf("log", "info", "debug")) {
                    ScriptableObject.putProperty(consoleObj, method, logFn)
                }
                val warnFn = object : BaseFunction() {
                    override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                        val sb = StringBuilder()
                        for (arg in args) { if (sb.isNotEmpty()) sb.append(" "); sb.append(arg?.toString() ?: "null") }
                        Log.w("RhinoConsole", sb.toString())
                        return Undefined.instance
                    }
                }
                ScriptableObject.putProperty(consoleObj, "warn", warnFn)
                val errorFn = object : BaseFunction() {
                    override fun call(cx: RhinoContext, scope: Scriptable, thisObj: Scriptable?, args: Array<Any?>): Any {
                        val sb = StringBuilder()
                        for (arg in args) { if (sb.isNotEmpty()) sb.append(" "); sb.append(arg?.toString() ?: "null") }
                        Log.e("RhinoConsole", sb.toString())
                        return Undefined.instance
                    }
                }
                ScriptableObject.putProperty(consoleObj, "error", errorFn)
                ScriptableObject.putProperty(scope, "console", consoleObj)

                // 注入完整的 java 桥接对象（使用原生 JSoup）
                val baseUrl = bindings["baseUrl"]?.toString() ?: ""
                injectJavaBridge(cx, scope, baseUrl)

                val evalResult = cx.evaluateString(scope, script, "<script>", 1, null)
                result.success(RhinoContext.toString(evalResult))
            } finally {
                RhinoContext.exit()
            }
        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    // ===== SharedPreferences 键值对存储 =====

    /**
     * 存储键值对
     */
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

    /**
     * 读取键值对
     */
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

    /**
     * 删除键值对
     */
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

    /**
     * 获取设备信息（SDK版本、品牌、型号等）
     */
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

    /**
     * 在后台 WebView 中加载 URL 并执行 JS 代码
     * 借鉴 legado 的 BackstageWebView.getStrResponse()
     *
     * 流程：
     * 1. 创建后台 WebView
     * 2. 加载 URL（或直接加载 HTML）
     * 3. 页面加载完成后执行 JS 代码
     * 4. 返回 JS 执行结果
     * 5. 如果有 sourceRegex，嗅探匹配的资源 URL
     */
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

        // 使用主线程协程（WebView 必须在主线程操作）
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

                        // 合并 sourceRegex 嗅探和页面完成逻辑到一个 WebViewClient
                        webView.webViewClient = object : android.webkit.WebViewClient() {
                            // sourceRegex 嗅探（借鉴 legado 的 SnifferWebClient）
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
                                // 借鉴 legado 的 EvalJsRunnable：延迟执行 JS
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

                        // 加载页面
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

    // ===== 内置 Node.js 运行时 =====

    /**
     * 初始化 Node.js 运行环境（解压二进制 + 脚本）
     */
    @Suppress("UNUSED_PARAMETER")
    private fun nodeSetup(call: MethodCall, result: MethodChannel.Result) {
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
    @Suppress("UNUSED_PARAMETER")
    private fun nodeStartProxy(call: MethodCall, result: MethodChannel.Result) {
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
    @Suppress("UNUSED_PARAMETER")
    private fun nodeStop(call: MethodCall, result: MethodChannel.Result) {
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
    @Suppress("UNUSED_PARAMETER")
    private fun nodeStatus(call: MethodCall, result: MethodChannel.Result) {
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

    // ===== 解析规则桥接（直接对接 Dart AnalyzeRule）=====

    /**
     * 构建一个带 Rhino jsEvaluator 的 AnalyzeRule 实例
     * Dart 端只要传 content + baseUrl + rule，即可调用完整 legado 解析能力
     * 对齐 legado AnalyzeRule.evalJS 的绑定变量：src/result/baseUrl/source/book/chapter/nextChapterUrl
     */
    private fun buildAnalyzeRule(
        content: String,
        baseUrl: String?,
        redirectUrl: String? = null,
        sourceInfo: Map<String, Any?>? = null,
        bookInfo: Map<String, Any?>? = null,
        chapterInfo: Map<String, Any?>? = null,
        nextChapterUrl: String? = null,
    ): com.mr.app.analyzeRule.AnalyzeRule {
        val rule = com.mr.app.analyzeRule.AnalyzeRule(content = content, baseUrl = baseUrl)
        // 对齐 legado：setRedirectUrl 设置 HTTP 重定向后的实际 URL，
        // 用于 getAbsoluteURL 拼接相对路径时作为基准。
        if (!redirectUrl.isNullOrEmpty()) {
            rule.setRedirectUrl(redirectUrl)
        }
        // 对齐 legado AnalyzeRule：设置 source/book/chapter 上下文
        if (sourceInfo != null) rule.setSource(sourceInfo)
        if (bookInfo != null) rule.setBook(bookInfo)
        if (chapterInfo != null) rule.setChapter(chapterInfo)

        rule.jsEvaluator = { jsStr, res ->
            try {
                val cx = RhinoContext.enter()
                try {
                    val scope = cx.initStandardObjects()
                    // 关键修复：Java List 在 Rhino 中没有 .length 属性！
                    // 必须转成 NativeArray，这样 JS 中 result.length / result[0] 才能正常工作
                    val jsResult = when (res) {
                        is List<*> -> {
                            val arr = cx.newArray(scope, res.size)
                            for ((i, item) in res.withIndex()) {
                                arr.put(i, arr, item ?: "")
                            }
                            arr
                        }
                        else -> res ?: content
                    }
                    // ===== 对齐 legado AnalyzeRule.evalJS 的绑定变量 =====
                    ScriptableObject.putProperty(scope, "result", jsResult)
                    ScriptableObject.putProperty(scope, "baseUrl", baseUrl ?: "")
                    // src = content（HTML原文），legado JS 规则常用 src.match(...)
                    ScriptableObject.putProperty(scope, "src", content)
                    // source/book/chapter 上下文
                    if (sourceInfo != null) ScriptableObject.putProperty(scope, "source", sourceInfo)
                    if (bookInfo != null) ScriptableObject.putProperty(scope, "book", bookInfo)
                    if (chapterInfo != null) {
                        ScriptableObject.putProperty(scope, "chapter", chapterInfo)
                        // title = chapter.title，legado JS 常用
                        val title = chapterInfo["title"] as? String
                        if (title != null) ScriptableObject.putProperty(scope, "title", title)
                    }
                    if (!nextChapterUrl.isNullOrEmpty()) {
                        ScriptableObject.putProperty(scope, "nextChapterUrl", nextChapterUrl)
                    }
                    // injectJavaBridge：java.log/get/post
                    injectJavaBridge(cx, scope, baseUrl ?: "")
                    val evalResult = cx.evaluateString(scope, jsStr, "<jsRule>", 1, null)
                    Log.d(TAG, "JS eval: rule=[${jsStr.take(60)}...] resultType=${evalResult?.javaClass?.simpleName} resultPreview=${when(evalResult) { is List<*> -> "List(${evalResult.size})"; is org.mozilla.javascript.NativeArray -> "Array(${evalResult.length})"; else -> evalResult?.toString()?.take(80) }}")
                    // 关键：JS 返回数组时必须保留为 List 而非 toString，
                    // 否则 NativeArray.toString 会用逗号拼接，破坏 getStringList 的后续处理
                    when (evalResult) {
                        null -> null
                        org.mozilla.javascript.Undefined.instance -> null
                        is org.mozilla.javascript.NativeArray -> {
                            val list = ArrayList<String>(evalResult.length.toInt())
                            for (i in 0 until evalResult.length.toInt()) {
                                val item = evalResult.get(i, evalResult)
                                if (item != null && item != org.mozilla.javascript.Undefined.instance) {
                                    list.add(RhinoContext.toString(item))
                                }
                            }
                            list
                        }
                        is org.mozilla.javascript.NativeJavaObject -> evalResult.unwrap()
                        is List<*> -> evalResult
                        else -> RhinoContext.toString(evalResult)
                    }
                } finally {
                    RhinoContext.exit()
                }
            } catch (e: Exception) {
                Log.e(TAG, "analyzeRule JS eval failed: js=[${jsStr.take(100)}] resultType=${res?.javaClass?.simpleName} resultPreview=${res?.toString()?.take(80)}", e)
                null
            }
        }
        return rule
    }

    /** legado JS 桥的最小实现：java.log/get/post —— 当前只实现 log（最常用） */
    private class JsJavaBridge {
        fun log(msg: Any?): String {
            val s = msg?.toString() ?: "null"
            Log.d("AnalyzeRule.js", s)
            return s
        }
        fun toast(msg: Any?) { Log.i("AnalyzeRule.js", "toast: $msg") }
    }

    /** 单字符串提取：content + rule → String */
    private fun analyzeRuleGetString(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content") ?: ""
        val rule = call.argument<String>("rule") ?: ""
        val baseUrl = call.argument<String>("baseUrl")
        val redirectUrl = call.argument<String>("redirectUrl")
        val isUrl = call.argument<Boolean>("isUrl") ?: false
        val unescape = call.argument<Boolean>("unescape") ?: true
        val sourceInfo = call.argument<Map<String, Any?>>("sourceInfo")
        val bookInfo = call.argument<Map<String, Any?>>("bookInfo")
        val chapterInfo = call.argument<Map<String, Any?>>("chapterInfo")
        val nextChapterUrl = call.argument<String>("nextChapterUrl")
        if (rule.isEmpty()) {
            result.success(content)
            return
        }
        pluginScope.launch {
            val r: String = try {
                val ret = buildAnalyzeRule(content, baseUrl, redirectUrl,
                    sourceInfo = sourceInfo, bookInfo = bookInfo, chapterInfo = chapterInfo,
                    nextChapterUrl = nextChapterUrl
                ).getString(rule, isUrl = isUrl, unescape = unescape)
                // 强保证：必须返回 String，避免 MethodChannel 类型错误
                ret as? String ?: ret.toString()
            } catch (e: Throwable) {
                Log.e(TAG, "analyzeRuleGetString failed: rule=[$rule] baseUrl=[$baseUrl] contentLen=${content.length}", e)
                ""
            }
            withContext(Dispatchers.Main) { result.success(r) }
        }
    }

    /** 字符串列表提取：content + rule → List<String> */
    private fun analyzeRuleGetStringList(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content") ?: ""
        val rule = call.argument<String>("rule") ?: ""
        val baseUrl = call.argument<String>("baseUrl")
        val redirectUrl = call.argument<String>("redirectUrl")
        val isUrl = call.argument<Boolean>("isUrl") ?: false
        val sourceInfo = call.argument<Map<String, Any?>>("sourceInfo")
        val bookInfo = call.argument<Map<String, Any?>>("bookInfo")
        val chapterInfo = call.argument<Map<String, Any?>>("chapterInfo")
        val nextChapterUrl = call.argument<String>("nextChapterUrl")
        if (rule.isEmpty()) {
            result.success(mapOf("data" to emptyList<String>(), "logs" to emptyList<String>()))
            return
        }
        pluginScope.launch {
            // 初始化当前线程的 JS 日志缓存
            jsLogBuffer.set(ArrayList())
            val r: List<String> = try {
                val analyzeRule = buildAnalyzeRule(content, baseUrl, redirectUrl,
                    sourceInfo = sourceInfo, bookInfo = bookInfo, chapterInfo = chapterInfo,
                    nextChapterUrl = nextChapterUrl
                )
                val ret = analyzeRule.getStringList(rule, isUrl = isUrl)
                // 诊断日志：规则提取结果
                if (ret == null || ret.isEmpty()) {
                    Log.w(TAG, "analyzeRuleGetStringList EMPTY: rule=[$rule] baseUrl=[$baseUrl] contentLen=${content.length} contentPreview=${content.take(200)}")
                } else {
                    Log.d(TAG, "analyzeRuleGetStringList OK: rule=[$rule] count=${ret.size} first=${ret.firstOrNull()?.take(80)}")
                }
                // 强保证：必须返回 List<String>，避免 MethodChannel 类型错误
                when (ret) {
                    null -> emptyList()
                    is List<*> -> ret.mapNotNull { it?.toString() }
                    else -> listOf(ret.toString())
                }
            } catch (e: Throwable) {
                Log.e(TAG, "analyzeRuleGetStringList failed: rule=[$rule] baseUrl=[$baseUrl] contentLen=${content.length}", e)
                emptyList()
            }
            val logs = jsLogBuffer.get() ?: emptyList()
            jsLogBuffer.remove()
            withContext(Dispatchers.Main) { result.success(mapOf("data" to r, "logs" to logs)) }
        }
    }

    /** 元素列表提取：content + rule → List<String>（每个元素 toString/outerHtml） */
    private fun analyzeRuleGetElements(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content") ?: ""
        val rule = call.argument<String>("rule") ?: ""
        val baseUrl = call.argument<String>("baseUrl")
        val redirectUrl = call.argument<String>("redirectUrl")
        val sourceInfo = call.argument<Map<String, Any?>>("sourceInfo")
        val bookInfo = call.argument<Map<String, Any?>>("bookInfo")
        val chapterInfo = call.argument<Map<String, Any?>>("chapterInfo")
        val nextChapterUrl = call.argument<String>("nextChapterUrl")
        if (rule.isEmpty()) {
            result.success(emptyList<String>())
            return
        }
        pluginScope.launch {
            val r: List<String> = try {
                buildAnalyzeRule(content, baseUrl, redirectUrl,
                    sourceInfo = sourceInfo, bookInfo = bookInfo, chapterInfo = chapterInfo,
                    nextChapterUrl = nextChapterUrl
                ).getElements(rule).map { it.toString() }
            } catch (e: Exception) {
                Log.w(TAG, "analyzeRuleGetElements failed: $rule", e)
                emptyList()
            }
            withContext(Dispatchers.Main) { result.success(r) }
        }
    }
}
