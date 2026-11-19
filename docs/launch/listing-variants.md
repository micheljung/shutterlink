# Listing variants

The files under `fastlane/metadata/android/en-US/` hold **variant N**
(user decision: title and short description stay free of the camera
maker's name; the full description names it once, nominatively).
`tool/check_store_assets.py` enforces the limits and the wording rule.

Both variants share the title and the short description.

Title (11 of 30 characters):

```
Shutterlink
```

Short description (75 of 80):

```
Copy photos from your camera over Wi-Fi or USB. Back up to your own server.
```

## Variant N (committed)

Full description, 2619 of 4000 characters. Only the compatibility line and
the disclaimer may match `grep -Eiw 'canon|eos'`.

```
Shutterlink gets the photos off your camera and onto your phone, backs them up to your own server as you shoot, and hands the people you photograph their pictures before they walk away. It talks to the camera directly, over the camera's own Wi-Fi or a USB cable. No camera maker's app, no account, and no cloud you don't own.

Browse & Download
* See everything on the memory card, newest first, grouped by day. A RAW+JPEG pair is one tile.
* Long-press and drag to select a range, select a whole day, or tap Select new for everything you haven't downloaded yet.
* Open any photo full screen and swipe through the card.
* Save JPEG, RAW (CR3) or both, byte-identical to what the camera wrote.
* Downloaded photos are marked and skipped next time. Interrupted downloads resume after reconnecting.

Auto Upload to your own server
* Every new shot goes to your storage while you keep shooting: Immich, Nextcloud/ownCloud or any WebDAV server, Backblaze B2, AWS S3, Cloudflare R2 and other S3-compatible storage, or any SFTP server such as a Hetzner Storage Box.
* Keeps going in the background, so you can pocket the phone.
* Choose whether uploads may use mobile data: never, JPEGs only, or always.
* Passwords and keys stay in the phone's secure storage. Self-signed certificates and SFTP host keys are confirmed once and pinned.
* Nothing is uploaded until you set up a destination.

Live Share: everyone gets their photos
* Start a Live Share, let the person scan the QR code, and every photo you take of them appears in their own private web gallery a few seconds later. They need no app and no account.
* Guests swipe and zoom through full-screen photos, download one or all of them, and can delete photos or their whole gallery.
* One Live Share is one Session with its own link and a readable code. Photos taken while no Session runs are never shared.
* Galleries live on your own small Sessions server (open source, ready-made Docker image) and are deleted after 30 days by default.

And also
* Try without a camera: your phone's camera becomes a demo camera, so you can try every mode.
* Finds the camera on your home Wi-Fi by itself.
* Camera traffic stays on the camera's Wi-Fi and never goes out over mobile data.
* No ads, no analytics, no tracking. Photos and settings go only to the servers you configure.

Tested with the Canon EOS R.

Other cameras that offer PTP over Wi-Fi or USB should work with basic support (JPEG only). Reports are welcome on the project page.

Canon and EOS are trademarks of Canon Inc. Shutterlink is an independent open-source project, not affiliated with or endorsed by Canon.
```

## Variant S (strict, not committed)

Same as N, without the Canon lines; the last paragraph becomes generic.
Full description, 2446 of 4000 characters.

```
Shutterlink gets the photos off your camera and onto your phone, backs them up to your own server as you shoot, and hands the people you photograph their pictures before they walk away. It talks to the camera directly, over the camera's own Wi-Fi or a USB cable. No camera maker's app, no account, and no cloud you don't own.

Browse & Download
* See everything on the memory card, newest first, grouped by day. A RAW+JPEG pair is one tile.
* Long-press and drag to select a range, select a whole day, or tap Select new for everything you haven't downloaded yet.
* Open any photo full screen and swipe through the card.
* Save JPEG, RAW (CR3) or both, byte-identical to what the camera wrote.
* Downloaded photos are marked and skipped next time. Interrupted downloads resume after reconnecting.

Auto Upload to your own server
* Every new shot goes to your storage while you keep shooting: Immich, Nextcloud/ownCloud or any WebDAV server, Backblaze B2, AWS S3, Cloudflare R2 and other S3-compatible storage, or any SFTP server such as a Hetzner Storage Box.
* Keeps going in the background, so you can pocket the phone.
* Choose whether uploads may use mobile data: never, JPEGs only, or always.
* Passwords and keys stay in the phone's secure storage. Self-signed certificates and SFTP host keys are confirmed once and pinned.
* Nothing is uploaded until you set up a destination.

Live Share: everyone gets their photos
* Start a Live Share, let the person scan the QR code, and every photo you take of them appears in their own private web gallery a few seconds later. They need no app and no account.
* Guests swipe and zoom through full-screen photos, download one or all of them, and can delete photos or their whole gallery.
* One Live Share is one Session with its own link and a readable code. Photos taken while no Session runs are never shared.
* Galleries live on your own small Sessions server (open source, ready-made Docker image) and are deleted after 30 days by default.

And also
* Try without a camera: your phone's camera becomes a demo camera, so you can try every mode.
* Finds the camera on your home Wi-Fi by itself.
* Camera traffic stays on the camera's Wi-Fi and never goes out over mobile data.
* No ads, no analytics, no tracking. Photos and settings go only to the servers you configure.

Works with cameras that offer PTP/IP over Wi-Fi or PTP over USB. See the project page for tested models. Reports are welcome.
```
