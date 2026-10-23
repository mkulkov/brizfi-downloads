// ES5 and XMLHttpRequest for older reader browsers. No external resources.
const readerBatchScript = r'''
(function () {
  var start = document.getElementById('download-all');
  var stop = document.getElementById('stop-downloads');
  var message = document.getElementById('batch-message');
  var frame = document.getElementById('batch-download');
  if (!start || !window.XMLHttpRequest || !window.JSON) return;
  function text(name) { return message.getAttribute('data-' + name); }
  var running = false, timer = null, xhr = null, current = -1;
  var lastBytes = -1, lastProgress = 0;
  function finish(text) {
    running = false;
    clearTimeout(timer);
    if (xhr) {
      xhr.onreadystatechange = null; xhr.onerror = null; xhr.ontimeout = null;
      xhr.abort(); xhr = null;
    }
    start.disabled = false;
    stop.hidden = true;
    message.textContent = text;
  }
  function failed() {
    finish(text('failed'));
    window.alert(text('failed'));
  }
  function status() {
    if (!running) return;
    xhr = new XMLHttpRequest();
    xhr.open('GET', '/status', true);
    xhr.timeout = 10000;
    xhr.onerror = failed;
    xhr.ontimeout = failed;
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4 || !running) return;
      if (xhr.status !== 200) { failed(); return; }
      var data;
      try { data = JSON.parse(xhr.responseText); } catch (e) { failed(); return; }
      xhr = null;
      if (!data.books || !data.books.length) { failed(); return; }
      for (var j = 0; j < data.books.length; j++) {
        var mark = document.getElementById('book-completed-' + j);
        if (mark) mark.hidden = !data.books[j].transferred;
      }
      if (current < 0 && data.transferring) {
        timer = setTimeout(status, 5000);
        return;
      }
      if (current >= 0 && !data.books[current].transferred) {
        var bytes = data.books[current].sentBytes;
        if (bytes !== lastBytes) { lastBytes = bytes; lastProgress = Date.now(); }
        if (Date.now() - lastProgress >= 60000) { failed(); return; }
        timer = setTimeout(status, 5000);
        return;
      }
      var next = -1;
      for (var i = 0; i < data.books.length; i++) {
        if (!data.books[i].transferred) { next = i; break; }
      }
      if (next < 0) {
        finish(text('complete'));
        return;
      }
      current = next;
      lastBytes = -1;
      lastProgress = Date.now();
      message.textContent = text('progress').replace('{current}', next + 1).replace('{total}', data.books.length);
      frame.src = '/download/' + next;
      timer = setTimeout(status, 5000);
    };
    xhr.send();
  }
  start.hidden = false;
  start.onclick = function () {
    if (running) return;
    running = true;
    current = -1;
    start.disabled = true;
    stop.hidden = false;
    message.textContent = text('starting');
    status();
  };
  stop.onclick = function () {
    finish(text('stopped'));
  };
  window.addEventListener('pagehide', function () {
    finish(text('stopped'));
  });
}());
''';
