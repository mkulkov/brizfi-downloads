import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brizfi/services/reader_server.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic PalmDB structure, not a readable Kindle book.
Uint8List fixture([int size = 1024]) {
  final bytes = Uint8List(size);
  bytes.setRange(60, 68, ascii.encode('BOOKMOBI'));
  bytes[77] = 1;
  bytes[81] = 86;
  for (var i = 86; i < size; i++) {
    bytes[i] = i % 251;
  }
  return bytes;
}

class HeldSource implements File {
  HeldSource(this.file);
  final File file;
  final reading = Completer<void>();
  final release = Completer<void>();
  @override
  Uri get uri => file.uri;
  @override
  Future<int> length() => file.length();
  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    reading.complete();
    await release.future;
    yield* file.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Reply {
  Reply(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final List<int> bytes;
  String get text => utf8.decode(bytes);
}

void main() {
  late Directory root;
  late Directory copies;
  late ReaderServer server;
  late HttpClient client;
  late File first;
  late File second;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('brizfi-live-http-test-');
    copies = await Directory('${root.path}/copies').create();
    first = await File('${root.path}/first.azw3').writeAsBytes(fixture());
    second = await File('${root.path}/Вторая & книга.azw3')
        .writeAsBytes(fixture(2048));
    now = DateTime.utc(2026, 10, 9);
    server = ReaderServer(clock: () => now, temporaryRoot: copies);
    client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    await server.startPage(address: InternetAddress.loopbackIPv4, port: 0);
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    server.dispose();
    await root.delete(recursive: true);
  });

  Future<Reply> request(
    String path, {
    String? cookie,
    String method = 'GET',
    String? body,
    String? range,
  }) async {
    final req = await client.openUrl(method, server.url!.resolve(path));
    req.followRedirects = false;
    if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    if (body != null) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      req.headers.set('Origin', server.url!.origin);
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    final bytes = await res.fold<List<int>>(
      [],
      (list, chunk) => list..addAll(chunk),
    );
    return Reply(res.statusCode, res.headers, bytes);
  }

  Future<String> pair({bool approve = true}) async {
    final page = await request('/');
    final cookie = page.headers
        .value(HttpHeaders.setCookieHeader)!
        .split(';')
        .first;
    expect(
      (await request(
        '/pair',
        cookie: cookie,
        method: 'POST',
        body: 'code=${cookie.split('=').last}',
      )).status,
      HttpStatus.seeOther,
    );
    if (approve) server.approvePairing();
    return cookie;
  }

  Future<int> managedCopies() async =>
      Directory('${copies.path}/brizfi-transfer-cache')
          .list(followLinks: false)
          .where((entry) => entry is Directory)
          .length;

  Future<void> waitForTransfer() async {
    if (!server.isTransferring) return;
    final done = Completer<void>();
    void listen() {
      if (!server.isTransferring && !done.isCompleted) done.complete();
    }

    server.addListener(listen);
    try {
      await done.future.timeout(const Duration(seconds: 5));
    } finally {
      server.removeListener(listen);
    }
  }

  test(
    'empty page permits private pairing with harmless localized waiting',
    () async {
      for (final locale in ['en', 'ru']) {
        await server.stop();
        await server.startPage(
          address: InternetAddress.loopbackIPv4,
          port: 0,
          languageCode: locale,
        );
        expect(server.isRunning, isTrue);
        expect(server.bookCount, 0);
        expect(await managedCopies(), 0);
        expect((await request('/status')).status, HttpStatus.forbidden);
        expect((await request('/download')).status, HttpStatus.forbidden);
        final cookie = await pair();
        final page = await request('/', cookie: cookie);
        expect(page.status, HttpStatus.ok);
        expect(page.text, contains('<html lang="$locale">'));
        expect(page.text, isNot(contains('id="download-all"')));
        expect(page.text, isNot(contains('href="/download')));
        expect(page.text, isNot(contains('iframe')));
        expect(
          page.headers.value('Content-Security-Policy'),
          isNot(contains('unsafe-inline')),
        );
        expect(
          (await request('/download', cookie: cookie)).status,
          HttpStatus.notFound,
        );
        final status =
            jsonDecode((await request('/status', cookie: cookie)).text) as Map;
        expect(status['books'], isEmpty);
        expect(status['booksRevision'], 0);
        expect(status['fileLength'], 0);
        expect(status['transferred'], isFalse);
      }
    },
  );

