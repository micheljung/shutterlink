# EOS R over PTP/IP: observed hardware behaviour

These notes come from a real Canon EOS R (firmware 3-1.8.0, home Wi-Fi in
infrastructure mode), probed with `bin/probe.dart` on 2026-11-14. Where they
disagree with `test/ptpip/fake_camera.dart`, these notes are correct.

- **Unknown GUID:** the camera sends a TCP RST right after
  InitCommandRequest, with no InitFail. The app maps this to
  `PairingRequiredException`, and the fake camera models it with
  `resetUnknownGuid`.
- **Pairing in infrastructure mode:** go to Wi-Fi function → Remote control
  (EOS Utility) → select the connection → "Start pairing devices" → OK. This
  has to be repeated whenever the camera has left the network.
- **Discovery:** no SSDP replies were seen. That observation isn't conclusive,
  because the capture only filtered for the camera's address.
- **Clock:** 0x5011 DateTime is not supported. Canon property 0xD113, in the
  initial GetEvent dump, holds the camera's wall-clock time, which is the same
  clock as the display and EXIF. It's stored as seconds encoded as if it were
  UTC. `cameraTime()` reads it, and this was confirmed with `probe --clock`.
- **New shots:** shooting to the card produces no ObjectAddedEx (0xC181 or
  0xC1A7), even with SetRemoteMode and SetEventMode set. The camera only sends
  0xC185 StorageInfoChanged and the 0xC18B and 0xD11B property changes.
  Auto Upload and QR Session diff the newest folder every 2 s and at once on
  0xC185 (the `storageChanged` stream).
- **Download speed:** 0.13 MB/s with a weak signal, 3.57 MB/s near the
  router. Speed depends on the signal, not on the app.
- **Reconnect gap:** after any TCP connection to port 15740 closes, the camera
  is unreachable for about 12–15 s. That includes a clean PTP session and a
  bare `nc -z` probe. Don't poll it between runs; wait about 15 s instead.
- **Thumbnail orientation:** GetThumb returns the thumbnail as stored, not
  turned upright. A portrait shot (ES3A7363.JPG, firmware 3-1.8.0, probed
  2026-11-16) came back as a 160x120 landscape JPEG with no EXIF Orientation.
  So `PtpCameraClient.thumbnailsUpright` is false, and the preview and grid
  turn thumbnails by the photo's own orientation (EXIF, or CR3 CMT1).
- **Download stall:** in the same run, a 1 MB GetPartialObject sent nothing
  for 3 s, and the probe gave up with "No PTP response". This has been seen
  once. If it happens again, the 3 s response timeout may be too short over
  Wi-Fi.

## USB

Observed on 2026-11-17 with a Pixel 8, a USB cable plugged into the phone
through a USB-A to USB-C OTG adapter, and the camera's Wi-Fi function
disabled. The phone was watched over wireless `adb` (`dumpsys usb`, `logcat`).

- **Device:** `04a9:32da` "Canon Inc. / Canon Digital Camera", one
  configuration (max power 36 mA), one interface of class 6/1/1 (PTP still
  image) with bulk-in 0x82, bulk-out 0x01 and interrupt-in 0x83 (512/512/64
  bytes). It matches `usb_device_filter.xml`.
- **Physical contact:** the first attempts showed nothing on the phone:
  `dumpsys usb` reported port0 `connected=false`, `no-power`, `no-data` and no
  host connections. After a replug the camera enumerated; one attach dropped
  after about 0.4 s before a later one held. The same cable works with a PC,
  and the adapter works with a card reader, so this was the plug seating, not
  the app.
  "Unplug and push it back in firmly" is the first thing to try.
- **Plugging in with the app closed opens nothing:** three activities match a
  PTP camera (`com.android.gallery3d/.ingest.IngestActivity`,
  `com.android.mtp/.ReceiverActivity` and Shutterlink's `MainActivity`), no
  default was stored for the device, and Android showed no chooser: it logged
  `starting of usb overlay activities` and the launcher kept focus. So the app
  tells users to open Shutterlink first, then plug in.
- **With Shutterlink open:** the app enumerated the already-plugged camera,
  showed the USB permission dialog and, once allowed, reached the mode picker
  with "Connected over USB".
- **Untested:** whether the camera offers USB while its Wi-Fi function is
  enabled.
