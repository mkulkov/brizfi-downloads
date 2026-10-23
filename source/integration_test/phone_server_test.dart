import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Phone UI and HTTP byte transport smoke (synthetic, not a book)',
    (tester) async {
      await tester.pumpWidget(const BrizfiApp());
      await tester.pumpAndSettle();
      expect(find.text('BRIZFI'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());

      final root = await Directory.systemTemp.createTemp('brizfi-device-test-');
      final bytes = Uint8List(1024);
      bytes.setRange(60, 68, ascii.encode('BOOKMOBI'));
      bytes[77] = 1;
      bytes[81] = 86;
      for (var i = 86; i < bytes.length; i++) {
        bytes[i] = i % 251;
      }
      final source = await File('${root.path}/synthetic.azw3')
          .writeAsBytes(bytes);
      final server = ReaderServer(temporaryRoot: root);
      final client = HttpClient();
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        final address = interfaces.expand((i) => i.addresses).firstWhere((a) {
          final b = a.rawAddress;
          return b[0] == 10 ||
              (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
              (b[0] == 192 && b[1] == 168);
        });
        await server.start(address: address, source: source, port: 0);
        Future<HttpClientResponse> get(String path, {String? cookie}) async {
          final request = await client.getUrl(server.url!.resolve(path));
          if (cookie != null) {
            request.headers.set(HttpHeaders.cookieHeader, cookie);
          }
          return request.close();
        }

        final denied = await get('/download');
        expect(denied.statusCode, HttpStatus.forbidden);
        await denied.drain<void>();
        final page = await get('/');
        final cookie = page.cookies.single;
        await page.drain<void>();
        final pair = await client.postUrl(server.url!.resolve('/pair'));
        pair.followRedirects = false;
        pair.headers.set(
          HttpHeaders.cookieHeader,
          '${cookie.name}=${cookie.value}',
        );
        pair.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        final form = utf8.encode('code=${cookie.value}');
        pair.contentLength = form.length;
        pair.add(form);
        final pending = await pair.close();
        expect(pending.statusCode, HttpStatus.seeOther);
        await pending.drain<void>();
        expect(server.pendingPairing, isTrue);
        server.approvePairing();
        final download = await get(
          '/download',
          cookie: '${cookie.name}=${cookie.value}',
        );
        expect(download.statusCode, HttpStatus.ok);
        final received = await download.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        expect(received, bytes);
        expect(await source.readAsBytes(), bytes);
        await server.stop();
        expect(server.url, isNull);
      } finally {
        client.close(force: true);
        await server.stop();
        server.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
