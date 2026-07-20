/**
 * 污污漫畫 (wu55comic) - 网页书源
 *
 * === 网站结构（已逆向确认）===
 *
 * 首页: https://www.wu55comic.store/
 *
 * 搜索页: /search?keyword={关键词}
 *   - 无分页，固定返回最多 100 条结果
 *   - 结果容器: <div class="sp-search-grid">
 *   - 每本书: <a href="/book/{id}" class="sp-search-card" title="书名">
 *       <div class="sp-search-card-cover">
 *         <div class="cropped" data-src="https://.../cover_pc.jpg?t=3">
 *       </div>
 *       <div class="sp-search-card-info">
 *         <div class="sp-search-card-title">书名</div>
 *       </div>
 *     </a>
 *
 * 分类页: /booklist?tag={标签}&area=-1&end=-1&page={页码}
 *   - 有分页: ?page={N}，分页栏 .sp-pagination a
 *   - 结果容器: <div class="sp-booklist-grid" id="tags">
 *   - 每本书: <a href="/book/{id}" class="sp-booklist-card" title="书名">
 *       <div class="sp-booklist-cover">
 *         <div class="cropped" data-src="https://.../cover_pc.jpg?t=3">
 *       </div>
 *       <div class="sp-booklist-info">
 *         <div class="sp-booklist-title">书名</div>
 *         <div class="sp-booklist-meta">共 X 話</div>
 *       </div>
 *     </a>
 *
 * 详情页: /book/{bookId}
 *   - 书名: <h1 class="sp-book-title">
 *   - 作者: <p class="sp-book-author">作者：xxx</p>
 *   - 标签: <div class="sp-book-tags"><a class="sp-book-tag">人妻</a></div>
 *   - 元数据: <div class="sp-book-meta">
 *       <div class="sp-book-meta-item">狀態：<span>已完結</span></div>
 *       <div class="sp-book-meta-item">地區：<span>日漫</span></div>
 *       <div class="sp-book-meta-item">更新：<span>2021-10-29</span></div>
 *     </div>
 *   - 简介: <p class="sp-book-summary">
 *   - 封面: <div class="cropped" data-src="https://.../cover_pc.jpg?t=3">
 *   - 章节列表: <div class="sp-chapter-grid">
 *       <a class="sp-chapter-item" href="/free-chapter/{chapterId}?t=...">话名</a>
 *     </div>
 *
 * 正文页: /free-chapter/{chapterId}?t={时间戳}
 *   - 标题格式: 书名 - 话数 - 污污漫畫
 *   - 图片容器: <div class="cropped" id="{imageId}"
 *                  data-src="https://.../break_2/.../{imageId}.jpg">
 *       <canvas id="canvas_{imageId}"></canvas>
 *     </div>
 *   - 侧边栏章节: <div class="sp-sidebar-list">
 *       <a href="/free-chapter/{id}?t=..." rel="nofollow">话名</a>
 *     </div>
 *
 * === 图片加密（三重混淆）===
 *
 * 1. 切片混淆: 原始 .jpg 被切成 2 份 (b_0, b_1)，分属不同 CDN 主机
 *    - b_0: https://bmigmij-wuwu.sqxxov.com/break_2/.../xxx.b_0
 *    - b_1: https://bmigmih-wuwu.sqxxov.com/break_2/.../xxx.b_1
 *    - ?v 参数不校验，可省略
 *
 * 2. AES-CBC 加密: 每份 b_N 单独 AES-CBC-PKCS7 加密
 *    - key = "aaaaaaaaaaaaaaaa" (16字节)
 *    - iv  = "0123456789aaaaaa" (16字节)  ← 来自 decrypt-worker.js 明文
 *
 * 3. 合并解密: decrypt(b_0) || decrypt(b_1) → 原始 monga 数据
 *
 * 4. magic number 注入: 前12字节是占位符，按首字节(0/1/3/4)注入对应图片头
 *    - 0 = JPEG: FF D8 FF E0 00 10 4A 46 49 46 00 01
 *    - 1 = PNG:  89 50 4E 47 0D 0A 1A 0A
 *    - 3 = GIF:  47 49 46 38 39 61
 *    - 4 = AVIF: 00 00 00 20 66 74 79 70 61 76 69 66
 *
 * 5. 条带重排: 按 get_corp_count(bookId, pageNum) 切成 s 个水平条带倒序重排
 *    - s = md5(bookId + pageNum) 最后1字符 ASCII % 10 映射 44~80
 *    - 复用 __nativeImage.scrambleRestore(bytes, s) (C 原生条带重排)
 *
 * === 双 img 配对策略 ===
 *
 * 由于 QuickJS 的 fetch()/java.ajax() 走 ResponseType.plain，
 * 对二进制图片字节有 UTF-8 解码损失（484540/486521 字节损坏，99.6%）。
 * 必须让软件用 ResponseType.bytes 通道下载 b_0 和 b_1（作为独立图片 URL 输出）。
 *
 * content() 对每个原图输出 b_0 和 b_1 两个 <img>，双向配对缓存策略：
 *   - b_0 来了 → AES 解密缓存到 _b0Cache[pairKey]，返回 10000x1 透明 PNG 占位图
 *   - b_1 来了 → AES 解密缓存到 _b1Cache[pairKey]，返回 10000x1 透明 PNG 占位图
 *   - 后到者检查对方缓存 → 有则合并解密，返回最终图；无则缓存自己返回占位图
 *
 * 占位图高度优化：
 *   - 10000x1 透明 PNG，BoxFit.fitWidth 下高度仅为屏幕宽度的 1/10000（亚像素）
 *   - 配合 comic_reader_page.dart 的 loadingBuilder 对 .b_0 URL 返回 SizedBox.shrink()
 *   - 下载过程和最终显示都不占高度，彻底消除废料图片
 *
 * 封面图（cover_pc.jpg）也是加密的，同样走双 img 配对。
 * 列表场景下封面只能显示一张，用 b_1 URL 作为 coverUrl（软件下载 b_1 时
 * 会自动用 b_0 缓存配对合并，若 b_0 未就绪则等 b_0 到达后由 b_0 合并）。
 *
 * 参考逆向:
 *   - /static/js/merge_img.0.0.15.js (条带重排算法)
 *   - /static/js/merge_split_file_monga.min.js (切片+AES解密)
 *   - /static/js/decrypt-worker.js (AES key/iv 明文)
 *   - /static/js/md5.min.js
 */

