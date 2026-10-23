import 'dart:io';
import 'dart:ui' as ui;

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:brizfi/ui/brizfi_style.dart';
import 'package:brizfi/ui/journey_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class JourneyServer extends ReaderServer {
  Uri? active;
  bool approved = false;
  bool requested = true;
  bool complete = false;
  bool downloading = false;
  List<File> published = [];
  @override
  Uri? get url => active;
  @override
  bool get paired => approved && active != null;
  @override
  bool get pendingPairing => requested && active != null;
  @override
  String? get pairingCode => active == null ? null : '482';
  @override
  bool get transferred => complete;
  @override
  bool get isTransferring => downloading;
  int get activeIndex => published.length > 1 ? 1 : 0;
  @override
  int get completedBooks => complete
      ? published.length
      : downloading
      ? activeIndex
      : 0;
  @override
  List<BookDeliveryStatus> get deliveryStatus => [
    for (var i = 0; i < published.length; i++)
      BookDeliveryStatus(
        published[i].uri.pathSegments.last,
        100,
        complete || (downloading && i < activeIndex)
            ? 100
            : downloading && i == activeIndex
            ? 54
            : 0,
        complete || (downloading && i < activeIndex),
        downloading && i == activeIndex,
      ),
  ];
  @override
  void approvePairing() {
    approved = true;
    requested = false;
    notifyListeners();
  }

  @override
  void revokePairing() {
    approved = false;
    requested = true;
    notifyListeners();
  }

  void finish() {
    complete = true;
    downloading = false;
    notifyListeners();
  }

  @override
  Future<void> startPage({
    required InternetAddress address,
    int port = 8080,
    String languageCode = 'en',
  }) async {
    active = Uri.parse('http://192.168.1.12:8080/');
    notifyListeners();
  }

  @override
  Future<void> updateBooks(List<File> sources) async {
    published = List.of(sources);
    complete = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    active = null;
    approved = false;
    notifyListeners();
  }
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  const importer = MethodChannel('ru.mkulkov.brizfi/import');
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0, 3.2]) {
      for (final locale in ['ru', 'en']) {
        testWidgets('guided parcel $brightness $locale at $scale', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(360, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final server = JourneyServer();
          final strings = lookupAppLocalizations(Locale(locale));
          final semantics = tester.ensureSemantics();
          var picks = 0;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            importer,
            (call) async {
              if (call.method == 'pickBooks') {
                return [picks++ == 0 ? 'first.azw3' : 'second.azw3'];
              }
              return null;
            },
          );
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: brizfiTheme(brightness),
                locale: Locale(locale),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: RepaintBoundary(
                  key: const ValueKey('capture'),
                  child: PocScreen(
                    server: server,
                    loadAddresses: () async => [
                      InternetAddress('192.168.1.12'),
                    ],
                    receiveShares: false,
                    enableUsb: false,
                    allowMultiple: true,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(strings.journeyConnect), findsOneWidget);
            final illustrationSize = tester.getSize(
              find.byType(JourneyIllustration),
            );
            expect(illustrationSize.height, 140);
            final illustrationRect = tester.getRect(
              find.byType(JourneyIllustration),
            );
            final actionBottom = tester
                .getRect(find.byKey(const ValueKey('journey-action')))
                .bottom;
            void expectAnchors() {
              expect(
                tester.getRect(find.byType(JourneyIllustration)),
                illustrationRect,
              );
              expect(
                tester
                    .getRect(find.byKey(const ValueKey('journey-action')))
                    .bottom,
                actionBottom,
              );
            }

            await tester.ensureVisible(find.text(strings.journeyChooseReason));
            expect(
              tester.getRect(find.text(strings.journeyChooseReason)).bottom,
              lessThan(tester.getRect(find.text(strings.journeyContinue)).top),
            );
            expect(find.byKey(const ValueKey('pick-books')), findsNothing);
            expect(server.published, isEmpty);
            expect(
              find.bySemanticsLabel(strings.pairingCodeSpoken('4 8 2')),
              findsOneWidget,
            );
            await tapText(tester, strings.journeyApprove);
            expectAnchors();
            await tapText(tester, strings.journeyContinue);
            expectAnchors();
            expect(find.text(strings.journeyChoose), findsOneWidget);
            expect(
              tester.getSize(find.byType(JourneyIllustration)),
              illustrationSize,
            );
            await tapText(tester, strings.journeyAdd);
            await tapText(tester, strings.journeyAdd);
            expect(find.text('first.azw3'), findsOneWidget);
            expect(find.text('second.azw3'), findsOneWidget);
            expect(
              server.published,
              isEmpty,
              reason: 'Selection must not publish before Send',
            );
            final remove = find.byTooltip(strings.removeOneBook).last;
            await tester.ensureVisible(remove);
            expectAnchors();
            await tester.tap(remove);
            await tester.pumpAndSettle();
            expect(find.text('second.azw3'), findsNothing);
            await tapText(tester, strings.journeySend);
            expect(server.published.single.path, 'first.azw3');
            expect(find.text(strings.journeySending), findsOneWidget);
            expectAnchors();
            expect(
              tester.getSize(find.byType(JourneyIllustration)),
              illustrationSize,
            );
            expect(find.text(strings.journeyDone), findsNothing);
            server.downloading = true;
            server.notifyListeners();
            await tester.pumpAndSettle();
            expect(find.text('54%'), findsOneWidget);
            server.finish();
            await tester.pumpAndSettle();
            expect(find.text(strings.journeyDone), findsOneWidget);
            expectAnchors();
            expect(find.text(strings.journeyEnd), findsNothing);
            expect(
              tester.getSize(find.byType(JourneyIllustration)),
              illustrationSize,
            );
            expect(find.text(strings.journeyCheckLibrary), findsOneWidget);
            await tapText(tester, strings.journeyAgain);
            expect(server.approved, isTrue);
            expect(server.published, isEmpty);
            expect(find.text('first.azw3'), findsNothing);
            expect(find.text(strings.journeyChoose), findsOneWidget);
            server.revokePairing();
            await tester.pumpAndSettle();
            expect(find.text(strings.journeyConnect), findsOneWidget);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            semantics.dispose();
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              importer,
              null,
            );
          }
        });
      }
    }
  }

  testWidgets('capture all four real Flutter screens', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_JOURNEY')) return;
    await tester.runAsync(() async {
      final font = File('C:/Windows/Fonts/segoeui.ttf');
      if (await font.exists()) {
        final loader = FontLoader('Roboto')
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    tester.view.physicalSize = const Size(400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final server = JourneyServer();
    final key = GlobalKey();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      importer,
      (call) async => call.method == 'pickBooks'
          ? ['Маленький принц.azw3', 'Рассказы.azw3', 'Путешествие.azw3']
          : null,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: brizfiTheme(Brightness.light),
          darkTheme: brizfiTheme(Brightness.dark),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RepaintBoundary(
            key: key,
            child: PocScreen(
              server: server,
              receiveShares: false,
              enableUsb: true,
              allowMultiple: true,
              loadAddresses: () async => [InternetAddress('192.168.1.12')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(int stage, {String? name}) async {
        await tester.runAsync(() async {
          await precacheImage(
            AssetImage('assets/illustrations/journey-$stage.png'),
            key.currentContext!,
          );
        });
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(() => boundary.toImage()))!;
        final bytes = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.png),
        );
        await tester.runAsync(() async {
          await Directory('artifacts/journey').create(recursive: true);
          await File('artifacts/journey/${name ?? 'stage-$stage'}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
        image.dispose();
      }

      await capture(0);
      await tapText(tester, 'Код совпадает');
      await tapText(tester, 'Выбрать книги');
      await tapText(tester, 'Добавить книги');
      await capture(1);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      await capture(1, name: 'selection-dark');
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
      tester.view.physicalSize = const Size(900, 1100);
      await tester.pumpAndSettle();
      await capture(1, name: 'selection-wide');
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      await capture(1, name: 'selection-compact');
      tester.view.physicalSize = const Size(400, 1100);
      await tester.pumpAndSettle();
      await tapText(tester, 'Отправить книги');
      server.downloading = true;
      server.notifyListeners();
      await tester.pumpAndSettle();
      await capture(2);
      server.finish();
      await tester.pumpAndSettle();
      await capture(3);
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
