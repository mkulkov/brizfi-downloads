import 'dart:io';

import 'book_list_layout_test.dart';
import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';

import 'package:brizfi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'failed import keeps the selected copy and remove preserves original',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('brizfi-ui-storage-'),
      ))!;
      final files = (await tester.runAsync(() async {
        final original = await File('${root.path}/original.azw3')
            .writeAsBytes([1, 2, 3]);
        final directory = await Directory(
          '${root.path}/brizfi_imports/01a11b41-c4a3-7c31-be08-492f1a72cb09',
        ).create(recursive: true);
        return (
          original,
          await original.copy('${directory.path}/selected.azw3'),
        );
      }))!;
      final (original, copy) = files;
      const channel = MethodChannel('ru.mkulkov.brizfi/import');
      var failImport = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'releaseImport') {
          expect(call.arguments['path'], copy.path);
          await copy.delete();
          await copy.parent.delete();
          return null;
        }
        if (failImport) throw PlatformException(code: 'cache_full');
        return copy.path;
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              allowMultiple: false,
              server: LayoutPageServer(),
              enableUsb: false,
              receiveShares: false,
              loadAddresses: () async => [InternetAddress.loopbackIPv4],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Add books'));
        await tester.tap(find.text('Add books'));
        await tester.pumpAndSettle();
        expect(find.text('selected.azw3'), findsOneWidget);
        failImport = true;
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Add books'));
        await tester.tap(find.text('Add books'));
        await tester.pumpAndSettle();
        expect(find.textContaining('not enough room'), findsOneWidget);
        expect(find.text('selected.azw3'), findsOneWidget);
        expect(await tester.runAsync(copy.exists), isTrue);
        await tester.ensureVisible(find.text('Remove selected book'));
        await tester.tap(find.text('Remove selected book'));
        for (var attempt = 0; attempt < 20; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (find.text('selected.azw3').evaluate().isEmpty) break;
        }
        expect(await tester.runAsync(copy.exists), isFalse);
        expect(await tester.runAsync(original.readAsBytes), [1, 2, 3]);
        expect(find.text('selected.azw3'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('PoC actions remain reachable at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PocScreen(
            allowMultiple: false,
            server: LayoutPageServer(),
            enableUsb: false,
            receiveShares: false,
            loadAddresses: () async => [InternetAddress.loopbackIPv4],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final choose = find.text('Choose books');
      await tester.ensureVisible(choose);
      expect(choose, findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('Open download page'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
