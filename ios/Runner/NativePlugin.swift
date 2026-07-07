import Flutter
import UIKit
import WebKit

/// iOS 原生桥接插件（精简版）
///
/// 仅保留平台特有 API：
/// - 屏幕亮度（getScreenBrightness / setScreenBrightness）
/// - WebView JS 执行（executeWebViewJs）
/// - Cookie 获取（getCookie）
/// - 设备信息（getDeviceInfo）
///
/// HTTP 请求 → Dart Dio
/// 加密 → JS crypto-js
/// HTML 解析 → JS _JsoupLite
/// TTS → flutter_tts 包
class NativePlugin: NSObject, FlutterPlugin {

    static let channelName = "com.mr.app/native"

    private var activeHandlers: [WebViewJsHandler] = []

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = NativePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    fileprivate func removeHandler(_ handler: WebViewJsHandler) {
        activeHandlers.removeAll { $0 === handler }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getScreenBrightness":
            getScreenBrightness(result: result)
        case "setScreenBrightness":
            setScreenBrightness(call: call, result: result)
        case "executeWebViewJs":
            executeWebViewJs(call: call, result: result)
        case "getCookie":
            getCookie(call: call, result: result)
        case "getDeviceInfo":
            getDeviceInfo(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - 屏幕亮度

    private func getScreenBrightness(result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result(Double(UIScreen.main.brightness))
        }
    }

    private func setScreenBrightness(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let value = (args["value"] as? NSNumber)?.doubleValue else {
            result(FlutterError(code: "INVALID_VALUE", message: "value is required", details: nil))
            return
        }
        DispatchQueue.main.async {
            UIScreen.main.brightness = CGFloat(max(0.0, min(1.0, value)))
            result(true)
        }
    }

    // MARK: - Cookie

    private func getCookie(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String,
              let cookieURL = URL(string: url) else {
            result("")
            return
        }
        let key = args["key"] as? String
        let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) ?? []
        if let key = key, !key.isEmpty {
            result(cookies.first { $0.name == key }?.value ?? "")
        } else {
            result(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
        }
    }

    // MARK: - 设备信息

    private func getDeviceInfo(result: @escaping FlutterResult) {
        let device = UIDevice.current
        let sdkInt = Int(device.systemVersion.split(separator: ".").first ?? "0") ?? 0
        result([
            "sdkInt": sdkInt,
            "release": device.systemVersion,
            "brand": "Apple",
            "model": device.model,
            "manufacturer": "Apple",
        ])
    }

    // MARK: - WebView JS 执行（WKWebView）

    private func executeWebViewJs(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "ERROR", message: "invalid arguments", details: nil))
            return
        }
        let url = (args["url"] as? String) ?? ""
        let jsCode = (args["jsCode"] as? String) ?? "document.documentElement.outerHTML"
        let sourceRegex = args["sourceRegex"] as? String
        let html = args["html"] as? String
        let delayTime = (args["delayTime"] as? Int) ?? 200

        if url.isEmpty && (html?.isEmpty ?? true) {
            result(FlutterError(code: "ERROR", message: "url or html is required", details: nil))
            return
        }

        DispatchQueue.main.async {
            self.runWebViewJs(url: url, jsCode: jsCode, sourceRegex: sourceRegex,
                              html: html, delayTime: delayTime, result: result)
        }
    }

    private func runWebViewJs(url: String, jsCode: String, sourceRegex: String?,
                              html: String?, delayTime: Int, result: @escaping FlutterResult) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

        let sniffRegex = sourceRegex.flatMap { try? NSRegularExpression(pattern: $0, options: []) }
        let handler = WebViewJsHandler(webView: webView, jsCode: jsCode, sniffRegex: sniffRegex,
                                       delayTime: delayTime) { jsResult in result(jsResult) }
        handler.owner = self
        webView.navigationDelegate = handler
        if sniffRegex != nil { webView.uiDelegate = handler }
        activeHandlers.append(handler)

        if let html = html, !html.isEmpty {
            webView.loadHTMLString(html, baseURL: URL(string: url))
        } else if let targetURL = URL(string: url) {
            webView.load(URLRequest(url: targetURL))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak handler] in handler?.timeout() }
    }
}

/// WebView JS 执行的导航代理处理
private class WebViewJsHandler: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView?
    private let jsCode: String
    private let sniffRegex: NSRegularExpression?
    private let delayTime: Int
    private let completion: (String?) -> Void
    private var isCompleted = false
    weak var owner: NativePlugin?

    init(webView: WKWebView, jsCode: String, sniffRegex: NSRegularExpression?,
         delayTime: Int, completion: @escaping (String?) -> Void) {
        self.webView = webView
        self.jsCode = jsCode
        self.sniffRegex = sniffRegex
        self.delayTime = delayTime
        self.completion = completion
        super.init()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let sniffRegex = sniffRegex {
            let reqURL = navigationAction.request.url?.absoluteString ?? ""
            let range = NSRange(location: 0, length: reqURL.utf16.count)
            if sniffRegex.firstMatch(in: reqURL, options: [], range: range) != nil {
                complete(reqURL)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayTime) / 1000.0) { [weak self] in
            guard let self = self, !self.isCompleted else { return }
            webView.evaluateJavaScript(self.jsCode) { [weak self] evalResult, _ in
                guard let self = self, !self.isCompleted else { return }
                self.complete(self.cleanJsResult(evalResult))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    func timeout() { complete(nil) }

    private func complete(_ result: String?) {
        guard !isCompleted else { return }
        isCompleted = true
        completion(result)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        owner?.removeHandler(self)
    }

    private func cleanJsResult(_ result: Any?) -> String? {
        guard let result = result else { return nil }
        var str = (result as? String) ?? "\(result)"
        if str == "null" || str.isEmpty { return nil }
        if str.hasPrefix("\"") { str.removeFirst() }
        if str.hasSuffix("\"") { str.removeLast() }
        str = str.replacingOccurrences(of: "\\u003C", with: "<")
        str = str.replacingOccurrences(of: "\\u003E", with: ">")
        str = str.replacingOccurrences(of: "\\/", with: "/")
        str = str.replacingOccurrences(of: "\\n", with: "\n")
        str = str.replacingOccurrences(of: "\\t", with: "\t")
        str = str.replacingOccurrences(of: "\\\"", with: "\"")
        return str
    }
}
