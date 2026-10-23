import 'package:brizfi/services/reader_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generic devices receive original formats independent of brand', () {
    for (final id in ['generic', 'generic-storage', 'generic-mtp']) {
      final profile = ReaderProfile.fromNative(id, [
        'epub',
        'azw3',
        'pdf',
        'txt',
        'mobi',
      ]);
      for (final format in ['epub', 'azw3', 'pdf', 'txt', 'mobi']) {
        expect(profile.targetFor(format), format);
      }
      expect(profile.targetFor('kfx'), isNull);
    }
  });
  test('NOOK preserves EPUB/PDF and converts unsupported ebook originals', () {
    for (final format in ['epub', 'pdf']) {
      expect(ReaderProfile.nook.targetFor(format), format);
    }
    for (final format in ['fb2', 'azw3', 'mobi', 'txt']) {
      expect(ReaderProfile.nook.targetFor(format), 'epub');
    }
    expect(ReaderProfile.nook.targetFor('kfx'), isNull);
  });

  test('Kindle preserves supported originals; legacy transport stays AZW3', () {
    for (final format in ['azw3', 'mobi', 'pdf', 'txt']) {
      expect(ReaderProfile.kindle.targetFor(format), format);
    }
    expect(ReaderProfile.kindle.targetFor('epub'), 'azw3');
    expect(ReaderProfile.kindleLegacy.targetFor('pdf'), isNull);
  });

  test(
    'unknown profile never guesses support; native capabilities can narrow',
    () {
      final unknown = ReaderProfile.fromNative('unidentified', ['epub']);
      expect(unknown.targetFor('epub'), isNull);
      final restricted = ReaderProfile.fromNative('nook', ['pdf', 'azw3']);
      expect(restricted.targetFor('pdf'), 'pdf');
      expect(restricted.targetFor('azw3'), isNull);
      expect(restricted.targetFor('fb2'), isNull);
    },
  );

  test('file format parsing ignores directory dots and normalizes case', () {
    expect(ReaderProfile.formatOf(r'C:\some.dir\Книга.EPUB'), 'epub');
    expect(ReaderProfile.formatOf('/some.dir/book'), '');
  });
}
