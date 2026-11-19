# Bluetooth remote (intervalometer)

The intervalometer fires the camera as its Bluetooth remote, the role
Canon's BR-E1 plays. It needs no Wi-Fi connection, so the camera's Wi-Fi
stays off and its battery lasts for hours of shooting.

None of this is verified on hardware yet. Where a real camera disagrees,
note it here.

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

## Unverified

- Whether the `00050000` characteristics require an encrypted link. Android
  bonds on demand; other implementations bond explicitly.
- Whether a bulb exposure stays open when the link drops. Shutterlink sends
  the closing click once the camera is back, which would start a new
  exposure if the camera had closed it itself.
- Whether `0x0C` wakes a camera that went to sleep between shots. It is
  sent 5 s before each shot when the interval is 2 minutes or longer.
- Whether a paired camera keeps advertising; Shutterlink reconnects by
  address.

## Sources

- furble, `CanonEOSRemote`: https://github.com/gkoh/furble
- Ian Douglas Scott's reverse engineering:
  https://iandouglasscott.com/2018/07/04/canon-dslr-bluetooth-remote-protocol/
- eos-remote-web (bulb as two clicks): https://github.com/RReverser/eos-remote-web
- cbremote: https://github.com/iebyt/cbremote
