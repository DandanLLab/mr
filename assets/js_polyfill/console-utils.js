/**
 * console-utils.js — Console 日志提取与恢复工具
 *
 * 从 js_engine.dart 中剥离的内联 JS 代码。
 * 提供：
 *   - __flushConsoleLogs()：提取并清空 console 日志，返回 JSON 字符串
 *   - __reinjectConsole()：当 console 被用户代码覆盖时重新注入
 */

// ===== 提取 console 日志（提取后清空）=====
// 返回值：
//   - JSON 字符串（日志数组）
//   - "NEED_REINJECT"：console 被覆盖，需要重新注入
//   - "[]" 或 "undefined"：无日志
function __flushConsoleLogs() {
  var logs = [];
  if (typeof __consoleLogs !== 'undefined' && __consoleLogs.length > 0) {
    logs = __consoleLogs.slice();
    __consoleLogs.length = 0;
  } else if (typeof console !== 'undefined' && typeof console._getLogs === 'function') {
    logs = console._getLogs();
    if (console._clearLogs) console._clearLogs();
  } else if (typeof console === 'undefined' || typeof console._getLogs !== 'function') {
    return 'NEED_REINJECT';
  }
  return JSON.stringify(logs);
}

// ===== 重新注入 console（被用户代码覆盖后恢复）=====
function __reinjectConsole() {
  var __consoleLogs = [];
  globalThis.console = {
    log: function() { var msg = Array.from(arguments).join(' '); __consoleLogs.push({level: 'log', msg: msg}); },
    warn: function() { var msg = Array.from(arguments).join(' '); __consoleLogs.push({level: 'warn', msg: msg}); },
    error: function() { var msg = Array.from(arguments).join(' '); __consoleLogs.push({level: 'error', msg: msg}); },
    info: function() { var msg = Array.from(arguments).join(' '); __consoleLogs.push({level: 'info', msg: msg}); },
    debug: function() { var msg = Array.from(arguments).join(' '); __consoleLogs.push({level: 'debug', msg: msg}); },
  };
}
