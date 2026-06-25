#include "quickjs_bridge.h"
#include <stdlib.h>
#include <string.h>

struct QuickJSBridge {
    JSRuntime *runtime;
    JSContext *ctx;
};

QuickJSBridge *quickjs_bridge_create(void) {
    QuickJSBridge *bridge = (QuickJSBridge *)malloc(sizeof(QuickJSBridge));
    if (!bridge) return NULL;

    bridge->runtime = JS_NewRuntime();
    if (!bridge->runtime) {
        free(bridge);
        return NULL;
    }

    // 设置内存限制（256MB）和栈大小（256KB）
    JS_SetMemoryLimit(bridge->runtime, 256 * 1024 * 1024);
    JS_SetMaxStackSize(bridge->runtime, 256 * 1024);

    bridge->ctx = JS_NewContext(bridge->runtime);
    if (!bridge->ctx) {
        JS_FreeRuntime(bridge->runtime);
        free(bridge);
        return NULL;
    }

    // 注入 quickjs-libc 标准库（setTimeout 等暂不需要）
    // js_std_add_helpers(bridge->ctx, 0, NULL);

    return bridge;
}

const char *quickjs_bridge_eval(QuickJSBridge *bridge, const char *script, int *is_error) {
    if (!bridge || !bridge->ctx || !script) {
        if (is_error) *is_error = 1;
        return NULL;
    }

    JSValue val = JS_Eval(bridge->ctx, script, strlen(script), "<eval>", JS_EVAL_TYPE_GLOBAL);

    if (JS_IsException(val)) {
        JSValue exception = JS_GetException(bridge->ctx);
        const char *str = JS_ToCString(bridge->ctx, exception);
        JS_FreeValue(bridge->ctx, exception);
        JS_FreeValue(bridge->ctx, val);
        if (is_error) *is_error = 1;
        if (str) {
            char *result = strdup(str);
            JS_FreeCString(bridge->ctx, str);
            return result;
        }
        return strdup("Unknown error");
    }

    const char *str = JS_ToCString(bridge->ctx, val);
    JS_FreeValue(bridge->ctx, val);
    if (is_error) *is_error = 0;

    if (str) {
        char *result = strdup(str);
        JS_FreeCString(bridge->ctx, str);
        return result;
    }

    return strdup("");
}

void quickjs_bridge_free_string(const char *str) {
    if (str) {
        free((void *)str);
    }
}

void quickjs_bridge_dispose(QuickJSBridge *bridge) {
    if (!bridge) return;
    if (bridge->ctx) {
        JS_FreeContext(bridge->ctx);
    }
    if (bridge->runtime) {
        JS_FreeRuntime(bridge->runtime);
    }
    free(bridge);
}
