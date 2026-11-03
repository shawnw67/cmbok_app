import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

/// Builds a synthetic PDB byte sequence with `records` as the record payloads.
/// Header fields are filled in with recognisable values so tests can assert on
/// them.
Uint8List _buildPdb({
  String name = 'test_book',
  String type = 'BOOK',
  String creator = 'MOBI',
  int attributes = 0x0001,
  int version = 0x0002,
  int creationDate = 0x12345678,
  int modificationDate = 0x23456789,
  int lastBackupDate = 0x3456789A,
  int modificationNumber = 0x00000007,
  int appInfoId = 0x00000000,
  int sortInfoId = 0x00000000,
  int uniqueIdSeed = 0x000000FF,
  required List<List<int>> records,
  List<int>? recordAttributes,
  List<int>? recordUniqueIds,
}) {
  const headerSize = 78;
  const entrySize = 8;
  final recordCount = records.length;
  final recordListEnd = headerSize + recordCount * entrySize;
  // 2-byte gap is conventional; not strictly required, but real files have it.
  const gap = 2;

  final offsets = <int>[];
  var cursor = recordListEnd + gap;
  for (final r in records) {
    offsets.add(cursor);
    cursor += r.length;
  }
  final totalSize = cursor;

  final out = Uint8List(totalSize);
  final view = ByteData.sublistView(out);

  // Name (32 bytes, null-padded latin1).
  final nameBytes = name.codeUnits;
  for (var i = 0; i < nameBytes.length && i < 32; i++) {
    out[i] = nameBytes[i];
  }
  view.setUint16(32, attributes);
  view.setUint16(34, version);
  view.setUint32(36, creationDate);
  view.setUint32(40, modificationDate);
  view.setUint32(44, lastBackupDate);
  view.setUint32(48, modificationNumber);
  view.setUint32(52, appInfoId);
  view.setUint32(56, sortInfoId);
  for (var i = 0; i < 4; i++) {
    out[60 + i] = type.codeUnits[i];
    out[64 + i] = creator.codeUnits[i];
  }
  view.setUint32(68, uniqueIdSeed);
  view.setUint32(72, 0); // nextRecordListID
  view.setUint16(76, recordCount);

  for (var i = 0; i < recordCount; i++) {
    final base = headerSize + i * entrySize;
    view.setUint32(base, offsets[i]);
    out[base + 4] = recordAttributes?[i] ?? 0;
    final uid = recordUniqueIds?[i] ?? (i + 1);
    out[base + 5] = (uid >> 16) & 0xFF;
    out[base + 6] = (uid >> 8) & 0xFF;
    out[base + 7] = uid & 0xFF;
  }

  for (var i = 0; i < recordCount; i++) {
    out.setRange(offsets[i], offsets[i] + records[i].length, records[i]);
  }

  return out;
}

