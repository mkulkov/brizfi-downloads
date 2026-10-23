import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'dart:ui' show Locale;

import '../l10n/app_localizations.dart';

import 'book_validation.dart';
import 'reader_batch_script.dart';
import 'reader_page.dart';
import 'reader_identity.dart';

class TransferStorageFailure implements Exception {
  const TransferStorageFailure(this.code);
  final String code;
}

/// Measured HTTP delivery state; completion does not mean reader indexing.
class BookDeliveryStatus {
  const BookDeliveryStatus(
    this.name,
    this.length,
    this.sent,
    this.completed,
    this.active,
  );
  final String name;
  final int length;
  final int sent;
  final bool completed;
  final bool active;
}

/// A managed unchanged book, retained for the session's bounded retry window.
class _TransferBook {
  _TransferBook(this.file, this.name, this.length);
  final File file;
  final String name;
  final int length;
  int sent = 0;
  bool completed = false;
}

class _PreparedBooks {
  _PreparedBooks(this.storage, this.books, this.length);
  final Directory? storage;
  final List<_TransferBook> books;
  final int length;
}

class ReaderServer extends ChangeNotifier {
  ReaderServer({
    DateTime Function()? clock,
    Directory? temporaryRoot,
    this.cacheLimitBytes = maxCacheBytes,
    Set<String> allowedFormats = const {'azw3'},
  }) : allowedFormats = Set.unmodifiable(allowedFormats),
       _clock = clock ?? DateTime.now,
       _temporaryRoot = temporaryRoot ?? Directory.systemTemp;

  static const maxBooks = 10;
  String _languageCode = 'en';
  AppLocalizations get _pageStrings =>
      lookupAppLocalizations(Locale(_languageCode));
  static const maxFileBytes = 32 * 1024 * 1024;
  static const maxCacheBytes = 96 * 1024 * 1024;
  static const _leaseAllowance = 128;
  static Future<void> _cacheGate = Future<void>.value();
  // In-process leases prevent another server instance's startup cleanup from
  // deleting a file whose HTTP stream is still closing, even after its TTL.
  static final Map<String, int> _liveCopies = {};
  static const lifetime = Duration(minutes: 15);
  static const _cookieName = 'brizfi_session';
  final DateTime Function() _clock;
  final Directory _temporaryRoot;
  final int cacheLimitBytes;

  /// The AZW3-only default retains the original header-only PoC validation.
  /// Expanded reader profiles use the bounded content gates for every format.
  final Set<String> allowedFormats;
  final Random _random = Random.secure();
  final Set<Future<void>> _handlers = {};
  final Map<String, DateTime> _challenges = {};
  HttpServer? _server;
  Directory? _storage;
  final List<_TransferBook> _books = [];
  DateTime? _expires;
  DateTime? _pendingUntil;
  String? _pendingToken;
  String? _sessionToken;
  String? _pairingCode;
  ReaderIdentity? readerIdentity;
  Timer? _expiryTimer;
  Timer? _pairTimer;
  Future<void>? _stopping;
  Completer<void>? _startDone;
  Completer<void>? _updateDone;
  bool _starting = false;
  bool _updating = false;
  bool _transferring = false;
  _TransferBook? _activeBook;
  bool _disposed = false;
  DateTime? _rateWindow;
  int _requestsInWindow = 0;
  Uri? _url;
  String? _error;
  String? _errorCode;
  String _name = 'book.azw3';
  int _fileLength = 0;
  int _sentBytes = 0;
  bool _transferred = false;
  int _booksRevision = 0;

