import Flutter
import UIKit
import WebKit
import CryptoKit
import CommonCrypto

/// iOS 原生桥接插件
///
/// 对应 Android 的 NativePlugin.kt
/// 实现 HTTP（URLSession）、AES 加解密（CommonCrypto）、哈希（CryptoKit）、
/// Base64、数据存储（UserDefaults）、设备信息、WebView JS 执行（WKWebView）等能力。
///
/// MethodChannel 名称：com.mr.app/native（与 Android 保持一致）
///
/// 注意：iOS 无 Jsoup 等价库，HTML 解析相关方法（jsoupSelect 等）使用
/// 简单的正则/字符串处理实现，复杂场景由 Dart 侧的 `html` 包接管。
class NativePlugin: NSObject, FlutterPlugin {

    // MARK: - 注册

    static let channelName = "com.mr.app/native"

  /// 保持正在运行的 WebView handler 引用，防止被提前释放
    private var activeHandlers: [WebViewJsHandler] = []

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        let instance = NativePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    /// 移除已完成的 handler
    /// fileprivate 因为参数 WebViewJsHandler 是 private class
    fileprivate func removeHandler(_ handler: WebViewJsHandler) {
        activeHandlers.removeAll { $0 === handler }
    }

    // MARK: - MethodChannel 分发

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        // 屏幕亮度
        case "getScreenBrightness":
            getScreenBrightness(result: result)
        case "setScreenBrightness":
            setScreenBrightness(call: call, result: result)
        // HTTP 请求
        case "httpGet":
            httpGet(call: call, result: result)
        case "httpPost":
            httpPost(call: call, result: result)
        case "httpGetWithCache":
            httpGetWithCache(call: call, result: result)
        case "httpDownload":
            httpDownload(call: call, result: result)
        case "httpHead":
            httpHead(call: call, result: result)
        // HTML 解析（Jsoup 等价，iOS 简化实现）
        case "jsoupSelect":
            jsoupSelect(call: call, result: result)
        case "jsoupSelectAll":
            jsoupSelectAll(call: call, result: result)
        case "jsoupGetAttr":
            jsoupGetAttr(call: call, result: result)
        case "jsoupClean":
            jsoupClean(call: call, result: result)
        case "jsoupParseUrl":
            jsoupParseUrl(call: call, result: result)
        case "jsoupGetLinks":
            jsoupGetLinks(call: call, result: result)
        // 加解密
        case "aesEncrypt":
            aesEncrypt(call: call, result: result)
        case "aesDecrypt":
            aesDecrypt(call: call, result: result)
        case "md5":
            md5(call: call, result: result)
        case "sha1":
            sha1(call: call, result: result)
        case "sha256":
            sha256(call: call, result: result)
        case "hmacSHA256":
            hmacSHA256(call: call, result: result)
        case "base64Encode":
            base64Encode(call: call, result: result)
        case "base64Decode":
            base64Decode(call: call, result: result)
        // 数据存储
        case "putData":
            putData(call: call, result: result)
        case "getData":
            getData(call: call, result: result)
        case "deleteData":
            deleteData(call: call, result: result)
        // 设备信息
        case "getDeviceInfo":
            getDeviceInfo(result: result)
        // Cookie
        case "getCookie":
            getCookie(call: call, result: result)
        // WebView JS 执行
        case "executeWebViewJs":
            executeWebViewJs(call: call, result: result)
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
            // iOS 亮度范围 0.0 ~ 1.0，-1 表示系统默认，这里 clamp 到 [0, 1]
            let clamped = max(0.0, min(1.0, value))
            UIScreen.main.brightness = CGFloat(clamped)
            result(true)
        }
    }

    // MARK: - HTTP 请求（URLSession）

    private func httpGet(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
            result(FlutterError(code: "ERROR", message: "url is required", details: nil))
            return
        }
        let headers = (args["headers"] as? [String: String]) ?? [:]
        let timeoutMs = (args["timeoutMs"] as? Int) ?? 10000

        var request = URLRequest(url: URL(string: url)!, timeoutInterval: TimeInterval(timeoutMs) / 1000.0)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        performRequest(request, result: result)
    }

    private func httpPost(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
            result(FlutterError(code: "ERROR", message: "url is required", details: nil))
            return
        }
        let body = (args["body"] as? String) ?? ""
        let headers = (args["headers"] as? [String: String]) ?? [:]
        let timeoutMs = (args["timeoutMs"] as? Int) ?? 10000

        var request = URLRequest(url: URL(string: url)!, timeoutInterval: TimeInterval(timeoutMs) / 1000.0)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        // 默认 Content-Type
        if headers["Content-Type"] == nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        performRequest(request, result: result)
    }

    private func httpGetWithCache(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
            result(FlutterError(code: "ERROR", message: "url is required", details: nil))
            return
        }
        let headers = (args["headers"] as? [String: String]) ?? [:]
        // iOS 使用系统缓存策略
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15.0)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        performRequest(request, result: result)
    }

    private func httpHead(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
            result(FlutterError(code: "ERROR", message: "url is required", details: nil))
            return
        }
        let headers = (args["headers"] as? [String: String]) ?? [:]

        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15.0)
        request.httpMethod = "HEAD"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let httpResponse = response as? HTTPURLResponse else {
                result(nil)
                return
            }
            var headerMap: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headerMap["\(key)"] = "\(value)"
            }
            result(headerMap)
        }
        task.resume()
    }

    private func httpDownload(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty,
              let savePath = args["savePath"] as? String, !savePath.isEmpty else {
            result(FlutterError(code: "ERROR", message: "url and savePath are required", details: nil))
            return
        }
        let headers = (args["headers"] as? [String: String]) ?? [:]

        var request = URLRequest(url: URL(string: url)!)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = URLSession.shared.downloadTask(with: request) { tempUrl, response, error in
            if let error = error {
                result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
                return
            }
            guard let tempUrl = tempUrl else {
                result(FlutterError(code: "ERROR", message: "No data downloaded", details: nil))
                return
            }
            let destUrl = URL(fileURLWithPath: savePath)
            do {
                // 创建父目录
                try? FileManager.default.createDirectory(at: destUrl.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: savePath) {
                    try FileManager.default.removeItem(at: destUrl)
                }
                try FileManager.default.moveItem(at: tempUrl, to: destUrl)
                result(savePath)
            } catch {
                result(FlutterError(code: "ERROR", message: error.localizedDescription, details: nil))
            }
        }
        task.resume()
    }

    /// 执行 URLRequest 并返回响应体字符串
    private func performRequest(_ request: URLRequest, result: @escaping FlutterResult) {
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                NSLog("HTTP request failed: \(error.localizedDescription)")
                result("")
                return
            }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            result(body)
        }
        task.resume()
    }

    // MARK: - HTML 解析（Jsoup 等价，iOS 简化实现）

    private func jsoupSelect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let html = args["html"] as? String,
              let selector = args["selector"] as? String else {
            result(FlutterError(code: "ERROR", message: "html and selector are required", details: nil))
            return
        }
        // iOS 无 Jsoup，使用 WKWebView 的 DOM 查询是最精确的方案，
        // 但为避免性能开销，这里用简化实现：提取标签文本
        result(simpleSelectText(html: html, selector: selector))
    }

    private func jsoupSelectAll(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let html = args["html"] as? String,
              let selector = args["selector"] as? String else {
            result(FlutterError(code: "ERROR", message: "html and selector are required", details: nil))
            return
        }
        result(simpleSelectAll(html: html, selector: selector))
    }

    private func jsoupGetAttr(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let html = args["html"] as? String,
              let selector = args["selector"] as? String,
              let attr = args["attr"] as? String else {
            result(FlutterError(code: "ERROR", message: "html, selector and attr are required", details: nil))
            return
        }
        result(simpleGetAttr(html: html, selector: selector, attr: attr))
    }

    private func jsoupClean(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let html = args["html"] as? String else {
            result(FlutterError(code: "ERROR", message: "html is required", details: nil))
            return
        }
        result(cleanHtml(html))
    }

    private func jsoupParseUrl(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String, !url.isEmpty else {
            result(FlutterError(code: "ERROR", message: "url is required", details: nil))
            return
        }
        let headers = (args["headers"] as? [String: String]) ?? [:]
        let selector = args["selector"] as? String

        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15.0)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                NSLog("jsoupParseUrl failed: \(error.localizedDescription)")
                result("")
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                result("")
                return
            }
            if let selector = selector, !selector.isEmpty {
                result(self.simpleSelectAll(html: html, selector: selector).joined(separator: "\n"))
            } else {
                result(html)
            }
        }
        task.resume()
    }

    private func jsoupGetLinks(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let html = args["html"] as? String else {
            result(FlutterError(code: "ERROR", message: "html is required", details: nil))
            return
        }
        let baseUrl = (args["baseUrl"] as? String) ?? ""

        // 用正则提取所有 <a href="...">
        let pattern = #"<a[^>]+href\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            result([String]())
            return
        }
        let nsHtml = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
        var links: [String] = []
        for match in matches {
            if match.numberOfRanges > 1 {
                var href = nsHtml.substring(with: match.range(at: 1))
                // 处理相对路径
                if !baseUrl.isEmpty && !href.hasPrefix("http://") && !href.hasPrefix("https://") {
                    if href.hasPrefix("//") {
                        href = "https:" + href
                    } else if href.hasPrefix("/") {
                        if let base = URL(string: baseUrl) {
                            href = "\(base.scheme ?? "https")://\(base.host ?? "")\(href)"
                        }
                    } else {
                        href = baseUrl + (baseUrl.hasSuffix("/") ? "" : "/") + href
                    }
                }
                if !href.isEmpty {
                    links.append(href)
                }
            }
        }
        result(links)
    }

    /// 简化版 CSS 选择器文本提取（仅支持标签名选择，如 "div.title"）
    private func simpleSelectText(html: String, selector: String) -> String {
        // 简化实现：去掉所有标签，返回纯文本
        let cleaned = cleanHtml(html)
        // 去掉所有 HTML 标签
        let text = cleaned.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        // 压缩空白
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// 简化版 CSS 选择器批量提取（返回 outerHtml 列表）
    private func simpleSelectAll(html: String, selector: String) -> [String] {
        // 简化实现：iOS 无完整 CSS 选择器引擎，返回空数组
        // 复杂 HTML 解析由 Dart 侧的 `html` 包处理
        return []
    }

    /// 简化版属性提取
    private func simpleGetAttr(html: String, selector: String, attr: String) -> String {
        // 简化实现：提取第一个匹配 attr 的值
        let pattern = #"\s"# + NSRegularExpression.escapedPattern(for: attr) + #"\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ""
        }
        let nsHtml = html as NSString
        let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
        if let match = match, match.numberOfRanges > 1 {
            return nsHtml.substring(with: match.range(at: 1))
        }
        return ""
    }

    /// 清理 HTML：移除 script/style/noscript 标签及隐藏元素
    private func cleanHtml(_ html: String) -> String {
        var result = html
        // 移除 script/style/noscript 标签及其内容
        let patterns = [
            #"<script[^>]*>[\s\S]*?</script>"#,
            #"<style[^>]*>[\s\S]*?</style>"#,
            #"<noscript[^>]*>[\s\S]*?</noscript>"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // 移除 display:none 的元素
        let hiddenPattern = #"<[^>]*style\s*=\s*["'][^"']*display\s*:\s*none[^"']*["'][^>]*>[\s\S]*?</[^>]+>"#
        result = result.replacingOccurrences(
            of: hiddenPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }

    // MARK: - 加解密

    private func aesEncrypt(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String,
              let key = args["key"] as? String else {
            result(FlutterError(code: "ERROR", message: "data and key are required", details: nil))
            return
        }
        let iv = args["iv"] as? String

        guard let encrypted = aesCrypt(
            data: data,
            key: key,
            iv: iv,
            operation: CCOperation(kCCEncrypt)
        ) else {
            result(FlutterError(code: "ERROR", message: "AES encrypt failed", details: nil))
            return
        }
        result(encrypted)
    }

    private func aesDecrypt(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String,
              let key = args["key"] as? String else {
            result(FlutterError(code: "ERROR", message: "data and key are required", details: nil))
            return
        }
        let iv = args["iv"] as? String

        guard let decrypted = aesCrypt(
            data: data,
            key: key,
            iv: iv,
            operation: CCOperation(kCCDecrypt)
        ) else {
            result(FlutterError(code: "ERROR", message: "AES decrypt failed", details: nil))
            return
        }
        result(decrypted)
    }

    /// AES 加解密核心
    /// - 与 Android 兼容：key/iv 不足 16 字节时用 0 填充到 16 字节（AES-128）
    /// - iv 为空时使用 ECB 模式，否则使用 CBC 模式
    /// - 加密时 data 是明文，返回 Base64；解密时 data 是 Base64，返回明文
    private func aesCrypt(data: String, key: String, iv: String?, operation: CCOperation) -> String? {
        let keyData = padKey(Data(key.utf8))
        let ivData: Data? = {
            if let iv = iv, !iv.isEmpty {
                return padKey(Data(iv.utf8))
            }
            return nil
        }()

        // 加密：明文 → 密文（Base64）
        // 解密：Base64 → 密文 → 明文
        let rawData: Data
        var outputIsBase64 = false
        if operation == CCOperation(kCCEncrypt) {
            guard let d = data.data(using: .utf8) else { return nil }
            rawData = d
            outputIsBase64 = true
        } else {
            guard let d = Data(base64Encoded: data) else { return nil }
            rawData = d
        }

        let bufferSize = rawData.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesProcessed = 0

        // CommonCrypto 常量（kCCOptionPKCS7Padding / kCCOptionECBMode / kCCSuccess）在 Swift 中是 Int，
        // 而 CCOptions 是 UInt32、CCCryptorStatus 是 Int32，需要显式类型转换。
        let options: CCOptions = CCOptions(kCCOptionPKCS7Padding) | (ivData == nil ? CCOptions(kCCOptionECBMode) : 0)

        var status: CCCryptorStatus = CCCryptorStatus(kCCSuccess)

        keyData.withUnsafeBytes { keyBytesRaw in
            rawData.withUnsafeBytes { dataBytesRaw in
                buffer.withUnsafeMutableBytes { bufferBytesRaw in
                    if let ivData = ivData {
                        ivData.withUnsafeBytes { ivBytesRaw in
                            status = CCCrypt(
                                operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                options,
                                keyBytesRaw.baseAddress, keyData.count,
                                ivBytesRaw.baseAddress,
                                dataBytesRaw.baseAddress, rawData.count,
                                bufferBytesRaw.baseAddress, bufferSize,
                                &numBytesProcessed
                            )
                        }
                    } else {
                        status = CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytesRaw.baseAddress, keyData.count,
                            nil,
                            dataBytesRaw.baseAddress, rawData.count,
                            bufferBytesRaw.baseAddress, bufferSize,
                            &numBytesProcessed
                        )
                    }
                }
            }
        }

        guard status == CCCryptorStatus(kCCSuccess) else {
            NSLog("AES crypt failed, status: \(status)")
            return nil
        }

        buffer.count = numBytesProcessed

        if outputIsBase64 {
            return buffer.base64EncodedString()
        } else {
            return String(data: buffer, encoding: .utf8)
        }
    }

    /// 将 key 填充到 16 字节（AES-128），与 Android padKey 行为一致
    private func padKey(_ data: Data) -> Data {
        var padded = Data(count: 16)
        let copyLen = min(data.count, 16)
        padded.replaceSubrange(0..<copyLen, with: data.prefix(copyLen))
        return padded
    }

    // MARK: - 哈希（CryptoKit）

    private func md5(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String else {
            result(FlutterError(code: "ERROR", message: "data is required", details: nil))
            return
        }
        let digest = Insecure.MD5.hash(data: Data(data.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        result(hex)
    }

    private func sha1(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String else {
            result(FlutterError(code: "ERROR", message: "data is required", details: nil))
            return
        }
        let digest = Insecure.SHA1.hash(data: Data(data.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        result(hex)
    }

    private func sha256(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String else {
            result(FlutterError(code: "ERROR", message: "data is required", details: nil))
            return
        }
        let digest = SHA256.hash(data: Data(data.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        result(hex)
    }

    private func hmacSHA256(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String,
              let key = args["key"] as? String else {
            result(FlutterError(code: "ERROR", message: "data and key are required", details: nil))
            return
        }
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let hmac = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: symmetricKey)
        let hex = hmac.map { String(format: "%02x", $0) }.joined()
        result(hex)
    }

    // MARK: - Base64

    private func base64Encode(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String else {
            result(FlutterError(code: "ERROR", message: "data is required", details: nil))
            return
        }
        result(Data(data.utf8).base64EncodedString())
    }

    private func base64Decode(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let data = args["data"] as? String else {
            result(FlutterError(code: "ERROR", message: "data is required", details: nil))
            return
        }
        guard let decoded = Data(base64Encoded: data),
              let str = String(data: decoded, encoding: .utf8) else {
            result(FlutterError(code: "ERROR", message: "base64 decode failed", details: nil))
            return
        }
        result(str)
    }

    // MARK: - 数据存储（UserDefaults）

    private func putData(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String,
              let value = args["value"] as? String else {
            result(FlutterError(code: "ERROR", message: "key and value are required", details: nil))
            return
        }
        UserDefaults.standard.set(value, forKey: key)
        result(nil)
    }

    private func getData(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String else {
            result(FlutterError(code: "ERROR", message: "key is required", details: nil))
            return
        }
        let defaultValue = (args["defaultValue"] as? String) ?? ""
        let value = UserDefaults.standard.string(forKey: key) ?? defaultValue
        result(value)
    }

    private func deleteData(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let key = args["key"] as? String else {
            result(FlutterError(code: "ERROR", message: "key is required", details: nil))
            return
        }
        UserDefaults.standard.removeObject(forKey: key)
        result(nil)
    }

    // MARK: - 设备信息

    private func getDeviceInfo(result: @escaping FlutterResult) {
        let device = UIDevice.current
        let systemVersion = device.systemVersion
        // 将 "16.0" 转换为整数 16（对应 Android 的 sdkInt）
        let sdkInt = Int(systemVersion.split(separator: ".").first ?? "0") ?? 0
        result([
            "sdkInt": sdkInt,
            "release": systemVersion,
            "brand": "Apple",
            "model": device.model,
            "manufacturer": "Apple",
        ])
    }

    // MARK: - Cookie

    private func getCookie(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let url = args["url"] as? String,
              let cookieURL = URL(string: url) else {
            result(FlutterError(code: "ERROR", message: "url is required", details: nil))
            return
        }
        let key = args["key"] as? String

        guard let cookies = HTTPCookieStorage.shared.cookies(for: cookieURL) else {
            result("")
            return
        }

        if let key = key, !key.isEmpty {
            // 查找指定 cookie
            if let cookie = cookies.first(where: { $0.name == key }) {
                result(cookie.value)
            } else {
                result("")
            }
        } else {
            // 返回所有 cookie，格式 "name=value; name2=value2"
            let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            result(cookieStr)
        }
    }

    // MARK: - WebView JS 执行（WKWebView）

    /// 在 WKWebView 中加载 URL 并执行 JS 代码
    /// 对应 Android 的 BackstageWebView.getStrResponse()
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
            self.runWebViewJs(
                url: url,
                jsCode: jsCode,
                sourceRegex: sourceRegex,
                html: html,
                delayTime: delayTime,
                result: result
            )
        }
    }

    private func runWebViewJs(
        url: String,
        jsCode: String,
        sourceRegex: String?,
        html: String?,
        delayTime: Int,
        result: @escaping FlutterResult
    ) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

        // 资源嗅探正则
        let sniffRegex: NSRegularExpression? = {
            guard let sourceRegex = sourceRegex, !sourceRegex.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: sourceRegex, options: [])
        }()

        let handler = WebViewJsHandler(
            webView: webView,
            jsCode: jsCode,
            sniffRegex: sniffRegex,
            delayTime: delayTime,
            completion: { jsResult in
                result(jsResult)
            }
        )
        handler.owner = self

        // 设置导航代理
        webView.navigationDelegate = handler

        // 设置资源拦截（用于嗅探）
        if sniffRegex != nil {
            webView.uiDelegate = handler
        }

        // 保持 handler 引用，防止 WKWebView 被提前释放
        activeHandlers.append(handler)

        if let html = html, !html.isEmpty {
            webView.loadHTMLString(html, baseURL: URL(string: url))
        } else if let targetURL = URL(string: url) {
            webView.load(URLRequest(url: targetURL))
        }

        // 30 秒超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak handler] in
            handler?.timeout()
        }
    }
}

