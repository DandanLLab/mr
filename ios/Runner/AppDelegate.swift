import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

    private var sharedText: String?
    private var pendingShareResult: FlutterResult?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 注册 Flutter 插件（Swift 版 GeneratedPluginRegistrant）
        // Flutter 3.45 在启用 Swift Package Manager 时生成 Swift 版（.swift）
        // Swift API: @objc public static func register(with registry: FlutterPluginRegistry)
        GeneratedPluginRegistrant.register(with: self)

        // 调用 super，确保 FlutterAppDelegate 完成 window / rootViewController 初始化
        let didLaunch = super.application(application, didFinishLaunchingWithOptions: launchOptions)

        // 注册原生桥接插件（MethodChannel: com.mr.app/native）
        // 对应 Android 的 NativePlugin.register()
        if let controller = window?.rootViewController as? FlutterViewController {
            let nativeChannel = FlutterMethodChannel(
                name: NativePlugin.channelName,
                binaryMessenger: controller.binaryMessenger
            )
            let nativePlugin = NativePlugin()
            nativeChannel.setMethodCallHandler { call, result in
                nativePlugin.handle(call, result: result)
            }

            // 注册分享文本通道（MethodChannel: com.mr.app/share）
            // 对应 Android MainActivity 中的分享处理
            let shareChannel = FlutterMethodChannel(
                name: "com.mr.app/share",
                binaryMessenger: controller.binaryMessenger
            )
            shareChannel.setMethodCallHandler { [weak self] call, result in
                guard let self = self else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                switch call.method {
                case "getSharedText":
                    if let text = self.sharedText {
                        self.sharedText = nil
                        result(text)
                    } else {
                        self.pendingShareResult = result
                    }
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        }

        // 处理启动时的分享 Intent
        if let url = launchOptions?[.url] as? URL {
            handleOpenURL(url)
        }

        return didLaunch
    }

    // MARK: - URL Scheme 处理（接收其他 App 分享的链接）

    override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        handleOpenURL(url)
        return true
    }

    private func handleOpenURL(_ url: URL) {
        let text = url.absoluteString
        sharedText = text
        if let pending = pendingShareResult {
            pendingShareResult = nil
            pending(text)
        }
    }
}
