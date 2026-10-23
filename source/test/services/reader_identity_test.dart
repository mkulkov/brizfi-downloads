import 'package:brizfi/services/reader_identity.dart';
import 'package:brizfi/services/reader_profile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('brand tokens are bounded; ambiguous or generic browsers are Other', () {
    expect(
      ReaderIdentity.detectUserAgent('Mozilla/5.0 Kindle/3.0'),
      ReaderBrand.kindle,
    );
    expect(
      ReaderIdentity.detectUserAgent('Mozilla/5.0 (NOOK)'),
      ReaderBrand.nook,
    );
    expect(ReaderIdentity.detectUserAgent('Kobo browser'), ReaderBrand.kobo);
    expect(
      ReaderIdentity.detectUserAgent('PocketBook'),
      ReaderBrand.pocketbook,
    );
    expect(ReaderIdentity.detectUserAgent('BOOX'), ReaderBrand.onyx);
    for (final value in [
      'Chrome Android',
      'NotKindle',
      'Kindle NOOK',
      'Kindle ${'x' * 1024}',
    ]) {
      expect(ReaderIdentity.detectUserAgent(value), ReaderBrand.other);
    }
    expect(ReaderIdentity.profileFor(ReaderBrand.kobo), ReaderProfile.generic);
  });

  test('correction persists across store instances, including Other', () async {
    final disk = <String, String>{};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReaderPreferences.channel, (call) async {
      if (call.method == 'read') return disk;
      disk[call.arguments['key'] as String] = call.arguments['brand'] as String;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReaderPreferences.channel, null),
    );
    final first = ReaderPreferences();
    await first.load();
    expect(first.choice('usb:test'), isNull);
    await first.save('usb:test', ReaderBrand.other);
    final second = ReaderPreferences();
    await second.load();
    expect(second.choice('usb:test'), ReaderBrand.other);
    expect(second.choice('usb:another'), isNull);
    await second.save('usb:test', ReaderBrand.nook);
    await first.load();
    expect(first.choice('usb:test'), ReaderBrand.nook);
  });

  test('failed persistence never marks choice saved', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReaderPreferences.channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReaderPreferences.channel, null),
    );
    final store = ReaderPreferences();
    await expectLater(
      store.save('usb:test', ReaderBrand.kindle),
      throwsA(isA<PlatformException>()),
    );
    expect(store.choice('usb:test'), isNull);
  });
}