  test(
    'updates preserve URL cookie code and reset only batch progress',
    () async {
      final cookie = await pair();
      final url = server.url;
      final code = server.pairingCode;
      await server.updateBooks([first]);
      expect(server.booksRevision, 1);
      expect((await request('/download', cookie: cookie)).bytes, fixture());
      await waitForTransfer();
      expect(server.transferred, isTrue);
      await server.updateBooks([second, first]);
      expect(server.url, url);
      expect(server.pairingCode, code);
      expect(server.paired, isTrue);
      expect(server.booksRevision, 2);
      expect(server.sentBytes, 0);
      expect(server.completedBooks, 0);
      expect(server.transferred, isFalse);
      expect(await managedCopies(), 1);
      final page = await request('/', cookie: cookie);
      expect(page.headers.value(HttpHeaders.setCookieHeader), isNull);
      expect(page.text, contains('Вторая &amp; книга.azw3'));
      expect(page.text, contains('href="/download/1"'));
      final head = await request('/download/0', cookie: cookie, method: 'HEAD');
      expect(head.headers.contentLength, 2048);
      expect(
        head.headers.contentType!.mimeType,
        'application/vnd.amazon.mobi8-ebook',
      );
      expect(
        head.headers.value('Content-Disposition'),
        contains("filename*=UTF-8''"),
      );
      final range = await request(
        '/download/0',
        cookie: cookie,
        range: 'bytes=86-95',
      );
      expect(range.status, HttpStatus.partialContent);
      expect(range.bytes, fixture(2048).sublist(86, 96));
      await waitForTransfer();
      expect(
        (await request('/download/0', cookie: cookie)).bytes,
        fixture(2048),
      );
      await waitForTransfer();
      await server.updateBooks([]);
      expect(server.booksRevision, 3);
      expect(server.bookCount, 0);
      expect(server.fileLength, 0);
      expect(server.sentBytes, 0);
      expect(server.transferred, isFalse);
      expect(server.paired, isTrue);
      expect(await managedCopies(), 0);
      expect(await first.readAsBytes(), fixture());
      expect(await second.readAsBytes(), fixture(2048));
      await server.stop();
      await server.startPage(address: InternetAddress.loopbackIPv4, port: 0);
      expect(server.booksRevision, 3);
      await server.updateBooks([first]);
      expect(server.booksRevision, 4);
    },
  );

  test(
    'invalid batch and quota failure retain previous authorized bytes',
    () async {
      final cookie = await pair();
      await server.updateBooks([first]);
      final invalid = await File('${root.path}/invalid.azw3')
          .writeAsBytes(List.filled(1024, 0));
      await expectLater(
        server.updateBooks([second, invalid]),
        throwsFormatException,
      );
      await expectLater(
        server.updateBooks(List.filled(11, first)),
        throwsA(isA<TransferStorageFailure>()),
      );
      final huge = await File('${root.path}/large.azw3')
          .writeAsBytes(fixture(ReaderServer.maxFileBytes));
      await expectLater(
        server.updateBooks(List.filled(3, huge)),
        throwsA(
          isA<TransferStorageFailure>().having(
            (e) => e.code,
            'code',
            'cache_full',
          ),
        ),
      );
      expect(server.booksRevision, 1);
      expect(server.bookCount, 1);
      expect(server.paired, isTrue);
      expect(await managedCopies(), 1);
      expect((await request('/download', cookie: cookie)).bytes, fixture());
      expect(await invalid.exists(), isTrue);
      expect(await huge.length(), ReaderServer.maxFileBytes);
    },
  );

