-- Endgame Fitness — D1 schema (database: batesai-db)
--
-- Apply with:
--   npx wrangler d1 execute batesai-db --remote --file=App/Backend/schema.sql
--
-- Every statement is IF NOT EXISTS so this is safe to re-run. The `users` and
-- `sessions` tables are shared with the rest of batesai.org membership; the
-- fitness_* and social tables are owned by this app.

-- ---------------------------------------------------------------- accounts

CREATE TABLE IF NOT EXISTS users (
  id             TEXT PRIMARY KEY,
  email          TEXT NOT NULL UNIQUE,
  password_hash  TEXT,
  name           TEXT,
  avatar_url     TEXT,
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

-- ---------------------------------------------------------------- profile

CREATE TABLE IF NOT EXISTS fitness_profiles (
  user_id        TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  display_name   TEXT NOT NULL DEFAULT 'Athlete',
  -- progression
  level          INTEGER NOT NULL DEFAULT 1,
  xp             INTEGER NOT NULL DEFAULT 0,
  talent_points  INTEGER NOT NULL DEFAULT 0,
  prestige       INTEGER NOT NULL DEFAULT 0,
  -- streaks
  current_streak INTEGER NOT NULL DEFAULT 0,
  longest_streak INTEGER NOT NULL DEFAULT 0,
  last_workout_date TEXT,
  -- lifetime totals (denormalised for cheap leaderboard reads)
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
  units            TEXT NOT NULL DEFAULT 'imperial',
  -- character / cosmetics
  avatar_config  TEXT,               -- JSON blob owned by AvatarSystem.swift
  title          TEXT,               -- equipped title, e.g. "Iron Disciple"
  -- housekeeping
  is_public      INTEGER NOT NULL DEFAULT 1,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_profiles_xp ON fitness_profiles (xp DESC);
CREATE INDEX IF NOT EXISTS idx_profiles_streak ON fitness_profiles (current_streak DESC);

CREATE TABLE IF NOT EXISTS user_settings (
  user_id               TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  theme                 TEXT    NOT NULL DEFAULT 'dark',
  units                 TEXT    NOT NULL DEFAULT 'imperial',
  weekly_goal_days      INTEGER NOT NULL DEFAULT 4,
  notifications_enabled INTEGER NOT NULL DEFAULT 1
);

-- ---------------------------------------------------------------- training

-- One row per completed session. `payload` holds the full exercise/set tree as
-- JSON so the client model can evolve without a migration for every field; the
-- promoted columns exist only for querying and leaderboards.
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
  updated_at    INTEGER NOT NULL
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

-- Personal records, one row per (user, exercise, rep-count).
CREATE TABLE IF NOT EXISTS personal_records (
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  exercise      TEXT NOT NULL,
  reps          INTEGER NOT NULL,
  weight        REAL NOT NULL,
  estimated_1rm REAL NOT NULL,
  achieved_at   INTEGER NOT NULL,
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

-- ---------------------------------------------------------------- social

-- A friendship is stored as a single row with an ordered pair so that
-- (a,b) and (b,a) can never both exist. Requests carry a direction.
CREATE TABLE IF NOT EXISTS friendships (
  user_low   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_high  TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  requested_by TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending',  -- pending | accepted | blocked
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_low, user_high),
  CHECK (user_low < user_high)
);
CREATE INDEX IF NOT EXISTS idx_friend_low ON friendships (user_low, status);
CREATE INDEX IF NOT EXISTS idx_friend_high ON friendships (user_high, status);

CREATE TABLE IF NOT EXISTS guilds (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  motto       TEXT,
  owner_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emblem      TEXT,
  member_cap  INTEGER NOT NULL DEFAULT 25,
  created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS guild_members (
  guild_id  TEXT NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
  user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role      TEXT NOT NULL DEFAULT 'member',   -- owner | officer | member
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (guild_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_guild_member_user ON guild_members (user_id);

-- Activity feed: what friends see. Deliberately denormalised and append-only.
CREATE TABLE IF NOT EXISTS activity_feed (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,   -- workout | level_up | pr | achievement | quest
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

-- ---------------------------------------------------------------- friend codes (2026-08-28)
-- Applied to the live database by hand with ALTER TABLE (D1 has no IF NOT EXISTS
-- for columns); kept here so a fresh database gets it too.
-- ALTER TABLE fitness_profiles ADD COLUMN friend_code TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_fitness_profiles_friend_code
  ON fitness_profiles (friend_code) WHERE friend_code IS NOT NULL;

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
