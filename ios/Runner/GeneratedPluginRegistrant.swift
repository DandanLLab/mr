//
//  Generated file. Do not edit.
//
import Flutter
import UIKit

import connectivity_plus
import file_picker
import flutter_inappwebview_ios
import flutter_tts
import mobile_scanner
import package_info_plus
import permission_handler_apple
import share_plus
import shared_preferences_foundation
import sqflite_darwin
import url_launcher_ios
import video_player_avfoundation
import wakelock_plus

@objc public class GeneratedPluginRegistrant: NSObject {
    @objc public static func register(with registry: FlutterPluginRegistry) {
        if let connectivityPlusPlugin = registry.registrar(forPlugin: "ConnectivityPlusPlugin") {
            ConnectivityPlusPlugin.register(with: connectivityPlusPlugin)
        }
        if let filePickerPlugin = registry.registrar(forPlugin: "FilePickerPlugin") {
            FilePickerPlugin.register(with: filePickerPlugin)
        }
        if let inAppWebViewFlutterPlugin = registry.registrar(forPlugin: "InAppWebViewFlutterPlugin") {
            InAppWebViewFlutterPlugin.register(with: inAppWebViewFlutterPlugin)
        }
        if let flutterTtsPlugin = registry.registrar(forPlugin: "FlutterTtsPlugin") {
            FlutterTtsPlugin.register(with: flutterTtsPlugin)
        }
        if let mobileScannerPlugin = registry.registrar(forPlugin: "MobileScannerPlugin") {
            MobileScannerPlugin.register(with: mobileScannerPlugin)
        }
        if let fPPPackageInfoPlusPlugin = registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin") {
            FPPPackageInfoPlusPlugin.register(with: fPPPackageInfoPlusPlugin)
        }
        if let permissionHandlerPlugin = registry.registrar(forPlugin: "PermissionHandlerPlugin") {
            PermissionHandlerPlugin.register(with: permissionHandlerPlugin)
        }
        if let fPPSharePlusPlugin = registry.registrar(forPlugin: "FPPSharePlusPlugin") {
            FPPSharePlusPlugin.register(with: fPPSharePlusPlugin)
        }
        if let sharedPreferencesPlugin = registry.registrar(forPlugin: "SharedPreferencesPlugin") {
            SharedPreferencesPlugin.register(with: sharedPreferencesPlugin)
        }
        if let sqflitePlugin = registry.registrar(forPlugin: "SqflitePlugin") {
            SqflitePlugin.register(with: sqflitePlugin)
        }
        if let uRLLauncherPlugin = registry.registrar(forPlugin: "URLLauncherPlugin") {
            URLLauncherPlugin.register(with: uRLLauncherPlugin)
        }
        if let videoPlayerPlugin = registry.registrar(forPlugin: "VideoPlayerPlugin") {
            VideoPlayerPlugin.register(with: videoPlayerPlugin)
        }
        if let wakelockPlusPlugin = registry.registrar(forPlugin: "WakelockPlusPlugin") {
            WakelockPlusPlugin.register(with: wakelockPlusPlugin)
        }
    }
}
