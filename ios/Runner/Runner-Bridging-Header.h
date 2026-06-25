//
//  Runner-Bridging-Header.h
//  Runner
//
//  Swift ↔ Objective-C 桥接头文件
//  让 Swift 代码（AppDelegate.swift）能访问 OC 版的 GeneratedPluginRegistrant
//
//  Flutter 3.45 在禁用 Swift Package Manager 时总是生成 OC 版（.m/.h），
//  Swift 调用 OC 类必须通过 bridging header 导入对应的 .h 文件。
//

#import "GeneratedPluginRegistrant.h"
