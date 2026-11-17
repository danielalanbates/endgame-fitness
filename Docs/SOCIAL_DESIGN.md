# Social design: a social game without our own accounts

Endgame Fitness runs entirely on the device with local players (see STATUS.md).
The social layer is built from four pieces that need no Endgame Fitness server
and no accounts of our own. It lives in the **Community** tab (tab 7) as the Rivals,
Gym Party, Game Center and Share sections; rival events show under Rivals >
Rival activity, and the general feed is Community > Feed. (The separate Social
tab, tab 8, was removed 2026-11-16.)

## 1. Game Center (GameKit) — optional, `GameCenterService.swift`

- Game Center is one Apple account per device. Each **local player** opts in
  ("Post this player's progress to Game Center"); only opted-in players submit.
  The opt-in list is `gc.enabledPlayers` in UserDefaults.
- Leaderboards (weekly, recurring): `egf.weekly_volume`, `egf.level`,
  `egf.streak`, `egf.raid_damage`.
- Achievements are mirrored from local ones as `egf.ach.<local achievement id>`.
- Friends list via `GKLocalPlayer.loadFriends()` (needs `NSGKFriendListUsageDescription`);
  boards show friends-only when the list is non-empty, else global.
- Duels: `GKTurnBasedMatch`, 2 players. Each side posts this week's volume as
  the match data; the second post ends the match with won/lost/tied.
- Not signed in / unavailable / boards missing: a status line, nothing else breaks.

**To make it live (manual, App Store Connect):** enable Game Center on the app
record, create the 4 leaderboards above (recurring weekly, integer, high wins)
and one achievement per local achievement id with the `egf.ach.` prefix.
The `com.apple.developer.game-center` entitlement is in `project.yml` for both
targets; the provisioning profiles must be regenerated to include it.

## 2. Friend codes / player cards — `SocialCore.swift`

- A `PlayerCard` = name, icon, level, XP, class, title, this week's volume and
  workouts, streak, top 5 lifts (e1RM), raid damage, issue time. Nothing else.
- Encoded as `EGF1.<base64url JSON>.<8-byte HMAC-SHA256>`; shared as text, as
  the deep link `endgamefitness://card/<code>`, or as a QR code (CoreImage).
- The HMAC key ships in the app, so this is **tamper-evident, not secure**:
  it rejects typos and casual edits. Rival boards are bragging rights.
- Import: paste, open the link, iOS camera scan (AVFoundation), or import an
  image/text file (macOS reads the QR out of a screenshot with CIDetector).
- Rivals are stored per local player in `Game/Players/<id>/rivals.json`.
  Re-importing a newer card updates the rival and logs feed events
  (level up, PR, streak, new session).

## 3. Gym Party (nearby) — `GymParty.swift`

- MultipeerConnectivity, service `egf-gymparty` (Bonjour `_egf-gymparty._tcp/_udp`,
  `NSLocalNetworkUsageDescription`). Encryption required. Runs only while the
  user has started a party; it auto-connects nearby peers (the lexically
  smaller peer name invites).
- Joining peers exchange player cards (they become rivals, source "nearby").
- Co-op boss: anyone summons this week's boss; HP = 8000 x party size. Every
  completed set on any device (hooked into `toggleSetCompleted`) deals
  weight x reps (bodyweight: reps x 25) and is broadcast. Hits have ids, so
  duplicates count once. A late joiner gets the full boss + hit list.
- Not persisted: a party boss lasts as long as the party.

## 4. Share cards — `ShareCards.swift`

- 540x540 images rendered with `ImageRenderer`: last session, level, top PR,
  raid kill, player card (with QR). Shared with `ShareLink`, so Messages,
  Instagram, Facebook, etc. appear in the system share sheet when installed.

### Why no Facebook SDK

- The Facebook SDK requires a Meta app registration, App Review for any
  permission beyond basic profile, a privacy-policy and data-deletion flow,
  and it adds tracking-related SDK code (App Tracking Transparency and the
  privacy manifest would need to declare it). It also brings accounts back,
  which the local-players design removed on purpose.
- The share sheet already reaches Facebook and Instagram (Stories / Feed) for
  images, with zero SDK code.

### Pathway to a future Facebook integration

1. Register a Meta app; add Facebook Login (limited login on iOS, which does
   not require ATT) as an *optional* link on a local player, like Game Center.
2. Use the Instagram Stories share URL scheme (`instagram-stories://share`,
   needs the Meta app id) for sticker-style story shares of the share cards.
3. Friend discovery via Graph `user_friends` (only friends who also use the
   app) would need App Review; map them to player cards exchanged via a small
   relay, or keep exchange peer-to-peer.
4. Update PrivacyInfo.xcprivacy, the privacy policy, and add data deletion.

## Verified vs not (2026-11-16)

- Verified: compiles (swiftc check + macOS Debug xcodebuild); self-test covers
  card encode/decode round trip, deep link in text, tamper rejection, QR render,
  rival-update events.
- Not verified: Game Center sign-in/boards/duels (needs App Store Connect setup
  and a signed build with the entitlement), Gym Party between two real devices,
  iOS camera scan, the share sheet targets, the iOS build (Simulator tools out
  of date on the build Mac).
