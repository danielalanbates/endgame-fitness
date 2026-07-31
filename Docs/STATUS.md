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
| 2 | **Get the App Store Connect API Issuer ID** — App Store Connect → Users and Access → Integrations → App Store Connect API. The key itself (`AuthKey_32R84GFV2F.p8`) is already on disk; only the issuer UUID is missing, and without it no ASC API token can be minted at all. | Everything below it. |
| 3 | App Store Connect: create the app record for `org.batesai.endgamefitness` | TestFlight. |
| 4 | Generate a distribution certificate + provisioning profiles, add the 8 repo secrets | The TestFlight workflow. |
| 5 | Apple Developer portal: enable the **Sign in with Apple** capability for the bundle id, and register `endgamefitness://` | Native sign-in actually working on device. |
| 6 | Cloudflare dashboard: set `JWT_SECRET`, `OAUTH_GOOGLE_CLIENT_SECRET`, `OAUTH_APPLE_CLIENT_SECRET`, `ALLOWED_ORIGINS` | Real OAuth. The JWT secret currently in the old `wrangler.toml` is a placeholder committed to git and **must be replaced**. |

Item 2 was checked directly: the `.p8` is at
`~/Library/Application Support/BatesAI/keys/AuthKey_32R84GFV2F.p8`, the issuer id
is recorded as MISSING in `CREDENTIALS.md`, and it could not be recovered from
the `batesai-notary` keychain profile. It has to come from the web UI.

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

## CI is live and green

Repo: <https://github.com/danielalanbates/endgame-fitness> (private).

The **iOS target now compiles** — verified in GitHub Actions, run 30601151148,
all three jobs green (iOS, macOS, backend tests). Getting there took four rounds
of real cross-platform errors:

1. `AvatarSystem.swift` used `NSColor`, which does not exist off AppKit →
   `PlatformColor` alias.
2. `SCNVector3` takes `CGFloat` components on macOS and `Float` on iOS →
   `SCNFloat` alias plus an `scn()` helper.
3. The fix for (2) was applied too broadly and broke `SCNSphere`/`SCNCylinder`,
   which take `CGFloat` dimensions on both platforms → reverted those.
4. `HSplitView`, `Process`, `.toggleStyle(.checkbox)`, `windowStyle` and
   `defaultPosition` are all macOS-only → guarded, with `PlatformSplit` added.

CI also caught a workflow bug: pinning the simulator to "iPhone 16" failed on the
runner image before compiling anything. It now uses a generic destination.

After that, iPhone navigation was rebuilt: `ContentView` was putting a fixed
220pt sidebar beside the content on every platform, which would have shipped a
near-unusable phone layout to the first tester. macOS keeps the split view; iOS
gets a `TabView` (Home, Workout, Community, Progress, Programs, then More).

## Not verified — do not claim these work

- **The API has never been deployed.** `/api/auth/verify` returns the site's HTML.
- **No end-to-end sign-in has ever happened.** Not once, on any platform.
- **The iOS app has never been run**, only compiled. Compiling is not running.
- **The iOS tab bar has never been seen.** iPhone/iPad now use a `TabView`
  instead of the desktop sidebar and it compiles, but no one has looked at it on
  a device or simulator.
- **The macOS UI has not been seen since the auth gate was added.** The app built
  and launched, but macOS would not realise a window while a fullscreen game held
  the display; the pristine pre-change build behaved identically, so this is
  environmental rather than a code fault — but the new sign-in screen has still
  never been looked at.

## Next, once unblocked

1. Deploy the API; confirm `/api/auth/verify` returns 401 rather than HTML.
2. Sign in for real on macOS. Confirm a profile row appears in D1.
3. Complete a workout; confirm XP lands and the level bar moves.
4. First TestFlight build, macOS then iOS.

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
