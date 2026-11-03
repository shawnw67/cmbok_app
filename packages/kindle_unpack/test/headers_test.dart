import 'dart:convert';
import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

/// Builds a synthetic record-0 byte sequence: a 16-byte PalmDOC header,
/// followed by a 232-byte MOBI header (the most common size), optionally
/// followed by a `fullName` payload past the MOBI header.
///
/// The builder lets each test override only the fields that matter to it.
Uint8List _buildRecord0({
  // PalmDOC header
  int compression = 2, // PalmDOC
  int textLength = 0x10000,
  int textRecordCount = 16,
  int maxRecordSize = 4096,
  int encryption = 0,
  // MOBI header
  int headerLength = 232,
  int mobiType = 2,
  int textEncoding = 65001,
  int uniqueId = 0xDEADBEEF,
  int fileVersion = 6,
  int firstNonBookIndex = 0xFFFFFFFF,
  int fullNameOffset = 248, // immediately after a 232-byte MOBI header
  int fullNameLength = 0,
  int locale = 9,
  int firstImageIndex = 5,
  int huffmanRecordOffset = 0,
  int huffmanRecordCount = 0,
  int exthFlags = 0x40,
  int drmOffset = 0xFFFFFFFF,
  int drmCount = 0xFFFFFFFF,
  int drmSize = 0,
  int drmFlags = 0,
  // Optional payload (fullName etc.) appended after the MOBI header.
  List<int>? trailing,
}) {
  final mobiEnd = 16 + headerLength;
  final tail = trailing ?? const <int>[];
  final out = Uint8List(mobiEnd + tail.length);
  final view = ByteData.sublistView(out);

  // PalmDOC header
  view.setUint16(0, compression);
  view.setUint32(4, textLength);
  view.setUint16(8, textRecordCount);
  view.setUint16(10, maxRecordSize);
  view.setUint16(12, encryption);

  // MOBI signature + length live at the start of the MOBI header.
  out[16] = 'M'.codeUnitAt(0);
  out[17] = 'O'.codeUnitAt(0);
  out[18] = 'B'.codeUnitAt(0);
  out[19] = 'I'.codeUnitAt(0);
  view.setUint32(20, headerLength);

  // Helper that writes inside the declared MOBI header only.
  void writeU32(int relOffset, int value) {
    if (relOffset + 4 > headerLength) return;
    view.setUint32(16 + relOffset, value);
  }

  writeU32(8, mobiType);
  writeU32(12, textEncoding);
  writeU32(16, uniqueId);
  writeU32(20, fileVersion);
  writeU32(64, firstNonBookIndex);
  writeU32(68, fullNameOffset);
  writeU32(72, fullNameLength);
  writeU32(76, locale);
  writeU32(92, firstImageIndex);
  writeU32(96, huffmanRecordOffset);
  writeU32(100, huffmanRecordCount);
  writeU32(112, exthFlags);
  writeU32(152, drmOffset);
  writeU32(156, drmCount);
  writeU32(160, drmSize);
  writeU32(164, drmFlags);

  if (tail.isNotEmpty) {
    out.setRange(mobiEnd, mobiEnd + tail.length, tail);
  }
  return out;
}

