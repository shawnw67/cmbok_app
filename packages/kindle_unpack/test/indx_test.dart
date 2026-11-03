import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

/// Build a minimal forward variable-width int per the INDX format:
/// each byte holds 7 bits (high to low), the byte with the high bit
/// set marks the end. Mirrors KindleUnpack's `getVariableWidthValue`.
List<int> _vwi(int value) {
  if (value < 0) throw ArgumentError('value must be non-negative');
  final out = <int>[];
  out.add((value & 0x7F) | 0x80); // terminator (low 7 bits)
  var v = value >> 7;
  while (v != 0) {
    out.insert(0, v & 0x7F);
    v >>= 7;
  }
  return out;
}

/// Build a minimal "main" INDX record at offset 0:
///   "INDX" + 192-byte header + TAGX block.
/// Caller controls the `count` field (number of entry-INDX records that
/// follow) and `nctoc`. The TAGX block is appended verbatim.
Uint8List _mainIndx({
  required int count,
  required int nctoc,
  required Uint8List tagx,
  int codepage = 65001,
}) {
  // Header is 192 bytes; TAGX follows immediately after.
  const headerLen = 192;
  final out = Uint8List(headerLen + tagx.length);
  out[0] = 'I'.codeUnitAt(0);
  out[1] = 'N'.codeUnitAt(0);
  out[2] = 'D'.codeUnitAt(0);
  out[3] = 'X'.codeUnitAt(0);
  final view = ByteData.sublistView(out);
  view.setUint32(4, headerLen);
  view.setUint32(24, count); // index count = number of entry blocks
  view.setUint32(28, codepage);
  view.setUint32(52, nctoc);
  out.setRange(headerLen, headerLen + tagx.length, tagx);
  return out;
}

/// Build a minimal TAGX block: "TAGX" + firstEntryOffset + cbCount +
/// 4-byte (tag, vpe, mask, endFlag) tuples.
Uint8List _tagx(int controlByteCount, List<List<int>> rows) {
  final firstEntryOffset = 12 + rows.length * 4;
  final out = Uint8List(firstEntryOffset);
  out[0] = 'T'.codeUnitAt(0);
  out[1] = 'A'.codeUnitAt(0);
  out[2] = 'G'.codeUnitAt(0);
  out[3] = 'X'.codeUnitAt(0);
  final view = ByteData.sublistView(out);
  view.setUint32(4, firstEntryOffset);
  view.setUint32(8, controlByteCount);
  for (var i = 0; i < rows.length; i++) {
    out[12 + i * 4] = rows[i][0];
    out[12 + i * 4 + 1] = rows[i][1];
    out[12 + i * 4 + 2] = rows[i][2];
    out[12 + i * 4 + 3] = rows[i][3];
  }
  return out;
}

/// Build an entry-INDX record (the type-1 INDX) holding one or more
/// entries. Each entry has: 1-byte name length + name + control bytes
/// + variable-width values, ordered to match the supplied TAGX rows.
Uint8List _entryIndx({
  required List<({String name, List<int> controlBytes, List<int> data})>
      entries,
}) {
  const headerLen = 192;
  // Build a body that lays the entries out and records start offsets.
  final body = <int>[];
  final positions = <int>[];
  for (final e in entries) {
    positions.add(headerLen + body.length);
    body.add(e.name.length);
    body.addAll(e.name.codeUnits);
    body.addAll(e.controlBytes);
    body.addAll(e.data);
  }
  final idxtStart = headerLen + body.length;
  // IDXT section: "IDXT" + uint16 positions + 2 bytes padding.
  final idxt = <int>[
    'I'.codeUnitAt(0),
    'D'.codeUnitAt(0),
    'X'.codeUnitAt(0),
    'T'.codeUnitAt(0),
  ];
  for (final pos in positions) {
    idxt.add((pos >> 8) & 0xFF);
    idxt.add(pos & 0xFF);
  }
  // Pad to 4-byte alignment.
  while ((idxt.length % 4) != 0) {
    idxt.add(0);
  }

  final total = idxtStart + idxt.length;
  final out = Uint8List(total);
  out[0] = 'I'.codeUnitAt(0);
  out[1] = 'N'.codeUnitAt(0);
  out[2] = 'D'.codeUnitAt(0);
  out[3] = 'X'.codeUnitAt(0);
  final view = ByteData.sublistView(out);
  view.setUint32(4, headerLen);
  view.setUint32(12, 1); // type 1 = entry block
  view.setUint32(20, idxtStart); // IDXT start
  view.setUint32(24, entries.length); // entry count
  out.setRange(headerLen, idxtStart, body);
  out.setRange(idxtStart, total, idxt);
  return out;
}

