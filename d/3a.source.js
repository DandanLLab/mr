// @name 3A小说
// @url https://www.aaawww.cc
// @group 写源
// @type 0

var searchUrl = JSON.stringify({
  url: '/api-search',
  body: 'keyword={{key}}&page={{page}}&size=10',
  method: 'POST'
});

var exploreUrl = '[]';

// ===== jsLib: XSVUE 压缩库（LZString）=====
var XSVUE = function () {
  var _0x23751e = String.fromCharCode;
  var _0x3ced15 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
  var _0x1d1483 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$";
  var _0x580dcb = {};
  function _0x28ba1a(_0x2f8367, _0x3ffced) {
    {
      if (!_0x580dcb[_0x2f8367]) {
        {
          _0x580dcb[_0x2f8367] = {};
          for (var _0x33d8a4 = 0; _0x33d8a4 < _0x2f8367.length; _0x33d8a4++) {
            _0x580dcb[_0x2f8367][_0x2f8367.charAt(_0x33d8a4)] = _0x33d8a4;
          }
        }
      }
      return _0x580dcb[_0x2f8367][_0x3ffced];
    }
  }
  var _0x74c117 = {
    compressToBase64: function (_0x437e73) {
      {
        if (_0x437e73 == null) {
          return "";
        }
        var _0x37f29b = _0x74c117._compress(_0x437e73, 6, function (_0x3ec0d3) {
          {
            return _0x3ced15.charAt(_0x3ec0d3);
          }
        });
        switch (_0x37f29b.length % 4) {
          default:
          case 0:
            return _0x37f29b;
          case 1:
            return _0x37f29b + "===";
          case 2:
            return _0x37f29b + "==";
          case 3:
            return _0x37f29b + "=";
        }
      }
    },
    decompressFromBase64: function (_0x270cf7) {
  if (_0x270cf7 == null) {
    return "";
  }
  if (_0x270cf7 == "") {
    return null;
  }
  
  var _0x3ced15 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
  var _0x580dcb = {};
  
  function _0x28ba1a(_0x2f8367, _0x3ffced) {
    if (!_0x580dcb[_0x2f8367]) {
      _0x580dcb[_0x2f8367] = {};
      for (var _0x33d8a4 = 0; _0x33d8a4 < _0x2f8367.length; _0x33d8a4++) {
        _0x580dcb[_0x2f8367][_0x2f8367.charAt(_0x33d8a4)] = _0x33d8a4;
      }
    }
    return _0x580dcb[_0x2f8367][_0x3ffced];
  }
  
  function _0xdecompress(_0x59931f, _0x265873, _0x88276c) {
    var _0x5d4d3f = [];
    var _0xcbe84c;
    var _0x4032ab = 4;
    var _0x2e49c3 = 4;
    var _0x4dd191 = 3;
    var _0x41b0a4 = "";
    var _0x5eb07a = [];
    var _0x5c1ccd;
    var _0x4fd2f5;
    var _0x2ff1dd;
    var _0x429fb6;
    var _0x4f4ea6;
    var _0x4ecf48;
    var _0x162a1a;
    var data = {
      val: _0x88276c(0),
      position: _0x265873,
      index: 1
    };
    
    for (_0x5c1ccd = 0; _0x5c1ccd < 3; _0x5c1ccd += 1) {
      _0x5d4d3f[_0x5c1ccd] = _0x5c1ccd;
    }
    
    _0x2ff1dd = 0;
    _0x4f4ea6 = Math.pow(2, 2);
    _0x4ecf48 = 1;
    
    while (_0x4ecf48 != _0x4f4ea6) {
      _0x429fb6 = data.val & data.position;
      data.position >>= 1;
      if (data.position == 0) {
        data.position = _0x265873;
        data.val = _0x88276c(data.index++);
      }
      _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
      _0x4ecf48 <<= 1;
    }
    
    switch (_0xcbe84c = _0x2ff1dd) {
      case 0:
        _0x2ff1dd = 0;
        _0x4f4ea6 = Math.pow(2, 8);
        _0x4ecf48 = 1;
        while (_0x4ecf48 != _0x4f4ea6) {
          _0x429fb6 = data.val & data.position;
          data.position >>= 1;
          if (data.position == 0) {
            data.position = _0x265873;
            data.val = _0x88276c(data.index++);
          }
          _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
          _0x4ecf48 <<= 1;
        }
        _0x162a1a = String.fromCharCode(_0x2ff1dd);
        break;
      case 1:
        _0x2ff1dd = 0;
        _0x4f4ea6 = Math.pow(2, 16);
        _0x4ecf48 = 1;
        while (_0x4ecf48 != _0x4f4ea6) {
          _0x429fb6 = data.val & data.position;
          data.position >>= 1;
          if (data.position == 0) {
            data.position = _0x265873;
            data.val = _0x88276c(data.index++);
          }
          _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
          _0x4ecf48 <<= 1;
        }
        _0x162a1a = String.fromCharCode(_0x2ff1dd);
        break;
      case 2:
        return "";
    }
    
    _0x5d4d3f[3] = _0x162a1a;
    _0x4fd2f5 = _0x162a1a;
    _0x5eb07a.push(_0x162a1a);
    
    while (true) {
      if (data.index > _0x59931f) {
        return "";
      }
      
      _0x2ff1dd = 0;
      _0x4f4ea6 = Math.pow(2, _0x4dd191);
      _0x4ecf48 = 1;
      
      while (_0x4ecf48 != _0x4f4ea6) {
        _0x429fb6 = data.val & data.position;
        data.position >>= 1;
        if (data.position == 0) {
          data.position = _0x265873;
          data.val = _0x88276c(data.index++);
        }
        _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
        _0x4ecf48 <<= 1;
      }
      
      switch (_0x162a1a = _0x2ff1dd) {
        case 0:
          _0x2ff1dd = 0;
          _0x4f4ea6 = Math.pow(2, 8);
          _0x4ecf48 = 1;
          while (_0x4ecf48 != _0x4f4ea6) {
            _0x429fb6 = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) {
              data.position = _0x265873;
              data.val = _0x88276c(data.index++);
            }
            _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
            _0x4ecf48 <<= 1;
          }
          _0x5d4d3f[_0x2e49c3++] = String.fromCharCode(_0x2ff1dd);
          _0x162a1a = _0x2e49c3 - 1;
          _0x4032ab--;
          break;
        case 1:
          _0x2ff1dd = 0;
          _0x4f4ea6 = Math.pow(2, 16);
          _0x4ecf48 = 1;
          while (_0x4ecf48 != _0x4f4ea6) {
            _0x429fb6 = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) {
              data.position = _0x265873;
              data.val = _0x88276c(data.index++);
            }
            _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
            _0x4ecf48 <<= 1;
          }
          _0x5d4d3f[_0x2e49c3++] = String.fromCharCode(_0x2ff1dd);
          _0x162a1a = _0x2e49c3 - 1;
          _0x4032ab--;
          break;
        case 2:
          return _0x5eb07a.join("");
      }
      
      if (_0x4032ab == 0) {
        _0x4032ab = Math.pow(2, _0x4dd191);
        _0x4dd191++;
      }
      
      if (_0x5d4d3f[_0x162a1a]) {
        _0x41b0a4 = _0x5d4d3f[_0x162a1a];
      } else {
        if (_0x162a1a === _0x2e49c3) {
          _0x41b0a4 = _0x4fd2f5 + _0x4fd2f5.charAt(0);
        } else {
          return null;
        }
      }
      
      _0x5eb07a.push(_0x41b0a4);
      _0x5d4d3f[_0x2e49c3++] = _0x4fd2f5 + _0x41b0a4.charAt(0);
      _0x4032ab--;
      _0x4fd2f5 = _0x41b0a4;
      
      if (_0x4032ab == 0) {
        _0x4032ab = Math.pow(2, _0x4dd191);
        _0x4dd191++;
      }
    }
  }
  
  return _0xdecompress(_0x270cf7.length, 32, function (_0x5162e0) {
    return _0x28ba1a(_0x3ced15, _0x270cf7.charAt(_0x5162e0));
  });
},
    compressToUTF16: function (_0xb5a153) {
      if (_0xb5a153 == null) {
        return "";
      }
      return _0x74c117._compress(_0xb5a153, 15, function (_0x5e989b) {
        {
          return _0x23751e(_0x5e989b + 32);
        }
      }) + " ";
    },
    decompressFromUTF16: function (_0x2cb419) {
      {
        if (_0x2cb419 == null) {
          return "";
        }
        if (_0x2cb419 == "") {
          return null;
        }
        return _0x74c117._decompress(_0x2cb419.length, 16384, function (_0x11d3b4) {
          return _0x2cb419.charCodeAt(_0x11d3b4) - 32;
        });
      }
    },
    compressToUint8Array: function (_0x47a1fc) {
      var _0x331ac0 = _0x74c117.compress(_0x47a1fc);
      var _0x574f74 = new Uint8Array(_0x331ac0.length * 2);
      for (var _0x4917b4 = 0, _0x22f34f = _0x331ac0.length; _0x4917b4 < _0x22f34f; _0x4917b4++) {
        {
          var _0x1b0258 = _0x331ac0.charCodeAt(_0x4917b4);
          _0x574f74[_0x4917b4 * 2] = _0x1b0258 >>> 8;
          _0x574f74[_0x4917b4 * 2 + 1] = _0x1b0258 % 256;
        }
      }
      return _0x574f74;
    },
    decompressFromUint8Array: function (_0xf1b57f) {
      if (_0xf1b57f === null || _0xf1b57f === undefined) {
        {
          return _0x74c117.decompress(_0xf1b57f);
        }
      } else {
        {
          var _0x1a2a39 = new Array(_0xf1b57f.length / 2);
          for (var _0x1c3335 = 0, _0x452f17 = _0x1a2a39.length; _0x1c3335 < _0x452f17; _0x1c3335++) {
            _0x1a2a39[_0x1c3335] = _0xf1b57f[_0x1c3335 * 2] * 256 + _0xf1b57f[_0x1c3335 * 2 + 1];
          }
          var _0x27d94e = [];
          _0x1a2a39.forEach(function (_0x396b62) {
            {
              _0x27d94e.push(_0x23751e(_0x396b62));
            }
          });
          return _0x74c117.decompress(_0x27d94e.join(""));
        }
      }
    },
    compressToEncodedURIComponent: function (_0x4535e5) {
      if (_0x4535e5 == null) {
        return "";
      }
      return _0x74c117._compress(_0x4535e5, 6, function (_0x24b024) {
        {
          return _0x1d1483.charAt(_0x24b024);
        }
      });
    },
    decompressFromEncodedURIComponent: function (_0xf254e4) {
      if (_0xf254e4 == null) {
        return "";
      }
      if(!_0xf254e4){return null;}
      _0xf254e4 = String(_0xf254e4).replace(/ /g, "+");
      return _0x74c117._decompress(_0xf254e4.length, 32, function (_0x3b225f) {
        return _0x28ba1a(_0x1d1483, _0xf254e4.charAt(_0x3b225f));
      });
    },
    compress: function (_0x37f9a7) {
      {
        return _0x74c117._compress(_0x37f9a7, 16, function (_0x4cbdb7) {
          return _0x23751e(_0x4cbdb7);
        });
      }
    },
    _compress: function (_0x47ded7, _0x338642, _0x3381ba) {
      {
        if (_0x47ded7 == null) {
          return "";
        }
        var _0x35df51;
        var _0x384fcf;
        var _0x10fadf = {};
        var _0x15cd0a = {};
        var _0x86bdee = "";
        var _0x1ec58c = "";
        var _0x26f666 = "";
        var _0x319b15 = 2;
        var _0x3c3c72 = 3;
        var _0x3aa476 = 2;
        var _0x3dc23f = [];
        var _0x87625e = 0;
        var _0x3f4388 = 0;
        var _0x2a0179;
        for (_0x2a0179 = 0; _0x2a0179 < _0x47ded7.length; _0x2a0179 += 1) {
          _0x86bdee = _0x47ded7.charAt(_0x2a0179);
          !Object.prototype.hasOwnProperty.call(_0x10fadf, _0x86bdee) && (_0x10fadf[_0x86bdee] = _0x3c3c72++, _0x15cd0a[_0x86bdee] = true);
          _0x1ec58c = _0x26f666 + _0x86bdee;
          if (Object.prototype.hasOwnProperty.call(_0x10fadf, _0x1ec58c)) {
            _0x26f666 = _0x1ec58c;
          } else {
            {
              if (Object.prototype.hasOwnProperty.call(_0x15cd0a, _0x26f666)) {
                {
                  if (_0x26f666.charCodeAt(0) < 256) {
                    {
                      for (_0x35df51 = 0; _0x35df51 < _0x3aa476; _0x35df51++) {
                        _0x87625e = _0x87625e << 1;
                        _0x3f4388 == _0x338642 - 1 ? (_0x3f4388 = 0, _0x3dc23f.push(_0x3381ba(_0x87625e)), _0x87625e = 0) : _0x3f4388++;
                      }
                      _0x384fcf = _0x26f666.charCodeAt(0);
                      for (_0x35df51 = 0; _0x35df51 < 8; _0x35df51++) {
                        _0x87625e = _0x87625e << 1 | _0x384fcf & 1;
                        _0x3f4388 == _0x338642 - 1 ? (_0x3f4388 = 0, _0x3dc23f.push(_0x3381ba(_0x87625e)), _0x87625e = 0) : _0x3f4388++;
                        _0x384fcf = _0x384fcf >> 1;
                      }
                    }
                  } else {
                    {
                      _0x384fcf = 1;
                      for (_0x35df51 = 0; _0x35df51 < _0x3aa476; _0x35df51++) {
                        {
                          _0x87625e = _0x87625e << 1 | _0x384fcf;
                          if (_0x3f4388 == _0x338642 - 1) {
                            {
                              _0x3f4388 = 0;
                              _0x3dc23f.push(_0x3381ba(_0x87625e));
                              _0x87625e = 0;
                            }
                          } else {
                            _0x3f4388++;
                          }
                          _0x384fcf = 0;
                        }
                      }
                      _0x384fcf = _0x26f666.charCodeAt(0);
                      for (_0x35df51 = 0; _0x35df51 < 16; _0x35df51++) {
                        {
                          _0x87625e = _0x87625e << 1 | _0x384fcf & 1;
                          if (_0x3f4388 == _0x338642 - 1) {
                            _0x3f4388 = 0;
                            _0x3dc23f.push(_0x3381ba(_0x87625e));
                            _0x87625e = 0;
                          } else {
                            _0x3f4388++;
                          }
                          _0x384fcf = _0x384fcf >> 1;
                        }
                      }
                    }
                  }
                  _0x319b15--;
                  _0x319b15 == 0 && (_0x319b15 = Math.pow(2, _0x3aa476), _0x3aa476++);
                  delete _0x15cd0a[_0x26f666];
                }
              } else {
                _0x384fcf = _0x10fadf[_0x26f666];
                for (_0x35df51 = 0; _0x35df51 < _0x3aa476; _0x35df51++) {
                  _0x87625e = _0x87625e << 1 | _0x384fcf & 1;
                  _0x3f4388 == _0x338642 - 1 ? (_0x3f4388 = 0, _0x3dc23f.push(_0x3381ba(_0x87625e)), _0x87625e = 0) : _0x3f4388++;
                  _0x384fcf = _0x384fcf >> 1;
                }
              }
              _0x319b15--;
              _0x319b15 == 0 && (_0x319b15 = Math.pow(2, _0x3aa476), _0x3aa476++);
              _0x10fadf[_0x1ec58c] = _0x3c3c72++;
              _0x26f666 = String(_0x86bdee);
            }
          }
        }
        if (_0x26f666 !== "") {
          if (Object.prototype.hasOwnProperty.call(_0x15cd0a, _0x26f666)) {
            {
              if (_0x26f666.charCodeAt(0) < 256) {
                {
                  for (_0x35df51 = 0; _0x35df51 < _0x3aa476; _0x35df51++) {
                    _0x87625e = _0x87625e << 1;
                    if (_0x3f4388 == _0x338642 - 1) {
                      _0x3f4388 = 0;
                      _0x3dc23f.push(_0x3381ba(_0x87625e));
                      _0x87625e = 0;
                    } else {
                      {
                        _0x3f4388++;
                      }
                    }
                  }
                  _0x384fcf = _0x26f666.charCodeAt(0);
                  for (_0x35df51 = 0; _0x35df51 < 8; _0x35df51++) {
                    {
                      _0x87625e = _0x87625e << 1 | _0x384fcf & 1;
                      if (_0x3f4388 == _0x338642 - 1) {
                        _0x3f4388 = 0;
                        _0x3dc23f.push(_0x3381ba(_0x87625e));
                        _0x87625e = 0;
                      } else {
                        {
                          _0x3f4388++;
                        }
                      }
                      _0x384fcf = _0x384fcf >> 1;
                    }
                  }
                }
              } else {
                _0x384fcf = 1;
                for (_0x35df51 = 0; _0x35df51 < _0x3aa476; _0x35df51++) {
                  {
                    _0x87625e = _0x87625e << 1 | _0x384fcf;
                    if (_0x3f4388 == _0x338642 - 1) {
                      {
                        _0x3f4388 = 0;
                        _0x3dc23f.push(_0x3381ba(_0x87625e));
                        _0x87625e = 0;
                      }
                    } else {
                      _0x3f4388++;
                    }
                    _0x384fcf = 0;
                  }
                }
                _0x384fcf = _0x26f666.charCodeAt(0);
                for (_0x35df51 = 0; _0x35df51 < 16; _0x35df51++) {
                  {
                    _0x87625e = _0x87625e << 1 | _0x384fcf & 1;
                    if (_0x3f4388 == _0x338642 - 1) {
                      {
                        _0x3f4388 = 0;
                        _0x3dc23f.push(_0x3381ba(_0x87625e));
                        _0x87625e = 0;
                      }
                    } else {
                      _0x3f4388++;
                    }
                    _0x384fcf = _0x384fcf >> 1;
                  }
                }
              }
              _0x319b15--;
              _0x319b15 == 0 && (_0x319b15 = Math.pow(2, _0x3aa476), _0x3aa476++);
              delete _0x15cd0a[_0x26f666];
            }
          } else {
            _0x384fcf = _0x10fadf[_0x26f666];
            for (_0x35df51 = 0; _0x35df51 < _0x3aa476; _0x35df51++) {
              {
                _0x87625e = _0x87625e << 1 | _0x384fcf & 1;
                if (_0x3f4388 == _0x338642 - 1) {
                  {
                    _0x3f4388 = 0;
                    _0x3dc23f.push(_0x3381ba(_0x87625e));
                    _0x87625e = 0;
                  }
                } else {
                  _0x3f4388++;
                }
                _0x384fcf = _0x384fcf >> 1;
              }
            }
          }
          _0x319b15--;
          _0x319b15 == 0 && (_0x319b15 = Math.pow(2, _0x3aa476), _0x3aa476++);
        }
        _0x384fcf = 2;
        for (_0x35df51 = 0; _0x35df51 < _0x3aa476; _0x35df51++) {
          _0x87625e = _0x87625e << 1 | _0x384fcf & 1;
          _0x3f4388 == _0x338642 - 1 ? (_0x3f4388 = 0, _0x3dc23f.push(_0x3381ba(_0x87625e)), _0x87625e = 0) : _0x3f4388++;
          _0x384fcf = _0x384fcf >> 1;
        }
        while (true) {
          {
            _0x87625e = _0x87625e << 1;
            if (_0x3f4388 == _0x338642 - 1) {
              _0x3dc23f.push(_0x3381ba(_0x87625e));
              break;
            } else {
              _0x3f4388++;
            }
          }
        }
        return _0x3dc23f.join("");
      }
    },
    decompress: function (_0x480722) {
      {
        if (_0x480722 == null) {
          return "";
        }
        if (_0x480722 == "") {
          return null;
        }
        return _0x74c117._decompress(_0x480722.length, 32768, function (_0x170dd2) {
          {
            return _0x480722.charCodeAt(_0x170dd2);
          }
        });
      }
    },
    _decompress: function (_0x59931f, _0x265873, _0x88276c) {
      {
        var _0x5d4d3f = [];
        var _0xcbe84c;
        var _0x4032ab = 4;
        var _0x2e49c3 = 4;
        var _0x4dd191 = 3;
        var _0x41b0a4 = "";
        var _0x5eb07a = [];
        var _0x5c1ccd;
        var _0x4fd2f5;
        var _0x2ff1dd;
        var _0x429fb6;
        var _0x4f4ea6;
        var _0x4ecf48;
        var _0x162a1a;
        var data = {
          val: _0x88276c(0),
          position: _0x265873,
          index: 1
        };
        for (_0x5c1ccd = 0; _0x5c1ccd < 3; _0x5c1ccd += 1) {
          _0x5d4d3f[_0x5c1ccd] = _0x5c1ccd;
        }
        _0x2ff1dd = 0;
        _0x4f4ea6 = Math.pow(2, 2);
        _0x4ecf48 = 1;
        while (_0x4ecf48 != _0x4f4ea6) {
          _0x429fb6 = data.val & data.position;
          data.position >>= 1;
          data.position == 0 && (data.position = _0x265873, data.val = _0x88276c(data.index++));
          _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
          _0x4ecf48 <<= 1;
        }
        switch (_0xcbe84c = _0x2ff1dd) {
          case 0:
            _0x2ff1dd = 0;
            _0x4f4ea6 = Math.pow(2, 8);
            _0x4ecf48 = 1;
            while (_0x4ecf48 != _0x4f4ea6) {
              {
                _0x429fb6 = data.val & data.position;
                data.position >>= 1;
                data.position == 0 && (data.position = _0x265873, data.val = _0x88276c(data.index++));
                _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
                _0x4ecf48 <<= 1;
              }
            }
            _0x162a1a = _0x23751e(_0x2ff1dd);
            break;
          case 1:
            _0x2ff1dd = 0;
            _0x4f4ea6 = Math.pow(2, 16);
            _0x4ecf48 = 1;
            while (_0x4ecf48 != _0x4f4ea6) {
              _0x429fb6 = data.val & data.position;
              data.position >>= 1;
              data.position == 0 && (data.position = _0x265873, data.val = _0x88276c(data.index++));
              _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
              _0x4ecf48 <<= 1;
            }
            _0x162a1a = _0x23751e(_0x2ff1dd);
            break;
          case 2:
            return "";
        }
        _0x5d4d3f[3] = _0x162a1a;
        _0x4fd2f5 = _0x162a1a;
        _0x5eb07a.push(_0x162a1a);
        while (true) {
          {
            if (data.index > _0x59931f) {
              return "";
            }
            _0x2ff1dd = 0;
            _0x4f4ea6 = Math.pow(2, _0x4dd191);
            _0x4ecf48 = 1;
            while (_0x4ecf48 != _0x4f4ea6) {
              _0x429fb6 = data.val & data.position;
              data.position >>= 1;
              data.position == 0 && (data.position = _0x265873, data.val = _0x88276c(data.index++));
              _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
              _0x4ecf48 <<= 1;
            }
            switch (_0x162a1a = _0x2ff1dd) {
              case 0:
                _0x2ff1dd = 0;
                _0x4f4ea6 = Math.pow(2, 8);
                _0x4ecf48 = 1;
                while (_0x4ecf48 != _0x4f4ea6) {
                  {
                    _0x429fb6 = data.val & data.position;
                    data.position >>= 1;
                    data.position == 0 && (data.position = _0x265873, data.val = _0x88276c(data.index++));
                    _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
                    _0x4ecf48 <<= 1;
                  }
                }
                _0x5d4d3f[_0x2e49c3++] = _0x23751e(_0x2ff1dd);
                _0x162a1a = _0x2e49c3 - 1;
                _0x4032ab--;
                break;
              case 1:
                _0x2ff1dd = 0;
                _0x4f4ea6 = Math.pow(2, 16);
                _0x4ecf48 = 1;
                while (_0x4ecf48 != _0x4f4ea6) {
                  {
                    _0x429fb6 = data.val & data.position;
                    data.position >>= 1;
                    if (data.position == 0) {
                      {
                        data.position = _0x265873;
                        data.val = _0x88276c(data.index++);
                      }
                    }
                    _0x2ff1dd |= (_0x429fb6 > 0 ? 1 : 0) * _0x4ecf48;
                    _0x4ecf48 <<= 1;
                  }
                }
                _0x5d4d3f[_0x2e49c3++] = _0x23751e(_0x2ff1dd);
                _0x162a1a = _0x2e49c3 - 1;
                _0x4032ab--;
                break;
              case 2:
                return _0x5eb07a.join("");
            }
            if (_0x4032ab == 0) {
              {
                _0x4032ab = Math.pow(2, _0x4dd191);
                _0x4dd191++;
              }
            }
            if (_0x5d4d3f[_0x162a1a]) {
              {
                _0x41b0a4 = _0x5d4d3f[_0x162a1a];
              }
            } else {
              {
                if (_0x162a1a === _0x2e49c3) {
                  {
                    _0x41b0a4 = _0x4fd2f5 + _0x4fd2f5.charAt(0);
                  }
                } else {
                  return null;
                }
              }
            }
            _0x5eb07a.push(_0x41b0a4);
            _0x5d4d3f[_0x2e49c3++] = _0x4fd2f5 + _0x41b0a4.charAt(0);
            _0x4032ab--;
            _0x4fd2f5 = _0x41b0a4;
            _0x4032ab == 0 && (_0x4032ab = Math.pow(2, _0x4dd191), _0x4dd191++);
          }
        }
      }
    }
  };
  return _0x74c117;
}();
(function(global){ if(typeof XSVUE !== "undefined"){ global.XSVUE = XSVUE; } else { /* no export found */ } })(this);

// ===== jsLib 结束 =====

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
  var body = XSVUE.decompressFromBase64(result);
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
  var body = XSVUE.decompressFromBase64(result);
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
  var body = XSVUE.decompressFromBase64(result);
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
  // AES-CBC 解密（用内置 CryptoJS，密钥同原 _0x3ed9ab）
  var raw = atob(result);
  var iv = [], cipher = [];
  for (var i = 0; i < 16; i++) iv.push(raw.charCodeAt(i));
  for (var i = 16; i < raw.length; i++) cipher.push(raw.charCodeAt(i));
  var key = CryptoJS.enc.Utf8.parse('123#2^0@0vm@08.b890123g456789012');
  var decrypted = CryptoJS.AES.decrypt(cipher, key, { iv: iv, mode: CryptoJS.mode.CBC, padding: CryptoJS.pad.Pkcs7 });
  var decryptedStr = decrypted.toString(CryptoJS.enc.Utf8);
  // LZString 解压
  return XSVUE.decompressFromBase64(decryptedStr);
}

function nextTocUrl(result) {
  return '';
}

function nextContentUrl(result) {
  return '';
}