void main() {
  group('PalmDocHeader.parse', () {
    test('decodes all fields from a typical header', () {
      final r0 = _buildRecord0(
        compression: 2,
        textLength: 0x12345,
        textRecordCount: 17,
        maxRecordSize: 4096,
        encryption: 0,
      );
      final h = PalmDocHeader.parse(r0);

      expect(h.compression, CompressionType.palmDoc);
      expect(h.textLength, 0x12345);
      expect(h.textRecordCount, 17);
      expect(h.maxRecordSize, 4096);
      expect(h.encryption, EncryptionType.none);
      expect(h.isEncrypted, isFalse);
    });

    test('recognises each compression code', () {
      expect(
        PalmDocHeader.parse(_buildRecord0(compression: 1)).compression,
        CompressionType.none,
      );
      expect(
        PalmDocHeader.parse(_buildRecord0(compression: 2)).compression,
        CompressionType.palmDoc,
      );
      expect(
        PalmDocHeader.parse(_buildRecord0(compression: 17480)).compression,
        CompressionType.huffCdic,
      );
    });

    test('recognises each encryption code', () {
      expect(
        PalmDocHeader.parse(_buildRecord0(encryption: 0)).encryption,
        EncryptionType.none,
      );
      expect(
        PalmDocHeader.parse(_buildRecord0(encryption: 1)).encryption,
        EncryptionType.oldMobipocket,
      );
      expect(
        PalmDocHeader.parse(_buildRecord0(encryption: 2)).encryption,
        EncryptionType.mobipocket,
      );
    });

    test('isEncrypted is true for any non-zero encryption value', () {
      expect(
        PalmDocHeader.parse(_buildRecord0(encryption: 2)).isEncrypted,
        isTrue,
      );
    });

    test('throws on unknown compression code', () {
      expect(
        () => PalmDocHeader.parse(_buildRecord0(compression: 999)),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws on unknown encryption code', () {
      expect(
        () => PalmDocHeader.parse(_buildRecord0(encryption: 7)),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when buffer is shorter than 16 bytes', () {
      expect(
        () => PalmDocHeader.parse(Uint8List(10)),
        throwsA(isA<HeaderException>()),
      );
    });
  });

  group('MobiHeader.parse', () {
    test('decodes all fields from a typical header', () {
      final r0 = _buildRecord0(
        textEncoding: 65001,
        uniqueId: 0xCAFEBABE,
        fileVersion: 8,
        firstImageIndex: 12,
        huffmanRecordOffset: 0,
        exthFlags: 0x40,
        drmOffset: 0xFFFFFFFF,
        drmCount: 0xFFFFFFFF,
      );
      final h = MobiHeader.parse(r0);

      expect(h.headerLength, 232);
      expect(h.mobiType, 2);
      expect(h.textEncoding, 65001);
      expect(h.uniqueId, 0xCAFEBABE);
      expect(h.fileVersion, 8);
      expect(h.firstImageIndex, 12);
      expect(h.huffmanRecordOffset, 0);
      expect(h.exthFlags, 0x40);
      expect(h.hasExth, isTrue);
      expect(h.hasDrm, isFalse);
      expect(h.exthOffset, 16 + 232);
    });

    test('hasExth is false when the EXTH flag bit is clear', () {
      final h = MobiHeader.parse(_buildRecord0(exthFlags: 0));
      expect(h.hasExth, isFalse);
    });

    test('hasDrm is true when DRM offset and count are both set', () {
      final h = MobiHeader.parse(
        _buildRecord0(drmOffset: 0x1000, drmCount: 1, drmSize: 64),
      );
      expect(h.hasDrm, isTrue);
    });

    test('hasDrm is false when DRM count is zero or unset', () {
      expect(
        MobiHeader.parse(_buildRecord0(drmOffset: 0x1000, drmCount: 0)).hasDrm,
        isFalse,
      );
      expect(
        MobiHeader.parse(
          _buildRecord0(drmOffset: 0xFFFFFFFF, drmCount: 0xFFFFFFFF),
        ).hasDrm,
        isFalse,
      );
    });

    test('fullName decodes UTF-8 when textEncoding is 65001', () {
      const title = 'Café — résumé';
      final bytes = utf8.encode(title);
      final r0 = _buildRecord0(
        textEncoding: 65001,
        fullNameOffset: 16 + 232,
        fullNameLength: bytes.length,
        trailing: bytes,
      );
      final h = MobiHeader.parse(r0);
      expect(h.fullName(r0), title);
    });

    test('fullName decodes latin1 when textEncoding is 1252', () {
      const title = 'Plain ASCII Title';
      final bytes = title.codeUnits;
      final r0 = _buildRecord0(
        textEncoding: 1252,
        fullNameOffset: 16 + 232,
        fullNameLength: bytes.length,
        trailing: bytes,
      );
      final h = MobiHeader.parse(r0);
      expect(h.fullName(r0), title);
    });

    test('fullName returns empty string when length is 0', () {
      final h = MobiHeader.parse(_buildRecord0(fullNameLength: 0));
      expect(h.fullName(_buildRecord0(fullNameLength: 0)), '');
    });

    test('short MOBI header reports tail fields as null', () {
      // 132-byte header: covers EXTH flags but stops short of DRM section.
      final r0 = _buildRecord0(headerLength: 132, exthFlags: 0x40);
      final h = MobiHeader.parse(r0);
      expect(h.headerLength, 132);
      expect(h.exthFlags, 0x40);
      expect(h.drmOffset, isNull);
      expect(h.drmCount, isNull);
      expect(h.hasDrm, isFalse);
    });

    test('throws when MOBI signature is wrong', () {
      final r0 = _buildRecord0();
      r0[16] = 'X'.codeUnitAt(0);
      expect(() => MobiHeader.parse(r0), throwsA(isA<HeaderException>()));
    });

    test('throws when headerLength is too small', () {
      // headerLength of 8 is below the 24-byte minimum we accept.
      final r0 = _buildRecord0();
      ByteData.sublistView(r0).setUint32(20, 8);
      expect(() => MobiHeader.parse(r0), throwsA(isA<HeaderException>()));
    });

    test('throws when headerLength extends past record 0', () {
      final r0 = _buildRecord0();
      ByteData.sublistView(r0).setUint32(20, r0.length); // 16 + huge > len
      expect(() => MobiHeader.parse(r0), throwsA(isA<HeaderException>()));
    });

    test('throws when fullName slice extends past record 0', () {
      final r0 = _buildRecord0(
        fullNameOffset: 16 + 232,
        fullNameLength: 100, // no trailing bytes were appended
      );
      final h = MobiHeader.parse(r0);
      expect(() => h.fullName(r0), throwsA(isA<HeaderException>()));
    });

    test('throws when buffer is too small for signature + length', () {
      expect(
        () => MobiHeader.parse(Uint8List(20)),
        throwsA(isA<HeaderException>()),
      );
    });
  });
}
