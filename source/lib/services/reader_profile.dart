/// Conversion presets are separate from transport file access. Generic devices
/// receive supported source formats unchanged, without claiming they can open them.
class ReaderProfile {
  const ReaderProfile(this.id, this.formats, this.conversionTarget);

  final String id;
  final Set<String> formats;
  final String? conversionTarget;

  // Compatibility fallback for older native channels and legacy Wi-Fi callers.
  static const kindleLegacy = ReaderProfile('kindle-azw3', {'azw3'}, 'azw3');
  static const kindle = ReaderProfile('kindle', {
    'azw3',
    'mobi',
    'pdf',
    'txt',
  }, 'azw3');
  static const nook = ReaderProfile('nook', {'epub', 'pdf'}, 'epub');
  static const unknown = ReaderProfile('unknown', {}, null);
  static const generic = ReaderProfile('generic', {
    'azw3',
    'mobi',
    'epub',
    'pdf',
    'txt',
  }, null);

  static ReaderProfile fromNative(String? id, Iterable<String>? advertised) {
    final known = switch (id) {
      'kindle' => kindle,
      'nook' => nook,
      'generic' || 'generic-storage' || 'generic-mtp' => generic,
      _ => unknown,
    };
    // A transport may support fewer formats than the device itself.
    final formats = advertised == null
        ? known.formats
        : known.formats.intersection(advertised.toSet());
    return ReaderProfile(
      known.id,
      Set.unmodifiable(formats),
      formats.contains(known.conversionTarget) ? known.conversionTarget : null,
    );
  }

  String? targetFor(String sourceFormat) {
    if (formats.contains(sourceFormat)) return sourceFormat;
    final target = conversionTarget;
    if (target == 'azw3' &&
        {'epub', 'fb2', 'mobi', 'txt'}.contains(sourceFormat)) {
      return target;
    }
    if (target == 'epub' &&
        {'fb2', 'azw3', 'mobi', 'txt'}.contains(sourceFormat)) {
      return target;
    }
    return null;
  }

  static String formatOf(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }
}
