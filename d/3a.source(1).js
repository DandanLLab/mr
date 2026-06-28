// @name 3A小说
// @url https://www.aaawz.cc
// @group 写源
// @type 0

var searchUrl = JSON.stringify({
  url: '/api-search',
  body: 'keyword={{key}}&page={{page}}&size=10',
  method: 'POST'
});

var exploreUrl = '[]';


var LZString = (function() {

// private property
var f = String.fromCharCode;
var keyStrBase64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
var keyStrUriSafe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$";
var baseReverseDic = {};

function getBaseValue(alphabet, character) {
  if (!baseReverseDic[alphabet]) {
    baseReverseDic[alphabet] = {};
    for (var i=0 ; i<alphabet.length ; i++) {
      baseReverseDic[alphabet][alphabet.charAt(i)] = i;
    }
  }
  return baseReverseDic[alphabet][character];
}

var LZString = {
 

  decompressFromBase64 : function (input) {
    if (input == null) return "";
    if (input == "") return null;
    return LZString._decompress(input.length, 32, function(index) { return getBaseValue(keyStrBase64, input.charAt(index)); });
  },

  _decompress: function (length, resetValue, getNextValue) {
    var dictionary = [],
        next,
        enlargeIn = 4,
        dictSize = 4,
        numBits = 3,
        entry = "",
        result = [],
        i,
        w,
        bits, resb, maxpower, power,
        c,
        data = {val:getNextValue(0), position:resetValue, index:1};

    for (i = 0; i < 3; i += 1) {
      dictionary[i] = i;
    }

    bits = 0;
    maxpower = Math.pow(2,2);
    power=1;
    while (power!=maxpower) {
      resb = data.val & data.position;
      data.position >>= 1;
      if (data.position == 0) {
        data.position = resetValue;
        data.val = getNextValue(data.index++);
      }
      bits |= (resb>0 ? 1 : 0) * power;
      power <<= 1;
    }

    switch (next = bits) {
      case 0:
          bits = 0;
          maxpower = Math.pow(2,8);
          power=1;
          while (power!=maxpower) {
            resb = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) {
              data.position = resetValue;
              data.val = getNextValue(data.index++);
            }
            bits |= (resb>0 ? 1 : 0) * power;
            power <<= 1;
          }
        c = f(bits);
        break;
      case 1:
          bits = 0;
          maxpower = Math.pow(2,16);
          power=1;
          while (power!=maxpower) {
            resb = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) {
              data.position = resetValue;
              data.val = getNextValue(data.index++);
            }
            bits |= (resb>0 ? 1 : 0) * power;
            power <<= 1;
          }
        c = f(bits);
        break;
      case 2:
        return "";
    }
    dictionary[3] = c;
    w = c;
    result.push(c);
    while (true) {
      if (data.index > length) {
        return "";
      }

      bits = 0;
      maxpower = Math.pow(2,numBits);
      power=1;
      while (power!=maxpower) {
        resb = data.val & data.position;
        data.position >>= 1;
        if (data.position == 0) {
          data.position = resetValue;
          data.val = getNextValue(data.index++);
        }
        bits |= (resb>0 ? 1 : 0) * power;
        power <<= 1;
      }

      switch (c = bits) {
        case 0:
          bits = 0;
          maxpower = Math.pow(2,8);
          power=1;
          while (power!=maxpower) {
            resb = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) {
              data.position = resetValue;
              data.val = getNextValue(data.index++);
            }
            bits |= (resb>0 ? 1 : 0) * power;
            power <<= 1;
          }

          dictionary[dictSize++] = f(bits);
          c = dictSize-1;
          enlargeIn--;
          break;
        case 1:
          bits = 0;
          maxpower = Math.pow(2,16);
          power=1;
          while (power!=maxpower) {
            resb = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) {
              data.position = resetValue;
              data.val = getNextValue(data.index++);
            }
            bits |= (resb>0 ? 1 : 0) * power;
            power <<= 1;
          }
          dictionary[dictSize++] = f(bits);
          c = dictSize-1;
          enlargeIn--;
          break;
        case 2:
          return result.join('');
      }

      if (enlargeIn == 0) {
        enlargeIn = Math.pow(2, numBits);
        numBits++;
      }

      if (dictionary[c]) {
        entry = dictionary[c];
      } else {
        if (c === dictSize) {
          entry = w + w.charAt(0);
        } else {
          return null;
        }
      }
      result.push(entry);

      // Add w+entry[0] to the dictionary.
      dictionary[dictSize++] = w + entry.charAt(0);
      enlargeIn--;

      w = entry;

      if (enlargeIn == 0) {
        enlargeIn = Math.pow(2, numBits);
        numBits++;
      }

    }
  }
};
  return LZString;
})();