  Uri? get url => _url;
  String? get error => _error;
  String? get errorCode => _errorCode;
  String get name => _name;
  int get fileLength => _fileLength;
  int get sentBytes => _sentBytes;
  bool get transferred => _transferred;
  int get bookCount => _books.length;
  int get booksRevision => _booksRevision;
  int get completedBooks => _books.where((b) => b.completed).length;
  List<BookDeliveryStatus> get deliveryStatus => List.unmodifiable(
    _books.map(
      (b) => BookDeliveryStatus(
        b.name,
        b.length,
        b.sent,
        b.completed,
        identical(b, _activeBook),
      ),
    ),
  );
  bool get isRunning => _server != null && !_expired;
  bool get isTransferring => _transferring;
  bool get pendingPairing =>
      isRunning &&
      _pendingToken != null &&
      _pendingUntil != null &&
      _clock().isBefore(_pendingUntil!);
  bool get paired => isRunning && _sessionToken != null;
  // Human comparison only; authorization still uses the full random cookie.
  String? get pairingCode => pendingPairing || paired ? _pairingCode : null;
  bool get _expired => _expires != null && !_clock().isBefore(_expires!);

  void dismissError() {
    if (_server != null || _starting) return;
    _error = null;
    _errorCode = null;
    _notify();
  }

  Future<void> start({
    required InternetAddress address,
    required File source,
    int port = 8080,
    String languageCode = 'en',
  }) => startBatch(
    address: address,
    sources: [source],
    port: port,
    languageCode: languageCode,
  );

  Future<void> startBatch({
    required InternetAddress address,
    required List<File> sources,
    int port = 8080,
    String languageCode = 'en',
  }) => _start(
    address: address,
    sources: sources,
    port: port,
    languageCode: languageCode,
    allowEmpty: false,
  );

  /// Open the pairing/waiting page before a book has been selected.
  Future<void> startPage({
    required InternetAddress address,
    int port = 8080,
    String languageCode = 'en',
  }) => _start(
    address: address,
    sources: const [],
    port: port,
    languageCode: languageCode,
    allowEmpty: true,
  );

  Future<void> _start({
    required InternetAddress address,
    required List<File> sources,
    required int port,
    required String languageCode,
    required bool allowEmpty,
  }) async {
    if (_disposed || _starting || _server != null || _stopping != null) {
      throw StateError('The server is already active or unavailable.');
    }
    _starting = true;
    _languageCode =
        languageCode.toLowerCase().split(RegExp('[-_]')).first == 'ru'
        ? 'ru'
        : 'en';
    _startDone = Completer<void>();
    _error = null;
    _errorCode = null;
    _sentBytes = 0;
    _transferred = false;
    try {
      if (!_isLocalV4(address)) {
        throw ArgumentError('Select a private IPv4 or loopback address.');
      }
      if (port < 0 || port > 65535) {
        throw ArgumentError('Invalid port.');
      }
      if (!allowEmpty && sources.isEmpty) {
        throw const TransferStorageFailure('batch_limit');
      }
      if (sources.isEmpty) await _withCacheLock(_prepareCache);
      _installBooks(await _prepareBooks(sources, _clock().add(lifetime)));
      final server = await HttpServer.bind(address, port, shared: false);
      _server = server;
      server.idleTimeout = const Duration(seconds: 10);
      _url = Uri(scheme: 'http', host: address.address, port: server.port);
      _expires = _clock().add(lifetime);
      if (_storage != null) await _writeLease(_storage!, _expires!);
      _rateWindow = _clock();
      _requestsInWindow = 0;
      _expiryTimer = Timer(lifetime, () => unawaited(stop()));
      server.listen(
        _accept,
        onError: (Object _) {
          _error = 'The local server stopped unexpectedly.';
          _errorCode = 'transfer_failed';
          _notify();
          unawaited(stop());
        },
      );
    } catch (exception) {
      await _server?.close(force: true);
      _server = null;
      _url = null;
      _expires = null;
      _error = exception is FormatException
          ? exception.message.toString()
          : 'Could not prepare the local transfer.';
      _errorCode = exception is TransferStorageFailure
          ? exception.code
          : exception is FileSystemException
          ? 'storage_unavailable'
          : exception is FormatException
          ? 'invalid_book'
          : 'transfer_failed';
      await _removeCopy();
      rethrow;
    } finally {
      _starting = false;
      _startDone!.complete();
      _notify();
    }
  }

