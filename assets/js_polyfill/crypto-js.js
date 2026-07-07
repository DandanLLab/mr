// ===== CryptoJS 兼容层（纯 JS 实现，不依赖 C FFI）=====
// 提取自 js_engine.dart 内联的 _AES/_MD5/_SHA1/_SHA256/_HMACSHA256 引擎
// 包装为 CryptoJS 兼容 API，供 legado 书源规则使用

// ===== AES S-Box =====
var _AES_SBOX = [0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16];
var _AES_INV_SBOX = [0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d];
var _AES_RCON = [0x00,0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36];

function _aesXtime(a) { return (a & 0x80) ? ((a << 1) ^ 0x1b) : (a << 1); }
function _aesMul(a, b) { var r = 0; for (var i = 0; i < 8; i++) { if (b & 1) r ^= a; a = _aesXtime(a); b >>= 1; } return r & 0xff; }
function _aesSubBytes(s) { for (var i = 0; i < 16; i++) s[i] = _AES_SBOX[s[i]]; }
function _aesInvSubBytes(s) { for (var i = 0; i < 16; i++) s[i] = _AES_INV_SBOX[s[i]]; }
function _aesShiftRows(s) { var t=s[1];s[1]=s[5];s[5]=s[9];s[9]=s[13];s[13]=t;t=s[2];s[2]=s[10];s[10]=t;t=s[6];s[6]=s[14];s[14]=t;t=s[15];s[15]=s[11];s[11]=s[7];s[7]=s[3];s[3]=t; }
function _aesInvShiftRows(s) { var t=s[13];s[13]=s[9];s[9]=s[5];s[5]=s[1];s[1]=t;t=s[2];s[2]=s[10];s[10]=t;t=s[6];s[6]=s[14];s[14]=t;t=s[3];s[3]=s[7];s[7]=s[11];s[11]=s[15];s[15]=t; }
function _aesMixColumns(s) { for (var i=0;i<4;i++) { var a=s[i*4],b=s[i*4+1],c=s[i*4+2],d=s[i*4+3]; s[i*4]=_aesMul(2,a)^_aesMul(3,b)^c^d; s[i*4+1]=a^_aesMul(2,b)^_aesMul(3,c)^d; s[i*4+2]=a^b^_aesMul(2,c)^_aesMul(3,d); s[i*4+3]=_aesMul(3,a)^b^c^_aesMul(2,d); } }
function _aesInvMixColumns(s) { for (var i=0;i<4;i++) { var a=s[i*4],b=s[i*4+1],c=s[i*4+2],d=s[i*4+3]; s[i*4]=_aesMul(0x0e,a)^_aesMul(0x0b,b)^_aesMul(0x0d,c)^_aesMul(0x09,d); s[i*4+1]=_aesMul(0x09,a)^_aesMul(0x0e,b)^_aesMul(0x0b,c)^_aesMul(0x0d,d); s[i*4+2]=_aesMul(0x0d,a)^_aesMul(0x09,b)^_aesMul(0x0e,c)^_aesMul(0x0b,d); s[i*4+3]=_aesMul(0x0b,a)^_aesMul(0x0d,b)^_aesMul(0x09,c)^_aesMul(0x0e,d); } }
function _aesAddRoundKey(s, rk) { for (var i = 0; i < 16; i++) s[i] ^= rk[i]; }

