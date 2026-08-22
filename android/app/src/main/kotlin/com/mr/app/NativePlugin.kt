package com.mr.app

import android.app.Activity
import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File

/**
 * Android 原生桥接插件（精简版）
 *
 * 架构原则：
 * • 网络请求由 Dart Dio 处理（PlatformBridge），不再经过 MethodChannel
 * • 加密/HTML 解析/编码转换由 C 层 FFI 直接处理
 * • 本插件仅保留平台强依赖 API：屏幕亮度、WebView、数据存储、设备信息
 *
 * 代码量从 698 行精简至 ~180 行，删除 16 个冗余方法。
 */
@Suppress("SpellCheckingInspection", "SetJavaScriptEnabled")
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

    private val sharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    val handler = { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
            // 屏幕亮度
            "getScreenBrightness" -> getScreenBrightness(result)
            "setScreenBrightness" -> setScreenBrightness(call, result)
            // 数据存储
            "putData" -> putData(call, result)
            "getData" -> getData(call, result)
            "deleteData" -> deleteData(call, result)
            // 设备信息
            "getDeviceInfo" -> getDeviceInfo(call, result)
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
                "manufacturer" to Build.MANUFACTURER,
                "hardware" to Build.HARDWARE
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
