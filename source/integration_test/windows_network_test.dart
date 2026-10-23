import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:brizfi/main.dart';
import 'package:brizfi/services/local_network.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows selects physical LAN with VPN active and binds there', (
    tester,
  ) async {
    const expected = String.fromEnvironment('BRIZFI_EXPECT_LAN');
    expect(Platform.isWindows, isTrue);
    expect(
      expected,
      isNotEmpty,
      reason: 'Supply the independently verified physical LAN IP',
    );
    final addresses = await LocalNetwork.addresses();
    expect(addresses.map((a) => a.address), contains(expected));
    final captureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: captureKey, child: const BrizfiApp()),
    );
    final dynamic state = tester.state(find.byType(PocScreen));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (state.server.url == null && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(state.selected.address, expected);
    final url = state.server.url as Uri;
    expect(url.host, expected);
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(url)).close();
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
    final result = {
      'nativeEligibleAddresses': addresses.map((a) => a.address).toList(),
      'selected': state.selected.address,
      'url': url.toString(),
      'httpStatus': 200,
      'scope': 'Windows native enumeration, default app selection, local HTTP; Kindle browser NOT_RUN',
    };
    const output = String.fromEnvironment('BRIZFI_NETWORK_EVIDENCE');
    if (output.isNotEmpty) {
      await File(output).writeAsString(jsonEncode(result));
      await precacheImage(
        const AssetImage('assets/illustrations/journey-0.png'),
        tester.element(find.byType(PocScreen)),
      );
      await tester.pumpAndSettle();
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    }
    // ignore: avoid_print
    print('BRIZFI_WINDOWS_NETWORK ${jsonEncode(result)}');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
