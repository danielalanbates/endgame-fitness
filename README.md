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

There is **no Xcode on the development machine** — Command Line Tools only, and
not enough free disk to install one. That shapes everything:

```bash
# Type-check / build the macOS app locally (this works, and is fast)
cd App/Sources/EndgameFitness
swiftc -parse-as-library -target arm64-apple-macos14.0 -o /tmp/EndgameFitness *.swift
```

`-parse-as-library` is required: without it the compiler treats the file holding
`@main` as a script and refuses to build.

**iOS cannot be compiled locally** (no iOS SDK). Both platforms build in GitHub
Actions on every push — see `.github/workflows/ci.yml`. Treat CI as the authority
on whether the iOS build is healthy.

## Shipping to TestFlight

`.github/workflows/testflight.yml`, run manually. It archives, signs, exports and
uploads through the App Store Connect API with no local Xcode — the same path
that shipped Descend Watch.

Secrets it needs (repository settings): `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_PRIVATE_KEY`, `DEVELOPMENT_TEAM`, `BUILD_CERTIFICATE`, `P12_PASSWORD`,
`PROVISIONING_IOS`, `PROVISIONING_MACOS`.

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

**Working and verified:**

- macOS app compiles clean and runs — 73 view/model types, Charts, full onboarding.
- Auth client, sync engine and social/game UI all compile into the app.
- Backend workers written and syntax-checked; 12/12 security tests passing
  against the real production file.
- **The iOS target compiles.** CI is green on iOS, macOS and the backend tests:
  <https://github.com/danielalanbates/endgame-fitness>

**Not done yet:**

- The backend has **never been deployed**. `https://batesai.org/api/auth/verify`
  still returns the site's HTML. Blocked on `npx wrangler login`, which is
  interactive and has to be run by hand.
- The iOS app has never been **run** — only compiled. iPhone navigation is also
  still wrong (a sidebar, not a tab bar); see the TODO in `Platform.swift`.
- Nothing has been near TestFlight. The App Store Connect app record, signing
  certificates and provisioning profiles do not exist yet.
- The game layer is built but **unproven end to end**, because proving it needs a
  deployed backend and a real signed-in account.
- The macOS UI has not been visually verified since the auth gate was added.

`Docs/STATUS.md` tracks the live version of this list.
