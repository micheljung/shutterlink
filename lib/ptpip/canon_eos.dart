abstract final class PtpOperation {
  static const getDeviceInfo = 0x1001;
  static const openSession = 0x1002;
  static const closeSession = 0x1003;
  static const getStorageIds = 0x1004;
  static const getObjectHandles = 0x1007;
  static const getObjectInfo = 0x1008;
  static const getThumb = 0x100A;
  static const getPartialObject = 0x101B;
}

abstract final class CanonEosOperation {
  static const setRemoteMode = 0x9114;
  static const setEventMode = 0x9115;
  static const getEvent = 0x9116;
}

abstract final class CanonEosEvent {
  static const terminator = 0;
  static const objectAddedEx = 0xC181;
  static const requestObjectTransfer = 0xC186;
  static const objectAddedEx64 = 0xC1A7;
  static const requestObjectTransfer64 = 0xC1A9;
}

abstract final class CanonEosMode {
  static const remoteModeOn = 1;
  static const eventModeOn = 1;
}

abstract final class PtpResponseCode {
  static const ok = 0x2001;
  static const generalError = 0x2002;
  static const operationNotSupported = 0x2005;
  static const invalidObjectHandle = 0x2009;
  static const noThumbnailPresent = 0x2010;
  static const deviceBusy = 0x2019;
  static const sessionAlreadyOpen = 0x201E;
}

abstract final class PtpObjectFormat {
  static const association = 0x3001;
  static const exifJpeg = 0x3801;
  static const jfif = 0x3808;
  static const canonCr3 = 0xB108;
  static const canonMov = 0xB104;
}

abstract final class PtpHandle {
  static const sessionId = 1;
  static const anyFormat = 0;
  static const root = 0xFFFFFFFF;
}
