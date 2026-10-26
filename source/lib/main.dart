import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_localizations.dart';
import 'about_screen.dart';
import 'ui/brizfi_style.dart';
import 'ui/journey_widgets.dart';
import 'services/reader_server.dart';
import 'services/conversion_service.dart';
import 'services/managed_imports.dart';
import 'services/usb_transfer.dart';
import 'services/local_network.dart';
import 'services/reader_profile.dart';
import 'services/reader_identity.dart';
import 'services/monetization.dart';
import 'services/android_monetization.dart';

enum TransferMode { wifi, usb }

enum JourneyStep { connection, books, transfer, done }

class _SelectedBook {
  _SelectedBook(this.source);
  final File source;
  File? ready;
  final outputs = <String, File>{};
  bool preparing = false;
  String? error;
  UsbReceipt? receipt;
}

void main() => runApp(const BrizfiApp());

class BrizfiApp extends StatelessWidget {
  const BrizfiApp({super.key, this.home = const PocScreen()});

  final Widget home;
  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      return CupertinoApp(
        title: 'BRIZFI',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => Theme(
          data: brizfiTheme(MediaQuery.platformBrightnessOf(context)),
          child: child!,
        ),
        home: home,
      );
    }
    return MaterialApp(
      title: 'BRIZFI',
      debugShowCheckedModeBanner: false,
      theme: brizfiTheme(Brightness.light),
      darkTheme: brizfiTheme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: Platform.isWindows
          ? (context, child) => BrizfiWindowFrame(child: child!)
          : null,
      home: home,
    );
  }
}

class PocScreen extends StatefulWidget {
  const PocScreen({
    super.key,
    this.server,
    this.loadAddresses,
    this.receiveShares,
    this.enableUsb,
    this.usbTransfer,
    this.conversionService,
    this.allowMultiple,
    this.enableWifiProfiles,
    this.monetization,
    this.readerPreferences,
  });
  final ReaderServer? server;
  final Future<List<InternetAddress>> Function()? loadAddresses;
  final bool? receiveShares;
  final bool? enableUsb;
  final UsbTransfer? usbTransfer;
  final ConversionService? conversionService;
  final bool? allowMultiple;
  final bool? enableWifiProfiles;
  final Monetization? monetization;
  final ReaderPreferences? readerPreferences;
  @override
  State<PocScreen> createState() => _PocScreenState();
}

class _PocScreenState extends State<PocScreen> with WidgetsBindingObserver {
  late final monetization = widget.monetization ?? androidMonetization();
  int parcelNumber = 0;

  void refreshMonetization() {
    if (mounted) setState(() {});
  }