  /// Replace only a ready batch, retaining this server's pairing and TTL.
  /// A failed preparation leaves the previous batch available for retry.
  Future<void> updateBooks(List<File> sources) async {
    if (_disposed ||
        !isRunning ||
        _starting ||
        _stopping != null ||
        _updating ||
        _transferring) {
      throw StateError('The server cannot replace books right now.');
    }
    _updating = true;
    _updateDone = Completer<void>();
    _PreparedBooks? prepared;
    try {
      prepared = await _prepareBooks(sources, _expires!);
      if (_disposed || !isRunning || _stopping != null) {
        throw StateError('The server stopped while preparing books.');
      }
      final oldStorage = _storage;
      _installBooks(prepared);
      prepared = null;
      _booksRevision++;
      _error = null;
      _errorCode = null;
      if (oldStorage != null) {
        try {
          await _deleteStorage(oldStorage);
        } on FileSystemException {
          // The expired lease allows a later startup to retry cleanup.
        }
      }
    } finally {
      try {
        if (prepared?.storage != null) await _deleteStorage(prepared!.storage!);
      } finally {
        _updating = false;
        _updateDone!.complete();
        _notify();
      }
    }
  }

  void _installBooks(_PreparedBooks prepared) {
    _storage = prepared.storage;
    _books
      ..clear()
      ..addAll(prepared.books);
    _fileLength = prepared.length;
    _name = _books.isEmpty ? 'book.azw3' : _books.first.name;
    _sentBytes = 0;
    _transferred = false;
  }

