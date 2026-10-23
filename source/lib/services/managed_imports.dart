import 'dart:io';

import 'package:flutter/services.dart';

/// Only native SAF-owned UUID directories qualify. The native implementation
/// rechecks canonical containment and its ownership marker before any deletion.
class ManagedImports {
  static const channel = MethodChannel('ru.mkulkov.brizfi/import');

  static bool hasManagedLayout(File file) {
    final parts = file.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return parts.length >= 3 &&
        parts[parts.length - 3] == 'brizfi_imports' &&
        RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(parts[parts.length - 2]);
  }

  static Future<void> reserve(File file) =>
      channel.invokeMethod<void>('reserveConversion', {'path': file.path});

  static Future<void> finish(File file) =>
      channel.invokeMethod<void>('finishConversion', {'path': file.path});

  static Future<void> release(File file) =>
      channel.invokeMethod<void>('releaseImport', {'path': file.path});
}
