# Endgame Fitness — status and next actions

_Updated 2026-07-30._

The goal: a world-class fitness app that blurs the line between a social game and
a training log, with profiles signed in through batesai.org membership, shipped
to TestFlight on macOS and iOS.

## Blocked on Daniel

These cannot be done non-interactively. Everything else is waiting behind them.

| # | Action | Unblocks |
|---|--------|----------|
| 1 | `npx wrangler login` | Deploying the API and creating the D1 tables. Nothing about profiles, XP, friends or leaderboards can be proven until this happens. |
| 2 | Create a GitHub repo and add it as a remote | CI, which is the **only** way the iOS build gets compiled at all. |
| 3 | App Store Connect: create the app record for `org.batesai.endgamefitness` | TestFlight. |
| 4 | Generate a distribution certificate + provisioning profiles, add the 8 repo secrets | The TestFlight workflow. |
| 5 | Apple Developer portal: enable the **Sign in with Apple** capability for the bundle id, and register `endgamefitness://` | Native sign-in actually working on device. |
| 6 | Cloudflare dashboard: set `JWT_SECRET`, `OAUTH_GOOGLE_CLIENT_SECRET`, `OAUTH_APPLE_CLIENT_SECRET`, `ALLOWED_ORIGINS` | Real OAuth. The JWT secret currently in the old `wrangler.toml` is a placeholder committed to git and **must be replaced**. |

## Done

- Consolidated 109 root entries down to 7. Six competing trackers, a vendored
  `wger-flutter` clone, unrelated business tooling and ~40 contradictory status
  reports moved to `_archive/2026-07-30/` with a manifest. Nothing deleted.
- Put the project under git for the first time.
- Confirmed the 6,314-line macOS app compiles clean and runs. (The 2026-07-02
  architect review calling it "FREEZE — not shippable" was wrong.)
- `Platform.swift`: all AppKit touchpoints behind `#if os(...)`, so one source
  tree targets macOS and iOS.
- Auth: Sign in with Apple (native, nonce-protected), Google via
  `ASWebAuthenticationSession`, and email/password. Session token in the
  Keychain, not UserDefaults.
- Backend: auth worker with **real JWKS signature verification**, replacing an
  unverified base64 decode that was an account-takeover hole. Fitness API for
  profiles, sync, feed, leaderboards, friends and guilds. 12 security tests.
- Game layer: server-authoritative XP and levels, streaks, talent points, rank
  titles, activity feed with reactions, three leaderboard scopes, guilds,
  level-up celebration.
- Build system: XcodeGen spec with macOS + iOS targets, CI workflow, TestFlight
  workflow.

## Not verified — do not claim these work

- **The API has never been deployed.** `/api/auth/verify` returns the site's HTML.
- **The iOS target has never been compiled.** No local iOS SDK exists.
- **No end-to-end sign-in has ever happened.** Not once, on any platform.
- **The macOS UI has not been seen since the auth gate was added.** The app built
  and launched, but macOS would not realise a window while a fullscreen game held
  the display; the pristine pre-change build behaved identically, so this looks
  environmental rather than a code fault — but it is unconfirmed either way.

## Next, once unblocked

1. Deploy the API; confirm `/api/auth/verify` returns 401 rather than HTML.
2. Push to GitHub; get a green iOS build. Expect real compile errors — 6,300
   lines written for macOS have never seen the iOS SDK.
3. Sign in for real on macOS. Confirm a profile row appears in D1.
4. Complete a workout; confirm XP lands and the level bar moves.
5. First TestFlight build, macOS then iOS.

## Deliberate design decisions

- **Server owns progression.** The client reports volume/reps/duration; the
  server computes XP. Otherwise the leaderboard is fiction.
- **Sync is idempotent.** Client-generated UUIDs as session ids, so a retry can't
  double-count XP.
- **Offline-first.** Workouts queue locally and flush later; gyms have bad signal.
- **Apple `(provider, sub)` is the identity key, not email.** Apple's private
  relay addresses rotate; matching on email would fracture accounts.
- **Sign-in comes before onboarding.** The onboarding answers belong on the
  server profile, so we need to know who the person is first.
