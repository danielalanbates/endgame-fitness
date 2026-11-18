# Endgame Fitness

Strength training with game progression and a training party. **Facebook is the only sign-in provider** (updated November 18, 2026).

- Website: **https://batesai.org/endgamefitness/**
- Support: **help@batesai.org** · https://batesai.org
- Source: https://github.com/danielalanbates/endgame-fitness
- Status: **public beta; real Facebook sign-in requires Meta app configuration**. No stable release or universal superiority claim is made.

| Area | Current behavior |
| --- | --- |
| Web | Equipment-aware strength plans, readiness/recovery sessions, conservative double progression, resumable workout logging, history, XP/levels/quests, unit conversion, export/import, account saves with conflict protection |
| Social | Facebook identity, private friend codes, mutual invitations, aggregate stats and a weekly consistency challenge. No automatic posts or Facebook contact import. |
| Mac beta | Existing full native training engine, 876-exercise library, game systems and native social features; Facebook gate and PKCE browser handoff added. Existing selected profile and answers adopted once on first Facebook connection. |
| Identity | Secure 30-day sessions; HttpOnly cookie on web, Keychain on Mac. No email, Google, Apple or guest login in the new Endgame entry points. |
| Data | Web data stays in per-account browser storage and private Cloudflare D1 records. Native logs remain on the Mac. **Native and web logs do not yet sync.** |

## Source map

```text
App/Sources/EndgameFitness/    SwiftUI Mac app and native training/game engines
  FacebookSession.swift      Facebook-only sign-in, PKCE, Keychain, existing-player mapping
  SmartPlanner.swift         native adaptive program generator and evaluation
  WorkoutStore.swift         atomic training storage and recovery
  EngineSelfTest.swift       native engine regression checks
Web/local-app/               dependency-free browser app and testable training engine
Server/                     scoped Cloudflare Worker, Facebook OAuth, account saves and friends
Docs/FACEBOOK_SETUP.md       Meta app settings, credential audit, and release checklist
Server/README.md             deployment, Meta setup and security details
Docs/STATUS.md              verification results, known limits and next actions
Docs/STATUS_LEGACY.md        earlier development notes (historical, not current behavior)
_archive/                   retired account/iOS features and superseded approaches
```

## Check and build locally (no GitHub compute)

Node 22+ (with `node:sqlite`), Python 3, Xcode and XcodeGen are used locally.

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

Browser regression checks are in `scripts/verify/web_flow.py` (Python Playwright). Start `python3 scripts/preview_web.py` for the local fixture server; it never creates a real authenticated session. Keep browser downloads and screenshots in ignored `.local/`.

Use the generated local `.app` for beta testing. Signing/notarization and verified real Facebook login are required before treating a downloadable Mac build as a stable public release. A source checkout and local build do not require GitHub Actions.

For website deployment and the exact Meta redirect URI, see [Server/README.md](Server/README.md). Build artifacts include only eight allowlisted web assets, excluding tests and development files. The Worker intercepts only Endgame routes and does not rebuild the rest of BatesAI.

## Privacy and licensing

Keep credentials, test exports, training data and logs in ignored `.local/` or environment/secret storage. Never commit them. Privacy and deletion instructions are published at `/endgamefitness/privacy.html`.

PolyForm Noncommercial 1.0.0 plus the existing 10% commercial rider: see [LICENSE](LICENSE). This is source available, not an OSI open-source license. Exercise data attribution is retained in the project. Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
