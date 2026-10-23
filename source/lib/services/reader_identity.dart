import 'package:flutter/services.dart';

import 'reader_profile.dart';

enum ReaderBrand { kindle, nook, kobo, pocketbook, onyx, other }

/// Identification is a hint, never authorization or proof of file support.
class ReaderIdentity {
  const ReaderIdentity(this.key, this.brand, {this.isUnique = true});
  final String key;
  final ReaderBrand brand;
  final bool isUnique;

  static ReaderBrand detectUserAgent(String value) {
    // Bound untrusted metadata and require brand tokens, not substrings.
    if (value.length > 1024) return ReaderBrand.other;
    final matches = <ReaderBrand>{};
    for (final entry in {
      ReaderBrand.kindle: r'\bKindle\b',
      ReaderBrand.nook: r'\bNOOK\b',
      ReaderBrand.kobo: r'\bKobo\b',
      ReaderBrand.pocketbook: r'\bPocketBook\b',
      ReaderBrand.onyx: r'\b(ONYX|BOOX)\b',
    }.entries) {
      if (RegExp(entry.value, caseSensitive: false).hasMatch(value)) {
        matches.add(entry.key);
      }
    }
    return matches.length == 1 ? matches.single : ReaderBrand.other;
  }

  static ReaderBrand fromProfile(ReaderProfile profile) => switch (profile.id) {
    'kindle' || 'kindle-azw3' => ReaderBrand.kindle,
    'nook' => ReaderBrand.nook,
    _ => ReaderBrand.other,
  };

  static ReaderProfile profileFor(ReaderBrand brand) => switch (brand) {
    ReaderBrand.kindle => ReaderProfile.kindle,
    ReaderBrand.nook => ReaderProfile.nook,
    _ => ReaderProfile.generic,
  };
}

/// Local preferences only. Stored identity never grants access to a book.
class ReaderPreferences {
  static const channel = MethodChannel('ru.mkulkov.brizfi/reader_preferences');
  final Map<String, ReaderBrand> _choices = {};

  Future<void> load() async {
    try {
      final values = await channel.invokeMapMethod<String, String>('read');
      for (final entry in (values ?? <String, String>{}).entries.take(128)) {
        final brand = ReaderBrand.values
            .where((b) => b.name == entry.value)
            .firstOrNull;
        if (brand != null && entry.key.length <= 160) {
          _choices[entry.key] = brand;
        }
      }
    } on MissingPluginException {
      // Test hosts and unsupported platforms retain choices for this run.
    } on PlatformException {
      // First connection remains usable; a failed write is surfaced on save.
    }
  }

  ReaderBrand? choice(String key) => _choices[key];

  Future<void> save(String key, ReaderBrand brand) async {
    try {
      await channel.invokeMethod<void>('write', {
        'key': key,
        'brand': brand.name,
      });
    } on PlatformException {
      throw PlatformException(code: 'reader_preferences_unavailable');
    }
    _choices[key] = brand;
  }
}
