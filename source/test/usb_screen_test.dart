import 'dart:async';
import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('system USB folder picker survives app pause', (tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('brizfi-usb-folder-ui-'),
    ))!;
    final file = (await tester.runAsync(
      () => File('${root.path}/own.azw3').writeAsBytes(List.filled(100, 0)),
    ))!;
    const importer = MethodChannel('ru.mkulkov.brizfi/import');
    final folderResult = Completer<Object?>();
    var folderStarted = false;
    var cancels = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      importer,
      (call) async => file.path,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      UsbTransfer.channel,
      (call) async {
        if (call.method == 'listDevices') {
          return [
            {'id': 7, 'name': 'Kindle USB'},
          ];
        }
        if (call.method == 'sendBook') {
          throw PlatformException(code: 'usb_busy');
        }
        if (call.method == 'sendBookViaDocuments') {
          folderStarted = true;
          return folderResult.future;
        }
        if (call.method == 'cancel') cancels++;
        return null;
      },
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PocScreen(
            allowMultiple: false,
            enableUsb: true,
            receiveShares: false,
            loadAddresses: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('USB'));
      await tester.pumpAndSettle();
      await enterSelection(tester);
      await tester.ensureVisible(find.text('Add books'));
      await tester.tap(find.text('Add books'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Send books'));
      await tester.tap(find.text('Send books'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(folderStarted, isTrue);
      expect(
        find.text('Choose the documents folder on Kindle'),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(cancels, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      folderResult.complete({'bytes': 100, 'name': 'brizfi-folder.azw3'});
      await tester.pumpAndSettle();
      expect(find.text('File transferred and verified'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        UsbTransfer.channel,
        null,
      );
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
  testWidgets('USB setup remains reachable on small screen at 320% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      UsbTransfer.channel,
      (call) async => [],
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(3.2)),
            child: child!,
          ),
          home: PocScreen(
            allowMultiple: false,
            enableUsb: true,
            receiveShares: false,
            loadAddresses: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('USB'));
      await tester.tap(find.text('USB'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Find USB reader'));
      expect(find.textContaining('No USB reader found'), findsOneWidget);
      await tester.ensureVisible(find.text('Choose books'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Choose books'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        UsbTransfer.channel,
        null,
      );
      await tester.binding.setSurfaceSize(null);
    }
  });
  testWidgets(
    'USB needs no Wi-Fi, waits for cancellation and supports large text',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('brizfi-usb-ui-'),
      ))!;
      final file = (await tester.runAsync(
        () => File('${root.path}/own.azw3').writeAsBytes(List.filled(100, 0)),
      ))!;
      const importer = MethodChannel('ru.mkulkov.brizfi/import');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        (call) async => file.path,
      );
      Completer<Object?>? sending;
      var starts = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        UsbTransfer.channel,
        (call) async {
          if (call.method == 'listDevices') {
            return [
              {'id': 7, 'name': 'Kindle USB'},
            ];
          }
          if (call.method == 'sendBook') {
            starts++;
            expect(call.arguments['path'], file.path);
            return sending!.future;
          }
          return null;
        },
      );
      await tester.binding.setSurfaceSize(const Size(360, 640));
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: PocScreen(
              allowMultiple: false,
              enableUsb: true,
              receiveShares: false,
              loadAddresses: () async => [],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('USB'));
        await tester.tap(find.text('USB'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Kindle USB'), findsOneWidget);
        expect(find.text('Open download page'), findsNothing);
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Add books'));
        await tester.tap(find.text('Add books'));
        await tester.pumpAndSettle();
        sending = Completer<Object?>();
        await tester.ensureVisible(find.text('Send books'));
        await tester.tap(find.text('Send books'));
        // File I/O must complete outside the widget fake clock.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
        expect(starts, 1);
        await tester.ensureVisible(find.text('Stop'));
        await tester.tap(find.text('Stop'));
        await tester.pump();
        expect(find.textContaining('Cancellation requested'), findsOneWidget);
        expect(find.textContaining('File written and verified'), findsNothing);
        expect(find.text('Add books'), findsNothing);
        sending.completeError(PlatformException(code: 'usb_cancelled'));
        await tester.pumpAndSettle();
        expect(find.textContaining('USB transfer cancelled'), findsOneWidget);
        expect(find.text('own.azw3'), findsOneWidget);
        await tapJourney(tester, 'Back');
        sending = Completer<Object?>();
        await tester.ensureVisible(find.text('Send books'));
        await tester.tap(find.text('Send books'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
        sending.complete({'bytes': 100, 'name': 'brizfi-test.azw3'});
        await tester.pumpAndSettle();
        expect(find.text('File transferred and verified'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          UsbTransfer.channel,
          null,
        );
        await tester.binding.setSurfaceSize(null);
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