  test(
    'preparation blocks downloads and overlapping updates atomically',
    () async {
      final cookie = await pair();
      await server.updateBooks([first]);
      final held = HeldSource(second);
      final inputs = <File>[held];
      final updating = server.updateBooks(inputs);
      await held.reading.future;
      inputs.clear();
      try {
        expect(await managedCopies(), 2);
        expect(server.bookCount, 1);
        expect(server.booksRevision, 1);
        expect(
          (await request('/download', cookie: cookie)).status,
          HttpStatus.conflict,
        );
        expect(
          (await request('/download', cookie: cookie, method: 'HEAD')).status,
          HttpStatus.conflict,
        );
        await expectLater(server.updateBooks([]), throwsStateError);
        final status =
            jsonDecode((await request('/status', cookie: cookie)).text) as Map;
        expect(status['booksRevision'], 1);
        expect(status['fileLength'], 1024);
      } finally {
        held.release.complete();
        await updating;
      }
      expect(server.booksRevision, 2);
      expect(server.fileLength, 2048);
      expect(await managedCopies(), 1);
      expect((await request('/download', cookie: cookie)).bytes, fixture(2048));
    },
  );

  test('active download rejects replacement until stream closes', () async {
    await first.writeAsBytes(fixture(ReaderServer.maxFileBytes));
    await server.updateBooks([first]);
    final cookie = await pair();
    final req = await client.getUrl(server.url!.resolve('/download'));
    req.headers.set(HttpHeaders.cookieHeader, cookie);
    final response = await req.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(server.isTransferring, isTrue);
    await expectLater(server.updateBooks([second]), throwsStateError);
    expect(await managedCopies(), 1);
    expect(server.booksRevision, 1);
    expect(
      (await request('/download', cookie: cookie)).status,
      HttpStatus.conflict,
    );
    await response.drain<void>();
    await waitForTransfer();
    await server.updateBooks([second]);
    expect(server.booksRevision, 2);
    expect((await request('/download', cookie: cookie)).bytes, fixture(2048));
  });

  test('stop during preparation rolls back both managed sets and preserves sources', () async {
    await server.updateBooks([first]);
    final held = HeldSource(second);
    final updating = server.updateBooks([held]);
    final rejected = expectLater(updating, throwsStateError);
    await held.reading.future;
    final stopping = server.stop();
    expect(await managedCopies(), 2);
    held.release.complete();
    await Future.wait([rejected, stopping]);
    expect(server.isRunning, isFalse);
    expect(server.bookCount, 0);
    expect(await managedCopies(), 0);
    expect(await first.readAsBytes(), fixture());
    expect(await second.readAsBytes(), fixture(2048));
  });

  test(
    'updating preserves pending approval and never extends session TTL',
    () async {
      final cookie = await pair(approve: false);
      final code = server.pairingCode;
      await server.updateBooks([first]);
      expect(server.pendingPairing, isTrue);
      expect(server.pairingCode, code);
      expect(
        (await request('/download', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
      server.approvePairing();
      now = now.add(const Duration(minutes: 14));
      await server.updateBooks([second]);
      now = now.add(const Duration(minutes: 1));
      expect(server.isRunning, isFalse);
      expect(server.paired, isFalse);
      await expectLater(server.updateBooks([first]), throwsStateError);
      await server.stop();
      expect(await managedCopies(), 0);
    },
  );

  test('empty startup reaps expired owned batches but leaves unrelated entries', () async {
    await server.stop();
    final cache = Directory('${copies.path}/brizfi-transfer-cache');
    for (final name in ['job-owned', 'job-unrelated']) {
      final dir = await Directory('${cache.path}/$name').create();
      await File('${dir.path}/.brizfi-owned').writeAsString(
        'brizfi-transfer-v1\n${now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch}\n',
      );
      await File('${dir.path}/book-0.azw3').writeAsBytes(fixture());
      await File('${dir.path}/book-1.azw3').writeAsBytes(fixture());
      if (name == 'job-unrelated') {
        for (var i = 2; i < ReaderServer.maxBooks; i++) {
          await File('${dir.path}/book-$i.azw3').writeAsBytes(fixture());
        }
        await File('${dir.path}/book.azw3').writeAsBytes(fixture());
        await File('${dir.path}/private.txt').writeAsString('keep');
      }
    }
    await server.startPage(address: InternetAddress.loopbackIPv4, port: 0);
    expect(await Directory('${cache.path}/job-owned').exists(), isFalse);
    expect(
      await File('${cache.path}/job-unrelated/private.txt').readAsString(),
      'keep',
    );
  });
}