// @name 污污漫畫
// @url https://www.wu55comic.store
// @group 漫画
// @type 2
// @searchUrl https://www.wu55comic.store/search?keyword={{key}}
// @exploreUrl 人妻::https://www.wu55comic.store/booklist?tag=%E4%BA%BA%E5%A6%BB&area=-1&end=-1&page={{page}}
// NTR::https://www.wu55comic.store/booklist?tag=NTR&area=-1&end=-1&page={{page}}
// 巨乳::https://www.wu55comic.store/booklist?tag=%E5%B7%A8%E4%B9%B3&area=-1&end=-1&page={{page}}
// 熟女::https://www.wu55comic.store/booklist?tag=%E7%86%9F%E5%A5%B3&area=-1&end=-1&page={{page}}
// 御姐女王::https://www.wu55comic.store/booklist?tag=%E5%BE%A1%E5%A7%90%E3%83%BB%E5%A5%B3%E7%8E%8B&area=-1&end=-1&page={{page}}
// 同人::https://www.wu55comic.store/booklist?tag=%E5%90%8C%E4%BA%BA&area=-1&end=-1&page={{page}}
// 教師::https://www.wu55comic.store/booklist?tag=%E6%95%99%E5%B8%AB&area=-1&end=-1&page={{page}}
// 日漫::https://www.wu55comic.store/booklist?area=1&end=-1&page={{page}}
// 韓漫::https://www.wu55comic.store/booklist?area=2&end=-1&page={{page}}
// @header {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", "Referer": "https://www.wu55comic.store/"}
// @imageDecode decryptImage(result)


// ===== 常量 =====
var BASE_URL = 'https://www.wu55comic.store';

// 图片 CDN 双主机（b_0 / b_1 分属不同主机）
var IMG_HOST_0 = 'https://bmigmij-wuwu.sqxxov.com';
var IMG_HOST_1 = 'https://bmigmih-wuwu.sqxxov.com';