  Future<_PreparedBooks> _prepareBooks(
    List<File> sources,
    DateTime expiry,
  ) async {
    if (sources.length > maxBooks) {
      throw const TransferStorageFailure('batch_limit');
    }
    final inputs = List<File>.of(sources);
    if (inputs.isEmpty) return _PreparedBooks(null, [], 0);
    final lengths = <int>[];
    final extensions = <String>[];
    var total = 0;
    for (final source in inputs) {
      final extension = transferExtension(source.uri.pathSegments.last);
      if (!allowedFormats.contains(extension) ||
          !transferMimeTypes.containsKey(extension)) {
        throw const FormatException('Select a supported book format.');
      }
      final length = await source.length();
      if (length == 0 || length > maxFileBytes) {
        throw const FormatException(
          'Books must be nonempty and no larger than 32 MiB.',
        );
      }
      lengths.add(length);
      extensions.add(extension);
      total += length;
    }
    final storage = await _allocateCopy(total);
    try {
      await _writeLease(storage, expiry);
      final books = <_TransferBook>[];
      final names = <String>{};
      for (var index = 0; index < inputs.length; index++) {
        final extension = extensions[index];
        final copy = File(
          '${storage.path}${Platform.pathSeparator}book-$index.$extension',
        );
        final sink = copy.openWrite();
        var copied = 0;
        try {
          await for (final chunk in inputs[index].openRead()) {
            copied += chunk.length;
            if (copied > lengths[index]) {
              throw const FormatException(
                'Book changed while preparing transfer.',
              );
            }
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (copied != lengths[index]) {
          throw const FormatException('Book changed while preparing transfer.');
        }
        await validateTransferBook(
          copy,
          extension,
          legacyPalmHeader:
              extension == 'azw3' &&
              allowedFormats.length == 1 &&
              allowedFormats.contains('azw3'),
        );
        final originalName = inputs[index].uri.pathSegments.last;
        final stem = originalName.substring(0, originalName.lastIndexOf('.'));
        var name = originalName;
        var suffix = 2;
        while (!names.add(name.toLowerCase())) {
          name = '$stem-${suffix++}.${originalName.split('.').last}';
        }
        books.add(_TransferBook(copy, name, copied));
      }
      return _PreparedBooks(storage, books, total);
    } catch (_) {
      await _deleteStorage(storage);
      rethrow;
    }
  }

  /// Approval is local to the operator; no HTTP route can approve a reader.
  void approvePairing() {
    if (!pendingPairing) return;
    _sessionToken = _pendingToken;
    _pendingToken = null;
    _pendingUntil = null;
    _pairTimer?.cancel();
    _notify();
  }

  void revokePairing() {
    readerIdentity = null;
    _pairingCode = null;
    _sessionToken = null;
    _pendingToken = null;
    _pendingUntil = null;
    _pairTimer?.cancel();
    _notify();
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    // Publish the future before closing sockets; concurrent callers share it.
    final completer = Completer<void>();
    _stopping = completer.future;
    unawaited(
      _stop().then(completer.complete, onError: completer.completeError),
    );
    return completer.future;
  }

  Future<void> _stop() async {
    try {
      if (_starting) await _startDone!.future;
      if (_updating) await _updateDone!.future;
      _expiryTimer?.cancel();
      _pairTimer?.cancel();
      final server = _server;
      _server = null;
      _url = null;
      revokePairing();
      _challenges.clear();
      // Abort stalled clients, then await every handler before removing its file.
      await server?.close(force: _handlers.isNotEmpty);
      await Future.wait(_handlers.toList());
      await _removeCopy();
      _expires = null;
    } finally {
      _stopping = null;
      _notify();
    }
  }

  void _accept(HttpRequest request) {
    if (_handlers.length >= 8) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      unawaited(request.response.close().catchError((Object _) {}));
      return;
    }
    late Future<void> handler;
    handler = _handle(request).whenComplete(() {
      _handlers.remove(handler);
      if (_expired && _stopping == null) unawaited(stop());
    });
    _handlers.add(handler);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        // no-referrer turns browser form POST Origin into "null" and breaks
        // our same-origin pairing check. Keep referrers inside this origin.
        ..set('Referrer-Policy', 'same-origin')
        ..set(
          'Content-Security-Policy',
          "default-src 'none'; form-action 'self'; frame-ancestors 'none'",
        );
      if (!isRunning ||
          request.headers.value(HttpHeaders.hostHeader) != _url!.authority) {
        return await _reply(
          response,
          HttpStatus.forbidden,
          'Transfer unavailable.',
        );
      }
      final now = _clock();
      if (_rateWindow == null ||
          now.difference(_rateWindow!) >= const Duration(minutes: 1)) {
        _rateWindow = now;
        _requestsInWindow = 0;
      }
      if (++_requestsInWindow > 60) {
        response.headers.set(HttpHeaders.retryAfterHeader, '60');
        return await _reply(
          response,
          HttpStatus.tooManyRequests,
          'Try again later.',
        );
      }
      final path = request.uri.path;
      final indexedDownload = RegExp(r'^/download/([0-9]+)$').firstMatch(path);
      if (request.uri.hasQuery ||
          (!{
                '/',
                '/pair',
                '/pair-status',
                '/status',
                '/download',
              }.contains(path) &&
              indexedDownload == null)) {
        return await _reply(response, HttpStatus.notFound, 'Not found.');
      }
      if (path == '/pair') {
        return await _pair(request);
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return await _reply(
          response,
          HttpStatus.methodNotAllowed,
          'Method not allowed.',
        );
      }
      if (path == '/') return await _page(request);
      if (path == '/pair-status') {
        final state = _authorized(request)
            ? 'approved'
            : pendingPairing && _cookie(request) == _pendingToken
            ? 'pending'
            : null;
        response.headers.contentType = ContentType.json;
        return await _reply(
          response,
          state == null ? HttpStatus.forbidden : HttpStatus.ok,
          jsonEncode({'state': state ?? 'expired'}),
          head: request.method == 'HEAD',
        );
      }
      if (!_authorized(request)) {
        return await _reply(
          response,
          HttpStatus.forbidden,
          'Approve this reader on the phone first.',
        );
      }
      if (path == '/status') {
        response.headers.contentType = ContentType.json;
        return await _reply(
          response,
          HttpStatus.ok,
          jsonEncode({
            'booksRevision': _booksRevision,
            'fileLength': _fileLength,
            'sentBytes': _sentBytes,
            'transferred': _transferred,
            'transferring': _transferring,
            'books': [
              for (var i = 0; i < _books.length; i++)
                {
                  'index': i,
                  'fileLength': _books[i].length,
                  'sentBytes': _books[i].sent,
                  'transferred': _books[i].completed,
                },
            ],
          }),
          head: request.method == 'HEAD',
        );
      }
      if (_updating) {
        response.headers.set(HttpHeaders.retryAfterHeader, '2');
        return await _reply(
          response,
          HttpStatus.conflict,
          'Books are being prepared.',
        );
      }
      final index = indexedDownload == null
          ? 0
          : int.tryParse(indexedDownload[1]!);
      if (index == null ||
          index < 0 ||
          index >= _books.length ||
          (indexedDownload != null && indexedDownload[1] != index.toString())) {
        return await _reply(response, HttpStatus.notFound, 'Not found.');
      }
      await _download(request, _books[index]);
    } catch (exception) {
      // Avoid logging private paths, cookies, and request data.
      if (_server != null) {
        _error = 'The transfer was interrupted. Try downloading again.';
        _notify();
      }
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _page(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.html;
    final nonce = _token();
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; script-src 'nonce-$nonce'; style-src 'nonce-$nonce'; connect-src 'self'; frame-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    );
    ReaderPageState state;
    String? challenge;
    if (_authorized(request)) {
      state = ReaderPageState.approved;
    } else if (_cookie(request) == _pendingToken && pendingPairing) {
      state = ReaderPageState.pending;
    } else {
      _challenges.removeWhere((_, until) => !_clock().isBefore(until));
      final existing = _cookie(request);
      final token = _challenges.containsKey(existing) ? existing! : _token();
      // Browser probes and repeated page loads must not replace the cookie
      // belonging to a form that is still visible. HEAD never issues a lease.
      if (request.method != 'HEAD' && !_challenges.containsKey(token)) {
        if (_challenges.length >= 8) _challenges.remove(_challenges.keys.first);
        _challenges[token] = _clock().add(const Duration(minutes: 2));
        _setCookie(response, token);
      }
      state = ReaderPageState.initial;
      challenge = token;
    }
    await _reply(
      response,
      HttpStatus.ok,
      renderReaderPage(
        strings: _pageStrings,
        state: state,
        nonce: nonce,
        challenge: challenge,
        code: state == ReaderPageState.initial ? null : pairingCode,
        names: state == ReaderPageState.approved
            ? _books.map((b) => b.name).toList()
            : const [],
        batchScript: readerBatchScript,
        completed: state == ReaderPageState.approved
            ? _books.map((b) => b.completed).toList()
            : const [],
        booksRevision: booksRevision,
      ),
      head: request.method == 'HEAD',
    );
  }

  Future<void> _pair(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'POST') {
      response.headers.set(HttpHeaders.allowHeader, 'POST');
      return _reply(
        response,
        HttpStatus.methodNotAllowed,
        'Use the pairing form.',
      );
    }
    final origin = request.headers.value('Origin');
    final referer = request.headers.value(HttpHeaders.refererHeader);
    final fetchSite = request.headers.value('Sec-Fetch-Site');
    final rejection = origin != null && origin != _url!.origin
        ? (origin == 'null' ? 'opaque_origin' : 'origin')
        : referer != null && !_sameOrigin(referer)
        ? 'referer'
        : fetchSite == 'cross-site'
        ? 'cross_site'
        : request.headers.contentType?.mimeType !=
              'application/x-www-form-urlencoded'
        ? 'form_type'
        : null;
    if (rejection != null) {
      // Diagnostic categories only: never cookies, tokens, URLs or form data.
      if (kDebugMode) debugPrint('BRIZFI pairing rejected: $rejection');
      return _reply(
        response,
        HttpStatus.forbidden,
        'Pairing request rejected ($rejection). Reload the local BRIZFI page.',
      );
    }
    if (request.contentLength > 128) {
      return _reply(
        response,
        HttpStatus.requestEntityTooLarge,
        'Request too large.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 128) {
        response.persistentConnection = false;
        // Do not drain an unbounded upload. Complete a bodyless rejection
        // before cancelling the incoming stream and closing its connection.
        response.statusCode = HttpStatus.requestEntityTooLarge;
        response.contentLength = 0;
        await response.close();
        return;
      }
      bytes.addAll(chunk);
    }
    final body = Uri.splitQueryString(utf8.decode(bytes));
    final token = _cookie(request);
    final challengeExpiry = _challenges[token];
    if (kDebugMode) {
      final category = token == null
          ? 'missing_cookie'
          : body['code'] != token
          ? 'cookie_mismatch'
          : challengeExpiry == null
          ? 'unknown_challenge'
          : !_clock().isBefore(challengeExpiry)
          ? 'expired_challenge'
          : 'valid_challenge';
      debugPrint('BRIZFI pairing form: $category');
    }
    // A page kept open across the challenge TTL or a server restart is stale.
    // Renew only by navigating to GET /; never approve or pair an old form.
    if (RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(body['code'] ?? '') &&
        (token == null || body['code'] == token) &&
        (challengeExpiry == null || !_clock().isBefore(challengeExpiry))) {
      response.statusCode = HttpStatus.seeOther;
      response.headers.set(HttpHeaders.locationHeader, '/');
      await response.close();
      return;
    }
    if (token == null ||
        challengeExpiry == null ||
        !_clock().isBefore(challengeExpiry) ||
        body['code'] != token) {
      return _reply(
        response,
        HttpStatus.forbidden,
        'Reload the local pairing page.',
      );
    }
    if (paired || pendingPairing) {
      return _reply(
        response,
        HttpStatus.conflict,
        'A reader is already paired or waiting.',
      );
    }
    _pendingToken = token;
    final identities = request.cookies
        .where((c) => c.name == 'brizfi_reader')
        .toList();
    final existingIdentity = identities.length == 1
        ? identities.single.value
        : '';
    final identity = RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(existingIdentity)
        ? existingIdentity
        : _token();
    if (identity != existingIdentity) {
      response.headers.add(
        HttpHeaders.setCookieHeader,
        'brizfi_reader=$identity; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000',
      );
    }
    readerIdentity = ReaderIdentity(
      'wifi:$identity',
      ReaderIdentity.detectUserAgent(
        request.headers.value(HttpHeaders.userAgentHeader) ?? '',
      ),
    );
    _pairingCode = (100 + _random.nextInt(900)).toString();
    _challenges.remove(token);
    _pendingUntil = _clock().add(const Duration(minutes: 2));
    _pairTimer?.cancel();
    _pairTimer = Timer(const Duration(minutes: 2), () {
      readerIdentity = null;
      _pendingToken = null;
      _pairingCode = null;
      _pendingUntil = null;
      _notify();
    });
    _notify();
    response.statusCode = HttpStatus.seeOther;
    response.headers.set(HttpHeaders.locationHeader, '/');
    await response.close();
  }

