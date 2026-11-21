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

## Remote control and live view (Phase 2 gate, to be measured)

The probe (`fvm dart run bin/probe.dart --host <ip> …`) runs over Wi-Fi
only. The debug screen is the speed icon on the mode picker in debug and
profile builds; its Copy button copies the stats text. Fill in each item
from those runs.

- **Wi-Fi fps at close range:** not measured yet. 30 s average from a
  profile build: the debug screen's "30 s avg" over Wi-Fi, or
  `--liveview=30`.
- **USB fps:** not measured yet. 30 s average from a profile build: the
  debug screen's "30 s avg" over USB. Record the Overhead line's share of
  the frame time too. USB counts as bridge-bound if the overhead is at least
  25 % of the frame time and removing it would lift USB from below 15 to at
  least 15 fps. The fallback bar is 10 fps.
- **10-minute soak, Wi-Fi:** not measured yet. fps, watchdog aborts and the
  0xA102 and 0x2019 counts: the debug screen after 10 min, or
  `--liveview=600`.
- **10-minute soak, USB:** not measured yet. fps, watchdog aborts and the
  0xA102 and Busy counts from the debug screen after 10 min.
- **Camera screen after a dead session with 0xD1B0 = PC:** not measured
  yet. Run the debug screen on EVF 2, then cut the connection (Wi-Fi off or
  cable out) and watch whether the camera's screen comes back.
- **EVF output 2 vs 3:** not measured yet. Whether the dials and the eye
  sensor still work on each: the debug screen's EVF 2 / EVF 3 switch, or
  `--liveview=<s> --evf-output=<2|3>`.
- **Smaller live-view size:** not measured yet. No probe mode or screen
  sets one; `--props` lists the properties the camera reports, and `--set`
  can try one.
- **Release params:** not measured yet. Which `--release-params=<half,full>`
  take a shot; the default is 1,3.
- **0xC18B:** not measured yet. Whether it is a GetEvent record type, and
  when it arrives relative to the release and 0xC185: the `0xc18b` and
  `0xc185` columns of `--release`.
- **RAW+JPEG write order:** not measured yet. The order of the new handles
  in `--release` with the camera on RAW+JPEG.
- **Tv 30 s:** not measured yet. `--release --release-timeout=<s>` with the
  shutter at 30 s.
- **AF failure:** not measured yet. `--release` with the lens unable to
  focus (lens cap on, AF on).
- **Image Review setting:** not measured yet. `--release` with Image Review
  off and on.
- **Continuous drive:** not measured yet. What a single On(3)/Off(3) does
  in continuous drive: `--release` with the drive mode on continuous.
- **Trigger → thumbnail with live view running:** not measured yet. The
  Thumb, Cold diff and Warm diff columns of `--release` (live view runs
  unless it is refused). Whether frames resume right after the capture:
  the debug screen's FPS line during a shutter press.
- **Echo latency:** not measured yet. At 250, 350 and 500 ms polling, and
  the fps cost of each: `--set=<prop=value>` prints both.
- **fps during a download:** not measured yet. With 256 KiB and with 1 MiB
  chunks, and the download MB/s for each. Neither the probe nor the debug
  screen runs a download with a chosen chunk size yet.
- **Reconnect to first frame:** not measured yet. The debug screen keeps
  its stats across a reconnect; time from the camera coming back to the FPS
  line rising again.
