import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'codes.dart';
import 'doorbell.dart';
import 'limits.dart' as limits;
import 'locks.dart';
import 'pages.dart';
import 'previews.dart';
import 'store.dart';
import 'tips.dart';
import 'zip_stream.dart';

const Map<String, String> securityHeaders = {
  'content-security-policy':
      "default-src 'none'; img-src 'self'; style-src 'self'; "
      "script-src 'self'; connect-src 'self'; font-src 'self'; "
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
const String _eventStreamType = 'text/event-stream';
const String _noCache = 'no-cache';
const String _lastEventIdHeader = 'last-event-id';
const String _bufferOutputKey = 'shelf.io.buffer_output';
final List<int> _emptyPhotos = utf8.encode(
  jsonEncode({'count': 0, 'photos': <Object>[]}),
);

class ShutterlinkApp {
  ShutterlinkApp._(
    this.store,
    this._uploadToken,
    this._tips,
    this._zipSlots,
    this._zipQueueTimeout,
    this._zipIdleTimeout,
    this.previews,
    this.doorbell,
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
    int previewConcurrency = limits.previewConcurrency,
    Stream<void>? keepAliveTicks,
    int sseStreamsPerSession = limits.sseStreamsPerSession,
    int sseStreamsGlobal = limits.sseStreamsGlobal,
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
    final previews = PreviewQueue(store, concurrency: previewConcurrency);
    unawaited(previews.scan());
    return ShutterlinkApp._(
      store,
      uploadToken,
      List.unmodifiable(tips),
      Semaphore(zipConcurrency),
      zipQueueTimeout,
      zipIdleTimeout,
      previews,
      Doorbell(
        store,
        keepAliveTicks: keepAliveTicks,
        perSession: sseStreamsPerSession,
        global: sseStreamsGlobal,
      ),
    );
  }

  final SessionStore store;
  final PreviewQueue previews;
  final Doorbell doorbell;
  final String _uploadToken;
  final List<Tip> _tips;
  final Semaphore _zipSlots;
  final Duration _zipQueueTimeout;
  final Duration _zipIdleTimeout;

  /// Closes the event streams and stops preview generation. Call after the
  /// HTTP server has stopped, so no upload can queue a new job.
  Future<void> close() async {
    await doorbell.close();
    await previews.close();
  }

  late final Handler handler = const Pipeline()
      .addMiddleware(_addSecurityHeaders)
      .addHandler(_router.call);

  late final Router _router = Router(notFoundHandler: _notFound)
    ..put('/api/sessions/<code>/photos/<key>', _put)
    ..get('/api/auth', _auth)
    // Liveness only: no parameters, no Session data, no token.
    ..get('/healthz', (Request _) => Response(HttpStatus.noContent))
    ..get('/', (Request _) => _html(landingPage))
    ..get('/static/app.css', (Request _) => _css())
    ..get('/s', _redirect)
    ..get('/s/<code>', _gallery)
    ..get('/s/<code>/p/<file>', _photo)
    ..get(
      '/s/<code>/t/<file>',
      (Request request, String code, String file) =>
          _preview(code, file, PreviewKind.thumbnail),
    )
    ..get(
      '/s/<code>/v/<file>',
      (Request request, String code, String file) =>
          _preview(code, file, PreviewKind.view),
    )
    ..get('/s/<code>/photos.json', _photosJson)
    // A HEAD body is never read, so its stream would hold a slot forever.
    ..head('/s/<code>/events', (Request _, String _) => _onTheirWay())
    ..get('/s/<code>/events', _events)
    ..head('/s/<code>/all.zip', (Request _, String _) => _onTheirWay())
    ..get('/s/<code>/all.zip', _zip);

  static Handler _addSecurityHeaders(Handler inner) {
    return (request) async {
      final response = await inner(request);
      final own = response.headers[HttpHeaders.cacheControlHeader];
      return response.change(
        headers: {...securityHeaders, HttpHeaders.cacheControlHeader: ?own},
      );
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
    final key = _keyOf(file);
    if (normalized == null || key == null) return _onTheirWay();
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

  static String? _keyOf(String file) {
    if (!file.endsWith(_photoSuffix)) return null;
    final key = file.substring(0, file.length - _photoSuffix.length);
    return isValidKey(key) ? key : null;
  }

  bool _isLive(DateTime expiresAt) => store.clock.now().isBefore(expiresAt);

  Future<Response> _preview(String code, String file, PreviewKind kind) async {
    final normalized = normalizeCode(code);
    final key = _keyOf(file);
    if (normalized == null || key == null) return _onTheirWay();
    final preview = await store.previewFile(normalized, key, kind);
    if (preview == null || !_isLive(preview.expiresAt)) return _onTheirWay();
    final maxAge = preview.expiresAt.difference(store.clock.now()).inSeconds;
    return Response.ok(
      preview.file.openRead(),
      headers: {
        HttpHeaders.contentTypeHeader: 'image/jpeg',
        HttpHeaders.contentLengthHeader: '${preview.size}',
        HttpHeaders.cacheControlHeader: 'private, max-age=${max(0, maxAge)}',
      },
    );
  }

  String _etag(int generation) => '"${doorbell.eventId(generation)}"';

  static bool _matches(String? ifNoneMatch, String etag) {
    if (ifNoneMatch == null) return false;
    for (final candidate in ifNoneMatch.split(',')) {
      var tag = candidate.trim();
      if (tag.startsWith('W/')) tag = tag.substring(2);
      if (tag == etag) return true;
    }
    return false;
  }

  Future<Response> _photosJson(Request request, String code) async {
    final normalized = normalizeCode(code);
    if (normalized == null) return _onTheirWay();
    final current = store.generationOf(store.dirName(normalized));
    if (current != null &&
        _matches(
          request.headers[HttpHeaders.ifNoneMatchHeader],
          _etag(current),
        )) {
      return Response.notModified(
        headers: {
          HttpHeaders.etagHeader: _etag(current),
          HttpHeaders.cacheControlHeader: _noCache,
        },
      );
    }
    final snapshot = await store.snapshot(normalized);
    if (snapshot == null || !_isLive(snapshot.expiresAt)) {
      return Response.ok(
        _emptyPhotos,
        headers: {
          HttpHeaders.contentTypeHeader: _jsonType,
          HttpHeaders.cacheControlHeader: _noCache,
        },
      );
    }
    return Response.ok(
      jsonEncode({
        'count': snapshot.photos.length,
        'photos': [
          for (final photo in snapshot.photos)
            {
              'key': photo.key,
              'state': photo.preview.status.name,
              if (photo.preview case PreviewInfo(
                :final width?,
                :final height?,
              )) ...{
                'w': width,
                'h': height,
              },
            },
        ],
      }),
      headers: {
        HttpHeaders.contentTypeHeader: _jsonType,
        HttpHeaders.cacheControlHeader: _noCache,
        HttpHeaders.etagHeader: _etag(snapshot.generation),
      },
    );
  }

  Response _events(Request request, String code) {
    final normalized = normalizeCode(code);
    if (normalized == null) return _onTheirWay();
    final knownId =
        Doorbell.normalizeId(request.headers[_lastEventIdHeader]) ??
        Doorbell.normalizeId(request.url.queryParameters['since']);
    final stream = doorbell.open(store.dirName(normalized), knownId);
    if (stream == null) return Response(HttpStatus.noContent);
    return Response.ok(
      stream,
      headers: {
        HttpHeaders.contentTypeHeader: _eventStreamType,
        'x-accel-buffering': 'no',
      },
      context: {_bufferOutputKey: false},
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
