import 'dart:io';

import 'package:flutter/services.dart';

import '../src/rust/api/conversion.dart' as rust;
import '../src/rust/frb_generated.dart';
import 'managed_imports.dart';

class ConversionFailure implements Exception {
  const ConversionFailure(this.code);
  final String code;
}

/// One foreground conversion. Cancellation discards the result after Rust returns;
/// it cannot interrupt Boko mid-export. The caller retains input until completion.
class ConversionService {
  static Future<void>? _initialization;
  bool _active = false;
  bool _cancelled = false;

  void cancel() {
    if (_active) _cancelled = true;
  }

  Future<File> convert(File input, {String targetFormat = 'azw3'}) async {
    if (_active) throw const ConversionFailure('busy');
    final isFb2 = input.path.toLowerCase().endsWith('.fb2');
    final isEpub = input.path.toLowerCase().endsWith('.epub');
    final isMobi = input.path.toLowerCase().endsWith('.mobi');
    final isAzw3 = input.path.toLowerCase().endsWith('.azw3');
    final isTxt = input.path.toLowerCase().endsWith('.txt');
    if (!((targetFormat == 'azw3' && (isFb2 || isEpub || isMobi || isTxt)) ||
        (targetFormat == 'epub' && (isFb2 || isMobi || isAzw3 || isTxt)))) {
      throw const ConversionFailure('unsupported_format');
    }
    if (!Platform.isAndroid && !Platform.isWindows) {
      throw const ConversionFailure('platform_not_verified');
    }
    _active = true;
    _cancelled = false;
    final output = File('${input.path}.converted.$targetFormat');
    var reserved = false;
    try {
      if (ManagedImports.hasManagedLayout(input)) {
        await ManagedImports.reserve(input);
        reserved = true;
      }
      _initialization ??= RustLib.instance.initialized
          ? Future<void>.value()
          : RustLib.init();
      try {
        await _initialization;
      } catch (_) {
        _initialization =
            null; // A transient native loading failure may be retried.
        rethrow;
      }
      if (_cancelled) throw const ConversionFailure('cancelled');
      final result = isMobi || isAzw3 || isTxt
          ? await rust.convertKindle(
              input: input.path,
              output: output.path,
              targetFormat: targetFormat,
            )
          : targetFormat == 'epub'
          ? await rust.convertFb2ToEpub(input: input.path, output: output.path)
          : isFb2
          ? await rust.convertFb2(input: input.path, output: output.path)
          : await rust.convertEpub(input: input.path, output: output.path);
      if (result.errorCode != null) {
        throw ConversionFailure(result.errorCode!);
      }
      if (_cancelled) {
        await output.delete();
        throw const ConversionFailure('cancelled');
      }
      return output;
    } on ConversionFailure {
      rethrow;
    } on PlatformException catch (error) {
      throw ConversionFailure(error.code);
    } catch (_) {
      // Never expose native errors with private paths or book metadata.
      throw const ConversionFailure('conversion_failed');
    } finally {
      if (reserved) {
        try {
          await ManagedImports.finish(input);
        } on PlatformException {
          // If the Activity/channel disappeared, keep the native reservation.
          // Process restart + bounded startup cleanup recover owned stale copies.
        } on MissingPluginException {
          // Engine teardown must not turn a completed conversion into a retry
          // against an already-created output file.
        }
      }
      _active = false;
    }
  }
}
