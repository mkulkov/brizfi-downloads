import 'dart:io';

import 'package:brizfi/services/local_network.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('private IPv4 filtering is separate from adapter eligibility', () {
    for (final address in ['10.8.1.33', '172.16.25.5', '192.168.1.2']) {
      expect(LocalNetwork.isPrivateIpv4(InternetAddress(address)), isTrue);
    }
    for (final address in ['127.0.0.1', '169.254.1.2', '8.8.8.8', '::1']) {
      expect(LocalNetwork.isPrivateIpv4(InternetAddress(address)), isFalse);
    }
  });

  test(
    'Windows trusts native physical LAN list, not all private addresses',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(LocalNetwork.channel, (call) async {
        expect(call.method, 'lanAddresses');
        return ['172.16.25.5', '127.0.0.1', '169.254.1.2', 'bad-address'];
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(LocalNetwork.channel, null),
      );
      expect((await LocalNetwork.addresses()).map((a) => a.address), [
        '172.16.25.5',
      ]);
    },
    skip: !Platform.isWindows,
  );

  test('native failure cannot silently fall back to VPN interfaces', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(LocalNetwork.channel, (call) async {
      throw PlatformException(code: 'network_unavailable');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(LocalNetwork.channel, null),
    );
    await expectLater(
      LocalNetwork.addresses(),
      throwsA(isA<PlatformException>()),
    );
  }, skip: !Platform.isWindows);
}
