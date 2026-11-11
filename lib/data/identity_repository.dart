import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../ptpip/camera_client.dart';

class IdentityRepository {
  IdentityRepository(this._prefs, {this._uuid = const Uuid()});

  static const friendlyName = 'EOS Transfer';
  static const guidKey = 'camera_identity_guid';

  final SharedPreferences _prefs;
  final Uuid _uuid;

  Future<CameraIdentity> identity() async {
    final stored = _prefs.getString(guidKey);
    if (stored != null) {
      return CameraIdentity(guid: base64Decode(stored), name: friendlyName);
    }
    final guid = Uint8List.fromList(_uuid.v4obj().toBytes());
    await _prefs.setString(guidKey, base64Encode(guid));
    return CameraIdentity(guid: guid, name: friendlyName);
  }
}
