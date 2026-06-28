#include "html_native.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

// ---------- 工具函数 ----------

static char *_str_dup(const char *s, size_t len) {
    char *p = (char *)malloc(len + 1);
    if (!p) return NULL;
    memcpy(p, s, len);
    p[len] = 0;
    return p;
}

static char *_str_dup_lower(const char *s, size_t len) {
    char *p = _str_dup(s, len);
    if (!p) return NULL;
    for (size_t i = 0; i < len; i++) {
        if (p[i] >= 'A' && p[i] <= 'Z') p[i] = p[i] + 32;
    }
    return p;
}

static int _str_eq(const char *a, const char *b) {
    if (!a || !b) return a == b;
    return strcmp(a, b) == 0;
}

static int _str_ieq(const char *a, const char *b) {
    if (!a || !b) return a == b;
    while (*a && *b) {
        char ca = (*a >= 'A' && *a <= 'Z') ? *a + 32 : *a;
        char cb = (*b >= 'A' && *b <= 'Z') ? *b + 32 : *b;
        if (ca != cb) return 0;
        a++; b++;
    }
    return *a == *b;
}

// ---------- HTML 节点管理 ----------

static html_node_t *_node_create(html_node_type_t type) {
    html_node_t *n = (html_node_t *)calloc(1, sizeof(html_node_t));
    if (!n) return NULL;
    n->type = type;
    return n;
}

void html_node_free(html_node_t *node) {
    if (!node) return;
    // 递归释放子节点
    for (int i = 0; i < node->child_count; i++) {
        html_node_free(node->children[i]);
    }
    free(node->children);
    free(node->tag);
    free(node->text);
    for (int i = 0; i < node->attr_count; i++) {
        free(node->attrs[i].name);
        free(node->attrs[i].value);
    }
    free(node->attrs);
    free(node);
}

static int _node_add_child(html_node_t *parent, html_node_t *child) {
    if (parent->child_count >= parent->child_capacity) {
        int new_cap = parent->child_capacity == 0 ? 8 : parent->child_capacity * 2;
        html_node_t **new_children = (html_node_t **)realloc(
            parent->children, new_cap * sizeof(html_node_t *));
        if (!new_children) return -1;
        parent->children = new_children;
        parent->child_capacity = new_cap;
    }
    parent->children[parent->child_count++] = child;
    child->parent = parent;
    return 0;
}

static html_attr_t *_node_add_attr(html_node_t *node) {
    html_attr_t *new_attrs = (html_attr_t *)realloc(
        node->attrs, (node->attr_count + 1) * sizeof(html_attr_t));
    if (!new_attrs) return NULL;
    node->attrs = new_attrs;
    html_attr_t *a = &node->attrs[node->attr_count++];
    a->name = NULL;
    a->value = NULL;
    return a;
}

// ---------- HTML 词法分析 + DOM 树构建 ----------

// 自闭合标签集合
static int _is_void_tag(const char *tag) {
    static const char *void_tags[] = {
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr", NULL
    };
    for (int i = 0; void_tags[i]; i++) {
        if (_str_ieq(tag, void_tags[i])) return 1;
    }
    return 0;
}

// 需要自动闭合的标签（遇到某些标签时自动闭合未关闭的父标签）
static const char *_auto_close_tag(const char *current_tag, const char *new_tag) {
    // <li> 遇到新的 <li> 自动闭合
    if (_str_ieq(current_tag, "li") && _str_ieq(new_tag, "li")) return current_tag;
    // <tr>/<td>/<th> 遇到新的同类自动闭合
    if (_str_ieq(current_tag, "tr") && _str_ieq(new_tag, "tr")) return current_tag;
    if (_str_ieq(current_tag, "td") && (_str_ieq(new_tag, "td") || _str_ieq(new_tag, "th"))) return current_tag;
    if (_str_ieq(current_tag, "th") && (_str_ieq(new_tag, "td") || _str_ieq(new_tag, "th"))) return current_tag;
    // <p> 遇到块级元素自动闭合
    if (_str_ieq(current_tag, "p")) {
        static const char *block_tags[] = {
            "div", "p", "h1", "h2", "h3", "h4", "h5", "h6",
            "ul", "ol", "li", "table", "tr", "td", "th",
            "section", "article", "header", "footer", "nav", "aside",
            NULL
        };
        for (int i = 0; block_tags[i]; i++) {
            if (_str_ieq(new_tag, block_tags[i])) return current_tag;
        }
    }
    return NULL;
}

