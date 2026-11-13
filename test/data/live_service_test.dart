import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/live_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = PlatformLiveService.channel;

  late List<MethodCall> calls;
  late Object? permissionResult;

  setUp(() {
    calls = [];
    permissionResult = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'requestNotificationPermission'
          ? permissionResult
          : null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  Future<void> sendFromNative(String method) async {
    final reply = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method)),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  test('sends the exact status payload on start and update', () async {
    final service = PlatformLiveService(isAndroid: true);

    await service.start(
      const LiveStatus(
        count: 0,
        uploaded: 0,
        pending: 0,
        state: LiveServiceState.connecting,
        text: 'Connecting to the camera',
      ),
    );
    await service.updateStatus(
      const LiveStatus(
        count: 3,
        uploaded: 1,
        pending: 2,
        state: LiveServiceState.transferring,
        text: 'Uploading',
      ),
    );
    await service.updateStatus(
      const LiveStatus(
        count: 3,
        uploaded: 1,
        pending: 2,
        state: LiveServiceState.reconnecting,
        text: 'Reconnecting',
      ),
    );

    expect(calls.map((call) => call.method), [
      'start',
      'updateStatus',
      'updateStatus',
    ]);
    expect(calls.map((call) => call.arguments), [
      {
        'count': 0,
        'uploaded': 0,
        'pending': 0,
        'state': 'connecting',
        'text': 'Connecting to the camera',
      },
      {
        'count': 3,
        'uploaded': 1,
        'pending': 2,
        'state': 'transferring',
        'text': 'Uploading',
      },
      {
        'count': 3,
        'uploaded': 1,
        'pending': 2,
        'state': 'reconnecting',
        'text': 'Reconnecting',
      },
    ]);
  });

  test('stops the service', () async {
    await PlatformLiveService(isAndroid: true).stop();

    expect(calls.single.method, 'stop');
  });

  test('reports the notification Stop action', () async {
    final service = PlatformLiveService(isAndroid: true);
    final stopped = service.stopRequests.first;

    await sendFromNative(PlatformLiveService.stopRequestedMethod);

    await expectLater(stopped, completes);
  });

  test('passes on the notification permission answer', () async {
    final service = PlatformLiveService(isAndroid: true);

    expect(await service.requestNotificationPermission(), isTrue);
    permissionResult = false;
    expect(await service.requestNotificationPermission(), isFalse);
    permissionResult = null;
    expect(await service.requestNotificationPermission(), isFalse);
  });

  test('does nothing off Android', () async {
    final service = PlatformLiveService(isAndroid: false);

    await service.start(
      const LiveStatus(
        count: 0,
        uploaded: 0,
        pending: 0,
        state: LiveServiceState.connecting,
        text: '',
      ),
    );
    await service.stop();

    expect(await service.requestNotificationPermission(), isTrue);
    expect(calls, isEmpty);
  });
}
