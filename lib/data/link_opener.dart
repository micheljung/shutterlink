import 'package:flutter/services.dart';

/// Opens a web page in the user's browser.
class LinkOpener {
  const LinkOpener();

  static const channel = MethodChannel('ch.micheljung.shutterlink/browser');

  /// Whether a browser took [url].
  Future<bool> open(Uri url) async {
    try {
      return await channel.invokeMethod<bool>('open', {
            'url': url.toString(),
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
