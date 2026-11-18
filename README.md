# Endgame Fitness

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.

Website: https://batesai.org/endgamefitness/ · Support: help@batesai.org

Source: https://github.com/danielalanbates/endgame-fitness

Endgame turns strength training into a long-running game: adaptive plans,
workout history, earned levels and quests, and friend-code training parties.
The web app is published from the BatesAI website repo. BatesAI's existing
Google and Apple membership system is the only login system.

## Current behavior

| Area | Behavior |
| --- | --- |
| Web app | Equipment-aware plans, readiness and recovery adjustments, conservative progression, resumable workout logging, history, XP/levels/quests, unit conversion, backup export/import, and cloud saves with revision checks |
| Social | Private friend codes, mutual invitations, aggregate stats and a weekly consistency quest. No contact import or automatic social posts |
| Login | Existing BatesAI Google/Apple account. Web uses its secure HttpOnly `batesai_session`; Mac uses a Keychain token. The Worker verifies that token against the shared D1 `sessions` table |
| Mac beta | Existing native training engine and local profile. First BatesAI sign-in maps the account to the selected local player so answers and local workouts remain intact |
| Data | Web training records are stored per BatesAI account. Native training history remains on the Mac and does not yet sync with the web format |

## Source map

```text
App/Sources/EndgameFitness/    SwiftUI Mac app and native training/game engines
  MembershipSession.swift    Google/Apple browser sign-in, PKCE handoff, Keychain, local-profile mapping
  SmartPlanner.swift         native adaptive program generator and evaluation
  WorkoutStore.swift         atomic training storage and recovery
  EngineSelfTest.swift       native engine regression checks
Web/local-app/               dependency-free browser app and testable training engine
Server/                      scoped Cloudflare Worker, shared membership session, saves and friends
Docs/                         current status, login handoff, privacy and future pathways
_archive/                     retired Facebook login source and older account approaches
```

## Build and verify locally

Node 22+ (`node:sqlite`), Python 3, Xcode and XcodeGen are used locally. No
GitHub-hosted compute is part of the build or deployment path.

```sh
node --test Web/local-app/tests/*.test.mjs Server/tests/*.test.mjs
node scripts/build-web.mjs
wrangler deploy --config Server/wrangler.toml --dry-run
xcodegen generate --spec App/project.yml
xcodebuild -project App/EndgameFitness.xcodeproj -scheme EndgameFitness-macOS \
  -configuration Release -derivedDataPath "$PWD/.local/DerivedData" \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO build
"build/Release/Endgame Fitness.app/Contents/MacOS/Endgame Fitness" -ef.selftest
```

Use the generated local `.app` for beta testing. Signing and notarization are
still required for a normal downloadable Mac release. Browser regression
checks are in `scripts/verify/web_flow.py`; preview uses
`python3 scripts/preview_web.py` and a local fixture only.

## Website publishing

The website checkout is `../endgame-fitness-website`. Its local deployment
script stages the eight-file Endgame web artifact at
`public/endgamefitness/`, applies its idempotent auth handoff migration, builds
Astro and deploys Cloudflare Pages. The Worker routes only
`batesai.org/api/endgame/*`. Read
[`Server/README.md`](Server/README.md) and the website repo's
`docs/ENDGAME_FITNESS_DEPLOYMENT.md` before changing this boundary.

Deploy the additive D1 profile-link table before the Worker code:

```sh
wrangler d1 execute batesai-db --remote --config Server/wrangler.toml --file Server/migrations/0002_batesai_membership.sql
wrangler deploy --config Server/wrangler.toml
```

## Identity and privacy

- BatesAI membership owns provider sign-in. Endgame receives neither Google nor Apple tokens.
- Web sessions are opaque 256-bit values; D1 stores only SHA-256 hashes. Web cookies are Secure and HttpOnly. Native tokens stay in Keychain.
- Native browser login returns a one-use, 60-second PKCE code; the reusable session token never appears in a custom URL.
- Endgame keeps a stable profile link to the BatesAI user ID. An internal synthetic `batesai:<user-id>` value fills the legacy required `facebook_id` column in the first Endgame schema; no Facebook identifier is stored.
- Deleting Endgame data removes its profile, training state and friendships and revokes the current shared session. BatesAI account deletion also removes the linked Endgame data.
- Keep credentials and personal training backups in ignored local storage or Cloudflare secret storage. Never commit them.

## Known limits and next paths

- Automated tests mock Google/Apple API responses. Complete one real production login with each provider before describing provider integration as end-to-end tested.
- Native and browser training models differ. Design and validate a versioned migration before enabling workout synchronization; never overwrite a native history with the smaller web schema.
- Current friend-code requests are self-reported. Add user controls, block/report flows, and rate limits before broad social promotion.
- The deterministic program generator is conservative guidance, not proof of superiority over a qualified coach or every user-built plan.
- If Endgame's account table is rebuilt, replace the legacy `facebook_id` column with a provider-neutral schema and migrate only after confirming existing `ef_accounts` counts and backups.

## License

PolyForm Noncommercial 1.0.0 with the 10% commercial revenue rider. This is
source available, not an OSI-approved open-source license. See [`LICENSE`](LICENSE).