// AES-CBC 解密参数（来自 decrypt-worker.js 明文）
var AES_KEY_STR = 'aaaaaaaaaaaaaaaa';
var AES_IV_STR = '0123456789aaaaaa';

// 图片 magic number 头（前12字节占位符替换）
var MAGIC_HEADERS = {
    0: [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01], // JPEG
    1: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],                         // PNG
    3: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61],                                     // GIF
    4: [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66] // AVIF
};

// 条带数映射表（get_corp_count: md5尾字符 ASCII%10 → 条带数）
var CORP_COUNT_MAP = [44, 48, 52, 56, 60, 64, 68, 72, 76, 80];


// ===== 工具函数 =====

// 字符串 → Uint8Array
function _strToU8(s) {
    var u = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) u[i] = s.charCodeAt(i);
    return u;
}

// Uint8Array → Base64 字符串（分块避免栈溢出）
function _u8ToB64(u8) {
    var binary = '';
    var chunkSize = 0x8000;
    for (var i = 0; i < u8.length; i += chunkSize) {
        var end = Math.min(i + chunkSize, u8.length);
        var chunk = u8.subarray(i, end);
        binary += String.fromCharCode.apply(null, chunk);
    }
    return btoa(binary);
}

// 计算 md5 十六进制字符串
function _md5Hex(s) {
    var u8 = _strToU8(s);
    var ab = __nativeCrypto.md5Native(u8);
    var hex = '';
    var arr = new Uint8Array(ab);
    for (var i = 0; i < arr.length; i++) {
        hex += (arr[i] < 16 ? '0' : '') + arr[i].toString(16);
    }
    return hex;
}

// 计算条带数（对应 merge_img.js 的 get_corp_count）
// s = md5(bookId + pageNum) 最后1字符 ASCII % 10 → CORP_COUNT_MAP[index]
function getCorpCount(bookId, pageNum) {
    var hash = _md5Hex(String(bookId) + String(pageNum));
    var lastChar = hash.charAt(hash.length - 1);
    var code = lastChar.charCodeAt(0);
    var idx = code % 10;
    return CORP_COUNT_MAP[idx];
}

// 从 monga 数据前8字节解析 magic number 信息
function parseMagicNumber(u8) {
    var firstByte = u8[0];
    var subType = u8[1];
    var info = { fileType: firstByte, type: subType };
    switch (firstByte) {
        case 0: // JPEG monga
        case 3: // GIF monga
            info.bookId = u8[2] * 256 + u8[3];
            info.pageNumber = u8[4] * 16777216 + u8[5] * 65536 + u8[6] * 256 + u8[7];
            break;
        case 1: // PNG seed
        case 4: // AVIF seed
            info.seed = u8[2] * 16777216 + u8[3] * 65536 + u8[4] * 256 + u8[5];
            info.bookId = 0;
            info.pageNumber = 0;
            break;
        default:
            info.bookId = 0;
            info.pageNumber = 0;
    }
    return info;
}

// 注入图片 magic number 头（替换前12字节占位符）
function injectMagicHeader(u8, fileType) {
    var magic = MAGIC_HEADERS[fileType];
    if (!magic) return u8;
    for (var i = 0; i < magic.length && i < u8.length; i++) {
        u8[i] = magic[i];
    }
    return u8;
}


// ===== 图片解密核心 =====

