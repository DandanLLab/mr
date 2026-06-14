package com.mr.app.analyzeRule

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import org.jsoup.select.Collector
import org.jsoup.select.Elements

/**
 * 书源规则解析 - JSoup 模式
 * 移植自 legado AnalyzeByJSoup.kt
 */
@Suppress("SpellCheckingInspection", "ControlFlowWithEmptyBody")
class AnalyzeByJSoup(doc: Any) {

    companion object {
        private val nullElement: Element? = null
        @Suppress("unused")
        private val nullSet = setOf(nullElement)
    }

    private var element: Element = parse(doc)

    private fun parse(doc: Any): Element {
        if (doc is Element) {
            return doc
        }
        val str = doc.toString()
        kotlin.runCatching {
            if (str.startsWith("<?xml", true)) {
                return Jsoup.parse(str, Parser.xmlParser())
            }
        }
        // 关键修复：当传入的是 HTML 片段（如单个 <a> / <li> / <div> 等 element 的 outerHtml）
        // 时，Jsoup.parse() 会把它包装成完整的 <html><body>...</body></html> Document，
        // 导致后续 element.attr("href") 取不到属性（href 在 body 的子节点上）。
        // 这里检测：如果字符串看起来像 HTML 片段（不以 <html / <!DOCTYPE 开头），
        // 用 parseBodyFragment 然后返回 body 的第一个有效子节点，
        // 让后续 element.attr() 能直接命中属性。
        kotlin.runCatching {
            val trimmed = str.trimStart()
            val isFullDoc = trimmed.startsWith("<html", true) ||
                            trimmed.startsWith("<!doctype", true)
            if (!isFullDoc && trimmed.startsWith("<")) {
                val doc2 = Jsoup.parseBodyFragment(str)
                val body = doc2.body()
                val children = body.children()
                if (children.size == 1) {
                    android.util.Log.d("AnalyzeByJSoup", "parse: fragment detected, unwrapped to single child <${children[0].tagName()}>")
                    return children[0]
                }
                // 多个根节点：保留 body，后续逻辑遍历 children 仍可工作
                if (children.isNotEmpty()) {
                    android.util.Log.d("AnalyzeByJSoup", "parse: fragment detected, ${children.size} root nodes, keep body")
                    return body
                }
            }
        }
        return Jsoup.parse(str)
    }

    internal fun getElements(rule: String) = getElements(element, rule)

    /**
     * 找到最后一个作为"提取规则分隔符"的 @
     * 必须在所有括号外（避免误识别 :contains(@text)、[href*=@] 等）
     */
    private fun findLastExtractAt(rule: String): Int {
        var depth = 0
        var lastAt = -1
        for (i in rule.indices) {
            when (rule[i]) {
                '(', '[' -> depth++
                ')', ']' -> depth--
                '@' -> if (depth == 0) lastAt = i
            }
        }
        return lastAt
    }

    internal fun getString(ruleStr: String): String? {
        if (ruleStr.isEmpty()) {
            return null
        }
        val list = getStringList(ruleStr)
        if (list.isEmpty()) {
            return null
        }
        if (list.size == 1) {
            return list.first()
        }
        return list.joinToString("\n")
    }

    internal fun getString0(ruleStr: String) =
        getStringList(ruleStr).let { if (it.isEmpty()) "" else it[0] }