  Future<void> _download(HttpRequest request, _TransferBook book) async {
    final response = request.response;
    // Downloads can be initiated by our own page's queue, never another site.
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; frame-ancestors 'self'",
    );
    var start = 0;
    var end = book.length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
        return _badRange(response, book.length);
      }
      if (match[1]!.isEmpty) {
        final suffix = int.tryParse(match[2]!);
        if (suffix == null || suffix == 0) {
          return _badRange(response, book.length);
        }
        start = max(0, book.length - suffix);
      } else {
        final requestedStart = int.tryParse(match[1]!);
        final requestedEnd = match[2]!.isEmpty ? end : int.tryParse(match[2]!);
        if (requestedStart == null ||
            requestedEnd == null ||
            requestedStart > requestedEnd ||
            requestedStart >= book.length) {
          return _badRange(response, book.length);
        }
        start = requestedStart;
        end = min(end, requestedEnd);
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${book.length}',
      );
    }
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(
        HttpHeaders.contentTypeHeader,
        transferMimeTypes[transferExtension(book.name)]!,
      )
      ..set('Content-Disposition', _disposition(book.name));
    response.contentLength = end - start + 1;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    if (_transferring) {
      response.headers.removeAll(HttpHeaders.contentLengthHeader);
      response.headers.set(HttpHeaders.retryAfterHeader, '2');
      return _reply(
        response,
        HttpStatus.conflict,
        'A download is already active.',
      );
    }
    _transferring = true;
    _activeBook = book;
    response.bufferOutput = false;
    book.sent = 0;
    _sentBytes = _books.fold(0, (sum, b) => sum + b.sent);
    _transferred = _books.every((b) => b.completed);
    _error = null;
    _notify();
    try {
      // Count bytes flushed to the HTTP transport, never elapsed time.
      // TCP delivery or a reader opening is not observable.
      final session = _sessionToken;
      await for (final chunk in book.file.openRead(start, end + 1)) {
        if (_server == null || _sessionToken != session || _expired) {
          throw StateError('Transfer stopped.');
        }
        response.add(chunk);
        await response.flush();
        // Dart HttpResponse can suppress socket errors. A closed connection
        // must not count discarded buffers as sent or complete the transfer.
        if (request.connectionInfo == null) {
          throw StateError('The reader disconnected.');
        }
        book.sent += chunk.length;
        _sentBytes = _books.fold(0, (sum, b) => sum + b.sent);
        _notify();
      }
      await response.close();
      if (start == 0 && end == book.length - 1 && _server != null) {
        book.completed = true;
      }
      _transferred = _books.every((b) => b.completed);
    } finally {
      _transferring = false;
      _activeBook = null;
      _notify();
    }
  }

  Future<void> _badRange(HttpResponse response, int length) {
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
    return _reply(
      response,
      HttpStatus.requestedRangeNotSatisfiable,
      'Invalid range.',
    );
  }

  Future<void> _reply(
    HttpResponse response,
    int status,
    String body, {
    bool head = false,
  }) async {
    response.statusCode = status;
    final encoded = utf8.encode(body);
    response.headers.contentType ??= ContentType.text;
    response.contentLength = encoded.length;
    if (!head) response.add(encoded);
    await response.close();
  }

  bool _authorized(HttpRequest request) =>
      paired && _cookie(request) == _sessionToken;
  String? _cookie(HttpRequest request) {
    final cookies = request.cookies
        .where((cookie) => cookie.name == _cookieName)
        .toList();
    return cookies.length == 1 ? cookies.single.value : null;
  }

  void _setCookie(HttpResponse response, String value) {
    // Secure cannot be used for this explicitly HTTP-only LAN PoC.
    response.headers.add(
      HttpHeaders.setCookieHeader,
      '$_cookieName=$value; Path=/; HttpOnly; SameSite=Strict; Max-Age=900',
    );
  }

  String _token() =>
      base64UrlEncode(List<int>.generate(32, (_) => _random.nextInt(256)))
          .replaceAll('=', '');
  static bool _isLocalV4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return address.isLoopback ||
        b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  static String _disposition(String name) {
    var asciiName = name.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    if (asciiName.length > 100) {
      final extension = transferExtension(name);
      asciiName = '${asciiName.substring(0, 99 - extension.length)}.$extension';
    }
    final displayName = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_');
    return 'attachment; filename="$asciiName"; filename*=UTF-8\'\'${Uri.encodeComponent(displayName)}';
  }

  bool _sameOrigin(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'http' &&
        uri.host == _url!.host &&
        uri.port == _url!.port &&
        uri.userInfo.isEmpty;
  }

  Future<void> _writeLease(Directory storage, DateTime expiry) =>
      File('${storage.path}${Platform.pathSeparator}.brizfi-owned')
          .writeAsString(
            'brizfi-transfer-v1\n${expiry.millisecondsSinceEpoch}\n',
          )
          .then((_) {});

  Future<Directory> _prepareCache() async {
    var cache = Directory(
      '${_temporaryRoot.path}${Platform.pathSeparator}brizfi-transfer-cache',
    );
    final cacheType = await FileSystemEntity.type(
      cache.path,
      followLinks: false,
    );
    if (cacheType == FileSystemEntityType.notFound) {
      await cache.create();
    } else if (cacheType != FileSystemEntityType.directory) {
      throw StateError('The temporary cache is not a directory.');
    }
    cache = Directory(await cache.resolveSymbolicLinks());
    var inspected = 0;
    await for (final entry in cache.list(followLinks: false)) {
      if (++inspected > 4096) {
        throw const TransferStorageFailure('storage_unavailable');
      }
      if (entry is! Directory ||
          _liveCopies.containsKey(entry.path) ||
          !entry.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last
              .startsWith('job-')) {
        continue;
      }
      final marker = File(
        '${entry.path}${Platform.pathSeparator}.brizfi-owned',
      );
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await marker.length() > 128) {
        continue;
      }
      final lease = (await marker.readAsString()).split('\n');
      final expiry = lease.length == 3 && lease[0] == 'brizfi-transfer-v1'
          ? int.tryParse(lease[1])
          : null;
      if (expiry == null || _clock().millisecondsSinceEpoch < expiry) continue;
      final contents = await entry
          .list(followLinks: false)
          .take(maxBooks + 3)
          .toList();
      // Recognize our exact layout, and never follow links or remove other data.
      if (contents.any(
        (item) =>
            item is! File ||
            !{
                  '.brizfi-owned',
                  'book.azw3',
                }.contains(item.uri.pathSegments.last) &&
                !RegExp(r'^book-[0-9]\.(azw3|mobi|epub|pdf|txt)$')
                    .hasMatch(item.uri.pathSegments.last),
      )) {
        continue;
      }
      try {
        await entry.delete(recursive: true);
      } on FileSystemException {
        // An open file or unavailable storage can be retried at the next start.
      }
    }
    return cache;
  }

  static Future<T> _withCacheLock<T>(Future<T> Function() action) async {
    final previous = _cacheGate;
    final done = Completer<void>();
    _cacheGate = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<Directory> _allocateCopy(int length) => _withCacheLock(() async {
    final cache = await _prepareCache();
    var bytes = 0;
    var entries = 0;
    Future<int> measure(Directory directory, [int depth = 0]) async {
      if (depth > 64) {
        throw const TransferStorageFailure('storage_unavailable');
      }
      var total = 0;
      await for (final entry in directory.list(followLinks: false)) {
        if (++entries > 4096 || entry is Link) {
          throw const TransferStorageFailure('storage_unavailable');
        }
        if (entry is File) {
          total += await entry.length();
        } else if (entry is Directory) {
          total += await measure(entry, depth + 1);
        }
        if (total > cacheLimitBytes) {
          throw const TransferStorageFailure('cache_full');
        }
      }
      return total;
    }

    await for (final entry in cache.list(followLinks: false)) {
      if (++entries > 4096 || entry is Link) {
        throw const TransferStorageFailure('storage_unavailable');
      }
      if (entry is Directory) {
        final actual = await measure(entry);
        bytes += max(actual, _liveCopies[entry.path] ?? 0);
      } else if (entry is File) {
        bytes += await entry.length();
      }
      if (bytes > cacheLimitBytes) {
        throw const TransferStorageFailure('cache_full');
      }
    }
    final allocation = length + _leaseAllowance;
    if (bytes + allocation > cacheLimitBytes) {
      throw const TransferStorageFailure('cache_full');
    }
    final directory = await cache.createTemp('job-');
    _liveCopies[directory.path] = allocation;
    return directory;
  });

  Future<void> _removeCopy() async {
    final storage = _storage;
    _storage = null;
    _books.clear();
    if (storage != null) {
      await _deleteStorage(storage);
    }
  }

  Future<void> _deleteStorage(Directory storage) => _withCacheLock(() async {
    try {
      if (await storage.exists()) await storage.delete(recursive: true);
    } finally {
      _liveCopies.remove(storage.path);
    }
  });

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
