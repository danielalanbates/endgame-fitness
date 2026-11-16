# Endgame Fitness — status and next actions

## 2026-11-16 — local players (branch worldclass-2026-11-16)

- **No accounts.** Launch shows "Who's training?" (`PlayerPickerView`): create,
  pick, edit, delete local players (name, symbol + colour avatar, optional
  4-digit PIN). Multiple players per device = the household.
- **The game runs on the device.** `GameRules.swift` is a 1:1 port of
  `App/Backend/functions/_lib/*.js` (XP, levels, PRs, quests, achievements,
  talents, challenges, raids, seasons, streaks, hero class, titles);
  `LocalGame.swift` applies it to JSON state in
  `~/Library/Application Support/EndgameFitness/Game/` (`players.json`,
  `household.json`, `Players/<id>/game.json`). `GameProfileService` keeps the
  old API, so every view works offline.
- Household = friends (auto), one household guild, weekly raid boss (guild or
  solo), duels between local players, shared feed with reactions/comments.
- Existing history: the first player created adopts the device's existing
  training log and replays it once (XP/totals/streak/PR baselines; no quests,
  raid damage or season XP for sessions before this week).
- Backup: Player screen → Export backup / Import (one JSON per player).
- Verify: `xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -o /tmp/ef_check App/Sources/EndgameFitness/*.swift && /tmp/ef_check -ef.selftest` → `SELFTEST PASS 48/48`.
- Archived: batesai.org auth/account/sign-in/networked service →
  `_archive/batesai-account-2026-11-16/` (see WHY_ARCHIVED.md). AI coach is
  disabled offline.


_Updated 2026-08-29 (autonomous session; supersedes the 2026-08-28 status)._

Goal: world-class fitness app that blurs social game and training log; profiles
via batesai.org membership; TestFlight on macOS + iOS.

## Where things stand (2026-08-29, evening)

| Area | State |
|---|---|
| App Store Connect record | **EXISTS** — "Endgame Fitness RPG", app id `6806675925`, bundle `org.batesai.endgamefitness`, SKU `org.batesai.endgamefitness`. Created through Xcode Organizer → Distribute App (REST `POST /v1/apps` is 403). "Endgame Fitness" as a store name is taken by another developer; rename in ASC if a better free name is found. |
| Signed builds | `scripts/ship.sh both 1.0.0 <build>` archives, exports and uploads locally (Xcode 26.6 + iOS 26.5 platform). Build 3 (both platforms) was REJECTED in processing — see "Build 3 post-mortem". **Build 1.0.0 (6) is VALID on both platforms** (see `Docs/SHIP_LOG.md`); TestFlight internal group created, Daniel invited. |
| Backend | Live on batesai.org (Cloudflare Pages `website` + D1 `batesai-db`). Guild raids + Step Count quest deployed and migrated 2026-08-29; smoke: `/api/fitness/{profile,quests,raid,achievements,talents,challenges}` all 200, a synced 12,000 lb session dealt 12,250 raid damage. |
| iOS UI | Ran in the Simulator for the FIRST time today. Sign-in, onboarding, Home, Workouts, Community feed verified on iPhone 17 Pro / iOS 26.5 after the layout pass (`Docs/screenshots/2026-08-29-ios/`). Known nit: Community segment labels truncate ("Leader…", "Challe…") on 390pt — use icons or a scrollable segmented control. Drive with `-ef.autologin`, `-ef.skipOnboarding`, `-ef.tab <n>` (DEBUG). |
| macOS UI | Build 6 verified live: sign-in → dashboard (Level 6) → Community feed → Guild raid card (`Docs/screenshots/2026-08-29-macos/`). `/Applications/Endgame Fitness.app` = build 6 archive re-signed ad-hoc (works locally; App Store profile builds cannot launch outside the store). Previous copies archived to iCloud `EndgameFitness/_archive/apps/2026-08-29-*`. |

## What changed today

1. **App record + TestFlight pipeline unblocked.** Xcode already had the Apple
   Account signed in, so Organizer's upload flow created the record after the
   name was changed to "Endgame Fitness RPG".
2. **iOS 26.5 platform installed** (`xcodebuild -downloadPlatform iOS`, no
   admin). Xcode 26.6 refuses every iOS destination — device *and* simulator —
   without it. Disk was at 8 GB free, so the iOS 26.2 runtime was deleted first.
3. **HealthKit** (`HealthKitManager.swift`, iOS only, macOS no-op stub): steps /
   active energy / HR / body-mass read auth, strength workouts written on
   session finish, Health card on the dashboard, Settings toggle,
   `steps_today` + `active_kcal_today` in the sync payload, daily quest
   "Step Count" (8,000). App ID has the HEALTHKIT capability; profiles
   regenerated ("… AppStore 2026-08-29").