// 从 URL 判断是 b_0 还是 b_1
function _isB0(url) {
    return /\.b_0(\?|$|#)/.test(url);
}

// 从 b_0 或 b_1 URL 提取配对 key
// 封面: /static/upload/book/{bookId}/cover_pc.b_N
// 正文: /static/upload/book/{bookId}/{chapterId}/{imageId}.b_N
function _pairKey(url) {
    var m = url.match(/\/static\/upload\/book\/(\d+\/\d+\/\d+|(\d+)\/cover_pc)\.b_\d/);
    if (m) return m[1];
    // 兜底：去掉主机和 b_N 后缀
    return url.replace(/^https?:\/\/[^/]+/, '').replace(/\.b_\d.*$/, '');
}

// 从 b_0 URL 推导 b_1 URL
function _deriveB1(b0Url) {
    return b0Url.replace(IMG_HOST_0, IMG_HOST_1)
               .replace(/\.b_0(\?|$|#)/, '.b_1$1');
}

// 从 .jpg URL 生成 b_0/b_1 URL（去掉 .jpg，换 b_N 后缀，换主机）
function _jpgToB0(jpgUrl) {
    var b0 = jpgUrl.replace(/\.jpg(\?.*)?$/, '.b_0');
    b0 = b0.replace(IMG_HOST_1, IMG_HOST_0);
    return b0;
}
function _jpgToB1(jpgUrl) {
    var b1 = jpgUrl.replace(/\.jpg(\?.*)?$/, '.b_1');
    b1 = b1.replace(IMG_HOST_0, IMG_HOST_1);
    return b1;
}

// AES-CBC 解密单份切片
function decryptSlice(cipherU8) {
    if (!cipherU8 || cipherU8.length === 0) return null;
    var keyU8 = _strToU8(AES_KEY_STR);
    var ivU8 = _strToU8(AES_IV_STR);
    var plain = __nativeCrypto.aesDecryptNative(cipherU8, keyU8, ivU8);
    if (!plain) return null;
    if (plain instanceof ArrayBuffer) plain = new Uint8Array(plain);
    return plain;
}

// 合并多份 Uint8Array
function combineU8(arrays) {
    var total = 0;
    for (var i = 0; i < arrays.length; i++) total += arrays[i].length;
    var result = new Uint8Array(total);
    var offset = 0;
    for (var j = 0; j < arrays.length; j++) {
        result.set(arrays[j], offset);
        offset += arrays[j].length;
    }
    return result;
}

// 完整合并解密流程（b_0 和 b_1 都已 AES 解密）
function _fullDecrypt(d0, d1) {
    if (!d0 || d0.length === 0) return null;

    var combined;
    if (d1 && d1.length > 0) {
        combined = combineU8([d0, d1]);
    } else {
        combined = d0;
    }

    // 解析 magic number
    var magic = parseMagicNumber(combined);
    var fileType = magic.fileType;

    // 注入图片头
    combined = injectMagicHeader(combined, fileType);

    // 条带重排（仅 JPEG/PNG/GIF/AVIF monga 需要 bookId/pageNumber）
    if (magic.bookId !== undefined && magic.pageNumber !== undefined &&
        magic.bookId > 0 && magic.pageNumber > 0) {
        var stripCount = getCorpCount(magic.bookId, magic.pageNumber);
        if (stripCount > 0 && stripCount <= 80) {
            if (typeof __nativeImage !== 'undefined' && __nativeImage.scrambleRestore) {
                var restored = __nativeImage.scrambleRestore(combined, stripCount);
                if (restored) return restored;
            }
        }
    }

    // 无条带重排需求或 C 原生不可用，直接返回 base64
    return _u8ToB64(combined);
}

// ===== 双 img 配对缓存（双向配对，解决下载顺序不确定）=====
// 注意：缓存必须挂到 globalThis，否则 IIFE 每次执行都会重新声明为空对象
// 导致跨调用配对失败
if (!globalThis._b0Cache) globalThis._b0Cache = {};
if (!globalThis._b1Cache) globalThis._b1Cache = {};
var _b0Cache = globalThis._b0Cache;
var _b1Cache = globalThis._b1Cache;

// 缓存大小限制：超过 20 个未配对项时清理最早的，避免内存泄漏
// （用户快速翻页时某些 b_0/b_1 可能永远等不到另一半）
var _MAX_CACHE_SIZE = 20;
function _trimCache(cache) {
    var keys = Object.keys(cache);
    if (keys.length <= _MAX_CACHE_SIZE) return;
    // 删除最早的项（FIFO 策略）
    var toDelete = keys.length - _MAX_CACHE_SIZE;
    for (var i = 0; i < toDelete; i++) {
        delete cache[keys[i]];
    }
}

// 10000x1 透明 PNG 占位图（宽高比 10000:1，PIL 生成，可靠解码）
// BoxFit.fitWidth 拉伸后高度仅为宽度的 1/10000，亚像素级别，视觉上等于 0
// 配合 comic_reader_page.dart 的 loadingBuilder 对 .b_0 URL 返回 SizedBox.shrink()
// 实现下载过程和最终显示都不占高度
var _TRANSPARENT_PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAJxAAAAABCAYAAAB43rQLAAAAPUlEQVR4nO3BMQEAAADCoPVP7WULoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgG6cQQABxrNxNAAAAABJRU5ErkJggg==';

/**
 * 图片解密入口（imageDecode 规则）
 *
 * result: 当前图片的原始字节（b_0 或 b_1，软件用 ResponseType.bytes 下载）
 * src:    当前图片的 URL
 *
 * 双 img 双向配对策略（解决下载顺序不确定）：
 *   - b_0 来了 → AES 解密后缓存到 _b0Cache[pairKey]
 *     - 若 _b1Cache 已有对应 b_1 → 合并解密，返回最终图，清理两个缓存
 *     - 否则返回 10000x1 透明 PNG 占位图
 *   - b_1 来了 → AES 解密后缓存到 _b1Cache[pairKey]
 *     - 若 _b0Cache 已有对应 b_0 → 合并解密，返回最终图，清理两个缓存
 *     - 否则返回 10000x1 透明 PNG 占位图（等 b_0 到达时再合并）
 */
function decryptImage(result) {
    if (!result || result.length === 0) return null;

    var url = (typeof src !== 'undefined') ? src : '';
    var key = _pairKey(url);

    // AES 解密当前切片
    var decrypted = decryptSlice(result);
    if (!decrypted || decrypted.length === 0) {
        // 解密失败，返回占位图避免整页崩溃
        return _TRANSPARENT_PNG_B64;
    }

    if (_isB0(url)) {
        // b_0 到达
        var cachedB1 = _b1Cache[key];
        if (cachedB1) {
            // b_1 已就绪 → 合并解密，返回最终图
            delete _b1Cache[key];
            return _fullDecrypt(decrypted, cachedB1);
        }
        // b_1 未就绪 → 缓存 b_0，返回占位图
        _b0Cache[key] = decrypted;
        _trimCache(_b0Cache);
        return _TRANSPARENT_PNG_B64;
    } else {
        // b_1 到达
        var cachedB0 = _b0Cache[key];
        if (cachedB0) {
            // b_0 已就绪 → 合并解密，返回最终图
            delete _b0Cache[key];
            return _fullDecrypt(cachedB0, decrypted);
        }
        // b_0 未就绪 → 缓存 b_1，返回占位图（等 b_0 后到再合并）
        _b1Cache[key] = decrypted;
        _trimCache(_b1Cache);
        return _TRANSPARENT_PNG_B64;
    }
}


// ===== 搜索 =====
// 搜索页结构: <a href="/book/{id}" class="sp-search-card" title="书名">
//   <div class="sp-search-card-cover">
//     <div class="cropped" data-src="https://.../cover_pc.jpg?t=3">
//   </div>
//   <div class="sp-search-card-info">
//     <div class="sp-search-card-title">书名</div>
//   </div>
// </a>
function search(key, page, result) {
    var list = [];
    var seen = {};

    // 正则提取所有 sp-search-card 卡片
    var cardRe = /<a[^>]+href="\/book\/(\d+)"[^>]*class="[^"]*sp-search-card[^"]*"[^>]*>/g;
    var m;
    while ((m = cardRe.exec(result)) !== null) {
        var bookId = m[1];
        if (seen[bookId]) continue;
        seen[bookId] = true;

        // 提取 title 属性
        var titleMatch = m[0].match(/title="([^"]*)"/);
        var name = titleMatch ? titleMatch[1] : '';

        // 提取封面 data-src
        var coverMatch = result.slice(m.index, m.index + 2000).match(/data-src="([^"]+)"/);
        var coverSrc = coverMatch ? coverMatch[1] : '';

        // 封面 URL 转换为 b_1（软件下载 b_1，decryptImage 配对合并）
        var coverUrl = '';
        if (coverSrc) {
            coverUrl = _jpgToB1(coverSrc);
        }

        list.push({
            name: name || ('book_' + bookId),
            author: '',
            bookUrl: BASE_URL + '/book/' + bookId,
            coverUrl: coverUrl,
            kind: '',
            lastChapter: '',
            intro: ''
        });
    }

    return list;
}


// ===== 发现 =====
// 分类页结构同搜索页，但用 sp-booklist-card 类
function explore(baseUrl, result) {
    var list = [];
    var seen = {};

    // 正则提取所有 sp-booklist-card 卡片
    var cardRe = /<a[^>]+href="\/book\/(\d+)"[^>]*class="[^"]*sp-booklist-card[^"]*"[^>]*>/g;
    var m;
    while ((m = cardRe.exec(result)) !== null) {
        var bookId = m[1];
        if (seen[bookId]) continue;
        seen[bookId] = true;

        // 提取 title 属性
        var titleMatch = m[0].match(/title="([^"]*)"/);
        var name = titleMatch ? titleMatch[1] : '';

        // 提取封面 data-src
        var coverMatch = result.slice(m.index, m.index + 2000).match(/data-src="([^"]+)"/);
        var coverSrc = coverMatch ? coverMatch[1] : '';
        var coverUrl = coverSrc ? _jpgToB1(coverSrc) : '';

        // 提取话数（共 X 話）
        var metaMatch = result.slice(m.index, m.index + 2000).match(/共\s*(\d+)\s*話/);
        var lastChapter = metaMatch ? '共' + metaMatch[1] + '話' : '';

        list.push({
            name: name || ('book_' + bookId),
            author: '',
            bookUrl: BASE_URL + '/book/' + bookId,
            coverUrl: coverUrl,
            kind: '',
            lastChapter: lastChapter,
            intro: ''
        });
    }

    return list;
}


