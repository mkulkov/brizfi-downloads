import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Bounded content gates for unchanged local downloads, not reader acceptance.
/// EPUB validation inspects ZIP metadata only and never extracts resources.
const transferMimeTypes = <String, String>{
  'azw3': 'application/vnd.amazon.mobi8-ebook',
  'mobi': 'application/x-mobipocket-ebook',
  'epub': 'application/epub+zip',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
};

String transferExtension(String name) => name.lastIndexOf('.') > 0
    ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
    : '';

Future<void> validateTransferBook(
  File file,
  String extension, {
  bool legacyPalmHeader = false,
}) async {
  // Check before allocating, then use a bounded stream to handle file mutation.
  const limit = 32 * 1024 * 1024;
  final length = await file.length();
  if (length == 0 || length > limit) _invalid();
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (builder.length + chunk.length > limit) _invalid();
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  if (bytes.length != length) _invalid();
  switch (extension) {
    case 'azw3':
    case 'mobi':
      _palm(bytes, legacyPalmHeader: legacyPalmHeader);
    case 'epub':
      _epub(bytes);
    case 'pdf':
      final prefix = latin1.decode(bytes.take(1024).toList());
      final suffix = latin1.decode(
        bytes.sublist(bytes.length > 1024 ? bytes.length - 1024 : 0),
      );
      // This conservative gate also rejects indirect/escaped Encrypt names.
      final content = latin1
          .decode(bytes)
          .replaceAllMapped(
            RegExp(r'#([0-9a-fA-F]{2})'),
            (match) => String.fromCharCode(int.parse(match[1]!, radix: 16)),
          );
      if (!prefix.contains('%PDF-') ||
          !suffix.contains('%%EOF') ||
          content.contains('/Encrypt')) {
        _invalid();
      }
    case 'txt':
      utf8.decode(bytes, allowMalformed: false);
      if (bytes.any(
        (b) => (b < 32 && b != 9 && b != 10 && b != 13) || b == 127,
      )) {
        _invalid();
      }
    default:
      _invalid();
  }
}

Never _invalid() =>
    throw const FormatException('Unsupported, protected or malformed book.');

int _u16(Uint8List b, int p) {
  if (p < 0 || p + 2 > b.length) _invalid();
  return b[p] | (b[p + 1] << 8);
}

int _u32(Uint8List b, int p) => _u16(b, p) | (_u16(b, p + 2) << 16);

int _be32(Uint8List b, int p) {
  if (p < 0 || p + 4 > b.length) _invalid();
  return (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
}

void _palm(Uint8List b, {required bool legacyPalmHeader}) {
  if (b.length < 86 || ascii.decode(b.sublist(60, 68)) != 'BOOKMOBI') {
    _invalid();
  }
  final count = (b[76] << 8) | b[77];
  if (count == 0 || count > 4096 || 78 + count * 8 > b.length) _invalid();
  var previous = 78 + count * 8 - 1;
  for (var i = 0; i < count; i++) {
    final offset = _be32(b, 78 + i * 8);
    if (offset <= previous || offset >= b.length) _invalid();
    previous = offset;
  }
  // Retain the original AZW3-only PoC's explicit header-only contract.
  if (legacyPalmHeader) return;
  final record = _be32(b, 78);
  if (record + 24 > b.length ||
      ascii.decode(b.sublist(record + 16, record + 20)) != 'MOBI' ||
      b[record + 12] != 0 ||
      b[record + 13] != 0) {
    _invalid();
  }
}

void _epub(Uint8List b) {
  const mime = 'application/epub+zip';
  if (b.length < 58 ||
      _u32(b, 0) != 0x04034b50 ||
      (_u16(b, 6) & ~0x800) != 0 ||
      _u16(b, 8) != 0 ||
      _u32(b, 18) != mime.length ||
      _u32(b, 22) != mime.length ||
      _u16(b, 26) != 8 ||
      _u16(b, 28) != 0 ||
      latin1.decode(b.sublist(30, 38)) != 'mimetype' ||
      latin1.decode(b.sublist(38, 38 + mime.length)) != mime) {
    _invalid();
  }
  var end = b.length - 22;
  final minimum = b.length > 65557 ? b.length - 65557 : 0;
  while (_u32(b, end) != 0x06054b50 ||
      end + 22 + _u16(b, end + 20) != b.length) {
    if (end == minimum) _invalid();
    end--;
  }
  final count = _u16(b, end + 10);
  final central = _u32(b, end + 16);
  if (_u16(b, end + 4) != 0 ||
      _u16(b, end + 6) != 0 ||
      count == 0 ||
      count > 4096 ||
      count != _u16(b, end + 8) ||
      central > end ||
      _u32(b, end + 12) != end - central) {
    _invalid();
  }
  var offset = central;
  var expanded = 0;
  var container = false;
  var mimetype = false;
  final names = <String>{};
  final spans = <(int, int)>[];
  for (var i = 0; i < count; i++) {
    if (offset + 46 > end || _u32(b, offset) != 0x02014b50) _invalid();
    final nameSize = _u16(b, offset + 28);
    final entrySize =
        46 + nameSize + _u16(b, offset + 30) + _u16(b, offset + 32);
    final flags = _u16(b, offset + 8);
    final method = _u16(b, offset + 10);
    final compressed = _u32(b, offset + 20);
    final uncompressed = _u32(b, offset + 24);
    expanded += uncompressed;
    if (offset + entrySize > end ||
        _u16(b, offset + 34) != 0 ||
        (flags & ~0x80e) != 0 ||
        (method != 0 && method != 8) ||
        (method == 0 && compressed != uncompressed) ||
        expanded > 128 * 1024 * 1024) {
      _invalid();
    }
    final name = utf8.decode(b.sublist(offset + 46, offset + 46 + nameSize));
    final canonical = name.toLowerCase();
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        name.contains('\x00') ||
        name.split('/').contains('..') ||
        !names.add(canonical) ||
        canonical == 'meta-inf/encryption.xml' ||
        canonical == 'meta-inf/rights.xml') {
      _invalid();
    }
    final local = _u32(b, offset + 42);
    if (local + 30 > central ||
        _u32(b, local) != 0x04034b50 ||
        _u16(b, local + 6) != flags ||
        _u16(b, local + 8) != method ||
        _u16(b, local + 26) != nameSize) {
      _invalid();
    }
    final data = local + 30 + nameSize + _u16(b, local + 28);
    if (data + compressed > central ||
        latin1.decode(b.sublist(local + 30, local + 30 + nameSize)) !=
            latin1.decode(b.sublist(offset + 46, offset + 46 + nameSize)) ||
        ((flags & 8) == 0 &&
            (_u32(b, local + 18) != compressed ||
                _u32(b, local + 22) != uncompressed ||
                _u32(b, local + 14) != _u32(b, offset + 16)))) {
      _invalid();
    }
    spans.add((local, data + compressed));
    if (name == 'mimetype') {
      if (local != 0) _invalid();
      mimetype = true;
    }
    if (name == 'META-INF/container.xml' && uncompressed > 0) container = true;
    offset += entrySize;
  }
  spans.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < spans.length; i++) {
    if (spans[i].$1 < spans[i - 1].$2) _invalid();
  }
  if (offset != end || !container || !mimetype) _invalid();
}
