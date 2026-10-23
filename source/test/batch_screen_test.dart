import 'dart:async';
import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/conversion_service.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:brizfi/services/usb_transfer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class BatchServer extends ReaderServer {
  @override
  bool get paired => url != null;
  Uri? active;
  List<File> received = [];
  String? receivedLanguage;
  @override
  Uri? get url => active;
  @override
  Future<void> startPage({
    required InternetAddress address,
    int port = 8080,
    String languageCode = 'en',
  }) async {
    receivedLanguage = languageCode;
    active = Uri.parse('http://127.0.0.1:8080/');
    notifyListeners();
  }

  @override
  Future<void> updateBooks(List<File> sources) async {
    received = List.of(sources);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    active = null;
    notifyListeners();
  }
}

class BatchConverter extends ConversionService {
  BatchConverter(this.outputs);
  final Map<String, File> outputs;
  final calls = <String>[];
  String? reject;
  String? gatePath;
  Completer<void>? gate;
  bool cancellation = false;
  int active = 0;
  int maxActive = 0;
  @override
  Future<File> convert(File input, {String targetFormat = 'azw3'}) async {
    calls.add(input.path);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (input.path == gatePath) await gate!.future;
      if (cancellation) throw const ConversionFailure('cancelled');
      if (input.path == reject) throw const ConversionFailure('encrypted_book');
      return outputs[input.path]!;
    } finally {
      active--;
    }
  }

  @override
  void cancel() {
    cancellation = true;
  }
}

