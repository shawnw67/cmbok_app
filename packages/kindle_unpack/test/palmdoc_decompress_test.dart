import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

/// Encode a back-reference opcode (2 bytes) for the given distance and
/// post-decode length. `distance` ∈ [1, 2047], `length` ∈ [3, 10].
List<int> _backRef(int distance, int length) {
  assert(distance >= 1 && distance <= 2047);
  assert(length >= 3 && length <= 10);
  final combined = (distance << 3) | (length - 3);
  return [0x80 | (combined >> 8), combined & 0xFF];
}

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  group('decompressPalmDoc — opcodes', () {
    test('empty input produces empty output', () {
      expect(decompressPalmDoc(Uint8List(0)), isEmpty);
    });

    test('emits 0x00 byte literally', () {
      expect(decompressPalmDoc(_u8([0x00])), [0x00]);
    });

    test('emits 0x09..0x7F as plain literal characters', () {
      expect(decompressPalmDoc(_u8([0x09, 0x41, 0x7F])), [0x09, 0x41, 0x7F]);
    });

    test('0x01..0x08 introduces a literal run of N bytes', () {
      // 0x03 means "next 3 bytes verbatim". 0x80 inside the run is data,
      // not a back-ref start.
      expect(
        decompressPalmDoc(_u8([0x03, 0x80, 0x9F, 0xC0])),
        [0x80, 0x9F, 0xC0],
      );
    });

    test('0xC0..0xFF emits a space + (byte XOR 0x80)', () {
      // 0xC1 → " A", 0xE1 → " a", 0xFF → " " + 0x7F.
      expect(decompressPalmDoc(_u8([0xC1])), [0x20, 0x41]);
      expect(decompressPalmDoc(_u8([0xE1])), [0x20, 0x61]);
      expect(decompressPalmDoc(_u8([0xFF])), [0x20, 0x7F]);
    });
  });

  group('decompressPalmDoc — back-references', () {
    test('copies a previously-emitted block', () {
      // "abc" then back-ref distance=3 length=3 → "abcabc".
      final input = _u8([0x61, 0x62, 0x63, ..._backRef(3, 3)]);
      expect(decompressPalmDoc(input), [0x61, 0x62, 0x63, 0x61, 0x62, 0x63]);
    });

    test('run-length pattern when distance < length', () {
      // 'A' then back-ref distance=1 length=5 → "AAAAAA".
      final input = _u8([0x41, ..._backRef(1, 5)]);
      expect(decompressPalmDoc(input), List.filled(6, 0x41));
    });

    test('handles maximum distance (2047) and length (10)', () {
      // Emit 2047 'X' bytes in chunks of 8 via literal-runs, then a
      // max-distance back-ref (distance 2047, length 10) that copies the
      // first 10 'X's into positions 2047..2056.
      final compressedFill = <int>[];
      for (var written = 0; written < 2047;) {
        final chunk = (2047 - written).clamp(1, 8);
        compressedFill
          ..add(chunk)
          ..addAll(List<int>.filled(chunk, 0x58));
        written += chunk;
      }
      final input = _u8([...compressedFill, ..._backRef(2047, 10)]);
      final out = decompressPalmDoc(input);
      expect(out.length, 2047 + 10);
      expect(out, List<int>.filled(2057, 0x58));
    });
  });

  group('decompressPalmDoc — error handling', () {
    test('throws when literal run extends past input', () {
      expect(
        () => decompressPalmDoc(_u8([0x05, 0x41, 0x42])),
        throwsA(isA<PalmDocDecompressException>()),
      );
    });

    test('throws when back-reference is missing its low byte', () {
      expect(
        () => decompressPalmDoc(_u8([0x80])),
        throwsA(isA<PalmDocDecompressException>()),
      );
    });

    test('throws when back-reference distance is 0', () {
      // combined = 0 → distance 0, length 3.
      expect(
        () => decompressPalmDoc(_u8([0x80, 0x00])),
        throwsA(isA<PalmDocDecompressException>()),
      );
    });

    test('throws when back-reference reads before start of output', () {
      // Output is empty when the back-ref runs.
      expect(
        () => decompressPalmDoc(_u8(_backRef(5, 3))),
        throwsA(isA<PalmDocDecompressException>()),
      );
    });
  });

  group('stripTrailingDataEntries', () {
    test('flag 0 is a no-op', () {
      final record = _u8([1, 2, 3, 4, 5]);
      expect(stripTrailingDataEntries(record, 0), equals([1, 2, 3, 4, 5]));
    });

    test('strips a single bit-1 trailer with 1-byte var-int', () {
      // 3 content bytes + 3 trailer-data bytes + 1 var-int byte (= 0x84,
      // encodes total trailer length 4).
      final record =
          _u8([0x41, 0x42, 0x43, 0xAA, 0xBB, 0xCC, 0x84]);
      expect(stripTrailingDataEntries(record, 0x2), equals([0x41, 0x42, 0x43]));
    });

    test('strips a multi-byte var-int trailer', () {
      // Trailer of length 128: 126 bytes of data + 2-byte var-int.
      // var-int encoding of 128 (backward read): bytes [0x81, 0x00].
      // So trailer in record order: [126 bytes, 0x81, 0x00]. Total 128.
      final content = List<int>.filled(10, 0x41); // 10 'A's
      final trailerData = List<int>.filled(126, 0xAA);
      final varInt = [0x81, 0x00];
      final record = _u8([...content, ...trailerData, ...varInt]);
      expect(stripTrailingDataEntries(record, 0x2), equals(content));
    });

    test('flag 1 strips the multibyte-overlap indicator + overlap bytes', () {
      // Indicator 0x01: low 2 bits = 1 → strip 2 bytes (indicator +
      // 1 overlap byte from the end).
      final record = _u8([0x41, 0x42, 0x43, 0xFF, 0x01]);
      expect(stripTrailingDataEntries(record, 0x1), equals([0x41, 0x42, 0x43]));
    });

    test('flags 0x3 strips a trailer first, then the overlap indicator', () {
      // Layout: content (3) | overlap_byte (1) | indicator (0x01) |
      //         trailer_data (3) | var-int (0x84, total trailer = 4).
      final record = _u8([
        0x41, 0x42, 0x43, // content
        0xFF, 0x01, // overlap byte + indicator (overlap=1 → strip 2 bytes)
        0xAA, 0xBB, 0xCC, 0x84, // trailer 4 bytes
      ]);
      expect(stripTrailingDataEntries(record, 0x3), equals([0x41, 0x42, 0x43]));
    });

    test('empty record with flag 1 yields 0 instead of throwing', () {
      // Regression: a zero-length text record (common as the last record)
      // used to make the multibyte-overlap branch index at -1 and throw,
      // which failed the entire book decompression.
      final record = _u8([]);
      expect(sizeOfTrailingDataEntries(record, 0x1), equals(0));
      expect(stripTrailingDataEntries(record, 0x1), isEmpty);
      // Same for combined flags.
      expect(stripTrailingDataEntries(record, 0x3), isEmpty);
    });

    test('throws when computed strip size exceeds record length', () {
      // var-int encodes 99, but the record only has 4 bytes.
      final record = _u8([0xE3, 0xAA, 0xBB, 0xCC]); // 0xE3 = 0x80 | 0x63 = 99
      expect(
        () => stripTrailingDataEntries(record, 0x2),
        throwsA(isA<HeaderException>()),
      );
    });
  });

  group('decompressBookText', () {
    /// Wraps a list of records into a synthetic [PdbFile] without going
    /// through the PDB parser.
    PdbFile makePdb(List<List<int>> records) {
      final wrapped = records
          .map((r) => PdbRecord(
                offset: 0,
                attributes: 0,
                uniqueId: 0,
                data: _u8(r),
              ))
          .toList(growable: false);
      return PdbFile(
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
        records: wrapped,
      );
    }

    /// A barebones MobiHeader instance for tests — only fields the
    /// assembler reads matter.
    MobiHeader mobi({
      int extraDataFlags = 0,
      int drmOffset = MobiHeader.unset,
      int drmCount = MobiHeader.unset,
    }) =>
        MobiHeader(
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
          firstImageIndex: MobiHeader.unset,
          huffmanRecordOffset: 0,
          huffmanRecordCount: 0,
          huffmanTableOffset: 0,
          huffmanTableLength: 0,
          exthFlags: 0,
          drmOffset: drmOffset,
          drmCount: drmCount,
          drmSize: 0,
          drmFlags: 0,
          fdstRecord: null,
          fdstFlowCount: null,
          fragmentIndex: null,
          skeletonIndex: null,
          extraDataFlags: extraDataFlags,
        );

    PalmDocHeader palmDoc({
      CompressionType compression = CompressionType.palmDoc,
      EncryptionType encryption = EncryptionType.none,
      int textRecordCount = 1,
    }) =>
        PalmDocHeader(
          compression: compression,
          textLength: 0,
          textRecordCount: textRecordCount,
          maxRecordSize: 4096,
          encryption: encryption,
        );

    test('passes through uncompressed text records', () {
      final pdb = makePdb([
        [0x00], // record 0 placeholder
        [0x41, 0x42, 0x43],
        [0x44, 0x45],
      ]);
      final out = decompressBookText(
        pdb: pdb,
        palmDoc: palmDoc(
          compression: CompressionType.none,
          textRecordCount: 2,
        ),
        mobi: mobi(),
      );
      expect(out, [0x41, 0x42, 0x43, 0x44, 0x45]);
    });

    test('decompresses + concatenates PalmDOC records', () {
      // Record 1: "abc" + back-ref(3,3) → "abcabc"
      // Record 2: "Z" + back-ref(1,5) → "ZZZZZZ"
      final pdb = makePdb([
        [0x00],
        [0x61, 0x62, 0x63, ..._backRef(3, 3)],
        [0x5A, ..._backRef(1, 5)],
      ]);
      final out = decompressBookText(
        pdb: pdb,
        palmDoc: palmDoc(textRecordCount: 2),
        mobi: mobi(),
      );
      expect(
        out,
        [
          0x61, 0x62, 0x63, 0x61, 0x62, 0x63, // record 1
          ...List.filled(6, 0x5A), // record 2
        ],
      );
    });

    test('strips trailing data before decompressing', () {
      // Record 1 = compressed "abc" + 4-byte trailer.
      final compressed = [0x61, 0x62, 0x63];
      final trailer = [0xAA, 0xBB, 0xCC, 0x84]; // total 4
      final pdb = makePdb([
        [0x00],
        [...compressed, ...trailer],
      ]);
      final out = decompressBookText(
        pdb: pdb,
        palmDoc: palmDoc(
          compression: CompressionType.none,
          textRecordCount: 1,
        ),
        mobi: mobi(extraDataFlags: 0x2),
      );
      expect(out, [0x61, 0x62, 0x63]);
    });

    test('throws on encrypted file (PalmDOC encryption flag)', () {
      final pdb = makePdb([
        [0x00],
        [0x41],
      ]);
      expect(
        () => decompressBookText(
          pdb: pdb,
          palmDoc: palmDoc(encryption: EncryptionType.mobipocket),
          mobi: mobi(),
        ),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws on DRM (MOBI header DRM count > 0)', () {
      final pdb = makePdb([
        [0x00],
        [0x41],
      ]);
      expect(
        () => decompressBookText(
          pdb: pdb,
          palmDoc: palmDoc(),
          mobi: mobi(drmOffset: 0x1000, drmCount: 5),
        ),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws on HUFF/CDIC when MOBI advertises no HUFF records', () {
      final pdb = makePdb([
        [0x00],
        [0x41],
      ]);
      expect(
        () => decompressBookText(
          pdb: pdb,
          palmDoc: palmDoc(compression: CompressionType.huffCdic),
          mobi: mobi(),
        ),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when textRecordCount exceeds available PDB records', () {
      final pdb = makePdb([
        [0x00],
        [0x41],
      ]);
      expect(
        () => decompressBookText(
          pdb: pdb,
          palmDoc: palmDoc(textRecordCount: 5),
          mobi: mobi(),
        ),
        throwsA(isA<HeaderException>()),
      );
    });
  });
}
