# Endgame Fitness — current state (2026-11-18)

The latest user instruction supersedes local-only login: **Facebook is the sole sign-in provider**. Existing local-player records remain the native storage model; they are not a second login provider.

## Delivered implementation

- Reconciled `main` with the newer `worldclass-2026-11-16` native branch; resolved conflicts toward the local training/game implementation rather than resurrecting old membership auth.
- Native Facebook gate, Keychain session, browser authentication and PKCE-bound single-use callback exchange. First Facebook connection adopts the existing selected profile once, preserving its log and onboarding answers. Subsequent Facebook accounts map to separate profiles.
- Dependency-free responsive browser app: preference onboarding, equipment-aware plans, readiness-based recovery, every-fifth-week volume reduction, rep-reserve progression, active-session recovery, rest timer, history, XP, quests, units, backups and exercise guide.
- Server-side Facebook identity verification; secure session handling; validated account-only cloud records with optimistic revisions; mutual friend invitations and aggregate-only party stats; deletion endpoint and privacy/deletion instructions.
- Scoped Worker deployment targets `/endgamefitness*` and `/api/endgame/*`, preserving the rest of the website. Added only isolated `ef_` database tables.
- No automatic GitHub workflows. Local `.app` is the beta artifact. Keep public release as a prerelease until the external sign-in path is verified.

## Verification evidence

| Check | Result / boundary |
| --- | --- |
| Native regression selftest | **304/304 PASS** on the consolidated native engine; includes planner, progression, data recovery and game rules. These tests do not prove clinical superiority. |
| Native Facebook sources | Swift compile succeeds; full Release `.app` build succeeds. Live authentication remains unverified. |
| Web/backend tests | **43/43 PASS**, including full plan matrix, earned quest claims, progression, replay prevention, mocked successful Facebook exchange, PKCE one-use codes, session expiry, ownership, conflicts, friendships, deletion and validation. Provider responses are mocked, not real Meta credentials. |
| Browser workflows | Pass in headless Chromium at desktop and 390px mobile: unavailable login, mocked authenticated onboarding, workout resume after reload, finish/XP, quests, main tabs, unit conversion, backup export/import, exercise search and invitation acceptance. No JavaScript errors or horizontal overflow observed. |
| Live deployment | App entry and scoped privacy page return 200. `/config` returns `facebook:false`; `/auth/start` returns 503. Real Chromium loads the production entry and privacy page with no JavaScript errors. Worker version `e9da6f85-072c-418b-98df-2021a19b9c8e` verified after final fixes. |
| Candidate source scan | Gitleaks found no leaks in the candidate source snapshot; ignored browsers/build artifacts excluded. |

Screenshots and raw test logs are private working artifacts in `.local/` (test player only). Do not publish real player data.

## Current external blocker

The Endgame Worker is deployed, but `wrangler secret list --config Server/wrangler.toml` returned an empty list at the latest check. Production `/api/endgame/config` returns `facebook:false` and `/api/endgame/auth/start` returns `503` with `FACEBOOK_NOT_CONFIGURED`. A public/live Meta application and successful testing with a non-role Facebook account are still required. See `Server/README.md` for exact setup; never ask the user to paste the secret into chat or source.

The setup values and credential search are recorded in [`FACEBOOK_SETUP.md`](FACEBOOK_SETUP.md). The Google Drive Code `Documentation` folder had no Endgame/Facebook credential file or matching app-key declarations; its `Project_Management_Meta` environment pointer leads to alert-email settings, not Facebook credentials. The secure key store also had no Facebook App ID or App Secret. A read-only browser report identified an existing BatesAI Meta app in Development mode, but its Facebook Login settings and App Secret remain unverified. No choice between reusing that app and creating a dedicated Endgame app is recorded.

The Meta developer dashboard was visible in the signed-in browser, but this review did not inspect app settings or change Meta configuration. No credentials were retrieved, and no app, permissions or Meta settings were created or changed.

## Known limitations and follow-up work

1. **No real Facebook end-to-end test yet.** Do not advertise the app as publicly usable or bug-free merely because the landing page is online.
2. **Native and web logs remain separate.** Native has a substantially richer planner/library and game world. Web is a usable training companion once login is configured, not feature parity. Build a versioned, lossless bridge before cloud-syncing native records.
3. Native social systems retain household/rival/Game Center/Gym Party capabilities; the web uses Facebook-authenticated friend codes. No automatic Facebook friend import and no automatic social posts.
4. Web rules are conservative heuristics informed by resistance-training research; they are not a mathematical proof that arbitrary user programs are inferior. Avoid optimizing a scoring function and presenting its own scores as independent outcome evidence.
5. Native online friend UI parity, signed/notarized distribution, real-device notifications, accessibility/VoiceOver over every native screen and cross-device concurrency under real workloads still need dedicated verification.
6. Add scheduled expiry cleanup, request-level abuse protection and granular session sync before scaling a public launch.
7. Bodyweight-only web plans have limited loaded pulling options; make bands/anchor equipment a future preference rather than pretending an unweighted W raise is equivalent to a loaded row.
8. The web 3 MB backup/save limit is deliberate. Design pagination and per-session storage before removing it.
9. Keep the existing bundle ID, player mapping, onboarding flags and WorkoutStore recovery behavior. Never replace old logs with empty or simplified web data.

## Research references

- [ACSM progression position stand](https://pubmed.ncbi.nlm.nih.gov/19204579/) supports progressive resistance training; our precise rounding/decision rules are implementation choices.
- [Proximity-to-failure meta-regression](https://pubmed.ncbi.nlm.nih.gov/38970765/) motivates tracking reps in reserve, with uncertainty about individual response.
- [2026 ACSM overview](https://pmc.ncbi.nlm.nih.gov/articles/PMC12965823/) is the newer guidance to evaluate in the next training-engine review.
- [Meta Graph version documentation](https://developers.facebook.com/docs/graph-api/changelog/versions/) was checked; this integration pins v27.0 and allows an explicit validated override.

Earlier notes are in `STATUS_LEGACY.md`; archived account and iOS approaches remain under `_archive/` with their original rationale. Some older documents describe obsolete membership behavior; use this file and `Server/README.md` as current guidance.
