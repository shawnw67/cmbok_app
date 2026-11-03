import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

Uint8List _u8(List<int> b) => Uint8List.fromList(b);

void main() {
  group('EpubBuilder.build', () {
    const metadata = EpubMetadata(
      identifier: 'urn:test:1',
      title: 'Sample',
      language: 'en',
      creators: ['Tester'],
    );
    final parts = [
      XhtmlPart(fileNumber: 0, bytes: _u8('<html>hi</html>'.codeUnits)),
      XhtmlPart(fileNumber: 1, bytes: _u8('<html>bye</html>'.codeUnits)),
    ];

    test('produces a non-empty EPUB zip', () {
      final epub = EpubBuilder.build(metadata: metadata, parts: parts);
      expect(epub, isNotEmpty);
      // EPUB zip files start with the standard PK\x03\x04 local file
      // header signature.
      expect(epub.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);
    });

    test('mimetype is the very first entry and stored uncompressed', () {
      final epub = EpubBuilder.build(metadata: metadata, parts: parts);
      // The first stored filename in a ZIP local file header sits at
      // bytes 30..30+filenameLength (uint16 LE at offset 26).
      final view = ByteData.sublistView(epub);
      final fnameLen = view.getUint16(26, Endian.little);
      final firstName =
          latin1.decode(epub.sublist(30, 30 + fnameLen));
      expect(firstName, 'mimetype');
      // Compression method @ offset 8 must be 0 (stored, no compression).
      expect(view.getUint16(8, Endian.little), 0);
    });

    test('archive contains all required EPUB structure', () {
      final epub = EpubBuilder.build(metadata: metadata, parts: parts);
      final entries = ZipDecoder()
          .decodeBytes(epub)
          .files
          .map((f) => f.name)
          .toSet();
      expect(entries, containsAll([
        'mimetype',
        'META-INF/container.xml',
        'OEBPS/content.opf',
        'OEBPS/toc.ncx',
        'OEBPS/Text/part0000.xhtml',
        'OEBPS/Text/part0001.xhtml',
      ]));
    });

    test('OPF references every part in the spine', () {
      final epub = EpubBuilder.build(metadata: metadata, parts: parts);
      final opfFile = ZipDecoder()
          .decodeBytes(epub)
          .files
          .firstWhere((f) => f.name == 'OEBPS/content.opf');
      final opf = utf8.decode(opfFile.content as List<int>);
      expect(opf, contains('Text/part0000.xhtml'));
      expect(opf, contains('Text/part0001.xhtml'));
      expect(opf, contains('<itemref idref="p0"/>'));
      expect(opf, contains('<itemref idref="p1"/>'));
      // dc:title escaped properly when content has special chars.
      expect(opf, contains('<dc:title>Sample</dc:title>'));
    });

    test('OPF escapes special XML characters in metadata', () {
      final epub = EpubBuilder.build(
        metadata: const EpubMetadata(
          identifier: 'urn:test:2',
          title: 'A & B <c>',
          language: 'en',
        ),
        parts: parts,
      );
      final opf = utf8.decode(ZipDecoder()
          .decodeBytes(epub)
          .files
          .firstWhere((f) => f.name == 'OEBPS/content.opf')
          .content as List<int>);
      expect(opf, contains('A &amp; B &lt;c&gt;'));
    });

    test('cover meta is emitted when coverImageId is set', () {
      final epub = EpubBuilder.build(
        metadata: const EpubMetadata(
          identifier: 'urn:test:3',
          title: 'T',
          language: 'en',
          coverImageId: 'img7',
        ),
        parts: parts,
        images: [
          ExtractedImage(
            blockIndex: 7,
            recordIndex: 100,
            format: ImageFormat.jpeg,
            data: _u8([0xFF, 0xD8, 0xFF, 0xAA]),
          ),
        ],
      );
      final files = ZipDecoder().decodeBytes(epub).files;
      final opf = utf8.decode(
        files.firstWhere((f) => f.name == 'OEBPS/content.opf').content
            as List<int>,
      );
      expect(opf, contains('name="cover" content="img7"'));
      expect(
        files.any((f) => f.name == 'OEBPS/Images/image00007.jpg'),
        isTrue,
      );
    });
  });
}
