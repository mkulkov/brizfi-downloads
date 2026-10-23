import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:brizfi/ui/brizfi_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'book_list_layout_test.dart' show LayoutPageServer;

class EmptyUsb extends UsbTransfer {
  @override
  Future<List<UsbReader>> listReaders() async => [];
}

void main() {
  const importer = MethodChannel('ru.mkulkov.brizfi/import');
  const names = [
    'A very long filename retaining its complete title and author across wrapped lines.azw3',
    'second.azw3',
    'third.azw3',
  ];
  for (final brightness in Brightness.values) {
    test('BRIZFI $brightness contrast', () {
      final theme = brizfiTheme(brightness);
      final c = theme.colorScheme;
      double contrast(Color a, Color b) {
        final x = a.computeLuminance();
        final y = b.computeLuminance();
        return (x > y ? x + .05 : y + .05) / (x > y ? y + .05 : x + .05);
      }

      expect(
        contrast(c.onSurface, theme.scaffoldBackgroundColor),
        greaterThanOrEqualTo(4.5),
      );
      expect(contrast(c.onSurface, c.surface), greaterThanOrEqualTo(4.5));
      expect(contrast(c.primary, c.onPrimary), greaterThanOrEqualTo(4.5));
      expect(contrast(c.secondary, c.onSecondary), greaterThanOrEqualTo(4.5));
      expect(
        contrast(c.onSurfaceVariant, c.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(c.onSurfaceVariant, c.surfaceContainerHighest),
        greaterThanOrEqualTo(4.5),
      );
      expect(contrast(c.secondary, c.surface), greaterThanOrEqualTo(3));
      expect(contrast(c.outline, c.surface), greaterThanOrEqualTo(3));
    });
    for (final scale in [1.0, 2.0, 3.2]) {
      for (final count in [0, 3]) {
        testWidgets(
          '$brightness $scale with $count books keeps connection controls and retained selection reachable',
          (tester) async {
            tester.view.physicalSize = const Size(360, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final semantics = tester.ensureSemantics();
            final server = LayoutPageServer();
            final usb = EmptyUsb();
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              importer,
              (call) async => call.method == 'pickBooks' ? names : null,
            );
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: brizfiTheme(brightness),
                  locale: const Locale('en'),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: PocScreen(
                    server: server,
                    usbTransfer: usb,
                    loadAddresses: () async => [
                      InternetAddress('192.168.50.7'),
                    ],
                    allowMultiple: true,
                    enableUsb: true,
                    receiveShares: false,
                  ),
                ),
              );
              await tester.pumpAndSettle();
              if (count != 0) {
                await enterSelection(tester);
                await tapJourney(tester, 'Add books');
                expect(find.text(names.first), findsOneWidget);
                final title = tester.widget<Text>(find.text(names.first));
                expect(title.maxLines, isNull);
                expect(title.overflow, isNot(TextOverflow.ellipsis));
                final remove = find.byTooltip('Remove this book').first;
                await tester.ensureVisible(remove);
                expect(tester.getSize(remove).width, greaterThanOrEqualTo(48));
                expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
                await tapJourney(tester, 'Change');
              }
              await tapJourney(tester, 'USB');
              await tester.ensureVisible(find.text('Find USB reader'));
              expect(find.text('No USB reader found'), findsOneWidget);
              expect(find.byKey(const ValueKey('reader-url')), findsNothing);
              expect(tester.takeException(), isNull);
              await tapJourney(tester, 'Wi-Fi');
              expect(find.byKey(const ValueKey('reader-url')), findsOneWidget);
              if (count != 0) {
                await enterSelection(tester);
                expect(find.text(names.first), findsOneWidget);
                expect(find.byTooltip('Remove this book'), findsNWidgets(3));
              }
              expect(tester.takeException(), isNull);
            } finally {
              semantics.dispose();
              await tester.pumpWidget(const SizedBox());
              await tester.pumpAndSettle();
              tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                importer,
                null,
              );
            }
          },
        );
      }
    }
  }
}
