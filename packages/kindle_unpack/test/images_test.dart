import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

const _jpegMagic = [0xFF, 0xD8, 0xFF, 0xE0];
const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const _gifMagic87 = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61];
const _gifMagic89 = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
const _bmpMagic = [0x42, 0x4D, 0x36, 0x00];

PdbHeader _stubHeader() => const PdbHeader(
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

PdbFile _pdb(List<List<int>> records) => PdbFile(
      header: _stubHeader(),
      records: records
          .map((r) => PdbRecord(
                offset: 0,
                attributes: 0,
                uniqueId: 0,
                data: _u8(r),
              ))
          .toList(growable: false),
    );

MobiHeader _mobi({required int firstImageIndex}) => MobiHeader(
      headerLength: 232,
      mobiType: 2,
      textEncoding: 65001,
      uniqueId: 0,
      fileVersion: 6,
      firstNonBookIndex: MobiHeader.unset,
      fullNameOffset: 0,
      fullNameLength: 0,
      locale: 0,
      inputLanguage: 0,
      outputLanguage: 0,
      minVersion: 0,
      firstImageIndex: firstImageIndex,
      huffmanRecordOffset: 0,
      huffmanRecordCount: 0,
      huffmanTableOffset: 0,
      huffmanTableLength: 0,
      exthFlags: 0,
      drmOffset: MobiHeader.unset,
      drmCount: MobiHeader.unset,
      drmSize: 0,
      drmFlags: 0,
      fdstRecord: null,
      fdstFlowCount: null,
      fragmentIndex: null,
      skeletonIndex: null,
      extraDataFlags: 0,
    );

void main() {
  group('ImageFormat.detect', () {
    test('recognises JPEG', () {
      expect(ImageFormat.detect(_u8(_jpegMagic)), ImageFormat.jpeg);
    });

    test('recognises PNG', () {
      expect(ImageFormat.detect(_u8(_pngMagic)), ImageFormat.png);
    });

    test('recognises both GIF87a and GIF89a variants', () {
      expect(ImageFormat.detect(_u8(_gifMagic87)), ImageFormat.gif);
      expect(ImageFormat.detect(_u8(_gifMagic89)), ImageFormat.gif);
    });

    test('recognises BMP', () {
      expect(ImageFormat.detect(_u8(_bmpMagic)), ImageFormat.bmp);
    });

    test('returns null for unknown magic', () {
      expect(ImageFormat.detect(_u8([0, 0, 0, 0])), isNull);
      expect(ImageFormat.detect(_u8('FONT'.codeUnits)), isNull);
    });

    test('returns null when buffer is shorter than the magic', () {
      expect(ImageFormat.detect(_u8([0xFF, 0xD8])), isNull);
    });
  });

  group('ExtractedImage.name', () {
    test('uses zero-padded 5-digit block index', () {
      final img = ExtractedImage(
        blockIndex: 7,
        recordIndex: 100,
        format: ImageFormat.jpeg,
        data: _emptyBytes,
      );
      expect(img.name, 'image00007.jpg');
    });

    test('uses correct extension per format', () {
      expect(
        ExtractedImage(
          blockIndex: 0,
          recordIndex: 0,
          format: ImageFormat.png,
          data: _emptyBytes,
        ).name,
        'image00000.png',
      );
    });
  });

  group('BookImages.extract', () {
    test('returns empty when firstImageIndex is unset', () {
      final result = BookImages.extract(
        pdb: _pdb([
          [0],
          _jpegMagic,
        ]),
        mobi: _mobi(firstImageIndex: MobiHeader.unset),
      );
      expect(result.all, isEmpty);
    });

    test('returns empty when firstImageIndex is 0 (sentinel)', () {
      final result = BookImages.extract(
        pdb: _pdb([
          _jpegMagic,
        ]),
        mobi: _mobi(firstImageIndex: 0),
      );
      expect(result.all, isEmpty);
    });

    test('returns empty when firstImageIndex is past end of PDB', () {
      final result = BookImages.extract(
        pdb: _pdb([
          [0],
          [0],
        ]),
        mobi: _mobi(firstImageIndex: 50),
      );
      expect(result.all, isEmpty);
    });

    test('extracts every recognised image record', () {
      final result = BookImages.extract(
        pdb: _pdb([
          [0], // record 0
          [0], // record 1 (text, not an image — but firstImageIndex is past it)
          _jpegMagic, // record 2
          _pngMagic, // record 3
          _gifMagic89, // record 4
        ]),
        mobi: _mobi(firstImageIndex: 2),
      );
      expect(result.all, hasLength(3));
      expect(result.all[0].format, ImageFormat.jpeg);
      expect(result.all[1].format, ImageFormat.png);
      expect(result.all[2].format, ImageFormat.gif);
      expect(result.all[0].blockIndex, 0);
      expect(result.all[1].blockIndex, 1);
      expect(result.all[2].blockIndex, 2);
    });

    test('skips unrecognised records but preserves block-index numbering', () {
      // Record 3 is FONT — not an image, must not consume a slot for the
      // block index but EXTH cover offsets are absolute within the block.
      final result = BookImages.extract(
        pdb: _pdb([
          [0],
          _jpegMagic, // record 1, blockIndex 0
          'FONT'.codeUnits, // record 2, skipped
          _pngMagic, // record 3, blockIndex 2
        ]),
        mobi: _mobi(firstImageIndex: 1),
      );
      expect(result.all, hasLength(2));
      expect(result.all[0].blockIndex, 0);
      expect(result.all[1].blockIndex, 2);
    });

    test('cover/thumbnail are resolved via EXTH', () {
      final exthBytes = _buildExth([
        (ExthType.coverOffset, _u32(2)),
        (ExthType.thumbnailOffset, _u32(0)),
      ]);
      final exth =
          ExthHeader.parse(exthBytes, offset: 0, textEncoding: 65001);
      final result = BookImages.extract(
        pdb: _pdb([
          [0],
          _jpegMagic, // blockIndex 0 → thumbnail
          _pngMagic, // blockIndex 1
          _gifMagic89, // blockIndex 2 → cover
        ]),
        mobi: _mobi(firstImageIndex: 1),
        exth: exth,
      );
      expect(result.cover?.format, ImageFormat.gif);
      expect(result.thumbnail?.format, ImageFormat.jpeg);
    });

    test('cover is null when EXTH offset points at a non-image record', () {
      final exthBytes = _buildExth([
        (ExthType.coverOffset, _u32(0)),
      ]);
      final exth =
          ExthHeader.parse(exthBytes, offset: 0, textEncoding: 65001);
      final result = BookImages.extract(
        pdb: _pdb([
          [0],
          'FONT'.codeUnits, // not an image
        ]),
        mobi: _mobi(firstImageIndex: 1),
        exth: exth,
      );
      expect(result.cover, isNull);
      expect(result.coverBlockIndex, 0);
    });

    test('toMap uses generated names', () {
      final result = BookImages.extract(
        pdb: _pdb([
          [0],
          _jpegMagic,
          _pngMagic,
        ]),
        mobi: _mobi(firstImageIndex: 1),
      );
      expect(result.toMap().keys, ['image00000.jpg', 'image00001.png']);
    });
  });
}

/// Helper: build an EXTH buffer holding [records] for tests that need
/// cover/thumbnail metadata.
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
  ByteData.sublistView(b).setUint32(0, value);
  return b;
}

final Uint8List _emptyBytes = Uint8List(0);
