# Guild Raids

_Added 2026-08-29, rebased onto `integrate` (quests, achievements, talents,
challenges, HealthKit)._ A weekly co-op boss that every guild member damages
with real training volume. Nothing here has run against a deployed backend —
see "What is untested".

## Design

- **One boss per week, same for every guild.** Picked deterministically from
  the week number (Monday 00:00 UTC, matching `weekKey` in `_lib/game.js`)
  out of a fixed catalog of 8 in `App/Backend/functions/_lib/raids.js`
  (`bossForWeek(epoch)`). No cron, no shared state.
- **Damage = real work.** Inside `POST /api/fitness/sync`, for each *newly
  inserted* session: `total_volume (lb) x 1 + 250 x prs`, where `prs` is the
  count `recordPersonalRecords` just verified server-side from
  `payload.exercises[].sets[]` (the same number that feeds the `set_pr` quest).
  Revision updates deal nothing, so editing a workout cannot re-land damage.
  The PR bonus is capped at 20/session in `raidDamage`.
- **HP scales with the guild.** A raid row is opened lazily on first contact
  each week with `hp = base_hp x clamp(member_count, 1, 25)`, snapshotted so
  joins/leaves mid-week do not move the goalposts. 1 hp == 1 lb.
- **Ordering inside sync:** workout XP + profile update → level_up feed →
  raid damage (`applyRaidDamage`) → `checkAchievements`. So workout XP can
  never be lost to a raid error (it is try/caught), and `raid_slayer` can
  unlock in the very sync that kills the boss.
- **Defeat.** When `damage_done >= hp`, the request that flips `defeated_at`
  (`UPDATE … WHERE defeated_at IS NULL`, checked via `meta.changes`, same
  guard `checkAchievements` uses) pays every contributor with damage > 0
  `boss.reward_xp` via the existing `awardXp` (level, talent points and
  level_up feed handled there; reason `raid`), pushes a `raid_defeated` feed
  item, and runs `checkAchievements` for the other contributors.
  Hits after defeat are still recorded in contributions but neither move
  `damage_done` nor pay again.
- **Achievement** `raid_slayer` lives in the shared catalog in
  `_lib/game.js` (`rarity: rare`, 150 XP, rule `raids_won >= 1`).
  `achievementStats` gains `raids_won` = count of defeated raids the user
  contributed to (try/caught, so a database without the raid tables still
  evaluates the other rules).

Catalog (id / name / base hp / reward xp / title): `ironjaw` Ironjaw the
Plate Hoarder 60k/400/Plate Liberator · `cardio_wraith` 55k/380 ·
`chalk_golem` 70k/450 · `squat_rack_curler` 65k/420 · `doms_dragon` 80k/500 ·
`plateau_titan` 90k/550 · `mirror_lich` 75k/480 · `rest_day_hydra` 85k/520.
Each carries an SF Symbol and a two-stop hex gradient the client draws.

## Endpoints

All under `/api/fitness`, bearer-authenticated like everything else.

### `GET /api/fitness/raid`

`{ "raid": null, "reason": "no_guild" }` without a guild, otherwise:

```json
{ "raid": {
    "id": "…", "guild_id": "…",
    "week_start": 1787529600, "ends_at": 1788134400, "seconds_left": 123456,
    "boss": { "id": "ironjaw", "name": "…", "flavor": "…", "symbol": "dumbbell.fill",
              "gradient": ["#8E8E93", "#1C1C1E"], "reward_xp": 400,
              "reward_title": "Plate Liberator", "reward_cosmetic": "aura_iron" },
    "hp": 240000, "damage_done": 51230, "hp_remaining": 188770,
    "defeated": false, "defeated_at": null, "member_count": 4,
    "contributors": [ { "rank": 1, "user_id": "…", "display_name": "…", "level": 12,
                        "avatar_url": null, "damage": 30000, "hits": 3, "is_self": true } ],
    "my_damage": 30000, "my_hits": 3 } }
```

