import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'services/monetization.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({
    super.key,
    required this.enableUsb,
    required this.allowMultiple,
    this.monetization,
  });

  final bool enableUsb;
  final bool allowMultiple;
  final Monetization? monetization;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final content = SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (monetization != null)
                  ListenableBuilder(
                    listenable: monetization!,
                    builder: (context, _) {
                      final ads = monetization!;
                      if (!ads.canRemove) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FilledButton.tonal(
                          key: const ValueKey('remove-ads'),
                          onPressed: ads.purchasing
                              ? null
                              : () async {
                                  final removed = await ads.removeAds();
                                  if (!context.mounted || removed) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(l.adsPurchaseFailed),
                                    ),
                                  );
                                },
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          child: Text(
                            ads.purchasing
                                ? l.adsPurchasing
                                : l.adsRemove(ads.price!),
                          ),
                        ),
                      );
                    },
                  ),
                _heading(context, 'BRIZFI'),
                Text(l.aboutDescription),
                _heading(context, l.aboutWifi),
                Text(l.aboutPhoneSteps),
                _heading(context, l.aboutReader),
                Text(l.instructions),
                if (enableUsb) ...[
                  _heading(context, l.usbMode),
                  Text(
                    Platform.isWindows
                        ? l.usbWindowsInstructions
                        : l.usbInstructions,
                  ),
                  const SizedBox(height: 12),
                  Text(Platform.isWindows ? l.usbWindowsNotice : l.usbNotice),
                  const SizedBox(height: 12),
                  Text(l.aboutUsbCompletion),
                ],
                _heading(context, l.aboutFormats),
                Text(
                  Platform.isAndroid
                      ? l.androidFormatsHelp
                      : Platform.isWindows
                      ? l.windowsFormatsHelp
                      : allowMultiple
                      ? l.aboutBatchLimits
                      : l.aboutSingleLimits,
                ),
                _heading(context, l.aboutPrivacy),
                Text(l.notice),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: 12),
                  Text(l.adsPrivacy),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (Platform.isIOS) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(middle: Text(l.aboutTitle)),
        child: content,
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(l.aboutTitle)),
      body: content,
    );
  }

  Widget _heading(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: Platform.isIOS
            ? CupertinoTheme.of(context).textTheme.navTitleTextStyle
            : Theme.of(context).textTheme.titleLarge,
      ),
    ),
  );
}