// ===== 书籍详情 =====
// 详情页结构:
//   <h1 class="sp-book-title">书名</h1>
//   <p class="sp-book-author">作者：xxx</p>
//   <div class="sp-book-tags"><a class="sp-book-tag">人妻</a></div>
//   <div class="sp-book-meta">
//     <div class="sp-book-meta-item">狀態：<span>已完結</span></div>
//     <div class="sp-book-meta-item">更新：<span>2021-10-29</span></div>
//   </div>
//   <p class="sp-book-summary">简介</p>
//   封面: <div class="cropped" data-src="https://.../cover_pc.jpg?t=3">
function bookInfo(result) {
    // 书名
    var name = '';
    var nameMatch = result.match(/<h1[^>]*class="[^"]*sp-book-title[^"]*"[^>]*>([\s\S]*?)<\/h1>/);
    if (nameMatch) name = nameMatch[1].replace(/<[^>]+>/g, '').trim();

    // 作者
    var author = '';
    var authorMatch = result.match(/<p[^>]*class="[^"]*sp-book-author[^"]*"[^>]*>([\s\S]*?)<\/p>/);
    if (authorMatch) {
        var authorText = authorMatch[1].replace(/<[^>]+>/g, '').trim();
        var am = authorText.match(/作者[：:]\s*([^\n]+)/);
        if (am) author = am[1].trim();
        else author = authorText;
    }

    // 标签
    var tags = [];
    var tagRe = /<a[^>]*class="[^"]*sp-book-tag[^"]*"[^>]*>([^<]+)<\/a>/g;
    var tm;
    while ((tm = tagRe.exec(result)) !== null) {
        tags.push(tm[1].trim());
    }

    // 状态
    var status = '';
    var statusMatch = result.match(/狀態[：:]\s*<span>([^<]+)<\/span>/);
    if (statusMatch) status = statusMatch[1].trim();

    // 地区
    var area = '';
    var areaMatch = result.match(/地區[：:]\s*<span>(?:<a[^>]*>)?([^<]+)/);
    if (areaMatch) area = areaMatch[1].trim();

    // 更新时间
    var updateTime = '';
    var updateMatch = result.match(/更新[：:]\s*<span>([^<]+)<\/span>/);
    if (updateMatch) updateTime = updateMatch[1].trim();

    // 简介
    var intro = '';
    var introMatch = result.match(/<p[^>]*class="[^"]*sp-book-summary[^"]*"[^>]*>([\s\S]*?)<\/p>/);
    if (introMatch) intro = introMatch[1].replace(/<[^>]+>/g, '').trim();

    // 从 URL 提取 bookId（用于构造封面 URL）
    var bookIdMatch = result.match(/\/book\/(\d+)/);
    var bookId = bookIdMatch ? bookIdMatch[1] : '';

    // 封面 URL（从详情页 .cropped data-src 提取，转换为 b_1）
    var coverUrl = '';
    var coverSrcMatch = result.match(/data-src="(https?:[^"]*cover_pc\.jpg[^"]*)"/);
    if (coverSrcMatch) {
        coverUrl = _jpgToB1(coverSrcMatch[1]);
    } else if (bookId) {
        // 兜底：构造默认封面 URL
        coverUrl = IMG_HOST_1 + '/break_2/static/upload/book/' + bookId + '/cover_pc.b_1';
    }

    // 组合 kind
    var kind = tags.join(',');
    if (status) kind = (kind ? kind + ',' : '') + status;
    if (area) kind = (kind ? kind + ',' : '') + area;

    return {
        name: name,
        author: author,
        coverUrl: coverUrl,
        intro: intro,
        kind: kind,
        lastChapter: '',
        tocUrl: '',
        wordCount: updateTime
    };
}


