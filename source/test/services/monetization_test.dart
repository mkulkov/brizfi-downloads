import 'dart:async';

import 'package:brizfi/services/monetization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAds extends AdsGateway {
  bool online = true;
  bool failInit = false;
  bool failShow = false;
  bool failStop = false;
  int starts = 0;
  int shows = 0;
  int stops = 0;
  Completer<void>? showing;
  @override
  bool get available => online;
  @override
  Widget banner(int width) => online
      ? SizedBox(
          key: const ValueKey('test-banner'),
          height: 50,
          width: width.toDouble(),
          child: const Text('Test ad'),
        )
      : const SizedBox.shrink();
  @override
  Future<void> initialize() async {
    starts++;
    if (failInit) throw StateError('SDK unavailable');
  }

  @override
  Future<void> preload() async {}
  @override
  Future<void> showReady() async {
    shows++;
    if (failShow) throw StateError('Display failed');
    await showing?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('SDK teardown failed');
    online = false;
    notifyListeners();
  }

  void unavailable() {
    online = false;
    notifyListeners();
  }
}

class FakePurchases implements PurchaseGateway {
  bool cached = false;
  bool owned = false;
  bool fail = false;
  bool accepted = true;
  int buys = 0;
  String? amount = '99 ₽';
  Completer<bool>? pending;
  @override
  Future<bool> readRemoved() async => cached;
  @override
  Future<void> saveRemoved() async {
    cached = true;
  }

  @override
  Future<bool> restore() async {
    if (fail) throw StateError('Store unavailable');
    return owned;
  }

  @override
  Future<String?> price() async {
    if (fail) throw StateError('Store unavailable');
    return amount;
  }

  @override
  Future<bool> purchase() async {
    buys++;
    if (fail) throw StateError('Store unavailable');
    return pending?.future ?? accepted;
  }
}

void main() {
  test(
    'initialization is idempotent and teardown cannot reverse paid entitlement',
    () async {
      final sdk = FakeAds()..failStop = true;
      final ads = Monetization(ads: sdk, purchases: FakePurchases());
      await Future.wait([ads.initialize(), ads.initialize()]);
      expect(sdk.starts, 1);
      expect(await ads.removeAds(), isTrue);
      expect(ads.removed, isTrue);
      expect(ads.hasAds, isFalse);
      ads.dispose();
    },
  );
  test('absent SDK and store are optional', () async {
    final ads = Monetization();
    await ads.initialize();
    await ads.completed(1, canShow: () => true);
    expect(ads.canRemove, isFalse);
    expect(ads.hasAds, isFalse);
    ads.dispose();
  });
  test('SDK initialization failure hides monetization', () async {
    final sdk = FakeAds()..failInit = true;
    final ads = Monetization(ads: sdk, purchases: FakePurchases());
    await ads.initialize();
    await ads.completed(1, canShow: () => true);
    expect(ads.canRemove, isFalse);
    expect(ads.hasAds, isFalse);
    expect(sdk.shows, 0);
    ads.dispose();
  });
  test('store outage leaves ads independent and purchase hidden', () async {
    final sdk = FakeAds();
    final ads = Monetization(ads: sdk, purchases: FakePurchases()..fail = true);
    await ads.initialize();
    expect(ads.hasAds, isTrue);
    expect(ads.canRemove, isFalse);
    sdk.unavailable();
    await ads.completed(1, canShow: () => true);
    expect(sdk.shows, 0);
    ads.dispose();
  });
  for (final cached in [true, false]) {
    test(
      'cached/restored entitlement prevents SDK startup: cached=$cached',
      () async {
        final sdk = FakeAds();
        final store = FakePurchases()
          ..cached = cached
          ..owned = !cached
          ..fail = cached;
        final ads = Monetization(ads: sdk, purchases: store);
        await ads.initialize();
        expect(ads.removed, isTrue);
        expect(store.cached, isTrue);
        expect(sdk.starts, 0);
        expect(ads.canRemove, isFalse);
        ads.dispose();
      },
    );
  }
  test('one show per parcel and no late/background shows', () async {
    final sdk = FakeAds();
    final ads = Monetization(ads: sdk, purchases: FakePurchases());
    await ads.initialize();
    await ads.completed(1, canShow: () => true);
    await ads.completed(1, canShow: () => true);
    await ads.completed(2, canShow: () => false);
    await ads.completed(2, canShow: () => true);
    expect(sdk.shows, 1);
    sdk.failShow = true;
    await ads.completed(3, canShow: () => true);
    expect(ads.presenting, isFalse);
    ads.dispose();
  });
  test('purchase is serialized, persisted and stops both formats', () async {
    final sdk = FakeAds();
    final store = FakePurchases()..pending = Completer<bool>();
    final ads = Monetization(ads: sdk, purchases: store);
    await ads.initialize();
    final buying = ads.removeAds();
    expect(await ads.removeAds(), isFalse);
    await ads.completed(1, canShow: () => true);
    expect(sdk.shows, 0);
    store.pending!.complete(true);
    expect(await buying, isTrue);
    expect(store.buys, 1);
    expect(store.cached, isTrue);
    expect(sdk.stops, 1);
    expect(ads.hasAds, isFalse);
    expect(ads.canRemove, isFalse);
    ads.dispose();
  });
  test('cancelled/failed purchase never grants ad removal', () async {
    final store = FakePurchases()..accepted = false;
    final ads = Monetization(ads: FakeAds(), purchases: store);
    await ads.initialize();
    expect(await ads.removeAds(), isFalse);
    store.fail = true;
    expect(await ads.removeAds(), isFalse);
    expect(ads.removed, isFalse);
    expect(ads.purchasing, isFalse);
    ads.dispose();
  });
}
