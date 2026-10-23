import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:brizfi/src/rust/api/conversion.dart';
import 'package:brizfi/src/rust/frb_generated.dart';
import 'package:brizfi/services/conversion_service.dart';
import 'package:brizfi/services/managed_imports.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android managed storage quota, leases and conversion cleanup', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final originals = await Directory.systemTemp.createTemp(
        'brizfi-storage-original-',
      );
      // Flutter VM may use code_cache; native SAF owns Context.cacheDir.
      final vmCache = Directory(
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      final cacheName = vmCache.uri.pathSegments
          .where((p) => p.isNotEmpty)
          .last;
      expect(cacheName, anyOf('cache', 'code_cache'));
      final imports = await Directory(
        '${vmCache.parent.path}/cache/brizfi_imports',
      ).create(recursive: true);
      final canonicalImports = Directory(await imports.resolveSymbolicLinks());
      Future<Directory> marked() async {
        final directory = await Directory(
          '${canonicalImports.path}/${_testUuid()}',
        ).create();
        await File('${directory.path}/.brizfi_owned').writeAsString(
          'brizfi-import-v1\n${directory.uri.pathSegments.where((p) => p.isNotEmpty).last}\n',
        );
        return directory;
      }

      final active = await marked();
      final stale = await marked();
      final unrelated = await Directory(
        '${canonicalImports.path}/storage-test-${_testUuid()}',
      ).create();
      final originalBytes = utf8.encode(
        _fb2('Собственная проверка хранения FB2.'),
      );
      final original = await File('${originals.path}/original.fb2')
          .writeAsBytes(originalBytes);
      final input = await original.copy('${active.path}/managed.fb2');
      final padding = File('${unrelated.path}/padding');
      var reserved = false;
      try {
        await File('${stale.path}/.brizfi_owned')
            .setLastModified(DateTime.now().subtract(const Duration(days: 2)));
        await ManagedImports.channel.invokeMethod<void>('clearExpiredImports');
        expect(await stale.exists(), isFalse);
        expect(await unrelated.exists(), isTrue);
        expect(await active.exists(), isTrue);
        final handle = await padding.open(mode: FileMode.write);
        try {
          await handle.truncate(96 * 1024 * 1024);
        } finally {
          await handle.close();
        }
        await expectLater(
          ManagedImports.reserve(input),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'cache_full',
            ),
          ),
        );
        expect(await input.readAsBytes(), originalBytes);
        await padding.delete();
        await ManagedImports.reserve(input);
        reserved = true;
        await expectLater(
          ManagedImports.release(input),
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'busy'),
          ),
        );
        await File('${active.path}/.brizfi_owned')
            .setLastModified(DateTime.now().subtract(const Duration(days: 2)));
        await ManagedImports.channel.invokeMethod<void>('clearExpiredImports');
        expect(await input.exists(), isTrue);
        await ManagedImports.finish(input);
        reserved = false;
        // The product service must reserve/release automatically around real Rust.
        final output = await ConversionService().convert(input);
        await _expectMobi(output, await output.length());
        expect(await input.readAsBytes(), originalBytes);
        await ManagedImports.release(input);
        expect(await active.exists(), isFalse);
        expect(await original.readAsBytes(), originalBytes);
        expect(await unrelated.exists(), isTrue);
      } finally {
        if (reserved) await ManagedImports.finish(input);
        if (await active.exists()) {
          try {
            await ManagedImports.release(input);
          } on PlatformException {
            // Cleanup must not mask the original assertion/contract failure.
            await active.delete(recursive: true);
          }
        }
        if (await stale.exists()) {
          await stale.delete(recursive: true); // Only this test's own fixture.
        }
        if (await padding.exists()) await padding.delete();
        await unrelated.delete();
        await originals.delete(recursive: true);
      }
    });
  });

  testWidgets('Android native EPUB bridge and Dart heartbeat', (tester) async {
    await tester.runAsync(() async {
      // Library initialization is deliberately outside the responsiveness sample.
      if (!RustLib.instance.initialized) await RustLib.init();
      final root = await Directory.systemTemp.createTemp('brizfi-converter-');
      try {
        final original = _epub(
          'Собственная проверочная книга. Кириллица: ё Ё.',
        );
        final input = await File('${root.path}/original.epub')
            .writeAsBytes(original, flush: true);
        final output = File('${root.path}/original.azw3');
        final result = await convertEpub(
          input: input.path,
          output: output.path,
        );
        expect(result.errorCode, isNull);
        expect(result.bytes, greaterThan(0));
        await _expectMobi(output, result.bytes);
        expect(await input.readAsBytes(), orderedEquals(original));

        final invalidBytes = utf8.encode('Это собственный текст, не EPUB.');
        final invalid = await File('${root.path}/invalid.epub')
            .writeAsBytes(invalidBytes);
        final invalidOutput = File('${root.path}/invalid.azw3');
        final rejected = await convertEpub(
          input: invalid.path,
          output: invalidOutput.path,
        );
        expect(rejected.errorCode, isNotNull);
        expect(rejected.bytes, 0);
        expect(await invalidOutput.exists(), isFalse);
        expect(await invalid.readAsBytes(), orderedEquals(invalidBytes));

        final existingBytes = await output.readAsBytes();
        final existing = await convertEpub(
          input: input.path,
          output: output.path,
        );
        expect(existing.errorCode, 'output_exists');
        expect(existing.bytes, 0);
        expect(await output.readAsBytes(), orderedEquals(existingBytes));
        expect(await input.readAsBytes(), orderedEquals(original));

        // One long text node stays far below the XML event limit. Stored ZIP
        // avoids relying on a compression package or app-bundled test assets.
        final largeBytes = _epub(
          List.filled(
            45000,
            'Бриз: собственный текст для проверки фоновой конвертации. ',
          ).join(),
        );
        final large = await File('${root.path}/large.epub')
            .writeAsBytes(largeBytes, flush: true);
        final largeOutput = File('${root.path}/large.azw3');
        var ticks = 0;
        var maxGapMs = 0;
        var lastMs = 0;
        final elapsed = Stopwatch()..start();
        final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
          final now = elapsed.elapsedMilliseconds;
          final gap = now - lastMs;
          if (gap > maxGapMs) maxGapMs = gap;
          lastMs = now;
          ticks++;
        });
        late ConversionResult largeResult;
        try {
          largeResult = await convertEpub(
            input: large.path,
            output: largeOutput.path,
          );
        } finally {
          heartbeat.cancel();
          elapsed.stop();
        }
        expect(largeResult.errorCode, isNull);
        await _expectMobi(largeOutput, largeResult.bytes);
        expect(await large.readAsBytes(), orderedEquals(largeBytes));
        expect(
          ticks,
          greaterThan(0),
          reason: 'Dart timer must run while native conversion is pending.',
        );
        binding.reportData = <String, dynamic>{
          'inputBytes': largeBytes.length,
          'outputBytes': largeResult.bytes,
          'conversionMs': elapsed.elapsedMilliseconds,
          'heartbeatTicksDuringConversion': ticks,
          'maxHeartbeatGapMs': maxGapMs,
          'scope': 'Dart timer responsiveness; no frame or Kindle assertion',
        };
        // Test-only evidence: no paths, metadata or user book content.
        // ignore: avoid_print
        print('BRIZFI_CONVERTER_METRICS ${jsonEncode(binding.reportData)}');

        final service = ConversionService();
        final cancelled = service.convert(large);
        // Cancellation is immediately requested. This covers the service's
        // pre-dispatch checkpoint; it does not prove interruption inside Boko.
        service.cancel();
        await expectLater(
          cancelled,
          throwsA(
            isA<ConversionFailure>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
        expect(await File('${large.path}.converted.azw3').exists(), isFalse);
        expect(await large.readAsBytes(), orderedEquals(largeBytes));

        // The resolved bridge initialization lets Dart dispatch before this timer.
        // Boko still completes; the service must discard output before acknowledging.
        var cancellationRequested = false;
        final requestCancellation = Timer(const Duration(milliseconds: 10), () {
          cancellationRequested = true;
          service.cancel();
        });
        try {
          await expectLater(
            service.convert(large),
            throwsA(
              isA<ConversionFailure>().having(
                (error) => error.code,
                'code',
                'cancelled',
              ),
            ),
          );
          expect(cancellationRequested, isTrue);
          expect(await File('${large.path}.converted.azw3').exists(), isFalse);
          expect(await large.readAsBytes(), orderedEquals(largeBytes));
        } finally {
          requestCancellation.cancel();
        }
      } finally {
        // Only this test-owned temporary directory is removed.
        await root.delete(recursive: true);
      }
    });
  });

  testWidgets('Android FB2 chain, encodings, unsafe XML and cancellation', (
    tester,
  ) async {
    await tester.runAsync(() async {
      if (!RustLib.instance.initialized) await RustLib.init();
      final root = await Directory.systemTemp.createTemp('brizfi-fb2-test-');
      try {
        final sourceBytes = utf8.encode(
          _fb2(
            'Эта книга преобразована из FB2 на телефоне в BRIZFI. Ёжик читает у моря.',
          ),
        );
        final input = await File('${root.path}/original.fb2')
            .writeAsBytes(sourceBytes);
        final output = File('${root.path}/original.azw3');
        final result = await convertFb2(input: input.path, output: output.path);
        expect(result.errorCode, isNull);
        await _expectMobi(output, result.bytes);
        expect(await input.readAsBytes(), orderedEquals(sourceBytes));
        final existingBytes = await output.readAsBytes();
        final existing = await convertFb2(
          input: input.path,
          output: output.path,
        );
        expect(existing.errorCode, 'output_exists');
        expect(await output.readAsBytes(), orderedEquals(existingBytes));

        final cp1251 = _windows1251(
          _fb2('Кириллица в Windows-1251: ё Ё.')
              .replaceFirst('encoding="UTF-8"', 'encoding="windows-1251"'),
        );
        final legacy = await File('${root.path}/legacy.fb2')
            .writeAsBytes(cp1251);
        final legacyOutput = File('${root.path}/legacy.azw3');
        final legacyResult = await convertFb2(
          input: legacy.path,
          output: legacyOutput.path,
        );
        expect(legacyResult.errorCode, isNull);
        await _expectMobi(legacyOutput, legacyResult.bytes);
        expect(await legacy.readAsBytes(), orderedEquals(cp1251));

        final unsafe = await File('${root.path}/unsafe.fb2').writeAsString(
          '<!DOCTYPE FictionBook [<!ENTITY read SYSTEM "file:///not-a-real-file">]><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">&read;</FictionBook>',
        );
        final unsafeOutput = File('${root.path}/unsafe.azw3');
        final unsafeResult = await convertFb2(
          input: unsafe.path,
          output: unsafeOutput.path,
        );
        expect(unsafeResult.errorCode, isNotNull);
        expect(await unsafeOutput.exists(), isFalse);

        final largeBytes = utf8.encode(
          _fb2(
            List.filled(
              45000,
              'Собственный текст FB2 для проверки преобразования. ',
            ).join(),
          ),
        );
        final large = await File('${root.path}/large.fb2')
            .writeAsBytes(largeBytes);
        final service = ConversionService();
        var ticks = 0;
        var lastMs = 0;
        var maxGapMs = 0;
        final elapsed = Stopwatch()..start();
        final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
          final now = elapsed.elapsedMilliseconds;
          if (now - lastMs > maxGapMs) maxGapMs = now - lastMs;
          lastMs = now;
          ticks++;
        });
        late File largeOutput;
        try {
          largeOutput = await service.convert(large);
        } finally {
          heartbeat.cancel();
          elapsed.stop();
        }
        await _expectMobi(largeOutput, await largeOutput.length());
        expect(ticks, greaterThan(0));
        expect(await large.readAsBytes(), orderedEquals(largeBytes));
        binding.reportData = {
          ...?binding.reportData,
          'fb2': {
            'inputBytes': largeBytes.length,
            'outputBytes': await largeOutput.length(),
            'conversionMs': elapsed.elapsedMilliseconds,
            'heartbeatTicksDuringConversion': ticks,
            'maxHeartbeatGapMs': maxGapMs,
            'scope': 'FB2 full chain, Dart timer; no frame or Kindle assertion',
          },
        };
        // ignore: avoid_print
        print('BRIZFI_FB2_METRICS ${jsonEncode(binding.reportData!['fb2'])}');
        await largeOutput.delete();

        final cancellation = Timer(
          const Duration(milliseconds: 10),
          service.cancel,
        );
        try {
          await expectLater(
            service.convert(large),
            throwsA(
              isA<ConversionFailure>().having(
                (e) => e.code,
                'code',
                'cancelled',
              ),
            ),
          );
          expect(await File('${large.path}.converted.azw3').exists(), isFalse);
          expect(await large.readAsBytes(), orderedEquals(largeBytes));
        } finally {
          cancellation.cancel();
        }
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}

String _testUuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String _fb2(String text) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><genre>prose_contemporary</genre><author><first-name>BRIZFI</first-name><last-name>Проверка</last-name></author><book-title>Бриз: FB2 на Android</book-title><lang>ru</lang></title-info><document-info><author><nickname>BRIZFI</nickname></author><date>2026-10-09</date><id>brizfi-fb2-test-original</id><version>1.0</version></document-info></description>
<body><title><p>Бриз: FB2 на Android</p></title><section id="chapter-one"><title><p>Первая глава</p></title><p>$text</p><p><strong>Жирный текст</strong> и <emphasis>курсив</emphasis>. <a l:href="#note-one" type="note">Примечание</a>.</p></section><section id="chapter-two"><title><p>Вторая глава</p></title><p>Оригинальная книга для проверки локального преобразования.</p></section></body>
<body name="notes"><title><p>Примечания</p></title><section id="note-one"><title><p>Первое примечание</p></title><p>Собственное примечание. <a l:href="#chapter-one">Назад</a>.</p></section></body>
</FictionBook>''';

List<int> _windows1251(String value) => value.runes.map((rune) {
  if (rune <= 0x7f) return rune;
  if (rune >= 0x410 && rune <= 0x44f) return rune - 0x410 + 0xc0;
  if (rune == 0x401) return 0xa8;
  if (rune == 0x451) return 0xb8;
  throw StateError('Unexpected character in original CP1251 fixture');
}).toList();

Future<void> _expectMobi(File output, int expectedLength) async {
  expect(expectedLength, greaterThan(68));
  expect(await output.length(), expectedLength);
  final handle = await output.open();
  try {
    await handle.setPosition(60);
    expect(await handle.read(8), orderedEquals(ascii.encode('BOOKMOBI')));
  } finally {
    await handle.close();
  }
}

// Original test-only EPUB 2; all text is authored for this fixture.
Uint8List _epub(String text) => _storedZip({
  'mimetype': utf8.encode('application/epub+zip'),
  'META-INF/container.xml': utf8.encode(
    '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  ),
  'OEBPS/content.opf': utf8.encode(
    '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:brizfi:original-test-book</dc:identifier><dc:title>Бриз: проверочная книга</dc:title><dc:creator>BRIZFI test</dc:creator><dc:language>ru</dc:language></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx"><itemref idref="chapter"/></spine></package>''',
  ),
  'OEBPS/toc.ncx': utf8.encode(
    '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:brizfi:original-test-book"/></head><docTitle><text>Бриз: проверочная книга</text></docTitle><navMap><navPoint id="chapter" playOrder="1"><navLabel><text>Проверка</text></navLabel><content src="chapter.xhtml"/></navPoint></navMap></ncx>''',
  ),
  'OEBPS/chapter.xhtml': utf8.encode(
    '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Бриз: проверочная книга</title></head><body><h1>Бриз: проверочная книга</h1><p>$text</p></body></html>''',
  ),
});

Uint8List _storedZip(Map<String, List<int>> entries) {
  final data = BytesBuilder(copy: false);
  final directory = BytesBuilder(copy: false);
  for (final entry in entries.entries) {
    final name = utf8.encode(entry.key);
    final bytes = entry.value;
    final crc = _crc32(bytes);
    final offset = data.length;
    final header = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, bytes.length, Endian.little)
      ..setUint32(22, bytes.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    data.add(header.buffer.asUint8List());
    data.add(name);
    data.add(bytes);
    final central = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, bytes.length, Endian.little)
      ..setUint32(24, bytes.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    directory.add(central.buffer.asUint8List());
    directory.add(name);
  }
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, directory.length, Endian.little)
    ..setUint32(16, data.length, Endian.little);
  data.add(directory.takeBytes());
  data.add(end.buffer.asUint8List());
  return data.takeBytes();
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
