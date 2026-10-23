import 'dart:async';
import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/conversion_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'book_list_layout_test.dart' show LayoutPageServer;

class PickerResumeConverter extends ConversionService {
  final calls = <String>[];
  @override
  Future<File> convert(File input, {String targetFormat = 'azw3'}) async {
    calls.add(input.path);
    return File('${input.path}.converted.azw3');
  }

  @override
  void cancel() {}
}

void pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void resume(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  const channel = MethodChannel('ru.mkulkov.brizfi/import');
  for (final format in ['epub', 'fb2']) {
    testWidgets('picker $format reply before resumed converts once on resume', (
      tester,
    ) async {
      final picker = Completer<List<String>>();
      final converter = PickerResumeConverter();
      final server = LayoutPageServer();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'pickBooks' ? await picker.future : null,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              server: server,
              conversionService: converter,
              loadAddresses: () async => [InternetAddress('192.168.50.7')],
              allowMultiple: true,
              receiveShares: false,
              enableUsb: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await enterSelection(tester);
        await tester.tap(find.text('Add books'));
        await tester.pump();
        pause(tester);
        picker.complete(['fixture.$format']);
        await tester.pump();
        await tester.pump();
        expect(converter.calls, isEmpty);
        resume(tester);
        await tester.pumpAndSettle();
        expect(converter.calls, ['fixture.$format']);
        expect(find.textContaining('Conversion cancelled'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    });
  }
}
