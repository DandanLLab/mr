# AI 调试服务接口文档

> 调试服务入口：[lib/pages/debug/book_source_debug_page.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/pages/debug/book_source_debug_page.dart)
>
> 调试服务后端：[lib/services/source_debug_service.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/services/source_debug_service.dart)
>
> 引擎性能统计面板：[lib/pages/debug/crypto_stats_panel.dart](file:///d:/OpenClaw/.openclaw/workspace/mr/lib/pages/debug/crypto_stats_panel.dart)

---

## 服务信息

| 项 | 值 |
|----|-----|
| WebSocket 地址 | `ws://localhost:9527` |
| HTTP API 地址 | `http://localhost:9527/api` |
| 状态页面 | `http://localhost:9527/status` |
| 实现语言 | Dart |
| 运行方式 | 独立进程，由 `source_debug_service.dart` 启动 |

---

## 连接方式

### WebSocket 连接

```javascript
const ws = new WebSocket('ws://localhost:9527');

ws.onopen = () => {
  console.log('已连接到调试服务');
};

ws.onmessage = (event) => {
  const response = JSON.parse(event.data);
  console.log('收到响应:', response);
};

ws.onerror = (error) => {
  console.error('连接错误:', error);
};
```

### HTTP API 调用

```bash
curl -X POST http://localhost:9527/api \
  -H "Content-Type: application/json" \
  -d '{"type": "ping", "id": "1", "data": {}}'
```

---

## 消息格式

### 请求格式

```json
{
  "type": "命令类型",
  "id": "请求ID",
  "data": {
    "source": { },
    "keyword": "",
    "url": ""
  },
  "timestamp": "2024-01-01T00:00:00.000Z"
}
```

### 成功响应

```json
{
  "id": "请求ID",
  "success": true,
  "result": { },
  "error": null,
  "timestamp": "2024-01-01T00:00:00.000Z"
}
```

### 错误响应

```json
{
  "id": "请求ID",
  "success": false,
  "result": null,
  "error": "错误描述信息",
  "timestamp": "2024-01-01T00:00:00.000Z"
}
```

---

## 可用命令

### 1. ping — 心跳测试

**请求：**
```json
{ "type": "ping", "id": "1", "data": {} }
```

**响应：**
```json
{ "id": "1", "success": true, "result": { "pong": true }, "error": null }
```

---

### 2. test_search — 测试搜索

**请求：**
```json
{
  "type": "test_search",
  "id": "2",
  "data": {
    "source": {
      "bookSourceUrl": "https://example.com",
      "bookSourceName": "示例书源",
      "searchUrl": "https://example.com/search?key={{key}}",
      "ruleSearch": {
        "bookList": "class.book-list@tag.li",
        "name": "tag.h3@text",
        "author": "tag.p@text##作者：",
        "bookUrl": "tag.a@href"
      }
    },
    "keyword": "斗破苍穹"
  }
}
```

**响应：**
```json
{
  "id": "2",
  "success": true,
  "result": {
    "keyword": "斗破苍穹",
    "count": 10,
    "results": [
      { "name": "斗破苍穹", "author": "天蚕土豆", "bookUrl": "https://example.com/book/123" }
    ]
  }
}
```

---

### 3. test_explore — 测试发现

**请求：**
```json
{
  "type": "test_explore",
  "id": "3",
  "data": {
    "source": {
      "bookSourceUrl": "https://example.com",
      "exploreUrl": "全部::https://example.com/list/all",
      "ruleExplore": {
        "bookList": "class.book-item",
        "name": "tag.h2@text",
        "author": "tag.p@text",
        "bookUrl": "tag.a@href"
      }
    },
    "url": "https://example.com/list/all"
  }
}
```

---

### 4. test_book_info — 测试书籍信息

**请求：**
```json
{
  "type": "test_book_info",
  "id": "4",
  "data": {
    "source": {
      "bookSourceUrl": "https://example.com",
      "ruleBookInfo": {
        "name": "tag.h1@text",
        "author": "class.author@text",
        "intro": "class.intro@text",
        "tocUrl": "class.read-btn@href"
      }
    },
    "bookUrl": "https://example.com/book/123"
  }
}
```

---

### 5. test_toc — 测试目录

**请求：**
```json
{
  "type": "test_toc",
  "id": "5",
  "data": {
    "source": {
      "bookSourceUrl": "https://example.com",
      "ruleToc": {
        "chapterList": "class.chapter-list@tag.li",
        "chapterName": "tag.a@text",
        "chapterUrl": "tag.a@href"
      }
    },
    "bookUrl": "https://example.com/book/123"
  }
}
```

---

### 6. test_content — 测试正文

**请求：**
```json
{
  "type": "test_content",
  "id": "6",
  "data": {
    "source": {
      "bookSourceUrl": "https://example.com",
      "ruleContent": {
        "content": "class.content@html"
      }
    },
    "chapterUrl": "https://example.com/chapter/123"
  }
}
```

---

### 7. test_rule — 测试规则

**请求：**
```json
{
  "type": "test_rule",
  "id": "7",
  "data": {
    "content": "<html><body><div class=\"book-list\"><li><h3>书名</h3></li></div></body></html>",
    "rule": "class.book-list@tag.li@tag.h3@text",
    "ruleType": "string"
  }
}
```

**ruleType 可选值：** `string`（默认）、`list`（列表）、`map`（对象列表）、`auto`（自动判断）

---

### 8. execute_js — 执行 JavaScript

**请求：**
```json
{
  "type": "execute_js",
  "id": "8",
  "data": {
    "code": "const items = result.match(/<li[^>]*>(.*?)<\\/li>/g) || []; JSON.stringify(items);",
    "variables": {
      "result": "<ul><li>项目1</li><li>项目2</li></ul>"
    }
  }
}
```

---

### 9. get_book_sources — 获取书源列表

**请求：**
```json
{ "type": "get_book_sources", "id": "9", "data": {} }
```

---

### 10. add_book_source — 添加书源

**请求：**
```json
{
  "type": "add_book_source",
  "id": "10",
  "data": {
    "source": {
      "bookSourceUrl": "https://newsource.com",
      "bookSourceName": "新书源",
      "enabled": true
    }
  }
}
```

---

### 11. update_book_source — 更新书源

**请求：**
```json
{
  "type": "update_book_source",
  "id": "11",
  "data": {
    "source": {
      "bookSourceUrl": "https://example.com",
      "bookSourceName": "更新后的书源名",
      "enabled": false
    }
  }
}
```

---

### 12. delete_book_source — 删除书源

**请求：**
```json
{
  "type": "delete_book_source",
  "id": "12",
  "data": {
    "sourceUrl": "https://example.com"
  }
}
```

---

### 13. get_miniprograms — 获取小程序列表

**请求：**
```json
{ "type": "get_miniprograms", "id": "13", "data": {} }
```

---

### 14. get_plugins — 获取插件列表

**请求：**
```json
{ "type": "get_plugins", "id": "14", "data": {} }
```

---

### 15. http_request — 发送 HTTP 请求

**请求：**
```json
{
  "type": "http_request",
  "id": "15",
  "data": {
    "url": "https://example.com/api/data",
    "method": "GET",
    "headers": {
      "User-Agent": "Mozilla/5.0",
      "Authorization": "Bearer token"
    },
    "body": null
  }
}
```

---

### 16. get_engine_stats — 获取引擎性能统计

**请求：**
```json
{ "type": "get_engine_stats", "id": "16", "data": {} }
```

**响应中包含：**
- **加密统计**：C 原生加密方法调用次数、总耗时、平均耗时、吞吐量
- **C 层内存统计**：全局 malloc/free 计数、当前字节、峰值字节、分配失败数
- **JS 引擎内存**：`JS_ComputeMemoryUsage` 25 字段（当前使用/限额/对象数/字符串数/shape 数/函数数/字节码大小/atom 数等）

---

### 17. trigger_gc — 手动触发 QuickJS GC

**请求：**
```json
{ "type": "trigger_gc", "id": "17", "data": {} }
```

**响应：**
```json
{ "id": "17", "success": true, "result": { "gc_completed": true }, "error": null }
```

---

### 18. get_promise_state — 查询 Promise 状态

**请求：**
```json
{
  "type": "get_promise_state",
  "id": "18",
  "data": {
    "varName": "bookLoadPromise"
  }
}
```

**响应：**
```json
{
  "id": "18",
  "success": true,
  "result": {
    "varName": "bookLoadPromise",
    "state": 2,
    "label": "fulfilled"
  }
}
```

**状态值：** `0`=非 Promise 对象, `1`=pending（等待中）, `2`=fulfilled（已完成）, `3`=rejected（已拒绝）

---

### 19. print_js_value — 流式打印 JS 值

**请求：**
```json
{
  "type": "print_js_value",
  "id": "19",
  "data": {
    "expr": "typeof book",
    "maxDepth": 2,
    "maxStringLength": 256
  }
}
```

**响应：**
```json
{
  "id": "19",
  "success": true,
  "result": {
    "expr": "typeof book",
    "value": "object"
  }
}
```

> 底层调用 `JS_PrintValue`（参考 quickjs-zh 实现），支持控制最大递归深度和字符串截断长度。

---

## 本应用调试面板功能

除了上述 AI 远程调试 API，本应用内置完整的调试 UI：

### 书源调试页
`book_source_debug_page.dart` — 实时日志 + 源码查看 + 执行追踪树

| 标签页 | 说明 |
|--------|------|
| 日志 | 实时显示 `console.log` 输出和规则执行日志 |
| 源码 | 当前调试书源的 JSON 源码 |
| 追踪 | JS 执行流程树（每个步骤的输入/输出/耗时） |

### 引擎性能统计面板
`crypto_stats_panel.dart` — 可独立打开的调试面板

| 卡片 | 功能 |
|------|------|
| 加密统计 | C 原生加密调用次数、总耗时、平均耗时、吞吐量（MB/s） |
| 吞吐量 | 每类加密方法的分时吞吐量 |
| C 层内存 | `memory_tracker` 全局分配/释放/峰值/活跃句柄数 |
| QuickJS 版本 | 引擎版本号 + context 异常状态 |
| JS 引擎内存 | 25 字段 `JS_ComputeMemoryUsage` 全量展示 |
| Promise 监控 | 输入变量名查询其 Promise 状态 |
| JS 值打印 | 输入 JS 表达式，`JS_PrintValue` 流式输出 |
| 自动刷新 | 500ms 定时刷新所有统计 |
| 手动 GC | AppBar 按钮触发 `JS_RunGC` |
| 重置计数 | 清空加密统计和内存统计 |

---

## 调试流程建议

1. **测试搜索** → `test_search` 检查 bookList/name/author 规则
2. **测试详情** → 从搜索结果拿 `bookUrl`，`test_book_info` 验证
3. **测试目录** → `test_toc` 检查章节列表完整性
4. **测试正文** → 从目录拿 `chapterUrl`，`test_content` 验证
5. **单独调规则** → `test_rule` 隔离测试某条规则
6. **检查引擎健康** → `get_engine_stats` 查看 JS 内存和 Promise 状态
7. **保存书源** → 测试通过后 `add_book_source` 保存

---

## 规则语法参考

> 完整规则语法见 [book_source_help.md](book_source_help.md) | 书写指南见 [book_source_guide.md](book_source_guide.md)

### CSS 选择器
```
class.book-list          // class 选择器
tag.div                  // 标签选择器
class.book-list@tag.li   // 子元素选择
tag.h3@text              // 获取文本
tag.a@href               // 获取属性
tag.p.0@text             // 获取第一个 p 标签
tag.p.-1@text            // 获取最后一个
tag.p[0:3]@text          // 切片
```

### JSONPath
```
$.data.list              // 获取 data.list
$.data.books             // 获取数组
$.name                   // 获取字段
$.data.list.*.name       // 通配
$[?(@.type==1)]          // 过滤器
```

### XPath
```
//div[@class='book-list']/ul/li
.//h3/a/text()
.//a/@href
```

### JavaScript
```
:result.match(/name":"([^"]*)"/)?.[1] || ''
@js:const items = result.match(/.+?/g); JSON.stringify(items);
```

---

## 客户端示例

### Python

```python
import websocket
import json

def on_message(ws, message):
    response = json.loads(message)
    print(f"收到响应: {response}")

def on_open(ws):
    request = {
        "type": "test_search",
        "id": "1",
        "data": {
            "source": {
                "bookSourceUrl": "https://example.com",
                "bookSourceName": "示例书源",
                "searchUrl": "https://example.com/search?key={{key}}",
                "ruleSearch": {
                    "bookList": "class.book-list@tag.li",
                    "name": "tag.h3@text",
                    "author": "tag.p@text##作者：",
                    "bookUrl": "tag.a@href"
                }
            },
            "keyword": "斗破苍穹"
        }
    }
    ws.send(json.dumps(request))

ws = websocket.WebSocketApp(
    "ws://localhost:9527",
    on_open=on_open,
    on_message=on_message
)
ws.run_forever()
```

### Node.js

```javascript
const WebSocket = require('ws');
const ws = new WebSocket('ws://localhost:9527');

ws.on('open', () => {
  ws.send(JSON.stringify({
    type: 'test_search',
    id: '1',
    data: {
      source: {
        bookSourceUrl: 'https://example.com',
        bookSourceName: '示例书源',
        searchUrl: 'https://example.com/search?key={{key}}',
        ruleSearch: {
          bookList: 'class.book-list@tag.li',
          name: 'tag.h3@text',
          author: 'tag.p@text##作者：',
          bookUrl: 'tag.a@href'
        }
      },
      keyword: '斗破苍穹'
    }
  }));
});

ws.on('message', (data) => {
  console.log('收到响应:', JSON.parse(data));
});
```