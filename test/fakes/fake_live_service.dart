import 'dart:async';

import 'package:shutterlink/data/live_service.dart';

class FakeLiveService implements LiveService {
  final calls = <String>[];
  final statuses = <LiveStatus>[];
  final stopController = StreamController<void>.broadcast();
  bool permitted = true;

  @override
  Future<void> start(LiveStatus status) async {
    calls.add('start');
    statuses.add(status);
  }

  @override
  Future<void> updateStatus(LiveStatus status) async {
    calls.add('update');
    statuses.add(status);
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<bool> requestNotificationPermission() async => permitted;

  @override
  Stream<void> get stopRequests => stopController.stream;
}
