# Bluetooth remote (intervalometer)

The intervalometer fires the camera as its Bluetooth remote, the role
Canon's BR-E1 plays. It needs no Wi-Fi connection, so the camera's Wi-Fi
stays off and its battery lasts for hours of shooting.

The protocol below is verified on an EOS R (see the findings section).
Where a real camera disagrees, note it here.

## Protocol

Canon bodies speak two BLE protocols: the remote one below (shutter and AF)
and the smartphone one Camera Connect uses (shutter and GPS, service
`00010000-…`). A camera is paired in one of the two modes at a time.
Shutterlink uses the remote protocol.

All UUIDs end in `-0000-1000-0000-d8492fffa821`.

| Role | UUID | Write |
|---|---|---|
| Service, advertised while pairing | `00050000` | |
| Identity: `0x03` + the remote's ASCII name | `00050002` | with response |
| Buttons: one byte per write | `00050003` | with response |

The name is written on every connect, not only when pairing; the camera
ignores buttons from a remote that has not named itself.

Button byte: bit 7 shutter, bit 6 focus, bits 2–3 mode (`11` immediate,
`01` 2 s delay, `10` movie).

| Action | Bytes |
|---|---|
| Photo | `0x8C`, ~150 ms, `0x0C` |
| Start/stop a recording | `0x88`, ~150 ms, `0x08` |
| Wake without shooting | `0x0C` |

On BULB a click opens the exposure and the next click closes it. Holding
`0x8C` is not documented to keep it open.

## Camera setup

- Pairing: MENU → Wireless settings → Bluetooth function → Remote →
  Pairing (newer bodies: Communication functions → Bluetooth settings, or
  "Connect to Wireless Remote"), then confirm on the camera.
- Drive mode must be Self-timer/Remote, or the camera ignores the remote.
- Movies need Shooting menu → Remote control: Enable.
- One remote slot per camera; re-pairing replaces it.

## EOS R findings (HCI snoop, Pixel 8, GrapheneOS on Android 17)

- The camera takes the name write (`0x17`) over an unencrypted link, but
  buttons (`0x19`) only once the link is encrypted. Android's bond needs
  the user to confirm a pairing request, sometimes only as a notification.
  Clicks sent before that are lost. So `CanonBleRemote` makes sure the phone
  is bonded first, through `BondBridge` (Android's `createBond`, waiting up
  to 60 s for the user), shown as `RemoteLink.pairing`. It then writes the
  name, then the idle button byte `0x0C` as a probe, and only then reports
  connected.
- The camera acknowledges every click, whatever the drive mode, but fires
  only in Self-timer/Remote. The remote service sends no notifications, so
  Shutterlink cannot tell whether a shot was taken. The run counts clicks
  as "Sent".
- A camera paired earlier sometimes stops accepting the phone: after a
  drop during a run, or the next day. The phone sends a connect request;
  the camera never answers it, and the connection fails with `0x3E` (GATT
  133) within about 100–250 ms, on every attempt, until it is paired again.
  Android connects from a new resolvable private address each time, which
  the camera may not resolve with the IRK the phone sent. Apps cannot pick
  the address, and Android has no setting for it. It is not every reconnect:
  right after pairing, a reconnect within a second worked. When it starts
  failing (camera sleep, power cycle, time) is not known yet.
- Shutterlink reports such a camera as `RemoteLink.refused` after 3 attempts
  in a row that fail within 2 s of starting. A camera that is off or out of
  reach lets each attempt run to the 10 s connection timeout instead, though
  that has not been checked on hardware.
- Pairing again needs no power cycle and no pairing sheet: delete the
  connection information on the camera and start pairing there. The app's
  retries (every 30 s once refused) reach the camera, Android notices its
  keys no longer work and asks to pair again, as a notification when the
  app did not ask itself. Confirmed within 30 s (Bluetooth's pairing
  timeout), the app connects. Unconfirmed, Android reports the old, broken
  bond as bonded again, so the next attempt asks again.
- Clicks during a link drop could crash the app: rxandroidble reports the
  write's late failure as an `UndeliverableException`, fatal by RxJava's
  default. `AppEngine` installs an RxJava error handler that logs it.
- `ACTION_BOND_STATE_CHANGED` comes from the Bluetooth process's own uid. A
  receiver registered `RECEIVER_NOT_EXPORTED` never gets it, so `BondBridge`
  registers it exported (the action is protected), and the remote also polls
  the bond state every second while it waits.
- `adb logcat | grep -E 'CanonBle|PairingSheet|\[Intervalometer\]'` shows
  each connect step.
- While the pairing sheet is open, the saved camera's reconnects are
  suspended. Otherwise they connected to the camera as soon as it entered
  pairing mode: it was never found by the scan, and hung until its battery
  was pulled.

## Unverified

- Whether a bulb exposure stays open when the link drops. Shutterlink sends
  the closing click once the camera is back, which would start a new
  exposure if the camera had closed it itself.
- Whether `0x0C` wakes a camera that went to sleep between shots. It is
  sent 5 s before each shot when the interval is 2 minutes or longer.
- Whether reconnecting works from a phone with a fixed address (iOS, or
  other Android builds).

## Sources

- furble, `CanonEOSRemote`: https://github.com/gkoh/furble
- Ian Douglas Scott's reverse engineering:
  https://iandouglasscott.com/2018/07/04/canon-dslr-bluetooth-remote-protocol/
- eos-remote-web (bulb as two clicks): https://github.com/RReverser/eos-remote-web
- cbremote: https://github.com/iebyt/cbremote
