abstract final class CanonEosOperation {
  static const setDevicePropValueEx = 0x9110;
  static const setRemoteMode = 0x9114;
  static const setEventMode = 0x9115;
  static const getEvent = 0x9116;
  static const remoteReleaseOn = 0x9128;
  static const remoteReleaseOff = 0x9129;
  static const getViewFinderData = 0x9153;
  static const doAf = 0x9154;
  static const zoom = 0x9158;
  static const zoomPosition = 0x9159;
  static const setLiveAfFrame = 0x915A;
}

/// RemoteReleaseOn/Off parameters as libgphoto2 sends them; unconfirmed on
/// the EOS R.
abstract final class CanonRemoteRelease {
  static const halfPress = 1;
  static const fullPress = 3;

  /// RemoteReleaseOn p2 that focuses before the release.
  static const withAutofocus = 0;
}

abstract final class CanonEosResponseCode {
  /// GetViewFinderData has no frame ready yet.
  static const deviceNotReady = 0xA102;
}

abstract final class CanonEosEvent {
  static const terminator = 0;
  static const objectAddedEx = 0xC181;
  static const objectRemoved = 0xC182;
  static const storageInfoChanged = 0xC185;
  static const requestObjectTransfer = 0xC186;
  static const objectAddedEx64 = 0xC1A7;
  static const requestObjectTransfer64 = 0xC1A9;
  static const propValueChanged = 0xC189;
  static const availListChanged = 0xC18A;

  /// libgphoto2's CameraStatusChanged; whether the EOS R sends it as a record
  /// type is unconfirmed.
  static const cameraStatusChanged = 0xC18B;
}

/// The value of a CameraStatusChanged record.
abstract final class CanonCameraStatus {
  static const idle = 0;
  static const capturing = 1;
}

abstract final class CanonEosProperty {
  static const aperture = 0xD101;
  static const shutterSpeed = 0xD102;
  static const iso = 0xD103;
  static const exposureCompensation = 0xD104;
  static const aeMode = 0xD105;
  static const driveMode = 0xD106;
  static const afMode = 0xD108;
  static const whiteBalance = 0xD109;

  /// Camera wall-clock time, as seconds since 1970 with the local time written
  /// as if it were UTC. The EOS R reports it in the initial GetEvent dump.
  static const cameraTime = 0xD113;
  static const evfOutputDevice = 0xD1B0;
  static const evfMode = 0xD1B1;
}

const canonPropertyNames = {
  CanonEosProperty.aperture: 'Av',
  CanonEosProperty.shutterSpeed: 'Tv',
  CanonEosProperty.iso: 'ISO',
  CanonEosProperty.exposureCompensation: 'ExpComp',
  CanonEosProperty.aeMode: 'AE mode',
  CanonEosProperty.driveMode: 'Drive',
  CanonEosProperty.afMode: 'AF mode',
  CanonEosProperty.whiteBalance: 'WB',
  CanonEosProperty.cameraTime: 'Camera time',
  CanonEosProperty.evfOutputDevice: 'EVF output',
  CanonEosProperty.evfMode: 'EVF mode',
};

/// Where the camera sends its electronic viewfinder image (0xD1B0).
abstract final class CanonEvfOutput {
  static const tft = 1;
  static const pc = 2;
  static const tftAndPc = 3;
}

abstract final class CanonEvfMode {
  static const on = 1;
}

abstract final class CanonViewFinder {
  /// The GetViewFinderData parameter libgphoto2 sends.
  static const requestParameter = 0x00200000;
  static const jpegRecordType = 1;
}

abstract final class CanonEosMode {
  static const remoteModeOn = 1;
  static const eventModeOn = 1;
}

abstract final class CanonObjectFormat {
  static const cr3 = 0xB108;
  static const mov = 0xB104;
}
