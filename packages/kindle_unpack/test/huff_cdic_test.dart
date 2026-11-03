import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

/// Build a HUFF record where every codeword is exactly 1 bit long.
/// Bit `0` resolves to dictionary entry 1, bit `1` resolves to entry 0
/// (canonical Huffman: longer-numbered codes map to lower-indexed
/// entries). The cache and base table are sized so that the
/// `decompressHuffCdic` fast path (terminal cache hit) handles every
/// lookup.
Uint8List _build1BitHuff() {
  // Header (24 bytes) + dict1 (1024 bytes) + dict2 (256 bytes).
  final out = Uint8List(24 + 1024 + 256);
  final view = ByteData.sublistView(out);

  // Signature + header length.
  out[0] = 'H'.codeUnitAt(0);
  out[1] = 'U'.codeUnitAt(0);
  out[2] = 'F'.codeUnitAt(0);
  out[3] = 'F'.codeUnitAt(0);
  view.setUint32(4, 0x18);
  view.setUint32(8, 24); // dict1 offset
  view.setUint32(12, 24 + 1024); // dict2 offset

  // Cache: every entry encodes (codelen=1, terminal=1, maxcode_raw=1).
  // Packed: (1 << 8) | 0x80 | 1 = 0x181.
  for (var i = 0; i < 256; i++) {
    view.setUint32(24 + i * 4, 0x181);
  }

  // Base table: pair 0 (for codelen 1) is (mincode=0, maxcode=1). Other
  // pairs all zero — no codes of those lengths exist.
  view.setUint32(24 + 1024, 0); // mincode @ codelen 1
  view.setUint32(24 + 1024 + 4, 1); // maxcode @ codelen 1
  // Remaining 248 bytes are already zero.

  return out;
}

/// Build a CDIC record with the given precoded phrases. `bits` controls
/// the per-record entry cap (typically 16 in real files; here we use a
/// just-large-enough value).
Uint8List _buildCdic(List<List<int>> phrases, {required int bits, int? totalPhraseCountOverride}) {
  // Body = offset table (n × 2 bytes) + entries (each = 2-byte length +
  // payload).
  final n = phrases.length;
  var bodyLen = n * 2;
  for (final p in phrases) {
    bodyLen += 2 + p.length;
  }
  final out = Uint8List(16 + bodyLen);
  final view = ByteData.sublistView(out);

  out[0] = 'C'.codeUnitAt(0);
  out[1] = 'D'.codeUnitAt(0);
  out[2] = 'I'.codeUnitAt(0);
  out[3] = 'C'.codeUnitAt(0);
  view.setUint32(4, 0x10);
  view.setUint32(8, totalPhraseCountOverride ?? n);
  view.setUint32(12, bits);

  // Lay out entries first to record their offsets.
  var cursor = n * 2; // body offset (relative to byte 16)
  for (var i = 0; i < n; i++) {
    final p = phrases[i];
    view.setUint16(16 + i * 2, cursor);
    // length+flag: precoded => high bit set.
    view.setUint16(16 + cursor, 0x8000 | p.length);
    out.setRange(16 + cursor + 2, 16 + cursor + 2 + p.length, p);
    cursor += 2 + p.length;
  }

  return out;
}

