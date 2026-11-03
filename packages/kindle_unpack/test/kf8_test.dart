import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

/// Minimal FDST record builder.
Uint8List _buildFdst(List<(int, int)> entries) {
  final out = Uint8List(12 + entries.length * 8);
  final view = ByteData.sublistView(out);
  out[0] = 'F'.codeUnitAt(0);
  out[1] = 'D'.codeUnitAt(0);
  out[2] = 'S'.codeUnitAt(0);
  out[3] = 'T'.codeUnitAt(0);
  view.setUint32(4, 12); // header length
  view.setUint32(8, entries.length);
  for (var i = 0; i < entries.length; i++) {
    final (start, end) = entries[i];
    view.setUint32(12 + i * 8, start);
    view.setUint32(12 + i * 8 + 4, end);
  }
  return out;
}

/// Minimal Mobi-7-shaped record 0 with a configurable file version.
/// Fields not driven by the test are left as innocuous defaults; the
/// builder targets [KindleFile.inspect] which only reads PalmDOC +
/// MOBI + EXTH.
Uint8List _buildRecord0({
  required int fileVersion,
  int compression = 2, // PalmDOC
  int textRecordCount = 1,
  int? exth121, // KF8 boundary record number to stuff into EXTH 121
  bool exthPresent = false,
}) {
  // PalmDOC header (16) + MOBI header (232) + optional EXTH.
  const mobiHeaderLen = 232;
  final exthBlock = exth121 == null && !exthPresent
      ? Uint8List(0)
      : _buildExth(
          exth121 == null
              ? const <(int, List<int>)>[]
              : [(ExthType.kf8BoundaryRecord, _u32(exth121))],
        );

  final out = Uint8List(16 + mobiHeaderLen + exthBlock.length);
  final view = ByteData.sublistView(out);

  // PalmDOC.
  view.setUint16(0, compression);
  view.setUint32(4, 0); // text length — irrelevant for boundary detection
  view.setUint16(8, textRecordCount);
  view.setUint16(10, 4096);
  view.setUint16(12, 0); // encryption

  // MOBI signature + length.
  out[16] = 'M'.codeUnitAt(0);
  out[17] = 'O'.codeUnitAt(0);
  out[18] = 'B'.codeUnitAt(0);
  out[19] = 'I'.codeUnitAt(0);
  view.setUint32(20, mobiHeaderLen);

  // Set EXTH bit 0x40 when an EXTH block follows so MobiHeader.parse
  // honours it.
  void writeU32(int relOffset, int value) {
    if (relOffset + 4 > mobiHeaderLen) return;
    view.setUint32(16 + relOffset, value);
  }

  writeU32(8, 2); // mobi type (Mobipocket book)
  writeU32(12, 65001); // text encoding (UTF-8)
  writeU32(20, fileVersion);
  writeU32(112, exth121 != null || exthPresent ? 0x40 : 0); // exthFlags
  writeU32(152, MobiHeader.unset); // drmOffset
  writeU32(156, MobiHeader.unset); // drmCount

  if (exthBlock.isNotEmpty) {
    out.setRange(16 + mobiHeaderLen, 16 + mobiHeaderLen + exthBlock.length,
        exthBlock);
  }
  return out;
}

Uint8List _buildExth(List<(int, List<int>)> records) {
  var bodyLen = 0;
  for (final r in records) {
    bodyLen += 8 + r.$2.length;
  }
  final totalLen = 12 + bodyLen;
  final out = Uint8List(totalLen);
  final view = ByteData.sublistView(out);
  out[0] = 'E'.codeUnitAt(0);
  out[1] = 'X'.codeUnitAt(0);
  out[2] = 'T'.codeUnitAt(0);
  out[3] = 'H'.codeUnitAt(0);
  view.setUint32(4, totalLen);
  view.setUint32(8, records.length);
  var cursor = 12;
  for (final r in records) {
    final (type, data) = r;
    view.setUint32(cursor, type);
    view.setUint32(cursor + 4, 8 + data.length);
    out.setRange(cursor + 8, cursor + 8 + data.length, data);
    cursor += 8 + data.length;
  }
  return out;
}

List<int> _u32(int value) {
  final b = Uint8List(4);
  ByteData.sublistView(b).getUint32(0); // ignore
  ByteData.sublistView(b).setUint32(0, value);
  return b;
}

