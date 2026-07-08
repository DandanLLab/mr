/**
 * fallback-polyfill.js — java-bridge.js 加载失败时的最小回退
 *
 * 当 rootBundle 加载 java-bridge.js 失败时注入，
 * 确保后续 evaluate 不崩溃。
 */
var _javaCache = {};
var java = {};
var CryptoJS = {};
var console = {
  log: function() {},
  warn: function() {},
  error: function() {},
};