    internal fun getStringList(ruleStr: String): List<String> {
        val textS = ArrayList<String>()
        if (ruleStr.isEmpty()) return textS

        val sourceRule = SourceRule(ruleStr)
        android.util.Log.d("AnalyzeByJSoup", "getStringList: rule=[$ruleStr] isCss=${sourceRule.isCss} elementsRule=[${sourceRule.elementsRule}]")

        if (sourceRule.elementsRule.isEmpty()) {
            textS.add(element.data())
        } else {
            val ruleAnalyzes = RuleAnalyzer(sourceRule.elementsRule)
            val ruleStrS = ruleAnalyzes.splitRule("&&", "||", "%%")

            val results = ArrayList<List<String>>()
            for (ruleStrX in ruleStrS) {
                val temp: ArrayList<String>? =
                    if (sourceRule.isCss) {
                        // @CSS: 前缀的纯 CSS 选择器路径
                        // 找最后一个 @ 作为提取规则（@text/@href 等）
                        try {
                            val lastIndex = findLastExtractAt(ruleStrX)
                            if (lastIndex < 0) {
                                getResultLast(element.select(ruleStrX), "html")
                            } else {
                                getResultLast(
                                    element.select(ruleStrX.take(lastIndex)),
                                    ruleStrX.substring(lastIndex + 1)
                                )
                            }
                        } catch (e: Exception) {
                            null
                        }
                    } else {
                        // legado 私有路径：findIndexSet + getElementsSingle
                        getResultList(ruleStrX)
                    }

                if (!temp.isNullOrEmpty()) {
                    results.add(temp)
                    if (ruleAnalyzes.elementsType == "||") break
                }
            }
            if (results.isNotEmpty()) {
                if ("%%" == ruleAnalyzes.elementsType) {
                    for (i in results[0].indices) {
                        for (temp in results) {
                            if (i < temp.size) {
                                textS.add(temp[i])
                            }
                        }
                    }
                } else {
                    for (temp in results) {
                        textS.addAll(temp)
                    }
                }
            }
        }
        return textS
    }

    private fun getElements(temp: Element?, rule: String): Elements {
        if (temp == null || rule.isEmpty()) return Elements()

        val elements = Elements()
        val sourceRule = SourceRule(rule)
        val ruleAnalyzes = RuleAnalyzer(sourceRule.elementsRule)
        val ruleStrS = ruleAnalyzes.splitRule("&&", "||", "%%")

        val elementsList = ArrayList<Elements>()
        if (sourceRule.isCss) {
            for (ruleStr in ruleStrS) {
                val tempS = try {
                    temp.select(ruleStr)
                } catch (e: Exception) {
                    // CSS 选择器解析失败，fallback 到 legado 私有路径
                    ElementsSingle().getElementsSingle(temp, ruleStr)
                }
                elementsList.add(tempS)
                if (tempS.isNotEmpty() && ruleAnalyzes.elementsType == "||") {
                    break
                }
            }
        } else {
            for (ruleStr in ruleStrS) {
                val rsRule = RuleAnalyzer(ruleStr)
                rsRule.trim()
                val rs = rsRule.splitRule("@")

                val el = if (rs.size > 1) {
                    val el = Elements()
                    el.add(temp)
                    for (rl in rs) {
                        val es = Elements()
                        for (et in el) {
                            es.addAll(getElements(et, rl))
                        }
                        el.clear()
                        el.addAll(es)
                    }
                    el
                } else ElementsSingle().getElementsSingle(temp, ruleStr)

                elementsList.add(el)
                if (el.isNotEmpty() && ruleAnalyzes.elementsType == "||") {
                    break
                }
            }
        }
        if (elementsList.isNotEmpty()) {
            if ("%%" == ruleAnalyzes.elementsType) {
                for (i in 0 until elementsList[0].size) {
                    for (es in elementsList) {
                        if (i < es.size) {
                            elements.add(es[i])
                        }
                    }
                }
            } else {
                for (es in elementsList) {
                    elements.addAll(es)
                }
            }
        }
        return elements
    }

    private fun getResultList(ruleStr: String): ArrayList<String>? {
        if (ruleStr.isEmpty()) return null

        var elements = Elements()
        elements.add(element)

        val rule = RuleAnalyzer(ruleStr)
        rule.trim()
        val rules = rule.splitRule("@")
        android.util.Log.d("AnalyzeByJSoup", "getResultList: rule=[$ruleStr] splitRules=${rules.map { it }}")
        val last = rules.size - 1
        for (i in 0 until last) {
            val es = Elements()
            for (elt in elements) {
                es.addAll(ElementsSingle().getElementsSingle(elt, rules[i]))
            }
            elements.clear()
            elements = es
            android.util.Log.d("AnalyzeByJSoup", "getResultList step[$i]: rule=[${rules[i]}] found=${elements.size} elements")
        }
        val result = if (elements.isEmpty()) null else getResultLast(elements, rules[last])
        android.util.Log.d("AnalyzeByJSoup", "getResultList final: elements=${elements.size} lastRule=[${rules[last]}] resultCount=${result?.size ?: 0} resultPreview=${result?.firstOrNull()?.take(100)}")
        return result
    }

