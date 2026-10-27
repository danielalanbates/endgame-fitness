-- Endgame Fitness — D1 schema (database: batesai-db)
--
-- Apply with:
--   npx wrangler d1 execute batesai-db --remote --file=App/Backend/schema.sql
--
-- This is the full current schema. It applies cleanly to:
--   * an empty database (every column lives in its CREATE TABLE), and
--   * an existing database at any earlier version (every statement is
--     IF NOT EXISTS, and no index here names a column that older databases
--     lack).
-- Columns added to tables that already exist in production are brought in by
-- migrations/2026-10-27-fitness-v2.sql, which also creates the indexes on
-- those columns (marked "-- index: migration" below). Deploy applies this
-- file first, then every migration in order.
--
-- The `users` and `sessions` tables are shared with the rest of batesai.org
-- membership; the fitness_* and social tables are owned by this app. Every
-- reference to users(id) cascades (or nulls), so deleting an account in the
-- auth worker never trips a foreign key.

-- ---------------------------------------------------------------- accounts

CREATE TABLE IF NOT EXISTS users (
  id             TEXT PRIMARY KEY,
  email          TEXT NOT NULL UNIQUE,
  password_hash  TEXT,
  name           TEXT,
  avatar_url     TEXT,
  membership_tier TEXT,
  oauth_provider TEXT,
  oauth_id      TEXT,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);

-- Apple gives us a stable (provider, sub) pair but an email that may rotate,
-- so sign-in resolves on this index rather than on email.
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_oauth
  ON users (oauth_provider, oauth_id)
  WHERE oauth_provider IS NOT NULL AND oauth_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS sessions (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions (token_hash);

-- Fixed-window rate limit counters shared by /api/auth and /api/fitness
-- (functions/_lib/ratelimit.js; also migrations/2026-10-27-rate-limits.sql).
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket       TEXT    NOT NULL,
  window_start INTEGER NOT NULL,
  count        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket, window_start)
);
CREATE INDEX IF NOT EXISTS idx_rate_limits_window ON rate_limits (window_start);

-- ---------------------------------------------------------------- profile

