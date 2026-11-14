import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'codes.dart';
import 'limits.dart' as limits;
import 'locks.dart';
import 'pages.dart';
import 'store.dart';
import 'tips.dart';
import 'zip_stream.dart';

const Map<String, String> securityHeaders = {
  'content-security-policy':
      "default-src 'none'; img-src 'self'; style-src 'self'; "
      "form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  'cache-control': 'no-store',
  'referrer-policy': 'no-referrer',
  'x-robots-tag': 'noindex',
  'x-content-type-options': 'nosniff',
};

const String _htmlType = 'text/html; charset=utf-8';
const String _jsonType = 'application/json';
const String _bearerPrefix = 'Bearer ';
const String _photoSuffix = '.jpg';

class ShutterlinkApp {
  ShutterlinkApp._(
    this.store,
    this._uploadToken,
    this._tips,
    this._zipSlots,
    this._zipQueueTimeout,
    this._zipIdleTimeout,
  );

  static Future<ShutterlinkApp> open({
    required Directory dataDir,
    required String uploadToken,
    List<Tip> tips = const [],
    Duration retention = limits.defaultRetention,
    Clock clock = const Clock(),
    int maxPhotoBytes = limits.maxPhotoBytes,
    int maxSessionBytes = limits.maxSessionBytes,
    int zipConcurrency = limits.zipConcurrency,
    Duration zipQueueTimeout = limits.zipQueueTimeout,
    Duration zipIdleTimeout = limits.zipIdleTimeout,
  }) async {
    if (uploadToken.isEmpty) {
      throw ArgumentError.value(
        uploadToken,
        'uploadToken',
        'must not be empty',
      );
    }
    final store = await SessionStore.open(
      dataDir,
      clock: clock,
      retention: retention,
      maxPhotoBytes: maxPhotoBytes,
      maxSessionBytes: maxSessionBytes,
    );
    return ShutterlinkApp._(
      store,
      uploadToken,
      List.unmodifiable(tips),
      Semaphore(zipConcurrency),
      zipQueueTimeout,
      zipIdleTimeout,
    );
  }

  final SessionStore store;
  final String _uploadToken;
  final List<Tip> _tips;
  final Semaphore _zipSlots;
  final Duration _zipQueueTimeout;
  final Duration _zipIdleTimeout;

  late final Handler handler = const Pipeline()
      .addMiddleware(_addSecurityHeaders)
      .addHandler(_router.call);

  late final Router _router = Router(notFoundHandler: _notFound)
    ..put('/api/sessions/<code>/photos/<key>', _put)
    ..get('/api/auth', _auth)
    ..get('/', (Request _) => _html(landingPage))
    ..get('/static/app.css', (Request _) => _css())
    ..get('/s', _redirect)
    ..get('/s/<code>', _gallery)
    ..get('/s/<code>/p/<file>', _photo)
    ..head('/s/<code>/all.zip', (Request _, String _) => _onTheirWay())
    ..get('/s/<code>/all.zip', _zip);

  static Handler _addSecurityHeaders(Handler inner) {
    return (request) async {
      final response = await inner(request);
      return response.change(headers: securityHeaders);
    };
  }

  static Response _html(List<int> body) =>
      Response.ok(body, headers: {HttpHeaders.contentTypeHeader: _htmlType});

  static Response _onTheirWay() => _html(onTheirWayPage);

  static Response _css() => Response.ok(
    appCss,
    headers: {HttpHeaders.contentTypeHeader: 'text/css; charset=utf-8'},
  );

  static Response _json(int status, Map<String, Object> body) => Response(
    status,
    body: jsonEncode(body),
    headers: {HttpHeaders.contentTypeHeader: _jsonType},
  );

  static Response _error(int status, String error) =>
      _json(status, {'error': error});

  static Response _notFound(Request request) {
    if (request.method == 'GET' || request.method == 'HEAD') {
      return _onTheirWay();
    }
    return Response.notFound(null);
  }

  bool _authorized(Request request) {
    final header = request.headers[HttpHeaders.authorizationHeader];
    if (header == null || !header.startsWith(_bearerPrefix)) return false;
    return constantTimeEquals(
      header.substring(_bearerPrefix.length),
      _uploadToken,
    );
  }

  Response _auth(Request request) => _authorized(request)
      ? Response(HttpStatus.noContent)
      : _error(HttpStatus.unauthorized, 'unauthorized');