html_node_t *html_parse(const char *html, size_t len) {
    if (!html || len == 0) {
        return _node_create(HTML_NODE_DOCUMENT);
    }

    html_node_t *root = _node_create(HTML_NODE_DOCUMENT);
    if (!root) return NULL;
    html_node_t *current = root;

    size_t i = 0;
    while (i < len) {
        if (html[i] == '<') {
            // 注释 <!-- -->
            if (i + 3 < len && html[i+1] == '!' && html[i+2] == '-' && html[i+3] == '-') {
                size_t start = i + 4;
                size_t end = start;
                while (end + 2 < len && !(html[end] == '-' && html[end+1] == '-' && html[end+2] == '>')) {
                    end++;
                }
                html_node_t *comment = _node_create(HTML_NODE_COMMENT);
                if (comment) {
                    size_t text_len = end > start ? end - start : 0;
                    comment->text = _str_dup(html + start, text_len);
                    _node_add_child(current, comment);
                }
                i = (end + 2 < len) ? end + 3 : len;
                continue;
            }
            // DOCTYPE 或其他声明 <!...>
            if (i + 1 < len && html[i+1] == '!') {
                size_t end = i + 2;
                while (end < len && html[end] != '>') end++;
                i = end + 1;
                continue;
            }
            // 结束标签 </tag>
            if (i + 1 < len && html[i+1] == '/') {
                size_t start = i + 2;
                size_t end = start;
                while (end < len && html[end] != '>' && !isspace((unsigned char)html[end])) end++;
                char *tag = _str_dup_lower(html + start, end - start);
                // 向上查找匹配的开放标签
                html_node_t *p = current;
                while (p && p != root) {
                    if (p->tag && _str_ieq(p->tag, tag)) {
                        current = p->parent;
                        break;
                    }
                    p = p->parent;
                }
                free(tag);
                // 跳到 >
                while (end < len && html[end] != '>') end++;
                i = end + 1;
                continue;
            }
            // 开始标签 <tag attr="value">
            size_t tag_start = i + 1;
            size_t tag_end = tag_start;
            while (tag_end < len && html[tag_end] != '>' && !isspace((unsigned char)html[tag_end]) && html[tag_end] != '/') {
                tag_end++;
            }
            char *tag = _str_dup_lower(html + tag_start, tag_end - tag_start);
            if (!tag || tag[0] == 0) {
                free(tag);
                // 无效标签，当文本处理
                html_node_t *text = _node_create(HTML_NODE_TEXT);
                if (text) {
                    text->text = _str_dup("<", 1);
                    _node_add_child(current, text);
                }
                i++;
                continue;
            }

            html_node_t *elem = _node_create(HTML_NODE_ELEMENT);
            if (!elem) { free(tag); i = tag_end; continue; }
            elem->tag = tag;

            // 解析属性
            size_t pos = tag_end;
            int self_closing = 0;
            while (pos < len && html[pos] != '>') {
                // 跳过空白
                while (pos < len && isspace((unsigned char)html[pos])) pos++;
                if (pos >= len || html[pos] == '>') break;
                // 自闭合标记 /
                if (html[pos] == '/') {
                    self_closing = 1;
                    pos++;
                    continue;
                }
                // 属性名
                size_t name_start = pos;
                while (pos < len && html[pos] != '=' && html[pos] != '>' && !isspace((unsigned char)html[pos]) && html[pos] != '/') {
                    pos++;
                }
                size_t name_end = pos;
                html_attr_t *attr = _node_add_attr(elem);
                if (attr) {
                    attr->name = _str_dup_lower(html + name_start, name_end - name_start);
                    // 跳过空白
                    while (pos < len && isspace((unsigned char)html[pos])) pos++;
                    // 属性值
                    if (pos < len && html[pos] == '=') {
                        pos++;
                        while (pos < len && isspace((unsigned char)html[pos])) pos++;
                        if (pos < len && (html[pos] == '"' || html[pos] == '\'')) {
                            char quote = html[pos];
                            pos++;
                            size_t val_start = pos;
                            while (pos < len && html[pos] != quote) pos++;
                            attr->value = _str_dup(html + val_start, pos - val_start);
                            if (pos < len) pos++; // 跳过引号
                        } else {
                            size_t val_start = pos;
                            while (pos < len && html[pos] != '>' && !isspace((unsigned char)html[pos]) && html[pos] != '/') {
                                pos++;
                            }
                            attr->value = _str_dup(html + val_start, pos - val_start);
                        }
                    }
                }
            }

            // 自闭合或 void 标签不入栈
            if (self_closing || _is_void_tag(tag)) {
                _node_add_child(current, elem);
            } else {
                // 自动闭合检查
                const char *close = (current != root && current->tag) ?
                    _auto_close_tag(current->tag, tag) : NULL;
                if (close) {
                    current = current->parent;
                }
                _node_add_child(current, elem);
                // script/style 标签内容当纯文本处理（不解析标签）
                if (_str_ieq(tag, "script") || _str_ieq(tag, "style")) {
                    size_t content_start = pos + 1;
                    size_t content_end = content_start;
                    // 查找对应的结束标签 </script> 或 </style>
                    while (content_end < len) {
                        if (html[content_end] == '<' && content_end + 1 < len && html[content_end+1] == '/') {
                            size_t close_start = content_end + 2;
                            size_t close_end = close_start;
                            while (close_end < len && html[close_end] != '>' && !isspace((unsigned char)html[close_end])) {
                                close_end++;
                            }
                            char *close_tag = _str_dup_lower(html + close_start, close_end - close_start);
                            int is_match = _str_ieq(close_tag, tag);
                            free(close_tag);
                            if (is_match) break;
                        }
                        content_end++;
                    }
                    if (content_end > content_start) {
                        html_node_t *text = _node_create(HTML_NODE_TEXT);
                        if (text) {
                            text->text = _str_dup(html + content_start, content_end - content_start);
                            _node_add_child(elem, text);
                        }
                    }
                    i = content_end;
                    // 跳过结束标签
                    while (i < len && html[i] != '>') i++;
                    i++;
                    continue;
                }
                current = elem;
            }
            i = pos + 1; // 跳过 >
            continue;
        }
        // 文本节点
        size_t text_start = i;
        while (i < len && html[i] != '<') i++;
        if (i > text_start) {
            html_node_t *text = _node_create(HTML_NODE_TEXT);
            if (text) {
                text->text = _str_dup(html + text_start, i - text_start);
                _node_add_child(current, text);
            }
        }
    }
    return root;
}

