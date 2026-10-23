import 'dart:io';
import 'dart:ui' as ui;

import 'package:brizfi/main.dart';
import 'package:brizfi/ui/journey_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'journey_screen_test.dart' show JourneyServer;
import 'journey_test_helpers.dart';

void main() {
  for (final size in [
    const Size(360, 800),
    const Size(480, 820),
    const Size(1280, 800),
  ]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0, 3.2]) {
        testWidgets('mobile appearance at $size $brightness text $scale', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final capture =
              const bool.fromEnvironment('CAPTURE_WINDOWS_UI') && scale == 1;
          if (capture) {
            await tester.runAsync(() async {
              final bytes = ByteData.sublistView(
                await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
              );
              for (final family in ['Segoe UI', 'Roboto']) {
                await (FontLoader(family)..addFont(Future.value(bytes))).load();
              }
              await (FontLoader('MaterialIcons')..addFont(
                    rootBundle.load('fonts/MaterialIcons-Regular.otf'),
                  ))
                  .load();
            });
          }
          const importer = MethodChannel('ru.mkulkov.brizfi/import');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            importer,
            (call) async =>
                call.method == 'pickBooks' ? ['BRIZFI Check.azw3'] : null,
          );
          final key = GlobalKey();
          final server = JourneyServer();
          try {
            await tester.pumpWidget(
              RepaintBoundary(
                key: key,
                child: BrizfiApp(
                  home: PocScreen(
                    server: server,
                    loadAddresses: () async => [
                      InternetAddress('192.168.1.12'),
                    ],
                    receiveShares: false,
                    enableUsb: true,
                    allowMultiple: true,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final context = tester.element(find.byType(PocScreen));
            final theme = Theme.of(context);
            expect(
              theme.scaffoldBackgroundColor,
              brightness == Brightness.light
                  ? const Color(0xFFFBF8F2)
                  : const Color(0xFF162631),
            );
            expect(theme.visualDensity, VisualDensity.standard);
            final expectedWidth = Platform.isWindows
                ? size.width.clamp(0, 520).toDouble()
                : size.width;
            expect(tester.getSize(find.byType(AppBar)).width, expectedWidth);
            final columnCenter = size.width / 2;
            expect(
              tester.getCenter(find.byType(AppBar)).dx,
              closeTo(columnCenter, .1),
            );
            expect(
              tester.getSize(find.byType(ConnectionTicket).first).height,
              greaterThanOrEqualTo(48),
            );

            Future<void> screenshot(int stage) async {
              if (!capture) return;
              await tester.runAsync(
                () => precacheImage(
                  AssetImage('assets/illustrations/journey-$stage.png'),
                  context,
                ),
              );
              await tester.pumpAndSettle();
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = (await tester.runAsync(() => boundary.toImage()))!;
              final data = await tester.runAsync(
                () => image.toByteData(format: ui.ImageByteFormat.png),
              );
              await tester.runAsync(() async {
                await Directory('artifacts/windows-ui').create(recursive: true);
                await File(
                  'artifacts/windows-ui/${size.width.toInt()}-${brightness.name}-$stage.png',
                ).writeAsBytes(data!.buffer.asUint8List());
              });
              image.dispose();
            }

            await screenshot(0);
            server.approvePairing();
            await tester.pumpAndSettle();
            await enterSelection(tester);
            await tapJourney(tester, 'Add books');
            final footer = find.byKey(const ValueKey('send-footer'));
            expect(
              tester.getRect(footer).bottom,
              lessThanOrEqualTo(size.height),
            );
            final send = find.widgetWithText(FilledButton, 'Send books');
            expect(tester.getSize(send).height, greaterThanOrEqualTo(56));
            await screenshot(1);
            expect(tester.takeException(), isNull);
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
  }
}