void main() {
  group('PdbFile.parse — header', () {
    test('decodes basic header fields', () {
      final bytes = _buildPdb(records: [
        [1, 2, 3]
      ]);
      final pdb = PdbFile.parse(bytes);

      expect(pdb.header.name, 'test_book');
      expect(pdb.header.type, 'BOOK');
      expect(pdb.header.creator, 'MOBI');
      expect(pdb.header.attributes, 0x0001);
      expect(pdb.header.version, 0x0002);
      expect(pdb.header.creationDate, 0x12345678);
      expect(pdb.header.modificationDate, 0x23456789);
      expect(pdb.header.lastBackupDate, 0x3456789A);
      expect(pdb.header.modificationNumber, 7);
      expect(pdb.header.uniqueIdSeed, 0xFF);
      expect(pdb.header.recordCount, 1);
    });

    test('null-terminates the database name correctly', () {
      final bytes = _buildPdb(name: 'short', records: [
        [0]
      ]);
      final pdb = PdbFile.parse(bytes);
      expect(pdb.header.name, 'short');
    });

    test('uses full 32 bytes when name has no null terminator', () {
      final longName = 'A' * 32;
      final bytes = _buildPdb(name: longName, records: [
        [0]
      ]);
      final pdb = PdbFile.parse(bytes);
      expect(pdb.header.name, longName);
    });
  });

  group('PdbFile.parse — records', () {
    test('returns empty record list when recordCount is 0', () {
      final bytes = _buildPdb(records: []);
      final pdb = PdbFile.parse(bytes);
      expect(pdb.records, isEmpty);
      expect(pdb.header.recordCount, 0);
    });

    test('slices a single record correctly', () {
      final payload = [10, 20, 30, 40, 50];
      final bytes = _buildPdb(records: [payload]);
      final pdb = PdbFile.parse(bytes);

      expect(pdb.records, hasLength(1));
      expect(pdb.records[0].data, equals(payload));
      expect(pdb.records[0].length, 5);
    });

    test('slices multiple records and preserves order', () {
      final r0 = List<int>.generate(16, (i) => i);
      final r1 = List<int>.generate(8, (i) => 100 + i);
      final r2 = List<int>.generate(4, (i) => 200 + i);
      final bytes = _buildPdb(records: [r0, r1, r2]);
      final pdb = PdbFile.parse(bytes);

      expect(pdb.records, hasLength(3));
      expect(pdb.records[0].data, equals(r0));
      expect(pdb.records[1].data, equals(r1));
      expect(pdb.records[2].data, equals(r2));
    });

    test('decodes 24-bit unique IDs', () {
      final bytes = _buildPdb(
        records: [
          [1],
          [2],
        ],
        recordUniqueIds: [0xABCDEF, 0x000042],
      );
      final pdb = PdbFile.parse(bytes);

      expect(pdb.records[0].uniqueId, 0xABCDEF);
      expect(pdb.records[1].uniqueId, 0x42);
    });

    test('decodes per-record attributes', () {
      final bytes = _buildPdb(
        records: [
          [1],
          [2],
        ],
        recordAttributes: [0x40, 0x80],
      );
      final pdb = PdbFile.parse(bytes);

      expect(pdb.records[0].attributes, 0x40);
      expect(pdb.records[1].attributes, 0x80);
    });

    test('record offsets reflect position in original file', () {
      final bytes = _buildPdb(records: [
        [1, 2],
        [3, 4, 5],
      ]);
      final pdb = PdbFile.parse(bytes);
      // First record sits past header (78) + 2 entries * 8 + 2-byte gap = 96.
      expect(pdb.records[0].offset, 96);
      expect(pdb.records[1].offset, 98);
    });

    test('record data shares the input buffer (view, not copy)', () {
      final bytes = _buildPdb(records: [
        [1, 2, 3]
      ]);
      final pdb = PdbFile.parse(bytes);
      final record = pdb.records[0];
      // Mutating the input buffer is visible through the view.
      bytes[record.offset] = 99;
      expect(record.data[0], 99);
    });
  });

  group('PdbFile.parse — error handling', () {
    test('throws when buffer is shorter than header', () {
      expect(
        () => PdbFile.parse(Uint8List(40)),
        throwsA(isA<PdbException>()),
      );
    });

    test('throws when record list is truncated', () {
      // Header advertises 5 records but file isn't long enough for the list.
      final bytes = Uint8List(78);
      ByteData.sublistView(bytes).setUint16(76, 5);
      expect(
        () => PdbFile.parse(bytes),
        throwsA(isA<PdbException>()),
      );
    });

    test('throws when a record offset points past EOF', () {
      final bytes = _buildPdb(records: [
        [1, 2, 3]
      ]);
      // Corrupt the first (and only) record offset to a value past EOF.
      ByteData.sublistView(bytes).setUint32(78, bytes.length + 100);
      expect(
        () => PdbFile.parse(bytes),
        throwsA(isA<PdbException>()),
      );
    });

    test('throws when a record offset lies inside the record-list area', () {
      final bytes = _buildPdb(records: [
        [1, 2, 3]
      ]);
      ByteData.sublistView(bytes).setUint32(78, 80);
      expect(
        () => PdbFile.parse(bytes),
        throwsA(isA<PdbException>()),
      );
    });

    test('throws when offsets are not monotonically increasing', () {
      final bytes = _buildPdb(records: [
        [1, 2, 3, 4],
        [5, 6, 7, 8],
      ]);
      // Swap the two offsets so record 1 < record 0.
      final view = ByteData.sublistView(bytes);
      final off0 = view.getUint32(78);
      final off1 = view.getUint32(78 + 8);
      view.setUint32(78, off1);
      view.setUint32(78 + 8, off0);
      expect(
        () => PdbFile.parse(bytes),
        throwsA(isA<PdbException>()),
      );
    });
  });
}
