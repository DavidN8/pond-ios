# POND Chat privacy policy

Last updated: 29 October 2026

POND Chat is a vibe-coded fork of [Element X](https://github.com/element-hq/element-x-ios) for personal use, run by David N8.
This policy covers the iPhone app and POND's own Matrix server. If you sign in to another Matrix server, that server's own
policy covers what it stores.

## What the app sends, and where

The app talks to the Matrix server you sign in to and to Apple's services that every iPhone app uses. It contains no
analytics, advertising or tracking, and it does not send crash reports.

Calls show only where your Matrix server offers them. When you join one, the app also connects to the call service (LiveKit)
named for that call: usually your Matrix server's, which can run on a different host, or, in a chat with members on other
servers, one of theirs. It carries your audio and video to the other members, and sees your Matrix ID and IP address while you
are in the call.

## What POND's server stores

- **Your account:** your user name, a hashed password, your display name and avatar if you set them.
- **Your messages and files:** what you send in chats, threads, task boards and notes, so other members can read them. In
  end-to-end encrypted chats the server stores only encrypted data it cannot read. Custom emoji and stickers are stored
  unencrypted, as the app's settings say.
- **Technical data:** the devices you sign in with, your IP address and the times you connect, kept in the server's logs to run
  the service and keep it secure.

## Permissions on your phone

The app asks for the camera, microphone and photo library only when you take a photo, record a voice message, join a call
or pick a file to send, and uses them only for that. It reads only the photos you select.

## Notifications

If you allow notifications, the app gives your Matrix server a push token Apple made for your phone. When a message arrives,
your Matrix server sends POND's push service (it runs on POND's server, whichever Matrix server you use) that token with the
message's ID, the chat's ID and your unread count, and the push service passes them to Apple, which wakes the app. The app then
fetches the message from your Matrix server and decrypts it on your phone to show it: message contents never go through the
push service or Apple. The push service stores nothing; its logs, which can include those IDs and the token, are overwritten
after a few megabytes. Turn notifications off in the app's settings or your phone's to stop all this.

## Sharing

We do not sell or share your data. Other members of a chat see what you post there. POND's server is hosted by
DigitalOcean in Singapore.

## Keeping and deleting your data

We keep your account and messages until you delete them. You can delete messages in the app, and delete your account under
Settings → Delete account. Messages you sent to others may stay visible to them. To ask for a copy or the removal of your data,
email david.work1405@gmail.com.

## Children

POND Chat is not meant for children under 13, and we do not knowingly collect their data.

## Changes

Changes to this policy are posted here, with a new date. The history of this file shows every earlier version.
