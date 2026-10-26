import 'dart:io';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:brizfi/ui/brizfi_style.dart';
import 'package:brizfi/ui/journey_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'journey_screen_test.dart' show JourneyServer, tapText;

void main() {
  for (final locale in ['ru', 'en']) {
    for (final size in [const Size(360, 640), const Size(360, 800)]) {
      testWidgets('connection fits $locale $size and send stays fixed', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final server = JourneyServer();
        final l = lookupAppLocalizations(Locale(locale));
        const importer = MethodChannel('ru.mkulkov.brizfi/import');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          (_) async => [for (var i = 0; i < 10; i++) 'book-$i.azw3'],
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          UsbTransfer.channel,
          (_) async => [],
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: brizfiTheme(Brightness.light),
            locale: Locale(locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              server: server,
              loadAddresses: () async => [InternetAddress('192.168.1.12')],
              receiveShares: false,
              enableUsb: true,
              allowMultiple: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final illustration = tester.getRect(find.byType(JourneyIllustration));
        expect(
          tester
              .getSize(
                find.descendant(
                  of: find.byType(JourneyIllustration),
                  matching: find.byType(Image),
                ),
              )
              .height,
          140,
          reason: 'Artwork keeps its size even on a short screen',
        );
        expect(find.byType(CheckboxListTile), findsOneWidget);
        expect(
          tester.widget<Text>(find.text(l.wifiAddressTitle)).textAlign,
          TextAlign.center,
        );
        expect(
          tester
              .widget<SelectableText>(find.byKey(const ValueKey('reader-url')))
              .textAlign,
          TextAlign.center,
        );
        await tapText(tester, l.journeyApprove);
        expect(tester.getRect(find.byType(JourneyIllustration)), illustration);
        expect(find.text('482'), findsNothing);
        expect(find.text(l.journeyCompare), findsNothing);
        expect(find.text(l.journeyHelp), findsNothing);
        await tapText(tester, l.journeyContinue);
        expect(find.text(l.selectBooksFirst), findsNothing);
        final send = find.text(l.journeySend);
        final before = tester.getRect(send);
        expect(before.bottom, lessThan(size.height));
        await tapText(tester, l.journeyAdd);
        expect(find.text('book-9.azw3'), findsOneWidget);
        expect(tester.getRect(send), before);
        await tester.ensureVisible(find.text('book-9.azw3'));
        await tester.pumpAndSettle();
        expect(tester.getRect(send), before);
        expect(tester.getRect(find.byType(JourneyIllustration)), illustration);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          UsbTransfer.channel,
          null,
        );
      });
    }
  }
}