  void parcelCompleted() {
    step = JourneyStep.done;
    final parcel = parcelNumber;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        monetization.completed(
          parcel,
          canShow: () =>
              mounted &&
              foreground &&
              step == JourneyStep.done &&
              parcelNumber == parcel &&
              ModalRoute.of(context)?.isCurrent == true,
        ),
      );
    });
  }

  late final wifiProfilesEnabled = widget.enableWifiProfiles ?? true;
  late final server =
      widget.server ??
      ReaderServer(
        allowedFormats: wifiProfilesEnabled
            ? const {'azw3', 'mobi', 'pdf', 'txt', 'epub'}
            : const {'azw3'},
      );
  ReaderProfile wifiProfile = ReaderProfile.kindle;
  late final readerPreferences =
      widget.readerPreferences ?? ReaderPreferences();
  late final Future<void> preferencesReady;
  ReaderBrand chosenBrand = ReaderBrand.other;
  String? displayedIdentityKey;
  bool readerConfirmed = false;

  ReaderIdentity? get currentIdentity => mode == TransferMode.wifi
      ? server.readerIdentity
      : selectedUsbReader == null
      ? null
      : ReaderIdentity(
          selectedUsbReader!.identityKey ??
              'usb:legacy:${selectedUsbReader!.profile.id}',
          selectedUsbReader!.detectedBrand ??
              ReaderIdentity.fromProfile(selectedUsbReader!.profile),
          isUnique: selectedUsbReader!.identityIsUnique,
        );

  Future<void> syncReaderIdentity() async {
    final identity = currentIdentity;
    if (identity?.key == displayedIdentityKey) return;
    await preferencesReady;
    if (!mounted || currentIdentity?.key != identity?.key) return;
    setState(() {
      displayedIdentityKey = identity?.key;
      final saved = identity == null
          ? null
          : readerPreferences.choice(identity.key);
      chosenBrand = saved ?? identity?.brand ?? ReaderBrand.other;
      readerConfirmed = saved != null && identity!.isUnique;
      wifiProfile = ReaderIdentity.profileFor(chosenBrand);
    });
  }

  Future<void> confirmReader() => perform(() async {
    final identity = currentIdentity;
    if (identity == null) return;
    final brand = chosenBrand;
    await readerPreferences.save(identity.key, brand);
    if (!mounted || currentIdentity?.key != identity.key) return;
    setState(() => readerConfirmed = true);
    await prepareBook();
  });

  Future<void> approveReader() async {
    await syncReaderIdentity();
    final identity = currentIdentity;
    final code = server.pairingCode;
    if (identity != null && !readerConfirmed) await confirmReader();
    if (!mounted ||
        (identity != null && !readerConfirmed) ||
        currentIdentity?.key != identity?.key ||
        server.pairingCode != code) {
      return;
    }
    server.approvePairing();
  }

  Future<void> chooseReaderBrand(ReaderBrand brand) async {
    if (selectionLocked || chosenBrand == brand) return;
    final identityKey = currentIdentity?.key;
    await perform(() async {
      await pageTask;
      if (server.url != null) await server.updateBooks([]);
      if (!mounted || currentIdentity?.key != identityKey) return;
      setState(() {
        chosenBrand = brand;
        wifiProfile = ReaderIdentity.profileFor(brand);
        readerConfirmed = false;
        publishedBooks = null;
        for (final item in books) {
          item.error = null;
        }
      });
      await prepareBook();
    });
  }

  late final converter = widget.conversionService ?? ConversionService();
  late final allowMultiple =
      widget.allowMultiple ?? (Platform.isAndroid || Platform.isWindows);
  static const importer = MethodChannel('ru.mkulkov.brizfi/import');
  List<InternetAddress> addresses = [];
  InternetAddress? selected;
  final books = <_SelectedBook>[];
  int preparingIndex = 0;
  File? get book => books.isEmpty ? null : books[minIndex].source;
  int get minIndex => preparingIndex < books.length ? preparingIndex : 0;
  File? get preparedBook =>
      books.isNotEmpty &&
          books.every(
            (b) =>
                b.ready != null &&
                ReaderProfile.formatOf(b.ready!.path) ==
                    readerProfile.targetFor(
                      ReaderProfile.formatOf(b.source.path),
                    ),
          )
      ? books.first.ready
      : null;
  String? get conversionError =>
      books.where((b) => b.error != null).firstOrNull?.error;
  bool converting = false;
  bool cancelling = false;
  Future<void>? conversionTask;
  bool busy = false;
  bool pickingBooks = false;
  bool failed = false;
  String? operationError;
  Timer? networkTimer;
  Future<void>? scanTask;
  int networkGeneration = 0;
  bool foreground = true;
  bool tearingDown = false;
  Completer<bool>? foregroundReady;
  bool startingTransfer = false;
  Future<void>? pageTask;
  String? publishedBooks;
  Uri? lastReaderUrl;
  String? interruption;
  late final receiveShares = widget.receiveShares ?? Platform.isAndroid;
  bool shareRequested = false;
  bool takingShare = false;
  String? shareError;
  late final usbEnabled =
      widget.enableUsb ?? (Platform.isAndroid || Platform.isWindows);
  late final usb = widget.usbTransfer ?? UsbTransfer();
  TransferMode mode = TransferMode.wifi;
  JourneyStep step = JourneyStep.connection;
  bool transferRequested = false;
  bool pageEnabled = true;
  bool get connected => mode == TransferMode.wifi
      ? server.paired && (currentIdentity == null || readerConfirmed)
      : selectedUsbReader != null && readerConfirmed;
  UsbReader? get selectedUsbReader =>
      usbReaders.where((reader) => reader.id == usbDeviceId).firstOrNull;
  ReaderProfile get readerProfile => mode == TransferMode.wifi
      ? wifiProfilesEnabled
            ? wifiProfile
            : ReaderProfile.kindleLegacy
      : selectedUsbReader == null
      ? ReaderProfile.unknown
      : ReaderProfile.fromNative(
          ReaderIdentity.profileFor(chosenBrand).id,
          selectedUsbReader!.profile.formats,
        );
  bool get selectionLocked =>
      busy ||
      converting ||
      usbSending ||
      transferRequested ||
      server.isTransferring;
  List<UsbReader> usbReaders = [];
  int? usbDeviceId;
  UsbReceipt? usbReceipt;
  int usbPosition = 0;
  bool usbSending = false;
  bool usbCancelling = false;
  Future<void>? usbTask;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    server.updateLanguage(Localizations.localeOf(context).languageCode);
  }

  @override
  void initState() {
    super.initState();
    preferencesReady = readerPreferences.load();
    monetization.addListener(refreshMonetization);
    unawaited(monetization.initialize());
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    server.addListener(refresh);
    if (usbEnabled) usb.addListener(refresh);
    if (receiveShares) {
      importer.setMethodCallHandler((call) async {
        if (!mounted) return;
        if (call.method == 'shareAvailable') {
          setState(() => shareRequested = true);
          unawaited(takeShare());
        } else if (call.method == 'shareRejected') {
          setState(() => shareError = 'busy');
        }
      });
      shareRequested =
          true; // Recover a cold-start notification sent before Dart.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(takeShare()),
      );
    }
    unawaited(scan());
    networkTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(scan()),
    );
  }

  void refresh() {
    if (mounted) {
      unawaited(syncReaderIdentity());
      if (server.url != null) lastReaderUrl = server.url;
      setState(() {
        if (mode == TransferMode.wifi &&
            step != JourneyStep.connection &&
            !server.paired) {
          // A stopped/expired session needs fresh human approval.
          if (step != JourneyStep.done) step = JourneyStep.connection;
          transferRequested = false;
        }
        if (step == JourneyStep.transfer &&
            books.isNotEmpty &&
            (mode == TransferMode.wifi
                ? server.transferred
                : books.every((b) => b.receipt != null))) {
          parcelCompleted();
        }
      });
      if (!server.isTransferring) unawaited(takeShare());
    }
  }

  Future<void> scan() {
    if (!foreground || !mounted) return Future<void>.value();
    return scanTask ??= scanNetwork().whenComplete(() => scanTask = null);
  }

  Future<void> scanNetwork() async {
    final generation = networkGeneration;
    try {
      final found = widget.loadAddresses != null
          ? await widget.loadAddresses!()
          : await localAddresses();
      if (!mounted || !foreground || generation != networkGeneration) return;
      final present = found.any((a) => a.address == selected?.address);
      if (!present && server.url != null) {
        interruption = 'network';
        await server.stop();
      }
      if (!mounted || !foreground || generation != networkGeneration) return;
      setState(() {
        addresses = found;
        if (!present) selected = found.isEmpty ? null : found.first;
      });
      await syncPage();
    } catch (_) {
      if (!mounted || !foreground || generation != networkGeneration) return;
      if (server.url != null) interruption = 'network';
      await server.stop();
      if (!mounted || !foreground || generation != networkGeneration) return;
      setState(() {
        addresses = [];
        selected = null;
      });
    }
  }

  static Future<List<InternetAddress>> localAddresses() =>
      LocalNetwork.addresses();

  Future<void> syncPage() {
    return pageTask ??= syncPageState().whenComplete(() => pageTask = null);
  }

  Future<void> syncPageState() async {
    if (!mounted ||
        !foreground ||
        mode != TransferMode.wifi ||
        !pageEnabled ||
        selected == null) {
      return;
    }
    final generation = networkGeneration;
    startingTransfer = true;
    try {
      if (server.url == null) {
        await server.startPage(
          address: selected!,
          languageCode: Localizations.localeOf(context).languageCode,
        );
        publishedBooks = null;
      }
      if (!mounted ||
          !foreground ||
          generation != networkGeneration ||
          mode != TransferMode.wifi) {
        await server.stop();
        return;
      }
      if (!busy && !converting && !server.isTransferring) {
        final ready = transferRequested && server.paired
            ? books.where((b) => b.ready != null).map((b) => b.ready!).toList()
            : <File>[];
        final signature = ready.map((f) => f.path).join('\u0000');
        if (publishedBooks != signature) {
          await server.updateBooks(ready);
          publishedBooks = signature;
        }
      }
      if (mounted) setState(() => interruption = null);
    } catch (_) {
      if (mounted) {
        setState(() {
          failed = true;
          operationError = 'transfer_failed';
        });
      }
    } finally {
      startingTransfer = false;
    }
  }

  Future<void> perform(
    Future<void> Function() action, {
    bool clearError = true,
  }) async {
    if (busy) return;
    setState(() {
      busy = true;
      if (clearError) {
        failed = false;
        operationError = null;
        shareError = null;
      }
    });
    if (clearError) server.dismissError();
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          failed = true;
          operationError = switch (error) {
            PlatformException() => error.code,
            TransferStorageFailure() => error.code,
            FileSystemException() => 'storage_unavailable',
            _ => 'operation_failed',
          };
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
      if (mounted) await syncPage();
      if (mounted) unawaited(takeShare());
    }
  }

  Future<void> pick() => perform(() async {
    pickingBooks = true;
    List<String>? paths;
    try {
      if (allowMultiple) {
        paths = await importer.invokeListMethod<String>('pickBooks');
      } else {
        final path = await importer.invokeMethod<String>(
          Platform.isAndroid ? 'pickBook' : 'pickAzw3',
        );
        if (path != null) paths = [path];
      }
    } finally {
      pickingBooks = false;
    }
    if (paths != null) await acceptBooks(paths, append: true);
  });

  Future<void> takeShare() async {
    if (!receiveShares ||
        !shareRequested ||
        takingShare ||
        !mounted ||
        !foreground ||
        busy ||
        converting ||
        server.isTransferring ||
        transferRequested ||
        usbSending) {
      return;
    }
    takingShare = true;
    setState(() => shareRequested = false);
    try {
      await perform(() async {
        final path = await importer.invokeMethod<String>('takeSharedBook');
        if (path != null) {
          if (mounted) {
            setState(() {
              failed = false;
              operationError = null;
              shareError = null;
            });
            server.dismissError();
          }
          await acceptBook(path);
        }
      }, clearError: false);
    } finally {
      takingShare = false;
      // Another notification may have arrived while the copy/conversion ran.
      if (mounted && shareRequested) unawaited(takeShare());
    }
  }

  Future<void> acceptBook(String path) => acceptBooks([path]);

  Future<void> acceptBooks(List<String> paths, {bool append = false}) async {
    final oldPaths = books.map((b) => b.source.path).toSet();
    final unique = {if (append) ...oldPaths, ...paths}.toList();
    if (unique.isEmpty) return;
    if (unique.length > ReaderServer.maxBooks) {
      for (final path in paths.toSet().difference(oldPaths)) {
        await releaseImport(File(path));
      }
      throw PlatformException(code: 'batch_limit');
    }
    if (!mounted) {
      for (final path in unique) {
        await releaseImport(File(path));
      }
      return;
    }
    final previous = List<_SelectedBook>.of(books);
    setState(() {
      books
        ..clear()
        ..addAll(
          unique.map(
            (p) => append
                ? previous.where((b) => b.source.path == p).firstOrNull ??
                      _SelectedBook(File(p))
                : _SelectedBook(File(p)),
          ),
        );
      if (connected) step = JourneyStep.books;
      preparingIndex = 0;
      usbReceipt = null;
    });
    for (final item in previous.where((b) => !unique.contains(b.source.path))) {
      await releaseImport(item.source);
    }
    await prepareBook();
  }

  Future<void> prepareBook() async {
    if (books.isEmpty) return;
    // Android may deliver the picker result before Flutter's resumed event.
    // Retain the imported selection and wait rather than treating it as cancelled.
    if (!foreground) {
      final resumed = await (foregroundReady ??= Completer<bool>()).future;
      if (!resumed || !mounted) return;
    }
    if (!mounted) return;
    setState(() {
      converting = true;
      cancelling = false;
    });
    final selection = List<_SelectedBook>.of(books);
    final task = () async {
      try {
        for (var i = 0; i < selection.length; i++) {
          final item = selection[i];
          final sourceFormat = ReaderProfile.formatOf(item.source.path);
          final target = readerProfile.targetFor(sourceFormat);
          if (item.ready != null &&
              ReaderProfile.formatOf(item.ready!.path) == target) {
            continue;
          }
          item.ready = null;
          if (!mounted || !foreground || cancelling) {
            item.error = 'cancelled';
            continue;
          }
          setState(() {
            preparingIndex = i;
            item.error = null;
          });
          if (target == null) {
            setState(() => item.error = 'reader_format_unsupported');
            continue;
          }
          if (target == sourceFormat) {
            setState(() => item.ready = item.source);
            continue;
          }
          if (item.outputs[target] case final cached?) {
            setState(() => item.ready = cached);
            continue;
          }
          setState(() => item.preparing = true);
          try {
            final output = target == 'azw3'
                ? await converter.convert(item.source)
                : await converter.convert(item.source, targetFormat: target);
            if (mounted) {
              setState(() {
                item.outputs[target] = output;
                item.ready = output;
              });
            } else {
              await releaseImport(output);
            }
          } on ConversionFailure catch (error) {
            item.error = error.code;
            if (error.code == 'cancelled') cancelling = true;
            if (mounted) setState(() {});
          } finally {
            item.preparing = false;
            if (mounted) setState(() {});
          }
        }
      } finally {
        if (mounted) setState(() => converting = false);
      }
    }();
    conversionTask = task;
    await task;
  }

  void cancelConversion() {
    converter.cancel();
    setState(() => cancelling = true);
  }

  Widget preparationIndicator(_SelectedBook item, AppLocalizations l) {
    final active = item.preparing;
    final cancelled = item.error == 'cancelled';
    final label = active
        ? cancelling
              ? l.bookCancelling
              : l.bookConverting
        : cancelled
        ? l.bookCancelled
        : item.error != null
        ? l.batchBookFailed
        : item.ready != null
        ? l.batchBookReady
        : l.batchBookWaiting;
    final icon = active
        ? Icons.hourglass_top
        : cancelled
        ? Icons.cancel_outlined
        : item.error != null
        ? Icons.error_outline
        : item.ready != null
        ? Icons.check_circle
        : Icons.schedule;
    return Semantics(
      key: ValueKey('preparation:${item.source.path}'),
      liveRegion: true,
      label: '${item.source.uri.pathSegments.last}: $label',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: active && !MediaQuery.disableAnimationsOf(context)
                    ? const CircularProgressIndicator.adaptive(strokeWidth: 2)
                    : Icon(
                        icon,
                        size: 24,
                        color: item.error != null && !cancelled
                            ? Theme.of(context).colorScheme.error
                            : item.ready != null || active
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedSwitcher(
                  duration: brizfiMotionDuration(context),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.topLeft,
                    children: [
                      for (final child in previous)
                        IgnorePointer(child: ExcludeSemantics(child: child)),
                      ?current,
                    ],
                  ),
                  child: Text(
                    label,
                    key: ValueKey(label),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> releaseImport(File file) async {
    if (!ManagedImports.hasManagedLayout(file)) return;
    if (Platform.isAndroid || Platform.isWindows) {
      await ManagedImports.release(file);
      return;
    }
    final directory = file.parent;
    // Only native importer-owned UUID directories; never a user source.
    if (directory.parent.uri.pathSegments.where((s) => s.isNotEmpty).last !=
        'brizfi_imports') {
      return;
    }
    if (!RegExp(r'^[0-9a-fA-F-]{36}$')
        .hasMatch(directory.uri.pathSegments.where((s) => s.isNotEmpty).last)) {
      return;
    }
    try {
      if (await file.exists()) await file.delete();
      await directory.delete();
    } catch (_) {
      // Startup TTL cleanup retries failed deletion.
    }
  }

  Future<void> removeBook(_SelectedBook item) => perform(() async {
    await releaseImport(item.source);
    if (mounted) {
      setState(() {
        books.remove(item);
        preparingIndex = 0;
        usbReceipt = null;
      });
    }
  });

  Future<void> removeSentBooks() => perform(() async {
    final sent = books.where((b) => b.receipt != null).toList();
    for (final item in sent) {
      await releaseImport(item.source);
    }
    if (mounted) {
      setState(() {
        books.removeWhere((b) => sent.contains(b));
        preparingIndex = 0;
        usbReceipt = null;
        step = JourneyStep.books;
      });
    }
  });

  Future<void> clearBook() => perform(() async {
    for (final item in List<_SelectedBook>.of(books)) {
      await releaseImport(item.source);
    }
    if (mounted) {
      setState(() {
        books.clear();
        preparingIndex = 0;
        usbReceipt = null;
      });
    }
  });

  Future<void> findUsbReaders() => perform(() async {
    if (converting || usbSending || transferRequested) return;
    final found = await usb.listReaders();
    if (!mounted) return;
    final previousDeviceId = usbDeviceId;
    setState(() {
      usbReaders = found;
      if (!found.any((d) => d.id == usbDeviceId)) {
        usbDeviceId = found.length == 1 ? found.single.id : null;
      }
      if (usbDeviceId != previousDeviceId) {
        usbReceipt = null;
        if (step != JourneyStep.connection) step = JourneyStep.books;
        for (final item in books) {
          item.receipt = null;
          item.error = null;
        }
      }
    });
    await syncReaderIdentity();
    await prepareBook();
  });

  Future<void> selectUsbReader(int id) async {
    if (selectionLocked || usbDeviceId == id) return;
    await perform(() async {
      setState(() {
        usbDeviceId = id;
        usbReceipt = null;
        if (step != JourneyStep.connection) step = JourneyStep.books;
        for (final item in books) {
          item.receipt = null;
          item.error = null;
        }
      });
      await syncReaderIdentity();
      await prepareBook();
    });
  }

  Future<void> selectWifiProfile(ReaderProfile profile) async {
    if (!wifiProfilesEnabled ||
        selectionLocked ||
        wifiProfile.id == profile.id) {
      return;
    }
    await perform(() async {
      // Withdraw old prepared files before changing the intended receiver.
      await pageTask;
      if (server.url != null) await server.updateBooks([]);
      if (!mounted) return;
      setState(() {
        wifiProfile = profile;
        chosenBrand = ReaderIdentity.fromProfile(profile);
        readerConfirmed = false;
        publishedBooks = null;
        for (final item in books) {
          item.error = null;
        }
      });
      await prepareBook();
    });
  }

  Future<void> sendUsbBook() async {
    if (preparedBook == null || usbDeviceId == null || !foreground) return;
    setState(() {
      usbSending = true;
      usbCancelling = false;
      usbReceipt = null;
      for (final item in books) {
        item.receipt = null;
      }
    });
    final selection = List<_SelectedBook>.of(books);
    final device = usbDeviceId!;
    final task = () async {
      try {
        for (var i = 0; i < selection.length; i++) {
          if (usbCancelling || !foreground) {
            throw PlatformException(code: 'usb_cancelled');
          }
          if (mounted) setState(() => usbPosition = i + 1);
          final receipt = await usb.send(selection[i].ready!, device);
          if (mounted) {
            setState(() {
              selection[i].receipt = receipt;
            });
          }
        }
        if (mounted) setState(() => usbReceipt = selection.last.receipt);
      } finally {
        if (mounted) setState(() => usbSending = false);
      }
    }();
    usbTask = task;
    await task;
  }

  Future<void> cancelUsb() async {
    if (!usbSending) return;
    if (mounted && !tearingDown) setState(() => usbCancelling = true);
    try {
      await usb.cancel();
    } on PlatformException {
      // Cancellation is best effort; the send result controls source lifetime.
    } on MissingPluginException {
      // Engine teardown cannot prove that native reading already stopped.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      foreground = false;
      networkGeneration++;
      // SAF is part of selection: preserve pairing on the empty reader page.
      // Published transfers and actual app exits still stop below.
      if (pickingBooks &&
          !transferRequested &&
          !server.isTransferring &&
          state != AppLifecycleState.detached) {
        return;
      }
      if (server.url != null || startingTransfer) interruption = 'background';
      unawaited(server.stop());
      converter.cancel();
      // The system folder picker temporarily pauses the app during USB setup.
      if (usbEnabled && usb.phase != 'selectingFolder') {
        unawaited(cancelUsb());
      }
      if (mounted && converting) setState(() => cancelling = true);
    }
    if (state == AppLifecycleState.resumed) {
      foreground = true;
      final waiting = foregroundReady;
      foregroundReady = null;
      waiting?.complete(true);
      if (receiveShares) {
        shareRequested = true;
        unawaited(takeShare());
      }
      // Wait for an invalidated scan before taking a fresh foreground snapshot.
      unawaited(() async {
        await scanTask;
        await scan();
      }());
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    tearingDown = true;
    monetization.removeListener(refreshMonetization);
    if (widget.monetization == null) monetization.dispose();
    networkTimer?.cancel();
    foreground = false;
    foregroundReady?.complete(false);
    foregroundReady = null;
    networkGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    if (receiveShares) importer.setMethodCallHandler(null);
    server.removeListener(refresh);
    converter.cancel();
    if (usbEnabled) {
      usb.removeListener(refresh);
      unawaited(cancelUsb());
    }
    unawaited(
      server.stop().then((_) async {
        await conversionTask;
        try {
          await usbTask;
        } catch (_) {
          // Retain the source until the native read/write job has actually ended.
        }
        try {
          for (final item in books) {
            await releaseImport(item.source);
          }
        } on PlatformException {
          // Engine teardown: startup TTL cleanup retries owned copies.
        } on MissingPluginException {
          // Never remove files while an unavailable native owner may be active.
        }
        server.dispose();
        if (usbEnabled) usb.dispose();
      }),
    );
    super.dispose();
  }

  String operationProblem(AppLocalizations l) =>
      switch (operationError ?? server.errorCode) {
        'reader_preferences_unavailable' => l.readerSaveFailed,
        'batch_limit' || 'too_many_books' => l.batchLimit,
        'invalid_selection' => l.invalidSelection,
        'cache_full' => l.cacheFull,
        'storage_unavailable' => l.storageUnavailable,
        'too_large' => l.importTooLarge,
        'unsupported_format' => l.importUnsupported,
        'multiple_books' => l.shareMultiple,
        'invalid_share' => l.shareInvalid,
        'invalid_book' || 'invalid_file' => l.invalidBook,
        'usb_not_found' => l.usbNotFound,
        'usb_permission' => l.usbPermission,
        'usb_unsupported' => l.usbUnsupported,
        'usb_open_failed' => l.usbOpenFailed,
        'usb_busy' => l.usbReaderBusy,
        'usb_documents_missing' =>
          readerProfile.id == 'nook'
              ? l.usbNookFolderMissing
              : l.usbDocumentsMissing,
        'usb_full' => l.usbFull,
        'usb_verification_failed' => l.usbVerificationFailed,
        'usb_cancelled' => l.usbCancelled,
        'usb_uncertain' => l.usbUncertain,
        'usb_invalid_file' => l.invalidBook,
        'usb_transfer_failed' => l.usbTransferFailed,
        'busy' when mode == TransferMode.usb => l.usbBusy,
        _ => mode == TransferMode.usb ? l.usbTransferFailed : l.error,
      };

  void changeMode(TransferMode next) {
    if (selectionLocked || mode == next) return;
    setState(() {
      mode = next;
      displayedIdentityKey = null;
      readerConfirmed = false;
      usbReceipt = null;
      for (final item in books) {
        item.receipt = null;
      }
      pageEnabled = true;
      transferRequested = false;
      failed = false;
      operationError = null;
    });
    if (next == TransferMode.usb) {
      unawaited(server.stop());
      unawaited(findUsbReaders());
    } else {
      unawaited(scan());
      unawaited(prepareBook());
    }
  }

  void chooseStep() {
    if (!connected || busy) return;
    setState(() => step = JourneyStep.books);
  }

  Future<void> sendParcel() => perform(() async {
    if (!connected || preparedBook == null || !foreground) return;
    parcelNumber++;
    monetization.prepareParcel();
    setState(() {
      step = JourneyStep.transfer;
      transferRequested = mode == TransferMode.wifi;
    });
    if (mode == TransferMode.usb) {
      await sendUsbBook();
      if (mounted && books.every((b) => b.receipt != null)) {
        setState(parcelCompleted);
      }
    }
  });

  Future<void> nextParcel() => perform(() async {
    // Withdraw the published set before releasing any import copy. Session
    // and cookie remain valid for another parcel within their original TTL.
    setState(() => transferRequested = false);
    await pageTask;
    if (mode == TransferMode.wifi && server.url != null) {
      await server.updateBooks([]);
      publishedBooks = '';
    }
    for (final item in List<_SelectedBook>.of(books)) {
      await releaseImport(item.source);
    }
    if (mounted) {
      setState(() {
        books.clear();
        usbReceipt = null;
        preparingIndex = 0;
        step = connected ? JourneyStep.books : JourneyStep.connection;
      });
    }
  });

  Future<void> endConnection() => perform(() async {
    setState(() {
      pageEnabled = false;
      transferRequested = false;
      step = JourneyStep.connection;
      usbDeviceId = null;
      usbReaders = [];
    });
    networkGeneration++;
    await pageTask;
    await server.stop();
    publishedBooks = null;
  });

  Future<void> stopParcel() async {
    if (mode == TransferMode.usb) {
      await cancelUsb();
    } else {
      await perform(() async {
        transferRequested = false;
        await server.stop();
        if (mounted) setState(() => step = JourneyStep.connection);
      });
    }
  }

  Widget button(String label, VoidCallback? action, {bool secondary = false}) {
    if (Platform.isIOS) {
      return secondary
          ? CupertinoButton(onPressed: action, child: Text(label))
          : CupertinoButton.filled(onPressed: action, child: Text(label));
    }
    return secondary
        ? TextButton(onPressed: action, child: Text(label))
        : ParcelButton(label: label, onPressed: action);
  }

  Widget connectionPanel(AppLocalizations l) {
    final c = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (usbEnabled)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ConnectionTicket(
                  label: l.wifiMode,
                  icon: Icons.wifi,
                  selected: mode == TransferMode.wifi,
                  onPressed: selectionLocked
                      ? null
                      : () => changeMode(TransferMode.wifi),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ConnectionTicket(
                  label: l.usbMode,
                  icon: Icons.usb,
                  selected: mode == TransferMode.usb,
                  onPressed: selectionLocked
                      ? null
                      : () => changeMode(TransferMode.usb),
                ),
              ),
            ],
          ),
        const SizedBox(height: 12),
        if (mode == TransferMode.wifi) ...[
          if (currentIdentity != null) readerIdentityEditor(l),
          if (server.url != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.wifiAddressTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  server.url.toString(),
                  key: const ValueKey('reader-url'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            )
          else
            Text(selected == null ? l.noNetwork : l.stopped),
          if (!server.paired && server.pairingCode != null) ...[
            const SizedBox(height: 8),
            Material(
              color: c.surfaceContainerHighest,
              shape: const PaperShape(PaperKind.tag),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Column(
                  children: [
                    Text(l.journeyCompare, textAlign: TextAlign.center),
                    const SizedBox(height: 6),
                    Semantics(
                      liveRegion: true,
                      label: l.pairingCodeSpoken(
                        server.pairingCode!.split('').join(' '),
                      ),
                      child: ExcludeSemantics(
                        child: Text(
                          server.pairingCode!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            color: c.onSurface,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (server.pendingPairing)
            CheckboxListTile.adaptive(
              key: const ValueKey('approve-pairing'),
              value: false,
              onChanged: busy
                  ? null
                  : (checked) {
                      if (checked == true) unawaited(approveReader());
                    },
              title: Text(l.journeyApprove),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
          if (server.paired)
            button(
              l.revokeReader,
              busy ? null : server.revokePairing,
              secondary: true,
            ),
          if (!pageEnabled)
            button(
              l.journeyReconnect,
              busy
                  ? null
                  : () {
                      setState(() => pageEnabled = true);
                      unawaited(scan());
                    },
              secondary: true,
            ),
        ] else ...[
          Text(l.usbReaderTitle, style: Theme.of(context).textTheme.bodySmall),
          if (usbReaders.isEmpty) Text(l.usbNoReader),
          for (final reader in usbReaders)
            button(
              '${usbDeviceId == reader.id ? '✓ ' : ''}${reader.name}',
              selectionLocked ? null : () => selectUsbReader(reader.id),
              secondary: true,
            ),
          button(
            l.usbFind,
            selectionLocked ? null : findUsbReaders,
            secondary: true,
          ),
          if (selectedUsbReader != null) readerIdentityEditor(l),
          if (selectedUsbReader != null)
            Text(
              l.readerFormats(
                (readerProfile.formats.toList()..sort())
                    .map((format) => format.toUpperCase())
                    .join(', '),
              ),
            ),
        ],
        if (connected)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Icon(Icons.check_circle_outline, color: c.secondary),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(l.journeyConnected)),
              ],
            ),
          ),
        if (!connected) button(l.journeyHelp, openAbout, secondary: true),
      ],
    );
  }

  String brandLabel(ReaderBrand brand, AppLocalizations l) => switch (brand) {
    ReaderBrand.kindle => 'Kindle',
    ReaderBrand.nook => 'NOOK',
    ReaderBrand.kobo => 'Kobo',
    ReaderBrand.pocketbook => 'PocketBook',
    ReaderBrand.onyx => 'ONYX BOOX',
    ReaderBrand.other => l.readerOther,
  };

  Widget readerIdentityEditor(AppLocalizations l) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (readerConfirmed) Text(l.readerSaved),
      Wrap(
        spacing: 8,
        children: [
          for (final brand in ReaderBrand.values)
            ChoiceChip(
              key: ValueKey('reader-brand-${brand.name}'),
              label: Text(brandLabel(brand, l)),
              selected: chosenBrand == brand,
              onSelected: selectionLocked
                  ? null
                  : (_) => chooseReaderBrand(brand),
            ),
        ],
      ),
      // Only a native result backed by exact-model evidence can name a model.
      Text(
        l.readerModel(
          mode == TransferMode.usb &&
                  selectedUsbReader?.modelVerified == true &&
                  chosenBrand == currentIdentity?.brand &&
                  selectedUsbReader!.model?.isNotEmpty == true
              ? selectedUsbReader!.model!
              : l.readerOther,
        ),
      ),
      if (!readerConfirmed)
        button(l.readerConfirm, busy ? null : confirmReader, secondary: true),
      if (mode == TransferMode.usb &&
          selectedUsbReader?.transport == 'unsupported')
        Text(l.usbNoFileProtocol, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Widget connectionBadge(AppLocalizations l) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      Icon(
        connected ? Icons.link : Icons.link_off,
        color: Theme.of(context).colorScheme.secondary,
      ),
      Text(
        '${mode == TransferMode.wifi ? l.wifiMode : selectedUsbReader?.name ?? l.usbMode}'
        '${currentIdentity != null ? ' · ${brandLabel(chosenBrand, l)}' : ''}'
        '${connected ? ' · ${l.journeyConnected}' : ''}',
      ),
      if (step == JourneyStep.books)
        button(
          l.journeyChange,
          selectionLocked
              ? null
              : () => setState(() => step = JourneyStep.connection),
          secondary: true,
        ),
    ],
  );

  String bookName(_SelectedBook item) => item.source.uri.pathSegments.last;

  Widget bookList(AppLocalizations l, {bool receipt = false}) {
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in books) ...[
          Padding(
            key: ValueKey('book:${item.source.path}'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    receipt
                        ? Icons.check_circle_outline
                        : Icons.description_outlined,
                    size: 30,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bookName(item),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        item.ready == null
                            ? ReaderProfile.formatOf(item.source.path)
                                  .toUpperCase()
                            : item.ready!.path == item.source.path
                            ? l.readerOriginal(
                                ReaderProfile.formatOf(item.source.path)
                                    .toUpperCase(),
                              )
                            : l.readerConverted(
                                ReaderProfile.formatOf(item.source.path)
                                    .toUpperCase(),
                                ReaderProfile.formatOf(item.ready!.path)
                                    .toUpperCase(),
                              ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (!receipt) preparationIndicator(item, l),
                      if (!receipt && item.receipt != null)
                        Text(l.batchUsbVerified),
                    ],
                  ),
                ),
                if (!receipt)
                  IconButton(
                    tooltip: l.removeOneBook,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: selectionLocked ? null : () => removeBook(item),
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          const PaperDivider(),
        ],
      ],
    );
    return receipt ? PaperReceipt(child: list) : BrizfiMotionSize(child: list);
  }

  Widget conversionProblem(AppLocalizations l) => Semantics(
    liveRegion: true,
    child: Text(switch (conversionError) {
      'reader_format_unsupported' ||
      'unsupported_format' => l.readerFormatUnsupported,
      'cancelled' => l.cancelled,
      'encrypted_book' => l.protectedBook,
      'input_too_large' ||
      'resource_limit' ||
      'output_too_large' => l.conversionLimit,
      'unsupported_encoding' => l.unsupportedEncoding,
      'unsupported_content' => l.unsupportedBook,
      'cache_full' => l.cacheFull,
      'storage_unavailable' => l.storageUnavailable,
      _ => l.conversionError,
    }),
  );

  Widget selectionPanel(AppLocalizations l) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      connectionBadge(l),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const ValueKey('pick-books'),
        style: OutlinedButton.styleFrom(
          shape: const PaperShape(PaperKind.ticket),
        ),
        onPressed: selectionLocked ? null : pick,
        icon: const Icon(Icons.add),
        label: Text(l.journeyAdd),
      ),
      const SizedBox(height: 16),
      if (books.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l.journeyEmpty, textAlign: TextAlign.center),
        ),
      bookList(l),
      if (books.isNotEmpty)
        Text(
          l.batchPrepared(
            books.where((b) => b.ready != null).length,
            books.length,
          ),
        ),
      if (converting)
        button(l.cancel, cancelling ? null : cancelConversion, secondary: true),
      if (!converting && conversionError != null) ...[
        conversionProblem(l),
        button(
          l.retryConversion,
          busy ? null : () => perform(prepareBook),
          secondary: true,
        ),
      ],
      if (books.isNotEmpty)
        button(
          allowMultiple ? l.clearBooks : l.clearBook,
          selectionLocked ? null : clearBook,
          secondary: true,
        ),
    ],
  );

  Widget deliveryRow(
    _SelectedBook item,
    BookDeliveryStatus? delivery,
    AppLocalizations l,
  ) {
    final active = delivery?.active ?? false;
    final complete = delivery?.completed ?? false;
    final progress = delivery != null && delivery.length > 0
        ? (delivery.sent / delivery.length).clamp(0.0, 1.0)
        : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  complete
                      ? Icons.check_circle_outline
                      : active
                      ? Icons.local_shipping_outlined
                      : Icons.schedule,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  bookName(item),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          if (active) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress, minHeight: 8),
            const SizedBox(height: 8),
            Text('${(progress * 100).floor()}%', textAlign: TextAlign.end),
          ] else
            Text(
              complete ? l.transferred : l.journeyWaiting,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const PaperDivider(),
        ],
      ),
    );
  }

  Widget transferPanel(AppLocalizations l) {
    final wifi = mode == TransferMode.wifi;
    final deliveries = server.deliveryStatus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        connectionBadge(l),
        const SizedBox(height: 16),
        PaperReceipt(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                liveRegion: true,
                child: Text(
                  wifi
                      ? l.batchHttpResult(server.completedBooks, books.length)
                      : usbSending
                      ? l.batchUsbProgress(usbPosition, books.length)
                      : l.batchUsbResult(
                          books.where((b) => b.receipt != null).length,
                          books.length,
                        ),
                ),
              ),
              const SizedBox(height: 12),
              if (wifi) ...[
                if (!server.isTransferring) Text(l.journeyWaiting),
                for (var i = 0; i < books.length; i++)
                  deliveryRow(
                    books[i],
                    i < deliveries.length ? deliveries[i] : null,
                    l,
                  ),
              ] else ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    usbCancelling
                        ? l.usbCancelling
                        : switch (usb.phase) {
                            'writing' => l.usbWriting,
                            'verifying' => l.usbVerifying,
                            'selectingFolder' =>
                              readerProfile.id == 'nook'
                                  ? l.usbNookChooseFolder
                                  : l.usbChooseFolder,
                            _ => usbSending ? l.usbConnecting : l.usbCancelled,
                          },
                  ),
                ),
                for (final item in books)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      item.receipt != null
                          ? Icons.check_circle_outline
                          : Icons.schedule,
                    ),
                    title: Text(bookName(item)),
                    subtitle: Text(
                      item.receipt != null
                          ? l.batchUsbVerified
                          : l.batchBookWaiting,
                    ),
                  ),
              ],
            ],
          ),
        ),
        if (!wifi && !usbSending) ...[
          if (books.any((b) => b.receipt != null))
            button(
              l.removeSentBooks,
              busy ? null : removeSentBooks,
              secondary: true,
            ),
        ],
      ],
    );
  }

  Widget resultPanel(AppLocalizations l) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        liveRegion: true,
        child: Text(
          mode == TransferMode.wifi
              ? l.batchHttpResult(server.completedBooks, books.length)
              : l.batchUsbResult(
                  books.where((b) => b.receipt != null).length,
                  books.length,
                ),
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 16),
      bookList(l, receipt: true),
      const SizedBox(height: 16),
      Text(l.journeyCheckLibrary, textAlign: TextAlign.center),
      if (mode == TransferMode.usb)
        Text(l.transferVerified, textAlign: TextAlign.center),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final content = SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final connection = step == JourneyStep.connection;
          final actionHint = connection && !connected
              ? l.journeyChooseReason
              : step == JourneyStep.transfer
              ? l.journeyKeepOpen
              : null;
          // Leave room for accessible scrolling when text or the footer is tall.
          final scrollActionHint =
              MediaQuery.textScalerOf(context).scale(14) > 28 ||
              constraints.maxHeight < 400;
          final scroll = SingleChildScrollView(
            key: ValueKey(step),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      switch (step) {
                        JourneyStep.connection => l.journeyConnectionStep,
                        JourneyStep.books => l.journeyBooksStep,
                        _ => l.journeyTransferStep,
                      },
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 12),
                    Semantics(
                      header: true,
                      child: Text(
                        switch (step) {
                          JourneyStep.connection => l.journeyConnect,
                          JourneyStep.books => l.journeyChoose,
                          JourneyStep.transfer => l.journeySending,
                          JourneyStep.done => l.journeyDone,
                        },
                        key: const ValueKey('journey-title'),
                        textAlign: TextAlign.center,
                        style:
                            (connection
                                    ? Theme.of(context).textTheme.titleLarge
                                    : Theme.of(context).textTheme.headlineSmall)
                                ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    SizedBox(height: connection ? 8 : 20),
                    if (shareRequested)
                      Semantics(liveRegion: true, child: Text(l.shareDeferred)),
                    if (shareError != null)
                      Semantics(liveRegion: true, child: Text(l.shareBusy)),
                    if (interruption != null && mode == TransferMode.wifi)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          interruption == 'background'
                              ? l.backgroundInterrupted
                              : l.networkInterrupted,
                        ),
                      ),
                    if (failed || server.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(operationProblem(l)),
                        ),
                      ),
                    switch (step) {
                      JourneyStep.connection => connectionPanel(l),
                      JourneyStep.books => selectionPanel(l),
                      JourneyStep.transfer => transferPanel(l),
                      JourneyStep.done => resultPanel(l),
                    },
                    if (scrollActionHint && actionHint != null) ...[
                      const SizedBox(height: 16),
                      Text(actionHint, textAlign: TextAlign.center),
                    ],
                    if (busy && !converting)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator.adaptive(),
                      ),
                  ],
                ),
              ),
            ),
          );
          final theme = Theme.of(context);
          return Theme(
            data: connection
                ? theme.copyWith(
                    textButtonTheme: TextButtonThemeData(
                      style: theme.textButtonTheme.style?.copyWith(
                        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                    ),
                  )
                : theme,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: SizedBox(
                        height: (constraints.maxHeight * .25).clamp(0.0, 140.0),
                        child: JourneyIllustration(step.index),
                      ),
                    ),
                  ),
                ),
                Expanded(child: scroll),
                Padding(
                  key: ValueKey(
                    step == JourneyStep.books
                        ? 'send-footer'
                        : 'journey-footer',
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!scrollActionHint && actionHint != null) ...[
                            Text(actionHint, textAlign: TextAlign.center),
                            const SizedBox(height: 8),
                          ],
                          KeyedSubtree(
                            key: const ValueKey('journey-action'),
                            child: switch (step) {
                              JourneyStep.connection => button(
                                l.journeyContinue,
                                connected && !busy ? chooseStep : null,
                              ),
                              JourneyStep.books => button(
                                l.journeySend,
                                selectionLocked ||
                                        preparedBook == null ||
                                        !connected ||
                                        !foreground
                                    ? null
                                    : sendParcel,
                              ),
                              JourneyStep.transfer =>
                                mode == TransferMode.usb && !usbSending
                                    ? button(
                                        l.journeyBack,
                                        busy
                                            ? null
                                            : () => setState(
                                                () => step = JourneyStep.books,
                                              ),
                                      )
                                    : button(
                                        l.journeyStop,
                                        usbCancelling ? null : stopParcel,
                                      ),
                              JourneyStep.done => button(
                                l.journeyAgain,
                                busy || server.isTransferring
                                    ? null
                                    : nextParcel,
                              ),
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (Platform.isIOS) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: const Text('BRIZFI'),
          leading: step == JourneyStep.books
              ? CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: selectionLocked
                      ? null
                      : () => setState(() => step = JourneyStep.connection),
                  child: Text(l.journeyBack),
                )
              : null,
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: openAbout,
            child: Semantics(
              label: l.aboutTitle,
              button: true,
              child: const Icon(CupertinoIcons.question_circle),
            ),
          ),
        ),
        child: Theme(
          data: brizfiTheme(MediaQuery.platformBrightnessOf(context)),
          child: Material(type: MaterialType.transparency, child: content),
        ),
      );
    }
    return PopScope(
      canPop: step == JourneyStep.connection,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && step == JourneyStep.books && !selectionLocked) {
          setState(() => step = JourneyStep.connection);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const BrizfiBrand(),
          leading: step == JourneyStep.books
              ? IconButton(
                  tooltip: l.journeyBack,
                  onPressed: selectionLocked
                      ? null
                      : () => setState(() => step = JourneyStep.connection),
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          actions: [
            IconButton(
              tooltip: l.aboutTitle,
              onPressed: openAbout,
              icon: const Icon(Icons.help_outline),
            ),
          ],
        ),
        body: content,
        bottomNavigationBar: monetization.hasAds
            ? LayoutBuilder(
                builder: (context, constraints) =>
                    monetization.ads!.banner(constraints.maxWidth.floor()),
              )
            : null,
      ),
    );
  }

  void openAbout() {
    final page = AboutScreen(
      enableUsb: usbEnabled,
      allowMultiple: allowMultiple,
      monetization: monetization,
    );
    Navigator.of(context).push(
      Platform.isIOS
          ? CupertinoPageRoute<void>(builder: (_) => page)
          : MaterialPageRoute<void>(builder: (_) => page),
    );
  }
}
