import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../feature/sessions/session.dart';
import '../upload/storage_backend.dart';
import 'sessions_upload_queue.dart';

const requestTimeout = Duration(minutes: 2);

sealed class UploadResult {
  const UploadResult(this.status);

  final String status;
}

class UploadDone extends UploadResult {
  const UploadDone(this.expiresAt, super.status);

  final DateTime expiresAt;
}

class UploadExpired extends UploadResult {
  const UploadExpired(super.status);
}

class UploadUnauthorized extends UploadResult {
  const UploadUnauthorized(super.status);
}

class UploadRejected extends UploadResult {
  const UploadRejected(super.status);
}

class UploadRetry extends UploadResult {
  const UploadRetry(super.status);
}

class UploadMisconfigured extends UploadResult {
  const UploadMisconfigured(super.status);
}

class UploadClient {
  const UploadClient();

  static const _expiredError = 'expired';
  static const _droppingErrors = {
    'sha_mismatch',
    'too_large',
    'bad_code',
    'bad_key',
    'session_full',
  };
  static const _missingFile = 'missing_file';

  static Uri photoUrl(Uri serverUrl, String code, String photoKey) =>
      serverUrl.replace(
        pathSegments: [
          ...serverUrl.pathSegments.where((segment) => segment.isNotEmpty),
          'api',
          'sessions',
          code,
          'photos',
          photoKey,
        ],
      );

  Future<UploadResult> upload(
    http.Client client, {
    required Uri serverUrl,
    required String token,
    required UploadItem item,
  }) async {
    final file = File(item.filePath);
    final int length;
    try {
      length = await file.length();
    } on FileSystemException {
      return const UploadRejected(_missingFile);
    }
    final request =
        http.StreamedRequest(
            'PUT',
            photoUrl(serverUrl, item.sessionCode, item.photoKey),
          )
          ..contentLength = length
          ..headers[HttpHeaders.authorizationHeader] = 'Bearer $token'
          ..headers[HttpHeaders.contentTypeHeader] = 'image/jpeg';
    try {
      final response = await () async {
        final sending = client.send(request);
        unawaited(file.openRead().pipe(request.sink).catchError((Object _) {}));
        return http.Response.fromStream(await sending);
      }().timeout(requestTimeout);
      return classify(response.statusCode, response.body);
    } on SocketException catch (error) {
      return UploadRetry('socket: ${error.message}');
    } on TimeoutException {
      return const UploadRetry('timeout');
    } on http.ClientException catch (error) {
      return UploadRetry('client: ${error.message}');
    } on HttpException catch (error) {
      return UploadRetry('http: ${error.message}');
    } on FileSystemException {
      return const UploadRejected(_missingFile);
    } on StorageException catch (error) {
      return error.retryable
          ? UploadRetry('network: ${error.message}')
          : UploadMisconfigured('network: ${error.message}');
    }
  }

  static UploadResult classify(int statusCode, String body) {
    final status = '$statusCode';
    final json = _json(body);
    final error = json?['error'];
    if (statusCode >= HttpStatus.ok &&
        statusCode < HttpStatus.multipleChoices) {
      final expiresAt = _expiresAt(json?['expiresAt']);
      return expiresAt == null
          ? UploadMisconfigured(status)
          : UploadDone(expiresAt, status);
    }
    if (statusCode == HttpStatus.gone && error == _expiredError) {
      return UploadExpired(status);
    }
    if (statusCode == HttpStatus.unauthorized) {
      return UploadUnauthorized(status);
    }
    if ((statusCode == HttpStatus.badRequest ||
            statusCode == HttpStatus.requestEntityTooLarge) &&
        _droppingErrors.contains(error)) {
      return UploadRejected('$status $error');
    }
    if (statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.tooManyRequests ||
        statusCode >= HttpStatus.internalServerError) {
      return UploadRetry(status);
    }
    return UploadMisconfigured(status);
  }

  static Map<String, Object?>? _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static DateTime? _expiresAt(Object? value) {
    try {
      return parseUtc(value);
    } on FormatException {
      return null;
    }
  }
}
