import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rustore_pay/api/flutter_rustore_pay_client.dart';
import 'package:flutter_rustore_pay/model/acknowledgement_state.dart';
import 'package:flutter_rustore_pay/model/preferred_purchase_type.dart';
import 'package:flutter_rustore_pay/model/product_type.dart';
import 'package:flutter_rustore_pay/model/purchase.dart';
import 'package:flutter_rustore_pay/model/purchase_result.dart';
import 'package:flutter_rustore_pay/model/purchase_availability.dart';
import 'package:flutter_rustore_pay/model/ru_store_exception.dart';
import 'package:yandex_mobileads/mobile_ads.dart';

import 'monetization.dart';

Monetization androidMonetization() {
  if (!Platform.isAndroid) return Monetization();
  const enabled = bool.fromEnvironment('BRIZFI_ADS', defaultValue: true);
  if (!enabled) return Monetization();
  // Real placements are used only in release. Development never records live impressions.
  const banner = String.fromEnvironment(
    'BRIZFI_BANNER_ID',
    defaultValue: 'R-M-20236521-1',
  );
  const interstitial = String.fromEnvironment(
    'BRIZFI_INTERSTITIAL_ID',
    defaultValue: 'R-M-20236521-2',
  );
  return Monetization(
    ads: _YandexAds(
      kReleaseMode ? banner : 'demo-banner-yandex',
      kReleaseMode ? interstitial : 'demo-interstitial-yandex',
    ),
    purchases: _RuStorePurchases(),
  );
}

class _YandexAds extends AdsGateway {
  _YandexAds(this.bannerId, this.interstitialId);
  final String bannerId;
  final String interstitialId;
  BannerAd? _banner;
  StreamSubscription<BannerAdLoadState>? _bannerEvents;
  InterstitialAdLoader? _loader;
  InterstitialAd? _interstitial;
  int _width = 0;
  bool _bannerReady = false;
  bool _stopped = false;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;
  Timer? _bannerTimeout;
  Completer<void>? _showing;

  @override
  bool get available =>
      !_stopped && !_failed && (_bannerReady || _interstitial != null);

  void _failure() {
    if (_stopped || _failed) return;
    _failed = true;
    _releaseBanner();
    _showing?.completeIfPending();
    notifyListeners();
  }

  // Some plugin calls don't await their platform futures. Keep these errors inside
  // the optional SDK boundary as well as catching the documented SDK errors.
  Future<void> _guard(Future<void> Function() action) {
    final result = Completer<void>();
    runZonedGuarded(
      () async {
        try {
          await action();
        } catch (_) {
          _failure();
        } finally {
          result.completeIfPending();
        }
      },
      (_, _) {
        _failure();
        result.completeIfPending();
      },
    );
    return result.future;
  }

  @override
  Future<void> initialize() async {
    await _guard(() async {
      await YandexAds.setUserConsent(false);
      await YandexAds.setLocationTracking(false);
      await YandexAds.initialize();
    });
    if (_failed) throw StateError('Optional ads SDK unavailable');
  }

  @override
  Widget banner(int width) {
    if (_stopped || _failed || bannerId.isEmpty) return const SizedBox.shrink();
    if (_banner == null || _width != width) {
      _releaseBanner();
      _width = width;
      unawaited(
        _guard(() async {
          final banner = BannerAd(adSize: BannerAdSize.sticky(width: width));
          _banner = banner;
          _bannerEvents = banner.loadStateStream.listen((state) {
            if (_stopped || !identical(_banner, banner)) return;
            if (state is BannerAdLoadStateLoaded) {
              _bannerTimeout?.cancel();
              _bannerReady = true;
              notifyListeners();
            } else if (state is BannerAdLoadStateError) {
              _failure();
            }
          }, onError: (_, _) => _failure());
          _bannerTimeout = Timer(Monetization.adTimeout, _failure);
          await banner.load(AdRequest(adUnitId: bannerId));
          // v8.6 creates the platform widget asynchronously during load(). Mount
          // it only after that future completes, otherwise no request can start.
          if (!_stopped && identical(_banner, banner)) notifyListeners();
        }),
      );
    }
    final ad = _banner;
    if (ad == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      bottom: _bannerReady,
      child: Center(heightFactor: 1, child: AdWidget(bannerAd: ad)),
    );
  }

