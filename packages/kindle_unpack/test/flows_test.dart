import 'dart:typed_data';

import 'package:kindle_unpack/kindle_unpack.dart';
import 'package:test/test.dart';

Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

/// Build a minimal in-memory FDST record from `(start, end)` pairs so we
/// can feed [BookFlows.split] without re-parsing every test.
FdstTable _fdst(List<(int, int)> ranges) => FdstTable(
      entries: [
        for (final r in ranges) FdstEntry(start: r.$1, end: r.$2),
      ],
    );

void main() {
  group('BookFlows.split', () {
    test('splits rawML into FDST-bounded sections', () {
      const html = '<html><body>hi</body></html>';
      const css = '@charset "utf-8"; body { color: black }';
      const aux = '\x00\x01\x02\x03';
      final rawML =
          _u8([...html.codeUnits, ...css.codeUnits, ...aux.codeUnits]);
      final fdst = _fdst([
        (0, html.length),
        (html.length, html.length + css.length),
        (html.length + css.length, rawML.length),
      ]);

      final flows = BookFlows.split(rawML, fdst);
      expect(flows.flows, hasLength(3));
      expect(flows.flows[0].kind, FlowKind.html);
      expect(flows.flows[0].extension, 'html');
      expect(flows.flows[1].kind, FlowKind.css);
      expect(flows.flows[1].extension, 'css');
      expect(flows.flows[2].kind, FlowKind.other);
      expect(flows.flows[2].extension, 'dat');
    });

    test('classifies bare-tag, XML-declared, and SVG flows', () {
      const xmlHtml = '<?xml version="1.0"?><html><head/></html>';
      const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>';
      final rawML = _u8([...xmlHtml.codeUnits, ...svg.codeUnits]);
      final flows = BookFlows.split(
        rawML,
        _fdst([(0, xmlHtml.length), (xmlHtml.length, rawML.length)]),
      );
      expect(flows.flows[0].kind, FlowKind.html);
      expect(flows.flows[1].kind, FlowKind.svg);
    });

    test('primaryHtml looks up the html flow regardless of position', () {
      const css = 'body{margin:0}';
      const html = '<html></html>';
      final rawML = _u8([...css.codeUnits, ...html.codeUnits]);
      final flows = BookFlows.split(
        rawML,
        _fdst([(0, css.length), (css.length, rawML.length)]),
      );
      expect(flows.primaryHtml, isNotNull);
      expect(flows.primaryHtml!.index, 1);
    });

    test('ofKind returns flows of the requested type in order', () {
      const a = '<html>1</html>';
      const b = '<html>2</html>';
      const c = '@charset "x";';
      final rawML = _u8([...a.codeUnits, ...b.codeUnits, ...c.codeUnits]);
      final flows = BookFlows.split(
        rawML,
        _fdst([
          (0, a.length),
          (a.length, a.length + b.length),
          (a.length + b.length, rawML.length),
        ]),
      );
      expect(flows.ofKind(FlowKind.html), hasLength(2));
      expect(flows.ofKind(FlowKind.css), hasLength(1));
    });

    test('flow bytes are zero-copy views over the input buffer', () {
      const html = '<html>x</html>';
      final rawML = Uint8List.fromList(html.codeUnits);
      final flows = BookFlows.split(rawML, _fdst([(0, rawML.length)]));
      // Mutating the source buffer should be visible through the slice.
      rawML[0] = 0x59; // 'Y'
      expect(flows.flows[0].bytes[0], 0x59);
    });

    test('throws when an FDST entry exceeds rawML length', () {
      final rawML = Uint8List(10);
      expect(
        () => BookFlows.split(rawML, _fdst([(0, 100)])),
        throwsA(isA<HeaderException>()),
      );
    });

    test('throws on inverted FDST range', () {
      final rawML = Uint8List(20);
      expect(
        () => BookFlows.split(rawML, _fdst([(15, 5)])),
        throwsA(isA<HeaderException>()),
      );
    });

    test('whitespace-only flows are classified as other', () {
      final rawML = _u8([0x20, 0x0A, 0x09]);
      final flows = BookFlows.split(rawML, _fdst([(0, rawML.length)]));
      expect(flows.flows.single.kind, FlowKind.other);
    });
  });
}