// ===== 章节目录 =====
// 章节列表结构: <a class="sp-chapter-item" href="/free-chapter/{id}?t=...">话名</a>
function toc(result) {
    var chapters = [];
    var seen = {};

    // 正则提取所有 sp-chapter-item
    var chapterRe = /<a[^>]+class="[^"]*sp-chapter-item[^"]*"[^>]+href="([^"]*\/free-chapter\/\d+[^"]*)"[^>]*>([\s\S]*?)<\/a>/g;
    var m;
    while ((m = chapterRe.exec(result)) !== null) {
        var href = m[1];
        var text = m[2].replace(/<[^>]+>/g, '').trim();

        if (seen[href]) continue;
        seen[href] = true;

        // 补全 URL
        if (href.indexOf('http') !== 0) {
            href = BASE_URL + (href.indexOf('/') === 0 ? '' : '/') + href;
        }

        chapters.push({
            name: text || ('第' + (chapters.length + 1) + '话'),
            url: href,
            isVolume: false
        });
    }

    // 兜底：如果没找到 sp-chapter-item，尝试正则提取所有 free-chapter 链接
    if (chapters.length === 0) {
        var fallbackRe = /href="(\/free-chapter\/\d+[^"]*)"[^>]*>([^<]*)</g;
        var fm;
        while ((fm = fallbackRe.exec(result)) !== null) {
            var fhref = fm[1];
            var ftext = fm[2].trim();
            if (ftext && ftext !== '▶ 開始閱讀' && !seen[fhref]) {
                seen[fhref] = true;
                chapters.push({
                    name: ftext,
                    url: BASE_URL + fhref,
                    isVolume: false
                });
            }
        }
    }

    return chapters;
}


