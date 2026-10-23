import 'dart:async';
import 'dart:io';

import 'package:brizfi/services/usb_transfer.dart';
import 'package:brizfi/services/reader_identity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source;
  late UsbTransfer usb;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('brizfi-usb-test-');
    source = await File('${root.path}/own.azw3')
        .writeAsBytes(List.filled(100, 0));
    usb = UsbTransfer();
  });
  tearDown(() async {
    usb.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UsbTransfer.channel, null);
    await root.delete(recursive: true);
  });

  test('USB brand hint is independent of writable format profile', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          UsbTransfer.channel,
          (call) async => [
            {
              'id': 9,
              'name': 'PocketBook USB',
              'brand': 'pocketbook',
              'profile': 'unknown',
              'formats': <String>[],
              'transport': 'massStorage',
              'identityKey': 'usb:test-pocketbook',
              'identityIsUnique': false,
              'model': null,
            },
          ],
        );
    final reader = (await usb.listReaders()).single;
    expect(reader.detectedBrand, ReaderBrand.pocketbook);
    expect(reader.profile.formats, isEmpty);
    expect(reader.profile.targetFor('epub'), isNull);
    expect(reader.identityIsUnique, isFalse);
    expect(reader.modelVerified, isFalse);
  });

  test(
    'receipt requires matching byte count; failure retains source',
    () async {
      var bytes = 99;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(UsbTransfer.channel, (call) async {
            expect(call.method, 'sendBook');
            expect(call.arguments, {'deviceId': 7, 'path': source.path});
            return {'bytes': bytes, 'name': 'brizfi-test.azw3'};
          });
      await expectLater(
        usb.send(source, 7),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'usb_verification_failed',
          ),
        ),
      );
      expect(await source.length(), 100);
      bytes = 100;
      final receipt = await usb.send(source, 7);
      expect(receipt.bytes, 100);
      expect(receipt.name, 'brizfi-test.azw3');
    },
  );

  test('cancel keeps active ownership until native job completes', () async {
    final started = Completer<void>();
    final nativeResult = Completer<Map<String, Object>>();
    var cancelled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UsbTransfer.channel, (call) async {
          if (call.method == 'cancel') {
            cancelled = true;
            return null;
          }
          started.complete();
          return nativeResult.future;
        });
    final task = usb.send(source, 7);
    final failed = expectLater(
      task,
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'usb_cancelled'),
      ),
    );
    await started.future;
    await usb.cancel();
    expect(cancelled, isTrue);
    await expectLater(
      usb.send(source, 7),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'busy')),
    );
    expect(await source.exists(), isTrue);
    nativeResult.completeError(PlatformException(code: 'usb_cancelled'));
    await failed;
    expect(usb.phase, isNull);
  });

  test(
    'malformed reader list and undersized input fail before writing',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(UsbTransfer.channel, (call) async {
            calls++;
            return [
              {'id': 'bad', 'name': 'Kindle'},
            ];
          });
      await expectLater(usb.listReaders(), throwsA(isA<PlatformException>()));
      await source.writeAsBytes([0]);
      await expectLater(
        usb.send(source, 7),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'usb_invalid_file',
          ),
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'busy USB uses system folder with the same source and verifies receipt',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(UsbTransfer.channel, (call) async {
            calls.add(call.method);
            expect(call.arguments, {'deviceId': 7, 'path': source.path});
            if (call.method == 'sendBook') {
              throw PlatformException(code: 'usb_busy');
            }
            expect(usb.phase, 'selectingFolder');
            return {'bytes': 100, 'name': 'brizfi-folder.azw3'};
          });
      expect((await usb.send(source, 7)).bytes, 100);
      expect(calls, ['sendBook', 'sendBookViaDocuments']);
      expect(await source.exists(), isTrue);
    },
  );

  test('USB open failure does not open a folder picker', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UsbTransfer.channel, (call) async {
          calls.add(call.method);
          throw PlatformException(code: 'usb_open_failed');
        });
    await expectLater(usb.send(source, 7), throwsA(isA<PlatformException>()));
    expect(calls, ['sendBook']);
  });

  test('cancellation before busy response prevents folder fallback', () async {
    final started = Completer<void>();
    final native = Completer<Map<String, Object>>();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UsbTransfer.channel, (call) async {
          calls.add(call.method);
          if (call.method == 'cancel') return null;
          started.complete();
          return native.future;
        });
    final task = usb.send(source, 7);
    final failure = expectLater(
      task,
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'usb_cancelled',
        ),
      ),
    );
    await started.future;
    await usb.cancel();
    native.completeError(PlatformException(code: 'usb_busy'));
    await failure;
    expect(calls, ['sendBook', 'cancel']);
  });

  test('NOOK metadata and EPUB receipt keep their real format', () async {
    source = await File('${root.path}/own.epub')
        .writeAsBytes(List.filled(100, 0));
    var wrongFormat = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(UsbTransfer.channel, (call) async {
          if (call.method == 'listDevices') {
            return [
              {
                'id': 8,
                'name': 'NOOK',
                'profile': 'nook',
                'transport': 'massStorage',
                'formats': ['epub', 'pdf'],
              },
            ];
          }
          return {
            'bytes': 100,
            'name': wrongFormat ? 'brizfi-wrong.azw3' : 'brizfi-own.epub',
          };
        });
    final reader = (await usb.listReaders()).single;
    expect(reader.profile.formats, {'epub', 'pdf'});
    expect(reader.transport, 'massStorage');
    await expectLater(
      usb.send(source, 8),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'usb_verification_failed',
        ),
      ),
    );
    wrongFormat = false;
    expect((await usb.send(source, 8)).name, 'brizfi-own.epub');
  });

  test('unidentified reader does not inherit Kindle capabilities', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          UsbTransfer.channel,
          (call) async => [
            {
              'id': 9,
              'name': 'USB device',
              'profile': 'unidentified',
              'formats': ['epub'],
            },
          ],
        );
    expect((await usb.listReaders()).single.profile.formats, isEmpty);
  });
}
