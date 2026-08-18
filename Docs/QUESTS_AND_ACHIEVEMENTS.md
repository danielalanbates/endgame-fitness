# Quests & Achievements

_Added 2026-08-18 on branch `feat/quests`._

The "game loop" layer: a daily/weekly quest board and an achievement wall, both
server-authoritative, both paying XP through the same `xp_transactions` path as
workouts and posting to `activity_feed`.

## Design

- **Deterministic generation, no scheduler.** A user's board for a given day/week
  is `pickDeterministic(catalog, n, "<user>|daily|YYYY-MM-DD")` (FNV-1a seed →
  xorshift Fisher–Yates). Same user + period → same quests, so the board is
  materialised lazily on any read/event with `INSERT OR IGNORE` under a
  deterministic id `user:kind:period:quest_key`. No new tables: the existing
  `quests` table already had every column needed. Periods are UTC; daily resets
  at 00:00Z, weekly on Monday 00:00Z (ISO week).
- **Progress is server-side.** `advanceQuests(env, userId, event)` is called
  from `handleSync` (per accepted new session), from `feed/:id/react`
  (reactions to others' posts), and from `friends/respond` on accept (both
  users). Progress caps at target; hitting target sets `completed_at`.
- **XP is paid on claim**, not on completion — `POST quests/:id/claim` flips
  `claimed` with a `claimed = 0` guard (double-tap safe), then `awardXp()` writes
  `xp_transactions(reason='quest')`, updates level/talent points, and posts a
  `quest` feed item (and `level_up` if applicable).
- **Achievements** are rules over a stats snapshot (`level, total_workouts,
  total_volume, longest_streak, friend_count, in_guild`). `checkAchievements`
  runs after `handleSync`'s profile update, on friend accept, on guild
  create/join. Unlock → `INSERT OR IGNORE achievements` (guarded by
  `meta.changes`), XP with `reason='achievement'`, `achievement` feed item. It
  re-runs once after paying so level-based rules that just became true unlock
  in the same request. `handleSync` returns `achievements_unlocked: [ids]`.
- **PR detection** was added to `handleSync` (`recordPersonalRecords`) so the
  "Set a PR" quest can fire: it walks `payload.exercises[].sets[]{weight,reps}`
  and upserts `personal_records` (Epley e1RM). The native client currently
  uploads aggregates only, so this is a no-op until the client sends the
  exercise tree — documented gap.

## Endpoints (all under `/api/fitness/`, Bearer session token)

| Method | Path | Returns |
|---|---|---|
| GET | `quests` | `{ daily:[Quest×3], weekly:[Quest×2], server_time }` |
| POST | `quests/:id/claim` | `{ success, xp_gained, levels_gained, quest }` — 404 unknown, 409 not complete, idempotent if already claimed |
| GET | `achievements` | `{ achievements:[{id,title,desc,rarity,xp,icon,unlocked,unlocked_at}], unlocked_count, total_count }` |

Quest shape: `{ id, quest_key, kind, title, description, icon, metric, target, progress, xp_reward, expires_at, completed_at, claimed }`.

## Catalog (`App/Backend/functions/_lib/game.js`)

Daily (3 picked / day): Show Up (log a workout, 40 XP) · Move Iron (5,000 lb, 60) ·
Century (100 reps, 50) · Half Hour Hero (30 min, 45) · Hype Squad (react to a
friend, 20) · Heavy Day (10,000 lb, 90).

Weekly (2 picked / week): Consistency (3 workouts, 150) · Grinder (5 workouts, 250) ·
Ton Lifter (25,000 lb, 200) · New Heights (set a PR, 175) · Volume Dealer (500
reps, 180) · Party Up (add a friend, 100).

Achievements: first_workout (50) · workouts_10 (100) · workouts_50 (250, rare) ·
workouts_100 (500, epic) · streak_7 (200, rare) · streak_30 (750, legendary) ·
volume_100k (400, epic) · level_10 (100) · level_25 (300, rare) · level_50
(1000, legendary) · first_friend (50) · guild_join (75).

## Client

- `GameProfile.swift`: `Quest`, `Achievement` models; `GameProfileService.loadQuests()`,
  `claimQuest(_:)`, `loadAchievements()`, `claimableQuestCount`,
  `pendingAchievements` (set from sync), `lastClaimedQuest`. `loadAll()` also
  loads quests; a sync that uploaded sessions refreshes the board.
- `QuestViews.swift`: `QuestBoardView` (daily/weekly, progress bars, Claim
  button, +XP burst animation on claim), `TodaysQuestsCard` (Home dashboard),
  `AchievementsView`/`AchievementTile` (adaptive grid, lock/unlock,
  rarity tint: gray/blue/purple/orange), `QuestsAndAchievementsPane` (segmented).
- Hooks: `DashboardView` shows `TodaysQuestsCard` under the schedule card ("All
  quests" jumps to tab 7); `CommunityView` gained a `Quests` section — on iOS
  that is inside the Community tab, on macOS inside the Community sidebar item.

## Verified

- `swiftc -parse-as-library -target arm64-apple-macos14.0 *.swift` → 0 errors.
- `node --check` on all four JS files.
- `node tests/game-rules.test.mjs` → 8 pass (period keys incl. ISO-week edge,
  determinism per user/period, variety across users/days, weekly rollover,
  metric advance + capping, all 12 achievement rules, catalog integrity).
- `node tests/auth-verification.test.mjs` → 12 pass (unchanged).

## Not verified / left undone

- Nothing has been deployed; D1 not exercised (wrangler login still blocked per
  STATUS.md). The worker's SQL paths (`ensureBoard` batch, claim guard,
  achievements upsert) are reviewed but not run against a real D1.
- `deploy.sh` now copies `_lib/game.js`; if the site repo's Pages Functions are
  synced any other way, add that file.
- Client does not yet upload the exercise tree, so `set_pr` never progresses.
- No celebration overlay for achievement unlocks yet — `pendingAchievements` is
  published but nothing consumes it (RootView could show a toast like the
  level-up overlay).
- Weekly quests use "workouts this week" rather than distinct training days.
