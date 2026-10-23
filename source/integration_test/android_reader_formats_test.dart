import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:brizfi/main.dart';
import 'package:brizfi/services/conversion_service.dart';
import 'package:brizfi/services/book_validation.dart';
import 'package:brizfi/services/reader_profile.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _PairedReader extends ReaderServer {
  @override
  bool get paired => true;
}

class _RealConverter extends ConversionService {
  final calls = <String>[];
  @override
  Future<File> convert(File input, {String targetFormat = 'azw3'}) {
    calls.add(targetFormat);
    return super.convert(input, targetFormat: targetFormat);
  }
}

// No mocked import/conversion/USB channels. Only the paired-browser status is
// supplied locally; this test does not claim a physical reader transfer.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android profiles use real EPUB/AZW3 conversion and retain alternates',
    (tester) async {
      expect(Platform.isAndroid, isTrue);
      expect(const bool.fromEnvironment('BRIZFI_ISOLATED_TEST'), isTrue);
      final vmCache = Directory(
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      expect(
        vmCache.path,
        contains('/ru.mkulkov.brizfi.isolated/'),
        reason: 'Refuse to test in the working application data',
      );
      final root = Directory('${vmCache.parent.path}/cache/brizfi_imports');
      await root.create(recursive: true);
      final random = Random.secure();
      final hex = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final uuid =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-8${hex.substring(17, 20)}-${hex.substring(20)}';
      final directory = await Directory('${root.path}/$uuid').create();
      await File('${directory.path}/.brizfi_owned')
          .writeAsString('brizfi-import-v1\n$uuid\n');
      final source = await File('${directory.path}/own.fb2')
          .writeAsString(_fixture);
      final original = await source.readAsBytes();
      final converter = _RealConverter();
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: BrizfiApp(
            home: PocScreen(
              server: _PairedReader(),
              conversionService: converter,
              receiveShares: false,
              enableWifiProfiles: true,
              loadAddresses: () async => [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PocScreen));
      await state.selectWifiProfile(ReaderProfile.nook);
      await state.acceptBooks([source.path]);
      await tester.pumpAndSettle();
      final epub = state.preparedBook as File?;
      expect(epub, isNotNull, reason: '${state.conversionError}');
      expect(epub!.path, endsWith('.converted.epub'));
      final epubBytes = await epub.readAsBytes();
      expect(epubBytes.take(2), [0x50, 0x4b]);
      await validateTransferBook(epub, 'epub');
      await state.selectWifiProfile(ReaderProfile.kindle);
      await tester.pumpAndSettle();
      final azw3 = state.preparedBook as File?;
      expect(azw3, isNotNull, reason: '${state.conversionError}');
      expect(azw3!.path, endsWith('.converted.azw3'));
      final azw3Bytes = await azw3.readAsBytes();
      await validateTransferBook(azw3, 'azw3');
      expect(String.fromCharCodes(azw3Bytes.sublist(60, 68)), 'BOOKMOBI');
      expect(await epub.readAsBytes(), orderedEquals(epubBytes));
      await state.selectWifiProfile(ReaderProfile.nook);
      await tester.pumpAndSettle();
      expect(state.preparedBook.path, epub.path);
      expect(converter.calls, ['epub', 'azw3']);
      expect(await source.readAsBytes(), orderedEquals(original));
      final usb = UsbTransfer();
      expect(
        await usb.listReaders(),
        isEmpty,
        reason: 'Emulator has no physical USB reader',
      );
      usb.dispose();
      expect(tester.takeException(), isNull);
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final screenshot = await boundary.toImage();
      final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
      await File('${vmCache.parent.path}/cache/android-reader-formats.png')
          .writeAsBytes(png!.buffer.asUint8List());
      screenshot.dispose();
      // ignore: avoid_print
      print(
        'BRIZFI_ANDROID_FORMATS fb2->epub=${epubBytes.length} fb2->azw3=${azw3Bytes.length} cachedReuse=true sourceUnchanged=true nativeUsbCount=0',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

const _fixture = '''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
<description><title-info><genre>prose_contemporary</genre><author><nickname>BRIZFI</nickname></author><book-title>BRIZFI Android profiles</book-title><lang>ru</lang></title-info></description>
<body><section><title><p>Проверка форматов</p></title><p>Собственный текст. Ёжик читает книгу у моря.</p><p>BRIZFI-ANDROID-PROFILES-20261017</p></section></body></FictionBook>''';