function _aesKeyExpansion(key) {
  var nk = key.length / 4, nr = nk + 6;
  var w = new Array(4 * (nr + 1));
  for (var i = 0; i < nk; i++) { w[i*4]=key[i*4]; w[i*4+1]=key[i*4+1]; w[i*4+2]=key[i*4+2]; w[i*4+3]=key[i*4+3]; }
  for (var i = nk; i < 4*(nr+1); i++) {
    var t = [w[(i-1)*4], w[(i-1)*4+1], w[(i-1)*4+2], w[(i-1)*4+3]];
    if (i % nk === 0) { var tmp=t[0]; t[0]=_AES_SBOX[t[1]]^_AES_RCON[i/nk]; t[1]=_AES_SBOX[t[2]]; t[2]=_AES_SBOX[t[3]]; t[3]=_AES_SBOX[tmp]; }
    else if (nk > 6 && i % nk === 4) { t[0]=_AES_SBOX[t[0]]; t[1]=_AES_SBOX[t[1]]; t[2]=_AES_SBOX[t[2]]; t[3]=_AES_SBOX[t[3]]; }
    w[i*4]=w[(i-nk)*4]^t[0]; w[i*4+1]=w[(i-nk)*4+1]^t[1]; w[i*4+2]=w[(i-nk)*4+2]^t[2]; w[i*4+3]=w[(i-nk)*4+3]^t[3];
  }
  return w;
}
function _aesEncryptBlock(block, w, nr) {
  var s = block.slice(); _aesAddRoundKey(s, w.slice(0, 16));
  for (var r = 1; r < nr; r++) { _aesSubBytes(s); _aesShiftRows(s); _aesMixColumns(s); _aesAddRoundKey(s, w.slice(r*16, r*16+16)); }
  _aesSubBytes(s); _aesShiftRows(s); _aesAddRoundKey(s, w.slice(nr*16, nr*16+16));
  return s;
}
function _aesDecryptBlock(block, w, nr) {
  var s = block.slice(); _aesAddRoundKey(s, w.slice(nr*16, nr*16+16));
  for (var r = nr-1; r > 0; r--) { _aesInvShiftRows(s); _aesInvSubBytes(s); _aesAddRoundKey(s, w.slice(r*16, r*16+16)); _aesInvMixColumns(s); }
  _aesInvShiftRows(s); _aesInvSubBytes(s); _aesAddRoundKey(s, w.slice(0, 16));
  return s;
}
function _aesPkcs7Pad(data) { var pad = 16 - (data.length % 16); var r = data.slice(); for (var i = 0; i < pad; i++) r.push(pad); return r; }
function _aesPkcs7Unpad(data) { if (data.length === 0) return data; var pad = data[data.length - 1]; if (pad < 1 || pad > 16) return data; for (var i = data.length - pad; i < data.length; i++) { if (data[i] !== pad) return data; } return data.slice(0, data.length - pad); }

function _aesUtf8ToBytes(str) {
  var bytes = [];
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    if (c < 0x80) bytes.push(c);
    else if (c < 0x800) { bytes.push(0xc0|(c>>6)); bytes.push(0x80|(c&0x3f)); }
    else if (c >= 0xd800 && c <= 0xdbff) { var hi=c,lo=str.charCodeAt(++i); var cp=((hi-0xd800)<<10)+(lo-0xdc00)+0x10000; bytes.push(0xf0|(cp>>18)); bytes.push(0x80|((cp>>12)&0x3f)); bytes.push(0x80|((cp>>6)&0x3f)); bytes.push(0x80|(cp&0x3f)); }
    else { bytes.push(0xe0|(c>>12)); bytes.push(0x80|((c>>6)&0x3f)); bytes.push(0x80|(c&0x3f)); }
  }
  return bytes;
}
function _aesBytesToUtf8(bytes) {
  var str = '';
  for (var i = 0; i < bytes.length; i++) {
    var c = bytes[i];
    if (c < 0x80) str += String.fromCharCode(c);
    else if (c >= 0xf0) { str += String.fromCharCode(((c&0x07)<<18)|((bytes[++i]&0x3f)<<12)|((bytes[++i]&0x3f)<<6)|(bytes[++i]&0x3f)); }
    else if (c >= 0xe0) { str += String.fromCharCode(((c&0x0f)<<12)|((bytes[++i]&0x3f)<<6)|(bytes[++i]&0x3f)); }
    else { str += String.fromCharCode(((c&0x1f)<<6)|(bytes[++i]&0x3f)); }
  }
  return str;
}
var _AES_B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function _aesBytesToBase64(bytes) {
  var r = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b1=bytes[i], b2=i+1<bytes.length?bytes[i+1]:0, b3=i+2<bytes.length?bytes[i+2]:0;
    r += _AES_B64[b1>>2] + _AES_B64[((b1&3)<<4)|(b2>>4)] + (i+1<bytes.length?_AES_B64[((b2&15)<<2)|(b3>>6)]:'=') + (i+2<bytes.length?_AES_B64[b3&63]:'=');
  }
  return r;
}
function _aesBase64ToBytes(b64) {
  b64 = b64.replace(/[^A-Za-z0-9+/]/g, '');
  var bytes = [];
  for (var i = 0; i < b64.length; i += 4) {
    var b1=_AES_B64.indexOf(b64[i]), b2=_AES_B64.indexOf(b64[i+1]), b3=b64[i+2]==='='?0:_AES_B64.indexOf(b64[i+2]), b4=b64[i+3]==='='?0:_AES_B64.indexOf(b64[i+3]);
    bytes.push((b1<<2)|(b2>>4)); if (b64[i+2]!=='=') bytes.push(((b2&15)<<4)|(b3>>2)); if (b64[i+3]!=='=') bytes.push(((b3&3)<<6)|b4);
  }
  return bytes;
}
function _aesParseKey(val) {
  if (!val) return [];
  if (typeof val === 'object' && val.words && Array.isArray(val.words)) {
    var bytes = [];
    for (var i = 0; i < val.words.length; i++) { bytes.push((val.words[i]>>24)&0xff, (val.words[i]>>16)&0xff, (val.words[i]>>8)&0xff, val.words[i]&0xff); }
    return val.sigBytes !== undefined ? bytes.slice(0, val.sigBytes) : bytes;
  }
  if (typeof val === 'string') return _aesUtf8ToBytes(val);
  if (Array.isArray(val)) return val;
  if (typeof val === 'number') return [val];
  return [];
}