// ---------- CSS 选择器引擎 ----------

// 简单选择器（不含组合器）
typedef struct {
    char *tag;        // 标签名，NULL = 任意
    char *id;         // ID，NULL = 任意
    char **classes;   // 类名列表
    int class_count;
    // 属性选择器 [attr] [attr=val] [attr^=val] [attr$=val] [attr*=val]
    struct {
        char *name;
        char *value;
        char op;      // 0=存在, '=' '^' '$' '*'
    } attr_sel;
    int has_attr_sel;
    // 伪类 :nth-child(n) :first-child :last-child
    int nth_child;    // -1=无, 0=first, -2=last, n=第n个(1-based)
} simple_sel_t;

// 组合选择器（含组合器）
typedef struct {
    simple_sel_t *sels;   // 简单选择器数组
    int sel_count;
    char *combinators;    // 组合器数组: ' ' (后代) '>' (子代) '+' (相邻)
} compound_sel_t;

// 解析单个简单选择器
static int _parse_simple(const char **p, simple_sel_t *sel) {
    memset(sel, 0, sizeof(*sel));
    sel->nth_child = -1;
    const char *s = *p;

    // 标签名
    if (*s == '*') {
        sel->tag = NULL;
        s++;
    } else if (isalpha((unsigned char)*s) || *s == '_') {
        const char *start = s;
        while (*s && *s != '.' && *s != '#' && *s != '[' && *s != ':' &&
               !isspace((unsigned char)*s) && *s != '>' && *s != '+' && *s != ',') {
            s++;
        }
        sel->tag = _str_dup_lower(start, s - start);
    }

    // 类名、ID、属性、伪类
    while (*s && *s != '>' && *s != '+' && *s != ',' && !isspace((unsigned char)*s)) {
        if (*s == '.') {
            s++;
            const char *start = s;
            while (*s && *s != '.' && *s != '#' && *s != '[' && *s != ':' &&
                   !isspace((unsigned char)*s) && *s != '>' && *s != '+') s++;
            sel->classes = (char **)realloc(sel->classes, (sel->class_count + 1) * sizeof(char *));
            sel->classes[sel->class_count++] = _str_dup(start, s - start);
        } else if (*s == '#') {
            s++;
            const char *start = s;
            while (*s && *s != '.' && *s != '#' && *s != '[' && *s != ':' &&
                   !isspace((unsigned char)*s) && *s != '>' && *s != '+') s++;
            sel->id = _str_dup(start, s - start);
        } else if (*s == '[') {
            s++;
            const char *name_start = s;
            while (*s && *s != '=' && *s != ']' && *s != '^' && *s != '$' && *s != '*') s++;
            const char *name_end = s;
            sel->attr_sel.name = _str_dup_lower(name_start, name_end - name_start);
            sel->has_attr_sel = 1;
            if (*s == '=' || *s == '^' || *s == '$' || *s == '*') {
                sel->attr_sel.op = *s;
                if (*s != '=') s++; // 跳过 ^ $ * 后面的 =
                if (*s == '=') s++;
                // 值
                if (*s == '"' || *s == '\'') {
                    char q = *s++;
                    const char *val_start = s;
                    while (*s && *s != q) s++;
                    sel->attr_sel.value = _str_dup(val_start, s - val_start);
                    if (*s) s++;
                } else {
                    const char *val_start = s;
                    while (*s && *s != ']') s++;
                    sel->attr_sel.value = _str_dup(val_start, s - val_start);
                }
            } else {
                sel->attr_sel.op = 0;
            }
            if (*s == ']') s++;
        } else if (*s == ':') {
            s++;
            const char *start = s;
            while (*s && *s != '(' && *s != '.' && *s != '#' && *s != '[' &&
                   !isspace((unsigned char)*s) && *s != '>') s++;
            size_t plen = s - start;
            if (plen == 9 && strncmp(start, "first-child", 11) == 0) {
                sel->nth_child = 0;
            } else if (plen == 9 && strncmp(start, "last-child", 10) == 0) {
                sel->nth_child = -2;
            } else if (plen == 9 && strncmp(start, "nth-child", 9) == 0) {
                if (*s == '(') {
                    s++;
                    sel->nth_child = atoi(s);
                    while (*s && *s != ')') s++;
                    if (*s) s++;
                }
            } else if (plen == 2 && strncmp(start, "eq", 2) == 0) {
                // :eq(n) jQuery 扩展
                if (*s == '(') {
                    s++;
                    sel->nth_child = atoi(s) + 1; // eq 是 0-based，nth-child 是 1-based
                    while (*s && *s != ')') s++;
                    if (*s) s++;
                }
            }
            // 跳过未知伪类
        } else {
            s++; // 跳过未知字符
        }
    }
    *p = s;
    return 0;
}

