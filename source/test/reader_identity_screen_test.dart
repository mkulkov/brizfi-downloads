import 'dart:io';
import 'dart:ui' as ui;

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_identity.dart';
import 'package:brizfi/services/reader_profile.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'journey_screen_test.dart' show JourneyServer;

class MemoryChoices extends ReaderPreferences {
  final saved = <String, ReaderBrand>{};
  @override
  Future<void> load() async {}
  @override
  ReaderBrand? choice(String key) => saved[key];
  @override
  Future<void> save(String key, ReaderBrand brand) async {
    saved[key] = brand;
  }
}

class IdentityUsb extends UsbTransfer {
  IdentityUsb({this.unique = true});
  final bool unique;
  @override
  Future<List<UsbReader>> listReaders() async => [
    UsbReader(
      7,
      'Kindle',
      profile: ReaderProfile.kindle,
      identityKey: 'usb:test',
      identityIsUnique: unique,
    ),
  ];
}

class DiscoveryUsb extends UsbTransfer {
  List<UsbReader> available = const [
    UsbReader(
      9,
      'PocketBook USB',
      detectedBrand: ReaderBrand.pocketbook,
      profile: ReaderProfile.generic,
      identityKey: 'usb:discovery',
      identityIsUnique: false,
    ),
  ];
  @override
  Future<List<UsbReader>> listReaders() async => available;
}

void main() {
  testWidgets('Wi-Fi PocketBook and Other can connect without a brand gate', (
    tester,
  ) async {
    final server = JourneyServer()
      ..readerIdentity = const ReaderIdentity(
        'wifi:generic',
        ReaderBrand.pocketbook,
      );
    await tester.pumpWidget(
      BrizfiApp(
        home: PocScreen(
          server: server,
          readerPreferences: MemoryChoices(),
          enableUsb: false,
          receiveShares: false,
          loadAddresses: () async => [InternetAddress.loopbackIPv4],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(PocScreen));
    expect(state.chosenBrand, ReaderBrand.pocketbook);
    await state.approveReader();
    await tester.pumpAndSettle();
    expect(state.connected, isTrue);
    await state.acceptBooks(['own.epub']);
    expect(state.preparedBook.path, 'own.epub');
    await state.chooseReaderBrand(ReaderBrand.other);
    await state.confirmReader();
    expect(state.connected, isTrue);
    expect(state.preparedBook.path, 'own.epub');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'USB discovery remembers corrections without a brand restriction',
    (tester) async {
      final choices = MemoryChoices();
      final usb = DiscoveryUsb();
      final reader = usb.available.single;
      await tester.pumpWidget(
        BrizfiApp(
          home: PocScreen(
            readerPreferences: choices,
            usbTransfer: usb,
            enableUsb: true,
            receiveShares: false,
            loadAddresses: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PocScreen));
      state.changeMode(TransferMode.usb);
      await tester.pumpAndSettle();
      expect(state.chosenBrand, ReaderBrand.pocketbook);
      expect(state.connected, isFalse);
      expect(find.text('Model: Other'), findsOneWidget);
      await state.chooseReaderBrand(ReaderBrand.other);
      await state.confirmReader();
      usb.available = [];
      await state.findUsbReaders();
      expect(state.selectedUsbReader, isNull);
      usb.available = [reader];
      await state.findUsbReaders();
      await tester.pumpAndSettle();
      expect(
        state.chosenBrand,
        ReaderBrand.other,
        reason: 'Saved correction overrides PocketBook discovery',
      );
      expect(
        state.readerConfirmed,
        isFalse,
        reason: 'USB family identity needs confirmation',
      );
      expect(state.readerProfile.targetFor('epub'), 'epub');
      expect(state.connected, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/segoeui.ttf');
    if (await font.exists()) {
      final loader = FontLoader('ReaderQA')
        ..addFont(
          font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
      await loader.load();
    }
  });
  testWidgets('USB family choice is restored but still needs confirmation', (
    tester,
  ) async {
    final choices = MemoryChoices()..saved['usb:test'] = ReaderBrand.kindle;
    await tester.pumpWidget(
      BrizfiApp(
        home: PocScreen(
          readerPreferences: choices,
          usbTransfer: IdentityUsb(unique: false),
          enableUsb: true,
          receiveShares: false,
          loadAddresses: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(PocScreen));
    state.changeMode(TransferMode.usb);
    await tester.pumpAndSettle();
    expect(state.chosenBrand, ReaderBrand.kindle);
    expect(state.readerConfirmed, isFalse);
    expect(state.connected, isFalse);
    await state.confirmReader();
    await tester.pumpAndSettle();
    expect(state.connected, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'USB requires confirmation, remembers correction across screens',
    (tester) async {
      final choices = MemoryChoices();
      Future<void> open() async {
        await tester.pumpWidget(
          BrizfiApp(
            home: PocScreen(
              readerPreferences: choices,
              usbTransfer: IdentityUsb(),
              enableUsb: true,
              receiveShares: false,
              loadAddresses: () async => [],
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(PocScreen));
        state.changeMode(TransferMode.usb);
        await tester.pumpAndSettle();
      }

      await open();
      dynamic state = tester.state(find.byType(PocScreen));
      expect(state.chosenBrand, ReaderBrand.kindle);
      expect(state.connected, isFalse);
      expect(find.text('Model: Other'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('reader-brand-other')),
      );
      await tester.tap(find.byKey(const ValueKey('reader-brand-other')));
      await tester.pumpAndSettle();
      await state.confirmReader();
      await tester.pumpAndSettle();
      expect(choices.saved['usb:test'], ReaderBrand.other);
      expect(
        state.connected,
        isTrue,
        reason: 'Other does not block connection to a file-capable USB device',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await open();
      state = tester.state(find.byType(PocScreen));
      expect(state.chosenBrand, ReaderBrand.other);
      expect(state.readerConfirmed, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('Wi-Fi correction and code approval reachable at $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final choices = MemoryChoices();
      final server = JourneyServer()
        ..readerIdentity = const ReaderIdentity(
          'wifi:test',
          ReaderBrand.kindle,
        );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            fontFamily: 'ReaderQA',
            brightness: scale == 2 ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: boundary, child: child),
          ),
          home: PocScreen(
            server: server,
            readerPreferences: choices,
            enableUsb: false,
            receiveShares: false,
            loadAddresses: () async => [InternetAddress.loopbackIPv4],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Модель: Другой'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('reader-brand-nook')),
      );
      await tester.tap(find.byKey(const ValueKey('reader-brand-nook')));
      await tester.pumpAndSettle();
      if (scale == 1) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await Directory('build/reader-identification')
              .create(recursive: true);
          await File('build/reader-identification/brand-selection.png')
              .writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.ensureVisible(find.byKey(const ValueKey('approve-pairing')));
      await tester.pumpAndSettle();
      if (scale == 1) {
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await Directory('build/reader-identification')
              .create(recursive: true);
          await File('build/reader-identification/wifi-confirmation.png')
              .writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const ValueKey('approve-pairing')));
      await tester.pumpAndSettle();
      expect(server.paired, isTrue);
      expect(choices.saved['wifi:test'], ReaderBrand.nook);
      expect(tester.takeException(), isNull);
      // A remembered choice never skips the pairing-code check.
      server.revokePairing();
      await tester.pumpAndSettle();
      expect(server.paired, isFalse);
      expect(find.byKey(const ValueKey('approve-pairing')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
