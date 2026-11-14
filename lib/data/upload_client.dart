import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../feature/sessions/session.dart';
import '../upload/storage_backend.dart';
import 'sessions_upload_queue.dart';

/// How long an upload may go without sending or receiving anything.
const uploadIdleTimeout = Duration(seconds: 30);

const tokenCheckTimeout = Duration(seconds: 15);

enum TokenCheck {
  valid,
  rejected,

  /// The server predates the token check, or is not a Sessions server.
  unsupported,
  unreachable,
}

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
  const UploadClient({this._idleTimeout = uploadIdleTimeout});

  final Duration _idleTimeout;

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

  static Uri authUrl(Uri serverUrl) => serverUrl.replace(
    pathSegments: [
      ...serverUrl.pathSegments.where((segment) => segment.isNotEmpty),
      'api',
      'auth',
    ],
  );

  Future<TokenCheck> checkToken(
    http.Client client, {
    required Uri serverUrl,
    required String token,
    Duration timeout = tokenCheckTimeout,
  }) async {
    try {
      final response = await client
          .get(
            authUrl(serverUrl),
            headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
          )
          .timeout(timeout);
      return switch (response.statusCode) {
        HttpStatus.noContent => TokenCheck.valid,
        HttpStatus.unauthorized => TokenCheck.rejected,
        _ => TokenCheck.unsupported,
      };
    } on IOException {
      return TokenCheck.unreachable;
    } on TimeoutException {
      return TokenCheck.unreachable;
    } on http.ClientException {
      return TokenCheck.unreachable;
    } on StorageException {
      return TokenCheck.unreachable;
    }
  }

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
    final abort = Completer<void>();
    var readFailed = false;
    Timer? idle;
    void progress() {
      idle?.cancel();
      idle = Timer(_idleTimeout, () {
        if (!abort.isCompleted) abort.complete();
      });
    }

    Future<T> guarded<T>(Future<T> future) => Future.any([
      future,
      abort.future.then<T>((_) => throw TimeoutException(null)),
    ]);

    final request =
        http.AbortableStreamedRequest(
            'PUT',
            photoUrl(serverUrl, item.sessionCode, item.photoKey),
            abortTrigger: abort.future,
          )
          ..contentLength = length
          ..headers[HttpHeaders.authorizationHeader] = 'Bearer $token'
          ..headers[HttpHeaders.contentTypeHeader] = 'image/jpeg';
    progress();
    try {
      final sending = client.send(request);
      unawaited(
        request.sink
            .addStream(
              file
                  .openRead()
                  .map((chunk) {
                    progress();
                    return chunk;
                  })
                  .handleError((Object _) {
                    readFailed = true;
                    if (!abort.isCompleted) abort.complete();
                  }),
            )
            .whenComplete(request.sink.close),
      );
      final response = await guarded(
        sending.then((streamed) {
          progress();
          return http.Response.fromStream(streamed);
        }),
      );
      if (readFailed) return const UploadRejected(_missingFile);
      return classify(response.statusCode, response.body);
    } on Exception catch (error) {
      if (readFailed) return const UploadRejected(_missingFile);
      return switch (error) {
        SocketException(:final message) => UploadRetry('socket: $message'),
        TimeoutException() ||
        http.RequestAbortedException() => const UploadRetry('timeout'),
        http.ClientException(:final message) => UploadRetry('client: $message'),
        HttpException(:final message) => UploadRetry('http: $message'),
        FileSystemException() => const UploadRejected(_missingFile),
        StorageException(:final message, retryable: true) => UploadRetry(
          'network: $message',
        ),
        StorageException(:final message) => UploadMisconfigured(
          'network: $message',
        ),
        _ => throw error,
      };
    } finally {
      idle?.cancel();
      if (!abort.isCompleted) abort.complete();
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
