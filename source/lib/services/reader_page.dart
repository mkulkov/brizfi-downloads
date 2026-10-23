import 'dart:convert';

import '../l10n/app_localizations.dart';

enum ReaderPageState { initial, pending, approved }

String _escape(String value) => const HtmlEscape().convert(value);

// Monochrome, system fonts and no animation: a small page for e-ink browsers.
const _readerStyles = '''
* { box-sizing: border-box; }
html { font-size: 16px; background: #fff; color: #111; }
body { margin: 0; font-family: Arial, Helvetica, sans-serif; line-height: 1.3; }
main { max-width: 560px; margin: 0 auto; padding: 12px 16px; }
header { border-bottom: 2px solid #111; padding-bottom: 8px; margin-bottom: 12px; }
h1 { font-size: 1.5rem; letter-spacing: .08em; margin: 0; line-height: 1.2; overflow-wrap: anywhere; }
h2 { font-size: 1.25rem; line-height: 1.2; margin: 6px 0 8px; overflow-wrap: anywhere; }
h3 { font-size: 1rem; margin: 12px 0 6px; }
p { margin: 0 0 8px; }
.subtitle, .note, .format, footer { font-size: .8rem; color: #444; }
.subtitle { margin: 4px 0 0; }
.eyebrow { font-size: .75rem; font-weight: bold; letter-spacing: .06em; text-transform: uppercase; margin-bottom: 6px; }
.code { text-align: center; border: 2px solid #111; padding: 8px 12px; margin: 12px 0; border-radius: 8px; }
.code p { margin: 0; }
#pairing-code { font-size: 2.5rem; font-size: clamp(2rem, 12vw, 2.5rem); font-weight: bold; letter-spacing: .15em; padding-left: .15em; line-height: 1.2; font-family: monospace; }
.connected-code { margin: 8px 0; font-size: .8rem; }
.connected-code strong { font-size: 1.4rem; letter-spacing: .1em; margin-left: 8px; }
a { color: #111; text-underline-offset: .15em; }
button, .button { display: block; width: 100%; min-height: 48px; border: 2px solid #111; border-radius: 6px; padding: 8px 12px; font: inherit; font-weight: bold; line-height: 1.4; text-align: center; text-decoration: none; background: #111; color: #fff; cursor: pointer; margin: 8px 0; }
.secondary { background: #fff; color: #111; }
.text-button { background: #fff; color: #111; font-size: .8rem; border: 0; text-decoration: underline; margin: 0; font-weight: normal; }
button:disabled { background: #ddd; color: #333; border-color: #777; cursor: default; }
a:focus, button:focus { outline: 3px solid #111; outline-offset: 4px; }
[hidden] { display: none !important; }
#batch-message:empty { display: none; }
#batch-message { border-left: 3px solid #111; padding-left: 12px; }
ol { list-style: none; padding: 0; margin: 0; }
li { border-top: 1px solid #777; padding: 8px 0; }
.book-name { display: block; font-weight: bold; overflow-wrap: anywhere; word-wrap: break-word; margin-bottom: 4px; }
.format { margin: 0; }
.book-link { display: inline-block; min-height: 48px; padding: 10px 0; }
footer { margin-top: 12px; border-top: 1px solid #777; padding-top: 8px; }
@media (max-width: 360px) { main { padding: 10px 12px; } #pairing-code { letter-spacing: .08em; padding-left: .08em; } }
@media (max-height: 540px) {
  body { line-height: 1.2; }
  main { padding-top: 8px; padding-bottom: 8px; }
  header { padding-bottom: 6px; margin-bottom: 8px; }
  h2 { margin-top: 4px; margin-bottom: 6px; }
  p { margin-bottom: 6px; }
  .code { margin: 8px 0; padding-top: 6px; padding-bottom: 6px; }
  #pairing-code { font-size: 2rem; }
  .subtitle, .eyebrow, .auto-hint { display: none; }
  .pairing-controls .button, .pairing-controls button {
    display: inline-block; vertical-align: top; width: 49%;
    margin: 4px 0; font-size: .8rem;
  }
  footer { margin-top: 8px; padding-top: 6px; }
}
''';

