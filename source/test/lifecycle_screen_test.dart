import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> settleUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (ready()) return;
  }
  fail('State did not settle within the bounded wait.');
}

class GatedReaderServer extends ReaderServer {
  GatedReaderServer({required super.temporaryRoot});
  Completer<void>? startGate;
  bool allowed = true;
  @override
  bool get paired => allowed && url != null;
  @override
  void approvePairing() {
    allowed = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    allowed = false;
    await super.stop();
  }

  @override
  Future<void> startPage({
    required InternetAddress address,
    int port = 8080,
    String languageCode = 'en',
  }) async {
    await super.startPage(
      address: address,
      port: port,
      languageCode: languageCode,
    );
    await startGate?.future;
  }
}

void main() {
  void resume(WidgetTester tester) {
    if (tester.binding.lifecycleState == AppLifecycleState.paused) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  testWidgets(
    'interruption and automatic restart across five network/lifecycle cases',
    (tester) async {
      for (final mode in [
        'background',
        'network loss',
        'scan failure',
        'stale scan',
        'interruption during start',
      ]) {
        resume(tester);
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('brizfi-lifecycle-test-'),
        ))!;
        final bytes = Uint8List(1024)
          ..setRange(60, 68, ascii.encode('BOOKMOBI'));
        bytes[77] = 1;
        bytes[81] = 86;
        final source = (await tester.runAsync(
          () => File('${root.path}/fixture.azw3').writeAsBytes(bytes),
        ))!;
        final server = GatedReaderServer(temporaryRoot: root);
        if (mode == 'interruption during start') {
          server.startGate = Completer<void>();
        }
        var networkAvailable = true;
        var scanFailure = false;
        Completer<List<InternetAddress>>? pendingScan;
        Future<List<InternetAddress>> load() async {
          if (pendingScan != null) return pendingScan.future;
          if (scanFailure) {
            throw const SocketException('Synthetic scan failure');
          }
          return networkAvailable ? [InternetAddress.loopbackIPv4] : [];
        }

        const channel = MethodChannel('ru.mkulkov.brizfi/import');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => source.path,
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: PocScreen(
                allowMultiple: false,
                enableUsb: false,
                server: server,
                loadAddresses: load,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await settleUntil(tester, () => server.url != null);
          server.approvePairing();
          await tester.pumpAndSettle();
          await enterSelection(tester);
          await tapJourney(tester, 'Add books');
          await tester.pumpAndSettle();
          await settleUntil(
            tester,
            () =>
                server.url != null &&
                (mode == 'interruption during start' ||
                    find.byType(CircularProgressIndicator).evaluate().isEmpty),
          );

          if (mode == 'background' ||
              mode == 'stale scan' ||
              mode == 'interruption during start') {
            if (mode == 'stale scan') {
              pendingScan = Completer<List<InternetAddress>>();
              await tester.pump(const Duration(seconds: 5));
            }
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            if (mode == 'interruption during start') {
              server.startGate!.complete();
              server.startGate = null;
            }
            await settleUntil(tester, () => server.url == null);
            var backgroundStopDone = false;
            unawaited(server.stop().then((_) => backgroundStopDone = true));
            await settleUntil(tester, () => backgroundStopDone);
            if (mode == 'stale scan') {
              networkAvailable = false;
              final oldScan = pendingScan!;
              pendingScan = null;
              oldScan.complete([InternetAddress.loopbackIPv4]);
              resume(tester);
            }
            await settleUntil(
              tester,
              () =>
                  mode != 'stale scan' ||
                  find.text('Not connected to Wi-Fi').evaluate().isNotEmpty,
            );
          } else {
            networkAvailable = false;
            scanFailure = mode == 'scan failure';
            await tester.pump(const Duration(seconds: 5));
            await settleUntil(tester, () => server.url == null);
            await settleUntil(
              tester,
              () => find.text('Not connected to Wi-Fi').evaluate().isNotEmpty,
            );
          }
          expect(server.url, isNull);
          // A paused Flutter tree retains its last frame until resumed.
          if (tester.binding.lifecycleState != AppLifecycleState.paused) {
            await settleUntil(
              tester,
              () =>
                  find.text('Let’s connect your devices').evaluate().isNotEmpty,
            );
            expect(find.text('fixture.azw3'), findsNothing);
          }
          expect(await tester.runAsync(source.readAsBytes), bytes);
          if (mode == 'stale scan') {
            expect(find.text('Not connected to Wi-Fi'), findsOneWidget);
          }
          // Restoring foreground/network restarts the page and retains the file.
          networkAvailable = true;
          scanFailure = false;
          resume(tester);
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          await settleUntil(
            tester,
            () =>
                server.url != null &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty,
          );
          expect(server.paired, isFalse);
          server.approvePairing();
          await tester.pumpAndSettle();
          await enterSelection(tester);
          expect(find.text('fixture.azw3'), findsOneWidget);
          expect(find.textContaining('moved to the background'), findsNothing);
          expect(find.textContaining('network changed'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          if (server.startGate != null && !server.startGate!.isCompleted) {
            server.startGate!.complete();
          }
          pendingScan?.complete([]);
          resume(tester);
          await tester.pumpWidget(const SizedBox.shrink());
          var stopped = false;
          unawaited(server.stop().whenComplete(() => stopped = true));
          await settleUntil(tester, () => stopped);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
          await tester.runAsync(() => root.delete(recursive: true));
        }
      }
    },
  );
}
