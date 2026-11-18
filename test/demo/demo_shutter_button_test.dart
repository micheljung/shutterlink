import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/demo/demo_camera_client.dart';
import 'package:shutterlink/demo/demo_shutter_button.dart';
import 'package:shutterlink/demo/phone_camera.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';

import '../fakes/fake_camera_client.dart';

class _MockConnectCubit extends MockCubit<ConnectState>
    implements ConnectCubit {}

class _MockDemoCameraClient extends Mock implements DemoCameraClient {}

class _FakePhoneCamera implements PhoneCamera {
  _FakePhoneCamera(this.shoot);

  final Future<File?> Function() shoot;
  int taken = 0;

  @override
  Future<File?> takePhoto() {
    taken++;
    return shoot();
  }
}

void main() {
  final shot = File('/phone/IMG_0001.jpg');
  late _MockConnectCubit connect;
  late _MockDemoCameraClient demo;
  late int shots;

  setUpAll(() => registerFallbackValue(File('')));

  setUp(() {
    connect = _MockConnectCubit();
    demo = _MockDemoCameraClient();
    when(() => demo.addShot(any())).thenAnswer((_) async {});
    shots = 0;
  });

  Future<_FakePhoneCamera> pump(
    WidgetTester tester,
    ConnectState state, {
    Future<File?> Function()? shoot,
  }) async {
    when(() => connect.state).thenReturn(state);
    final camera = _FakePhoneCamera(shoot ?? () async => shot);
    await tester.pumpWidget(
      RepositoryProvider<PhoneCamera>.value(
        value: camera,
        child: BlocProvider<ConnectCubit>.value(
          value: connect,
          child: MaterialApp(
            home: Scaffold(
              floatingActionButton: DemoShutterButton(
                client: switch (state) {
                  ConnectConnected(:final client) => client,
                  _ => null,
                },
                onShot: () => shots++,
              ),
            ),
          ),
        ),
      ),
    );
    return camera;
  }

  Future<void> tapShutter(WidgetTester tester) async {
    await tester.tap(find.text(DemoShutterButton.label));
    await tester.pump();
  }

  testWidgets('puts a shot from the phone on the card', (tester) async {
    await pump(tester, ConnectConnected(demo, target: const DemoTarget()));

    await tapShutter(tester);

    verify(() => demo.addShot(shot)).called(1);
    expect(shots, 1);
  });

  testWidgets('shows only for the demo camera', (tester) async {
    await pump(tester, ConnectConnected(FakeCameraClient([])));
    expect(find.text(DemoShutterButton.label), findsNothing);

    await pump(tester, const ConnectIdle());
    expect(find.text(DemoShutterButton.label), findsNothing);
  });

  testWidgets('backing out of the camera changes nothing', (tester) async {
    await pump(
      tester,
      ConnectConnected(demo, target: const DemoTarget()),
      shoot: () async => null,
    );

    await tapShutter(tester);

    verifyNever(() => demo.addShot(any()));
    expect(shots, 0);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('says when the camera fails', (tester) async {
    await pump(
      tester,
      ConnectConnected(demo, target: const DemoTarget()),
      shoot: () async => throw PlatformException(code: 'no_available_camera'),
    );

    await tapShutter(tester);

    expect(find.text(DemoShutterButton.failedText), findsOneWidget);
    expect(shots, 0);
  });

  testWidgets('opens one camera at a time', (tester) async {
    final taking = Completer<File?>();
    final camera = await pump(
      tester,
      ConnectConnected(demo, target: const DemoTarget()),
      shoot: () => taking.future,
    );

    await tapShutter(tester);
    await tapShutter(tester);
    taking.complete(shot);
    await tester.pump();

    expect(camera.taken, 1);
    verify(() => demo.addShot(shot)).called(1);
  });
}