PdbFile _wrap(List<Uint8List> records) => PdbFile(
      header: const PdbHeader(
        name: 'test',
        attributes: 0,
        version: 0,
        creationDate: 0,
        modificationDate: 0,
        lastBackupDate: 0,
        modificationNumber: 0,
        appInfoId: 0,
        sortInfoId: 0,
        type: 'BOOK',
        creator: 'MOBI',
        uniqueIdSeed: 0,
        recordCount: 0,
      ),
      records: records
          .map((r) => PdbRecord(
                offset: 0,
                attributes: 0,
                uniqueId: 0,
                data: r,
              ))
          .toList(growable: false),
    );

void main() {
  group('IndxData.read', () {
    test('decodes entries with the small-count tag encoding', () {
      // TAGX: tag 1 (vpe=1, mask=0x03), end-marker.
      final tagx = _tagx(1, [
        [1, 1, 0x03, 0],
        [0, 0, 0x00, 1],
      ]);
      // Single entry "A": control byte 0x01 (count=1 in mask-0x03 slot),
      // then one var-int value 42.
      final entry = _entryIndx(entries: [
        (
          name: 'A',
          controlBytes: [0x01],
          data: _vwi(42),
        ),
      ]);
      final pdb = _wrap([_mainIndx(count: 1, nctoc: 0, tagx: tagx), entry]);
      final indx = IndxData.read(pdb, 0);
      expect(indx.entries, hasLength(1));
      expect(indx.entries[0].tagMap[1], [42]);
    });

    test('decodes multi-value tags with the byte-length encoding', () {
      // mask=0x03, all-bits-set path → next data byte is a var-int
      // BYTE-LENGTH; we then read var-ints until that many bytes
      // consumed.
      final tagx = _tagx(1, [
        [6, 2, 0x03, 0],
        [0, 0, 0x00, 1],
      ]);
      // Two var-int values: 100 (1 byte 0xE4) and 200 (2 bytes 0x01 0xC8).
      final dataBytes = [..._vwi(100), ..._vwi(200)];
      final byteLen = dataBytes.length; // 3
      final entry = _entryIndx(entries: [
        (
          name: 'X',
          controlBytes: [0x03],
          data: [..._vwi(byteLen), ...dataBytes],
        ),
      ]);
      final pdb = _wrap([_mainIndx(count: 1, nctoc: 0, tagx: tagx), entry]);
      final indx = IndxData.read(pdb, 0);
      expect(indx.entries[0].tagMap[6], [100, 200]);
    });

    test('decodes CTOC strings into the offset map', () {
      // No actual entries — just a main + entry block + ctoc record.
      final tagx = _tagx(1, [
        [0, 0, 0x00, 1],
      ]);
      final main = _mainIndx(count: 1, nctoc: 1, tagx: tagx);
      final entry = _entryIndx(entries: const []);
      // CTOC: <var-int len><bytes> sequences, terminated by 0.
      const a = 'hello';
      const b = 'world!';
      final ctoc = Uint8List.fromList([
        ..._vwi(a.length),
        ...a.codeUnits,
        ..._vwi(b.length),
        ...b.codeUnits,
        0,
      ]);
      final pdb = _wrap([main, entry, ctoc]);
      final indx = IndxData.read(pdb, 0);
      expect(indx.ctoc, hasLength(2));
      // First string starts at offset 0 of the CTOC record; second
      // follows after the first var-int + payload.
      final firstKey = indx.ctoc.keys.first;
      expect(String.fromCharCodes(indx.ctoc[firstKey]!), a);
    });

    test('throws on missing INDX signature', () {
      final tagx = _tagx(1, [
        [0, 0, 0x00, 1],
      ]);
      final main = _mainIndx(count: 1, nctoc: 0, tagx: tagx);
      main[0] = 'X'.codeUnitAt(0);
      expect(
        () => IndxData.read(_wrap([main]), 0),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws on missing TAGX signature', () {
      // Build a main INDX whose post-header bytes don't start with TAGX.
      final tagx = _tagx(1, [
        [0, 0, 0x00, 1],
      ]);
      final main = _mainIndx(count: 1, nctoc: 0, tagx: tagx);
      // Corrupt the TAGX magic.
      main[192] = 'Y'.codeUnitAt(0);
      expect(
        () => IndxData.read(_wrap([main]), 0),
        throwsA(isA<HeaderException>()),
      );
    });
  });
}