PdbHeader _stubPdbHeader() => const PdbHeader(
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
    );

PdbFile _wrap(List<Uint8List> records) => PdbFile(
      header: _stubPdbHeader(),
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
  group('FdstTable.parse', () {
    test('decodes section count and (start, end) pairs', () {
      final fdst = FdstTable.parse(_buildFdst([
        (0, 100),
        (100, 250),
        (250, 1000),
      ]));
      expect(fdst.sectionCount, 3);
      expect(fdst.entries[0].start, 0);
      expect(fdst.entries[0].end, 100);
      expect(fdst.entries[1].length, 150);
      expect(fdst.entries[2].end, 1000);
    });

    test('throws on wrong signature', () {
      final bytes = _buildFdst([(0, 10)]);
      bytes[0] = 'X'.codeUnitAt(0);
      expect(
        () => FdstTable.parse(bytes),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when section count exceeds buffer length', () {
      final bytes = _buildFdst([(0, 10)]);
      ByteData.sublistView(bytes).setUint32(8, 999);
      expect(
        () => FdstTable.parse(bytes),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws on too-short buffer', () {
      expect(
        () => FdstTable.parse(_u8([0x46, 0x44, 0x53])),
        throwsA(isA<HeaderException>()),
      );
    });
  });

  group('KindleFile.inspect', () {
    test('reports kf8Only when fileVersion >= 8', () {
      final pdb = _wrap([
        _buildRecord0(fileVersion: 8),
      ]);
      final kf = KindleFile.inspect(pdb);
      expect(kf.format, KindleFormat.kf8Only);
      expect(kf.mobi7, isNull);
      expect(kf.kf8?.recordOffset, 0);
      expect(kf.kf8?.mobi.fileVersion, 8);
    });

    test('reports mobi7Only when version is 6 and EXTH 121 is absent', () {
      final pdb = _wrap([
        _buildRecord0(fileVersion: 6),
        _u8([0x00]),
      ]);
      final kf = KindleFile.inspect(pdb);
      expect(kf.format, KindleFormat.mobi7Only);
      expect(kf.kf8, isNull);
      expect(kf.mobi7?.recordCount, 2);
    });

    test('reports mobi7Only when EXTH 121 is the unset sentinel', () {
      final pdb = _wrap([
        _buildRecord0(fileVersion: 6, exth121: MobiHeader.unset),
        _u8([0x00]),
      ]);
      final kf = KindleFile.inspect(pdb);
      expect(kf.format, KindleFormat.mobi7Only);
    });

    test('reports combo when EXTH 121 + BOUNDARY sentinel + valid record',
        () {
      final boundaryRecord = 'BOUNDARY'.codeUnits;
      // KF8 record 0 needs a valid PalmDOC + MOBI header that parses.
      final kf8R0 = _buildRecord0(fileVersion: 8);
      final pdb = _wrap([
        _buildRecord0(fileVersion: 6, exth121: 3),
        _u8([0xFF]), // record 1 — Mobi-7 text
        _u8(boundaryRecord), // record 2 — boundary sentinel
        kf8R0, // record 3 — KF8 record 0
        _u8([0xFF]), // record 4 — KF8 trailing record
      ]);
      final kf = KindleFile.inspect(pdb);
      expect(kf.format, KindleFormat.combo);
      expect(kf.mobi7?.recordOffset, 0);
      expect(kf.mobi7?.recordCount, 3); // 0..2 inclusive
      expect(kf.kf8?.recordOffset, 3);
      expect(kf.kf8?.recordCount, 2); // 3..4
      expect(kf.kf8?.mobi.fileVersion, 8);
    });

    test('falls back to mobi7Only when BOUNDARY sentinel is missing', () {
      // EXTH 121 says boundary at record 2, but record 1 isn't BOUNDARY —
      // looks like a stale / leftover EXTH 121, not a real combo.
      final pdb = _wrap([
        _buildRecord0(fileVersion: 6, exth121: 2),
        _u8([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11]),
        _buildRecord0(fileVersion: 8),
      ]);
      final kf = KindleFile.inspect(pdb);
      expect(kf.format, KindleFormat.mobi7Only);
    });
  });
}
