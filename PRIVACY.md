# Shutterlink privacy policy

Effective date: 2026-12-01

Shutterlink is an open-source Android and iOS app by Michel Jung. It copies
photos from your camera to your phone, and optionally on to servers that
you choose.

Contact: [shutterlink@micheljung.ch](mailto:shutterlink@micheljung.ch)

## Summary

- The app has no account, no advertising, no analytics and no crash
  reporting. It contains no third-party tracking code.
- Your photos and settings stay on your phone. They leave it only for a
  server that you configured yourself.
- I run no server that the app contacts on its own.

## What the app does with your data

**Photos from your camera.** The app talks to your camera over the
camera's own Wi-Fi or a USB cable and saves the photos to your phone's
storage. Nothing is sent anywhere for this.

**Auto Upload.** If you set up Auto Upload, the app uploads your photos to
the destination you enter: a Nextcloud, ownCloud or WebDAV server, an
S3-compatible bucket such as Backblaze B2, AWS S3 or Cloudflare R2, an SFTP
server, or Immich. The credentials you enter are stored in the phone's
secure storage and are sent only to that destination. What the destination
does with your photos is governed by its operator, not by me.

**Live Share.** If you set up Live Share, the app uploads the photos of a
Live Share Session to the Sessions server whose address you enter, and
guests who open the Session's gallery link can view and download them. The
server's operator, normally you, controls retention. Guests can delete
their own photos or their whole gallery.

**Tip buttons.** A gallery can show tip buttons (for example PayPal or
TWINT) that you configure. They are plain links to the payment provider and
are followed only if a guest taps them.

**Settings and history.** Your settings, which photos you already
downloaded and your upload progress are stored on your phone only.

## Public demo server

For trying Live Share without running your own server, I operate a public
demo Sessions server at `demo.shutterlink.micheljung.ch`. The app never
contacts it on its own: it is used only if you enter its address and
upload token yourself, or open one of its gallery links in a browser.

- **Operator:** Michel Jung, on a server I run myself.
- **Who can see photos:** anyone who has a gallery link can view the photos
  in it and can add photos to the Session. Do not upload private photos,
  photos of people who did not agree, or anything illegal. The upload
  token is public.
- **Retention:** photos are deleted at most about 25 hours after a
  Session's first upload. They may be deleted earlier, for example
  whenever the service restarts or its storage is full. Nothing is
  backed up.
- **Logs:** the server keeps no access logs. Error logs may briefly
  contain IP addresses and are rotated away with the system journal.
- **Sharing:** I do not sell or share demo server data with anyone, and I
  do not look at the photos unless I receive an abuse report.
- **Abuse and removal:** write to
  [shutterlink@micheljung.ch](mailto:shutterlink@micheljung.ch) with the
  gallery link to have a gallery removed. I may remove content or switch
  the demo server off at any time.

## Permissions on Android

| Permission | Why |
|---|---|
| Internet, network and Wi-Fi state, change network state, Wi-Fi multicast | Reach the camera on its Wi-Fi, find it on your network and upload to your servers. |
| USB (device access, not a manifest permission) | Talk to a camera plugged in by cable. Android asks you when you plug it in. |
| Foreground service (connected device), wake lock | Keep the camera connection and uploads running with the screen off while Live transfer or Auto Upload is on. |
| Notifications | Show the progress of Live transfer and Auto Upload. |
| Storage (Android 9 and older) | Save photos to your phone. |

## Children

The app is not directed at children.

## Your rights

I hold no personal data about app users. If you uploaded photos to the
demo server and want them removed earlier than the automatic deletion,
write to the contact address above with the gallery link. If you are in
the EU, you may also contact your data protection authority.

## Changes

If this policy changes, the new version is published at
[shutterlink.micheljung.ch/privacy/](https://shutterlink.micheljung.ch/privacy/)
with a new effective date. The history is in the
[repository](https://github.com/micheljung/shutterlink/commits/main/PRIVACY.md).

Shutterlink is not affiliated with or endorsed by Canon Inc. Canon and EOS
are trademarks of Canon Inc.
