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
  Auto Upload and Live Share diff the newest folder every 2 s and at once on
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