// 释放组合选择器
static void _free_compound(compound_sel_t *cs) {
    for (int i = 0; i < cs->sel_count; i++) {
        free(cs->sels[i].tag);
        free(cs->sels[i].id);
        for (int j = 0; j < cs->sels[i].class_count; j++) {
            free(cs->sels[i].classes[j]);
        }
        free(cs->sels[i].classes);
        free(cs->sels[i].attr_sel.name);
        free(cs->sels[i].attr_sel.value);
    }
    free(cs->sels);
    free(cs->combinators);
}

// 解析 CSS 选择器（支持逗号分组，每个分组含组合器）
// 返回选择器组数组，out_count 为组数
static compound_sel_t *_parse_selector(const char *selector, int *out_count) {
    *out_count = 0;
    // 先计算逗号分组数量
    int group_count = 1;
    for (const char *p = selector; *p; p++) {
        if (*p == ',') group_count++;
    }
    compound_sel_t *groups = (compound_sel_t *)calloc(group_count, sizeof(compound_sel_t));
    if (!groups) return NULL;

    const char *p = selector;
    for (int g = 0; g < group_count; g++) {
        compound_sel_t *cs = &groups[g];
        // 解析到逗号或结束
        const char *group_end = p;
        while (*group_end && *group_end != ',') group_end++;

        // 解析组合选择器
        int cap = 4;
        cs->sels = (simple_sel_t *)calloc(cap, sizeof(simple_sel_t));
        cs->combinators = (char *)calloc(cap, 1);
        int sel_idx = 0;

        while (p < group_end) {
            // 跳过空白
            while (p < group_end && isspace((unsigned char)*p)) p++;
            if (p >= group_end) break;

            // 检查组合器
            char comb = ' '; // 默认后代
            if (*p == '>') { comb = '>'; p++; }
            else if (*p == '+') { comb = '+'; p++; }
            while (p < group_end && isspace((unsigned char)*p)) p++;

            if (p >= group_end) break;

            if (sel_idx >= cap) {
                cap *= 2;
                cs->sels = (simple_sel_t *)realloc(cs->sels, cap * sizeof(simple_sel_t));
                cs->combinators = (char *)realloc(cs->combinators, cap);
            }
            if (sel_idx > 0) {
                cs->combinators[sel_idx - 1] = comb;
            }
            _parse_simple(&p, &cs->sels[sel_idx]);
            sel_idx++;
        }
        cs->sel_count = sel_idx;
        (*out_count)++;

        if (*group_end == ',') p = group_end + 1;
        else p = group_end;
    }
    return groups;
}