    private fun getResultLast(elements: Elements, lastRule: String): ArrayList<String> {
        val textS = ArrayList<String>()
        when (lastRule) {
            "text" -> for (element in elements) {
                val text = element.text()
                if (text.isNotEmpty()) {
                    textS.add(text)
                }
            }

            "textNodes" -> for (element in elements) {
                val tn = arrayListOf<String>()
                val contentEs = element.textNodes()
                for (item in contentEs) {
                    val text = item.text().trim { it <= ' ' }
                    if (text.isNotEmpty()) {
                        tn.add(text)
                    }
                }
                if (tn.isNotEmpty()) {
                    textS.add(tn.joinToString("\n"))
                }
            }

            "ownText" -> for (element in elements) {
                val text = element.ownText()
                if (text.isNotEmpty()) {
                    textS.add(text)
                }
            }

            "html" -> {
                elements.select("script").remove()
                elements.select("style").remove()
                val html = elements.outerHtml()
                if (html.isNotEmpty()) {
                    textS.add(html)
                }
            }

            "all" -> textS.add(elements.outerHtml())
            else -> for (element in elements) {
                var url = element.attr(lastRule)
                android.util.Log.d("AnalyzeByJSoup", "getResultLast[attr]: lastRule=[$lastRule] elementClass=${element.javaClass.simpleName} tagName=${element.tagName()} directAttr=[$url]")
                // 修复：当 element 是 Document 根节点（HTML 残片被 Jsoup.parse 包装）
                // 时，attr() 取不到属性，需要下钻到 body 内的实际节点
                if (url.isBlank() && (element is org.jsoup.nodes.Document || element.tagName() == "#root")) {
                    val body = element.select("body").first() ?: element
                    // 优先：body 唯一子节点
                    val children = body.children()
                    android.util.Log.d("AnalyzeByJSoup", "getResultLast[attr] doc-drilldown: bodyChildren=${children.size} firstTag=${children.firstOrNull()?.tagName()}")
                    if (children.size == 1) {
                        url = children[0].attr(lastRule)
                    } else {
                        // 多子节点：遍历，第一个有该属性的胜出
                        for (child in children) {
                            val v = child.attr(lastRule)
                            if (v.isNotBlank()) {
                                url = v
                                break
                            }
                        }
                    }
                    // 仍为空：尝试整个 body 下任意带该属性的节点
                    if (url.isBlank()) {
                        val any = body.select("[$lastRule]").first()
                        if (any != null) url = any.attr(lastRule)
                    }
                    android.util.Log.d("AnalyzeByJSoup", "getResultLast[attr] doc-drilldown result: url=[$url]")
                }
                if (url.isBlank() || textS.contains(url)) continue
                textS.add(url)
            }
        }
        return textS
    }

