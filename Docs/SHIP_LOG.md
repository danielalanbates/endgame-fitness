# Ship log — App Store Connect / TestFlight

App: **Endgame Fitness RPG** · ASC app id `6806675925` · bundle `org.batesai.endgamefitness` · team MG4YW8XX2Z

| Date | Build | Platform | Result | Notes |
|---|---|---|---|---|
| 2026-08-29 15:55 | 1.0.0 (3) | iOS | FAILED (90022, 90023, 90713) | No asset catalog in the bundle — `project.yml` used a `resources:` key xcodegen ignores. |
| 2026-08-29 16:05 | 1.0.0 (3) | macOS | FAILED (90236, 90296) | Same missing icon + no App Sandbox entitlement. First attempt 409'd on UTI (`com.apple.installer-package-archive` → `com.apple.pkg`). |
| 2026-08-29 16:13 | 1.0.0 (4) | iOS | **VALID** | Asset catalog fixed. Entitlements were EMPTY (xcodegen rewrites the file) — no HealthKit. |
| 2026-08-29 16:20 | 1.0.0 (4) | macOS | FAILED (90296) | Sandbox still missing for the same xcodegen reason. |
| 2026-08-29 16:30 | 1.0.0 (5) | both | EXPORT FAILED | ExportOptions plists still named the 2026-08-28 profiles; `healthkit.access` entitlement needs Apple approval (Verifiable Health Records). |
| 2026-08-29 16:40 | 1.0.0 (6) | iOS | **VALID** | Entitlements: applesignin + healthkit. Assets.car + icons present (verified by unzipping the .ipa). |
| 2026-08-29 16:47 | 1.0.0 (6) | macOS | **VALID** | Entitlements: app-sandbox, network.client, files.user-selected.read-write, applesignin. |

TestFlight: internal group "Internal" (`b13fa61b-40a2-4809-b2e4-c38137c13225`, access to all builds);
tester danielalanbates@live.com invited 2026-08-29 (state INVITED — accept the email on the
iPhone/Mac, then builds 6 appear in the TestFlight app).

## Recipe that works (2026-08-29)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
security unlock-keychain -p "$(cat ~/Library/Application\ Support/BatesAI/keys/endgame-signing/keychain-password.txt)" \
  ~/Library/Keychains/endgame-ci.keychain-db
scripts/ship.sh both 1.0.0 <next build number>      # ~6 min per platform incl. processing poll
```

Rules learned the hard way:
- Entitlements live in `project.yml` → `entitlements.properties`. Never edit the
  `.entitlements` files; xcodegen overwrites them on every generate.
- Asset catalog is listed under `sources:` (xcodegen has no `resources:` key).
- Profile names appear in THREE places: `scripts/ship.sh`, `App/ExportOptions-iOS.plist`,
  `App/ExportOptions-macOS.plist`. Regenerate profiles (ASC API) whenever a capability
  changes on the App ID; the old ones flip to INVALID.
- Build numbers must increase per upload even when the previous one failed processing.
- The store name "Endgame Fitness" is taken by another developer; the record is
  "Endgame Fitness RPG". `CFBundleDisplayName` stays "Endgame Fitness".
- `/Applications/Endgame Fitness.app` = macOS archive re-signed ad-hoc (`codesign --force
  --deep --sign -`), which drops the sandbox entitlements — fine for local use. On first
  launch macOS asks for Documents access (the app reads/writes `~/Documents`; the sandboxed
  store build uses its container instead).