static void _free_selector_groups(compound_sel_t *groups, int count) {
    for (int i = 0; i < count; i++) {
        _free_compound(&groups[i]);
    }
    free(groups);
}

// 检查节点是否匹配简单选择器
static int _match_simple(html_node_t *node, simple_sel_t *sel) {
    if (!node || node->type != HTML_NODE_ELEMENT) return 0;
    // 标签名
    if (sel->tag && !_str_ieq(node->tag, sel->tag)) return 0;
    // ID
    if (sel->id) {
        char *id_val = html_get_attr(node, "id");
        if (!id_val || !_str_eq(id_val, sel->id)) {
            free(id_val);
            return 0;
        }
        free(id_val);
    }
    // 类名
    for (int i = 0; i < sel->class_count; i++) {
        char *class_val = html_get_attr(node, "class");
        if (!class_val) return 0;
        // 检查 class 列表中是否包含 sel->classes[i]
        int found = 0;
        const char *p = class_val;
        while (*p) {
            while (*p && isspace((unsigned char)*p)) p++;
            const char *start = p;
            while (*p && !isspace((unsigned char)*p)) p++;
            size_t plen = p - start;
            if (plen == strlen(sel->classes[i]) && strncmp(start, sel->classes[i], plen) == 0) {
                found = 1;
                break;
            }
        }
        free(class_val);
        if (!found) return 0;
    }
    // 属性选择器
    if (sel->has_attr_sel) {
        char *attr_val = html_get_attr(node, sel->attr_sel.name);
        if (sel->attr_sel.op == 0) {
            // [attr] 只检查存在性
            if (!attr_val) return 0;
        } else if (!attr_val) {
            return 0;
        } else {
            switch (sel->attr_sel.op) {
                case '=':
                    if (!_str_eq(attr_val, sel->attr_sel.value)) return 0;
                    break;
                case '^':
                    if (strncmp(attr_val, sel->attr_sel.value, strlen(sel->attr_sel.value)) != 0) return 0;
                    break;
                case '$': {
                    size_t alen = strlen(attr_val);
                    size_t blen = strlen(sel->attr_sel.value);
                    if (alen < blen || strcmp(attr_val + alen - blen, sel->attr_sel.value) != 0) return 0;
                    break;
                }
                case '*':
                    if (!strstr(attr_val, sel->attr_sel.value)) return 0;
                    break;
            }
        }
        free(attr_val);
    }
    // 伪类 :nth-child / :first-child / :last-child / :eq
    if (sel->nth_child != -1) {
        if (!node->parent) return 0;
        int elem_idx = 0;
        int total = 0;
        for (int i = 0; i < node->parent->child_count; i++) {
            if (node->parent->children[i]->type == HTML_NODE_ELEMENT) {
                total++;
                if (node->parent->children[i] == node) elem_idx = total;
            }
        }
        if (sel->nth_child == 0) { // first-child
            if (elem_idx != 1) return 0;
        } else if (sel->nth_child == -2) { // last-child
            if (elem_idx != total) return 0;
        } else {
            if (elem_idx != sel->nth_child) return 0;
        }
    }
    return 1;
}

