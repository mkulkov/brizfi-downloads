import 'dart:convert';
import 'dart:io';

import 'package:brizfi/main.dart';
import 'package:brizfi/services/monetization.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class LanguageServer extends ReaderServer {
  String? language;

  @override
  void updateLanguage(String languageCode) {
    super.updateLanguage(languageCode);
    language = languageCode;
  }
}

void main() {
  test('English and Russian catalogs have complete translations', () {
    Map<String, dynamic> catalog(String language) =>
        jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = catalog('en')..removeWhere((key, _) => key.startsWith('@'));
    final ru = catalog('ru')..removeWhere((key, _) => key.startsWith('@'));
    expect(en.keys.toSet(), ru.keys.toSet());
    for (final key in en.keys) {
      expect(en[key], isNotEmpty, reason: key);
      expect(ru[key], isNotEmpty, reason: key);
      expect(
        RegExp('[А-Яа-яЁё]').hasMatch(en[key] as String),
        isFalse,
        reason: 'Untranslated English string: $key',
      );
    }
  });

  testWidgets('App follows system locales and propagates live changes', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final server = LanguageServer();
    tester.platformDispatcher.localesTestValue = [const Locale('ru', 'RU')];
    await tester.pumpWidget(
      BrizfiApp(
        home: PocScreen(
          server: server,
          monetization: Monetization(),
          receiveShares: false,
          enableUsb: false,
          loadAddresses: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Познакомим устройства'), findsOneWidget);
    expect(server.language, 'ru');

    for (final locales in [
      [const Locale('en', 'GB')],
      [const Locale('en', 'US')],
      [const Locale('de', 'DE')],
      [const Locale('fr', 'FR'), const Locale('en', 'GB')],
    ]) {
      tester.platformDispatcher.localesTestValue = locales;
      await tester.pumpAndSettle();
      expect(find.text('Let’s connect your devices'), findsOneWidget);
      expect(server.language, 'en');
    }

    tester.platformDispatcher.localesTestValue = [const Locale('ru', 'KZ')];
    await tester.pumpAndSettle();
    expect(find.text('Познакомим устройства'), findsOneWidget);
    expect(server.language, 'ru');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