// ===== AES 公共 API =====
var _AES = {
  encrypt: function(data, key, iv, mode) {
    mode = mode || 'CBC';
    var kb = _aesParseKey(key), ivb = iv ? _aesParseKey(iv) : [];
    var db = (typeof data === 'string') ? _aesUtf8ToBytes(data) : data;
    var nr = kb.length/4 + 6, w = _aesKeyExpansion(kb), padded = _aesPkcs7Pad(db), encrypted = [];
    if (mode === 'ECB') { for (var i=0;i<padded.length;i+=16) { encrypted=encrypted.concat(_aesEncryptBlock(padded.slice(i,i+16),w,nr)); } }
    else { var prev=ivb.length>=16?ivb.slice(0,16):new Array(16).fill(0); for (var i=0;i<padded.length;i+=16) { var block=padded.slice(i,i+16); for (var j=0;j<16;j++) block[j]^=prev[j]; var enc=_aesEncryptBlock(block,w,nr); encrypted=encrypted.concat(enc); prev=enc; } }
    return _aesBytesToBase64(encrypted);
  },
  decrypt: function(data, key, iv, mode) {
    mode = mode || 'CBC';
    var kb = _aesParseKey(key), ivb = iv ? _aesParseKey(iv) : [];
    var db = (typeof data === 'string') ? _aesBase64ToBytes(data) : data;
    var nr = kb.length/4 + 6, w = _aesKeyExpansion(kb), decrypted = [];
    if (mode === 'ECB') { for (var i=0;i<db.length;i+=16) { decrypted=decrypted.concat(_aesDecryptBlock(db.slice(i,i+16),w,nr)); } }
    else { var prev=ivb.length>=16?ivb.slice(0,16):new Array(16).fill(0); for (var i=0;i<db.length;i+=16) { var block=db.slice(i,i+16); var dec=_aesDecryptBlock(block,w,nr); for (var j=0;j<16;j++) dec[j]^=prev[j]; decrypted=decrypted.concat(dec); prev=block; } }
    return _aesBytesToUtf8(_aesPkcs7Unpad(decrypted));
  },
  utf8Parse: function(str) {
    var bytes = _aesUtf8ToBytes(str), words = [];
    for (var i = 0; i < bytes.length; i += 4) { words.push(((bytes[i]||0)<<24)|((bytes[i+1]||0)<<16)|((bytes[i+2]||0)<<8)|(bytes[i+3]||0)); }
    return { words: words, sigBytes: bytes.length };
  },
  base64Parse: function(str) {
    var bytes = _aesBase64ToBytes(str), words = [];
    for (var i = 0; i < bytes.length; i += 4) { words.push(((bytes[i]||0)<<24)|((bytes[i+1]||0)<<16)|((bytes[i+2]||0)<<8)|(bytes[i+3]||0)); }
    return { words: words, sigBytes: bytes.length };
  },
};

