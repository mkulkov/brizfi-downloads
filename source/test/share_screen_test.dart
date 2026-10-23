import 'dart:async';
import 'dart:io';

import 'journey_test_helpers.dart';

import 'package:brizfi/l10n/app_localizations.dart';
import 'package:brizfi/main.dart';
import 'package:brizfi/services/reader_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class VisibleServer extends ReaderServer {
  @override
  bool get paired => url != null;
  Uri? active;
  bool transferring = false;
  @override
  bool get isTransferring => transferring;
  @override
  Future<void> startPage({
    required InternetAddress address,
    int port = 8080,
    String languageCode = 'en',
  }) async {
    active = Uri.parse('http://127.0.0.1:8080/');
    notifyListeners();
  }

  @override
  Future<void> updateBooks(List<File> sources) async {}
  @override
  Uri? get url => active;
  void activate() {
    transferring = true;
    active = Uri.parse('http://127.0.0.1:8080');
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    active = null;
    notifyListeners();
  }
}

void main() {
  testWidgets('cold/warm shares defer safely and rejected share retains book', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('brizfi-share-ui-'),
    ))!;
    final files = (await tester.runAsync(() async {
      return [
        await File('${root.path}/first.azw3').writeAsBytes([1, 2, 3]),
        await File('${root.path}/second.azw3').writeAsBytes([4, 5, 6]),
      ];
    }))!;
    const channel = MethodChannel('ru.mkulkov.brizfi/import');
    String? pending = files.first.path;
    String? rejection;
    var takes = 0;
    Completer<String>? picker;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'pickBook' || call.method == 'pickAzw3') {
        return picker!.future;
      }
      if (call.method == 'takeSharedBook') {
        takes++;
        if (rejection != null) {
          final code = rejection!;
          rejection = null;
          throw PlatformException(code: code);
        }
        final result = pending;
        pending = null;
        return result;
      }
      return null;
    });
    Future<void> notify(String method, [Object? value]) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, value)),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    final server = VisibleServer();
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PocScreen(
            allowMultiple: false,
            enableUsb: false,
            server: server,
            loadAddresses: () async => [InternetAddress.loopbackIPv4],
            receiveShares: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await enterSelection(tester);
      expect(find.text('first.azw3'), findsOneWidget);
      expect(takes, 1); // Cold intent recovered without a notification.

      pending = files.last.path;
      await notify('shareAvailable');
      expect(find.text('second.azw3'), findsOneWidget);

      server.activate();
      await tester.pumpAndSettle();
      pending = files.first.path;
      final before = takes;
      await notify('shareAvailable');
      expect(takes, before);
      expect(find.text('second.azw3'), findsOneWidget);
      expect(find.textContaining('A new book is waiting'), findsOneWidget);
      server.transferring = false;
      server.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('first.azw3'), findsOneWidget);
      expect(server.url, isNotNull);

      picker = Completer<String>();
      await enterSelection(tester);
      await tester.ensureVisible(find.text('Add books'));
      await tester.tap(find.text('Add books'));
      await tester.pump();
      pending = files.first.path;
      final busyTakes = takes;
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('shareAvailable'),
        ),
        (_) {},
      );
      await tester.pump();
      expect(takes, busyTakes);
      picker.complete(files.last.path);
      await tester.pumpAndSettle();
      expect(find.text('first.azw3'), findsOneWidget);
      expect(pending, isNull);

      rejection = 'multiple_books';
      await notify('shareAvailable');
      expect(find.textContaining('Send one book at a time'), findsOneWidget);
      expect(find.text('first.azw3'), findsOneWidget);
      await notify('shareRejected', 'busy');
      expect(
        find.textContaining('One book is already waiting'),
        findsOneWidget,
      );
      expect(await tester.runAsync(files.first.readAsBytes), [1, 2, 3]);
      expect(await tester.runAsync(files.last.readAsBytes), [4, 5, 6]);
      expect(tester.takeException(), isNull);
    } finally {
      if (picker != null && !picker.isCompleted) {
        picker.complete(files.last.path);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
