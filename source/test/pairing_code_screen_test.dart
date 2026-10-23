import 'dart:io';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class PairingPreview extends ReaderServer {
  bool active = false;
  bool requested = true;
  bool allowed = false;
  void activate() {
    active = true;
    notifyListeners();
  }

  @override
  Uri? get url => active ? Uri.parse('http://127.0.0.1:8080/') : null;
  @override
  bool get pendingPairing => active && requested;
  @override
  bool get paired => active && allowed;
  @override
  String? get pairingCode => active && (requested || allowed) ? '517' : null;
  @override
  void approvePairing() {
    requested = false;
    allowed = true;
    notifyListeners();
  }

  @override
  Future<void> startPage({
    required InternetAddress address,
    int port = 8080,
    String languageCode = 'en',
  }) async {
    activate();
  }

  @override
  Future<void> updateBooks(List<File> sources) async {}

  @override
  Future<void> stop() async {
    active = false;
    notifyListeners();
  }
}

void main() {
  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets(
      'comparison code and approval remain reachable at $scale text',
      (tester) async {
        final server = PairingPreview();
        final semantics = tester.ensureSemantics();
        await tester.binding.setSurfaceSize(const Size(320, 640));
        try {
          await tester.pumpWidget(
            MaterialApp(
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
                allowMultiple: false,
                server: server,
                receiveShares: false,
                enableUsb: false,
                loadAddresses: () async => [InternetAddress.loopbackIPv4],
              ),
            ),
          );
          await tester.pumpAndSettle();
          server.activate();
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('517'));
          expect(find.text('517'), findsOneWidget);
          expect(find.bySemanticsLabel('Pairing code: 5 1 7'), findsOneWidget);
          final code = tester.widget<Text>(find.text('517'));
          expect(code.style!.fontSize, 30);
          final paragraph = tester.renderObject<RenderBox>(find.text('517'));
          // The test font has unusually wide glyphs; allow wrapping rather than
          // reducing the user's text scale or clipping any digit.
          expect(paragraph.size.width, lessThanOrEqualTo(272));
          await tester.ensureVisible(find.text('The codes match'));
          await tester.tap(find.text('The codes match'));
          await tester.pumpAndSettle();
          expect(server.allowed, isTrue);
          expect(find.text('517'), findsNothing);
          expect(find.text('How to connect?'), findsNothing);
          expect(
            find.textContaining(
              'Access is allowed for the reader with this code',
            ),
            findsNothing,
          );
          await server.stop();
          await tester.pumpAndSettle();
          expect(find.text('517'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.binding.setSurfaceSize(null);
          semantics.dispose();
        }
      },
    );
  }
}
