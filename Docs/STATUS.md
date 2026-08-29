# Endgame Fitness — status and next actions

_Updated 2026-08-28 (autonomous session; supersedes the 2026-08-18 status)._

Goal: world-class fitness app that blurs social game and training log; profiles
via batesai.org membership; TestFlight on macOS + iOS.

## What changed today (all verified unless marked)

- **Merged the long-open feature branch into main** (PR #2, was PR #1
  `feat/membership-sessions-live`): quests + achievements, talent tree with
  server-side XP effects, friend duels / guild challenges, Account screen,
  Program Wizard, opaque sessions shared with the website (`users.oauth_id`,
  no JWT secret). Two conflict hunks (route table, schedule persistence) —
  main's persistence kept, both route tables kept.
- **Backend re-deployed to production.** A 2026-08-22 website deploy had
  silently dropped the fitness API (`/api/auth/verify` returned the SPA HTML).
  The functions now also live in the **website repo** (website PR #6) so the next
  site deploy keeps them. `_lib/auth.js` on the website accepts the app's Bearer
  token, so `/api/auth/me` and `/logout` work for native clients too.
- **In-app account deletion** — `DELETE /api/auth/account` (+ `Delete account…`
  in Account with confirmation). One D1 batch (transactional) clears every
  fitness table, hands owned guilds to the longest-serving member, deletes the
  user. App Store Review 5.1.1(v) needs this; the old "delete on batesai.org"
  link pointed at a page that does not exist. Verified: register → delete →
  token dead → login fails.
- **Friend codes** — `fitness_profiles.friend_code` (6-char, lazily generated,
  unique partial index; column added to the live D1 by hand). Friends pane shows
  your code with Copy and one "Friend code or email" field;
  `POST friends/request {query}` accepts either. Bad code → 404 shown inline.
- **PR detection now real** — the client uploads completed sets per exercise
  (`payload.exercises[].sets[]{reps,weight}`); the server's
  `recordPersonalRecords` was a documented no-op before. Verified: Bench 225×5
  → `personal_records` row + `pr` feed item; "New Heights" quest can fire.
- Settings: "Sec-onds"/"Goal" placeholder labels no longer render in the
  grouped form (`labelsHidden()`).
- **Xcode 26.6 installed on this Mac** (App Store, via Accessibility — `mas`
  needs sudo). `xcodebuild` works with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; the licence was
  already accepted system-wide. This removes the GitHub-Actions dependency:
  `scripts/ship.sh ios|macos|both` archives, exports and uploads locally.
  Provisioning profiles `Endgame Fitness IOS_APP_STORE` / `MAC_APP_STORE` are
  downloaded from ASC into `~/Library/MobileDevice/Provisioning Profiles`.
- macOS app driven end-to-end against live membership (smoke account):
  sign-in → dashboard → Community (feed, leaderboard, friends, guild,
  challenges, quests, achievements) → talents sheet → settings/account.
  Screenshots: `Docs/screenshots/2026-08-28-macos/`.

## Live API smoke (2026-08-28)

```
POST /api/auth/login          -> token (43 chars, opaque)
GET  /api/auth/verify         -> {"valid":true,"user":{...,"membership":"free"}}
GET  /api/auth/me             -> {"signedIn":true,...}   (website endpoint, Bearer accepted)
GET  /api/fitness/profile     -> level 3, friend_code "F5BEP6"
GET  /api/fitness/quests      -> daily: Show Up / Hype Squad / Move Iron; weekly: Party Up / New Heights
GET  /api/fitness/talents     -> tree v1, 3 branches
GET  /api/fitness/achievements-> catalog + unlocked
GET  /api/fitness/challenges  -> {pending:[],active:[],finished:[]}
POST /api/fitness/sync (with payload) -> xp_gained 264, levels_gained 1, PR recorded
DELETE /api/auth/account      -> {"deleted":true}
```

Test accounts on the live DB: `ef-smoke-test@batesai.org` / `smoketest-pass-123`
(level 3), `ef-friend-test@batesai.org` / `friendtest-pass-123` (level 3, has a
pending request to Smoke). Delete them once real users exist.

## Blocked on Daniel

1. **App Store Connect app record for `org.batesai.endgamefitness`** — still the
   only thing between the signed builds and TestFlight. The ASC REST API cannot
   create it, `xcodebuild -exportArchive destination=upload` does not create it,
   the Chrome extension is not connected on this Mac, and no browser has an ASC
   session. Create it: appstoreconnect.apple.com → My Apps → **+** → New App →
   platforms **iOS + macOS**, name **Endgame Fitness**, primary language
   English (U.S.), bundle id **org.batesai.endgamefitness**, SKU
   **endgame-fitness**. Then run `scripts/ship.sh both` (or the daily
   `testflight.yml` once billing is fixed) — nothing else is needed.
2. GitHub Actions billing (Settings → Billing & plans): every job still dies in
   3s. Not needed any more for shipping (local Xcode), but CI on push is dead
   until it is fixed.
3. Optional after the first build lands: TestFlight internal group; App Store
   listing needs a privacy policy URL (https://batesai.org/privacy-policy exists)
   and a support URL (https://batesai.org/contact).

## Not verified — do not claim

- Native **Sign in with Apple** has never been exercised (needs a signed bundle
  on a device/TestFlight; the capability is on the App ID and the entitlement is
  in both targets). Google sign-in has no client secret configured.
- iOS UI: see the "iOS" section below for what was and was not run today.
- Avatar editor round-trip and `avatar_config` reader.
- Health/HealthKit integration is described in Info.plist strings but not wired.

## How to build and verify on this Mac

```bash
# fast macOS binary (no bundle, no signing)
cd App/Sources/EndgameFitness
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -o /tmp/EF *.swift
security delete-generic-password -s org.batesai.endgamefitness -a session-token  # see below
nohup /tmp/EF &

# real archives / TestFlight
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SKIP_UPLOAD=1 scripts/ship.sh ios      # archive + export only
scripts/ship.sh both 1.0.0 42          # + upload (needs the app record)
```

Driving the UI without stealing focus: `scripts/verify/ax.py` (AX tree walk),
`screencapture -x -l <windowid>` (works while occluded), `CGEventPostToPid`
for typing. See `scripts/verify/drive.py`.

**Keychain trap:** a rebuilt unsigned binary reading the token the previous
build stored pops a SecurityAgent password dialog on screen; the dialog outlives
the app and ignores synthetic clicks. Delete the item before relaunching; if the
dialog is already up, `kill -9 $(pgrep -x SecurityAgent)`.

## Where things run

- API: Cloudflare Pages project `website` (batesai.org), D1 `batesai-db`
  (`9e43d1f6-b25f-4cab-87da-9669dc4148d2`). Deploy = `~/.git/dist` (the live
  site's built output — the GitHub website repo's `dist/` lacks /qola, /play)
  + `functions/` from the website repo, `wrangler pages deploy dist
  --project-name=website --branch=main` from a non-iCloud directory.
  `App/Backend/deploy.sh` automates the functions part.
- Secrets on Pages: OPENROUTER_API_KEY (AI coach), APPLE/GOOGLE client secrets,
  Stripe. No JWT_SECRET exists and none is needed.

## Ideas queued (not started)

- Weekly leagues (Bronze/Silver/Gold divisions by weekly XP from
  `xp_transactions`), promotion/relegation on Monday.
- Guild chat / shout-outs; push notifications for duel invites and friend
  requests (needs APNs — the ASC key can mint the token).
- Apple Watch companion for set logging; HealthKit write-back.
- Cosmetic titles unlocked by achievements (schema has `title`).
