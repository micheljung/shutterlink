import 'package:shutterlink/data/sessions_credentials.dart';

class FakeSessionsCredentials implements SessionsCredentials {
  FakeSessionsCredentials([this._token]);

  String? _token;
  int reads = 0;

  @override
  Future<String?> token() async {
    reads++;
    return _token;
  }

  @override
  Future<void> setToken(String? token) async => _token = token;
}
