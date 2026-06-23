package com.mr.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var sharedText: String? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativePlugin.register(flutterEngine, this)

        // 注册分享文本通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.mr.app/share")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSharedText" -> {
                        if (sharedText != null) {
                            result.success(sharedText)
                            sharedText = null
                        } else {
                            pendingResult = result
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 处理启动Intent
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    ?: intent.getStringExtra(Intent.EXTRA_STREAM)
                if (text != null) {
                    sharedText = text
                    pendingResult?.success(text)
                    pendingResult = null
                }
            }
            Intent.ACTION_VIEW -> {
                val data = intent.data
                if (data != null) {
                    val text = data.toString()
                    sharedText = text
                    pendingResult?.success(text)
                    pendingResult = null
                }
            }
        }
    }
}
