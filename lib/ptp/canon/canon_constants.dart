abstract final class CanonEosOperation {
  static const setRemoteMode = 0x9114;
  static const setEventMode = 0x9115;
  static const getEvent = 0x9116;
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
}

abstract final class CanonEosProperty {
  /// Camera wall-clock time, as seconds since 1970 with the local time written
  /// as if it were UTC. The EOS R reports it in the initial GetEvent dump.
  static const cameraTime = 0xD113;
}

abstract final class CanonEosMode {
  static const remoteModeOn = 1;
  static const eventModeOn = 1;
}

abstract final class CanonObjectFormat {
  static const cr3 = 0xB108;
  static const mov = 0xB104;
}
