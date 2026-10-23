import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class AboutTestServer extends ReaderServer {
  @override
  bool get paired => url != null;
  Uri? active;
  int stops = 0;
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
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    active = null;
    notifyListeners();
  }
}

void main() {
  const importer = MethodChannel('ru.mkulkov.brizfi/import');
  for (final locale in ['ru', 'en']) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets(
        'About navigation preserves transfer: $locale at $scale text',
        (tester) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final l = lookupAppLocalizations(Locale(locale));
          final server = AboutTestServer();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            importer,
            (call) async =>
                call.method == 'pickBooks' ? ['my-book.azw3'] : null,
          );
          try {
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(locale),
                theme: ThemeData(
                  brightness: scale == 2 ? Brightness.dark : Brightness.light,
                ),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: PocScreen(
                  server: server,
                  allowMultiple: true,
                  enableUsb: false,
                  receiveShares: false,
                  loadAddresses: () async => [
                    InternetAddress('192.168.50.7'),
                    InternetAddress('10.1.0.9'),
                  ],
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(l.batchIntro), findsNothing);
            expect(find.text(l.notice), findsNothing);
            expect(find.text(l.network), findsNothing);
            expect(find.text('192.168.50.7'), findsNothing);
            expect(find.textContaining('10.1.0.9'), findsNothing);
            expect(
              tester
                  .widget<SelectableText>(
                    find.byKey(const ValueKey('reader-url')),
                  )
                  .data,
              'http://192.168.50.7:8080/',
            );
            expect(server.url, isNotNull);
            await enterSelection(tester);
            await tapJourney(tester, l.journeyAdd);
            await tester.pumpAndSettle();
            await tester.pumpAndSettle();
            final url = server.url;
            expect(url, isNotNull);
            expect(url.toString(), 'http://192.168.50.7:8080/');
            expect(find.byKey(const ValueKey('reader-url')), findsNothing);
            expect(find.text(l.instructions), findsNothing);
            await tester.tap(find.byTooltip(l.aboutTitle));
            await tester.pumpAndSettle();
            expect(find.text(l.aboutTitle), findsOneWidget);
            expect(find.text(l.instructions), findsOneWidget);
            await tester.ensureVisible(find.text(l.notice));
            expect(find.text(l.notice), findsOneWidget);
            expect(server.stops, 0);
            expect(server.url, url);
            expect(tester.takeException(), isNull);
            await tester.tap(find.byType(BackButton));
            await tester.pumpAndSettle();
            expect(find.text('my-book.azw3'), findsOneWidget);
            expect(find.text(l.instructions), findsNothing);
            expect(server.url, url);
            expect(server.stops, 0);
            expect(tester.takeException(), isNull);
          } finally {
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
