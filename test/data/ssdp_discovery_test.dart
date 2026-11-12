import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/ssdp_discovery.dart';

const _testTimeout = Duration(milliseconds: 300);
const _smartPhoneTarget =
    'urn:schemas-canon-com:service:ICPO-SmartPhoneEOSSystemService:1';
const _wftTarget = 'urn:schemas-canon-com:service:ICPO-WFTEOSSystemService:1';
const _secondLoopbackHost = '127.0.0.2';

class FakeSsdpDevice {
  FakeSsdpDevice._(this._server, this.target);

  static Future<FakeSsdpDevice> start({
    String host = '127.0.0.1',
    String target = _smartPhoneTarget,
    String? description,
    String name = 'EOS R',
  }) async {
    final server = await HttpServer.bind(host, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('text', 'xml')
        ..write(
          description ??
              '<?xml version="1.0"?><root><device>'
                  '<friendlyName>$name</friendlyName>'
                  '</device></root>',
        );
      unawaited(request.response.close());
    });
    return FakeSsdpDevice._(server, target);
  }

  final HttpServer _server;
  final String target;

  String get location =>
      'http://${_server.address.address}:${_server.port}/desc.xml';

  String searchReply() =>
      'HTTP/1.1 200 OK\r\n'
      'CACHE-CONTROL: max-age=1800\r\n'
      'LOCATION: $location\r\n'
      'ST: $target\r\n'
      'USN: uuid:camera::$target\r\n'
      '\r\n';

  String notify({String nts = 'ssdp:alive'}) =>
      'NOTIFY * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'LOCATION: $location\r\n'
      'NT: $target\r\n'
      'NTS: $nts\r\n'
      '\r\n';

  Future<void> close() => _server.close(force: true);
}

class FakeSsdpResponder {
  FakeSsdpResponder._(this._socket, this.replies, this.replyDelay) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _socket.receive();
      if (datagram == null) return;
      final message = utf8.decode(datagram.data);
      if (!message.startsWith('M-SEARCH')) return;
      final target = RegExp(
        r'^ST: (.*)$',
        multiLine: true,
      ).firstMatch(message)!.group(1)!.trim();
      searchedTargets.add(target);
      final reply = replies(target).toList();
      _pendingReplies.add(
        Timer(replyDelay, () {
          for (final message in reply) {
            _socket.send(utf8.encode(message), datagram.address, datagram.port);
          }
        }),
      );
    });
  }

  static Future<FakeSsdpResponder> start({
    Iterable<String> Function(String target)? replies,
    Duration replyDelay = Duration.zero,
  }) async => FakeSsdpResponder._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    replies ?? (_) => const [],
    replyDelay,
  );

  final RawDatagramSocket _socket;
  final Iterable<String> Function(String target) replies;
  final Duration replyDelay;
  final searchedTargets = <String>[];
  final _pendingReplies = <Timer>[];

  int get port => _socket.port;

  void send(String message, int port) =>
      _socket.send(utf8.encode(message), InternetAddress.loopbackIPv4, port);

  void close() {
    for (final timer in _pendingReplies) {
      timer.cancel();
    }
    _socket.close();
  }
}

Future<int> _freePort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final port = socket.port;
  socket.close();
  return port;
}