/// WebView JS 执行的导航代理处理
private class WebViewJsHandler: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// 强引用 WKWebView，确保页面加载和 JS 执行期间不被释放
    private var webView: WKWebView?
    private let jsCode: String
    private let sniffRegex: NSRegularExpression?
    private let delayTime: Int
    private let completion: (String?) -> Void
    private var isCompleted = false
    /// 弱引用 NativePlugin，完成后通知其移除自己
    weak var owner: NativePlugin?

    init(webView: WKWebView,
         jsCode: String,
         sniffRegex: NSRegularExpression?,
         delayTime: Int,
         completion: @escaping (String?) -> Void) {
        self.webView = webView
        self.jsCode = jsCode
        self.sniffRegex = sniffRegex
        self.delayTime = delayTime
        self.completion = completion
        super.init()
    }

    /// 资源嗅探：检查请求 URL 是否匹配正则
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
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

    /// 页面加载完成：执行 JS
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayTime) / 1000.0) { [weak self] in
            guard let self = self, !self.isCompleted else { return }
            webView.evaluateJavaScript(self.jsCode) { [weak self] evalResult, _ in
                guard let self = self, !self.isCompleted else { return }
                self.complete(self.cleanJsResult(evalResult))
            }
        }
    }

    /// 页面加载失败
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(nil)
    }

    /// 超时处理
    func timeout() {
        complete(nil)
    }

    /// 统一完成入口：确保只调用一次，并清理资源
    private func complete(_ result: String?) {
        guard !isCompleted else { return }
        isCompleted = true
        completion(result)
        // 清理 WKWebView 引用，避免内存泄漏
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        // 通知 NativePlugin 移除自己
        owner?.removeHandler(self)
    }

    /// 清理 JS 执行结果（与 Android 的清理逻辑保持一致）
    private func cleanJsResult(_ result: Any?) -> String? {
        guard let result = result else { return nil }
        var str: String
        if let s = result as? String {
            str = s
        } else {
            str = "\(result)"
        }
        if str == "null" || str.isEmpty {
            return nil
        }
        // 去掉首尾引号
        if str.hasPrefix("\"") { str.removeFirst() }
        if str.hasSuffix("\"") { str.removeLast() }
        // 反转义
        str = str.replacingOccurrences(of: "\\u003C", with: "<")
        str = str.replacingOccurrences(of: "\\u003E", with: ">")
        str = str.replacingOccurrences(of: "\\/", with: "/")
        str = str.replacingOccurrences(of: "\\n", with: "\n")
        str = str.replacingOccurrences(of: "\\t", with: "\t")
        str = str.replacingOccurrences(of: "\\\"", with: "\"")
        return str
    }
}