CREATE TABLE IF NOT EXISTS fitness_profiles (
  user_id        TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  display_name   TEXT NOT NULL DEFAULT 'Athlete',
  -- progression
  level          INTEGER NOT NULL DEFAULT 1,
  xp             INTEGER NOT NULL DEFAULT 0,
  talent_points  INTEGER NOT NULL DEFAULT 0,
  prestige       INTEGER NOT NULL DEFAULT 0,
  -- streaks (dates are the player's local day, see tz_offset_min)
  current_streak INTEGER NOT NULL DEFAULT 0,
  longest_streak INTEGER NOT NULL DEFAULT 0,
  last_workout_date TEXT,
  streak_freezes INTEGER NOT NULL DEFAULT 0,     -- banked, 0–3
  tz_offset_min  INTEGER NOT NULL DEFAULT 0,     -- minutes east of UTC, −840…840
  -- lifetime totals (denormalised for cheap leaderboard reads; flagged and
  -- deleted sessions are excluded)
  total_workouts INTEGER NOT NULL DEFAULT 0,
  total_volume   REAL    NOT NULL DEFAULT 0,
  total_reps     INTEGER NOT NULL DEFAULT 0,
  -- onboarding answers
  training_goal    TEXT,
  experience_level TEXT,
  equipment_level  TEXT,
  body_weight      REAL,
  height_inches    REAL,
  birth_year       INTEGER,
  units            TEXT NOT NULL DEFAULT 'imperial',   -- lb | kg (v1: imperial | metric)
  -- character / cosmetics
  avatar_config  TEXT,               -- JSON blob owned by AvatarSystem.swift
  title          TEXT,               -- equipped title; must be in fitness_unlocks / derived
  cosmetic       TEXT,               -- equipped cosmetic id, e.g. "aura_gold"
  bio            TEXT,               -- ≤ 160 chars
  hero_class     TEXT,               -- cached from the last read/sync (_lib/heroclass.js)
  class_affinity TEXT,               -- JSON {strength, endurance, mobility, athletic}
  friend_code    TEXT,               -- 6 chars, unique (index: migration)
  -- housekeeping
  is_public      INTEGER NOT NULL DEFAULT 0,   -- new players are private until they opt in
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_profiles_xp ON fitness_profiles (xp DESC);
CREATE INDEX IF NOT EXISTS idx_profiles_streak ON fitness_profiles (current_streak DESC);
CREATE INDEX IF NOT EXISTS idx_profiles_volume ON fitness_profiles (total_volume DESC);
CREATE INDEX IF NOT EXISTS idx_profiles_workouts ON fitness_profiles (total_workouts DESC);
-- index: migration — idx_fitness_profiles_friend_code (UNIQUE, friend_code)

CREATE TABLE IF NOT EXISTS user_settings (
  user_id               TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  theme                 TEXT    NOT NULL DEFAULT 'dark',
  units                 TEXT    NOT NULL DEFAULT 'imperial',
  weekly_goal_days      INTEGER NOT NULL DEFAULT 4,
  notifications_enabled INTEGER NOT NULL DEFAULT 1
);

-- Titles and cosmetics a player owns (API v2 §7). Rank and achievement titles
-- are also derived on read; raid and season rewards live only here.
CREATE TABLE IF NOT EXISTS fitness_unlocks (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL,          -- title | cosmetic
  value       TEXT NOT NULL,
  source      TEXT NOT NULL,          -- rank | achievement:<id> | raid:<boss> | season:<id>
  unlocked_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, kind, value)
);

-- ---------------------------------------------------------------- training

-- One row per session. `payload` holds the full exercise/set tree as JSON so
-- other devices can rebuild history; the promoted columns exist for queries
-- and leaderboards and are recomputed by the server from the payload.
-- A deleted session stays as a tombstone (deleted = 1) so other devices learn
-- about it on their next pull. A flagged session failed a plausibility cap: it
-- is kept for history but earns nothing and counts toward no total.
CREATE TABLE IF NOT EXISTS workout_sessions (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  performed_at  INTEGER NOT NULL,
  name          TEXT,
  program_id    TEXT,
  duration_secs INTEGER NOT NULL DEFAULT 0,
  total_volume  REAL    NOT NULL DEFAULT 0,
  total_reps    INTEGER NOT NULL DEFAULT 0,
  xp_earned     INTEGER NOT NULL DEFAULT 0,
  payload       TEXT    NOT NULL,
  client_rev    INTEGER NOT NULL DEFAULT 1,
  updated_at    INTEGER NOT NULL,
  deleted       INTEGER NOT NULL DEFAULT 0,
  flagged       INTEGER NOT NULL DEFAULT 0,
  flag_reason   TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_user_time
  ON workout_sessions (user_id, performed_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_sync
  ON workout_sessions (user_id, updated_at);

CREATE TABLE IF NOT EXISTS workout_programs (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  payload    TEXT NOT NULL,
  is_active  INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_programs_user ON workout_programs (user_id);

-- Personal records, one row per (user, exercise key, rep-count). The key is
-- the library exercise_id when the client sent one, else the lower-cased
-- trimmed name; exercise_name keeps the display name.
CREATE TABLE IF NOT EXISTS personal_records (
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  exercise      TEXT NOT NULL,
  reps          INTEGER NOT NULL,
  weight        REAL NOT NULL,
  estimated_1rm REAL NOT NULL,
  achieved_at   INTEGER NOT NULL,
  exercise_name TEXT,
  PRIMARY KEY (user_id, exercise, reps)
);

CREATE TABLE IF NOT EXISTS talents (
  user_id  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  talent_id TEXT NOT NULL,
  rank     INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (user_id, talent_id)
);

-- ---------------------------------------------------------------- the game

CREATE TABLE IF NOT EXISTS achievements (
  user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  achievement_id TEXT NOT NULL,
  unlocked_at    INTEGER NOT NULL,
  progress       REAL NOT NULL DEFAULT 1.0,
  PRIMARY KEY (user_id, achievement_id)
);

CREATE TABLE IF NOT EXISTS quests (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  quest_key   TEXT NOT NULL,
  kind        TEXT NOT NULL,          -- daily | weekly | milestone
  target      REAL NOT NULL,
  progress    REAL NOT NULL DEFAULT 0,
  xp_reward   INTEGER NOT NULL DEFAULT 0,
  expires_at  INTEGER,
  completed_at INTEGER,
  claimed     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_quests_user ON quests (user_id, expires_at);

CREATE TABLE IF NOT EXISTS xp_transactions (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  amount     INTEGER NOT NULL,
  reason     TEXT NOT NULL,
  source_id  TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_xp_user ON xp_transactions (user_id, created_at DESC);

-- Seasons (API v2 §6, functions/_lib/seasons.js). Seasons themselves are
-- derived from the date; only per-player progress and claims are stored.
CREATE TABLE IF NOT EXISTS season_progress (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  season_id  TEXT NOT NULL,           -- s1, s2, …
  xp         INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, season_id)
);
CREATE INDEX IF NOT EXISTS idx_season_progress_board ON season_progress (season_id, xp DESC);

CREATE TABLE IF NOT EXISTS season_claims (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  season_id  TEXT NOT NULL,
  tier       INTEGER NOT NULL,
  claimed_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, season_id, tier)
);

-- ---------------------------------------------------------------- social

-- A friendship is stored as a single row with an ordered pair so that
-- (a,b) and (b,a) can never both exist. Requests carry a direction.
CREATE TABLE IF NOT EXISTS friendships (
  user_low   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  requested_by TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending',  -- pending | accepted
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_low, user_high),
  CHECK (user_low < user_high)
);
CREATE INDEX IF NOT EXISTS idx_friend_low ON friendships (user_low, status);
CREATE INDEX IF NOT EXISTS idx_friend_high ON friendships (user_high, status);

-- Blocks are one-directional rows but hide both players from each other
-- everywhere (feed, comments, leaderboards, search, player cards, requests).
CREATE TABLE IF NOT EXISTS user_blocks (
  blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked ON user_blocks (blocked_id);

CREATE TABLE IF NOT EXISTS guilds (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  motto       TEXT,
  owner_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emblem      TEXT,
  member_cap  INTEGER NOT NULL DEFAULT 50,
  created_at  INTEGER NOT NULL,
  invite_code TEXT,                   -- 8 chars A–Z2–9 (index: migration)
  is_open     INTEGER NOT NULL DEFAULT 1   -- 1 = anyone may join from discovery
);

CREATE TABLE IF NOT EXISTS guild_members (
  guild_id  TEXT NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
  user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role      TEXT NOT NULL DEFAULT 'member',   -- owner | officer | member
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (guild_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_guild_member_user ON guild_members (user_id);
-- index: migration — idx_guild_members_one_guild (UNIQUE user_id; the
-- migration first removes duplicate memberships older races could create)

-- Activity feed: what friends and guildmates see. Append-only.
CREATE TABLE IF NOT EXISTS activity_feed (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,   -- workout | level_up | pr | achievement | quest | challenge | raid_defeated | season
  summary    TEXT NOT NULL,
  payload    TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_feed_user_time ON activity_feed (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS activity_reactions (
  activity_id TEXT NOT NULL REFERENCES activity_feed(id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji       TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (activity_id, user_id, emoji)
);

CREATE TABLE IF NOT EXISTS activity_comments (
  id          TEXT PRIMARY KEY,
  activity_id TEXT NOT NULL REFERENCES activity_feed(id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  text        TEXT NOT NULL,          -- 1–280 chars, filtered
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_comments_activity ON activity_comments (activity_id, created_at);

-- User reports for review by help@batesai.org. The reporter is nulled (not
-- deleted) if their account goes, so the report survives.
CREATE TABLE IF NOT EXISTS ugc_reports (
  id          TEXT PRIMARY KEY,
  reporter_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  target_type TEXT NOT NULL,          -- user | feed_item | comment | guild
  target_id   TEXT NOT NULL,
  reason      TEXT NOT NULL,
  snapshot    TEXT,                   -- the reported text at report time, if any
  status      TEXT NOT NULL DEFAULT 'open',   -- open | reviewed | actioned
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reports_status ON ugc_reports (status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_reports_once
  ON ugc_reports (reporter_id, target_type, target_id);

-- ---------------------------------------------------------------- challenges

-- A duel (two friends) or a guild challenge (everyone in the guild) over a
-- time window. Standings are NEVER stored: they are recomputed from
-- workout_sessions in [starts_at, ends_at) on every read, and settle() runs
-- lazily on the first GET after ends_at (see functions/_lib/challenges.js).
CREATE TABLE IF NOT EXISTS challenges (
  id           TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,                 -- duel | guild
  metric       TEXT NOT NULL,                 -- volume | workouts | streak
  creator_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  opponent_id  TEXT REFERENCES users(id) ON DELETE CASCADE,   -- duel only
  guild_id     TEXT REFERENCES guilds(id) ON DELETE CASCADE,  -- guild only
  starts_at    INTEGER NOT NULL,
  ends_at      INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending', -- pending | active | declined | finished
  winner_id    TEXT,
  settled_at   INTEGER,
  created_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_challenges_status ON challenges (status, ends_at);
CREATE INDEX IF NOT EXISTS idx_challenges_guild ON challenges (guild_id, status);

-- Who is in a challenge. Duels get exactly two rows; guild challenges get one
-- row per member at creation time (late joiners are not enrolled).
CREATE TABLE IF NOT EXISTS challenge_participants (
  challenge_id TEXT NOT NULL REFERENCES challenges(id) ON DELETE CASCADE,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  joined_at    INTEGER NOT NULL,
  PRIMARY KEY (challenge_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_challenge_participants_user ON challenge_participants (user_id);

-- ---------------------------------------------------------------- guild raids
-- Same DDL as migrations/2026-08-29-guild-raids.sql (which also seeds the
-- boss catalog; the worker upserts it from functions/_lib/raids.js anyway).

CREATE TABLE IF NOT EXISTS raid_bosses (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  flavor          TEXT,
  symbol          TEXT,                       -- SF Symbol used by the client
  gradient        TEXT,                       -- JSON [hexStart, hexEnd]
  base_hp         INTEGER NOT NULL,           -- hp for a one-member guild (1 hp = 1 lb)
  reward_xp       INTEGER NOT NULL DEFAULT 0, -- paid to every contributor on defeat
  reward_title    TEXT,
  reward_cosmetic TEXT
);

-- One row per (guild, week). hp is snapshotted at creation from the member
-- count so joining mid-week neither inflates nor shrinks the fight.
CREATE TABLE IF NOT EXISTS guild_raids (
  id           TEXT PRIMARY KEY,
  guild_id     TEXT NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
  boss_id      TEXT NOT NULL REFERENCES raid_bosses(id),
  week_start   INTEGER NOT NULL,              -- Monday 00:00 UTC, epoch seconds
  hp           INTEGER NOT NULL,
  damage_done  INTEGER NOT NULL DEFAULT 0,
  defeated_at  INTEGER,
  created_at   INTEGER NOT NULL,
  UNIQUE (guild_id, week_start)
);
CREATE INDEX IF NOT EXISTS idx_guild_raids_guild ON guild_raids (guild_id, week_start DESC);

CREATE TABLE IF NOT EXISTS guild_raid_contributions (
  raid_id     TEXT NOT NULL REFERENCES guild_raids(id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  damage      INTEGER NOT NULL DEFAULT 0,
  hits        INTEGER NOT NULL DEFAULT 0,     -- number of sessions that landed
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (raid_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_raid_contrib_raid ON guild_raid_contributions (raid_id, damage DESC);
