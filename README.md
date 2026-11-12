# Shutterlink

Download JPEG and CR3 photos from a Canon EOS R to an Android or iOS phone
over the camera's own Wi-Fi. The camera speaks PTP/IP (TCP port 15740),
implemented in pure Dart under `lib/ptpip/`.

## Camera setup

1. On the camera: MENU → Wireless communication settings → Wi-Fi function.
2. Remote control (EOS Utility) → Add a device.
3. Camera access point mode → Easy connection.
4. Join the camera's Wi-Fi network on the phone (or laptop for the probe).
5. Connect from the app. The first time, confirm the device name on the
   camera to pair it. Pairing is tied to a GUID the app generates once.

## Probe

`bin/probe.dart` exercises the protocol from a laptop joined to the camera's
access point, without the app:

```bash
fvm dart run bin/probe.dart --host <camera-ip> --dump packets.txt
```

It pairs, prints the device info and photo count, fetches one thumbnail,
downloads the newest photo (or `--index n`) and reports the transfer rate.
The camera IP is usually the Wi-Fi gateway address. The GUID is stored in
`~/.shutterlink_guid` (`--guid-file`). Exit code 77 means the camera
rejected the GUID and needs pairing.

## App

- Thumbnail grid of the card, newest first. A RAW+JPEG pair is one tile.
- Select photos and download them. Settings choose JPEG, RAW or both and
  can override the camera address.
- JPEG goes to the gallery. CR3 goes to `Download/EOS R` on Android and into
  Photos as RAW on iOS (Files app as fallback).
- Interrupted downloads resume from where they stopped after reconnecting.

On Android the app binds itself to the camera's Wi-Fi so traffic doesn't
leave over mobile data.

## Development

```bash
fvm flutter test
fvm flutter analyze
fvm flutter build apk --debug
```

`test/ptpip/fake_camera.dart` is an in-process PTP/IP camera used by the
tests.