// ===== 正文内容 =====
// 正文页结构:
//   <div class="cropped" id="{imageId}"
//        data-src="https://.../break_2/.../{imageId}.jpg">
//     <canvas id="canvas_{imageId}"></canvas>
//   </div>
//
// content() 对每个原图输出 b_0 和 b_1 两个 <img>
function content(result) {
    var dataSrcs = [];
    var seen = {};

    // 正则提取所有 div.cropped 的 data-src
    var re = /<div[^>]*class="[^"]*cropped[^"]*"[^>]*data-src="([^"]+)"[^>]*>/g;
    var m;
    while ((m = re.exec(result)) !== null) {
        var src = m[1];
        if (seen[src]) continue;
        seen[src] = true;
        dataSrcs.push(src);
    }

    // 兜底：正则提取所有 break_2 图片 URL
    if (dataSrcs.length === 0) {
        var re2 = /data-src="(https?:[^"]*\/break_2\/[^"]+\.jpg[^"]*)"/g;
        var m2;
        while ((m2 = re2.exec(result)) !== null) {
            if (!seen[m2[1]]) {
                seen[m2[1]] = true;
                dataSrcs.push(m2[1]);
            }
        }
    }

    // 将 .jpg URL 转换为 b_0/b_1 URL 并输出双 img
    // 顺序：b_1 在前（显示完整图），b_0 在后（10000x1 透明 PNG 占位，不占高度）
    var imgTags = '';
    for (var j = 0; j < dataSrcs.length; j++) {
        var src = dataSrcs[j];
        var b0Url = _jpgToB0(src);
        var b1Url = _jpgToB1(src);

        // b_1 在前（最终图），b_0 在后（占位）
        imgTags += '<img src="' + b1Url + '">\n';
        imgTags += '<img src="' + b0Url + '">\n';
    }

    return imgTags;
}
