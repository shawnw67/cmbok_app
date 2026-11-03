import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

/// Build a synthetic RESC record with the given XML payload.
Uint8List _buildResc(String xml, {String preamble = 'size=8&version=1&type=1'}) {
  final preambleBytes = preamble.codeUnits;
  final xmlBytes = xml.codeUnits;
  final out = Uint8List(16 + preambleBytes.length + xmlBytes.length + 3);
  // Signature.
  out[0] = 'R'.codeUnitAt(0);
  out[1] = 'E'.codeUnitAt(0);
  out[2] = 'S'.codeUnitAt(0);
  out[3] = 'C'.codeUnitAt(0);
  ByteData.sublistView(out)
    ..setUint32(4, 0x10)
    ..setUint32(8, 1)
    ..setUint32(12, preambleBytes.length);
  out.setRange(16, 16 + preambleBytes.length, preambleBytes);
  out.setRange(16 + preambleBytes.length,
      16 + preambleBytes.length + xmlBytes.length, xmlBytes);
  // Trailing 3 nulls (KF8 alignment padding) — already zero from Uint8List.
  return out;
}

/// Build a synthetic FONT record with given payload and flags. The
/// builder XOR-encodes the payload first (when [obfuscated]) and zlib-
/// compresses it (when [compressed]) — the parser must undo both.
Uint8List _buildFont({
  required Uint8List font,
  bool obfuscated = false,
  bool compressed = false,
  Uint8List? xorKey,
}) {
  Uint8List payload = font;
  if (compressed) {
    payload = Uint8List.fromList(ZLibCodec().encode(payload));
  }
  if (obfuscated) {
    if (xorKey == null || xorKey.isEmpty) {
      throw ArgumentError('obfuscated FONT needs a non-empty xorKey');
    }
    final mutable = Uint8List.fromList(payload);
    final extent = mutable.length < 1040 ? mutable.length : 1040;
    for (var i = 0; i < extent; i++) {
      mutable[i] ^= xorKey[i % xorKey.length];
    }
    payload = mutable;
  }

  // 24-byte header + (xorKey?) + payload.
  final keyBytes = xorKey ?? Uint8List(0);
  final dataOffset = 24 + keyBytes.length;
  final out = Uint8List(dataOffset + payload.length);
  out[0] = 'F'.codeUnitAt(0);
  out[1] = 'O'.codeUnitAt(0);
  out[2] = 'N'.codeUnitAt(0);
  out[3] = 'T'.codeUnitAt(0);
  var flags = 0;
  if (compressed) flags |= FontResource.flagZlib;
  if (obfuscated) flags |= FontResource.flagObfuscated;
  ByteData.sublistView(out)
    ..setUint32(4, font.length) // uncompressed size (informational)
    ..setUint32(8, flags)
    ..setUint32(12, dataOffset)
    ..setUint32(16, keyBytes.length)
    ..setUint32(20, 24);
  if (keyBytes.isNotEmpty) {
    out.setRange(24, 24 + keyBytes.length, keyBytes);
  }
  out.setRange(dataOffset, dataOffset + payload.length, payload);
  return out;
}