  Future<Response> _put(Request request, String code, String key) async {
    if (!_authorized(request)) {
      return _error(HttpStatus.unauthorized, 'unauthorized');
    }
    final normalized = normalizeCode(code);
    if (normalized == null) return _error(HttpStatus.badRequest, 'bad_code');
    if (!isValidKey(key)) return _error(HttpStatus.badRequest, 'bad_key');
    final length = request.contentLength;
    if (length != null && length > store.maxPhotoBytes) {
      return _error(HttpStatus.requestEntityTooLarge, 'too_large');
    }
    final result = await store.put(normalized, key, request.read());
    return switch (result.error) {
      null => _json(result.created ? HttpStatus.created : HttpStatus.ok, {
        'expiresAt': result.expiresAt!.toUtc().toIso8601String(),
      }),
      PutError.tooLarge => _error(
        HttpStatus.requestEntityTooLarge,
        'too_large',
      ),
      PutError.sessionFull => _error(
        HttpStatus.requestEntityTooLarge,
        'session_full',
      ),
      PutError.shaMismatch => _error(HttpStatus.badRequest, 'sha_mismatch'),
      PutError.expired => _error(HttpStatus.gone, 'expired'),
    };
  }

  Response _redirect(Request request) {
    final code = normalizeCode(request.url.queryParameters['code']);
    if (code == null) return _onTheirWay();
    return Response(
      HttpStatus.seeOther,
      headers: {HttpHeaders.locationHeader: '/s/${Uri.encodeComponent(code)}'},
    );
  }

  Future<Response> _gallery(Request request, String code) async {
    final normalized = normalizeCode(code);
    if (normalized == null) return _onTheirWay();
    final snapshot = await store.snapshot(normalized);
    if (snapshot == null) return _onTheirWay();
    return _html(galleryPage(normalized, snapshot, _tips));
  }

  Future<Response> _photo(Request request, String code, String file) async {
    final normalized = normalizeCode(code);
    if (normalized == null || !file.endsWith(_photoSuffix)) {
      return _onTheirWay();
    }
    final key = file.substring(0, file.length - _photoSuffix.length);
    if (!isValidKey(key)) return _onTheirWay();
    final photo = await store.photo(normalized, key);
    if (photo == null) return _onTheirWay();
    return Response.ok(
      photo.file.openRead(),
      headers: {
        HttpHeaders.contentTypeHeader: 'image/jpeg',
        HttpHeaders.contentLengthHeader: '${photo.size}',
      },
    );
  }

  Future<Response> _zip(Request request, String code) async {
    final waited = Stopwatch()..start();
    if (!await _zipSlots.acquire(_zipQueueTimeout)) return _busy();
    var slotHandedOff = false;
    try {
      final normalized = normalizeCode(code);
      if (normalized == null) return _onTheirWay();
      final name = store.dirName(normalized);
      final remaining = _zipQueueTimeout - waited.elapsed;
      if (!await store.zipLocks.acquire(name, remaining)) return _busy();
      var lockHandedOff = false;
      try {
        final snapshot = await store.snapshot(normalized);
        if (snapshot == null) return _onTheirWay();
        final body = _releasing(
          _zipIdleTimeout,
          storeZip([
            for (final photo in snapshot.photos)
              ZipEntry(
                '${photo.key}$_photoSuffix',
                snapshot.createdAt,
                photo.file.openRead,
              ),
          ]),
          () {
            store.zipLocks.release(name);
            _zipSlots.release();
          },
        );
        lockHandedOff = slotHandedOff = true;
        return Response.ok(
          body,
          headers: {
            HttpHeaders.contentTypeHeader: 'application/zip',
            'content-disposition': 'attachment; filename="photos.zip"',
          },
        );
      } finally {
        if (!lockHandedOff) store.zipLocks.release(name);
      }
    } finally {
      if (!slotHandedOff) _zipSlots.release();
    }
  }

  Response _busy() => Response(
    HttpStatus.serviceUnavailable,
    body: 'Busy, please retry.',
    headers: {
      HttpHeaders.retryAfterHeader: '${_zipQueueTimeout.inSeconds}',
      HttpHeaders.contentTypeHeader: 'text/plain; charset=utf-8',
    },
  );

  /// Runs [release] once the body ends, the client goes away, or the client
  /// stops taking data for [idleTimeout], so a stalled download cannot hold
  /// a zip slot.
  static Stream<List<int>> _releasing(
    Duration idleTimeout,
    Stream<List<int>> source,
    void Function() release,
  ) {
    var released = false;
    void releaseOnce() {
      if (released) return;
      released = true;
      release();
    }

    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? idle;
    void arm() {
      idle?.cancel();
      idle = Timer(idleTimeout, () async {
        await subscription?.cancel();
        releaseOnce();
        controller.addError(TimeoutException('Zip download stalled'));
        await controller.close();
      });
    }

    controller = StreamController(
      onListen: () {
        subscription = source.listen(
          (chunk) {
            arm();
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: () {
            idle?.cancel();
            releaseOnce();
            controller.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        idle?.cancel();
        await subscription?.cancel();
        releaseOnce();
      },
    );
    arm();
    return controller.stream;
  }
}
