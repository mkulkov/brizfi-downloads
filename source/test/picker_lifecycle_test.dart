import 'dart:async';
import 'dart:io';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'journey_screen_test.dart' show JourneyServer, tapText;

void main() {
  testWidgets('picker retains empty paired page; Home still revokes it', (
    tester,
  ) async {
    const channel = MethodChannel('ru.mkulkov.brizfi/import');
    final picker = Completer<List<String>?>();
    final server = JourneyServer();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) => picker.future,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PocScreen(
          server: server,
          loadAddresses: () async => [InternetAddress('192.168.1.12')],
          receiveShares: false,
          enableUsb: false,
          allowMultiple: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapText(tester, 'The codes match');
    await tapText(tester, 'Choose books');
    await tester.ensureVisible(find.text('Add books'));
    await tester.tap(find.text('Add books'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(server.paired, isTrue);
    expect(server.published, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    picker.complete(null);
    await tester.pumpAndSettle();
    expect(server.paired, isTrue);
    expect(find.text('Add books'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(server.paired, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });
}