String renderReaderPage({
  required AppLocalizations strings,
  required ReaderPageState state,
  required String nonce,
  String? challenge,
  String? code,
  List<String> names = const [],
  List<bool> completed = const [],
  int booksRevision = 0,
  required String batchScript,
}) {
  final l = strings;
  String e(String value) => _escape(value);
  String content;
  if (state == ReaderPageState.initial) {
    content =
        '<p class="eyebrow">${e(l.readerConnection)}</p>'
        '<h2>${e(l.readerInitialTitle)}</h2><p>${e(l.readerInitialHint)}</p>'
        '<form method="post" action="/pair"><input type="hidden" name="code" value="${e(challenge!)}">'
        '<button type="submit">${e(l.readerConnect)}</button></form>';
  } else if (state == ReaderPageState.pending) {
    content =
        '<p class="eyebrow">${e(l.readerConnection)}</p>'
        '<h2>${e(l.readerWaitingTitle)}</h2><p>${e(l.readerWaitingHint)}</p>'
        '<section class="code" aria-label="${e(l.readerCodeLabel)}">'
        '<p class="note">${e(l.readerCodeLabel)}</p><p id="pairing-code">${e(code!)}</p></section>'
        '<p id="pairing-message" role="status" aria-live="polite" '
        'data-expired="${e(l.readerPairExpired)}" data-paused="${e(l.readerPaused)}">${e(l.readerPendingStatus)}</p>'
        '<p class="note auto-hint">${e(l.readerAutoHint)}</p>'
        '<div class="pairing-controls"><a class="button secondary" href="/">${e(l.readerRefresh)}</a> '
        '<button class="text-button" id="pause-pairing" type="button" hidden>${e(l.readerPause)}</button>'
        '</div>'
        '<script nonce="$nonce">$_pairingScript</script>';
  } else if (names.isEmpty) {
    content =
        '<p class="eyebrow">${e(l.readerConnected)}</p>'
        '<h2>${e(l.readerNoBooks)}</h2><p>${e(l.readerNoBooksHint)}</p>'
        '<p class="connected-code">${e(l.readerCodeLabel)}<strong id="pairing-code">${e(code!)}</strong></p>'
        '<a class="button secondary" href="/">${e(l.readerRefresh)}</a>';
  } else {
    final books = StringBuffer();
    for (var i = 0; i < names.length; i++) {
      books.write(
        '<li><span class="book-name">${e(names[i])}</span>'
        '<span id="book-completed-$i" role="status"${i < completed.length && completed[i] ? '' : ' hidden'}>'
        '<span aria-hidden="true">&#10003; </span>${e(l.transferred)}</span>'
        '<p class="format">AZW3</p>',
      );
      if (names.length > 1) {
        books.write(
          '<a class="book-link" href="/download/$i" target="brizfi-download" aria-label="${e(l.readerDownloadOne)}: ${e(names[i])}">${e(l.readerDownloadOne)}</a>',
        );
      }
      books.write('</li>');
    }
    final action = names.length == 1
        ? '<a class="button" href="/download" target="brizfi-download">${e(l.readerDownloadBook)}</a>'
        : '<button id="download-all" type="button" hidden>${e(l.readerDownloadAll)}</button>'
              '<button id="stop-downloads" class="secondary" type="button" hidden>${e(l.readerStop)}</button>'
              '<p id="batch-message" role="status" aria-live="polite" '
              'data-starting="${e(l.readerStarting)}" data-failed="${e(l.readerFailed)}" '
              'data-complete="${e(l.readerComplete)}" data-stopped="${e(l.readerStopped)}" '
              'data-progress="${e(l.readerDownloading('{current}', '{total}'))}"></p>';
    content =
        '<p class="eyebrow">${e(l.readerConnected)}</p>'
        '<h2>${e(l.readerReadyTitle)}</h2><p>${e(l.readerReadyHint)}</p>'
        '<p class="connected-code">${e(l.readerCodeLabel)}<strong id="pairing-code">${e(code!)}</strong></p>'
        '$action<h3>${e(l.readerBooks(names.length))}</h3><ol>$books</ol>'
        '<p id="reader-error" role="alert" hidden>${e(l.readerFailed)}</p>'
        '<iframe id="batch-download" name="brizfi-download" title="${e(l.readerDownloadBook)}" hidden></iframe>'
        '${names.length > 1 ? '<p class="note">${e(l.readerFallback)}</p><script nonce="$nonce">$batchScript</script>' : ''}';
  }
  if (state == ReaderPageState.approved) {
    content +=
        '<script nonce="$nonce">var brizfiBooksRevision=$booksRevision;$_booksRefreshScript</script>';
  }
  return '<!doctype html><html lang="${l.localeName}"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1"><title>BRIZFI</title>'
      '<style nonce="$nonce">$_readerStyles</style></head><body><main>'
      '<header><h1>BRIZFI</h1><p class="subtitle">${e(l.readerSubtitle)}</p></header>'
      '$content<footer>${e(l.readerPrivacy)}</footer></main></body></html>';
}