void main() {
  group('ImageFormat.detect — SVG', () {
    test('recognises a bare <svg> root', () {
      expect(
        ImageFormat.detect(_u8('<svg xmlns="http://w3.org">'.codeUnits)),
        ImageFormat.svg,
      );
    });

    test('recognises XML-declared SVG', () {
      expect(
        ImageFormat.detect(
          _u8('<?xml version="1.0"?><svg width="10"></svg>'.codeUnits),
        ),
        ImageFormat.svg,
      );
    });

    test('case-insensitive on the svg tag', () {
      expect(
        ImageFormat.detect(_u8('<SVG width="10"></SVG>'.codeUnits)),
        ImageFormat.svg,
      );
    });

    test('does NOT match plain XML without an <svg> tag', () {
      expect(
        ImageFormat.detect(
          _u8('<?xml version="1.0"?><metadata></metadata>'.codeUnits),
        ),
        isNull,
      );
    });
  });

  group('RescResource.parse', () {
    test('extracts the XML payload, trimming trailing nulls', () {
      const xml = '<package><manifest></manifest></package>';
      final resc = RescResource.parse(_buildResc(xml));
      expect(resc.xml, xml);
    });

    test('throws on wrong signature', () {
      final bytes = _buildResc('<x/>');
      bytes[0] = 'X'.codeUnitAt(0);
      expect(
        () => RescResource.parse(bytes),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when no `<` is found in the payload', () {
      final out = Uint8List(20);
      out[0] = 'R'.codeUnitAt(0);
      out[1] = 'E'.codeUnitAt(0);
      out[2] = 'S'.codeUnitAt(0);
      out[3] = 'C'.codeUnitAt(0);
      expect(
        () => RescResource.parse(out),
        throwsA(isA<HeaderException>()),
      );
    });
  });

  group('FontResource.parse', () {
    test('passes through a plain TTF payload', () {
      final ttf = _u8([0x00, 0x01, 0x00, 0x00, ...List.filled(100, 0xAA)]);
      final font = FontResource.parse(_buildFont(font: ttf));
      expect(font.format, FontFormat.ttf);
      expect(font.payload, ttf);
      expect(font.hasXor, isFalse);
      expect(font.hasZlib, isFalse);
    });

    test('deobfuscates XOR-mangled payloads', () {
      final otf = _u8(<int>[
        ...'OTTO'.codeUnits,
        ...List.generate(2000, (i) => i & 0xFF),
      ]);
      final key = _u8([0xDE, 0xAD, 0xBE, 0xEF, 0x42]);
      final font = FontResource.parse(
        _buildFont(font: otf, obfuscated: true, xorKey: key),
      );
      expect(font.format, FontFormat.otf);
      expect(font.payload, otf,
          reason: 'XOR deobfuscation should recover the original bytes');
      expect(font.hasXor, isTrue);
    });

    test('decompresses zlib-flagged payloads', () {
      final ttf = _u8([0x00, 0x01, 0x00, 0x00, ...List.filled(500, 0x55)]);
      final font = FontResource.parse(_buildFont(font: ttf, compressed: true));
      expect(font.format, FontFormat.ttf);
      expect(font.payload, ttf);
      expect(font.hasZlib, isTrue);
    });

    test('handles XOR + zlib together', () {
      final ttf = _u8([
        ...'true'.codeUnits,
        ...List.generate(1500, (i) => (i * 7) & 0xFF),
      ]);
      final key = _u8([0x12, 0x34, 0x56, 0x78]);
      final font = FontResource.parse(
        _buildFont(
          font: ttf,
          obfuscated: true,
          compressed: true,
          xorKey: key,
        ),
      );
      // Builder applies zlib first then XOR; parser undoes XOR then zlib.
      expect(font.format, FontFormat.ttf);
      expect(font.payload, ttf);
    });

    test('reports unknown format on unrecognised header', () {
      final junk = _u8([0xAB, 0xCD, 0xEF, 0x12, ...List.filled(50, 0)]);
      final font = FontResource.parse(_buildFont(font: junk));
      expect(font.format, FontFormat.unknown);
    });

    test('throws when obfuscated flag set but key length is 0', () {
      // Build an obfuscated record with a stub key, then zero out the
      // declared key length.
      final stub = _u8([0x00, 0x01, 0x00, 0x00]);
      final bytes = _buildFont(
        font: stub,
        obfuscated: true,
        xorKey: _u8([0xFF]),
      );
      ByteData.sublistView(bytes).setUint32(16, 0);
      expect(
        () => FontResource.parse(bytes),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws on wrong signature', () {
      final bytes = _buildFont(font: _u8([0x00, 0x01, 0x00, 0x00, 0x00]));
      bytes[0] = 'X'.codeUnitAt(0);
      expect(
        () => FontResource.parse(bytes),
        throwsA(isA<HeaderException>()),
      );
    });
  });
}