// ===== MD5 引擎 =====
var _MD5 = (function() {
  function safeAdd(x, y) { var l = (x & 0xFFFF) + (y & 0xFFFF), m = (x >> 16) + (y >> 16) + (l >> 16); return (m << 16) | (l & 0xFFFF); }
  function bitRotateLeft(n, c) { return (n << c) | (n >>> (32 - c)); }
  function md5cmn(q, a, b, x, s, t) { return safeAdd(bitRotateLeft(safeAdd(safeAdd(a, q), safeAdd(x, t)), s), b); }
  function md5ff(a, b, c, d, x, s, t) { return md5cmn((b & c) | ((~b) & d), a, b, x, s, t); }
  function md5gg(a, b, c, d, x, s, t) { return md5cmn((b & d) | (c & (~d)), a, b, x, s, t); }
  function md5hh(a, b, c, d, x, s, t) { return md5cmn(b ^ c ^ d, a, b, x, s, t); }
  function md5ii(a, b, c, d, x, s, t) { return md5cmn(c ^ (b | (~d)), a, b, x, s, t); }
  function binlMD5(x, len) {
    x[len >> 5] |= 0x80 << (len % 32);
    x[(((len + 64) >>> 9) << 4) + 14] = len;
    var a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
    for (var i = 0; i < x.length; i += 16) {
      var oa = a, ob = b, oc = c, od = d;
      a=md5ff(a,b,c,d,x[i],7,-680876936); d=md5ff(d,a,b,c,x[i+1],12,-389564586); c=md5ff(c,d,a,b,x[i+2],17,606105819); b=md5ff(b,c,d,a,x[i+3],22,-1044525330);
      a=md5ff(a,b,c,d,x[i+4],7,-176418897); d=md5ff(d,a,b,c,x[i+5],12,1200080426); c=md5ff(c,d,a,b,x[i+6],17,-1473231341); b=md5ff(b,c,d,a,x[i+7],22,-45705983);
      a=md5ff(a,b,c,d,x[i+8],7,1770035416); d=md5ff(d,a,b,c,x[i+9],12,-1958414417); c=md5ff(c,d,a,b,x[i+10],17,-42063); b=md5ff(b,c,d,a,x[i+11],22,-1990404162);
      a=md5ff(a,b,c,d,x[i+12],7,1804603682); d=md5ff(d,a,b,c,x[i+13],12,-40341101); c=md5ff(c,d,a,b,x[i+14],17,-1502002290); b=md5ff(b,c,d,a,x[i+15],22,1236535329);
      a=md5gg(a,b,c,d,x[i+1],5,-165796510); d=md5gg(d,a,b,c,x[i+6],9,-1069501632); c=md5gg(c,d,a,b,x[i+11],14,643717713); b=md5gg(b,c,d,a,x[i],20,-373897302);
      a=md5gg(a,b,c,d,x[i+5],5,-701558691); d=md5gg(d,a,b,c,x[i+10],9,38016083); c=md5gg(c,d,a,b,x[i+15],14,-660478335); b=md5gg(b,c,d,a,x[i+4],20,-405537848);
      a=md5gg(a,b,c,d,x[i+9],5,568446438); d=md5gg(d,a,b,c,x[i+14],9,-1019803690); c=md5gg(c,d,a,b,x[i+3],14,-187363961); b=md5gg(b,c,d,a,x[i+8],20,1163531501);
      a=md5gg(a,b,c,d,x[i+13],5,-1444681467); d=md5gg(d,a,b,c,x[i+2],9,-51403784); c=md5gg(c,d,a,b,x[i+7],14,1735328473); b=md5gg(b,c,d,a,x[i+12],20,-1926607734);
      a=md5hh(a,b,c,d,x[i+5],4,-378558); d=md5hh(d,a,b,c,x[i+8],11,-2022574463); c=md5hh(c,d,a,b,x[i+11],16,1839030562); b=md5hh(b,c,d,a,x[i+14],23,-35309556);
      a=md5hh(a,b,c,d,x[i+1],4,-1530992060); d=md5hh(d,a,b,c,x[i+4],11,1272893353); c=md5hh(c,d,a,b,x[i+7],16,-155497632); b=md5hh(b,c,d,a,x[i+10],23,-1094730640);
      a=md5hh(a,b,c,d,x[i+13],4,681279174); d=md5hh(d,a,b,c,x[i],11,-358537222); c=md5hh(c,d,a,b,x[i+3],16,-722521979); b=md5hh(b,c,d,a,x[i+6],23,76029189);
      a=md5hh(a,b,c,d,x[i+9],4,-640364487); d=md5hh(d,a,b,c,x[i+12],11,-421815835); c=md5hh(c,d,a,b,x[i+15],16,530742520); b=md5hh(b,c,d,a,x[i+2],23,-995338651);
      a=md5ii(a,b,c,d,x[i],6,-198630844); d=md5ii(d,a,b,c,x[i+7],10,1126891415); c=md5ii(c,d,a,b,x[i+14],15,-1416354905); b=md5ii(b,c,d,a,x[i+5],21,-57434055);
      a=md5ii(a,b,c,d,x[i+12],6,1700485571); d=md5ii(d,a,b,c,x[i+3],10,-1894986606); c=md5ii(c,d,a,b,x[i+10],15,-1051523); b=md5ii(b,c,d,a,x[i+1],21,-2054922799);
      a=md5ii(a,b,c,d,x[i+8],6,1873313359); d=md5ii(d,a,b,c,x[i+15],10,-30611744); c=md5ii(c,d,a,b,x[i+6],15,-1560198380); b=md5ii(b,c,d,a,x[i+13],21,1309151649);
      a=md5ii(a,b,c,d,x[i+4],6,-145523070); d=md5ii(d,a,b,c,x[i+11],10,-1120210379); c=md5ii(c,d,a,b,x[i+2],15,718787259); b=md5ii(b,c,d,a,x[i+9],21,-343485551);
      a=safeAdd(a,oa); b=safeAdd(b,ob); c=safeAdd(c,oc); d=safeAdd(d,od);
    }
    return [a, b, c, d];
  }
  function binl2rstr(input) {
    var output = '';
    for (var i = 0; i < input.length * 32; i += 8) output += String.fromCharCode((input[i >> 5] >>> (i % 32)) & 0xFF);
    return output;
  }
  function rstr2binl(input) {
    var output = [];
    for (var i = 0; i < input.length * 8; i += 32) output[i >> 5] = 0;
    for (var i = 0; i < input.length * 8; i += 8) output[i >> 5] |= (input.charCodeAt(i / 8) & 0xFF) << (i % 32);
    return output;
  }
  function rstrMD5(s) { return binl2rstr(binlMD5(rstr2binl(s), s.length * 8)); }
  function rstr2hex(input) {
    var hexTab = '0123456789abcdef', output = '';
    for (var i = 0; i < input.length; i++) {
      var x = input.charCodeAt(i);
      output += hexTab.charAt((x >>> 4) & 0x0F) + hexTab.charAt(x & 0x0F);
    }
    return output;
  }
  function str2rstrUTF8(input) { return unescape(encodeURIComponent(input)); }
  return function(str) { return rstr2hex(rstrMD5(str2rstrUTF8(str))); };
})();

