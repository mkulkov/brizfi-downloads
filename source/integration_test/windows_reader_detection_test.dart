import 'dart:io';

import 'package:brizfi/services/usb_transfer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Read-only hardware probe. Does not import, send, or delete any books.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows native USB reader detection', (tester) async {
    expect(Platform.isWindows, isTrue);
    const expected = int.fromEnvironment(
      'BRIZFI_EXPECT_READERS',
      defaultValue: -1,
    );
    expect(
      expected,
      greaterThanOrEqualTo(0),
      reason: 'Supply the independently expected supported reader count',
    );
    final transfer = UsbTransfer();
    try {
      final readers = await transfer.listReaders();
      // ignore: avoid_print
      print(
        'BRIZFI_USB_DETECTION count=${readers.length} '
        'names=${readers.map((reader) => reader.name).toList()}',
      );
      expect(readers, hasLength(expected));
    } finally {
      transfer.dispose();
    }
  });
}
