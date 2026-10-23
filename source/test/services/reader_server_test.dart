import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brizfi/services/reader_server.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic PalmDB header only: this is NOT a readable Kindle book.
Uint8List fixture([int length = 1024]) {
  final data = Uint8List(length);
  data.setRange(60, 68, ascii.encode('BOOKMOBI'));
  data[77] = 1;
  data[81] = 86;
  for (var i = 86; i < data.length; i++) {
    data[i] = i % 251;
  }
  return data;
}

class Reply {
  Reply(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final List<int> bytes;
  String get text => utf8.decode(bytes);
}

// Simulates a source changing between its stat and the streamed snapshot.
class ChangedSource implements File {
  ChangedSource(this.original);
  final File original;
  @override
  Uri get uri => original.uri;
  @override
  Future<int> length() async => 1024;
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      Stream.value(fixture(2048));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late Directory copies;
  late File source;
  late ReaderServer server;
  late HttpClient client;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('brizfi-http-test-');
    copies = await Directory('${root.path}/copies').create();
    source = await File('${root.path}/Тестовая книга.azw3')
        .writeAsBytes(fixture());
    now = DateTime.utc(2026, 10, 8);
    server = ReaderServer(clock: () => now, temporaryRoot: copies);
    client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    await server.start(
      address: InternetAddress.loopbackIPv4,
      source: source,
      port: 0,
    );
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    server.dispose();
    await root.delete(recursive: true);
  });

  Future<Reply> request(
    String path, {
    String method = 'GET',
    String? cookie,
    String? range,
    String? origin,
    String? host,
    String? body,
    String? userAgent,
    bool chunked = false,
  }) async {
    final req = await client.openUrl(method, server.url!.resolve(path));
    req.followRedirects = false;
    if (userAgent != null) {
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }
    if (cookie != null) req.headers.set(HttpHeaders.cookieHeader, cookie);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    if (origin != null) req.headers.set('Origin', origin);
    if (host != null) req.headers.set(HttpHeaders.hostHeader, host);
    if (body != null) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      final bytes = utf8.encode(body);
      if (!chunked) req.contentLength = bytes.length;
      req.add(bytes);
    }
    final response = await req.close();
    final bytes = await response.fold<List<int>>(
      [],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    return Reply(response.statusCode, response.headers, bytes);
  }

  Future<int> managedCopies() async {
    final cache = Directory('${copies.path}/brizfi-transfer-cache');
    if (!await cache.exists()) return 0;
    return cache
        .list(followLinks: false)
        .where((entry) => entry is Directory && entry.path.contains('job-'))
        .length;
  }

  Future<String> pair({bool approve = true}) async {
    final page = await request('/');
    final cookie = page.headers
        .value(HttpHeaders.setCookieHeader)!
        .split(';')
        .first;
    final code = cookie.split('=').last;
    final pending = await request(
      '/pair',
      method: 'POST',
      cookie: cookie,
      body: 'code=$code',
      origin: server.url!.origin,
    );
    expect(pending.status, HttpStatus.seeOther);
    expect(server.pendingPairing, isTrue);
    if (approve) server.approvePairing();
    return cookie;
  }

  test(
    'reader identity survives reconnect but never authorizes downloads',
    () async {
      Future<Reply> identify(String? identityCookie) async {
        final page = await request('/');
        final session = page.headers
            .value(HttpHeaders.setCookieHeader)!
            .split(';')
            .first;
        return request(
          '/pair',
          method: 'POST',
          cookie:
              '$session${identityCookie == null ? '' : '; $identityCookie'}',
          body: 'code=${session.split('=').last}',
          origin: server.url!.origin,
          userAgent: 'Mozilla/5.0 Kindle/3.0',
        );
      }

      final pending = await identify(null);
      final identity = server.readerIdentity!;
      expect(identity.brand.name, 'kindle');
      final savedCookie = pending.headers
          .value(HttpHeaders.setCookieHeader)!
          .split(';')
          .first;
      expect(
        (await request('/download', cookie: savedCookie)).status,
        HttpStatus.forbidden,
      );
      server.revokePairing();
      expect(server.readerIdentity, isNull);
      await identify(savedCookie);
      expect(server.readerIdentity!.key, identity.key);
      expect(server.paired, isFalse);
      expect(
        (await request('/download', cookie: savedCookie)).status,
        HttpStatus.forbidden,
      );
      server.revokePairing();
      await identify(null);
      expect(server.readerIdentity!.key, isNot(identity.key));
    },
  );

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
    'batch shares one approval, preserves bytes and counts each completed file',
    () async {
      final second = await File('${root.path}/Вторая & книга.azw3')
          .writeAsBytes(fixture(2048));
      await server.stop();
      await server.startBatch(
        address: InternetAddress.loopbackIPv4,
        sources: [source, second],
        port: 0,
      );
      expect(server.bookCount, 2);
      expect(server.fileLength, 3072);
      expect((await request('/download/1')).status, HttpStatus.forbidden);
      final unpaired = await request('/');
      expect(unpaired.text, isNot(contains('id="download-all"')));
      final cookie = await pair();
      final page = await request('/', cookie: cookie);
      expect(page.text, contains('href="/download/0"'));
      expect(page.text, contains('href="/download/1"'));
      expect(page.text, contains('Вторая &amp; книга.azw3'));
      expect(page.text, contains('id="download-all"'));
      expect(page.text, contains('id="book-completed-0" role="status" hidden'));
      expect(page.text, contains('target="brizfi-download"'));
      expect(page.text, contains('name="brizfi-download"'));
      expect(page.text, contains('Download all books'));
      expect(page.text, isNot(contains('Скачать весь набор')));
      final nonce = RegExp(r'<script nonce="([^"]+)">')
          .firstMatch(page.text)![1];
      final policy = page.headers.value('Content-Security-Policy')!;
      expect(policy, contains("script-src 'nonce-$nonce'"));
      expect(policy, contains("style-src 'nonce-$nonce'"));
      expect(policy, contains("connect-src 'self'"));
      expect(policy, contains("frame-src 'self'"));
      expect(policy, isNot(contains('unsafe-inline')));
      final head = await request('/download/1', method: 'HEAD', cookie: cookie);
      expect(head.headers.contentLength, 2048);
      expect(
        head.headers.value('Content-Security-Policy'),
        contains("frame-ancestors 'self'"),
      );
      final range = await request(
        '/download/1',
        range: 'bytes=0-3',
        cookie: cookie,
      );
      expect(
        range.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-3/2048',
      );
      expect(server.completedBooks, 0);
      expect(
        (await request('/download/1', cookie: cookie)).bytes,
        fixture(2048),
      );
      await waitForTransfer();
      expect(server.completedBooks, 1);
      expect(server.transferred, isFalse);
      final partialPage = (await request('/', cookie: cookie)).text;
      expect(
        partialPage,
        contains('id="book-completed-0" role="status" hidden'),
      );
      expect(partialPage, contains('id="book-completed-1" role="status">'));
      expect((await request('/download/0', cookie: cookie)).bytes, fixture());
      await waitForTransfer();
      expect(server.completedBooks, 2);
      expect(server.transferred, isTrue);
      expect(server.sentBytes, 3072);
      final completedPage = (await request('/', cookie: cookie)).text;
      expect(completedPage, contains('id="book-completed-0" role="status">'));
      expect(completedPage, contains('id="book-completed-1" role="status">'));
      // Retry is idempotent for the completed-book count.
      await request('/download/1', cookie: cookie);
      await waitForTransfer();
      expect(server.completedBooks, 2);
      expect(server.sentBytes, 3072);
      final status =
          jsonDecode((await request('/status', cookie: cookie)).text) as Map;
      expect((status['books'] as List).length, 2);
      for (final path in [
        '/download/2',
        '/download/01',
        '/download/-1',
        '/download/1?file=private',
      ]) {
        expect(
          (await request(path, cookie: cookie)).status,
          HttpStatus.notFound,
        );
      }
      await server.stop();
      expect(await managedCopies(), 0);
      expect(await source.readAsBytes(), fixture());
      expect(await second.readAsBytes(), fixture(2048));
    },
  );

  test(
    'invalid batch rolls back all copies and never opens a partial session',
    () async {
      final broken = await File('${root.path}/broken.azw3')
          .writeAsBytes(List.filled(1024, 0));
      await server.stop();
      await expectLater(
        server.startBatch(
          address: InternetAddress.loopbackIPv4,
          sources: [source, broken],
          port: 0,
        ),
        throwsFormatException,
      );
      expect(server.url, isNull);
      expect(server.bookCount, 0);
      expect(await managedCopies(), 0);
      expect(await source.exists(), isTrue);
      expect(await broken.exists(), isTrue);
      await expectLater(
        server.startBatch(
          address: InternetAddress.loopbackIPv4,
          sources: List.filled(11, source),
          port: 0,
        ),
        throwsA(
          isA<TransferStorageFailure>().having(
            (e) => e.code,
            'code',
            'batch_limit',
          ),
        ),
      );
      expect(await managedCopies(), 0);
    },
  );

  test('batch duplicate filenames have distinct download names without changing bytes', () async {
    final otherDirectory = await Directory('${root.path}/other').create();
    final second = await File(
      '${otherDirectory.path}/${source.uri.pathSegments.last}',
    ).writeAsBytes(fixture(2048));
    await server.stop();
    await server.startBatch(
      address: InternetAddress.loopbackIPv4,
      sources: [source, second],
      port: 0,
    );
    final cookie = await pair();
    final first = await request('/download/0', cookie: cookie);
    await waitForTransfer();
    final other = await request('/download/1', cookie: cookie);
    await waitForTransfer();
    expect(
      first.headers.value('Content-Disposition'),
      isNot(other.headers.value('Content-Disposition')),
    );
    expect(first.bytes, fixture());
    expect(other.bytes, fixture(2048));
  });

  test(
    'bounded chunked pairing form works and still requires phone approval',
    () async {
      final page = await request('/');
      final cookie = page.headers
          .value(HttpHeaders.setCookieHeader)!
          .split(';')
          .first;
      final code = cookie.split('=').last;
      final reply = await request(
        '/pair',
        method: 'POST',
        cookie: cookie,
        body: 'code=$code',
        chunked: true,
        origin: server.url!.origin,
      );
      expect(reply.status, HttpStatus.seeOther);
      expect(server.pendingPairing, isTrue);
      expect(server.paired, isFalse);
      expect(
        (await request('/download', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
    },
  );

  test(
    'chunked pairing rejects oversized bodies and forged challenges',
    () async {
      final page = await request('/');
      final cookie = page.headers
          .value(HttpHeaders.setCookieHeader)!
          .split(';')
          .first;
      expect(
        (await request(
          '/pair',
          method: 'POST',
          cookie: cookie,
          body: 'code=${'x' * 129}',
          chunked: true,
        )).status,
        HttpStatus.requestEntityTooLarge,
      );
      expect(
        (await request(
          '/pair',
          method: 'POST',
          cookie: cookie,
          body: 'code=forged',
          chunked: true,
        )).status,
        HttpStatus.forbidden,
      );
      expect(server.pendingPairing, isFalse);
    },
  );

  for (final method in ['GET', 'HEAD']) {
    test('$method probe preserves the visible pairing form', () async {
      final initial = await request('/');
      final cookie = initial.headers
          .value(HttpHeaders.setCookieHeader)!
          .split(';')
          .first;
      final token = cookie.split('=').last;
      final probe = await request('/', method: method, cookie: cookie);
      expect(probe.status, HttpStatus.ok);
      expect(probe.headers.value(HttpHeaders.setCookieHeader), isNull);
      if (method == 'GET') expect(probe.text, contains('value="$token"'));
      expect(
        (await request(
          '/pair',
          method: 'POST',
          cookie: cookie,
          body: 'code=$token',
        )).status,
        HttpStatus.seeOther,
      );
      expect(server.pendingPairing, isTrue);
      expect(server.pairingCode, matches(RegExp(r'^\d{3}$')));
      expect(server.paired, isFalse);
      expect(
        (await request('/download', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
    });
  }

  test('anonymous HEAD does not overwrite a visible form cookie', () async {
    final initial = await request('/');
    final cookie = initial.headers
        .value(HttpHeaders.setCookieHeader)!
        .split(';')
        .first;
    final probe = await request('/', method: 'HEAD');
    expect(probe.headers.value(HttpHeaders.setCookieHeader), isNull);
    expect(probe.bytes, isEmpty);
    expect(
      (await request(
        '/pair',
        method: 'POST',
        cookie: cookie,
        body: 'code=${cookie.split('=').last}',
      )).status,
      HttpStatus.seeOther,
    );
    expect(server.pendingPairing, isTrue);
  });

  for (final stale in ['expired', 'restart', 'missing cookie']) {
    test(
      'stale pairing $stale returns to fresh page without granting access',
      () async {
        final oldPage = await request('/');
        final oldCookie = oldPage.headers
            .value(HttpHeaders.setCookieHeader)!
            .split(';')
            .first;
        final oldToken = oldCookie.substring(oldCookie.indexOf('=') + 1);
        if (stale == 'expired') now = now.add(const Duration(minutes: 2));
        if (stale == 'restart') {
          await server.stop();
          await server.start(
            address: InternetAddress.loopbackIPv4,
            source: source,
            port: 0,
          );
        }
        final redirected = await request(
          '/pair',
          method: 'POST',
          cookie: stale == 'missing cookie' ? null : oldCookie,
          origin: server.url!.origin,
          body: 'code=$oldToken',
        );
        expect(redirected.status, HttpStatus.seeOther);
        expect(redirected.headers.value(HttpHeaders.locationHeader), '/');
        expect(server.pendingPairing, isFalse);
        expect(server.paired, isFalse);
        expect(
          (await request('/download', cookie: oldCookie)).status,
          HttpStatus.forbidden,
        );
        final fresh = await request('/');
        final cookie = fresh.headers
            .value(HttpHeaders.setCookieHeader)!
            .split(';')
            .first;
        expect(cookie, isNot(oldCookie));
        final token = cookie.substring(cookie.indexOf('=') + 1);
        expect(
          (await request(
            '/pair',
            method: 'POST',
            cookie: cookie,
            origin: server.url!.origin,
            body: 'code=$token',
          )).status,
          HttpStatus.seeOther,
        );
        expect(server.pendingPairing, isTrue);
        expect(server.paired, isFalse);
        expect(
          (await request('/download', cookie: cookie)).status,
          HttpStatus.forbidden,
        );
      },
    );
  }
  test(
    'repeated pairing form preserves pending code and still needs approval',
    () async {
      final cookie = await pair(approve: false);
      final code = server.pairingCode;
      final token = cookie.substring(cookie.indexOf('=') + 1);
      final repeated = await request(
        '/pair',
        method: 'POST',
        cookie: cookie,
        origin: server.url!.origin,
        body: 'code=$token',
      );
      expect(repeated.status, HttpStatus.seeOther);
      expect(server.pairingCode, code);
      expect(server.paired, isFalse);
      expect(
        (await request('/download', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
    },
  );

  test(
    'opaque browser origin is diagnosed without echoing private request data',
    () async {
      final reply = await request(
        '/pair',
        method: 'POST',
        origin: 'null',
        body: 'code=private',
      );
      expect(reply.status, HttpStatus.forbidden);
      expect(reply.text, contains('opaque_origin'));
      expect(reply.text, isNot(contains('code=private')));
      expect(server.pendingPairing, isFalse);
    },
  );

  test(
    'manual page has no external resources and pairing requires approval',
    () async {
      final page = await request('/');
      expect(page.text, contains('Connect reader'));
      expect(page.text, isNot(contains('<script')));
      expect(page.text, isNot(contains('https://')));
      expect(page.headers.value('Referrer-Policy'), 'same-origin');
      expect(
        page.headers.value(HttpHeaders.setCookieHeader),
        contains('HttpOnly; SameSite=Strict'),
      );
      expect((await request('/status')).status, HttpStatus.forbidden);
      expect((await request('/download')).status, HttpStatus.forbidden);
      final cookie = await pair(approve: false);
      expect(server.paired, isFalse);
      expect(
        (await request('/download', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
      server.approvePairing();
      expect(server.paired, isTrue);
      expect(
        (await request('/', cookie: cookie)).text,
        contains('Download book'),
      );
      expect((await request('/status', cookie: cookie)).status, HttpStatus.ok);
    },
  );

  test(
    'one localized page retains private pairing and download states',
    () async {
      await server.stop();
      await server.start(
        address: InternetAddress.loopbackIPv4,
        source: source,
        port: 0,
        languageCode: 'ru-RU',
      );
      final initial = await request('/');
      expect(initial.text, contains('<html lang="ru">'));
      expect(initial.text, contains('Подключить ридер'));
      expect(initial.text, isNot(contains(source.uri.pathSegments.last)));
      final styleNonce = RegExp(r'<style nonce="([^"]+)">')
          .firstMatch(initial.text)![1];
      expect(
        initial.headers.value('Content-Security-Policy'),
        contains("style-src 'nonce-$styleNonce'"),
      );
      expect(initial.text, isNot(contains('style="')));
      final cookie = await pair(approve: false);
      final pending = await request('/', cookie: cookie);
      expect(pending.text, contains('Сверьте код'));
      expect(pending.text, contains('id="pause-pairing"'));
      expect(pending.text, isNot(contains('href="/download')));
      expect(pending.text, isNot(contains(source.uri.pathSegments.last)));
      expect(jsonDecode((await request('/pair-status', cookie: cookie)).text), {
        'state': 'pending',
      });
      expect((await request('/pair-status')).status, HttpStatus.forbidden);
      expect(
        (await request(
          '/pair-status',
          cookie: 'brizfi_session=${server.pairingCode}',
        )).status,
        HttpStatus.forbidden,
      );
      server.approvePairing();
      expect(jsonDecode((await request('/pair-status', cookie: cookie)).text), {
        'state': 'approved',
      });
      final ready = await request('/', cookie: cookie);
      expect(ready.text, contains('Можно скачивать'));
      expect(ready.text, contains('Скачать книгу'));
      expect(ready.text, contains(source.uri.pathSegments.last));
      expect(ready.text, isNot(contains('pause-pairing')));
      expect(ready.text, isNot(contains('Download book')));
      server.revokePairing();
      expect(
        (await request('/pair-status', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
    },
  );

  test(
    'localized batch messages use phone locale and fallback to English',
    () async {
      final second = await File('${root.path}/Second.azw3')
          .writeAsBytes(fixture());
      for (final locale in ['ru', 'en', 'de']) {
        await server.stop();
        await server.startBatch(
          address: InternetAddress.loopbackIPv4,
          sources: [source, second],
          port: 0,
          languageCode: locale,
        );
        final cookie = await pair();
        final page = await request('/', cookie: cookie);
        expect(
          page.text,
          contains(
            locale == 'ru' ? 'Скачать весь набор' : 'Download all books',
          ),
        );
        expect(
          page.text,
          contains(
            locale == 'ru'
                ? 'data-progress="Загрузка книги {current} из {total}…"'
                : 'data-progress="Downloading book {current} of {total}…"',
          ),
        );
        expect(page.text, isNot(contains('http://')));
      }
    },
  );

  test(
    'pending status expires, rejects mutation and exposes no books',
    () async {
      final cookie = await pair(approve: false);
      final head = await request(
        '/pair-status',
        method: 'HEAD',
        cookie: cookie,
      );
      expect(head.status, HttpStatus.ok);
      expect(head.bytes, isEmpty);
      expect(
        (await request('/pair-status', method: 'POST', cookie: cookie)).status,
        HttpStatus.methodNotAllowed,
      );
      expect(
        (await request('/pair-status?token=forged', cookie: cookie)).status,
        HttpStatus.notFound,
      );
      now = now.add(const Duration(minutes: 3));
      final expired = await request('/pair-status', cookie: cookie);
      expect(expired.status, HttpStatus.forbidden);
      expect(jsonDecode(expired.text), {'state': 'expired'});
      expect(expired.text, isNot(contains('books')));
    },
  );

  test(
    'comparison code is stable and private to the pending/approved reader',
    () async {
      expect(server.pairingCode, isNull);
      expect((await request('/')).text, isNot(contains('id="pairing-code"')));
      final cookie = await pair(approve: false);
      final code = server.pairingCode!;
      expect(code, matches(RegExp(r'^[1-9][0-9]{2}$')));
      final markup = 'id="pairing-code">$code';
      expect((await request('/', cookie: cookie)).text, contains(markup));
      expect((await request('/', cookie: cookie)).text, contains(markup));
      expect((await request('/')).text, isNot(contains('id="pairing-code"')));
      expect(
        (await request('/download', cookie: 'brizfi_session=$code')).status,
        HttpStatus.forbidden,
      );
      // A second visitor cannot replace the pending request/code.
      final other = await request('/');
      final otherCookie = other.headers
          .value(HttpHeaders.setCookieHeader)!
          .split(';')
          .first;
      final conflict = await request(
        '/pair',
        method: 'POST',
        cookie: otherCookie,
        body: 'code=${otherCookie.split('=').last}',
        origin: server.url!.origin,
      );
      expect(conflict.status, HttpStatus.conflict);
      expect(server.pairingCode, code);
      server.approvePairing();
      expect(server.pairingCode, code);
      final approved = await request('/', cookie: cookie);
      expect(approved.text, contains(markup));
      expect(approved.text, contains('Download book'));
      expect(
        (await request('/', cookie: otherCookie)).text,
        isNot(contains('id="pairing-code"')),
      );
      server.revokePairing();
      expect(server.pairingCode, isNull);
      expect(
        (await request('/', cookie: cookie)).text,
        isNot(contains('id="pairing-code"')),
      );
      await pair(approve: false);
      expect(server.pairingCode, matches(RegExp(r'^[1-9][0-9]{2}$')));
      await server.stop();
      expect(server.pairingCode, isNull);
    },
  );

  test('download is identical, measures bytes, retains copy for retry, preserves source', () async {
    final cookie = await pair();
    final before = await source.readAsBytes();
    final response = await request('/download', cookie: cookie);
    expect(response.status, HttpStatus.ok);
    expect(response.bytes, before);
    expect(response.headers.contentLength, before.length);
    expect(
      response.headers.value(HttpHeaders.contentTypeHeader),
      'application/vnd.amazon.mobi8-ebook',
    );
    expect(
      response.headers.value('Content-Disposition'),
      contains("filename*=UTF-8''"),
    );
    await waitForTransfer();
    expect(server.sentBytes, before.length);
    expect(server.transferred, isTrue);
    expect(await managedCopies(), 1);
    expect((await request('/download', cookie: cookie)).bytes, before);
    await server.stop();
    expect(await managedCopies(), 0);
    expect(await source.readAsBytes(), before);
  });

  test(
    'HEAD and single bounded, suffix, open ranges produce correct metadata',
    () async {
      final cookie = await pair();
      final head = await request('/download', cookie: cookie, method: 'HEAD');
      expect(head.status, HttpStatus.ok);
      expect(head.bytes, isEmpty);
      expect(head.headers.contentLength, 1024);
      expect(server.sentBytes, 0);
      expect(server.transferred, isFalse);
      final bytes = fixture();
      for (final range in ['bytes=100-109', 'bytes=-10', 'bytes=1014-']) {
        final response = await request(
          '/download',
          cookie: cookie,
          range: range,
        );
        final start = range == 'bytes=100-109' ? 100 : 1014;
        expect(response.status, HttpStatus.partialContent);
        expect(response.bytes, bytes.sublist(start, start + 10));
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes $start-${start + 9}/1024',
        );
        await waitForTransfer();
        expect(server.sentBytes, 10);
        expect(server.transferred, isFalse);
      }
      final clamped = await request(
        '/download',
        cookie: cookie,
        range: 'bytes=1000-9999',
      );
      expect(clamped.bytes, bytes.sublist(1000));
      final rangeHead = await request(
        '/download',
        cookie: cookie,
        method: 'HEAD',
        range: 'bytes=4-8',
      );
      expect(rangeHead.status, HttpStatus.partialContent);
      expect(rangeHead.headers.contentLength, 5);
      expect(rangeHead.bytes, isEmpty);
    },
  );

  test('invalid and multiple ranges return 416 without transfer', () async {
    final cookie = await pair();
    for (final range in [
      'bytes=2000-',
      'bytes=9-1',
      'bytes=-0',
      'bytes=-',
      'bytes=0-1,4-5',
      'bytes=99999999999999999999999-',
    ]) {
      final response = await request('/download', cookie: cookie, range: range);
      expect(
        response.status,
        HttpStatus.requestedRangeNotSatisfiable,
        reason: range,
      );
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes */1024',
      );
    }
    expect(server.sentBytes, 0);
  });

  test(
    'token revocation, forged token and cross-origin pairing denied',
    () async {
      final page = await request('/');
      final cookie = page.headers
          .value(HttpHeaders.setCookieHeader)!
          .split(';')
          .first;
      final code = cookie.split('=').last;
      expect(
        (await request(
          '/pair',
          method: 'POST',
          cookie: cookie,
          body: 'code=$code',
          origin: 'https://example.invalid',
        )).status,
        HttpStatus.forbidden,
      );
      final forged = List.filled(43, 'a').join();
      expect(
        (await request(
          '/pair',
          method: 'POST',
          cookie: 'brizfi_session=$forged',
          body: 'code=$forged',
        )).status,
        HttpStatus.seeOther,
      );
      expect(server.pendingPairing, isFalse);
      expect(
        (await request('/download', cookie: 'brizfi_session=$forged')).status,
        HttpStatus.forbidden,
      );
      final paired = await pair();
      expect(
        (await request('/status', cookie: 'brizfi_session=wrong')).status,
        HttpStatus.forbidden,
      );
      server.revokePairing();
      expect(
        (await request('/status', cookie: paired)).status,
        HttpStatus.forbidden,
      );
      expect(
        (await request('/download', cookie: paired)).status,
        HttpStatus.forbidden,
      );
    },
  );

  test('session expiration denies access and removes only the managed copy', () async {
    final cookie = await pair();
    now = now.add(ReaderServer.lifetime);
    expect(server.paired, isFalse);
    // Expiry may close an existing keep-alive connection before a new request.
    try {
      expect(
        (await request('/download', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
    } on HttpException {
      expect(server.paired, isFalse);
    } on SocketException {
      expect(server.paired, isFalse);
    }
    await server.stop();
    expect(await managedCopies(), 0);
    expect(await source.exists(), isTrue);
  });

  test(
    'pending request expires after two minutes without granting access',
    () async {
      final cookie = await pair(approve: false);
      expect(server.pairingCode, isNotNull);
      now = now.add(const Duration(minutes: 2));
      expect(server.pendingPairing, isFalse);
      expect(server.pairingCode, isNull);
      server.approvePairing();
      expect(server.paired, isFalse);
      expect(
        (await request('/download', cookie: cookie)).status,
        HttpStatus.forbidden,
      );
    },
  );

  test(
    'route allowlist, methods, query and Host deny traversal or rebinding',
    () async {
      final cookie = await pair();
      for (final path in [
        '/book/../../private.azw3',
        '/download/private.azw3',
        '/%2fdownload',
        '/download?path=secret',
        '/missing',
      ]) {
        final response = await request(path, cookie: cookie);
        expect(response.status, HttpStatus.notFound, reason: path);
      }
      expect(
        (await request('/download', cookie: cookie, method: 'POST')).status,
        HttpStatus.methodNotAllowed,
      );
      expect(
        (await request('/', host: 'evil.invalid')).status,
        HttpStatus.forbidden,
      );
    },
  );

  test('request rate is bounded and resets with the clock', () async {
    for (var i = 0; i < 60; i++) {
      expect((await request('/missing')).status, HttpStatus.notFound);
    }
    expect((await request('/missing')).status, HttpStatus.tooManyRequests);
    now = now.add(const Duration(minutes: 1));
    expect((await request('/missing')).status, HttpStatus.notFound);
  });

  test('stop during import is serialized and preserves the source', () async {
    await server.stop();
    final starting = server.start(
      address: InternetAddress.loopbackIPv4,
      source: source,
      port: 0,
    );
    final stopping = server.stop();
    await Future.wait([starting, stopping]);
    expect(server.isRunning, isFalse);
    expect(await managedCopies(), 0);
    expect(await source.readAsBytes(), fixture());
  });

  test('restart removes only expired recognizable owned copies', () async {
    await server.stop();
    final cache = Directory('${copies.path}/brizfi-transfer-cache');
    final old = await Directory('${cache.path}/job-expired').create();
    await File('${old.path}/.brizfi-owned').writeAsString(
      'brizfi-transfer-v1\n${now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch}\n',
    );
    await File('${old.path}/book.azw3').writeAsBytes(fixture());
    final recent = await Directory('${cache.path}/job-recent').create();
    await File('${recent.path}/.brizfi-owned').writeAsString(
      'brizfi-transfer-v1\n${now.add(const Duration(minutes: 1)).millisecondsSinceEpoch}\n',
    );
    await File('${recent.path}/book.azw3').writeAsBytes(fixture());
    final unrelated = await Directory('${cache.path}/job-unrelated').create();
    await File('${unrelated.path}/notes.txt').writeAsString('preserve');
    final outside = await Directory('${copies.path}/job-outside').create();
    await File('${outside.path}/.brizfi-owned')
        .writeAsString('brizfi-transfer-v1\n0\n');
    await server.start(
      address: InternetAddress.loopbackIPv4,
      source: source,
      port: 0,
    );
    expect(await old.exists(), isFalse);
    expect(await recent.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await outside.exists(), isTrue);
    await server.stop();
    expect(await recent.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await outside.exists(), isTrue);
  });

  test(
    'cache quota refuses a new copy without deleting unrelated data or source',
    () async {
      await server.stop();
      final notes = await File('${copies.path}/brizfi-transfer-cache/notes.txt')
          .writeAsBytes(Uint8List(512));
      final bounded = ReaderServer(
        temporaryRoot: copies,
        cacheLimitBytes: 1500,
      );
      try {
        await expectLater(
          bounded.start(
            address: InternetAddress.loopbackIPv4,
            source: source,
            port: 0,
          ),
          throwsA(
            isA<TransferStorageFailure>().having(
              (e) => e.code,
              'code',
              'cache_full',
            ),
          ),
        );
        expect(bounded.errorCode, 'cache_full');
        expect(await managedCopies(), 0);
        expect(await notes.length(), 512);
        expect(await source.readAsBytes(), fixture());
      } finally {
        await bounded.stop();
        bounded.dispose();
      }
    },
  );

  test(
    'concurrent allocations share the quota and preserve the winning copy',
    () async {
      await server.stop();
      final first = ReaderServer(temporaryRoot: copies, cacheLimitBytes: 1500);
      final second = ReaderServer(temporaryRoot: copies, cacheLimitBytes: 1500);
      try {
        Future<String> start(ReaderServer target) async {
          try {
            await target.start(
              address: InternetAddress.loopbackIPv4,
              source: source,
              port: 0,
            );
            return 'ready';
          } on TransferStorageFailure catch (e) {
            return e.code;
          }
        }

        expect(
          await Future.wait([start(first), start(second)]),
          unorderedEquals(['ready', 'cache_full']),
        );
        expect(await managedCopies(), 1);
        final winner = first.isRunning ? first : second;
        final response = await (await client.getUrl(winner.url!)).close();
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
        expect(await source.readAsBytes(), fixture());
      } finally {
        await first.stop();
        await second.stop();
        first.dispose();
        second.dispose();
      }
    },
  );

  test(
    'another startup cannot reap an expired but live in-process copy',
    () async {
      now = now.add(const Duration(minutes: 16));
      final second = ReaderServer(
        clock: () => now,
        temporaryRoot: copies,
        cacheLimitBytes: 4000,
      );
      try {
        await second.start(
          address: InternetAddress.loopbackIPv4,
          source: source,
          port: 0,
        );
        expect(await managedCopies(), 2);
        await server.stop();
        expect(await managedCopies(), 1);
        expect(second.isRunning, isTrue);
      } finally {
        await second.stop();
        second.dispose();
      }
    },
  );

  test('changed source cannot exceed its reserved allocation', () async {
    await server.stop();
    await expectLater(
      server.start(
        address: InternetAddress.loopbackIPv4,
        source: ChangedSource(source),
        port: 0,
      ),
      throwsFormatException,
    );
    expect(await managedCopies(), 0);
    expect(await source.readAsBytes(), fixture());
  });

  test('start rejects public or wildcard binds and invalid headers without leaving copies', () async {
    await server.stop();
    for (final address in ['0.0.0.0', '8.8.8.8', '::1']) {
      await expectLater(
        server.start(
          address: InternetAddress(address),
          source: source,
          port: 0,
        ),
        throwsArgumentError,
      );
    }
    await source.writeAsBytes(Uint8List(1024));
    await expectLater(
      server.start(
        address: InternetAddress.loopbackIPv4,
        source: source,
        port: 0,
      ),
      throwsFormatException,
    );
    expect(await managedCopies(), 0);
    expect(await source.exists(), isTrue);
    final oversized = await source.open(mode: FileMode.write);
    await oversized.truncate(ReaderServer.maxFileBytes + 1);
    await oversized.close();
    await expectLater(
      server.start(
        address: InternetAddress.loopbackIPv4,
        source: source,
        port: 0,
      ),
      throwsFormatException,
    );
    expect(await managedCopies(), 0);
  });

  test('one active download and stop waits for stream before cleanup', () async {
    await server.stop();
    await source.writeAsBytes(fixture(ReaderServer.maxFileBytes));
    await server.start(
      address: InternetAddress.loopbackIPv4,
      source: source,
      port: 0,
    );
    final cookie = await pair();
    final first = await client.getUrl(server.url!.resolve('/download'));
    first.headers.set(HttpHeaders.cookieHeader, cookie);
    final firstResponse = await first.close();
    expect(firstResponse.statusCode, HttpStatus.ok);
    // Deliberately leave the client unread, so the socket applies backpressure.
    expect(server.isTransferring, isTrue);
    expect(
      (await request('/download', cookie: cookie)).status,
      HttpStatus.conflict,
    );
    expect(await managedCopies(), 1);
    await server.stop().timeout(const Duration(seconds: 5));
    expect(server.isTransferring, isFalse);
    expect(server.transferred, isFalse);
    expect(await managedCopies(), 0);
    expect(await source.length(), ReaderServer.maxFileBytes);
  });

  test('interrupted client retains the managed copy for a successful retry', () async {
    await server.stop();
    await source.writeAsBytes(fixture(ReaderServer.maxFileBytes));
    await server.start(
      address: InternetAddress.loopbackIPv4,
      source: source,
      port: 0,
    );
    final cookie = await pair();
    final socket = await Socket.connect(server.url!.host, server.url!.port);
    final received = Completer<void>();
    final subscription = socket.listen((_) {
      if (!received.isCompleted) received.complete();
      socket.destroy();
    });
    socket.write(
      'GET /download HTTP/1.1\r\nHost: ${server.url!.authority}\r\nCookie: $cookie\r\nConnection: close\r\n\r\n',
    );
    await received.future.timeout(const Duration(seconds: 5));
    final settled = Completer<void>();
    void listen() {
      if (!server.isTransferring && !settled.isCompleted) settled.complete();
    }

    server.addListener(listen);
    if (!server.isTransferring) settled.complete();
    await settled.future.timeout(const Duration(seconds: 5));
    server.removeListener(listen);
    await subscription.cancel();
    expect(server.transferred, isFalse);
    expect(await managedCopies(), 1);
    final response = await request('/download', cookie: cookie);
    expect(response.bytes, await source.readAsBytes());
    await waitForTransfer();
    expect(server.transferred, isTrue);
  });
}