// Rare authenticated polling; one reload per changed batch, no download trigger.
const _booksRefreshScript = r'''
(function () {
  if (!window.XMLHttpRequest || !window.JSON) return;
  var timer = null, xhr = null, stopped = false;
  var frame = document.getElementById('batch-download');
  var error = document.getElementById('reader-error');
  if (frame && error) frame.onload = function () {
    // Attachments leave the frame empty. A server error renders a response body.
    var body;
    try { body = frame.contentDocument.body; } catch (e) { return; }
    if (body && body.textContent.replace(/\s/g, '')) {
      error.hidden = false;
      window.alert(error.textContent);
    }
  };
  function stop() {
    stopped = true; clearTimeout(timer);
    if (xhr) { xhr.onreadystatechange = null; xhr.abort(); }
  }
  function poll() {
    if (stopped) return;
    xhr = new XMLHttpRequest(); xhr.open('GET', '/status', true);
    xhr.timeout = 10000; xhr.onerror = stop; xhr.ontimeout = stop;
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4 || stopped) return;
      if (xhr.status !== 200) { stop(); return; }
      var data;
      try { data = JSON.parse(xhr.responseText); } catch (e) { stop(); return; }
      xhr = null;
      if (data.booksRevision !== brizfiBooksRevision) { stop(); window.location.replace('/'); }
      else {
        if (data.books) {
          for (var i = 0; i < data.books.length; i++) {
            var mark = document.getElementById('book-completed-' + i);
            if (mark) mark.hidden = !data.books[i].transferred;
          }
        }
        timer = setTimeout(poll, 5000);
      }
    };
    xhr.send();
  }
  window.addEventListener('pagehide', stop);
  timer = setTimeout(poll, 5000);
}());
''';

// Poll only this cookie's approval. Never reveal book metadata before approval.
const _pairingScript = r'''
(function () {
  var message = document.getElementById('pairing-message');
  var pause = document.getElementById('pause-pairing');
  if (!window.XMLHttpRequest || !window.JSON) return;
  var running = true, timer = null, xhr = null;
  function stop(text) {
    running = false; clearTimeout(timer); pause.hidden = true;
    if (xhr) { xhr.onreadystatechange = null; xhr.onerror = null; xhr.ontimeout = null; xhr.abort(); xhr = null; }
    if (text) message.textContent = text;
  }
  function failed() { stop(message.getAttribute('data-expired')); }
  function poll() {
    if (!running) return;
    xhr = new XMLHttpRequest(); xhr.open('GET', '/pair-status', true);
    xhr.timeout = 10000; xhr.onerror = failed; xhr.ontimeout = failed;
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4 || !running) return;
      if (xhr.status !== 200) { failed(); return; }
      var data;
      try { data = JSON.parse(xhr.responseText); } catch (e) { failed(); return; }
      xhr = null;
      if (data.state === 'approved') { stop(); window.location.replace('/'); }
      else if (data.state === 'pending') timer = setTimeout(poll, 5000);
      else failed();
    };
    xhr.send();
  }
  pause.hidden = false;
  pause.onclick = function () { stop(message.getAttribute('data-paused')); };
  window.addEventListener('pagehide', function () { stop(); });
  timer = setTimeout(poll, 5000);
}());
''';
