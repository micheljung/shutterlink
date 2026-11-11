import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:eos_transfer/ptpip/ptpip.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_camera.dart';

typedef RequestHandler = void Function(Socket socket, CommandRequest request);

Future<(ServerSocket, PtpIpConnection)> scriptedCamera(
  RequestHandler handler,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.transform(const PtpIpPacketReader()).listen((packet) {
      switch (packet) {
        case InitCommandRequest():
          socket.add(
            InitCommandAck(
              connectionNumber: 1,
              guid: fakeCameraGuid,
              name: 'scripted',
            ).encode(),
          );
        case InitEventRequest():
          socket.add(const InitEventAck().encode());
        case CommandRequest():
          handler(socket, packet);
        default:
      }
    });
  });
  final connection = await PtpIpConnection.open(
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    identity: pairedIdentity,
  );
  return (server, connection);
}

void main() {
  group('against the fake camera', () {
    late FakeCamera camera;
    late PtpIpConnection connection;
    late PtpSession session;

    Future<void> start(FakeCamera fake) async {
      camera = fake;
      await camera.start();
      connection = await PtpIpConnection.open(
        host: InternetAddress.loopbackIPv4.address,
        port: camera.port,
        identity: pairedIdentity,
      );
      session = PtpSession(connection, responseTimeout: testResponseTimeout);
    }

    tearDown(() async {
      connection.close();
      await camera.stop();
    });

    test('OpenSession uses transaction 0, then ids count from 1', () async {
      await start(FakeCamera());
      await session.openSession();
      await session.execute(PtpOperation.getStorageIds);
      await session.execute(PtpOperation.getStorageIds);
      expect(camera.receivedRequests.map((r) => r.transactionId), [0, 1, 2]);
      expect(camera.receivedRequests.first.params, [PtpHandle.sessionId]);
    });

    test('an already open session is accepted', () async {
      await start(
        FakeCamera(openSessionCode: PtpResponseCode.sessionAlreadyOpen),
      );
      await session.openSession();
    });

    test('non-OK response throws PtpResponseException', () async {
      await start(FakeCamera());
      await expectLater(
        session.execute(PtpOperation.getThumb, params: [0xDEAD]),
        throwsA(
          isA<PtpResponseException>()
              .having((e) => e.operation, 'operation', PtpOperation.getThumb)
              .having(
                (e) => e.responseCode,
                'code',
                PtpResponseCode.noThumbnailPresent,
              ),
        ),
      );
      final ok = await session.execute(
        PtpOperation.getThumb,
        params: [0xDEAD],
        acceptedCodes: const {PtpResponseCode.noThumbnailPresent},
      );
      expect(ok.data, isEmpty);
    });

    test('reassembles a data phase split over many packets', () async {
      await start(FakeCamera(dataPacketSize: 7, maxFragmentSize: 5));
      final result = await session.execute(
        PtpOperation.getPartialObject,
        params: [FakeCamera.jpegHandle, 0, FakeCamera.jpegSize],
      );
      final expected = camera.objects
          .firstWhere((o) => o.handle == FakeCamera.jpegHandle)
          .content;
      expect(result.data, expected);
      expect(result.code, PtpResponseCode.ok);
      expect(result.params, isEmpty);
    });

    test('concurrent calls are strictly serialized', () async {
      await start(FakeCamera(responseDelay: const Duration(milliseconds: 20)));
      final results = await Future.wait([
        for (var i = 0; i < 5; i++) session.execute(PtpOperation.getStorageIds),
      ]);
      expect(results, hasLength(5));
      expect(camera.maxConcurrentRequests, 1);
    });

    test('a failing call does not block the queue', () async {
      await start(FakeCamera());
      final failing = session.execute(0x9999);
      final next = session.execute(PtpOperation.getStorageIds);
      await expectLater(failing, throwsA(isA<PtpResponseException>()));
      expect((await next).code, PtpResponseCode.ok);
    });

    test('low-priority calls run after normal ones, newest first', () async {
      await start(FakeCamera(responseDelay: const Duration(milliseconds: 10)));
      final first = session.execute(PtpOperation.getStorageIds);
      final thumbs = [
        for (var handle = 1; handle <= 3; handle++)
          session.executeLowPriority(
            PtpOperation.getThumb,
            params: [handle],
            acceptedCodes: const {PtpResponseCode.noThumbnailPresent},
          ),
      ];
      final normal = session.execute(PtpOperation.getStorageIds);
      await Future.wait([first, normal, ...thumbs]);
      expect(camera.receivedRequests.map((r) => r.opcode), [
        PtpOperation.getStorageIds,
        PtpOperation.getStorageIds,
        PtpOperation.getThumb,
        PtpOperation.getThumb,
        PtpOperation.getThumb,
      ]);
      expect(camera.receivedRequests.skip(2).map((r) => r.params.single), [
        3,
        2,
        1,
      ]);
    });

    test('cancelled low-priority calls are dropped unsent', () async {
      await start(FakeCamera(responseDelay: const Duration(milliseconds: 10)));
      final busy = session.execute(PtpOperation.getStorageIds);
      final token = CancelToken();
      final dropped = session.executeLowPriority(
        PtpOperation.getThumb,
        params: [FakeCamera.jpegHandle],
        cancelToken: token,
      );
      token.cancel();
      final cancelled = expectLater(
        dropped,
        throwsA(isA<TransferCancelledException>()),
      );
      await busy;
      await cancelled;
      expect(camera.receivedOpcodes, isNot(contains(PtpOperation.getThumb)));
    });

    test('a hold defers low-priority calls until released', () async {
      await start(FakeCamera());
      final release = session.holdLowPriority();
      var thumbDone = false;
      final thumb = session
          .executeLowPriority(
            PtpOperation.getThumb,
            params: [FakeCamera.jpegHandle],
          )
          .then((result) => thumbDone = true);
      await session.execute(PtpOperation.getStorageIds);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(thumbDone, isFalse);
      release();
      release();
      await thumb;
      expect(thumbDone, isTrue);
    });

    test('bytes trickling in keep a slow data packet alive', () async {
      await start(
        FakeCamera(
          dataPacketSize: PtpIpCameraClient.downloadChunkSize,
          maxFragmentSize: 64 * 1024,
          trickleDelay: const Duration(milliseconds: 40),
        ),
      );
      final stopwatch = Stopwatch()..start();
      final result = await session.execute(
        PtpOperation.getPartialObject,
        params: [
          FakeCamera.largeJpegHandle,
          0,
          PtpIpCameraClient.downloadChunkSize,
        ],
      );
      expect(stopwatch.elapsed, greaterThan(testResponseTimeout));
      expect(result.data, hasLength(PtpIpCameraClient.downloadChunkSize));
      expect(connection.isConnected, isTrue);
    });

    test('a silent camera fails in-flight and queued calls', () async {
      await start(FakeCamera());
      camera.silent = true;
      final stopwatch = Stopwatch()..start();
      final first = session.execute(PtpOperation.getStorageIds);
      final second = session.execute(PtpOperation.getStorageIds);
      await expectLater(first, throwsA(isA<CameraDisconnectedException>()));
      await expectLater(second, throwsA(isA<CameraDisconnectedException>()));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(connection.disconnectCause, isA<TimeoutException>());
      await session.disconnected;
    });
  });

  group('against a scripted camera', () {
    late ServerSocket server;
    late PtpIpConnection connection;

    tearDown(() async {
      connection.close();
      await server.close();
    });

    Future<PtpSession> start(RequestHandler handler) async {
      (server, connection) = await scriptedCamera(handler);
      return PtpSession(connection, responseTimeout: testResponseTimeout);
    }

    test('ignores packets of other transactions', () async {
      final session = await start((socket, request) {
        final txid = request.transactionId;
        socket
          ..add(
            CommandResponse(
              code: PtpResponseCode.generalError,
              transactionId: txid + 100,
            ).encode(),
          )
          ..add(const PingPacket().encode())
          ..add(StartData(transactionId: txid, totalLength: 2).encode())
          ..add(
            DataPacket(
              transactionId: txid,
              payload: Uint8List.fromList([1]),
            ).encode(),
          )
          ..add(
            EndDataPacket(
              transactionId: txid,
              payload: Uint8List.fromList([2]),
            ).encode(),
          )
          ..add(
            CommandResponse(
              code: PtpResponseCode.ok,
              transactionId: txid,
              params: const [5],
            ).encode(),
          );
      });
      final result = await session.execute(PtpOperation.getDeviceInfo);
      expect(result.data, [1, 2]);
      expect(result.params, [5]);
    });

    test('too much data aborts the connection', () async {
      final session = await start((socket, request) {
        final txid = request.transactionId;
        socket
          ..add(StartData(transactionId: txid, totalLength: 1).encode())
          ..add(
            EndDataPacket(
              transactionId: txid,
              payload: Uint8List.fromList([1, 2]),
            ).encode(),
          );
      });
      await expectLater(
        session.execute(PtpOperation.getDeviceInfo),
        throwsA(isA<CameraDisconnectedException>()),
      );
      expect(connection.disconnectCause, isA<PtpIpProtocolException>());
    });

    test('an oversized data phase aborts the connection', () async {
      final session = await start((socket, request) {
        socket.add(
          StartData(
            transactionId: request.transactionId,
            totalLength: ptpMaxDataInLength + 1,
          ).encode(),
        );
      });
      await expectLater(
        session.execute(PtpOperation.getDeviceInfo),
        throwsA(isA<CameraDisconnectedException>()),
      );
    });

    test('calls after disconnect fail immediately', () async {
      final session = await start((_, _) {});
      connection.close();
      await expectLater(
        session.execute(PtpOperation.getDeviceInfo),
        throwsA(isA<CameraDisconnectedException>()),
      );
    });
  });
}
