import 'dart:async';

import 'package:flutter/material.dart';

abstract class AdsGateway extends ChangeNotifier {
  bool get available;
  Widget banner(int width);
  Future<void> initialize();
  Future<void> preload();
  Future<void> showReady();
  Future<void> stop();
}

abstract interface class PurchaseGateway {
  Future<bool> restore();
  Future<String?> price();
  Future<bool> purchase();
  Future<bool> readRemoved();
  Future<void> saveRemoved();
}

/// Optional monetization never participates in the transfer's success path.
class Monetization extends ChangeNotifier {
  Monetization({this.ads, this.purchases});

  final AdsGateway? ads;
  final PurchaseGateway? purchases;
  bool removed = false;
  bool ready = false;
  bool purchasing = false;
  bool presenting = false;
  String? price;
  bool _disposed = false;
  Future<void>? _initialization;
  final _completed = <Object>{};
  static const timeout = Duration(seconds: 8);
  static const adTimeout = Duration(seconds: 30);

  bool get canRemove =>
      ready && !removed && ads?.available == true && price != null;
  bool get hasAds => ready && !removed && ads != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (ads == null) return;
    ads!.addListener(_changed);
    try {
      removed = await purchases?.readRemoved().timeout(timeout) ?? false;
      if (purchases != null) {
        try {
          removed = await purchases!.restore().timeout(timeout) || removed;
          if (removed) await purchases!.saveRemoved().timeout(timeout);
        } catch (_) {
          // Offline/absent store: retain the locally granted entitlement.
        }
      }
      if (_disposed || removed) return;
      await ads!.initialize().timeout(adTimeout);
      if (_disposed) return;
      ready = true;
      _changed();
      unawaited(_prepare());
      try {
        price = await purchases?.price().timeout(timeout);
      } catch (_) {
        price = null;
      }
    } catch (_) {
      ready = false;
    } finally {
      _changed();
    }
  }

  Future<void> _prepare() async {
    try {
      await ads?.preload().timeout(adTimeout);
    } catch (_) {
      // No retries in an error loop; another parcel can preload again.
    }
  }

  void prepareParcel() {
    if (hasAds && !presenting) unawaited(_prepare());
  }

  Future<void> completed(
    Object parcel, {
    required bool Function() canShow,
  }) async {
    if (!_completed.add(parcel)) return;
    // Never wait for ad loading or show an ad late after leaving the result.
    if (!hasAds ||
        ads?.available != true ||
        presenting ||
        purchasing ||
        !canShow()) {
      return;
    }
    presenting = true;
    _changed();
    try {
      await ads!.showReady();
    } catch (_) {
      // Missing SDK, no fill, or display failure cannot change the result.
    } finally {
      presenting = false;
      _changed();
    }
  }

  Future<bool> removeAds() async {
    if (!canRemove || purchasing || presenting) return false;
    purchasing = true;
    _changed();
    try {
      if (!await purchases!.purchase()) return false;
      removed = true;
      _changed();
      try {
        await purchases!.saveRemoved().timeout(timeout);
      } catch (_) {
        // Store restore recovers the confirmed purchase next time.
      }
      try {
        await ads?.stop().timeout(timeout);
      } catch (_) {
        // Payment is confirmed even if the optional SDK fails during teardown.
      }
      return true;
    } catch (_) {
      price = null;
      return false;
    } finally {
      purchasing = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ads?.removeListener(_changed);
    ads?.dispose();
    super.dispose();
  }
}
