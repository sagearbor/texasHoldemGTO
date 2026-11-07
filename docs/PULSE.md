# Pulse mode: live heart rate from players' watches

Status: in progress (Nov 7 2026). Owner decisions: build it inside Felt Notes
as a "Pulse" mode first, spin off later if it lands; Wear OS and Apple Watch
together; song previews from Apple's free 30-second clips, never uploads; no
accounts (name + selfie saved on the phone).

## The idea

One person starts a night. Others join with the QR / nearby invite as now and
put their phones down. Players who opt in to Pulse stream their heart rate
from their watch. The TV shows one line chart, one line per player, each line
ending in a small circle with the player's face. Whoever has been highest for
10 s gets their song's 30-second preview played on the TV (then 2 minutes
before any song plays again). End of night: "Calmest player", "Biggest spike:
hand 23" summary that people will want to share.

## Data path

```
watch ──Bluetooth (Wear Data Layer / WatchConnectivity)──▶ own phone
own phone ──(only if this player opted in to Pulse for this night)──▶ Firestore night
Firestore night ──▶ TV (web /#/tv and in-app TV)
```

The watch never goes online. Without opt-in, heart rate stays on the phone.

## Watch ↔ phone protocol (v1)

Both watch apps speak the same JSON. Keep it this small.

| Path / key | Direction | Payload |
|---|---|---|
| `/feltnotes/pulse/v1/hr` | watch → phone | `{"v":1,"s":[[tMs,bpm],...]}` — samples since the last send, sent every ~2 s while running. `tMs` = epoch ms on the watch clock. |
| `/feltnotes/pulse/v1/ctl` | phone → watch | `{"v":1,"cmd":"start"}` or `{"v":1,"cmd":"stop"}` |
| `/feltnotes/pulse/v1/state` | watch → phone | `{"v":1,"running":true,"err":null}` — on every change and in reply to a ctl |

Wear OS: `MessageClient` with these paths (UTF-8 JSON bytes). Apple: a
`WCSession.sendMessage` dictionary `{"path": "<path>", "json": "<payload>"}`
(same strings, so one parser on the phone side).

The watch app can also be started from the watch itself (big Start button);
it then sends `state` and samples unasked.

Test vectors: `test/pulse/protocol_vectors.json` — each watch app's unit
tests and the Dart parser test read the same file.

## Phone ↔ Flutter channel

* `EventChannel("feltnotes/pulse/events")` emits maps:
  * `{"type":"hr","s":[[tMs,bpm],...]}`
  * `{"type":"state","running":bool,"err":String?}`
* `MethodChannel("feltnotes/pulse/ctl")`:
  * `status` → `{"supported":bool,"paired":bool,"appInstalled":bool,"reachable":bool}`
  * `start` / `stop` → sends ctl to the watch, returns bool (sent)
  * `openWatchStore` → opens the watch app install page on the watch when possible (Wear: `RemoteActivityHelper`), returns bool

Native code parses the watch payload and forwards it unchanged; validation
(bpm 30..230, drop out-of-order) happens in Dart.

## While a Pulse night is on

The Pulse screen keeps the phone screen on (wakelock_plus, already a
dependency), dimmed and dark, so the app stays in the foreground on both OSes.
Background delivery is a later improvement.

## Firestore

Batched: one write per player every 15 s holding that window's samples
(about 8,000 writes on an 8-player, 4-hour night; free tier is 20,000/day).
Pulse data and the selfie live under the night and are deleted with it.
Exact documents and rules: see `firestore.rules` and the rules tests.

## Store and privacy

* Play: Wear OS form factor on the same listing (same applicationId,
  versionCode = 1_000_000 + n, same upload key), health permissions
  declaration, Wear screenshots before production.
* Apple: watch app embedded in the iOS app, HealthKit usage strings.
* Privacy page: heart rate and selfie lines (owner approval before pushing
  main, since that publishes the website).

## Apple Watch app (ios/FeltNotesWatch)

