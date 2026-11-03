import 'dart:convert';
import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

/// Builds a self-contained EXTH header buffer holding [records]. Each
/// record is (type, data). Returned bytes start at offset 0 with the
/// EXTH signature.
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

/// Encodes a uint32 in 4 big-endian bytes, the on-disk layout for numeric
/// EXTH records like [ExthType.coverOffset].
List<int> _u32(int value) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, value);
  return b;
}

void main() {
  group('ExthHeader.parse', () {
    test('decodes a single string record', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Jane Doe')),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);

      expect(exth.records, hasLength(1));
      expect(exth.records[0].type, ExthType.author);
      expect(exth.stringValue(ExthType.author), 'Jane Doe');
      expect(exth.authors, ['Jane Doe']);
    });

    test('groups repeated types in declaration order', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
        (ExthType.author, utf8.encode('Bob')),
        (ExthType.subject, utf8.encode('Fiction')),
        (ExthType.subject, utf8.encode('Fantasy')),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);

      expect(exth.authors, ['Alice', 'Bob']);
      expect(exth.subjects, ['Fiction', 'Fantasy']);
      expect(exth.byType[ExthType.author], hasLength(2));
    });

    test('decodes string with UTF-8 when textEncoding is 65001', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Café Crème')),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);
      expect(exth.stringValue(ExthType.author), 'Café Crème');
    });

    test('decodes string with latin1 when textEncoding is 1252', () {
      final bytes = _buildExth([
        (ExthType.author, latin1.encode('Plain ASCII')),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 1252);
      expect(exth.stringValue(ExthType.author), 'Plain ASCII');
    });

    test('decodes uint32 records', () {
      final bytes = _buildExth([
        (ExthType.coverOffset, _u32(7)),
        (ExthType.thumbnailOffset, _u32(8)),
        (ExthType.kf8BoundaryRecord, _u32(123)),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);
      expect(exth.coverOffset, 7);
      expect(exth.thumbnailOffset, 8);
      expect(exth.kf8BoundaryRecord, 123);
    });

    test('uint32Value returns null when record is not exactly 4 bytes', () {
      final bytes = _buildExth([
        (ExthType.coverOffset, [1, 2, 3]), // wrong length
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);
      expect(exth.uint32Value(ExthType.coverOffset), isNull);
      // Raw bytes are still accessible.
      expect(exth.rawValue(ExthType.coverOffset), [1, 2, 3]);
    });

    test('asin falls back to type 504 when 113 is absent', () {
      final bytesWith113 = _buildExth([
        (ExthType.asin, utf8.encode('B00ABC1234')),
      ]);
      final bytesWith504 = _buildExth([
        (ExthType.asinAlt, utf8.encode('B00DEF5678')),
      ]);
      expect(
        ExthHeader.parse(bytesWith113, offset: 0, textEncoding: 65001).asin,
        'B00ABC1234',
      );
      expect(
        ExthHeader.parse(bytesWith504, offset: 0, textEncoding: 65001).asin,
        'B00DEF5678',
      );
    });

    test('preserves unknown record types in raw lookups', () {
      const customType = 9999;
      final bytes = _buildExth([
        (customType, [0xDE, 0xAD, 0xBE, 0xEF]),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);
      expect(exth.rawValue(customType), [0xDE, 0xAD, 0xBE, 0xEF]);
      expect(exth.byType[customType], hasLength(1));
    });

    test('returns empty / null for absent types', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);
      expect(exth.publisher, isNull);
      expect(exth.subjects, isEmpty);
      expect(exth.rawValue(ExthType.coverOffset), isNull);
      expect(exth.rawValues(ExthType.coverOffset), isEmpty);
    });

    test('parses EXTH at non-zero offset within record 0', () {
      final exth = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      // Embed the EXTH after some MOBI-header-like padding.
      final r0 = Uint8List(20 + exth.length)
        ..setRange(20, 20 + exth.length, exth);
      final parsed =
          ExthHeader.parse(r0, offset: 20, textEncoding: 65001);
      expect(parsed.authors, ['Alice']);
    });

    test('record data is a view over the input buffer', () {
      final bytes = _buildExth([
        (ExthType.author, [1, 2, 3, 4]),
      ]);
      final exth = ExthHeader.parse(bytes, offset: 0, textEncoding: 65001);
      // Find the record's payload offset and mutate the source buffer.
      final record = exth.records.single;
      record.data; // grab reference
      // Record header is at offset 12; payload starts at offset 20.
      bytes[20] = 99;
      expect(exth.rawValue(ExthType.author)![0], 99);
    });
  });

  group('ExthHeader.parse — error handling', () {
    test('throws on wrong signature', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      bytes[0] = 'X'.codeUnitAt(0);
      expect(
        () => ExthHeader.parse(bytes, offset: 0, textEncoding: 65001),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when header length is below the 12-byte minimum', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      ByteData.sublistView(bytes).setUint32(4, 8);
      expect(
        () => ExthHeader.parse(bytes, offset: 0, textEncoding: 65001),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when declared header length runs past the buffer', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      ByteData.sublistView(bytes).setUint32(4, bytes.length + 100);
      expect(
        () => ExthHeader.parse(bytes, offset: 0, textEncoding: 65001),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when a record length is below the 8-byte minimum', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      // First record's length field sits at offset 12 + 4.
      ByteData.sublistView(bytes).setUint32(16, 4);
      expect(
        () => ExthHeader.parse(bytes, offset: 0, textEncoding: 65001),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when a record runs past the EXTH end', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      // Inflate the first record's length so it would extend past EXTH end.
      ByteData.sublistView(bytes).setUint32(16, bytes.length);
      expect(
        () => ExthHeader.parse(bytes, offset: 0, textEncoding: 65001),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when the declared record count exceeds the body', () {
      final bytes = _buildExth([
        (ExthType.author, utf8.encode('Alice')),
      ]);
      ByteData.sublistView(bytes).setUint32(8, 5); // claim 5 records
      expect(
        () => ExthHeader.parse(bytes, offset: 0, textEncoding: 65001),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when offset is past the buffer', () {
      final bytes = Uint8List(20);
      expect(
        () => ExthHeader.parse(bytes, offset: 100, textEncoding: 65001),
        throwsA(isA<HeaderException>()),
      );
    });
  });
}
