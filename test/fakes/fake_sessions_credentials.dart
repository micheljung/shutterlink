import 'package:shutterlink/data/sessions_credentials.dart';

class FakeSessionsCredentials implements SessionsCredentials {
  FakeSessionsCredentials([this._token]);

  String? _token;
  int reads = 0;
  Object? readError;

  @override
  Future<String?> token() async {
    reads++;
    if (readError case final error?) throw error;
    return _token;
  }

  @override
  Future<void> setToken(String? token) async => _token = token;
}
