import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionsCredentials {
  Future<String?> token();

  Future<void> setToken(String? token);
}

class SecureSessionsCredentials implements SessionsCredentials {
  SecureSessionsCredentials({this._storage = const FlutterSecureStorage()});

  static const tokenKey = 'sessions_upload_token';

  final FlutterSecureStorage _storage;
  Future<String?>? _token;

  @override
  Future<String?> token() async {
    final read = _token ??= _storage.read(key: tokenKey);
    try {
      return await read;
    } on Object {
      _token = null;
      rethrow;
    }
  }

  @override
  Future<void> setToken(String? token) async {
    final trimmed = token?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _storage.delete(key: tokenKey);
      _token = Future.value();
    } else {
      await _storage.write(key: tokenKey, value: trimmed);
      _token = Future.value(trimmed);
    }
  }
}
