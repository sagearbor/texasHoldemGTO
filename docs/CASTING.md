# Casting the table TV to a Chromecast

Felt Notes can put a table night on a Chromecast with nothing but a phone:
the organizer taps **Show on the TV → Cast to a TV**, picks the TV, and the
Chromecast itself loads the Felt Notes TV page for that night's code. The
phone then lets go. Nothing of the phone's screen is sent, so the owner's
own cards never reach the TV, only the night code (which is already in the
TV link).

## Pieces

| Piece | Where |
|---|---|
| Cast application | Custom Receiver "Felt Notes TV", Application ID **`2537B496`** (Google Cast SDK Developer Console, owner's account). Guest Mode on. |
| Receiver URL | `https://sagearbor.github.io/texasHoldemGTO/cast/` |
| Receiver page | `web/cast/index.html` (plain HTML + JS, no build step; the Flutter web build copies `web/` as-is, and GitHub Pages deploys `main`) |
| Sender (app) | `lib/ui/tv/cast/`: `cast_message.dart` (CASTV2 codec), `cast_sender.dart` (launch / stop), `cast_discovery.dart` (mDNS), `cast_panel.dart` (UI in the Show on the TV sheet) |
| Native help | Android `MainActivity.kt`, channel `felt_notes/tv_cast`, method `multicastLock` (Wi-Fi MulticastLock while looking for TVs) |

## Message format

Custom namespace: **`urn:x-cast:com.sagearbor.feltnotes`**, JSON payloads.

```json
{"code": "ABCD2345-WXYZ6789"}
```

The receiver ignores anything that is not `[A-Za-z0-9-]{3,64}`. A new code
swaps the TV page; the same code again is ignored.

## What happens

1. **Discovery**: mDNS query for `_googlecast._tcp.local` (package
   `multicast_dns`, pure Dart). Each device's TXT `fn` is the name shown.
   Android holds a MulticastLock meanwhile; the socket is bound without
   `SO_REUSEPORT` on Android.
2. **Launch** (TLS to port 8009, self-signed certificate accepted; CASTV2
   frames are a 4-byte big-endian length + a hand-encoded protobuf
   `CastMessage`):
   - `CONNECT` to `receiver-0` (namespace `urn:x-cast:com.google.cast.tp.connection`)
   - `LAUNCH {appId: "2537B496"}` on `urn:x-cast:com.google.cast.receiver`
   - wait for a `RECEIVER_STATUS` listing the app with a `transportId`
     and, once the page has started, our namespace (after 8 s a
     transport id alone is enough)
   - `CONNECT` to the transport id, send `{"code": …}` on our namespace
   - close the socket (no STOP, no CLOSE). Heartbeat: PING every 5 s,
     PONG to every PING.
3. **Receiver**: `CastReceiverContext.start()` with `disableIdleTimeout`
   and `skipPlayersLoad`; shows "Felt Notes · waiting for the game code"
   until a code arrives, then an iframe on `../#/tv?c=CODE` (the existing
   Flutter TV route, same origin, relative so the base href applies).
4. **Stop casting**: reconnect, `GET_STATUS`, `STOP {sessionId}` for our
   app.

Desktop test of the receiver page, no Chromecast:
`https://sagearbor.github.io/texasHoldemGTO/cast/?c=ABCD2345-WXYZ6789`.

## Limits and gotchas

- **Unpublished receiver = registered devices only.** While the Cast app is
  Unpublished, a Chromecast launches it only if its serial number is
  registered under Devices in the Cast console (then reboot the Chromecast;
  registration can take ~15 minutes). Otherwise LAUNCH fails with
  `NOT_FOUND`/`NOT_ALLOWED` and the app says so. Publishing the app removes
  the limit.
- **The receiver must be live on GitHub Pages**: `web/cast/index.html` has
  to be on `main` and deployed.
- **iOS**: raw multicast (our mDNS) needs Apple's
  `com.apple.developer.networking.multicast` entitlement, which must be
  requested from Apple. `Info.plist` already has `NSBonjourServices`
  (`_googlecast._tcp`) and `NSLocalNetworkUsageDescription`; the Cast option
  is hidden on iOS until discovery works there (alternative: discover with
  `NWBrowser` natively and keep the Dart CASTV2 client).
- **Chromecast hardware is weak**: the iframe holds only the TV route (the
  small `TvApp` in `lib/main.dart`). The Flutter web build picks CanvasKit
  on a Chromecast; if it is too slow, a lighter renderer is the next lever.
- Guest Mode (console setting) lets phones not on the Wi-Fi find the
  device by ultrasound in Google's own sender SDK; this pure-Dart sender
  only finds devices on the same Wi-Fi.

## Reusing it in another app

The sender is app-agnostic apart from three constants in
`cast_message.dart` (`feltNotesCastAppId`, `nsFeltNotes`) and the message
body. For another of the owner's apps:

1. In the same Cast developer account, add a new **Custom Receiver**
   application; its receiver URL points at that app's own site, e.g.
   `https://sagearbor.github.io/<repo>/cast/`. Note the new Application ID.
   Register test Chromecasts' serials (or publish).
2. Copy `web/cast/index.html`: change `NAMESPACE` (use
   `urn:x-cast:com.sagearbor.<app>`), the message handling, and the iframe
   URL (or render directly; keep it light).
3. Copy `lib/ui/tv/cast/` and pass the new app id / namespace
   (`castShowCode(appId: …)`; make the namespace a parameter if the app
   sends more than one kind of message). Add `multicast_dns`, the Android
   `CHANGE_WIFI_MULTICAST_STATE` permission and the `multicastLock` native
   method.
4. Copy `test/cast_test.dart`: the fake device covers the launch and stop
   state machines without a Chromecast.