// 递归匹配组合选择器
// node: 待匹配的节点，sel_idx: 当前要匹配的选择器索引
static int _match_compound(html_node_t *node, compound_sel_t *cs, int sel_idx) {
    if (sel_idx < 0) return 1; // 所有选择器都匹配了
    if (!node || node->type != HTML_NODE_ELEMENT) return 0;

    simple_sel_t *sel = &cs->sels[sel_idx];
    if (!_match_simple(node, sel)) return 0;

    if (sel_idx == 0) return 1; // 第一个选择器，无需检查组合器

    char comb = cs->combinators[sel_idx - 1];
    if (comb == ' ') {
        // 后代：向上查找祖先匹配
        html_node_t *p = node->parent;
        while (p && p->type != HTML_NODE_DOCUMENT) {
            if (_match_compound(p, cs, sel_idx - 1)) return 1;
            p = p->parent;
        }
        return 0;
    } else if (comb == '>') {
        // 子代：父节点必须匹配
        return _match_compound(node->parent, cs, sel_idx - 1);
    } else if (comb == '+') {
        // 相邻：前一个兄弟节点必须匹配
        if (!node->parent) return 0;
        html_node_t *prev = NULL;
        for (int i = 0; i < node->parent->child_count; i++) {
            if (node->parent->children[i] == node) break;
            if (node->parent->children[i]->type == HTML_NODE_ELEMENT) {
                prev = node->parent->children[i];
            }
        }
        return prev ? _match_compound(prev, cs, sel_idx - 1) : 0;
    }
    return 0;
}

// 递归遍历 DOM 树，收集匹配的元素
typedef struct {
    html_node_t **results;
    int count;
    int capacity;
} result_list_t;

static void _collect(html_node_t *node, compound_sel_t *groups, int group_count, result_list_t *rl) {
    if (!node) return;
    if (node->type == HTML_NODE_ELEMENT) {
        for (int g = 0; g < group_count; g++) {
            compound_sel_t *cs = &groups[g];
            if (cs->sel_count > 0 && _match_compound(node, cs, cs->sel_count - 1)) {
                // 添加到结果（去重）
                int found = 0;
                for (int i = 0; i < rl->count; i++) {
                    if (rl->results[i] == node) { found = 1; break; }
                }
                if (!found) {
                    if (rl->count >= rl->capacity) {
                        int new_cap = rl->capacity == 0 ? 16 : rl->capacity * 2;
                        rl->results = (html_node_t **)realloc(rl->results, new_cap * sizeof(html_node_t *));
                        rl->capacity = new_cap;
                    }
                    rl->results[rl->count++] = node;
                }
                break; // 匹配一个组即可
            }
        }
    }
    for (int i = 0; i < node->child_count; i++) {
        _collect(node->children[i], groups, group_count, rl);
    }
}

html_node_t **html_query_all(html_node_t *root, const char *selector, int *out_count) {
    if (!root || !selector || !out_count) return NULL;
    *out_count = 0;

    int group_count = 0;
    compound_sel_t *groups = _parse_selector(selector, &group_count);
    if (!groups || group_count == 0) {
        _free_selector_groups(groups, group_count);
        return NULL;
    }

    result_list_t rl = {0, 0, 0};
    _collect(root, groups, group_count, &rl);
    _free_selector_groups(groups, group_count);

    *out_count = rl.count;
    return rl.results;
}

html_node_t *html_query_first(html_node_t *root, const char *selector) {
    int count = 0;
    html_node_t **results = html_query_all(root, selector, &count);
    if (!results || count == 0) {
        free(results);
        return NULL;
    }
    html_node_t *first = results[0];
    free(results);
    return first;
}

// ---------- 结果提取 ----------

// 辅助：递归计算文本总长度
static size_t _calc_text_len(html_node_t *n) {
    if (!n) return 0;
    size_t total = 0;
    if (n->type == HTML_NODE_TEXT && n->text) {
        total += strlen(n->text);
    }
    for (int i = 0; i < n->child_count; i++) {
        total += _calc_text_len(n->children[i]);
    }
    return total;
}

// 辅助：递归收集文本到 buffer
static size_t _collect_text_to(html_node_t *n, char *buf, size_t pos) {
    if (!n) return pos;
    if (n->type == HTML_NODE_TEXT && n->text) {
        size_t len = strlen(n->text);
        memcpy(buf + pos, n->text, len);
        pos += len;
    }
    for (int i = 0; i < n->child_count; i++) {
        pos = _collect_text_to(n->children[i], buf, pos);
    }
    return pos;
}

char *html_get_text(html_node_t *node, size_t *out_len) {
    if (!node) return NULL;
    if (out_len) *out_len = 0;

    size_t total = _calc_text_len(node);
    char *result = (char *)malloc(total + 1);
    if (!result) return NULL;
    size_t pos = _collect_text_to(node, result, 0);
    result[pos] = 0;
    if (out_len) *out_len = pos;
    return result;
}

