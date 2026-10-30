# Store privacy forms for table nights (0.3.2)

Until 0.3.1 both stores say "Data Not Collected". From the release that
contains table nights (multi-phone sync + TV, branch `table-tv`), the app
sends data off the phone when a user starts or joins a table night, so both
forms must change **in the same submission** as that build. The privacy
policy text is `web/privacy.html` (deployed with the web app on merge to
main; the store listing's privacy URL stays
`https://sagearbor.github.io/texasHoldemGTO/privacy.html`).

What actually leaves the phone (source of truth: `lib/sync/cloud_logs.dart`
`cloudEvents` / `releasedCards`, `firestore.rules`):

| Data | When | Where |
|---|---|---|
| Firebase anonymous user id; random install id (12 chars) | joining / starting a table night | Firestore `nights/*/members`, `logs` |
| Display names (seating, the name a player joins with) | table night | `members`, `logs` |
| Hand start times, dealer, seating, board, blind clock (organizer) | table night | `logs` |
| A player's call / raise taps with times ("had cards" marker) | table night, sharing on | `logs` |
| A player's hole cards | after the hand, sharing on; unreadable 2 min | `cards` |
| Buy-in / cash-out, trainer data, solo nights | never | stays on device |

No ads, no analytics, no crash reporting, no advertising id, no location,
no contacts. Firebase Analytics is not included (only `firebase_core`,
`firebase_auth`, `cloud_firestore`). Data is encrypted in transit (TLS).
Retention: every document has `expireAt` = +60 days; the owner runs
`tool/sweep_expired_nights.sh` (TTL policies need billing, which this
project never enables). Deletion on request: email in the policy.

## Google Play: Data safety

Play Console → App content → Data safety → Edit.

**Data collection and security**

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** |
| Do you provide a way for users to request that their data is deleted? | **Yes** (privacy policy: email with the night code; plus in-app: sharing off deletes taps and cards) |
| Account creation | **My app does not allow users to create an account** (anonymous sign-in is not an account the user creates or logs into) |

**Data types** (tick exactly these):

| Category → type | Collected | Shared | Processed ephemerally | Required or optional | Purposes |
|---|---|---|---|---|---|
| Personal info → **Name** | Yes | No | No | Optional | App functionality |
| App activity → **Other user-generated content** (game taps, hole cards, hand times) | Yes | No | No | Optional | App functionality |
| Device or other IDs → **Device or other IDs** (Firebase anonymous id, install id) | Yes | No | No | Optional | App functionality |

Everything else: not collected. Notes for the reviewer if asked:
"Shared = No": the only transfer is to Google Firebase as our service
provider, and to the other players at the same table at the user's own
direction (they scanned the QR and left sharing on), which Play does not
count as sharing. "Optional": nothing is collected unless the user starts
or joins a table night, and the sharing switch turns off taps and cards.

## Apple: App Privacy (App Store Connect → App Privacy → Edit)

**Do you or your third-party partners collect data from this app?** **Yes**

Data types (tick exactly these):

| Type | Used for | Linked to the user? | Used for tracking? |
|---|---|---|---|
| Contact Info → **Name** | App Functionality | **Yes** | No |
| User Content → **Gameplay Content** (taps, hole cards, hand times) | App Functionality | **Yes** | No |
| Identifiers → **User ID** (Firebase anonymous id) | App Functionality | **Yes** | No |
| Identifiers → **Device ID** (the app's own random install id; not IDFA / IDFV) | App Functionality | **Yes** | No |

"Linked = Yes" is the conservative answer: a night's data from one phone is
grouped under its anonymous ids and the display name. Nothing is used for
tracking, advertising, analytics or product personalisation. The resulting
label: "Data Linked to You: Contact Info, User Content, Identifiers";
"Data Used to Track You": none.

No ATT prompt is needed (no tracking, no IDFA).

## Also check in the same release

* Info.plist / manifest: no new permissions (network only; camera was
  already declared for the QR photo / Snap my cards).
* Play "Data deletion" URL field (if asked): the privacy policy URL; the
  deletion section is "How long table-night data is kept" / "Deleting your data".
* In-app: Help → Home game → "Table nights (other phones and a TV)" says the same.
