import 'dart:io';
import 'dart:ui' as ui;

import 'package:brizfi/about_screen.dart';
import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/monetization.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:brizfi/ui/brizfi_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'journey_screen_test.dart' show JourneyServer, tapText;
import 'services/monetization_test.dart' show FakeAds, FakePurchases;

class _Usb extends UsbTransfer {
  _Usb(this.failSecond);
  final bool failSecond;
  int sends = 0;
  @override
  Future<List<UsbReader>> listReaders() async => [
    const UsbReader(7, 'Kindle USB'),
  ];
  @override
  Future<UsbReceipt> send(File file, int deviceId) async {
    sends++;
    if (sends == 2 && failSecond) {
      throw PlatformException(code: 'usb_transfer_failed');
    }
    return UsbReceipt(100, file.uri.pathSegments.last);
  }
}

void main() {
  for (final failed in [false, true]) {
    testWidgets(
      'USB batch advertisement only after all receipts: failed=$failed',
      (tester) async {
        final sdk = FakeAds();
        final ads = Monetization(ads: sdk, purchases: FakePurchases());
        final usb = _Usb(failed);
        const importer = MethodChannel('ru.mkulkov.brizfi/import');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          (call) async =>
              call.method == 'pickBooks' ? ['first.azw3', 'second.azw3'] : null,
        );
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              monetization: ads,
              usbTransfer: usb,
              enableUsb: true,
              receiveShares: false,
              allowMultiple: true,
              loadAddresses: () async => [],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tapText(tester, 'USB');
        await tapText(tester, 'Confirm reader');
        await tapText(tester, 'Choose books');
        await tapText(tester, 'Add books');
        await tapText(tester, 'Send books');
        expect(usb.sends, 2);
        expect(sdk.shows, failed ? 0 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        ads.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
      },
    );
  }
  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets(
      'About purchase appears only with ads and store, scale $scale',
      (tester) async {
        final sdk = FakeAds();
        final ads = Monetization(ads: sdk, purchases: FakePurchases());
        await ads.initialize();
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: AboutScreen(
              enableUsb: false,
              allowMultiple: true,
              monetization: ads,
            ),
          ),
        );
        final button = find.byKey(const ValueKey('remove-ads'));
        expect(button.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(button).bottom,
          lessThan(tester.getRect(find.text('BRIZFI')).top),
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
        sdk.unavailable();
        await tester.pump();
        expect(button, findsNothing);
        sdk.online = true;
        sdk.notifyListeners();
        await tester.pump();
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(ads.removed, isTrue);
        expect(button, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        ads.dispose();
      },
    );
  }
  for (final failAd in [false, true]) {
    testWidgets('Wi-Fi success alone triggers ad once; SDK failure=$failAd', (
      tester,
    ) async {
      final sdk = FakeAds()..failShow = failAd;
      final ads = Monetization(ads: sdk, purchases: FakePurchases());
      final server = JourneyServer();
      const importer = MethodChannel('ru.mkulkov.brizfi/import');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        (call) async =>
            call.method == 'pickBooks' ? ['first.azw3', 'second.azw3'] : null,
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PocScreen(
            server: server,
            monetization: ads,
            enableUsb: false,
            receiveShares: false,
            allowMultiple: true,
            loadAddresses: () async => [InternetAddress('192.168.1.12')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-banner')), findsOneWidget);
      await tapText(tester, 'The codes match');
      await tapText(tester, 'Choose books');
      await tapText(tester, 'Add books');
      await tapText(tester, 'Send books');
      server.downloading = true;
      server.notifyListeners();
      await tester.pumpAndSettle();
      expect(sdk.shows, 0, reason: 'Partial batch is not success');
      server.finish();
      await tester.pumpAndSettle();
      server.finish();
      await tester.pumpAndSettle();
      expect(sdk.shows, 1);
      expect(
        find.text('Check the books in your reader’s library'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      ads.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        null,
      );
    });
  }

  testWidgets('capture Android monetization layout with simulated providers', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('CAPTURE_MONETIZATION')) return;
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
            ),
          ),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final captureKey = GlobalKey();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ads = Monetization(ads: FakeAds(), purchases: FakePurchases());
    await ads.initialize();
    for (final wide in [false, true]) {
      for (final dark in [false, true]) {
        tester.view.physicalSize = wide
            ? const Size(720, 900)
            : const Size(360, 800);
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              theme: brizfiTheme(dark ? Brightness.dark : Brightness.light),
              locale: const Locale('ru'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(wide ? 2 : 1)),
                child: child!,
              ),
              home: AboutScreen(
                enableUsb: false,
                allowMultiple: true,
                monetization: ads,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('remove-ads')));
        await tester.pumpAndSettle();
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = (await tester.runAsync(() => boundary.toImage()))!;
        final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        ))!;
        await tester.runAsync(() async {
          final dir = await Directory('artifacts/monetization-ui')
              .create(recursive: true);
          await File(
            '${dir.path}/about-${wide ? 'wide-200' : 'compact'}-${dark ? 'dark' : 'light'}.png',
          ).writeAsBytes(bytes.buffer.asUint8List());
        });
        image.dispose();
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
    ads.dispose();
  });
}
