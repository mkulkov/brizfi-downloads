import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Host-side result collection for profile integration_test runs only.
/// No Flutter Driver extension is installed in the product entry point.
Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 3),
  responseDataCallback: (data) async {
    final directory = Directory('artifacts/evidence');
    await directory.create(recursive: true);
    await File('${directory.path}/converter-profile.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    // ignore: avoid_print
    print('BRIZFI_CONVERTER_METRICS ${jsonEncode(data)}');
  },
);
