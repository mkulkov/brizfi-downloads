import 'dart:io';

import 'package:brizfi/services/conversion_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unsupported conversion pairs fail before loading native code',
    () async {
      for (final pair in [
        ('book.pdf', 'epub'),
        ('book.epub', 'epub'),
        ('book.azw3', 'azw3'),
        ('book.fb2', 'pdf'),
        ('book.bin', 'azw3'),
      ]) {
        await expectLater(
          ConversionService().convert(File(pair.$1), targetFormat: pair.$2),
          throwsA(
            isA<ConversionFailure>().having(
              (e) => e.code,
              'code',
              'unsupported_format',
            ),
          ),
        );
      }
    },
  );
}
