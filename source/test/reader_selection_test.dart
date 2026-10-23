import 'dart:io';

import 'package:brizfi/main.dart';
import 'package:brizfi/services/conversion_service.dart';
import 'package:brizfi/services/reader_profile.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class ProfileUsb extends UsbTransfer {
  final sent = <String>[];
  List<UsbReader> available = const [
    UsbReader(1, 'Kindle', profile: ReaderProfile.kindle),
    UsbReader(2, 'NOOK', profile: ReaderProfile.nook, transport: 'massStorage'),
  ];
  @override
  Future<List<UsbReader>> listReaders() async => available;
  @override
  Future<UsbReceipt> send(File file, int deviceId) async {
    sent.add('$deviceId:${file.path}');
    return UsbReceipt(100, 'brizfi-test.${ReaderProfile.formatOf(file.path)}');
  }
}

class ProfileConverter extends ConversionService {
  final calls = <String>[];
  @override
  Future<File> convert(File input, {String targetFormat = 'azw3'}) async {
    calls.add('${input.path}:$targetFormat');
    return File('${input.path}.converted.$targetFormat');
  }
}

class PairedWifiProfileServer extends ReaderServer {
  @override
  bool get paired => true;
}

void main() {
  testWidgets(
    'Android Wi-Fi profile controls target and preserves native originals',
    (tester) async {
      final converter = ProfileConverter();
      await tester.pumpWidget(
        BrizfiApp(
          home: PocScreen(
            server: PairedWifiProfileServer(),
            enableWifiProfiles: true,
            conversionService: converter,
            enableUsb: false,
            receiveShares: false,
            loadAddresses: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Other'),
        findsNothing,
      ); // No reader has contacted this fake server.
      expect(find.text('NOOK'), findsNothing);
      final dynamic state = tester.state(find.byType(PocScreen));
      await state.selectWifiProfile(ReaderProfile.nook);
      await state.acceptBooks([
        'native.epub',
        'book.fb2',
        'original.pdf',
        'notes.txt',
      ]);
      await tester.pumpAndSettle();
      expect(converter.calls, ['book.fb2:epub', 'notes.txt:epub']);
      expect((state.books as List).map((dynamic item) => item.ready.path), [
        'native.epub',
        'book.fb2.converted.epub',
        'original.pdf',
        'notes.txt.converted.epub',
      ]);
      await state.selectWifiProfile(ReaderProfile.kindle);
      await tester.pumpAndSettle();
      expect(state.preparedBook.path, 'native.epub.converted.azw3');
      expect(converter.calls, [
        'book.fb2:epub',
        'notes.txt:epub',
        'native.epub:azw3',
        'book.fb2:azw3',
      ]);
      expect((state.books as List).last.ready.path, 'notes.txt');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'switching reader replans books; native originals bypass converter',
    (tester) async {
      final usb = ProfileUsb();
      final converter = ProfileConverter();
      await tester.pumpWidget(
        BrizfiApp(
          home: PocScreen(
            usbTransfer: usb,
            conversionService: converter,
            enableUsb: true,
            receiveShares: false,
            loadAddresses: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PocScreen));
      state.changeMode(TransferMode.usb);
      await tester.pumpAndSettle();
      await state.selectUsbReader(2);
      await state.confirmReader();
      await state.acceptBooks(['own.epub', 'own.fb2', 'own.pdf']);
      await tester.pumpAndSettle();
      expect(converter.calls, ['own.fb2:epub']);
      expect(state.preparedBook.path, 'own.epub');
      await state.sendParcel();
      await tester.pumpAndSettle();
      expect(usb.sent, ['2:own.epub', '2:own.fb2.converted.epub', '2:own.pdf']);

      // Change the receiver with the same selection: EPUB/FB2 need AZW3 now.
      await state.selectUsbReader(1);
      await state.confirmReader();
      await tester.pumpAndSettle();
      expect(converter.calls, [
        'own.fb2:epub',
        'own.epub:azw3',
        'own.fb2:azw3',
      ]);
      expect(state.preparedBook.path, 'own.epub.converted.azw3');
      await state.selectUsbReader(2);
      await state.confirmReader();
      await tester.pumpAndSettle();
      expect(state.preparedBook.path, 'own.epub');
      expect(
        converter.calls.length,
        3,
        reason: 'reuse the already prepared EPUB',
      );
      await state.sendParcel();
      expect(state.usbReceipt, isNotNull);
      // Unplug NOOK and discover the only remaining reader automatically.
      usb.available = const [
        UsbReader(1, 'Kindle', profile: ReaderProfile.kindle),
      ];
      await state.findUsbReaders();
      await tester.pumpAndSettle();
      expect(state.usbDeviceId, 1);
      expect(state.usbReceipt, isNull);
      expect(
        (state.books as List).every((dynamic book) => book.receipt == null),
        isTrue,
      );
      expect(state.preparedBook.path, 'own.epub.converted.azw3');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('unsupported source never enables send or invokes converter', (
    tester,
  ) async {
    final usb = ProfileUsb();
    final converter = ProfileConverter();
    await tester.pumpWidget(
      BrizfiApp(
        home: PocScreen(
          usbTransfer: usb,
          conversionService: converter,
          enableUsb: true,
          receiveShares: false,
          loadAddresses: () async => [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(PocScreen));
    state.changeMode(TransferMode.usb);
    await tester.pumpAndSettle();
    await state.selectUsbReader(2);
    await state.acceptBooks(['protected.kfx']);
    await tester.pumpAndSettle();
    expect(state.preparedBook, isNull);
    expect(state.conversionError, 'reader_format_unsupported');
    await state.sendParcel();
    expect(usb.sent, isEmpty);
    expect(converter.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
