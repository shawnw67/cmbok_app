import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

/// End-to-end smoke test against a real KF8 (AZW3) file.
///
/// The fixture isn't checked in — modern AZW3 books are typically under
/// active copyright and can't sit alongside the GPL-3 source. To run
/// this suite locally, drop a DRM-free AZW3 at the path below
/// (`Leviathan_Wakes.azw3` is what the original development used). The
/// suite skips itself when the file is absent.
///
/// **Caution:** assertions exercise structural properties (record
/// counts, table sizes, format detection, decompressed length) but
/// deliberately don't echo book content. The `decompressBookText` call
/// produces the full novel; we check its length and a tiny invariant
/// (whitespace ratio) without printing the bytes.
void main() {
  final fixture = File('test/fixtures/Leviathan_Wakes.azw3');
  if (!fixture.existsSync()) {
    test('AZW3 integration skipped (fixture missing)', () {
      // ignore: avoid_print
      print(
        'Skipping AZW3 integration tests: ${fixture.path} not present. '
        'Drop a DRM-free AZW3 there to enable.',
      );
    }, skip: 'AZW3 fixture not present');
    return;
  }
  final bytes = fixture.readAsBytesSync();

  group('AZW3 fixture', () {
    late PdbFile pdb;
    late KindleFile kf;
    late KindleSection kf8;

    setUpAll(() {
      pdb = PdbFile.parse(bytes);
      kf = KindleFile.inspect(pdb);
      // Every AZW3 file we'd realistically test against is either
      // standalone KF8 or combo with a KF8 section.
      kf8 = kf.kf8!;
    });

    test('detected as a KF8 file (standalone or combo)', () {
      expect(kf.format, anyOf(KindleFormat.kf8Only, KindleFormat.combo));
      expect(kf.kf8, isNotNull);
      expect(kf8.mobi.fileVersion, greaterThanOrEqualTo(8));
    });

    test('KF8 record 0 carries non-empty headers', () {
      expect(kf8.palmDoc.textRecordCount, greaterThan(0));
      expect(kf8.mobi.headerLength, greaterThanOrEqualTo(232));
      expect(kf8.mobi.textEncoding, 65001);
      expect(kf8.mobi.hasExth, isTrue);
      expect(kf8.exth, isNotNull);
    });

    test('drm fields are unset (DRM-free book)', () {
      expect(kf8.mobi.hasDrm, isFalse);
      expect(kf8.mobi.drmCount, anyOf(0, MobiHeader.unset));
    });

    test('FDST entries are contiguous starting at offset 0', () {
      expect(kf8.mobi.fdstRecord, isNotNull);
      expect(kf8.mobi.fdstRecord, isNot(MobiHeader.unset));
      final fdstRec = pdb.records[kf8.mobi.fdstRecord! + kf8.recordOffset];
      final fdst = FdstTable.parse(fdstRec.data);
      expect(fdst.sectionCount, greaterThan(0));
      expect(fdst.entries.first.start, 0);
      for (var i = 1; i < fdst.entries.length; i++) {
        expect(
          fdst.entries[i].start,
          fdst.entries[i - 1].end,
          reason: 'FDST entries should be contiguous',
        );
      }
      // KF8's first flow is the HTML; its length matches the PalmDOC
      // textLength field (which only covers the primary flow, not the
      // CSS / font / NCX flows that follow).
      expect(fdst.entries.first.end, kf8.palmDoc.textLength);
    });

    test('HUFF/CDIC decompression matches FDST total flow length', () {
      // Exercises Phase 6's decompressor against real bytes for the
      // first time — the synthetic round-trips cover the algorithm,
      // but a real KF8 has many text records and a multi-record CDIC
      // dictionary with non-precoded entries, which the synthetic tests
      // can't reach.
      //
      // KF8's `textLength` only counts the primary HTML flow. The
      // decompressed rawML extends further to cover CSS / font / NCX
      // flows; the FDST table's last entry tells us the true total.
      expect(kf8.palmDoc.compression, CompressionType.huffCdic);
      final fdstRec = pdb.records[kf8.mobi.fdstRecord! + kf8.recordOffset];
      final fdst = FdstTable.parse(fdstRec.data);
      final text = decompressBookText(
        pdb: pdb,
        palmDoc: kf8.palmDoc,
        mobi: kf8.mobi,
      );
      expect(text.length, fdst.entries.last.end);
      // Cheap content sanity: the rawML should be mostly printable
      // ASCII / UTF-8 — at least 50 % of bytes in the 0x20..0x7E range.
      // We deliberately don't log or fingerprint the actual content.
      final printable = _printableRatio(text);
      expect(
        printable,
        greaterThan(0.5),
        reason: 'decompressed text looks more like binary than HTML/text',
      );
    });

    test('cover image is present and has a recognised format', () {
      final images = BookImages.extract(
        pdb: pdb,
        mobi: kf8.mobi,
        exth: kf8.exth,
      );
      expect(images.all, isNotEmpty);
      final cover = images.cover;
      expect(cover, isNotNull);
      expect(
        cover!.format,
        anyOf(ImageFormat.jpeg, ImageFormat.png, ImageFormat.gif),
      );
    });

    test('BookFlows.split partitions rawML by FDST byte ranges', () {
      final rawML = decompressBookText(
        pdb: pdb,
        palmDoc: kf8.palmDoc,
        mobi: kf8.mobi,
      );
      final fdstRec = pdb.records[kf8.mobi.fdstRecord! + kf8.recordOffset];
      final fdst = FdstTable.parse(fdstRec.data);
      final flows = BookFlows.split(rawML, fdst);

      expect(flows.flows, hasLength(fdst.entries.length));
      var sum = 0;
      for (final f in flows.flows) {
        sum += f.length;
      }
      expect(sum, rawML.length);

      // Flow 0 is the primary HTML; the structure check doesn't echo
      // any book content.
      expect(flows.primaryHtml, isNotNull);
      expect(flows.primaryHtml!.index, 0);
      final head = flows.primaryHtml!.bytes;
      var i = 0;
      while (i < head.length && (head[i] == 0x20 || head[i] == 0x0A)) {
        i++;
      }
      expect(head[i], 0x3C, reason: 'primary flow should start with "<"');
    });

    test('skeleton + fragment INDX tables parse and align', () {
      final skel = SkeletonTable.parse(pdb, kf8.mobi);
      final frag = FragmentTable.parse(pdb, kf8.mobi);

      // Cross-check on the AZW3 we developed against: 70 skeletons,
      // 414 fragments, fragmentCount across skeletons sums to the
      // fragment-table size.
      expect(skel.entries, hasLength(70));
      expect(frag.entries, hasLength(414));
      var totalFragments = 0;
      for (final s in skel.entries) {
        totalFragments += s.fragmentCount;
      }
      expect(totalFragments, frag.entries.length);

      // Skeletons should be ordered by start offset and non-overlapping.
      var prevEnd = 0;
      for (final s in skel.entries) {
        expect(s.start, greaterThanOrEqualTo(prevEnd));
        prevEnd = s.end;
      }

      // Each fragment's fileNumber must reference an existing skeleton.
      for (final f in frag.entries) {
        expect(f.fileNumber, lessThan(skel.entries.length));
      }
    });

    test('XhtmlSplitter produces one .xhtml part per skeleton', () {
      final rawML = decompressBookText(
        pdb: pdb,
        palmDoc: kf8.palmDoc,
        mobi: kf8.mobi,
      );
      final fdstRec = pdb.records[kf8.mobi.fdstRecord! + kf8.recordOffset];
      final fdst = FdstTable.parse(fdstRec.data);
      final flows = BookFlows.split(rawML, fdst);
      final skel = SkeletonTable.parse(pdb, kf8.mobi);
      final frag = FragmentTable.parse(pdb, kf8.mobi);

      final parts = XhtmlSplitter.split(
        primaryFlow: flows.primaryHtml!.bytes,
        skeletons: skel,
        fragments: frag,
      );

      // 70 skeletons → 70 XHTML parts.
      expect(parts, hasLength(skel.entries.length));
      // Spliced parts together should equal the primary flow length —
      // splicing reassembles the same bytes, just regrouped.
      var totalLen = 0;
      for (final p in parts) {
        totalLen += p.bytes.length;
      }
      expect(totalLen, flows.primaryHtml!.bytes.length);
      // Filenames are sequential, zero-padded, no gaps.
      for (var i = 0; i < parts.length; i++) {
        expect(parts[i].filename,
            'part${i.toString().padLeft(4, '0')}.xhtml');
      }
    });

    test('KindleBook.toEpub produces a structurally valid EPUB zip', () {
      final book = KindleBook.fromBytes(bytes);
      final epubBytes = book.toEpub();

      // Verify zip can be re-decoded.
      final archive = ZipDecoder().decodeBytes(epubBytes);
      final names = archive.files.map((f) => f.name).toSet();
      // Required EPUB skeleton.
      expect(names, contains('mimetype'));
      expect(names, contains('META-INF/container.xml'));
      expect(names, contains('OEBPS/content.opf'));
      // 70 XHTML parts (one per skeleton).
      final partFiles =
          names.where((n) => n.startsWith('OEBPS/Text/part')).toList();
      expect(partFiles, hasLength(book.parts.length));
      // 9 image entries (matches what BookImages extracts on this file).
      final imgFiles =
          names.where((n) => n.startsWith('OEBPS/Images/')).toList();
      expect(imgFiles, hasLength(book.images.all.length));

      // mimetype is first entry, stored uncompressed (EPUB OCF spec).
      final view = ByteData.sublistView(epubBytes);
      final firstFnameLen = view.getUint16(26, Endian.little);
      expect(latin1.decode(epubBytes.sublist(30, 30 + firstFnameLen)),
          'mimetype');
      expect(view.getUint16(8, Endian.little), 0);

      // OPF spine references every part. We assert structural shape
      // only — no book content is echoed.
      final opfFile =
          archive.files.firstWhere((f) => f.name == 'OEBPS/content.opf');
      final opf = utf8.decode(opfFile.content as List<int>);
      for (final part in book.parts) {
        expect(opf, contains('Text/${part.filename}'));
      }
    });

    test('exactly one RESC record is present and parses to OPF XML', () {
      // Walk the resource block looking for the RESC magic.
      final rescIndices = <int>[];
      for (var i = kf8.mobi.firstImageIndex; i < pdb.records.length; i++) {
        final d = pdb.records[i].data;
        if (d.length >= 4 &&
            d[0] == 0x52 && d[1] == 0x45 && d[2] == 0x53 && d[3] == 0x43) {
          rescIndices.add(i);
        }
      }
      expect(rescIndices, hasLength(1),
          reason: 'KF8 books carry exactly one RESC manifest');

      final resc = RescResource.parse(pdb.records[rescIndices.single].data);
      // Sanity-check the XML structure: it should contain the OPF
      // metadata + spine elements, start with '<', and have no trailing
      // null padding (the parser strips it).
      expect(resc.xml, contains('<metadata'));
      expect(resc.xml, contains('<spine'));
      expect(resc.xml.codeUnitAt(0), 0x3C);
      expect(resc.xmlBytes.last, isNot(0));
    });
  });
}

double _printableRatio(Uint8List bytes) {
  if (bytes.isEmpty) return 0;
  var printable = 0;
  for (final b in bytes) {
    if ((b >= 0x20 && b <= 0x7E) || b == 0x09 || b == 0x0A || b == 0x0D) {
      printable++;
    }
  }
  return printable / bytes.length;
}