// ===== SHA1 引擎 =====
var _SHA1 = (function() {
  function rotateLeft(n, c) { return (n << c) | (n >>> (32 - c)); }
  function utf8Encode(str) { return unescape(encodeURIComponent(str)); }
  function str2binb(str) {
    var bin = [], mask = (1 << 8) - 1;
    for (var i = 0; i < str.length * 8; i += 8)
      bin[i >> 5] |= (str.charCodeAt(i / 8) & mask) << (24 - i % 32);
    return bin;
  }
  function binb2hex(binarray) {
    var hexTab = '0123456789abcdef', str = '';
    for (var i = 0; i < binarray.length * 4; i++) {
      str += hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8 + 4)) & 0xF) +
             hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8)) & 0xF);
    }
    return str;
  }
  function sha1Core(x, len) {
    x[len >> 5] |= 0x80 << (24 - len % 32);
    x[((len + 64 >> 9) << 4) + 15] = len;
    var w = [], a = 1732584193, b = -271733879, c = -1732584194, d = 271733878, e = -1009589776;
    for (var i = 0; i < x.length; i += 16) {
      var oa = a, ob = b, oc = c, od = d, oe = e;
      for (var j = 0; j < 80; j++) {
        if (j < 16) w[j] = x[i + j];
        else w[j] = rotateLeft(w[j-3] ^ w[j-8] ^ w[j-14] ^ w[j-16], 1);
        var t = rotateLeft(a, 5) + ((j < 20) ? (b & c | ~b & d) + 1518500249 :
                (j < 40) ? (b ^ c ^ d) + 1859775393 :
                (j < 60) ? (b & c | b & d | c & d) - 1894007588 :
                           (b ^ c ^ d) - 899497514) + e + w[j];
        e = d; d = c; c = rotateLeft(b, 30); b = a; a = t;
      }
      a += oa; b += ob; c += oc; d += od; e += oe;
    }
    return [a, b, c, d, e];
  }
  return function(str) {
    var s = utf8Encode(str);
    return binb2hex(sha1Core(str2binb(s), s.length * 8));
  };
})();