// 辅助：序列化节点为 HTML
static void _serialize(html_node_t *node, char **buf, size_t *len, size_t *cap, int include_self) {
    if (!node) return;
    if (node->type == HTML_NODE_TEXT && node->text) {
        size_t tlen = strlen(node->text);
        if (*len + tlen + 1 > *cap) {
            *cap = (*cap == 0 ? 256 : *cap * 2) + tlen;
            *buf = (char *)realloc(*buf, *cap);
        }
        memcpy(*buf + *len, node->text, tlen);
        *len += tlen;
        return;
    }
    if (node->type == HTML_NODE_COMMENT && node->text) {
        size_t clen = strlen(node->text) + 7;
        if (*len + clen + 1 > *cap) {
            *cap = (*cap == 0 ? 256 : *cap * 2) + clen;
            *buf = (char *)realloc(*buf, *cap);
        }
        *len += sprintf(*buf + *len, "<!--%s-->", node->text);
        return;
    }
    if (node->type == HTML_NODE_ELEMENT) {
        if (include_self) {
            // 开始标签
            size_t tlen = strlen(node->tag) + 2;
            if (*len + tlen + 1 > *cap) {
                *cap = (*cap == 0 ? 256 : *cap * 2) + tlen;
                *buf = (char *)realloc(*buf, *cap);
            }
            *len += sprintf(*buf + *len, "<%s", node->tag);
            // 属性
            for (int i = 0; i < node->attr_count; i++) {
                if (node->attrs[i].value) {
                    size_t alen = strlen(node->attrs[i].name) + strlen(node->attrs[i].value) + 6;
                    if (*len + alen + 1 > *cap) {
                        *cap = (*cap == 0 ? 256 : *cap * 2) + alen;
                        *buf = (char *)realloc(*buf, *cap);
                    }
                    *len += sprintf(*buf + *len, " %s=\"%s\"", node->attrs[i].name, node->attrs[i].value);
                } else {
                    size_t alen = strlen(node->attrs[i].name) + 2;
                    if (*len + alen + 1 > *cap) {
                        *cap = (*cap == 0 ? 256 : *cap * 2) + alen;
                        *buf = (char *)realloc(*buf, *cap);
                    }
                    *len += sprintf(*buf + *len, " %s", node->attrs[i].name);
                }
            }
            if (_is_void_tag(node->tag)) {
                *len += sprintf(*buf + *len, ">");
                return;
            }
            *len += sprintf(*buf + *len, ">");
        }
        // 子节点
        for (int i = 0; i < node->child_count; i++) {
            _serialize(node->children[i], buf, len, cap, 1);
        }
        if (include_self) {
            size_t clen = strlen(node->tag) + 3;
            if (*len + clen + 1 > *cap) {
                *cap = (*cap == 0 ? 256 : *cap * 2) + clen;
                *buf = (char *)realloc(*buf, *cap);
            }
            *len += sprintf(*buf + *len, "</%s>", node->tag);
        }
    }
}

char *html_get_inner_html(html_node_t *node, size_t *out_len) {
    if (!node) return NULL;
    char *buf = NULL;
    size_t len = 0, cap = 0;
    for (int i = 0; i < node->child_count; i++) {
        _serialize(node->children[i], &buf, &len, &cap, 1);
    }
    if (!buf) {
        buf = (char *)malloc(1);
        buf[0] = 0;
    }
    if (out_len) *out_len = len;
    return buf;
}

char *html_get_outer_html(html_node_t *node, size_t *out_len) {
    if (!node) return NULL;
    char *buf = NULL;
    size_t len = 0, cap = 0;
    _serialize(node, &buf, &len, &cap, 1);
    if (!buf) {
        buf = (char *)malloc(1);
        buf[0] = 0;
    }
    if (out_len) *out_len = len;
    return buf;
}

char *html_get_attr(html_node_t *node, const char *attr_name) {
    if (!node || node->type != HTML_NODE_ELEMENT || !attr_name) return NULL;
    for (int i = 0; i < node->attr_count; i++) {
        if (_str_ieq(node->attrs[i].name, attr_name)) {
            return node->attrs[i].value ? _str_dup(node->attrs[i].value, strlen(node->attrs[i].value)) : _str_dup("", 0);
        }
    }
    return NULL;
}

const char *html_get_tag_name(html_node_t *node) {
    if (!node || node->type != HTML_NODE_ELEMENT) return NULL;
    return node->tag;
}
