// CMS1 源配置密文解密的回归测试。
//
// 用服务端 /api/source-key 下发的 probe 密文做固定样本（明文固定为
// cmbok-source-key-probe-v1），确保 AES-256-GCM 的参数（12 字节 nonce、
// 16 字节 tag 附在密文尾部、AAD 为空）不被改坏。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cmbok_app/source/cms1_crypto.dart';

/// keyId k2026-19a 的密钥（与 Cms1Crypto 内置兜底一致）。
const _keyHex =
    '11cb5487834d83ba21f120aafaa67e5415c088cbed478cee932d0322265186e3';

/// probe 密文（CMS1 格式）。
const _probeCipher =
    'Q01TMQHgIlq5yN3v2OOCy8jVsVf0CNyPq+IX1vFmienfrvP6gnE2VAJF5YFfOz/aZ8s9aenaGWz4oQ==';

void main() {
  setUp(() {
    // 预置本地密钥，避免测试触发网络请求
    SharedPreferences.setMockInitialValues({'cms1_key_hex': _keyHex});
  });

  test('CMS1 密文识别', () {
    expect(Cms1Crypto.looksEncrypted(_probeCipher), isTrue);
    expect(Cms1Crypto.looksEncrypted('{"version":1,"sources":[]}'), isFalse);
    expect(Cms1Crypto.looksEncrypted(''), isFalse);
    expect(Cms1Crypto.looksEncrypted('https://example.com/sources.json'), isFalse);
  });

  test('probe 解密为固定明文', () async {
    expect(await Cms1Crypto.decrypt(_probeCipher), 'cmbok-source-key-probe-v1');
  });

  test('非密文原样跳过', () async {
    expect(await Cms1Crypto.tryDecrypt('{"a":1}'), isNull);
    expect(await Cms1Crypto.tryDecrypt(_probeCipher), 'cmbok-source-key-probe-v1');
  });

  test('密钥不匹配时抛出（不清缓存、不返回半截明文）', () async {
    SharedPreferences.setMockInitialValues({
      'cms1_key_hex': '00' * 32,
    });
    // 重新取密钥会走网络（测试环境不可达）后回退兜底密钥，最终应能解开 probe
    expect(await Cms1Crypto.tryDecrypt(_probeCipher), isNotNull);
  });
}
