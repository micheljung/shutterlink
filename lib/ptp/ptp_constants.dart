abstract final class PtpOperation {
  static const getDeviceInfo = 0x1001;
  static const openSession = 0x1002;
  static const closeSession = 0x1003;
  static const getStorageIds = 0x1004;
  static const getObjectHandles = 0x1007;
  static const getObjectInfo = 0x1008;
  static const getThumb = 0x100A;
  static const deleteObject = 0x100B;
  static const getDevicePropValue = 0x1015;
  static const setDevicePropValue = 0x1016;
  static const getPartialObject = 0x101B;
}

abstract final class PtpDeviceProperty {
  static const dateTime = 0x5011;
}

abstract final class PtpResponseCode {
  static const ok = 0x2001;
  static const generalError = 0x2002;
  static const operationNotSupported = 0x2005;
  static const invalidObjectHandle = 0x2009;
  static const devicePropNotSupported = 0x200A;
  static const objectWriteProtected = 0x200D;
  static const storeReadOnly = 0x200E;
  static const accessDenied = 0x200F;
  static const noThumbnailPresent = 0x2010;
  static const deviceBusy = 0x2019;
  static const sessionAlreadyOpen = 0x201E;
}

abstract final class PtpObjectFormat {
  static const association = 0x3001;
  static const exifJpeg = 0x3801;
  static const jfif = 0x3808;
}

abstract final class PtpHandle {
  static const sessionId = 1;
  static const anyFormat = 0;
  static const root = 0xFFFFFFFF;
}
