import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/live_service.dart';
import 'package:shutterlink/data/live_service_leases.dart';

import '../fakes/fake_live_service.dart';

LiveStatus _status(String text) => LiveStatus(
  title: text,
  count: 0,
  uploaded: 0,
  pending: 0,
  state: LiveServiceState.transferring,
  text: text,
);

void main() {
  late FakeLiveService service;
  late LiveServiceLeases leases;

  setUp(() {
    service = FakeLiveService();
    leases = LiveServiceLeases(service);
  });

  test('the service runs until the last holder stops', () async {
    final upload = leases.lease();
    final timelapse = leases.lease();
    await timelapse.start(_status('timelapse'));
    await upload.start(_status('upload'));
    await timelapse.stop();
    expect(service.calls, ['start', 'update']);
    expect(service.statuses.last.text, 'upload');
    await upload.stop();
    expect(service.calls.last, 'stop');
  });

  test('the notification falls back to the holder still running', () async {
    final upload = leases.lease();
    final timelapse = leases.lease();
    await upload.start(_status('upload'));
    await timelapse.start(_status('timelapse'));
    await timelapse.stop();
    expect(service.statuses.last.text, 'upload');
  });

  test('Stop goes only to the holder the notification shows', () async {
    final upload = leases.lease();
    final timelapse = leases.lease();
    var uploadStops = 0;
    var timelapseStops = 0;
    upload.stopRequests.listen((_) => uploadStops++);
    timelapse.stopRequests.listen((_) => timelapseStops++);
    await timelapse.start(_status('timelapse'));
    await upload.start(_status('upload'));
    service.stopController.add(null);
    await pumpEventQueue();
    expect((uploadStops, timelapseStops), (1, 0));
  });

  test('a holder that never started cannot stop the others', () async {
    final upload = leases.lease();
    final timelapse = leases.lease();
    await timelapse.start(_status('timelapse'));
    await upload.stop();
    await upload.updateStatus(_status('upload'));
    expect(service.calls, ['start']);
  });
}
