import 'dart:async';

import 'package:brizfi/services/reader_identity.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory replacement for the native preferences plugin in widget tests.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    // Pure HTTP tests must keep their real HttpClient and no widget binding.
    if (BindingBase.debugBindingType() == null) return;
    final saved = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPreferences.channel, (call) async {
          if (call.method == 'read') return Map<String, String>.of(saved);
          final args = call.arguments as Map;
          saved[args['key'] as String] = args['brand'] as String;
          return null;
        });
  });
  await testMain();
}
