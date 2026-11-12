import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class NetworkBinder {
  /// Routes this process's sockets over Wi-Fi and returns the Wi-Fi gateway,
  /// so the camera stays reachable while mobile data is the default route.
  Future<String?> bindToWifi();

  Future<void> unbind();

  /// Lets Wi-Fi deliver multicast packets, which Android drops by default.
  Future<void> acquireMulticastLock();

  Future<void> releaseMulticastLock();
}

class PlatformNetworkBinder implements NetworkBinder {
  const PlatformNetworkBinder();

  static const channel = MethodChannel('ch.micheljung.shutterlink/network');

  @override
  Future<String?> bindToWifi() async {
    if (!Platform.isAndroid) return null;
    return channel.invokeMethod<String>('bindToWifi');
  }

  @override
  Future<void> unbind() async {
    if (!Platform.isAndroid) return;
    await channel.invokeMethod<void>('unbind');
  }

  @override
  Future<void> acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    await channel.invokeMethod<void>('acquireMulticastLock');
  }

  @override
  Future<void> releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    await channel.invokeMethod<void>('releaseMulticastLock');
  }
}
