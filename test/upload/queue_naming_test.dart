import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/queue_naming.dart';

void main() {
  test('capture day uses the local date', () {
    final local = DateTime(2026, 1, 2, 23, 59);
    expect(captureDayOf(local), '2026-01-02');
    expect(captureDayOf(local.toUtc()), '2026-01-02');
  });

  test('temp names are hidden and never .part', () {
    expect(tempNameFor('IMG_0001.JPG', 'u1'), '.IMG_0001.JPG.tmp-u1');
  });

  test('candidates suffix the stem', () {
    expect(candidateName('IMG_0001.JPG', 0), 'IMG_0001.JPG');
    expect(candidateName('IMG_0001.JPG', 2), 'IMG_0001_2.JPG');
    expect(candidateName('README', 1), 'README_1');
    expect(candidateIndexOf('IMG_0001.JPG', 'IMG_0001_7.JPG'), 7);
    expect(candidateIndexOf('IMG_0001.JPG', 'other.JPG'), -1);
  });

  group('destination fingerprint', () {
    const base = Destination(
      type: DestinationType.s3,
      endpoint: 'https://s3.example.com',
      region: 'eu-central-1',
      bucket: 'photos',
      basePath: 'camera',
      username: 'AKIA',
    );

    test('ignores policy, local copy and path style', () {
      const tweaked = Destination(
        type: DestinationType.s3,
        endpoint: 'https://s3.example.com',
        region: 'eu-central-1',
        bucket: 'photos',
        basePath: 'camera',
        username: 'AKIA',
        pathStyle: true,
        policy: MobileDataPolicy.all,
        keepLocalCopy: false,
      );
      expect(tweaked.fingerprint, base.fingerprint);
      expect(tweaked, isNot(base));
    });

    test('changes with where files land', () {
      const other = Destination(
        type: DestinationType.s3,
        endpoint: 'https://s3.example.com',
        region: 'eu-central-1',
        bucket: 'archive',
        basePath: 'camera',
        username: 'AKIA',
      );
      expect(other.fingerprint, isNot(base.fingerprint));
      expect(base.fingerprint, hasLength(64));
    });
  });
}
