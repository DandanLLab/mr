package com.mr.app.analyzeRule

import android.util.Log
import org.jsoup.nodes.Element
import java.net.URL
import java.util.Locale
import java.util.regex.Pattern

/**
 * 核心规则解析引擎
 * 移植自 legado AnalyzeRule.kt，适配 Flutter 插件环境
 */
@Suppress("unused", "RegExpRedundantEscape", "MemberVisibilityCanBePrivate", "SpellCheckingInspection")
class AnalyzeRule(
    private var content: Any? = null,
    private var baseUrl: String? = null,
    private var source: Map<String, Any?>? = null,
    private var variableMap: HashMap<String, String> = HashMap()
) {

    /** JS 评估回调，由调用方注入 */
    var jsEvaluator: ((String, Any?) -> Any?)? = null

    // 对齐 legado：book/chapter 上下文，JS 中可通过 book/chapter 变量访问
    private var book: Map<String, Any?>? = null
    private var chapter: Map<String, Any?>? = null

    private fun evalJS(jsStr: String, result: Any?): Any? {
        return jsEvaluator?.invoke(jsStr, result)
    }

    private var isJSON: Boolean = false
    private var isRegex: Boolean = false
    private var redirectUrl: URL? = null

    private var analyzeByXPath: AnalyzeByXPath? = null
    private var analyzeByJSoup: AnalyzeByJSoup? = null
    private var analyzeByJSonPath: AnalyzeByJSonPath? = null

    private val stringRuleCache = hashMapOf<String, List<SourceRule>>()
    private val regexCache = hashMapOf<String, Regex?>()

    companion object {
        private const val TAG = "AnalyzeRule"
        private val putPattern = Pattern.compile("@put:(\\{[^}]+?\\})", Pattern.CASE_INSENSITIVE)
        private val evalPattern =
            Pattern.compile("@get:\\{[^}]+?\\}|\\{\\{[\\w\\W]*?\\}\\}", Pattern.CASE_INSENSITIVE)
        private val regexPattern = Pattern.compile("\\$\\d{1,2}")
        private val jsPattern = Pattern.compile("<js>([\\s\\S]*?)</js>|@js:([\\s\\S]*)", Pattern.CASE_INSENSITIVE)
        private val webJsPattern = Pattern.compile("<webJs>([\\s\\S]*?)</webJs>", Pattern.CASE_INSENSITIVE)
    }

    fun setContent(content: Any?, baseUrl: String? = null): AnalyzeRule {
        if (content == null) return this
        this.content = content
        isJSON = when (content) {
            is Element -> false
            else -> content.toString().let { str ->
                val trimmed = str.trimStart()
                // 对齐 legado：检查首尾是否匹配 JSON 格式
                (trimmed.startsWith("{") && trimmed.endsWith("}")) ||
                (trimmed.startsWith("[") && trimmed.endsWith("]"))
            }
        }
        baseUrl?.let { this.baseUrl = it }
        analyzeByXPath = null
        analyzeByJSoup = null
        analyzeByJSonPath = null
        return this
    }

    /**
     * 对齐 legado：设置 HTTP 重定向后的实际 URL
     * 用于 getAbsoluteURL 拼接相对路径时作为基准
     * legado 在 BookChapterList/BookContent/BookInfo 中都会调用 setRedirectUrl
     */
    fun setRedirectUrl(url: String): AnalyzeRule {
        try {
            redirectUrl = java.net.URL(url)
        } catch (_: Exception) {
        }
        return this
    }

    fun setBaseUrl(baseUrl: String?): AnalyzeRule {
        baseUrl?.let { this.baseUrl = it }
        return this
    }

    fun setSource(source: Map<String, Any?>?): AnalyzeRule {
        this.source = source
        return this
    }

    fun setBook(book: Map<String, Any?>?): AnalyzeRule {
        this.book = book
        return this
    }

    fun setChapter(chapter: Map<String, Any?>?): AnalyzeRule {
        this.chapter = chapter
        return this
    }

    fun setVariableMap(map: HashMap<String, String>): AnalyzeRule {
        this.variableMap = map
        return this
    }

    private fun getAnalyzeByXPath(o: Any): AnalyzeByXPath {
        return if (o !== content) {
            AnalyzeByXPath(o)
        } else {
            if (analyzeByXPath == null) {
                analyzeByXPath = AnalyzeByXPath(content!!)
            }
            analyzeByXPath!!
        }
    }

    private fun getAnalyzeByJSoup(o: Any): AnalyzeByJSoup {
        return if (o !== content) {
            AnalyzeByJSoup(o)
        } else {
            if (analyzeByJSoup == null) {
                analyzeByJSoup = AnalyzeByJSoup(content!!)
            }
            analyzeByJSoup!!
        }
    }

    private fun getAnalyzeByJSonPath(o: Any): AnalyzeByJSonPath {
        return if (o !== content) {
            AnalyzeByJSonPath(o)
        } else {
            if (analyzeByJSonPath == null) {
                analyzeByJSonPath = AnalyzeByJSonPath(content!!)
            }
            analyzeByJSonPath!!
        }
    }

    fun getStringList(rule: String?, mContent: Any? = null, isUrl: Boolean = false): List<String>? {
        if (rule.isNullOrEmpty()) return null
        val ruleList = splitSourceRuleCacheString(rule)
        android.util.Log.d("AnalyzeRule", "getStringList: ruleStr=[${rule.take(80)}] splitSize=${ruleList.size} modes=${ruleList.map { it.mode }}")
        return getStringList(ruleList, mContent, isUrl)
    }

    fun getStringList(
        ruleList: List<SourceRule>,
        mContent: Any? = null,
        isUrl: Boolean = false
    ): List<String>? {
        var result: Any? = null
        val content = mContent ?: this.content
        if (content != null && ruleList.isNotEmpty()) {
            result = content
            for ((idx, sourceRule) in ruleList.withIndex()) {
                putRule(sourceRule.putMap)
                sourceRule.makeUpRule(result)
                result ?: continue
                val rule = sourceRule.rule
                if (rule.isNotEmpty()) {
                    result = when (sourceRule.mode) {
                        Mode.Js -> evalJS(rule, result)
                        Mode.Json -> getAnalyzeByJSonPath(result).getStringList(rule)
                        Mode.XPath -> getAnalyzeByXPath(result).getStringList(rule)
                        Mode.Default -> getAnalyzeByJSoup(result).getStringList(rule)
                        else -> rule
                    }
                    android.util.Log.d("AnalyzeRule", "getStringList step[$idx]: mode=${sourceRule.mode} rule=[${rule.take(60)}] resultType=${result?.javaClass?.simpleName} resultPreview=${when(result) { is List<*> -> "List(${result.size})"; else -> result?.toString()?.take(80) }}")
                }
                if (sourceRule.replaceRegex.isNotEmpty() && result is List<*>) {
                    val newList = ArrayList<String>()
                    for (item in result) {
                        newList.add(replaceRegex(item.toString(), sourceRule))
                    }
                    result = newList
                } else if (sourceRule.replaceRegex.isNotEmpty()) {
                    result = replaceRegex(result.toString(), sourceRule)
                }
            }
        }
        if (result == null) return null
        if (result is String) {
            result = result.split("\n")
        }
        if (isUrl) {
            val urlList = ArrayList<String>()
            if (result is List<*>) {
                for (url in result) {
                    if (url == null) continue
                    val raw = url.toString()
                    val absoluteURL = getAbsoluteURL(redirectUrl, raw)
                    android.util.Log.d("AnalyzeRule", "getStringList[isUrl] base=[$baseUrl] redirect=[$redirectUrl] raw=[$raw] -> abs=[$absoluteURL]")
                    if (absoluteURL.isNotEmpty() && !urlList.contains(absoluteURL)) {
                        urlList.add(absoluteURL)
                    }
                }
            }
            return urlList
        }
        // 关键修复：result 可能是 List<Any>（JS 解包后元素未必是 String），
        // 原来 `as? List<String>` 强转会失败返回 null，这里逐项 toString 保证类型安全
        if (result is List<*>) {
            return result.mapNotNull { it?.toString() }
        }
        return listOf(result.toString())
    }

    fun getString(ruleStr: String?, mContent: Any? = null, isUrl: Boolean = false, unescape: Boolean = true): String {
        if (ruleStr.isNullOrEmpty()) return ""
        val ruleList = splitSourceRuleCacheString(ruleStr)
        return getString(ruleList, mContent, isUrl, unescape)
    }

    fun getString(
        ruleList: List<SourceRule>,
        mContent: Any? = null,
        isUrl: Boolean = false,
        unescape: Boolean = true
    ): String {
        var result: Any? = null
        val content = mContent ?: this.content
        if (content != null && ruleList.isNotEmpty()) {
            result = content
            for (sourceRule in ruleList) {
                putRule(sourceRule.putMap)
                sourceRule.makeUpRule(result)
                result ?: continue
                val rule = sourceRule.rule
                if (rule.isNotBlank() || sourceRule.replaceRegex.isEmpty()) {
                    result = when (sourceRule.mode) {
                        Mode.Js -> evalJS(rule, result)
                        Mode.Json -> getAnalyzeByJSonPath(result).getString(rule)
                        Mode.XPath -> getAnalyzeByXPath(result).getString(rule)
                        Mode.Default -> if (isUrl) {
                            getAnalyzeByJSoup(result).getString0(rule)
                        } else {
                            getAnalyzeByJSoup(result).getString(rule)
                        }
                        else -> rule
                    }
                }
                if (result != null && sourceRule.replaceRegex.isNotEmpty()) {
                    result = replaceRegex(result.toString(), sourceRule)
                }
            }
        }
        if (result == null) result = ""
        // 关键修复：result 可能是 List（JS 返回 NativeArray 时），不能直接 toString，
        // 否则会变成 "[a, b]" 格式，应该用 "\n" 拼接（legado 行为）
        val resultStr = when (result) {
            is List<*> -> result.joinToString("\n") { it?.toString() ?: "" }
            else -> result.toString()
        }
        val str = if (unescape && resultStr.indexOf('&') > -1) {
            org.apache.commons.text.StringEscapeUtils.unescapeHtml4(resultStr)
        } else {
            resultStr
        }
        if (isUrl) {
            return if (str.isBlank()) {
                baseUrl ?: ""
            } else {
                getAbsoluteURL(redirectUrl, str)
            }
        }
        return str
    }

    fun getElements(ruleStr: String): List<Any> {
        var result: Any? = null
        val content = this.content
        val ruleList = splitSourceRule(ruleStr, true)
        if (content != null && ruleList.isNotEmpty()) {
            result = content
            for (sourceRule in ruleList) {
                putRule(sourceRule.putMap)
                result ?: continue
                val rule = sourceRule.rule
                result = when (sourceRule.mode) {
                    Mode.Regex -> AnalyzeByRegex.getElements(
                        result.toString(),
                        rule.split("&&").filter { it.isNotBlank() }.toTypedArray()
                    )
                    Mode.Json -> getAnalyzeByJSonPath(result).getList(rule)
                    Mode.XPath -> getAnalyzeByXPath(result).getElements(rule)
                    else -> getAnalyzeByJSoup(result).getElements(rule)
                }
            }
        }
        result?.let {
            return it as List<Any>
        }
        return ArrayList()
    }

    private fun putRule(map: Map<String, String>) {
        for ((key, value) in map) {
            put(key, getString(value))
        }
    }

    private fun replaceRegex(result: String, rule: SourceRule): String {
        if (rule.replaceRegex.isEmpty()) return result
        val replaceRegex = rule.replaceRegex
        val replacement = rule.replacement
        val regex = compileRegexCache(replaceRegex)
        if (rule.replaceFirst) {
            if (regex != null) kotlin.runCatching {
                val pattern = regex.toPattern()
                val matcher = pattern.matcher(result)
                return if (matcher.find()) {
                    matcher.group(0)!!.replaceFirst(regex, replacement)
                } else {
                    ""
                }
            }
            return replacement
        } else {
            if (regex != null) kotlin.runCatching {
                return result.replace(regex, replacement)
            }
            return result.replace(replaceRegex, replacement)
        }
    }

    private fun compileRegexCache(regex: String): Regex? {
        return regexCache.getOrPut(regex) {
            try {
                regex.toRegex()
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun splitSourceRuleCacheString(ruleStr: String?): List<SourceRule> {
        if (ruleStr.isNullOrEmpty()) return emptyList()
        return stringRuleCache.getOrPut(ruleStr) {
            splitSourceRule(ruleStr)
        }
    }

    fun splitSourceRule(ruleStr: String?, allInOne: Boolean = false): List<SourceRule> {
        if (ruleStr.isNullOrEmpty()) return emptyList()
        val ruleList = ArrayList<SourceRule>()
        var mMode: Mode = Mode.Default
        var start = 0
        if (allInOne && ruleStr.startsWith(":")) {
            mMode = Mode.Regex
            isRegex = true
            start = 1
        } else if (isRegex) {
            mMode = Mode.Regex
        }
        var tmp: String
        val jsMatcher = jsPattern.matcher(ruleStr)
        while (jsMatcher.find()) {
            if (jsMatcher.start() > start) {
                tmp = ruleStr.substring(start, jsMatcher.start()).trim { it <= ' ' }
                if (tmp.isNotEmpty()) {
                    ruleList.add(SourceRule(tmp, mMode))
                }
            }
            ruleList.add(SourceRule(jsMatcher.group(2) ?: jsMatcher.group(1) ?: "", Mode.Js))
            start = jsMatcher.end()
        }
        val webJsMatcher = webJsPattern.matcher(ruleStr)
        while (webJsMatcher.find()) {
            if (webJsMatcher.start() > start) {
                tmp = ruleStr.substring(start, webJsMatcher.start()).trim { it <= ' ' }
                if (tmp.isNotEmpty()) {
                    ruleList.add(SourceRule(tmp, mMode))
                }
            }
            ruleList.add(SourceRule(webJsMatcher.group(1) ?: "", Mode.WebJs))
            start = webJsMatcher.end()
        }
        if (ruleStr.length > start) {
            tmp = ruleStr.substring(start).trim { it <= ' ' }
            if (tmp.isNotEmpty()) {
                ruleList.add(SourceRule(tmp, mMode))
            }
        }
        return ruleList
    }

    fun put(key: String, value: String): String {
        variableMap[key] = value
        return value
    }

    fun get(key: String): String {
        return variableMap[key] ?: ""
    }

    /**
     * 对齐 legado NetworkUtils.getAbsoluteURL
     * 完全复制 legado 的 URL 拼接逻辑
     */
    private fun getAbsoluteURL(redirectUrl: URL?, url: String): String {
        if (url.isEmpty()) return ""
        val trimmed = url.trim()
        // 对齐 legado isAbsUrl(): 大小写不敏感
        val lower = trimmed.lowercase(Locale.ROOT)
        if (lower.startsWith("http://") || lower.startsWith("https://")) return trimmed
        // 对齐 legado isDataUrl()
        if (lower.startsWith("data:")) return trimmed
        // 对齐 legado: javascript 前缀返回空
        if (lower.startsWith("javascript")) return ""
        if (redirectUrl == null) return trimmed
        // 对齐 legado: 直接用 URL(baseURL, relativePath) 拼接
        return try {
            URL(redirectUrl, trimmed).toString()
        } catch (_: Exception) {
            trimmed
        }
    }

    inner class SourceRule internal constructor(
        ruleStr: String,
        internal var mode: Mode = Mode.Default
    ) {
        internal var rule: String
        internal var replaceRegex = ""
        internal var replacement = ""
        internal var replaceFirst = false
        internal val putMap = HashMap<String, String>()
        private val ruleParam = ArrayList<String>()
        private val ruleType = ArrayList<Int>()
        private val getRuleType = -2
        private val jsRuleType = -1
        private val defaultRuleType = 0

        init {
            rule = when {
                mode == Mode.Js || mode == Mode.Regex -> ruleStr
                ruleStr.startsWith("@CSS:", true) -> {
                    mode = Mode.Default
                    ruleStr
                }
                ruleStr.startsWith("@@") -> {
                    mode = Mode.Default
                    ruleStr.substring(2)
                }
                ruleStr.startsWith("@XPath:", true) -> {
                    mode = Mode.XPath
                    ruleStr.substring(7)
                }
                ruleStr.startsWith("@Json:", true) -> {
                    mode = Mode.Json
                    ruleStr.substring(6)
                }
                isJSON || ruleStr.startsWith("$.") || ruleStr.startsWith("$[") -> {
                    mode = Mode.Json
                    ruleStr
                }
                ruleStr.startsWith("/") -> {
                    mode = Mode.XPath
                    ruleStr
                }
                else -> ruleStr
            }
            rule = splitPutRule(rule, putMap)
            var start = 0
            var tmp: String
            val evalMatcher = evalPattern.matcher(rule)

            if (evalMatcher.find()) {
                tmp = rule.substring(start, evalMatcher.start())
                if (mode != Mode.Js && mode != Mode.Regex &&
                    (evalMatcher.start() == 0 || !tmp.contains("##"))
                ) {
                    mode = Mode.Regex
                }
                do {
                    if (evalMatcher.start() > start) {
                        tmp = rule.substring(start, evalMatcher.start())
                        splitRegex(tmp)
                    }
                    tmp = evalMatcher.group()
                    when {
                        tmp.startsWith("@get:", true) -> {
                            ruleType.add(getRuleType)
                            // @get:{key} → 提取 key，跳过 "@get:{" (6 个字符)，去掉末尾的 "}"
                            ruleParam.add(tmp.substring(6, tmp.length - 1))
                        }
                        tmp.startsWith("{{") -> {
                            ruleType.add(jsRuleType)
                            ruleParam.add(tmp.substring(2, tmp.length - 2))
                        }
                        else -> {
                            splitRegex(tmp)
                        }
                    }
                    start = evalMatcher.end()
                } while (evalMatcher.find())
            }
            if (rule.length > start) {
                tmp = rule.substring(start)
                splitRegex(tmp)
            }
        }

        private fun splitRegex(ruleStr: String) {
            var start = 0
            var tmp: String
            val ruleStrArray = ruleStr.split("##")
            val regexMatcher = regexPattern.matcher(ruleStrArray[0])

            if (regexMatcher.find()) {
                if (mode != Mode.Js && mode != Mode.Regex) {
                    mode = Mode.Regex
                }
                do {
                    if (regexMatcher.start() > start) {
                        tmp = ruleStr.substring(start, regexMatcher.start())
                        ruleType.add(defaultRuleType)
                        ruleParam.add(tmp)
                    }
                    tmp = regexMatcher.group()
                    ruleType.add(tmp.substring(1).toInt())
                    ruleParam.add(tmp)
                    start = regexMatcher.end()
                } while (regexMatcher.find())
            }
            if (ruleStr.length > start) {
                tmp = ruleStr.substring(start)
                ruleType.add(defaultRuleType)
                ruleParam.add(tmp)
            }
        }

        fun makeUpRule(result: Any?) {
            val infoVal = StringBuilder()
            if (ruleParam.isNotEmpty()) {
                var index = ruleParam.size
                while (index-- > 0) {
                    val regType = ruleType[index]
                    when {
                        regType > defaultRuleType -> {
                            @Suppress("UNCHECKED_CAST")
                            (result as? List<String?>)?.run {
                                if (this.size > regType) {
                                    this[regType]?.let {
                                        infoVal.insert(0, it)
                                    }
                                }
                            } ?: infoVal.insert(0, ruleParam[index])
                        }
                        regType == jsRuleType -> {
                            val jsEval = evalJS(ruleParam[index], result)
                            if (jsEval != null) {
                                when (jsEval) {
                                    is String -> infoVal.insert(0, jsEval)
                                    is Double -> if (jsEval % 1.0 == 0.0) {
                                        infoVal.insert(0, String.format(Locale.ROOT, "%.0f", jsEval))
                                    } else {
                                        infoVal.insert(0, jsEval.toString())
                                    }
                                    else -> infoVal.insert(0, jsEval.toString())
                                }
                            }
                        }
                        regType == getRuleType -> {
                            infoVal.insert(0, get(ruleParam[index]))
                        }
                        else -> infoVal.insert(0, ruleParam[index])
                    }
                }
                rule = infoVal.toString()
            }
            val ruleStrS = rule.split("##")
            rule = ruleStrS[0].trim()
            if (ruleStrS.size > 1) {
                replaceRegex = ruleStrS[1]
            }
            if (ruleStrS.size > 2) {
                replacement = ruleStrS[2]
            }
            if (ruleStrS.size > 3) {
                replaceFirst = true
            }
        }

        fun getParamSize(): Int {
            return ruleParam.size
        }
    }

    enum class Mode {
        XPath, Json, Default, Js, Regex, WebJs
    }

    private fun splitPutRule(ruleStr: String, putMap: HashMap<String, String>): String {
        var vRuleStr = ruleStr
        val putMatcher = putPattern.matcher(vRuleStr)
        while (putMatcher.find()) {
            vRuleStr = vRuleStr.replace(putMatcher.group(), "")
            val putJsonStr = putMatcher.group(1)
            try {
                val putJson = org.json.JSONObject(putJsonStr)
                val keys = putJson.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    putMap[key] = putJson.getString(key)
                }
            } catch (_: Exception) {}
        }
        return vRuleStr
    }
}
