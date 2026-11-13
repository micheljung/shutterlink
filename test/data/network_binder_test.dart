import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/network_binder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const gateway = '192.168.1.2';

  late List<MethodCall> calls;
  late PlatformNetworkBinder binder;

  List<String> methods() => [for (final call in calls) call.method];

  setUp(() {
    calls = [];
    binder = PlatformNetworkBinder(isAndroid: true);
    messenger.setMockMethodCallHandler(PlatformNetworkBinder.channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'bindToWifi' ? gateway : null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(PlatformNetworkBinder.channel, null);
    messenger.setMockStreamHandler(PlatformNetworkBinder.events, null);
  });

  test('binds and returns the gateway, holding Wi-Fi on request', () async {
    expect(await binder.acquireBinding('connect'), gateway);
    await binder.acquireBinding('live', holdNetwork: true);

    expect(calls.map((call) => call.arguments), [
      {'hold': false},
      {'hold': true},
    ]);
  });

  test('unbinds only when the last owner releases', () async {
    await binder.acquireBinding('connect');
    await binder.acquireBinding('live');

    await binder.releaseBinding('connect');
    expect(methods(), isNot(contains('unbind')));

    await binder.releaseBinding('live');
    expect(methods().where((method) => method == 'unbind'), hasLength(1));
  });

  test('repeated acquires by one owner need a single release', () async {
    await binder.acquireBinding('live');
    await binder.acquireBinding('live');
    await binder.acquireBinding('live');

    await binder.releaseBinding('live');

    expect(methods(), [...List.filled(3, 'bindToWifi'), 'unbind']);
  });

  test('releasing an owner that holds nothing does not unbind', () async {
    await binder.releaseBinding('live');

    await binder.acquireBinding('connect');
    await binder.releaseBinding('live');

    expect(methods(), ['bindToWifi']);
  });

  test('a transfer keeps the binding for the new owner', () async {
    await binder.acquireBinding('live');

    binder.transferBinding('live', 'connect');
    await binder.releaseBinding('live');
    expect(methods(), ['bindToWifi']);

    await binder.releaseBinding('connect');
    expect(methods(), ['bindToWifi', 'unbind']);
  });

  test('transferring from a non-owner grants nothing', () async {
    binder.transferBinding('live', 'connect');
    await binder.releaseBinding('connect');

    expect(calls, isEmpty);
  });

  test('a failed bind adds no owner', () async {
    messenger.setMockMethodCallHandler(PlatformNetworkBinder.channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'bindToWifi') throw PlatformException(code: 'no_wifi');
      return null;
    });

    await expectLater(
      binder.acquireBinding('connect'),
      throwsA(isA<PlatformException>()),
    );
    await binder.releaseBinding('connect');

    expect(methods(), ['bindToWifi']);
  });

  test('reports a lost held Wi-Fi', () async {
    messenger.setMockStreamHandler(
      PlatformNetworkBinder.events,
      MockStreamHandler.inline(onListen: (_, events) => events.success('lost')),
    );

    await expectLater(binder.bindingLost.first, completes);
  });

  test('tracks owners without native calls off Android', () async {
    final other = PlatformNetworkBinder(isAndroid: false);

    expect(await other.acquireBinding('connect'), isNull);
    await other.releaseBinding('connect');
    await other.acquireMulticastLock();

    expect(calls, isEmpty);
  });
}
