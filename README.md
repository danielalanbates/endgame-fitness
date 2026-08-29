# Endgame Fitness

A strength-training app that behaves like a game: you level up, earn talent
points, hold streaks, and your friends can see it. macOS and iOS, one codebase,
signed in through your **batesai.org membership**.

---

## Where things are

```
App/
  Sources/EndgameFitness/     the app — both platforms build from these files
    WorkoutTrackerMac_Enhanced.swift   6,300 lines: tracking, programs, mesocycles,
                                       AI coach cards, calculators, charts, onboarding
    Platform.swift                     every AppKit/UIKit difference, in one file
    BatesAIAuth.swift                  Sign in with Apple / Google / email, Keychain
    GameProfile.swift                  XP, levels, streaks, offline-first sync
    SocialViews.swift                  sign-in, player card, feed, leaderboards, guilds
    RootView.swift                     launch flow: restore -> sign in -> onboard -> app
    AvatarSystem.swift, AvatarViews.swift   character/cosmetics system
  Backend/
    schema.sql                  D1 tables (profiles, sessions, friends, guilds, feed)
    functions/                  Cloudflare Pages Functions — source of truth
    tests/                      security tests for identity-token verification
    deploy.sh                   sync + migrate + deploy
  Support/                      Info.plists and entitlements
  project.yml                   XcodeGen spec (macOS + iOS targets)
Docs/                           design specs worth keeping
Legal/                          disclaimer, ToS, licence
Web/web-react/                  React companion (separate from the native app)
_archive/2026-07-30/            everything retired, with WHY_ARCHIVED.md
```

## Building

**Xcode 26.6 is installed** on the development Mac (since 2026-08-28). Two ways
to build:

```bash
# Fast macOS binary for local verification (seconds, no bundle, no signing)
cd App/Sources/EndgameFitness
xcrun swiftc -parse-as-library -target arm64-apple-macos14.0 -o /tmp/EndgameFitness *.swift

# Real archives (macOS + iOS), signed with the Apple Distribution certificate
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SKIP_UPLOAD=1 scripts/ship.sh both
```

`-parse-as-library` is required for the swiftc path: without it the compiler
treats the file holding `@main` as a script and refuses to build.

## Shipping to TestFlight

`scripts/ship.sh ios|macos|both [version] [build]` — XcodeGen → archive →
export (`App/ExportOptions-iOS.plist` / `-macOS.plist`) → upload through the
App Store Connect Build Upload API (`scripts/upload_asc.py`). Needs the ASC API
key at `~/Library/Application Support/BatesAI/keys/AuthKey_32R84GFV2F.p8` and
**an App Store Connect app record for `org.batesai.endgamefitness`** (see
`Docs/STATUS.md`).

`.github/workflows/testflight.yml` does the same thing on GitHub Actions and is
kept for when the account's Actions billing works again.

## The backend

Profiles live in the shared Cloudflare D1 database `batesai-db`
(`9e43d1f6-b25f-4cab-87da-9669dc4148d2`), alongside the rest of BatesAI
membership. Endpoints are Pages Functions under `/api/auth/*` and `/api/fitness/*`.

```bash
cd App/Backend
./deploy.sh --dry-run                    # see what it would do
./deploy.sh                              # sync workers, migrate, deploy
node tests/auth-verification.test.mjs     # 12 security tests
```

### Sign-in, and why the verification matters

Native Sign in with Apple hands the device a JWT signed by Apple, which the app
trades for a BatesAI session token. No client secret is involved in that
exchange, so **signature verification is the only thing standing between the
endpoint and account takeover**. `functions/api/auth/[[path]].js` verifies the
token against Apple's published JWKS, plus issuer, audience and expiry.

An earlier revision of that worker base64-decoded the token payload *without*
checking the signature — anyone could have minted an identity token for any email
and logged in as that user. `tests/auth-verification.test.mjs` exists so that
cannot come back; it runs in CI.

### Server-authoritative progression

The client uploads what happened (volume, reps, duration). The **server** decides
the XP and the level. A patched client can lie about a single workout, but it
cannot declare itself level 99 on the leaderboard. Session ids are
client-generated UUIDs, so a retried sync is idempotent and can't double-count XP.

Sync is offline-first: workouts queue locally and flush when a connection and a
signed-in user are both available. A workout in a basement gym is never lost.

## Status

See `Docs/STATUS.md` — kept current per session. As of 2026-08-28: backend live at
batesai.org (membership sign-in, sync, quests, achievements, talents, challenges,
friend codes, account deletion all verified end to end from the macOS app);
Xcode 26 installed and archives build locally; TestFlight waits only on the App
Store Connect app record.
