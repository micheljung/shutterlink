import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class NetworkBinder {
  /// Routes this process's sockets over Wi-Fi on behalf of [owner] and
  /// returns the Wi-Fi gateway, so the camera stays reachable while mobile
  /// data is the default route. Acquiring again rebinds, e.g. after the Wi-Fi
  /// reconnected, without adding a second reference for the same owner.
  ///
  /// With [holdNetwork] the Wi-Fi is also kept up while the screen is off or
  /// mobile data is in use, until the binding ends.
  Future<String?> acquireBinding(String owner, {bool holdNetwork = false});

  /// Unbinds once no owner is left.
  Future<void> releaseBinding(String owner);

  /// Hands [from]'s reference to [to] without unbinding in between.
  void transferBinding(String from, String to);

  /// Fires when a held Wi-Fi is lost.
  Stream<void> get bindingLost;

  /// Lets Wi-Fi deliver multicast packets, which Android drops by default.
  Future<void> acquireMulticastLock();

  Future<void> releaseMulticastLock();
}

class PlatformNetworkBinder implements NetworkBinder {
  PlatformNetworkBinder({bool? isAndroid})
    : _isAndroid = isAndroid ?? Platform.isAndroid;

  static const channel = MethodChannel('ch.micheljung.shutterlink/network');
  static const events = EventChannel(
    'ch.micheljung.shutterlink/network/events',
  );

  final bool _isAndroid;
  final _owners = <String>{};

  @override
  Future<String?> acquireBinding(
    String owner, {
    bool holdNetwork = false,
  }) async {
    final gateway = _isAndroid
        ? await channel.invokeMethod<String>('bindToWifi', {
            'hold': holdNetwork,
          })
        : null;
    _owners.add(owner);
    return gateway;
  }

  @override
  Future<void> releaseBinding(String owner) async {
    if (!_owners.remove(owner) || _owners.isNotEmpty || !_isAndroid) return;
    await channel.invokeMethod<void>('unbind');
  }

  @override
  void transferBinding(String from, String to) {
    if (_owners.remove(from)) _owners.add(to);
  }

  @override
  Stream<void> get bindingLost => _isAndroid
      ? events.receiveBroadcastStream().map((_) {})
      : const Stream.empty();

  @override
  Future<void> acquireMulticastLock() async {
    if (!_isAndroid) return;
    await channel.invokeMethod<void>('acquireMulticastLock');
  }

  @override
  Future<void> releaseMulticastLock() async {
    if (!_isAndroid) return;
    await channel.invokeMethod<void>('releaseMulticastLock');
  }
}
