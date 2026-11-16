# Endgame Fitness

A strength-training app that behaves like a game: you level up, earn talent
points, hold streaks, and your friends can see it. **macOS only for now**, no
accounts: local players on the device. Login/backend/iOS are archived in
`_archive/accounts-and-ios-2026-11-16/`.

---

## Where things are

```
App/
  Sources/EndgameFitness/   the macOS app (SwiftUI)
    LocalPlayers.swift      on-device players, backup export/import
    LocalGame.swift         XP, levels, streaks, quests, raids, duels — all local
    SocialTabView.swift     rivals via player-card code/QR, Game Center, Gym Party
    ProgramWizard.swift     Build Your Program (weekly days or X-on / Y-off cycles)
    EngineSelfTest.swift    `-ef.selftest` checks
  project.yml               XcodeGen spec (macOS target)
Docs/                       design notes, STATUS.md (current state)
Legal/                      disclaimer, terms
_archive/                   retired code (online accounts, backend, iOS) + WHY_ARCHIVED.md
```

## Build

```bash
cd App && xcodegen generate --spec project.yml
xcodebuild -project EndgameFitness.xcodeproj -target EndgameFitness-macOS \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
# quick checks
"build/Release/Endgame Fitness.app/Contents/MacOS/Endgame Fitness" -ef.selftest
```

No accounts, no servers: everything is stored on the Mac. The bundle ID
(`org.batesai.endgamefitness`) is kept only so existing players' saved data carries over.

## Status

See `Docs/STATUS.md`.

## Licence

PolyForm Noncommercial 1.0.0 + 10% commercial rider — see `LICENSE`.
Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
Help: https://github.com/danielalanbates/endgame-fitness/issues