void main() {
  const importer = MethodChannel('ru.mkulkov.brizfi/import');

  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('per-book progress and cancellation at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final converter =
          BatchConverter({
              'second.fb2': File('second.azw3'),
              'third.epub': File('third.azw3'),
            })
            ..gatePath = 'second.fb2'
            ..gate = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        (call) async => ['first.azw3', 'second.fb2', 'third.epub'],
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: scale == 2 ? Brightness.dark : Brightness.light,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: scale == 3.2,
              ),
              child: child!,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              server: BatchServer(),
              allowMultiple: true,
              enableUsb: false,
              receiveShares: false,
              conversionService: converter,
              loadAddresses: () async => [InternetAddress.loopbackIPv4],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Add books'));
        await tester.tap(find.text('Add books'));
        await tester.pump(const Duration(milliseconds: 50));
        expect(converter.calls, ['second.fb2']);
        Finder indicator(String path) =>
            find.byKey(ValueKey('preparation:$path'));
        Finder status(String path, String text) =>
            find.descendant(of: indicator(path), matching: find.text(text));
        expect(status('first.azw3', 'Ready to send'), findsOneWidget);
        expect(status('second.fb2', 'Converting…'), findsOneWidget);
        expect(status('third.epub', 'Waiting for preparation'), findsOneWidget);
        expect(
          find.descendant(
            of: indicator('second.fb2'),
            matching: find.byType(CircularProgressIndicator),
          ),
          scale == 3.2 ? findsNothing : findsOneWidget,
        );
        expect(
          tester.widget<Semantics>(indicator('second.fb2')).properties.label,
          'second.fb2: Converting…',
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Cancel conversion'));
        await tester.tap(find.text('Cancel conversion'));
        await tester.pump();
        expect(status('second.fb2', 'Cancelling…'), findsOneWidget);
        expect(find.textContaining('Waiting for conversion'), findsNothing);
        converter.gate!.complete();
        await tester.pumpAndSettle();
        expect(converter.calls, ['second.fb2']);
        expect(find.text('Books prepared: 1 of 3'), findsOneWidget);
        expect(find.text('first.azw3'), findsOneWidget);
        expect(find.text('second.fb2'), findsOneWidget);
        expect(find.text('third.epub'), findsOneWidget);
        expect(find.textContaining('Conversion cancelled'), findsOneWidget);
        expect(status('second.fb2', 'Cancelled'), findsOneWidget);
        expect(status('third.epub', 'Cancelled'), findsOneWidget);
        expect(
          find.descendant(
            of: indicator('second.fb2'),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!converter.gate!.isCompleted) converter.gate!.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
      }
    });
  }

  testWidgets('phone locale is passed for single and batch reader pages', (
    tester,
  ) async {
    for (final count in [1, 2]) {
      final server = BatchServer();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        (call) async => [for (var i = 0; i < count; i++) 'book-$i.azw3'],
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ru'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              server: server,
              allowMultiple: true,
              enableUsb: false,
              receiveShares: false,
              loadAddresses: () async => [InternetAddress.loopbackIPv4],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Добавить книги'));
        await tester.tap(find.text('Добавить книги'));
        await tester.pumpAndSettle();
        expect(server.receivedLanguage, 'ru');
        await tapJourney(tester, 'Отправить книги');
        expect(server.received.length, count);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
      }
    }
  });

  testWidgets(
    'batch conversion is sequential; retry keeps ready books; picker failure preserves batch',
    (tester) async {
      final server = BatchServer();
      final files = [
        File('first.epub'),
        File('second.fb2'),
        File('third.azw3'),
      ];
      final converter = BatchConverter({
        files[0].path: File('first.azw3'),
        files[1].path: File('second.azw3'),
      })..reject = files[1].path;
      var rejectPicker = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(importer, (
        call,
      ) async {
        expect(call.method, 'pickBooks');
        if (rejectPicker) throw PlatformException(code: 'too_many_books');
        return files.map((f) => f.path).toList();
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              server: server,
              allowMultiple: true,
              enableUsb: false,
              receiveShares: false,
              conversionService: converter,
              loadAddresses: () async => [InternetAddress.loopbackIPv4],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Add books'));
        await tester.tap(find.text('Add books'));
        await tester.pumpAndSettle();
        expect(find.text('Books prepared: 2 of 3'), findsOneWidget);
        expect(converter.maxActive, 1);
        expect(converter.calls, [files[0].path, files[1].path]);
        expect(server.received, isEmpty);
        converter.reject = null;
        await tester.ensureVisible(find.text('Retry conversion'));
        await tester.tap(find.text('Retry conversion'));
        await tester.pumpAndSettle();
        expect(converter.calls, [files[0].path, files[1].path, files[1].path]);
        expect(find.text('Books prepared: 3 of 3'), findsOneWidget);
        rejectPicker = true;
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Add books'));
        await tester.tap(find.text('Add books'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Select up to 10 books at a time'),
          findsOneWidget,
        );
        expect(find.text('Books prepared: 3 of 3'), findsOneWidget);
        await tester.pumpAndSettle();
        await tapJourney(tester, 'Send books');
        expect(server.received.map((f) => f.path), [
          'first.azw3',
          'second.azw3',
          'third.azw3',
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
      }
    },
  );

  testWidgets(
    'USB batch stops at failure, retains verified books and retries only selected remainder',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('brizfi-batch-ui-'),
      ))!;
      final files = (await tester.runAsync(
        () async => [
          for (var i = 0; i < 3; i++)
            await File('${root.path}/book-$i.azw3')
                .writeAsBytes(List.filled(100, i)),
        ],
      ))!;
      var fail = true;
      final writes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        importer,
        (call) async => files.map((f) => f.path).toList(),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        UsbTransfer.channel,
        (call) async {
          if (call.method == 'listDevices') {
            return [
              {'id': 7, 'name': 'Kindle USB'},
            ];
          }
          if (call.method == 'sendBook') {
            final path = call.arguments['path'] as String;
            writes.add(path);
            if (fail && path == files[1].path) {
              throw PlatformException(code: 'usb_permission');
            }
            return {'bytes': 100, 'name': 'brizfi-${writes.length}.azw3'};
          }
          return null;
        },
      );
      Future<void> finishIo() async {
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PocScreen(
              allowMultiple: true,
              enableUsb: true,
              receiveShares: false,
              loadAddresses: () async => [],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('USB'));
        await tester.tap(find.text('USB'));
        await tester.pumpAndSettle();
        await enterSelection(tester);
        await tester.ensureVisible(find.text('Add books'));
        await tester.tap(find.text('Add books'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Send books'));
        await tester.tap(find.text('Send books'));
        await finishIo();
        expect(writes, [files[0].path, files[1].path]);
        expect(
          find.textContaining('Books written and verified: 1 of 3'),
          findsOneWidget,
        );
        expect(
          find.textContaining('USB reader access was denied'),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.text('Remove completed books from selection'),
        );
        await tester.tap(find.text('Remove completed books from selection'));
        await tester.pumpAndSettle();
        expect(find.text('book-0.azw3'), findsNothing);
        expect(find.text('Books prepared: 2 of 2'), findsOneWidget);
        fail = false;
        await tester.ensureVisible(find.text('Send books'));
        await tester.tap(find.text('Send books'));
        await finishIo();
        expect(writes, [
          files[0].path,
          files[1].path,
          files[1].path,
          files[2].path,
        ]);
        expect(
          find.textContaining('Books written and verified: 2 of 2'),
          findsOneWidget,
        );
        for (final file in files) {
          expect(await tester.runAsync(file.exists), isTrue);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          importer,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          UsbTransfer.channel,
          null,
        );
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
