# Talents and Account — design, endpoints, verification

_Branch `feat/talents`, 2026-08-18._

## Talent tree

Definition lives in one dependency-free module, `App/Backend/functions/_lib/talents.js`,
imported by the fitness worker and by the tests. The client never hardcodes the tree; it
renders whatever `GET /api/fitness/talents` returns (`tree.version` for future migrations).

Three branches, three tiers. Tier N needs `(N-1)*3` points spent in that branch plus the
node's explicit prerequisites. One talent point per level (unchanged) plus milestone bonuses.

| Branch | Node | Ranks | Effect (server-side) |
|---|---|---|---|
| Strength | Iron Foundation | 5 | +2%/rank XP on sessions >= 5,000 lb |
| Strength | Heavy Hands (Iron 3) | 3 | +3%/rank XP on sessions >= 15,000 lb |
| Strength | Titan (Heavy 3) | 1 | +1 talent point every 10th level |
| Endurance | Momentum | 5 | +5%/rank XP on every workout |
| Endurance | Streak Shield (Momentum 3) | 2 | streak survives 1 missed day per rank |
| Endurance | Second Wind (Shield 1) | 3 | +4%/rank XP while streak >= 7 |
| Community | Rally | 5 | +1%/rank XP per accepted friend, max 5 friends |
| Community | Guild Banner (Rally 3) | 3 | +3%/rank XP while in a guild |
| Community | Mentor (Banner 2) | 1 | +1 talent point every 5th level |

XP percentages are additive: `xp = round(base * (1 + sum_pct/100))`.

### Where effects are applied (`functions/api/fitness/[[path]].js`, handleSync)
- Ranks, friend count and guild membership are loaded once per sync.
- Streak is now computed **before** XP so Second Wind sees the streak the session produces.
- `streakAfter(last, day, shieldDays)` forgives up to `shieldDays` missed days.
- `talent_points = talent_points + levelsGained + bonusTalentPoints(ranks, before, after)`;
  the sync response gains `talent_points_gained`.
- Effects use the ranks as they were at the start of the sync (a spend mid-sync is not
  retroactive).

### Endpoints (all Bearer-authenticated)
- `GET  /api/fitness/talents` -> `{ tree, ranks: {id: rank}, unspent, spent }`
- `POST /api/fitness/talents/spend` `{ talent_id }` -> 409 with a reason on any rule
  failure; success returns the new state. The decrement is `WHERE talent_points > 0` and the
  rank upsert is `WHERE rank < max`, batched in one D1 transaction, so racing requests
  cannot overspend.
- `POST /api/fitness/talents/respec` -> deletes all `talents` rows, refunds `spent` points.
  Free for now.

Storage: existing `talents (user_id, talent_id, rank)` + `fitness_profiles.talent_points`.
No schema change.

## Client
- `GameProfile.swift`: `TalentBranch/TalentNode/TalentTree/TalentState` models (mirrors the
  tier/prereq rule only to grey out buttons), `talents` published state,
  `loadTalents() / spendTalent(_:) -> String? / respecTalents()`.
- `TalentViews.swift`: `TalentPointsBadge`, `TalentTreeView` (segmented branch picker,
  vertical node column with lit prerequisite lines, +/checkmark spend button with blocker
  tooltip, Reset with confirmation), `TalentNodeCard`.
- `AccountView.swift`: membership email + tier (from `BatesAIUser.membership`, i.e.
  `/api/auth/verify`), display name + title (PUT profile), Talents row, avatar editor
  (`AvatarQuestionnaireView`, saved into `avatar_config`), sign out (confirm), links to
  https://batesai.org/members for manage / delete.
- Hooks: `PlayerCardView` — avatar tap opens Account; unspent-points badge and the
  "Talents" stat open the tree (so Community + anywhere the card is shown gets both).
  `SettingsView` — new "Account" section at the top (macOS sidebar + iOS More tab).

## Verified
- `swiftc -parse-as-library -target arm64-apple-macos14.0 *.swift`: 0 errors.
- `node --check` on every backend JS/MJS file: clean.
- `node tests/talents.test.mjs`: 20 passed (tree integrity, all validation rules, every
  effect kind, milestone points, `streakAfter` shield behaviour extracted from the worker).
- `node tests/auth-verification.test.mjs`: 12 passed.

## Not verified
- Nothing has run against a real D1 (API still never deployed — see STATUS.md); the
  `ON CONFLICT ... DO UPDATE ... WHERE` and `env.DB.batch` result shape (`meta.changes`)
  are per Cloudflare docs, untested live.
- No UI has been looked at; iOS only compiles in CI (not run here).
- Avatar editor round-trip to `avatar_config` is wired but the app has no reader for it yet.
- iOS: `LabeledContent`, `formStyle(.grouped)`, `NavigationStack` need iOS 16+ (target is 17).
