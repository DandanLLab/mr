/// JS 引擎入口（条件导出）
///
/// 原生平台（Android/iOS/Windows/Linux/macOS）：使用 flutter_js / QuickJS
/// Web 平台：返回桩实现，不支持 JS 执行
///
/// 所有平台共享的类型（JsEngineType / JsTraceNode / JsTracer）从 js_engine_types.dart 导出
library js_engine;

// 平台无关的类型（JsEngineType / JsTraceNode / JsTracer）
export 'js_engine_types.dart';

// 条件导出 JsEngine 实现
export 'js_engine_native.dart' if (dart.library.html) 'js_engine_web.dart';
