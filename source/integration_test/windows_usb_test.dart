import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:brizfi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Opt in only with a physical Kindle attached. Writes one original test book
// under a fresh UUID name and leaves it for the owner's reading check.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows FB2 conversion and physical Kindle USB readback', (
    tester,
  ) async {
    expect(Platform.isWindows, isTrue);
    final random = Random.secure();
    final hex = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final uuid =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-8${hex.substring(17, 20)}-${hex.substring(20)}';
    final sep = Platform.pathSeparator;
    final directory = await Directory(
      '${Directory.systemTemp.path}${sep}brizfi_imports$sep$uuid',
    ).create(recursive: true);
    await File('${directory.path}$sep.brizfi_owned')
        .writeAsString('brizfi-import-v1\n$uuid\n');
    final source = await File('${directory.path}${sep}BRIZFI-Windows-USB.fb2')
        .writeAsString(_fixture);
    final sourceBytes = await source.readAsBytes();

    final screenshotKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenshotKey,
        child: BrizfiApp(home: PocScreen(loadAddresses: () async => [])),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB'));
    await _wait(tester, () {
      final dynamic state = tester.state(find.byType(PocScreen));
      return state.usbDeviceId != null;
    });
    final dynamic state = tester.state(find.byType(PocScreen));
    expect((state.usbReaders as List).length, greaterThan(0));
    // Same acceptance/conversion path as the system picker, without requiring
    // interactive selection in the automated hardware test. No mocked channels.
    await state.acceptBooks([source.path]);
    await tester.pumpAndSettle();
    expect(state.preparedBook, isNotNull, reason: '${state.conversionError}');
    final output = state.preparedBook as File;
    final bytes = await output.readAsBytes();
    expect(ascii.decode(bytes.sublist(60, 68)), 'BOOKMOBI');
    final send = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          (widget.data == 'Send books' || widget.data == 'Отправить книги'),
    );
    await tester.ensureVisible(send);
    await tester.tap(send);
    await _wait(tester, () => state.usbReceipt != null || state.failed == true);
    expect(state.failed, isFalse, reason: '${state.operationError}');
    expect(state.usbReceipt, isNotNull);
    expect(state.usbReceipt.bytes, bytes.length);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            (widget.data == 'File transferred and verified' ||
                widget.data == 'Файл передан и проверен'),
      ),
      findsOneWidget,
    );
    expect(await source.readAsBytes(), orderedEquals(sourceBytes));
    final evidence = {
      'platform': 'windows-x64',
      'test':
          'native FB2 conversion -> UI Send books -> WPD USB -> full readback',
      'file': state.usbReceipt.name,
      'bytes': state.usbReceipt.bytes,
      'sourceUnchanged': true,
      'kindleOpening': 'NOT_RUN: disconnect USB and verify on Kindle',
    };
    const evidencePath = String.fromEnvironment('BRIZFI_USB_EVIDENCE');
    if (evidencePath.isNotEmpty) {
      await File(evidencePath).writeAsString(jsonEncode(evidence));
      await precacheImage(
        const AssetImage('assets/illustrations/journey-3.png'),
        tester.element(find.byType(PocScreen)),
      );
      await tester.pumpAndSettle();
      final boundary =
          screenshotKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final screenshot = await boundary.toImage();
      final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
      await File('$evidencePath.png').writeAsBytes(png!.buffer.asUint8List());
      screenshot.dispose();
    }
    // ignore: avoid_print
    print('BRIZFI_WINDOWS_USB ${jsonEncode(evidence)}');
    // Native ownership/lease checks perform cleanup, never the user's source.
    await state.removeSentBooks();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(
    done(),
    isTrue,
    reason: 'Timed out waiting for native Windows operation',
  );
  await tester.pump();
}

const _fixture = '''<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
<description><title-info><genre>prose_contemporary</genre>
<author><first-name>BRIZFI</first-name><last-name>Test</last-name></author>
<book-title>BRIZFI Windows USB Check</book-title><lang>ru</lang></title-info>
<document-info><author><nickname>BRIZFI</nickname></author>
<date>2026-10-17</date><id>brizfi-windows-usb-original</id><version>1.0</version>
</document-info></description>
<body><section><title><p>Проверка Windows и USB</p></title>
<p>Собственный тестовый текст BRIZFI. Ёжик читает книгу у моря.</p>
<p>Контрольная фраза: BRIZFI-WINDOWS-USB-20261017.</p>
<p>Книга преобразована локально из FB2 в AZW3 и передана через USB.</p>
</section></body></FictionBook>''';
