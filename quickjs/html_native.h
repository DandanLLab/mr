#ifndef HTML_NATIVE_H
#define HTML_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- 轻量 HTML 解析器 + CSS 选择器引擎（C 原生）----------
// 解析加速：替代 Dart html 包的 querySelectorAll，消除多层 fallback 开销
// 专为 Legado 规则引擎定制，支持常用 CSS 选择器语法

// HTML 节点类型
typedef enum {
    HTML_NODE_ELEMENT,    // 元素节点 <div>
    HTML_NODE_TEXT,       // 文本节点
    HTML_NODE_COMMENT,    // 注释 <!-- -->
    HTML_NODE_DOCUMENT    // 文档根
} html_node_type_t;

// HTML 属性
typedef struct {
    char *name;           // 属性名（小写）
    char *value;          // 属性值（可能为 NULL 表示无值）
} html_attr_t;

// HTML 节点
typedef struct html_node {
    html_node_type_t type;
    char *tag;            // 标签名（小写，仅元素节点）
    char *text;           // 文本内容（仅文本/注释节点）
    html_attr_t *attrs;   // 属性数组（仅元素节点）
    int attr_count;
    struct html_node *parent;
    struct html_node **children;  // 子节点数组
    int child_count;
    int child_capacity;   // children 数组容量
} html_node_t;

// 解析 HTML 字符串为 DOM 树
// 返回文档根节点（HTML_NODE_DOCUMENT），调用方用 html_node_free 释放
html_node_t *html_parse(const char *html, size_t len);

// 释放 DOM 树（递归释放所有子节点）
void html_node_free(html_node_t *node);

// ---------- CSS 选择器查询 ----------

// 查询匹配指定 CSS 选择器的所有元素
// 返回匹配的元素列表（不分配新内存，指向 DOM 树中的节点）
// out_count: 匹配的元素数量
// 返回值: 元素指针数组，调用方用 free() 释放（但不释放元素本身）
html_node_t **html_query_all(html_node_t *root, const char *selector, int *out_count);

// 查询第一个匹配指定 CSS 选择器的元素
// 返回 NULL 表示未匹配
html_node_t *html_query_first(html_node_t *root, const char *selector);

// ---------- 结果提取 ----------

// 获取元素的文本内容（递归拼接所有子文本节点）
// 返回 malloc 分配的字符串，调用方用 free() 释放
char *html_get_text(html_node_t *node, size_t *out_len);

// 获取元素的内部 HTML（包含子节点的 HTML 字符串）
// 返回 malloc 分配的字符串，调用方用 free() 释放
char *html_get_inner_html(html_node_t *node, size_t *out_len);

// 获取元素的外部 HTML（包含元素自身的标签）
// 返回 malloc 分配的字符串，调用方用 free() 释放
char *html_get_outer_html(html_node_t *node, size_t *out_len);

// 获取元素指定属性的值
// 返回 NULL 表示属性不存在，否则返回 malloc 分配的字符串（调用方 free）
char *html_get_attr(html_node_t *node, const char *attr_name);

// 获取元素自身的标签名（小写）
// 返回 NULL 表示非元素节点
const char *html_get_tag_name(html_node_t *node);

#ifdef __cplusplus
}
#endif

#endif /* HTML_NATIVE_H */