### `POST /api/fitness/sync` (extended)

Response gains `raid` (null when not in a guild or no new sessions):

```json
"raid": { "boss_id": "ironjaw", "boss_name": "…", "damage": 12450, "hp": 240000,
          "damage_done": 63680, "defeated": false, "just_defeated": false, "reward_xp": 0 }
```

`just_defeated`/`reward_xp` are set only for the request that killed the
boss. The `profile` in the same response already includes raid XP;
`achievements_unlocked` may contain `raid_slayer`.

## Schema / migration

`App/Backend/migrations/2026-08-29-guild-raids.sql` — D1-safe, all
`IF NOT EXISTS` / `INSERT OR IGNORE`, re-runnable:

- `raid_bosses` (id, name, flavor, symbol, gradient JSON, base_hp, reward_xp,
  reward_title, reward_cosmetic), seeded with the 8 bosses (the worker also
  upserts on first use).
- `guild_raids` (id, guild_id, boss_id, week_start, hp, damage_done,
  defeated_at, created_at; UNIQUE (guild_id, week_start)).
- `guild_raid_contributions` (raid_id, user_id, damage, hits, updated_at;
  PK (raid_id, user_id)).

`schema.sql` has the same DDL appended (without the seed).

## Deploying

`deploy.sh` already copies `_lib/*.js`; it now also runs every
`migrations/*.sql` after `schema.sql`. Normal path unchanged:

```bash
cd App/Backend && ./deploy.sh --dry-run && ./deploy.sh
```

Manual: `npx wrangler d1 execute batesai-db --remote
--file=App/Backend/migrations/2026-08-29-guild-raids.sql`, copy the
functions tree, `wrangler pages deploy`. Smoke test: `GET /api/fitness/raid`
returns a `raid` object for a guild member.

## Client

- `GameProfile.swift`: `RaidBoss`, `RaidContributor`, `RaidState`, `RaidHit`;
  `GameProfileService.raid`, `isLoadingRaid`, `lastRaidHit`, `loadRaid()`;
  sync decodes `raid`, sets `lastRaidHit` and refetches the raid so the HP bar
  animates. `ActivityItem` draws `raid_defeated` with `bolt.shield.fill`.
  No client-side PR counting — the server verifies PRs from the exercise
  payload the client already uploads.
- `RaidViews.swift`: `RaidCard` (boss art = SF Symbol over the catalog
  gradient, animated HP bar, your damage/hits/reward, top contributors,
  live countdown via `TimelineView`, defeated state) and `RaidDamageToast`
  over the card after a sync lands (the app has no global toast;
  `LevelUpOverlay` is a full-screen modal, too heavy for a per-workout hit).
- `SocialViews.swift`: `RaidCard()` under the guild header in the Guild pane.

## Verified

- `node App/Backend/tests/guild-raids.test.mjs` — 16/16 (damage maths, PR
  cap, Monday-UTC week boundaries, 8-boss deterministic rotation, hp scaling,
  `raid_slayer` in the shared catalog + unlock rule).
- `game-rules` 8/8 (catalog count bumped 12 → 13), `challenges` 7/7,
  `talents` 20/20 (its worker-import rewrite now also maps `raids.js`),
  `auth-verification` 12/12.
- `node --check` on the fitness worker; `bash -n deploy.sh`.
- `swiftc -typecheck` passes for macOS 14 arm64 and iOS 17 simulator.

## What is untested

- **Nothing has hit D1.** Migration SQL and every raid query were written
  against the schema, not executed. `upsertContribution`'s
  `ON CONFLICT … DO UPDATE` and the `raids_won` join are the likeliest typo
  sites.
- **The UI has never been rendered** on either platform.
- **Reward title / cosmetic** are returned but not applied to the profile or
  avatar; only XP and the achievement are granted.
- `awardXp` is called per contributor inside the defeating request; a
  25-member guild means ~75 D1 statements in one sync. Fine for D1 limits,
  but not measured.