  @override
  Future<void> preload() async {
    if (_stopped ||
        _failed ||
        _loading ||
        _interstitial != null ||
        interstitialId.isEmpty) {
      return;
    }
    _loading = true;
    final generation = _generation;
    await _guard(() async {
      _loader ??= InterstitialAdLoader();
      final ad = await _loader!.loadAd(
        adRequest: AdRequest(adUnitId: interstitialId),
      );
      if (_stopped || generation != _generation) {
        await ad.destroy();
        return;
      }
      _interstitial = ad;
      notifyListeners();
    });
    _loading = false;
  }

  @override
  Future<void> showReady() => _guard(() async {
    final ad = _interstitial;
    if (_stopped || _failed || ad == null) return;
    _interstitial = null;
    final done = Completer<void>();
    _showing = done;
    await ad.setAdEventListener(
      eventListener: InterstitialAdEventListener(
        onAdDismissed: done.completeIfPending,
        onAdFailedToShow: (_) {
          _failure();
          done.completeIfPending();
        },
      ),
    );
    try {
      await ad.show();
      await done.future;
    } finally {
      _showing = null;
      await ad.destroy();
      if (!_stopped) notifyListeners();
    }
  });

  void _releaseBanner() {
    _bannerTimeout?.cancel();
    unawaited(_bannerEvents?.cancel());
    _bannerEvents = null;
    final banner = _banner;
    _banner = null;
    _bannerReady = false;
    if (banner != null) unawaited(_guard(banner.destroy));
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _generation++;
    _showing?.completeIfPending();
    _releaseBanner();
    await _guard(() async {
      _loader?.destroy();
      _loader = null;
      await _interstitial?.destroy();
      _interstitial = null;
    });
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}

class _RuStorePurchases implements PurchaseGateway {
  static const _channel = MethodChannel('ru.mkulkov.brizfi/monetization');
  static const _appId = String.fromEnvironment(
    'BRIZFI_RUSTORE_APP_ID',
    defaultValue: '2063767962',
  );
  static const _productId = String.fromEnvironment(
    'BRIZFI_REMOVE_ADS_PRODUCT',
    defaultValue: 'donate_499',
  );
  final _client = RuStorePayClient.instance;
  bool get _configured => _appId.isNotEmpty && _productId.isNotEmpty;

  @override
  Future<bool> readRemoved() async =>
      await _channel.invokeMethod<bool>('adsRemoved', {
        'test': !kReleaseMode,
      }) ??
      false;

  @override
  Future<void> saveRemoved() =>
      _channel.invokeMethod<void>('setAdsRemoved', {'test': !kReleaseMode});

  @override
  Future<bool> restore() async {
    if (!_configured) return false;
    final purchases = await _client.purchaseInteractor.getPurchases(
      productType: ProductType.nonConsumable,
      purchaseStatus: ProductPurchaseStatus.confirmed,
    );
    for (final purchase in purchases.whereType<ProductPurchase>()) {
      if (purchase.productId == _productId &&
          (!kReleaseMode || !purchase.sandbox)) {
        // Persist before acknowledgement; a later restore can retry acknowledgement.
        try {
          await saveRemoved();
          unawaited(
            _client.purchaseInteractor
                .updateAcknowledgementState(
                  purchase.purchaseId,
                  AcknowledgementState.acknowledged,
                )
                .timeout(Monetization.timeout)
                .then<void>((_) {}, onError: (Object _) {}),
          );
        } catch (_) {
          // Still grant the confirmed entitlement; retry persistence on restore.
        }
        return true;
      }
    }
    return false;
  }

  @override
  Future<String?> price() async {
    if (!_configured) return null;
    if (await _client.purchaseInteractor.getPurchaseAvailability()
        is! Available) {
      return null;
    }
    final products = await _client.productInteractor.getProducts([_productId]);
    return products
        .where(
          (p) =>
              p.productId == _productId && p.type == ProductType.nonConsumable,
        )
        .firstOrNull
        ?.amountLabel;
  }

  @override
  Future<bool> purchase() async {
    if (!_configured) return false;
    if (await restore()) return true;
    late final ProductPurchaseResult result;
    try {
      result = await _client.purchaseInteractor.purchase(
        _productId,
        preferredPurchaseType: PreferredPurchaseType.oneStep,
      );
    } on RuStorePurchaseCancelledException {
      return false;
    }
    if (result.productId != _productId ||
        result.productType != ProductType.nonConsumable ||
        (kReleaseMode && result.sandbox)) {
      return false;
    }
    return restore();
  }
}
