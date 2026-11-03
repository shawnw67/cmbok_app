// Example: read a Kindle file and write an EPUB next to it.
//
//   dart run example/main.dart path/to/book.azw3
//
// Prints a small summary of what was parsed; writes
// `path/to/book.epub` alongside the input.

import 'dart:io';

import 'package:kindle_unpack/kindle_unpack.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run example/main.dart <book.mobi|.azw3>');
    exit(64);
  }
  final input = File(args[0]);
  if (!input.existsSync()) {
    stderr.writeln('No such file: ${input.path}');
    exit(66);
  }

  final book = KindleBook.fromBytes(input.readAsBytesSync());
  print('Title:   ${book.title}');
  print('Authors: ${book.exth?.authors.join(', ') ?? '(unknown)'}');
  print('Format:  ${book.format}');
  print('Parts:   ${book.parts.length}');
  print('Images:  ${book.images.all.length}');
  print('Fonts:   ${book.fonts.length}');

  final outPath = input.path.replaceFirst(
    RegExp(r'\.(azw3?|mobi)$', caseSensitive: false),
    '.epub',
  );
  File(outPath).writeAsBytesSync(book.toEpub());
  print('\nWrote EPUB → $outPath');
}
