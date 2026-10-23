import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brizfi/services/reader_server.dart';
import 'package:flutter_test/flutter_test.dart';

// Owned synthetic containers exercise format gates, not reader compatibility.
Uint8List palm({bool encrypted = false}) {
  final b = Uint8List(256);
  b.setRange(60, 68, ascii.encode('BOOKMOBI'));
  b[77] = 1;
  b[81] = 86;
  b[86] = 0;
  b[87] = 1;
  b[99] = encrypted ? 1 : 0;
  b.setRange(102, 106, ascii.encode('MOBI'));
  return b;
}

Uint8List epub({Map<String, String> extra = const {}}) {
  final entries = {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?><container><rootfiles>'
        '<rootfile full-path="content.opf"/></rootfiles></container>',
    'content.opf': '<package xmlns="http://www.idpf.org/2007/opf"/>',
    ...extra,
  };
  final local = BytesBuilder();
  final central = BytesBuilder();
  int crc32(List<int> b) {
    var crc = 0xffffffff;
    for (final v in b) {
      crc ^= v;
      for (var i = 0; i < 8; i++) {
        crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    return crc ^ 0xffffffff;
  }

  for (final entry in entries.entries) {
    final name = utf8.encode(entry.key);
    final data = utf8.encode(entry.value);
    final offset = local.length;
    final crc = crc32(data);
    final h = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    local
      ..add(h.buffer.asUint8List())
      ..add(name)
      ..add(data);
    final c = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(c.buffer.asUint8List())
      ..add(name);
  }
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, central.length, Endian.little)
    ..setUint32(16, local.length, Endian.little);
  return (BytesBuilder()
        ..add(local.takeBytes())
        ..add(central.takeBytes())
        ..add(end.buffer.asUint8List()))
      .takeBytes();
}

void main() {
  late Directory root;
  late Directory copies;
  late ReaderServer server;
  late HttpClient client;
  late String cookie;

  Future<({int status, HttpHeaders headers, List<int> bytes})> request(
    String path, {
    String method = 'GET',
    bool authorized = true,
    String? range,
    String? body,
  }) async {
    final req = await client.openUrl(method, server.url!.resolve(path));
    req.followRedirects = false;
    if (authorized) req.headers.set(HttpHeaders.cookieHeader, cookie);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    if (body != null) {
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      req.headers.set('Origin', server.url!.origin);
      req.write(body);
    }
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (all, b) => all..addAll(b));
    return (status: res.statusCode, headers: res.headers, bytes: bytes);
  }

  Future<File> book(String name, List<int> bytes) =>
      File('${root.path}/$name').writeAsBytes(bytes);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('brizfi-formats-test-');
    copies = await Directory('${root.path}/copies').create();
    server = ReaderServer(
      temporaryRoot: copies,
      allowedFormats: {'azw3', 'mobi', 'epub', 'pdf', 'txt'},
    );
    client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    await server.startPage(address: InternetAddress.loopbackIPv4, port: 0);
    final page = await request('/', authorized: false);
    cookie = page.headers.value(HttpHeaders.setCookieHeader)!.split(';').first;
    final response = await request(
      '/pair',
      method: 'POST',
      body: 'code=${cookie.split('=').last}',
    );
    expect(response.status, HttpStatus.seeOther);
    server.approvePairing();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    server.dispose();
    await root.delete(recursive: true);
  });

  test(
    'paired unchanged downloads preserve each format, MIME, HEAD and Range',
    () async {
      final fixtures = <String, (List<int>, String)>{
        'azw3': (palm(), 'application/vnd.amazon.mobi8-ebook'),
        'mobi': (palm(), 'application/x-mobipocket-ebook'),
        'epub': (epub(), 'application/epub+zip'),
        'pdf': (
          ascii.encode('%PDF-1.4\n1 0 obj <<>> endobj\n%%EOF\n'),
          'application/pdf',
        ),
        'txt': (utf8.encode('Тестовая книга\nLocal book.\n'), 'text/plain'),
      };
      final files = <File>[];
      for (final entry in fixtures.entries) {
        files.add(await book('Книга.${entry.key}', entry.value.$1));
      }
      await server.updateBooks(files);
      expect(server.paired, isTrue);
      expect(server.bookCount, 5);
      var index = 0;
      for (final entry in fixtures.entries) {
        final path = '/download/${index++}';
        expect(
          (await request(path, authorized: false)).status,
          HttpStatus.forbidden,
        );
        final head = await request(path, method: 'HEAD');
        expect(head.status, HttpStatus.ok);
        expect(head.bytes, isEmpty);
        expect(head.headers.contentLength, entry.value.$1.length);
        expect(head.headers.contentType!.mimeType, entry.value.$2);
        expect(
          head.headers.value('Content-Disposition'),
          contains('.${entry.key}'),
        );
        final partial = await request(path, range: 'bytes=0-3');
        expect(partial.status, HttpStatus.partialContent);
        expect(partial.bytes, entry.value.$1.sublist(0, 4));
        expect(partial.headers.contentType!.mimeType, entry.value.$2);
        expect(
          partial.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 0-3/${entry.value.$1.length}',
        );
        final full = await request(path);
        expect(full.status, HttpStatus.ok);
        expect(full.bytes, entry.value.$1);
        expect(await files[index - 1].readAsBytes(), entry.value.$1);
      }
      final paths = await copies
          .list(recursive: true)
          .map((e) => e.path)
          .toList();
      for (final ext in fixtures.keys) {
        expect(paths.any((p) => p.endsWith('.$ext')), isTrue);
      }
    },
  );

  test(
    'bad format or protected content preserves the previous approved batch',
    () async {
      final good = await book('valid.txt', utf8.encode('Keep this book'));
      await server.updateBooks([good]);
      final revision = server.booksRevision;
      final invalid = <String, List<int>>{
        'unsupported.fb2': utf8.encode('<FictionBook/>'),
        'missing-extension': utf8.encode('book'),
        'empty.txt': [],
        'binary.txt': [0, 1, 2],
        'invalid-utf8.txt': [0xff, 0xff],
        'renamed.pdf': utf8.encode('Not a PDF'),
        'encrypted.pdf': ascii.encode('%PDF-1.4\n/Encrypt 2 0 R\n%%EOF'),
        'escaped.pdf': ascii.encode('%PDF-1.4\n/Encr#79pt 2 0 R\n%%EOF'),
        'renamed.epub': utf8.encode('Not a ZIP'),
        'empty-container.epub': epub(extra: {'META-INF/container.xml': ''}),
        'encrypted.epub': epub(
          extra: {'META-INF/encryption.xml': '<encryption/>'},
        ),
        'rights.epub': epub(extra: {'META-INF/rights.xml': '<rights/>'}),
        'traversal.epub': epub(extra: {'../book.txt': 'bad'}),
        'broken.mobi': List.filled(256, 0),
        'encrypted.mobi': palm(encrypted: true),
        'encrypted.azw3': palm(encrypted: true),
      };
      for (final entry in invalid.entries) {
        await expectLater(
          server.updateBooks([good, await book(entry.key, entry.value)]),
          throwsFormatException,
          reason: entry.key,
        );
        expect(server.paired, isTrue);
        expect(server.booksRevision, revision);
        expect(server.bookCount, 1);
      }
      expect((await request('/download')).bytes, utf8.encode('Keep this book'));
      final jobs = await copies
          .list(recursive: true)
          .where((e) => e is Directory && e.path.contains('job-'))
          .length;
      expect(jobs, 1);
    },
  );

  test('oversized input and ZIP budgets reject before publication', () async {
    final good = await book('valid.txt', utf8.encode('Keep this book'));
    await server.updateBooks([good]);
    final oversized = await book('oversized.pdf', []);
    final handle = await oversized.open(mode: FileMode.write);
    await handle.truncate(ReaderServer.maxFileBytes + 1);
    await handle.close();
    final tooMany = epub();
    final metadata = ByteData.sublistView(tooMany);
    metadata
      ..setUint16(tooMany.length - 14, 4097, Endian.little)
      ..setUint16(tooMany.length - 12, 4097, Endian.little);
    final bomb = epub();
    final directory = ByteData.sublistView(bomb);
    final centralOffset = directory.getUint32(bomb.length - 6, Endian.little);
    directory.setUint32(centralOffset + 24, 129 * 1024 * 1024, Endian.little);
    for (final file in [
      oversized,
      await book('too-many.epub', tooMany),
      await book('bomb.epub', bomb),
    ]) {
      await expectLater(server.updateBooks([file]), throwsFormatException);
      expect(server.bookCount, 1);
      expect(server.paired, isTrue);
    }
    expect((await request('/download')).bytes, utf8.encode('Keep this book'));
  });

  test(
    'duplicate and long download names retain the actual extension',
    () async {
      final name = '${List.filled(120, 'a').join()}.epub';
      final source = await book(name, epub());
      await server.updateBooks([source, source]);
      expect(
        server.deliveryStatus.last.name,
        '${name.substring(0, name.length - 5)}-2.epub',
      );
      final reply = await request('/download/1', method: 'HEAD');
      final disposition = reply.headers.value('Content-Disposition')!;
      final fallback = RegExp('filename="([^"]+)"')
          .firstMatch(disposition)![1]!;
      expect(fallback.length, 100);
      expect(fallback, endsWith('.epub'));
      expect(
        disposition,
        contains(Uri.encodeComponent(server.deliveryStatus.last.name)),
      );
    },
  );

  test(
    'expired cleanup removes only exact owned supported-book layouts',
    () async {
      final cache = Directory('${copies.path}/brizfi-transfer-cache');
      Future<Directory> oldJob(String name, String file) async {
        final dir = await Directory('${cache.path}/job-$name').create();
        await File('${dir.path}/.brizfi-owned')
            .writeAsString('brizfi-transfer-v1\n0\n');
        await File('${dir.path}/$file').writeAsString('owned fixture');
        return dir;
      }

      final removed = <Directory>[];
      for (final ext in ['azw3', 'mobi', 'epub', 'pdf', 'txt']) {
        removed.add(await oldJob(ext, 'book-0.$ext'));
      }
      removed.add(await oldJob('legacy', 'book.azw3'));
      final kept = <Directory>[];
      for (final file in [
        'book-10.pdf',
        'book-0.exe',
        'book.txt',
        'personal.epub',
      ]) {
        kept.add(await oldJob(file, file));
      }
      await server.updateBooks([
        await book('new.txt', utf8.encode('new book')),
      ]);
      for (final dir in removed) {
        expect(await dir.exists(), isFalse);
      }
      for (final dir in kept) {
        expect(await dir.exists(), isTrue);
      }
    },
  );
}
