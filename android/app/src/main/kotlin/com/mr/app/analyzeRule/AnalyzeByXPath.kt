package com.mr.app.analyzeRule

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import org.jsoup.select.Elements

/**
 * XPath 规则解析
 * 使用 JSoup 1.22.2+ 内置的 selectXpath() 方法
 */
class AnalyzeByXPath(doc: Any) {
    private var element: Element = parse(doc)

    private fun parse(doc: Any): Element {
        if (doc is Element) return doc
        kotlin.runCatching {
            if (doc.toString().startsWith("<?xml", true)) {
                return Jsoup.parse(doc.toString(), Parser.xmlParser())
            }
        }
        return Jsoup.parse(doc.toString())
    }

    internal fun getElements(xPath: String): List<Any> {
        if (xPath.isEmpty()) return emptyList()

        val ruleAnalyzes = RuleAnalyzer(xPath)
        val rules = ruleAnalyzes.splitRule("&&", "||", "%%")

        val results = ArrayList<List<Any>>()
        for (rl in rules) {
            val temp = getElementsSingle(rl)
            if (temp.isNotEmpty()) {
                results.add(temp)
                if (ruleAnalyzes.elementsType == "||") break
            }
        }
        if (results.isEmpty()) return emptyList()

        val elements = ArrayList<Any>()
        if ("%%" == ruleAnalyzes.elementsType) {
            for (i in results[0].indices) {
                for (temp in results) {
                    if (i < temp.size) {
                        elements.add(temp[i])
                    }
                }
            }
        } else {
            for (temp in results) {
                elements.addAll(temp)
            }
        }
        return elements
    }

    private fun getElementsSingle(xPath: String): List<Any> {
        return try {
            val elements = element.selectXpath(xPath)
            elements.toList()
        } catch (_: Exception) {
            emptyList()
        }
    }

    internal fun getStringList(xPath: String): List<String> {
        if (xPath.isEmpty()) return emptyList()

        val ruleAnalyzes = RuleAnalyzer(xPath)
        val rules = ruleAnalyzes.splitRule("&&", "||", "%%")

        val results = ArrayList<List<String>>()
        for (rl in rules) {
            val temp = getStringListSingle(rl)
            if (temp.isNotEmpty()) {
                results.add(temp)
                if (ruleAnalyzes.elementsType == "||") break
            }
        }
        if (results.isEmpty()) return emptyList()

        val textS = ArrayList<String>()
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
        return textS
    }

    private fun getStringListSingle(xPath: String): List<String> {
        return try {
            val elements = element.selectXpath(xPath)
            elements.map { it.text() }.filter { it.isNotEmpty() }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun getString(rule: String): String? {
        if (rule.isEmpty()) return null

        val ruleAnalyzes = RuleAnalyzer(rule)
        val rules = ruleAnalyzes.splitRule("&&", "||")

        if (rules.size == 1) {
            return getStringSingle(rules[0])
        } else {
            val textList = arrayListOf<String>()
            for (rl in rules) {
                val temp = getString(rl)
                if (!temp.isNullOrEmpty()) {
                    textList.add(temp)
                    if (ruleAnalyzes.elementsType == "||") break
                }
            }
            return textList.joinToString("\n")
        }
    }

    private fun getStringSingle(xPath: String): String? {
        return try {
            val elements = element.selectXpath(xPath)
            if (elements.isEmpty()) null
            else elements.joinToString("\n") { it.text() }
        } catch (_: Exception) {
            null
        }
    }
}
