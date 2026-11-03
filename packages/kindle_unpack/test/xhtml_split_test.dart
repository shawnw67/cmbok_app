import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

Uint8List _u8(List<int> b) => Uint8List.fromList(b);

void main() {
  group('XhtmlSplitter.split', () {
    test('splices a single fragment into one skeleton', () {
      // Layout in primary flow: skeleton bytes "<x></x>" then fragment
      // bytes "AB". The skeleton has length 7; the fragment slides in
      // at insertion offset 3 (between </ and x>) ... but to keep this
      // simple we use a position that doesn't trigger the partial-tag
      // heuristic: between '<x>' and '</x>'.
      const skelBytes = '<x></x>'; // 7 bytes
      const fragBytes = 'HELLO'; // 5 bytes
      final flow = _u8([...skelBytes.codeUnits, ...fragBytes.codeUnits]);

      const skeletons = SkeletonTable(entries: [
        SkeletonEntry(
          fileNumber: 0,
          name: 'SKEL0000',
          fragmentCount: 1,
          start: 0,
          length: 7,
        ),
      ]);
      const fragments = FragmentTable(entries: [
        FragmentEntry(
          insertPosition: 3, // between '<x>' and '</x>'
          idText: "P-//*[@aid='0']",
          fileNumber: 0,
          sequenceNumber: 0,
          start: 0,
          length: 5,
        ),
      ]);

      final parts = XhtmlSplitter.split(
        primaryFlow: flow,
        skeletons: skeletons,
        fragments: fragments,
      );
      expect(parts, hasLength(1));
      expect(parts[0].fileNumber, 0);
      expect(parts[0].filename, 'part0000.xhtml');
      expect(String.fromCharCodes(parts[0].bytes), '<x>HELLO</x>');
    });

    test('splices multiple fragments in order', () {
      // Skeleton "[]" at 0..2; fragment0 "AAA" at offset 1 inside skel.
      // Then fragment1 "BBB" at offset 4 (which is now position 4 in the
      // *spliced* skeleton: '[' AAA + offset 0 = 1 → after AAA but
      // before ']' which started at 4 in flow). insertPosition refers
      // to the *original* flow position, so offset within skeleton =
      // insertPosition - skel.start.
      const skelBytes = '[]';
      const frag0 = 'AAA';
      const frag1 = 'BBB';
      final flow = _u8([
        ...skelBytes.codeUnits, // 0..1
        ...frag0.codeUnits, //     2..4
        ...frag1.codeUnits, //     5..7
      ]);
      const skeletons = SkeletonTable(entries: [
        SkeletonEntry(
          fileNumber: 0,
          name: 'SKEL',
          fragmentCount: 2,
          start: 0,
          length: 2,
        ),
      ]);
      const fragments = FragmentTable(entries: [
        FragmentEntry(
          insertPosition: 1, // splice between '[' and ']'
          idText: 'a',
          fileNumber: 0,
          sequenceNumber: 0,
          start: 0,
          length: 3,
        ),
        FragmentEntry(
          insertPosition: 1, // also at offset 1 — second splice
          idText: 'b',
          fileNumber: 0,
          sequenceNumber: 1,
          start: 0,
          length: 3,
        ),
      ]);
      final parts = XhtmlSplitter.split(
        primaryFlow: flow,
        skeletons: skeletons,
        fragments: fragments,
      );
      expect(parts, hasLength(1));
      // First splice: '[AAA]'. Second splice at original insertPosition=1
      // (which is "still" between '[' and AAA after the first splice).
      expect(String.fromCharCodes(parts[0].bytes), '[BBBAAA]');
    });

    test('produces one part per skeleton with sequential filenames', () {
      // 3 skeletons, no fragments — each part is just the skeleton
      // bytes verbatim.
      const a = '<a/>';
      const b = '<b/>';
      const c = '<c/>';
      final flow = _u8([...a.codeUnits, ...b.codeUnits, ...c.codeUnits]);
      const skeletons = SkeletonTable(entries: [
        SkeletonEntry(fileNumber: 0, name: 'A', fragmentCount: 0, start: 0, length: 4),
        SkeletonEntry(fileNumber: 1, name: 'B', fragmentCount: 0, start: 4, length: 4),
        SkeletonEntry(fileNumber: 2, name: 'C', fragmentCount: 0, start: 8, length: 4),
      ]);
      const fragments = FragmentTable(entries: []);
      final parts = XhtmlSplitter.split(
        primaryFlow: flow,
        skeletons: skeletons,
        fragments: fragments,
      );
      expect(parts.map((p) => p.filename),
          ['part0000.xhtml', 'part0001.xhtml', 'part0002.xhtml']);
      expect(String.fromCharCodes(parts[0].bytes), a);
      expect(String.fromCharCodes(parts[2].bytes), c);
    });

    test('moves splice past a partial tag when insert lands mid-element', () {
      // Skeleton "<a><b" — partial '<b' tag at the boundary. Fragment
      // would land at offset 5, but the head ends with '<b' so the
      // splicer should back up to the last '>' (offset 3).
      const skelBytes = '<a><b';
      const fragBytes = 'X';
      final flow = _u8([...skelBytes.codeUnits, ...fragBytes.codeUnits]);
      const skeletons = SkeletonTable(entries: [
        SkeletonEntry(fileNumber: 0, name: 'S', fragmentCount: 1, start: 0, length: 5),
      ]);
      const fragments = FragmentTable(entries: [
        FragmentEntry(
          insertPosition: 5, // would land inside '<b'
          idText: 'a',
          fileNumber: 0,
          sequenceNumber: 0,
          start: 0,
          length: 1,
        ),
      ]);
      final parts = XhtmlSplitter.split(
        primaryFlow: flow,
        skeletons: skeletons,
        fragments: fragments,
      );
      // Expect splice at offset 3 instead of 5 → '<a>X<b'.
      expect(String.fromCharCodes(parts[0].bytes), '<a>X<b');
    });

    test('throws when a skeleton extends past the primary flow', () {
      final flow = Uint8List(5);
      const skeletons = SkeletonTable(entries: [
        SkeletonEntry(fileNumber: 0, name: 'S', fragmentCount: 0, start: 0, length: 100),
      ]);
      const fragments = FragmentTable(entries: []);
      expect(
        () => XhtmlSplitter.split(
          primaryFlow: flow,
          skeletons: skeletons,
          fragments: fragments,
        ),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws when fragments run out before skeletons declare', () {
      final flow = Uint8List(10);
      const skeletons = SkeletonTable(entries: [
        SkeletonEntry(fileNumber: 0, name: 'S', fragmentCount: 2, start: 0, length: 5),
      ]);
      const fragments = FragmentTable(entries: []);
      expect(
        () => XhtmlSplitter.split(
          primaryFlow: flow,
          skeletons: skeletons,
          fragments: fragments,
        ),
        throwsA(isA<HeaderException>()),
      );
    });
  });
}