    @Suppress("UNCHECKED_CAST")
    data class ElementsSingle(
        var split: Char = '.',
        var beforeRule: String = "",
        val indexDefault: MutableList<Int> = mutableListOf(),
        val indexes: MutableList<Any> = mutableListOf()
    ) {
        fun getElementsSingle(temp: Element, rule: String): Elements {
            findIndexSet(rule)

            android.util.Log.d("AnalyzeByJSoup", "getElementsSingle: rule=[$rule] beforeRule=[$beforeRule] split=[$split] indexDefault=$indexDefault indexes=$indexes")

            var elements =
                if (beforeRule.isEmpty()) temp.children()
                else {
                    val rules = beforeRule.split(".")
                    android.util.Log.d("AnalyzeByJSoup", "getElementsSingle: rules=${rules.map { it }} rules[0]=[${rules[0]}]")
                    when (rules[0]) {
                        "children" -> temp.children()
                        "class" -> temp.getElementsByClass(rules[1])
                        "tag" -> temp.getElementsByTag(rules[1])
                        "id" -> Collector.collect(org.jsoup.select.Evaluator.Id(rules[1]), temp)
                        "text" -> temp.getElementsContainingOwnText(rules[1])
                        else -> temp.select(beforeRule)
                    }
                }

            android.util.Log.d("AnalyzeByJSoup", "getElementsSingle: found=${elements.size} elements")

            val len = elements.size
            val lastIndexes = (indexDefault.size - 1).takeIf { it != -1 } ?: (indexes.size - 1)
            val indexSet = mutableSetOf<Int>()

            if (indexes.isEmpty()) for (ix in lastIndexes downTo 0) {
                val it = indexDefault[ix]
                if (it in 0 until len) indexSet.add(it)
                else if (it < 0 && len >= -it) indexSet.add(it + len)
            } else for (ix in lastIndexes downTo 0) {
                if (indexes[ix] is Triple<*, *, *>) {
                    val (startX, endX, stepX) = indexes[ix] as Triple<Int?, Int?, Int>

                    var start = startX ?: 0
                    if (start < 0) start += len

                    var end = endX ?: (len - 1)
                    if (end < 0) end += len

                    if ((start < 0 && end < 0) || (start >= len && end >= len)) {
                        continue
                    }

                    if (start >= len) start = len - 1
                    else if (start < 0) start = 0

                    if (end >= len) end = len - 1
                    else if (end < 0) end = 0

                    if (start == end || stepX >= len) {
                        indexSet.add(start)
                        continue
                    }

                    val step =
                        if (stepX > 0) stepX else if (-stepX < len) stepX + len else 1

                    indexSet.addAll(if (end > start) start..end step step else start downTo end step step)
                } else {
                    val it = indexes[ix] as Int
                    if (it in 0 until len) indexSet.add(it)
                    else if (it < 0 && len >= -it) indexSet.add(it + len)
                }
            }

            if (split == '!') {
                // 排除模式：移除 indexSet 中的索引，保留其余元素
                val es = Elements()
                for (i in 0 until len) {
                    if (i !in indexSet) es.add(elements[i])
                }
                elements = es
            } else if (split == '.') {
                val es = Elements()
                for (pcInt in indexSet) {
                    if (pcInt in 0 until elements.size) es.add(elements[pcInt])
                }
                elements = es
            }

            return elements
        }

        private fun findIndexSet(rule: String) {
            val rus = rule.trim { it <= ' ' }
            var len = rus.length
            var curInt: Int?
            var curMinus = false
            val curList = mutableListOf<Int?>()
            var l = ""

            val head = rus.last() == ']'

            if (head) {
                len--
                while (len-- >= 0) {
                    var rl = rus[len]
                    if (rl == ' ') continue

                    if (rl in '0'..'9') l = rl + l
                    else if (rl == '-') curMinus = true
                    else {
                        curInt = if (l.isEmpty()) null else if (curMinus) -l.toInt() else l.toInt()

                        when (rl) {
                            ':' -> curList.add(curInt)
                            else -> {
                                if (curList.isEmpty()) {
                                    if (curInt == null) break
                                    indexes.add(curInt)
                                } else {
                                    indexes.add(
                                        Triple(
                                            curInt,
                                            curList.last(),
                                            if (curList.size == 2) curList.first() else 1
                                        )
                                    )
                                    curList.clear()
                                }

                                if (rl == '!') {
                                    split = '!'
                                    do {
                                        rl = rus[--len]
                                    } while (len > 0 && rl == ' ')
                                }

                                if (rl == '[') {
                                    beforeRule = rus.substring(0, len)
                                    return
                                }

                                if (rl != ',') break
                            }
                        }
                        l = ""
                        curMinus = false
                    }
                }
            } else while (len-- >= 0) {
                val rl = rus[len]
                if (rl == ' ') continue

                if (rl in '0'..'9') l = rl + l
                else if (rl == '-') curMinus = true
                else {
                    if (rl == '!' || rl == '.' || rl == ':') {
                        indexDefault.add(if (curMinus) -l.toInt() else l.toInt())
                        if (rl != ':') {
                            split = rl
                            beforeRule = rus.take(len)
                            return
                        }
                    } else break
                    l = ""
                    curMinus = false
                }
            }

            split = ' '
            beforeRule = rus
        }
    }

    /**
     * 完全对齐 legado 原版 SourceRule：
     * 只认 @CSS: 前缀，其余全部走 getResultList（legado 私有路径）
     * 不做任何自动 CSS 检测，避免 .font_max / .page-item.4 被误判
     */
    internal class SourceRule(ruleStr: String) {
        var isCss = false
        var elementsRule: String = if (ruleStr.startsWith("@CSS:", true)) {
            isCss = true
            ruleStr.substring(5).trim { it <= ' ' }
        } else {
            ruleStr
        }
    }
}