void main() {
  group('HuffTable.parse', () {
    test('decodes a minimal 1-bit HUFF record', () {
      final huff = HuffTable.parse(_build1BitHuff());
      expect(huff.cache, hasLength(256));
      expect(huff.cache[0].codeLen, 1);
      expect(huff.cache[0].terminal, isTrue);
      // For 1-bit codes, mincode[1] = 0 << 31, maxcode[1] = ((1+1)<<31)-1.
      expect(huff.minCode[1], 0);
      expect(huff.maxCodeByLen[1], 0xFFFFFFFF);
    });

    test('throws on wrong signature', () {
      final bytes = _build1BitHuff();
      bytes[0] = 'X'.codeUnitAt(0);
      expect(
        () => HuffTable.parse(bytes),
        throwsA(isA<HuffCdicException>()),
      );
    });

    test('throws on wrong header length', () {
      final bytes = _build1BitHuff();
      ByteData.sublistView(bytes).setUint32(4, 0x20);
      expect(
        () => HuffTable.parse(bytes),
        throwsA(isA<HuffCdicException>()),
      );
    });

    test('throws when dict1 offset would extend past record', () {
      final bytes = _build1BitHuff();
      ByteData.sublistView(bytes).setUint32(8, bytes.length);
      expect(
        () => HuffTable.parse(bytes),
        throwsA(isA<HuffCdicException>()),
      );
    });

    test('throws when a cache entry has codelen 0', () {
      final bytes = _build1BitHuff();
      ByteData.sublistView(bytes).setUint32(24, 0); // entry 0 = all zeros
      expect(
        () => HuffTable.parse(bytes),
        throwsA(isA<HuffCdicException>()),
      );
    });
  });

  group('CdicTable.parse', () {
    test('decodes a minimal CDIC with two precoded entries', () {
      final cdic = CdicTable.parse([
        _buildCdic([
          [0x57], // 'W'
          [0x48], // 'H'
        ], bits: 1),
      ]);
      expect(cdic.entries, hasLength(2));
      expect(cdic.entries[0].bytes, [0x57]);
      expect(cdic.entries[0].precoded, isTrue);
      expect(cdic.entries[1].bytes, [0x48]);
    });

    test('merges entries from multiple CDIC records', () {
      // Total 4 phrases, split 2 + 2 across two records. bits=1 means
      // each record holds at most 2 entries, so the second record gets
      // the remaining 2.
      final r1 = _buildCdic([
        [0x41], // 'A'
        [0x42], // 'B'
      ], bits: 1, totalPhraseCountOverride: 4);
      final r2 = _buildCdic([
        [0x43], // 'C'
        [0x44], // 'D'
      ], bits: 1, totalPhraseCountOverride: 4);
      final cdic = CdicTable.parse([r1, r2]);
      expect(cdic.entries.map((e) => e.bytes[0]), [0x41, 0x42, 0x43, 0x44]);
    });

    test('throws on wrong signature', () {
      final bytes = _buildCdic([
        [0x41]
      ], bits: 1);
      bytes[0] = 'X'.codeUnitAt(0);
      expect(
        () => CdicTable.parse([bytes]),
        throwsA(isA<HuffCdicException>()),
      );
    });

    test('throws when the record list does not fill the declared phrase count',
        () {
      final r1 = _buildCdic([
        [0x41]
      ], bits: 1, totalPhraseCountOverride: 5);
      expect(
        () => CdicTable.parse([r1]),
        throwsA(isA<HuffCdicException>()),
      );
    });

    test('decodes the precoded flag from the length+flag word', () {
      // Manually craft a CDIC where entry 0's high bit is clear (= not
      // precoded). The decompressor would normally interpret these
      // bytes recursively; we just verify the parser surfaces the flag.
      final out = Uint8List(16 + 2 + 2 + 1);
      final view = ByteData.sublistView(out);
      out[0] = 'C'.codeUnitAt(0);
      out[1] = 'D'.codeUnitAt(0);
      out[2] = 'I'.codeUnitAt(0);
      out[3] = 'C'.codeUnitAt(0);
      view.setUint32(4, 0x10);
      view.setUint32(8, 1); // 1 phrase total
      view.setUint32(12, 1); // bits = 1
      view.setUint16(16, 2); // entry 0 offset = 2
      // entry 0 at body offset 2: length=1, flag=0 (not precoded).
      view.setUint16(16 + 2, 0x0001);
      out[16 + 2 + 2] = 0xAB;

      final cdic = CdicTable.parse([out]);
      expect(cdic.entries[0].precoded, isFalse);
      expect(cdic.entries[0].bytes, [0xAB]);
    });
  });

  group('decompressHuffCdic', () {
    test('round-trip: 1-bit codes, all-precoded dictionary', () {
      // Dict[0] = "no", Dict[1] = "yes"
      final huff = HuffTable.parse(_build1BitHuff());
      final cdic = CdicTable.parse([
        _buildCdic([
          [0x6E, 0x6F], // "no"
          [0x79, 0x65, 0x73], // "yes"
        ], bits: 1),
      ]);

      // Input bits "01" packed into one byte (0x40 = 0100 0000).
      // Reading 8 bits MSB-first emits dict[1] dict[0] dict[1]*6.
      // = "yes" + "no" + "yes" * 6.
      final input = _u8([0x40]);
      final out = decompressHuffCdic(input: input, huff: huff, cdic: cdic);
      expect(
        String.fromCharCodes(out),
        'yesno${'yes' * 6}',
      );
    });

    test('handles a 2-byte input across the 32-bit window boundary', () {
      // Same setup as above, longer input. With 16 bits and 1-bit codes
      // we expect 16 phrases.
      final huff = HuffTable.parse(_build1BitHuff());
      final cdic = CdicTable.parse([
        _buildCdic([
          [0x4E], // 'N'
          [0x59], // 'Y'
        ], bits: 1),
      ]);

      // Recall: bit 0 → dict[1]='Y', bit 1 → dict[0]='N'.
      // 0xAA = 10101010 → N Y N Y N Y N Y
      // 0x55 = 01010101 → Y N Y N Y N Y N
      final input = _u8([0xAA, 0x55]);
      final out = decompressHuffCdic(input: input, huff: huff, cdic: cdic);
      expect(String.fromCharCodes(out), 'NYNYNYNYYNYNYNYN');
    });

    test('expands a non-precoded dictionary entry recursively', () {
      // Layered HUFF/CDIC: dict[1] = literal "B"; dict[0] is itself a
      // HUFF/CDIC payload — one byte 0x00 = bit 0 = lookup dict[1]. So
      // expanding dict[0] yields dict[1] eight times = "BBBBBBBB".
      final huff = HuffTable.parse(_build1BitHuff());
      final cdic = CdicTable.parse([
        _buildCdicMixed([
          // Entry 0: not precoded — payload is one zero byte that
          // decodes (under the same HUFF) to 8 lookups of dict[1].
          (bytes: const [0x00], precoded: false),
          // Entry 1: literal "B".
          (bytes: const [0x42], precoded: true),
        ]),
      ]);

      // Input "1" emits dict[0]; recursive expansion = "BBBBBBBB" × 1.
      // Then 7 more "0" bits each emit dict[1] = "B" → 7 more 'B'.
      // Total: 8 + 7 = 15 'B's.
      final out = decompressHuffCdic(
        input: _u8([0x80]),
        huff: huff,
        cdic: cdic,
      );
      expect(String.fromCharCodes(out), 'B' * 15);
    });
  });
}

/// Variant builder that lets each entry choose the precoded flag.
Uint8List _buildCdicMixed(List<({List<int> bytes, bool precoded})> phrases) {
  final n = phrases.length;
  var bodyLen = n * 2;
  for (final p in phrases) {
    bodyLen += 2 + p.bytes.length;
  }
  final out = Uint8List(16 + bodyLen);
  final view = ByteData.sublistView(out);
  out[0] = 'C'.codeUnitAt(0);
  out[1] = 'D'.codeUnitAt(0);
  out[2] = 'I'.codeUnitAt(0);
  out[3] = 'C'.codeUnitAt(0);
  view.setUint32(4, 0x10);
  view.setUint32(8, n);
  view.setUint32(12, 1); // bits
  var cursor = n * 2;
  for (var i = 0; i < n; i++) {
    final p = phrases[i];
    view.setUint16(16 + i * 2, cursor);
    final flag = p.precoded ? 0x8000 : 0x0000;
    view.setUint16(16 + cursor, flag | p.bytes.length);
    out.setRange(16 + cursor + 2, 16 + cursor + 2 + p.bytes.length, p.bytes);
    cursor += 2 + p.bytes.length;
  }
  return out;
}
