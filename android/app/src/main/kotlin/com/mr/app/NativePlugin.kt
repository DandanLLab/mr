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
import java.lang.Exception

/**
 * Android 原生桥接插件（精简版）
 *
 * 仅保留平台特有 API：
 * - 屏幕亮度（getScreenBrightness / setScreenBrightness）
 * - WebView JS 执行（executeWebViewJs）
 * - Cookie 获取（getCookie）
 * - 设备信息（getDeviceInfo）
 *
 * HTTP 请求 → Dart Dio
 * 加密 → JS crypto-js
 * HTML 解析 → JS _JsoupLite
 * TTS → flutter_tts 包
 */
class NativePlugin(private val context: Context) {

    companion object {
        private const val CHANNEL = "com.mr.app/native"
        private const val TAG = "NativePlugin"

        fun register(flutterEngine: FlutterEngine, context: Context) {
            MethodChannel(flutterEngine.dartExecutor as BinaryMessenger, CHANNEL)
                .setMethodCallHandler(NativePlugin(context).handler)
        }
    }

    val handler = { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
            "getScreenBrightness" -> getScreenBrightness(result)
            "setScreenBrightness" -> setScreenBrightness(call, result)
            "executeWebViewJs" -> executeWebViewJs(call, result)
            "getCookie" -> getCookie(call, result)
            "getDeviceInfo" -> getDeviceInfo(result)
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

    // ===== Cookie =====

    @Suppress("UNUSED_PARAMETER")
    private fun getCookie(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url") ?: ""
        val key = call.argument<String>("key")
        try {
            val cookieStr = android.webkit.CookieManager.getInstance().getCookie(url) ?: ""
            if (key.isNullOrEmpty()) {
                result.success(cookieStr)
            } else {
                val match = Regex("(?:^|;\\s*)$key=([^;]+)").find(cookieStr)
                result.success(match?.groupValues?.get(1) ?: "")
            }
        } catch (e: Exception) {
            result.success("")
        }
    }

    // ===== 设备信息 =====

    private fun getDeviceInfo(result: MethodChannel.Result) {
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

    // ===== WebView JS 执行 =====

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
                                                    .trimStart('"').trimEnd('"')
                                                    .replace("\\u003C", "<").replace("\\u003E", ">")
                                                    .replace("\\/", "/").replace("\\n", "\n")
                                                    .replace("\\t", "\t").replace("\\\"", "\"")
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
}