4. **Guild Raids** (`Docs/GUILD_RAIDS.md`): weekly boss from an 8-boss catalog
   (`_lib/raids.js`), hp scales with member count, damage = session volume in
   lb + 250 per verified PR, defeat → XP to every contributor, `raid_slayer`
   achievement, `raid_defeated` feed items. `GET /api/fitness/raid`, raid
   section in the sync response, `RaidViews.swift` card in the guild pane.
5. **Session game layer** (`Docs/SESSION_GAME_LAYER.md`): rest timer with local
   notification + haptics, per-set "+XP" pop-ups (estimate mirrors the server
   formula; server stays authoritative), combo/PR callouts, session summary +
   share card. Fixed two latent bugs: "Add Set" never logged (bad guard) and
   `duration` was never sent to the server.
6. **iOS adaptive layouts** (`Platform.swift`: `Font.screenTitle`,
   `desktopMinFrame`, `scrollableOnPhone`, `AdaptiveHStack`, …) applied to
   onboarding, dashboard, workouts, progress, history, tools, settings, sheets,
   wizard, talents, account. macOS appearance unchanged by construction.
7. **Backend drift fixed for good.** The website deploys from the home-directory
   worktree; it lagged origin and website PR #6 lacked `_lib/game.js`,
   `talents.js`, `challenges.js`, so `/api/fitness/quests` was 404 live.
   Website PR #7 syncs everything; `~` is fast-forwarded. Deploy from the
   session scratchpad — `wrangler pages deploy` fails under `/Users/daniel`
   with a mangled `.wrangler/tmp` path.
8. **Debug affordance:** `-ef.autologin <email> <password>` (DEBUG builds)
   signs in without a keyboard so the simulator can be driven headlessly
   (`xcrun simctl launch booted org.batesai.endgamefitness -ef.autologin …`).
9. Test-account credentials moved out of the docs into gitignored
   `.local/test-accounts.md`; `scripts/verify/ax_signin.py` reads
   `EF_TEST_PASSWORD`.

## Build 3 post-mortem (both platforms rejected by ASC processing)

- **No asset catalog in either bundle.** `project.yml` used a `resources:` key
  that xcodegen does not have; the `.xcassets` was silently dropped, so there
  was no `Assets.car` and no icon (iOS 90022/90023/90713, macOS 90236). Fixed
  by listing `Resources/Assets.xcassets` under `sources:`.
- **macOS: App Sandbox missing** (90296). Entitlements now: `app-sandbox`,
  `network.client`, `files.user-selected.read-write`, `applesignin`.
- **pkg UTI**: Build Upload API wants `com.apple.pkg`, not
  `com.apple.installer-package-archive` (409). Fixed in `upload_asc.py`.

## Not verified — do not claim

- Native Sign in with Apple, HealthKit permission sheet + workout write, rest
  timer notification delivery, haptics, ShareLink, raid card rendering — all
  typecheck-only; none exercised on a device. The raid *server* path is
  verified live.
- Raid reward title/cosmetic is returned by the API but not applied to the
  avatar yet.
- Google sign-in has no client secret configured.

## Next steps (in order)

1. Accept the TestFlight invite (email to danielalanbates@live.com); install build 6 on iPhone + Mac; exercise Sign in with Apple and the HealthKit permission sheet on device.
2. Simulator pass over every iOS screen with `-ef.autologin`, fix what the
   layout helpers missed (set rows, charts, sheets).
3. Apply raid reward title/cosmetic to the profile/avatar; show raid results in
   the feed UI.
4. Delete the smoke accounts + "Smoke Raiders" guild once real users exist.
5. Store listing: privacy policy https://batesai.org/privacy-policy, support
   https://batesai.org/contact, screenshots from `Docs/screenshots/`.

## How to build and verify on this Mac

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# typecheck both platforms (fast)
cd App/Sources/EndgameFitness
xcrun swiftc -typecheck -parse-as-library -target arm64-apple-macos14.0 *.swift
xcrun -sdk iphonesimulator swiftc -typecheck -parse-as-library -target arm64-apple-ios17.0-simulator *.swift
# iOS in the simulator, headless
cd App && xcodegen generate --spec project.yml --quiet
xcodebuild -project EndgameFitness.xcodeproj -target EndgameFitness-iOS -sdk iphonesimulator -arch arm64 \
  -configuration Debug SYMROOT="$HOME/Downloads/endgame-fitness-ship/sim-build" CODE_SIGNING_ALLOWED=NO build
xcrun simctl boot "iPhone 17 Pro"; xcrun simctl install booted "$HOME/Downloads/endgame-fitness-ship/sim-build/Debug-iphonesimulator/Endgame Fitness.app"
xcrun simctl launch booted org.batesai.endgamefitness -ef.autologin <email> <password>
xcrun simctl io booted screenshot shot.png
# ship
security unlock-keychain -p "$(cat ~/Library/Application\ Support/BatesAI/keys/endgame-signing/keychain-password.txt)" ~/Library/Keychains/endgame-ci.keychain-db
scripts/ship.sh both 1.0.0 <build>
```
