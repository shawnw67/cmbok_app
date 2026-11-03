// CMS1 源配置密文解密（独立工具类）。
//
// 云端下发的 sources 配置可能是密文，格式为：
//   base64( "CMS1" + 1 字节版本号 + 12 字节 nonce + 密文 + 16 字节 GCM tag )
// 算法为 AES-256-GCM，AAD 为空；密钥是 64 位 hex（解码成 32 字节）的 AES-256 key。
//
// 密钥来源：服务器 /api/source-key（需要 deviceId，任意 32 位 hex 即可），
// 返回 {"ok":true,"key":"<64 hex>","probe":"<CMS1 密文>"}。probe 可自校验。
// 复用流程：内存缓存 -> SharedPreferences 缓存 -> 请求服务器 -> 内置兜底密钥。
// 密钥轮换时解密会抛 InvalidCipherTextException，此时清缓存重取一次。
//
// 与 lib/services/crypto.dart（拷贝漫画接口解密，AES-CBC）无关，两者协议不同。

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[Cms1Crypto] $message');
}

class Cms1Crypto {
  Cms1Crypto._();

  static const _magic = 'CMS1';
  static const _keyEndpoint = 'https://bluemood.xiaomy.net/api/source-key';

  /// 服务端不可达时的兜底密钥（keyId k2026-19a，2026-11 取）。
  static const _fallbackKeyHex =
      '11cb5487834d83ba21f120aafaa67e5415c088cbed478cee932d0322265186e3';

  static const _prefKeyHex = 'cms1_key_hex';
  static const _prefDeviceId = 'cms1_device_id';

  /// probe 明文，用于校验服务端下发的密钥是否正确。
  static const _probePlain = 'cmbok-source-key-probe-v1';

  static Uint8List? _cachedKey;

  /// 是否为 CMS1 密文（base64 文本，解码后以 "CMS1" 开头）。
  ///
  /// 只做前缀粗筛 + 一次 base64 解码，避免把普通 JSON 误判进去。
  static bool looksEncrypted(String raw) {
    final s = raw.trim();
    // "CMS1" 的 base64 前 6 字符固定是 Q01TMQ
    if (s.length < 40 || !s.startsWith('Q01TMQ')) return false;
    try {
      final bytes = base64Decode(s);
      return bytes.length > 17 && _magicOf(bytes) == _magic;
    } catch (_) {
      return false;
    }
  }

  /// 解密 CMS1 密文，返回明文（通常是 JSON 文本，也可能是 URL）。
  ///
  /// 密钥自动获取（缓存/服务端/兜底）；解密失败会清缓存重取密钥再试一次。
  static Future<String> decrypt(String encoded) async {
    final bytes = base64Decode(encoded.trim());
    if (_magicOf(bytes) != _magic) {
      throw const FormatException('不是 CMS1 密文');
    }
    var key = await _key();
    try {
      return _decryptWith(bytes, key);
    } catch (e) {
      _log('首次解密失败（可能密钥已轮换）: $e，重新获取密钥');
      key = await _refreshKey();
      return _decryptWith(bytes, key);
    }
  }

  /// 若 [raw] 是 CMS1 密文则解密，否则原样返回。解密失败返回 null。
  static Future<String?> tryDecrypt(String raw) async {
    if (!looksEncrypted(raw)) return null;
    try {
      return await decrypt(raw);
    } catch (e) {
      _log('解密失败: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  static String _magicOf(Uint8List bytes) =>
      bytes.length < 4 ? '' : String.fromCharCodes(bytes.sublist(0, 4));

  static String _decryptWith(Uint8List blob, Uint8List key) {
    // blob = CMS1(4) + version(1) + nonce(12) + ciphertext + tag(16)
    final body = blob.sublist(5);
    if (body.length < 12 + 16) throw const FormatException('CMS1 密文长度不足');
    final nonce = body.sublist(0, 12);
    final cipherAndTag = body.sublist(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
      );
    final plain = gcm.process(cipherAndTag); // tag 校验失败会抛异常
    return utf8.decode(plain);
  }

  static Uint8List _hexToBytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static Future<Uint8List> _key() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefKeyHex);
      if (stored != null && stored.length == 64) {
        return _cachedKey = _hexToBytes(stored);
      }
    } catch (e) {
      _log('读取本地密钥失败: $e');
    }
    return _refreshKey();
  }

  /// 清缓存并向服务端重新取密钥；失败退回内置兜底密钥。
  static Future<Uint8List> _refreshKey() async {
    _cachedKey = null;
    final fetched = await _fetchKeyFromServer();
    if (fetched != null) return _cachedKey = fetched;
    _log('回退内置兜底密钥');
    return _cachedKey = _hexToBytes(_fallbackKeyHex);
  }

  static Future<Uint8List?> _fetchKeyFromServer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var deviceId = prefs.getString(_prefDeviceId);
      if (deviceId == null || deviceId.length != 32) {
        deviceId = _randomHex(16);
        await prefs.setString(_prefDeviceId, deviceId);
      }
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          responseType: ResponseType.json,
        ),
      );
      final res = await dio.post<dynamic>(
        _keyEndpoint,
        data: {'deviceId': deviceId},
        options: Options(contentType: Headers.jsonContentType),
      );
      final data = res.data;
      if (data is! Map) return null;
      if (data['ok'] != true) {
        _log('取密钥失败: ${data['msg'] ?? data}');
        return null;
      }
      final hex = (data['key'] as String?)?.trim() ?? '';
      if (hex.length != 64) return null;
      final key = _hexToBytes(hex);

      // 用 probe 校验密钥：解不开就当这次取到的无效，避免污染本地缓存。
      final probe = data['probe'] as String?;
      if (probe != null && probe.isNotEmpty) {
        try {
          final plain = _decryptWith(base64Decode(probe), key);
          if (plain != _probePlain) {
            _log('probe 校验不符: $plain');
            return null;
          }
        } catch (e) {
          _log('probe 校验失败: $e');
          return null;
        }
      }
      await prefs.setString(_prefKeyHex, hex);
      _log('已从服务端获取密钥 keyId=${data['keyId']}');
      return key;
    } catch (e) {
      _log('请求密钥接口失败: $e');
      return null;
    }
  }

  static String _randomHex(int bytes) {
    final rnd = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