void main() {
  final devices = <FakeSsdpDevice>[];
  late FakeSsdpResponder responder;
  late int listenPort;

  setUp(() async => listenPort = await _freePort());

  tearDown(() async {
    responder.close();
    for (final device in devices) {
      await device.close();
    }
    devices.clear();
  });

  Future<FakeSsdpDevice> device({
    String host = '127.0.0.1',
    String target = _smartPhoneTarget,
    String? description,
    String name = 'EOS R',
  }) async {
    final started = await FakeSsdpDevice.start(
      host: host,
      target: target,
      description: description,
      name: name,
    );
    devices.add(started);
    return started;
  }

  Future<void> respond(
    Iterable<String> Function(String target) replies, {
    Duration replyDelay = Duration.zero,
  }) async => responder = await FakeSsdpResponder.start(
    replies: replies,
    replyDelay: replyDelay,
  );

  Future<List<DiscoveredCamera>> discover() => SsdpDiscovery(
    group: InternetAddress.loopbackIPv4.address,
    searchPort: responder.port,
    listenPort: listenPort,
  ).discover(timeout: _testTimeout);

  for (final target in canonSearchTargets) {
    test('finds a camera answering M-SEARCH for $target', () async {
      final camera = await device(target: target);
      await respond(
        (searched) => [if (searched == target) camera.searchReply()],
      );

      final cameras = await discover();

      expect(cameras, [
        const DiscoveredCamera(host: '127.0.0.1', name: 'EOS R'),
      ]);
      expect(
        responder.searchedTargets,
        unorderedEquals([
          for (var repeat = 0; repeat < ssdpSearchRepeats; repeat++)
            ...canonSearchTargets,
        ]),
      );
    });
  }

  test('repeats each M-SEARCH and reports a camera once', () async {
    final camera = await device();
    await respond(
      (target) => [if (target == _smartPhoneTarget) camera.searchReply()],
    );

    final cameras = await discover();

    for (final target in canonSearchTargets) {
      expect(
        responder.searchedTargets.where((searched) => searched == target),
        hasLength(ssdpSearchRepeats),
      );
    }
    expect(cameras, [const DiscoveredCamera(host: '127.0.0.1', name: 'EOS R')]);
  });

  test('finds a camera that only hears a repeated M-SEARCH', () async {
    final camera = await device();
    var searches = 0;
    await respond(
      (target) => [
        if (target == _smartPhoneTarget && ++searches == ssdpSearchRepeats)
          camera.searchReply(),
      ],
    );

    expect(await discover(), [
      const DiscoveredCamera(host: '127.0.0.1', name: 'EOS R'),
    ]);
  });

  test('finds a camera announcing itself with NOTIFY', () async {
    final camera = await device(target: _wftTarget, name: 'EOS R5');
    await respond((_) => const []);

    final discovery = discover();
    await Future<void>.delayed(_testTimeout ~/ 3);
    responder.send(camera.notify(), listenPort);

    expect(await discovery, [
      const DiscoveredCamera(host: '127.0.0.1', name: 'EOS R5'),
    ]);
  });

  test('returns nothing when no camera answers', () async {
    await respond((_) => const []);

    expect(await discover(), isEmpty);
  });

  test('returns several cameras once per host', () async {
    final first = await device(name: 'EOS R');
    final second = await device(host: _secondLoopbackHost, name: 'EOS R6');
    await respond(
      (target) => [
        if (target == _smartPhoneTarget) ...[
          first.searchReply(),
          first.searchReply(),
          second.searchReply(),
        ],
      ],
    );

    expect(
      await discover(),
      unorderedEquals([
        const DiscoveredCamera(host: '127.0.0.1', name: 'EOS R'),
        const DiscoveredCamera(host: _secondLoopbackHost, name: 'EOS R6'),
      ]),
    );
  });

  test('ignores malformed and foreign messages', () async {
    final camera = await device();
    final foreign = camera.searchReply().replaceAll(
      _smartPhoneTarget,
      'urn:schemas-upnp-org:device:MediaRenderer:1',
    );
    final withoutLocation = camera.searchReply().replaceFirst(
      RegExp('LOCATION: .*\r\n'),
      '',
    );
    final notFound = camera.searchReply().replaceFirst(
      '200 OK',
      '404 Not Found',
    );
    await respond(
      (target) => [
        if (target == _smartPhoneTarget) ...[
          'garbage',
          '',
          foreign,
          withoutLocation,
          notFound,
        ],
      ],
    );

    final discovery = discover();
    await Future<void>.delayed(_testTimeout ~/ 3);
    responder.send(camera.notify(nts: 'ssdp:byebye'), listenPort);

    expect(await discovery, isEmpty);
  });

  test('names a camera by its host when the description has no name', () async {
    final camera = await device(description: '<root>not a device</root>');
    await respond((_) => [camera.searchReply()]);

    expect(await discover(), [
      const DiscoveredCamera(host: '127.0.0.1', name: '127.0.0.1'),
    ]);
  });

  test('ignores replies arriving after the timeout', () async {
    final camera = await device();
    await respond((_) => [camera.searchReply()], replyDelay: _testTimeout * 2);

    expect(await discover(), isEmpty);
  });

  test('searches with M-SEARCH only when the listener port is busy', () async {
    final camera = await device();
    final notifier = await device(host: _secondLoopbackHost, name: 'EOS R6');
    final blocker = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      listenPort,
      reuseAddress: false,
    );
    addTearDown(blocker.close);
    await respond(
      (target) => [if (target == _smartPhoneTarget) camera.searchReply()],
    );

    final discovery = discover();
    await Future<void>.delayed(_testTimeout ~/ 3);
    responder.send(notifier.notify(), listenPort);

    expect(await discovery, [
      const DiscoveredCamera(host: '127.0.0.1', name: 'EOS R'),
    ]);
  });
}
