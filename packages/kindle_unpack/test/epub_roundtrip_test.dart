import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epubx/epubx.dart' as epubx;
import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

/// Roundtrip: AZW3 -> KindleBook.toEpub() -> epubx.EpubReader.readBook.
///
/// epubx is a strict pure-Dart EPUB parser used by downstream readers
/// (e.g. the My_book_reader Flutter app). The packager has historically
/// produced an EPUB that opens in lenient tools but trips strict
/// readers with:
///
///     Exception: EPUB parsing error: TOC item, not found in EPUB manifest.
///
/// Root cause (confirmed by inspecting epubx's navigation_reader.dart
/// and the OPF this packager emits): the OPF declares
/// `<package version="3.0">`, so epubx looks for an EPUB-3 nav document
/// — i.e. a manifest item with `properties="nav"`. Our packager only
/// ships an NCX (`<item id="ncx" ... media-type="application/x-dtbncx+xml"/>`)
/// and never declares a nav.xhtml, so the manifest lookup returns
/// nothing and parsing fails.
///
/// The fix in task #2 will make the packager either emit a real
/// EPUB-3 nav.xhtml *and* declare it with properties="nav", or drop
/// the package version to 2.0 and rely on the NCX. Either makes
/// epubx happy.
void main() {
  final fixture = File('test/fixtures/Leviathan_Wakes.azw3');
  if (!fixture.existsSync()) {
    test('EPUB roundtrip skipped (fixture missing)', () {
      // ignore: avoid_print
      print(
        'Skipping EPUB roundtrip test: ${fixture.path} not present. '
        'Drop a DRM-free AZW3 there to enable.',
      );
    }, skip: 'AZW3 fixture not present');
    return;
  }

  group('AZW3 -> EPUB -> epubx roundtrip', () {
    late Uint8List epubBytes;

    setUpAll(() {
      final azwBytes = fixture.readAsBytesSync();
      epubBytes = KindleBook.fromBytes(azwBytes).toEpub();
    });

    test('produces a non-empty EPUB byte buffer', () {
      expect(epubBytes, isNotEmpty);
    });

    test('OPF and NCX exist in the zip and reference matching files', () {
      // Sanity-only: this test passes today. It's here so when #2 lands
      // and the manifest gains a nav.xhtml entry, regressions in OPF
      // shape get caught alongside the epubx assertion below.
      final archive = ZipDecoder().decodeBytes(epubBytes);
      final opf = archive.findFile('OEBPS/content.opf');
      expect(opf, isNotNull, reason: 'content.opf missing from EPUB');
      final ncx = archive.findFile('OEBPS/toc.ncx');
      expect(ncx, isNotNull, reason: 'toc.ncx missing from EPUB');

      final opfStr = utf8.decode(opf!.content as List<int>);
      final ncxStr = utf8.decode(ncx!.content as List<int>);

      // Diagnostic dump on assertion failure: surfaces exactly which
      // <navPoint><content src="..."/> entries have no matching
      // manifest <item href="..."/>. Useful while task #2 is in flight.
      final hrefRe = RegExp(r'<item\s+[^>]*href="([^"]+)"');
      final manifestHrefs =
          hrefRe.allMatches(opfStr).map((m) => m.group(1)!).toSet();
      final navSrcRe = RegExp(r'<content\s+src="([^"#]+)');
      final ncxSrcs =
          navSrcRe.allMatches(ncxStr).map((m) => m.group(1)!).toSet();
      final missing = ncxSrcs.difference(manifestHrefs);
      expect(
        missing,
        isEmpty,
        reason:
            'NCX references not declared in OPF manifest: $missing\n'
            '--- content.opf ---\n$opfStr\n--- toc.ncx ---\n$ncxStr',
      );
    });

    test('parses cleanly with epubx (strict EPUB reader)', () async {
      // This is the canary for the bug. Today this throws:
      //   Exception: EPUB parsing error: TOC item, not found in EPUB manifest.
      // After task #2 is fixed, epubx should return an EpubBook and
      // expose at least one chapter / TOC entry.
      final book = await epubx.EpubReader.readBook(epubBytes);
      expect(book.Title, isNotEmpty);
      expect(book.Chapters, isNotNull);
      expect(book.Chapters!.length, greaterThan(0),
          reason: 'epubx returned a book with no chapters; '
              'TOC/spine wiring is probably still off');
    });
  });
}
