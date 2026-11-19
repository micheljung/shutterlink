# Play Console answers

Copy-paste answers for the Shutterlink listing (`ch.micheljung.shutterlink`).
Listing text, screenshots and the feature graphic come from
`fastlane/metadata/android/en-US/`.

## Store listing

- App name: `Shutterlink`
- Short description: `Copy photos from your camera over Wi-Fi or USB. Back up to your own server.`
- Full description, screenshots and feature graphic: from the fastlane
  metadata (CI uploads them; paste from `full_description.txt` when doing it
  by hand).
- Category: Photography. Contact email: `shutterlink@micheljung.ch`.
- Privacy policy URL: `https://shutterlink.micheljung.ch/privacy/`
  (fallback: `https://github.com/micheljung/shutterlink/blob/main/PRIVACY.md`).

## App access

All functionality is available without special access or login.

> No account is needed. On the start screen tap **Try without a camera**.
> The phone's own camera then acts as a demo camera, so every mode can be
> tried without a real camera or any server.

## Ads

- Contains ads: **No**.
- Advertising ID: **No** (the app does not use it).

## Data safety

- Does your app collect or share any of the required user data types?
  **No data collected.**
- Data shared: none. No SDK that collects data (no analytics, ads or crash
  reporting).
- Security practices: data is encrypted in transit where the user's server
  supports HTTPS; the app does not offer account-based deletion because it
  has no accounts.

Accepted risk (user decision): the app can upload photos to a server the
player types in, including one run by the developer. Play may treat uploads
to a developer-run server as data collection even though the app only
contacts addresses the player enters. If Play flags the declaration, change
the answer to Photos: collected, optional, not shared, purpose App
functionality, encrypted in transit, deletable on request.

## Content rating (IARC questionnaire)

- Category: Utility, productivity, communication or other.
- Violence, sexual content, profanity, controlled substances, gambling:
  **No** to all.
- Users can interact or exchange content: **Yes** (Live Share galleries are
  viewable by anyone with the link, and guests can add nothing but may delete
  photos). Shares user location: **No**. Digital purchases: **No**.
- Expected result: PEGI 3 / Everyone, with the "Users Interact" notice.

## Target audience and content

- Target age group: **18 and over**.
- Appeals to children: **No**.
- Not a news app, not a government app, no health features, no COVID-19
  features.

## Foreground service declaration (`FOREGROUND_SERVICE_CONNECTED_DEVICE`)

Service: `LiveTransferService`, type `connectedDevice`.

> Live transfer keeps a connection to the user's camera (Wi-Fi PTP/IP or
> USB) and copies each new photo as it is taken while the screen is off. It
> runs only while the user has Live transfer on, with an ongoing
> notification showing progress; the user stops it from the notification or
> the app. WorkManager would drop the camera connection and miss photos.

Video link (30-60 s, real device and camera: start Live transfer, lock the
screen, notification shows progress, a photo arrives): `<YOUTUBE UNLISTED
URL - user to record and add>`

## Permissions

| Permission | Justification |
|---|---|
| `INTERNET` | Talk to the camera over Wi-Fi and upload photos to servers the user configures. |
| `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_NETWORK_STATE` | Tell whether the phone is on the camera's Wi-Fi and keep camera traffic on that network instead of mobile data. |
| `CHANGE_WIFI_MULTICAST_STATE` | Find the camera on the home Wi-Fi (multicast discovery). |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `WAKE_LOCK` | Live transfer with the screen off, see the declaration above. |
| `POST_NOTIFICATIONS` | The ongoing Live transfer progress notification. Nothing else is notified. |
| `WRITE_EXTERNAL_STORAGE` (Android 9 and older only) | Save downloaded photos to the gallery and `Download/` on old Android versions. |

## USB host

`android.hardware.usb.host` is declared as not required. The app uses it
only to talk PTP to a camera the user plugs in; the USB attach filter offers
to open the app for known camera vendors. Phones without USB host can still
use Wi-Fi.

## Release notes (first release)

Taken from `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`.
