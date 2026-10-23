import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'reader_profile.dart';
import 'reader_identity.dart';

class UsbReader {
  const UsbReader(
    this.id,
    this.name, {
    this.profile = ReaderProfile.kindleLegacy,
    this.transport = 'mtp',
    this.model,
    this.identityKey,
    this.modelVerified = false,
    this.identityIsUnique = true,
    this.detectedBrand,
  });
  final int id;
  final String name;
  final ReaderProfile profile;
  final String transport;
  final String? model;
  final String? identityKey;
  final bool modelVerified;
  final bool identityIsUnique;
  final ReaderBrand? detectedBrand;
}

class UsbReceipt {
  const UsbReceipt(this.bytes, this.name);
  final int bytes;
  final String name;
}

/// Native MTP writes and verifies off the UI thread. Completion does not imply
/// that a reader indexed or opened the book.
class UsbTransfer extends ChangeNotifier {
  static const channel = MethodChannel('ru.mkulkov.brizfi/usb');
  String? phase;
  bool _active = false;
  bool _cancelled = false;
  UsbTransfer() {
    channel.setMethodCallHandler((call) async {
      if (_active &&
          call.method == 'phase' &&
          [
            'connecting',
            'selectingFolder',
            'writing',
            'verifying',
          ].contains(call.arguments)) {
        phase = call.arguments as String;
        notifyListeners();
      }
    });
  }
  Future<List<UsbReader>> listReaders() async {
    final result = await channel.invokeListMethod<Object?>('listDevices') ?? [];
    return result.map((item) {
      if (item is! Map || item['id'] is! int || item['name'] is! String) {
        throw PlatformException(code: 'usb_unsupported');
      }
      final profileId = item['profile'];
      final formats = item['formats'];
      if ((profileId != null && profileId is! String) ||
          (formats != null &&
              (formats is! List || formats.any((value) => value is! String)))) {
        throw PlatformException(code: 'usb_unsupported');
      }
      return UsbReader(
        item['id'] as int,
        item['name'] as String,
        profile: profileId == null
            ? ((item['name'] as String).startsWith('Kindle')
                  ? ReaderProfile.kindleLegacy
                  : ReaderProfile.unknown)
            : ReaderProfile.fromNative(
                profileId as String,
                (formats as List?)?.cast<String>(),
              ),
        transport: item['transport'] is String
            ? item['transport'] as String
            : 'mtp',
        model: item['model'] is String ? item['model'] as String : null,
        identityKey: item['identityKey'] is String
            ? item['identityKey'] as String
            : null,
        modelVerified: item['modelVerified'] == true,
        identityIsUnique: item['identityIsUnique'] != false,
        detectedBrand: ReaderBrand.values
            .where((brand) => brand.name == item['brand'])
            .firstOrNull,
      );
    }).toList();
  }

  Future<UsbReceipt> send(File file, int deviceId) async {
    if (_active) throw PlatformException(code: 'busy');
    _active = true;
    _cancelled = false;
    phase = 'connecting';
    notifyListeners();
    try {
      final expected = await file.length();
      if (_cancelled) throw PlatformException(code: 'usb_cancelled');
      final extension = ReaderProfile.formatOf(file.path);
      if (!{'azw3', 'epub', 'mobi', 'pdf', 'txt'}.contains(extension) ||
          expected < (extension == 'txt' ? 1 : 86) ||
          expected > 32 * 1024 * 1024) {
        throw PlatformException(code: 'usb_invalid_file');
      }
      final arguments = {'deviceId': deviceId, 'path': file.path};
      Map<String, Object?>? result;
      try {
        result = await channel.invokeMapMethod<String, Object?>(
          'sendBook',
          arguments,
        );
      } on PlatformException catch (error) {
        if (error.code != 'usb_busy') rethrow;
        if (_cancelled) throw PlatformException(code: 'usb_cancelled');
        phase = 'selectingFolder';
        notifyListeners();
        result = await channel.invokeMapMethod<String, Object?>(
          'sendBookViaDocuments',
          arguments,
        );
      }
      if (result?['bytes'] != expected ||
          result?['name'] is! String ||
          ReaderProfile.formatOf(result!['name'] as String) != extension) {
        throw PlatformException(code: 'usb_verification_failed');
      }
      return UsbReceipt(expected, result['name'] as String);
    } finally {
      _active = false;
      phase = null;
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    if (_active) {
      _cancelled = true;
      await channel.invokeMethod<void>('cancel');
    }
  }

  @override
  void dispose() {
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