// ===== SHA256 引擎 =====
var _SHA256 = (function() {
  var K = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  ];
  function rightRotate(n, c) { return (n >>> c) | (n << (32 - c)); }
  function utf8Encode(str) { return unescape(encodeURIComponent(str)); }
  function str2binb(str) {
    var bin = [], mask = (1 << 8) - 1;
    for (var i = 0; i < str.length * 8; i += 8)
      bin[i >> 5] |= (str.charCodeAt(i / 8) & mask) << (24 - i % 32);
    return bin;
  }
  function binb2hex(binarray) {
    var hexTab = '0123456789abcdef', str = '';
    for (var i = 0; i < binarray.length * 4; i++) {
      str += hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8 + 4)) & 0xF) +
             hexTab.charAt((binarray[i >> 2] >> ((3 - i % 4) * 8)) & 0xF);
    }
    return str;
  }
  return function(str) {
    var s = utf8Encode(str);
    var M = str2binb(s), l = s.length * 8;
    M[l >> 5] |= 0x80 << (24 - l % 32);
    M[((l + 64 >> 9) << 4) + 15] = l;
    var H0 = 0x6a09e667, H1 = 0xbb67ae85, H2 = 0x3c6ef372, H3 = 0xa54ff53a;
    var H4 = 0x510e527f, H5 = 0x9b05688c, H6 = 0x1f83d9ab, H7 = 0x5be0cd19;
    for (var i = 0; i < M.length; i += 16) {
      var a=H0,b=H1,c=H2,d=H3,e=H4,f=H5,g=H6,h=H7;
      var W = [];
      for (var t = 0; t < 64; t++) {
        if (t < 16) W[t] = M[i + t];
        else {
          var s0 = rightRotate(W[t-15],7) ^ rightRotate(W[t-15],18) ^ (W[t-15] >>> 3);
          var s1 = rightRotate(W[t-2],17) ^ rightRotate(W[t-2],19) ^ (W[t-2] >>> 10);
          W[t] = (W[t-16] + s0 + W[t-7] + s1) | 0;
        }
        var ch = (e & f) ^ (~e & g);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var S0 = rightRotate(a,2) ^ rightRotate(a,13) ^ rightRotate(a,22);
        var S1 = rightRotate(e,6) ^ rightRotate(e,11) ^ rightRotate(e,25);
        var T1 = (h + S1 + ch + K[t] + W[t]) | 0;
        var T2 = (S0 + maj) | 0;
        h=g; g=f; f=e; e=(d+T1)|0; d=c; c=b; b=a; a=(T1+T2)|0;
      }
      H0=(H0+a)|0; H1=(H1+b)|0; H2=(H2+c)|0; H3=(H3+d)|0;
      H4=(H4+e)|0; H5=(H5+f)|0; H6=(H6+g)|0; H7=(H7+h)|0;
    }
    return binb2hex([H0,H1,H2,H3,H4,H5,H6,H7]);
  };
})();

