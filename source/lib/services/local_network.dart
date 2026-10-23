import 'dart:io';

import 'package:flutter/services.dart';

class LocalNetwork {
  static const channel = MethodChannel('ru.mkulkov.brizfi/network');

  static Future<List<InternetAddress>> addresses() async {
    if (Platform.isWindows) {
      // Native Windows checks adapter type, link state and HardwareInterface.
      // Never fall back to all RFC1918 addresses: VPNs use them as well.
      final values = await channel.invokeListMethod<String>('lanAddresses');
      return (values ?? [])
          .map(InternetAddress.tryParse)
          .whereType<InternetAddress>()
          .where(isPrivateIpv4)
          .toSet()
          .toList();
    }
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return interfaces.expand((i) => i.addresses).where(isPrivateIpv4).toList();
  }

  static bool isPrivateIpv4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
}
