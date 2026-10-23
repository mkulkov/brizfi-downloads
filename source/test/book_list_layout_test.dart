import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class LayoutPageServer extends ReaderServer {
  @override
  bool get paired => url != null;
  Uri? active;
  List<File> published = [];
  @override
  Uri? get url => active;
  @override
  Future<void> startPage({
    required InternetAddress address,
    int port = 8080,
    String languageCode = 'en',
  }) async {
    active = Uri(scheme: 'http', host: address.address, port: port, path: '/');
    notifyListeners();
  }

  @override
  Future<void> updateBooks(List<File> sources) async {
    published = List.of(sources);
  }

  @override
  Future<void> stop() async {
    active = null;
  }
}

void main() {
  const importer = MethodChannel('ru.mkulkov.brizfi/import');
  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('picker stays above keyed paper rows at $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = LayoutPageServer();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        (call) async => call.method == 'pickBooks'
            ? ['first.azw3', 'second.azw3', 'third.azw3']
            : null,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: PocScreen(
              server: server,
              loadAddresses: () async => [InternetAddress('192.168.50.7')],
              allowMultiple: true,
              enableUsb: false,
              receiveShares: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('reader-url')), findsOneWidget);
        await enterSelection(tester);
        final picker = find.byKey(const ValueKey('pick-books'));
        await tester.ensureVisible(picker);
        await tester.tap(picker);
        await tester.pumpAndSettle();
        expect(server.published, isEmpty);
        void resetScroll() => tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        resetScroll();
        await tester.pumpAndSettle();
        final pickerY = tester.getTopLeft(picker).dy;
        for (final remaining in [2, 1]) {
          final remove = find.byTooltip('Remove this book').last;
          await tester.ensureVisible(remove);
          expect(tester.getSize(remove).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
          await tester.tap(remove);
          await tester.pumpAndSettle();
          resetScroll();
          await tester.pumpAndSettle();
          expect(server.published, isEmpty);
          expect(tester.getTopLeft(picker).dy, pickerY);
          expect(find.byKey(const ValueKey('book:first.azw3')), findsOneWidget);
          expect(find.byTooltip('Remove this book'), findsNWidgets(remaining));
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
      }
    });
  }
}