// ===== HMAC-SHA256 引擎 =====
var _HMACSHA256 = (function() {
  return function(data, key) {
    var sha256 = _SHA256;
    var blocksize = 64;
    var kStr = unescape(encodeURIComponent(key));
    var dStr = unescape(encodeURIComponent(data));
    if (kStr.length > blocksize) kStr = sha256(key);
    while (kStr.length < blocksize) kStr += '\x00';
    var oKeyPad = '', iKeyPad = '';
    for (var i = 0; i < blocksize; i++) {
      oKeyPad += String.fromCharCode(kStr.charCodeAt(i) ^ 0x5c);
      iKeyPad += String.fromCharCode(kStr.charCodeAt(i) ^ 0x36);
    }
    var innerHash = sha256(iKeyPad + dStr);
    return sha256(oKeyPad + hexStr2Str(innerHash));
  };
  function hexStr2Str(hex) {
    var str = '';
    for (var i = 0; i < hex.length; i += 2)
      str += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
    return str;
  }
})();

// ===== CryptoJS 兼容 API =====
// 提供与 npm crypto-js 包兼容的接口，底层走纯 JS 实现
var CryptoJS = {
  AES: {
    encrypt: function(data, key, cfg) {
      var keyStr = typeof key === 'string' ? key : (key && key.toString ? key.toString() : '');
      var iv = cfg && cfg.iv ? (typeof cfg.iv === 'string' ? cfg.iv : (cfg.iv && cfg.iv.toString ? cfg.iv.toString() : '')) : '';
      var mode = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'ECB' : 'CBC';
      var result = _AES.encrypt(data, keyStr, iv, mode);
      return { toString: function() { return result; }, ciphertext: { toString: function(enc) { return result; } } };
    },
    decrypt: function(data, key, cfg) {
      var keyStr = typeof key === 'string' ? key : (key && key.toString ? key.toString() : '');
      var iv = cfg && cfg.iv ? (typeof cfg.iv === 'string' ? cfg.iv : (cfg.iv && cfg.iv.toString ? cfg.iv.toString() : '')) : '';
      var mode = (cfg && cfg.mode === CryptoJS.mode.ECB) ? 'ECB' : 'CBC';
      var result = _AES.decrypt(data, keyStr, iv, mode);
      return { toString: function(enc) { return result; } };
    },
  },
  MD5: function(str) { return { toString: function() { return _MD5(str); } }; },
  SHA1: function(str) { return { toString: function() { return _SHA1(str); } }; },
  SHA256: function(str) { return { toString: function() { return _SHA256(str); } }; },
  HmacSHA256: function(data, key) { return { toString: function() { return _HMACSHA256(data, key); } }; },
  enc: {
    Utf8: {
      parse: function(s) { return _AES.utf8Parse(s); },
      stringify: function(w) { return typeof w === 'string' ? w : (w && w.toString ? w.toString() : ''); },
    },
    Base64: {
      parse: function(s) { return _AES.base64Parse(s); },
      stringify: function(w) { return typeof w === 'string' ? btoa(w) : (w && w.toString ? btoa(w.toString()) : ''); },
    },
    Hex: {
      parse: function(s) {
        var bytes = [], words = [];
        for (var i = 0; i < s.length; i += 2) bytes.push(parseInt(s.substr(i, 2), 16));
        for (var i = 0; i < bytes.length; i += 4) words.push(((bytes[i]||0)<<24)|((bytes[i+1]||0)<<16)|((bytes[i+2]||0)<<8)|(bytes[i+3]||0));
        return { words: words, sigBytes: bytes.length };
      },
      stringify: function(w) {
        if (typeof w === 'string') return w;
        if (w && w.words) {
          var hex = '';
          for (var i = 0; i < w.sigBytes; i++) {
            var b = (w.words[i >> 2] >> ((3 - i % 4) * 8)) & 0xff;
            hex += (b < 16 ? '0' : '') + b.toString(16);
          }
          return hex;
        }
        return '';
      },
    },
    Latin1: { parse: function(s) { return s; }, stringify: function(w) { return w; } },
  },
  mode: { ECB: {}, CBC: {} },
  pad: { Pkcs7: {}, ZeroPadding: {}, NoPadding: {}, Iso97971: {} },
  lib: {
    WordArray: {
      create: function(words, sigBytes) {
        return { words: words || [], sigBytes: sigBytes || 0, toString: function() { return (words || []).join(''); } };
      }
    }
  },
  algo: {},
};