* Target `FeltNotesWatch`, shown as "Felt Notes Pulse", bundle id
  `com.sagearbor.feltnotes.app.watchkitapp` (registered, HealthKit capability
  on), watchOS 10+, single-target SwiftUI app embedded in Runner at
  `Runner.app/Watch/FeltNotesWatch.app`. Its version numbers come from
  Flutter's `Generated.xcconfig`, so they always match the iPhone app's.
* The Xcode project edit is `tool/watch_ios/add_watch_target.sh` (re-runnable;
  `pod install` leaves the target alone because it is not in the Podfile).
* Heart rate: `HKWorkoutSession` (.other, indoor) + `HKLiveWorkoutBuilder`;
  on stop the workout is discarded, so nothing is saved to Health.
  `state.err` values the watch sends: `no_permission`, `unavailable`,
  `workout_failed`.
* Protocol code: `ios/PulseShared/PulseProtocol.swift`, compiled into both the
  watch app and Runner (`ios/Runner/PulseChannel.swift`). Check it against the
  vectors with `tool/watch_ios/check_protocol.sh`.
* Watch → phone: `sendMessage` while the phone is reachable; a `state` sent
  while unreachable goes out as the application context and reaches Dart when
  the phone next activates the session.
* Limits: `start` from the phone only works while the watch app is open
  (reachable); otherwise it returns false and the player taps Start on the
  watch. Waking the watch app from the phone needs
  `HKHealthStore.startWatchApp`, i.e. HealthKit on the iPhone app too (later).
  `openWatchStore` always returns false on iOS: the watch app installs from
  the iPhone's Watch app.

## Wear OS app (watch/wear)

* Standalone Gradle project, module `:wearApp`, "Felt Notes Pulse". Same
  applicationId as the phone (`com.sagearbor.feltnotes.app`, also in debug:
  the Data Layer only connects same-package, same-key apps), minSdk 30,
  `standalone=false`. versionCode = 1_000_000 + the pubspec build number,
  versionName from pubspec, both read at configure time.
* Build: `cd watch/wear && ./gradlew :wearApp:assembleDebug`; tests
  `./gradlew :wearApp:testDebugUnitTest` (runs the shared vectors). Release
  for Play's Wear OS track: `./gradlew :wearApp:bundleRelease` →
  `wearApp/build/outputs/bundle/release/wearApp-release.aab`, signed with the
  phone's upload key when `android/key.properties` exists (debug key otherwise).
* Heart rate: Health Services `ExerciseClient` (type WORKOUT, heart rate only,
  5 s batching override where supported) inside a `health` foreground
  service, so it runs with the screen off. If another app's workout is in
  progress it falls back to `MeasureClient` instead of ending that workout.
  Permission: `BODY_SENSORS` (API ≤ 35) or `android.permission.health.READ_HEART_RATE`
  (Wear OS 6), asked at Start.
* Messages: `/hr` to phone nodes every ~2 s, `/state` on every change and in
  reply to every `/ctl`. Phone nodes = those with capability
  `feltnotes_pulse_phone` (declared by android/app `res/values/wear.xml`),
  else any nearby connected node. The watch declares `feltnotes_pulse_watch`.
* `/ctl start` while the watch app is closed: Android may refuse a background
  start of the sensor service; the watch then sends
  `{"running":false,"err":"needs_tap"}` and shows a "Tap to start Felt Notes
  Pulse" notification. `err` values from the Wear app: `no_permission`,
  `needs_tap`, `unsupported` (no heart-rate sensor), `sensor_error`, or null.
* One parser: `watch/wear/protocol/src/main/kotlin/.../PulseProtocol.kt` is
  compiled into both the watch app and the phone (`android/app/build.gradle`
  adds it as a source dir).
* Phone bridge: `android/app/.../PulseChannel.kt`. `supported` = Play services
  present and the Wearable API available (needs the Wear OS / Pixel Watch
  companion app); `paired` = a watch is connected or known to the Data Layer;
  `appInstalled` / `reachable` = capability `feltnotes_pulse_watch` with
  FILTER_ALL / FILTER_REACHABLE; `start`/`stop` go to reachable watches with
  the app; `openWatchStore` opens `market://details?id=com.sagearbor.feltnotes.app`
  on connected watches without the app (RemoteActivityHelper). Events flow
  only while Dart listens to the EventChannel.
