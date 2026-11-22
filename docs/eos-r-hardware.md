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

## Remote control and live view (Phase 2 gate)

USB results come from the probe over libusb on a Linux server
(`fvm dart run bin/probe.dart --usb …`, EOS R firmware 3-1.8.0, RF lens,
indoors, 2026-11-22), not from the Android USB bridge. Channel overhead
there measures the probe's isolate hop, so it says nothing about the
Android MethodChannel. Wi-Fi items are still open.

- **Live view needs a warm-up on a fresh connection.** The first live view
  after plugging the camera in, with EVF output 2, answered 0xA102 to all
  576 GetViewFinderData requests for 30 s. EVF output 3 right after it
  worked, and from then on output 2 worked too.
- **USB fps:** 59.0 and 58.6 fps over 30 s on EVF output 2, 51.7 fps on
  output 3. Frames are about 216 KiB JPEGs at 960x640. Time to first byte
  7 ms mean (p95 14–16 ms), transfer 9–12 ms mean (p95 19–23 ms).
- **10-minute soak, USB (EVF output 3):** 33928 frames, 56.6 fps average,
  52–61 fps in every second, 268 × 0xA102, no 0x2019, no errors and no
  watchdog aborts.
- **Release params 1,3** take a shot. RemoteReleaseOn(1)/(3) and Off(3)/(1)
  each answer 0x2001.
- **0xC18B is a GetEvent record type** (CameraStatusChanged, u32 value). It
  is 1 about 250–480 ms after the release, together with 0xC185, and 0
  when the camera is done. Over USB the camera also sends ObjectAdded
  (0xC1A7) for the new file 1.35–2.6 s after the release, unlike over
  Wi-Fi. A 0xC185 that arrives with 0xC18B = 1 does not mean the file is on
  the card yet.
- **Busy while capturing:** a release while 0xC18B is still 1 answers
  0x2019. Wait for 0xC18B = 0 or the ObjectAdded first.
- **AF failure:** a release can answer 0x2001 and then produce no events
  at all, here 2 of 10 shots in a dim room. Treat no 0xC18B within a few
  seconds as "no capture".
- **Trigger → thumbnail with live view running (EVF output 3, 250 ms
  polling):** 1.6–2.1 s for shots 3–10, 3.7 s for the first shot (a cold
  first diff of 885 ms). The newest-folder diff is 7 transactions in
  47–232 ms once warm.
- **Echo latency (ISO via SetDevicePropValueEx, live view on):** the echo
  follows the poll interval. 250 ms polling: mean 252 ms, max 268 ms, fps
  cost 11.5. 350 ms: 351 / 366 ms, cost 7.1. 500 ms: 503 / 518 ms, cost
  6.5. Without polling, live view ran at 59.0 fps.
- **Zoom (0x9158, level 5)** answers 0x2001, but the frames that follow
  are not magnified. Still open: whether the zoom needs ZoomPosition
  first, another value, or only applies to the camera's screen.
- **SetLiveAfFrame (0x915A)** with `u32 x, u32 y` = 3360, 2240 answers
  0x2001. Whether the AF point moved was not checked on the camera.
- **USB through the Android bridge (Pixel 8, Android 17, profile build):**
  29.9 fps on EVF output 3 and 29.8 fps on output 2 (30 s averages).
  Time to first byte 14 ms mean, transfer 15.6 ms mean, channel overhead
  12.7 ms mean (p95 about 20 ms), about 38 % of the frame time. That counts
  as bridge-bound, but the 15 fps bar is met without a native frame loop;
  one could lift USB towards the 52–59 fps libusb reaches.
- **The warm-up shows on Android too:** the first live view on output 2
  after connecting got 113 × 0xA102 and no frames.
- **Switching EVF output 2 → 3 on Android** made the camera drop off USB
  for about 1 s and re-enumerate; Android asked for USB access again.
  Switching back to 2 ended the session with an error, and the app
  reconnected by itself.
- **The camera drops off USB while streaming to the Pixel 8.** On both
  EVF outputs, live view over the Android bridge made the camera
  re-enumerate by itself ("Removed device", then "USB device attached")
  every 1–2 minutes: 7 times in 9 minutes on output 3, after a
  power-cycle. Each drop ended the session; the app reconnected and
  streamed again. Over libusb on a Linux server the same camera streamed
  10 minutes at 57 fps without a single drop. The phone was the USB power
  source (`power_role=source`), and the EOS R can draw power over USB-C,
  so power is one suspect; the Android bridge's transfer pattern is the
  other. Not yet resolved.
- **After such drops the camera can wedge.** Twice it stayed attached but
  answered nothing, showing Err 70. Every reopen runs the full reset
  sequence (clear halt, Device Reset 0x66, GetDeviceStatus until OK,
  drain); GetDeviceStatus timed out on each try, for over 10 minutes. The
  reset is not the problem: the camera's firmware crashed, and only a
  power-cycle recovers it. After 3 such tries in a row the app says "The
  camera isn't responding. Turn it off and on again." and keeps retrying,
  so it reconnects by itself once the camera is back.
- **Still to measure:** Wi-Fi fps and soak; the camera screen after a dead
  session on EVF output 2; whether the dials and eye sensor work on output
  2 vs 3; a smaller live-view size; RAW+JPEG write order; Tv 30 s; Image
  Review; continuous drive; fps during a download with 256 KiB vs 1 MiB
  chunks; reconnect to first frame; and a clean 10-minute soak through
  the Android bridge, which needs the drops above fixed first.
