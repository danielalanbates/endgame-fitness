# Endgame Fitness — status and next actions

_Updated 2026-08-18 (autonomous session)._

Goal: world-class fitness app that blurs social game and training log; profiles
via batesai.org membership; TestFlight on macOS + iOS.

## Done today (all verified unless marked)

- **Backend deployed and LIVE for the first time** at batesai.org. Sessions are
  now opaque tokens in the shared `sessions` table — the SAME store as the
  website's `batesai_session` cookie. One membership: an app token works on the
  web (`/api/auth/me`), a web cookie works on the API. No JWT secret exists.
  `users.oauth_sub` → `oauth_id` to match the live D1 schema.
- Live E2E: register → verify → profile → sync (XP awarded, level 3) → leaderboard
  → feed → friends; talents + challenges endpoints answer with data.
- **macOS app signed in end-to-end against the live membership** (email/password,
  smoke account) and reached onboarding — screenshot-verified via
  `screencapture -l <windowid>` (see "Driving the app" below).
- Apple provisioning done via ASC API (issuer id
  `67d2d531-0ef2-43f5-8319-7505313c9fd1`, key 32R84GFV2F — the "missing issuer
  id" note in older docs is obsolete): bundle id `org.batesai.endgamefitness`
  (T2W6UNZRXK, Sign in with Apple enabled), Apple Distribution cert GZ99693JK5,
  Mac Installer cert 7UP5CX57GL (CN "3rd Party Mac Developer Installer"),
  profiles MHL4MBRX5T (iOS App Store) / VQH6V88785 (Mac App Store). Private key
  + p12s live only in repo secrets and the workspace (never committed).
- All CI secrets set. **iOS archive builds and signs green in CI.** macOS
  archive builds; .pkg signing fixed (identity name) — last run pending.
- Feature work merged on `feat/membership-sessions-live`: talent tree with
  server-side effects (XP multipliers, streak shield), Account screen (tier,
  name/title, sign out), challenges (friend duels / guild, standings computed
  from workout_sessions, lazy settlement), Today dashboard cluster. Node tests:
  auth 12/12, talents 20/20, challenges 7/7. macOS swiftc build: 0 errors.
- Quests + achievements are complete on branch `feat/quests` (build green,
  tests 8/8) but NOT merged: three branches touched the same regions of
  `GameProfile.swift` / `SocialViews.swift` / `fitness/[[path]].js` and the
  merge needs a careful hand-merge (additive on both sides). Do this next.

## Blocked on Daniel

0. **GitHub Actions billing**: as of 2026-08-18 evening every runner job fails
   in 4s with "recent account payments have failed or your spending limit
   needs to be increased" (github.com -> Settings -> Billing & plans). The 3-hour
   hung macOS job (productbuild timestamp hang, since fixed with
   --timestamp=none + a 30-min job timeout) probably burned the limit —
   macOS minutes bill at 10x. Until this is fixed neither CI nor TestFlight
   runs at all.

1. **Create the App Store Connect app record**: My Apps → + → New App →
   platforms iOS + macOS, name "Endgame Fitness", bundle id
   `org.batesai.endgamefitness`, SKU `endgame-fitness`. The REST API cannot
   create it; `xcodebuild -exportArchive destination=upload` was tried and does
   NOT create it either ("Error Downloading App Information"); Chrome has no
   ASC session. **Nothing else is needed**: `testflight.yml` runs daily at
   15:17 UTC, resolves the app id from the bundle id, and will upload both
   platforms the first day the record exists (or run it manually).
2. Optional: internal tester group in TestFlight after the first build lands.

## Not verified — do not claim

- iOS has never been RUN (only archived). Native Sign in with Apple never
  exercised (needs a signed bundle → TestFlight). Google OAuth secrets not set.
- New feature UIs (talents, account, challenges, today cards) compiled but not
  yet rendered/screenshotted; quests branch unmerged.

## Driving the app for verification (works while occluded, no focus stealing)

Build: `swiftc -parse-as-library -target arm64-apple-macos14.0 -o /tmp/EF App/Sources/EndgameFitness/*.swift`
(no `-O`, it fails to link on this Mac). Launch with `nohup ./EF &`. Find the
window id with Quartz `CGWindowListCopyWindowInfo` filtered by pid;
`screencapture -x -l <id>` captures it even when covered. Fill fields with
pyobjc `ApplicationServices` (AXFocused on the text field, then
`CGEventPostToPid` unicode key events — AXValue alone does not update SwiftUI
bindings; System Events `keystroke` goes to whatever is frontmost, don't).
Buttons: `AXUIElementPerformAction(el,'AXPress')`. Scripts: scratchpad
`ax.py`, `pidtype.py`, `ax_signin.py` (copied to `scripts/verify/`).

## Deploying the backend

`App/Backend/deploy.sh` (wrangler is authenticated on this Mac now): clones the
website repo, copies `functions/`, applies `schema.sql` (idempotent), deploys
with `--branch=main` (without it the deploy lands on a preview URL only — that
bit me once). Website PR #4 tracks the functions in the website repo.