// LZString 解压：优先使用 C 原生实现（__nativeLz），回退到纯 JS 实现
// 开销从 JS 路径转移到 C 层，消除 JS 侧字符串膨胀与逐条解析损耗
function lzDecompress(input) {
  if (typeof __nativeLz !== 'undefined') {
    return __nativeLz.decompressFromBase64(input);
  }
  return LZString.decompressFromBase64(input);
}


// 纯 JS 时间格式化（UTC + 时区偏移）
function timeFormatUTC(timestamp, format, offset) {
  var d = new Date(timestamp);
  if (offset) d = new Date(d.getTime() + offset * 3600000);
  var year = d.getUTCFullYear().toString();
  var pad = function(n) { return n < 10 ? '0' + n : '' + n; };
  return format
    .replace(/yyyy/g, year)
    .replace(/yy/g, year.slice(-2))
    .replace(/MM/g, pad(d.getUTCMonth() + 1))
    .replace(/dd/g, pad(d.getUTCDate()))
    .replace(/HH/g, pad(d.getUTCHours()))
    .replace(/mm/g, pad(d.getUTCMinutes()))
    .replace(/ss/g, pad(d.getUTCSeconds()));
}

function search(key, page, result) {
  var body = lzDecompress(result);
  var data = JSON.parse(body);
  var books = data.data.books;
  return books.map(function(book) {
    var tid = book.tid;
    var siteid = book.siteid;
    return {
      name: book.articlename.replace(/<\/?em>/g, ''),
      author: book.author.replace(/<\/?em>/g, ''),
      bookUrl: '/api-info-' + tid + '-' + siteid,
      coverUrl: '/bookimg/' + siteid + '/' + (tid % 100) + '/' + tid + '.jpg',
      kind: String(book.lastupdate).replace(/\h\S+/, ''),
      lastChapter: book.lastchapter
    };
  });
}

function explore(baseUrl, result) {
  return [];
}

function bookInfo(result) {
  var body = lzDecompress(result);
  var data = JSON.parse(body);
  return {
    name: data.articlename,
    author: data.author,
    intro: data.intro,
    coverUrl: data.imgurl.replace(/\d+x\d+/, ''),
    lastChapter: data.lastchapter,
    tocUrl: '/api-chapterlist-' + data.tid + '-' + data.siteid,
    kind: timeFormatUTC(data.lastupdate * 1000, 'yy-MM-dd', 8)
  };
}

function toc(result) {
  var body = lzDecompress(result);
  var data = JSON.parse(body);
  return data.map(function(item) {
    return {
      name: item.title,
      url: baseUrl.replace('list-', '-') + '-' + item.cid,
      updateTime: item.wordNum + '字' + timeFormatUTC(item.update * 1000, 'yy-MM-dd', 8)
    };
  });
}

function content(result) {
  // 优先使用 C 原生原子组合：base64 解码 → AES-CBC 解密 → LZString 解压
  // 全链路在 C 层完成，消除 JS 侧字符串膨胀与多次跨语言往返
  if (typeof __nativeCrypto !== 'undefined' && __nativeCrypto.aesDecryptThenLzDecompress) {
    return __nativeCrypto.aesDecryptThenLzDecompress(result, '123#2^0@0vm@08.b5%$1[A]1&4115s((');
  }
  // 回退：原 AES + LZString 链路
  var raw = atob(result);
  var iv = [], cipher = [];
  for (var i = 0; i < 16; i++) iv.push(raw.charCodeAt(i));
  for (var i = 16; i < raw.length; i++) cipher.push(raw.charCodeAt(i));
  var key = CryptoJS.enc.Utf8.parse('123#2^0@0vm@08.b5%$1[A]1&4115s((');
  var decrypted = CryptoJS.AES.decrypt(cipher, key, { iv: iv, mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 });
  var decryptedStr = decrypted.toString(CryptoJS.enc.Utf8);
  // LZString 解压
  return lzDecompress(decryptedStr);
}

function nextTocUrl(result) {
  return '';
}

function nextContentUrl(result) {
  return '';
}