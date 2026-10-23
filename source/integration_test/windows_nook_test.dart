import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:brizfi/main.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Opt in with a physical NOOK connected. Writes one new original test book;
// leaves that book for reading verification. Never alters existing reader files.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('NOOK detection -> automatic FB2 to EPUB -> USB -> full readback', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue);
    const readerRoot = String.fromEnvironment('BRIZFI_NOOK_ROOT');
    expect(
      readerRoot,
      isNotEmpty,
      reason: 'Supply independently identified NOOK volume root',
    );
    final destination = Directory('$readerRoot/My Files/Books');
    expect(await destination.exists(), isTrue);
    final before = (await destination.list().toList())
        .map((file) => file.uri.pathSegments.last)
        .toSet();

    final hex = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final uuid =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-8${hex.substring(17, 20)}-${hex.substring(20)}';
    final separator = Platform.pathSeparator;
    final directory = await Directory(
      '${Directory.systemTemp.path}${separator}brizfi_imports$separator$uuid',
    ).create(recursive: true);
    await File('${directory.path}$separator.brizfi_owned')
        .writeAsString('brizfi-import-v1\n$uuid\n');
    final source = await File(
      '${directory.path}${separator}BRIZFI-NOOK-USB.fb2',
    ).writeAsString(_fixture);
    final originalBytes = await source.readAsBytes();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: BrizfiApp(home: PocScreen(loadAddresses: () async => [])),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB'));
    final dynamic state = tester.state(find.byType(PocScreen));
    await _wait(tester, () => (state.usbReaders as List).isNotEmpty);
    final nook = (state.usbReaders as List<UsbReader>)
        .where((reader) => reader.profile.id == 'nook')
        .single;
    await state.selectUsbReader(nook.id);
    expect(nook.profile.formats, {'epub', 'pdf'});
    expect(nook.transport, 'massStorage');
    await state.acceptBooks([source.path]);
    await tester.pumpAndSettle();
    expect(state.preparedBook, isNotNull, reason: '${state.conversionError}');
    final output = state.preparedBook as File;
    expect(output.path, endsWith('.converted.epub'));
    final bytes = await output.readAsBytes();
    expect(bytes.take(2), [0x50, 0x4b]);

    final send = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          (widget.data == 'Send books' || widget.data == 'Отправить книги'),
    );
    await tester.ensureVisible(send);
    await tester.tap(send);
    await _wait(tester, () => state.usbReceipt != null || state.failed == true);
    expect(state.failed, isFalse, reason: '${state.operationError}');
    final receipt = state.usbReceipt as UsbReceipt;
    expect(receipt.name, endsWith('.epub'));
    expect(receipt.bytes, bytes.length);
    // Independent OS read through the separately identified mounted volume,
    // in addition to the transport's native full SHA-256 readback.
    final written = File('${destination.path}/${receipt.name}');
    expect(await written.readAsBytes(), orderedEquals(bytes));
    expect(await source.readAsBytes(), orderedEquals(originalBytes));
    final after = (await destination.list().toList())
        .map((file) => file.uri.pathSegments.last)
        .toSet();
    expect(after.difference(before), {receipt.name});
    expect(before.difference(after), isEmpty);

    final result = {
      'reader': nook.name,
      'profile': nook.profile.id,
      'formats': nook.profile.formats.toList(),
      'transport': nook.transport,
      'conversion': 'fb2 -> epub',
      'file': receipt.name,
      'bytes': receipt.bytes,
      'nativeSha256Readback': true,
      'independentReadbackMatches': true,
      'sourceUnchanged': true,
      'newReaderFiles': 1,
      'readerOpening':
          'NOT_RUN: safely eject USB and open BRIZFI NOOK USB Check',
    };
    const evidence = String.fromEnvironment('BRIZFI_NOOK_EVIDENCE');
    if (evidence.isNotEmpty) {
      await File(evidence).writeAsString(jsonEncode(result));
      await precacheImage(
        const AssetImage('assets/illustrations/journey-3.png'),
        tester.element(find.byType(PocScreen)),
      );
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final screenshot = await boundary.toImage();
      final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
      await File('$evidence.png').writeAsBytes(png!.buffer.asUint8List());
      screenshot.dispose();
    }
    // ignore: avoid_print
    print('BRIZFI_NOOK_USB ${jsonEncode(result)}');
    await state.removeSentBooks();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: 'Timed out waiting for NOOK native operation');
  await tester.pump();
}

const _fixture = '''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
<description><title-info><genre>prose_contemporary</genre>
<author><first-name>BRIZFI</first-name><last-name>Test</last-name></author>
<book-title>BRIZFI NOOK USB Check</book-title><lang>ru</lang></title-info>
<document-info><author><nickname>BRIZFI</nickname></author>
<date>2026-10-17</date><id>brizfi-nook-usb-original</id><version>1.0</version>
</document-info></description>
<body><section><title><p>Проверка NOOK</p></title>
<p>Собственный тестовый текст BRIZFI. Ёжик читает книгу у моря.</p>
<p>Контрольная фраза: BRIZFI-NOOK-USB-20261017.</p>
<p>Книга автоматически преобразована из FB2 в EPUB для NOOK и передана по USB.</p>
</section></body></FictionBook>''';
