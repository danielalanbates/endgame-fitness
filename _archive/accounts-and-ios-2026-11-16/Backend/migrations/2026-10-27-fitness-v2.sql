-- Endgame Fitness API v2 (2026-10-27): profiles v2, sync v2, social safety,
-- guild invites, seasons. Brings an existing production database up to the
-- shape in schema.sql.
--
-- Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
-- https://batesai.org · help@batesai.org
--
-- HOW TO APPLY (read this): D1 has no ADD COLUMN IF NOT EXISTS, so the
-- ALTER TABLE statements below fail with "duplicate column name" on a
-- database that already has the column (a fresh database built from
-- schema.sql, or a second run of this file). Deploy therefore runs this file
-- ONE STATEMENT AT A TIME and ignores exactly that error. Every other
-- statement is idempotent on its own: tables and indexes are IF NOT EXISTS,
-- inserts are OR IGNORE, and every UPDATE or DELETE only touches rows that
-- still need it. Statements are separated by a semicolon at the end of a
-- line, and no comment or string in this file contains a semicolon.
--
-- Order matters: schema.sql runs first, then the earlier migrations, then this.

-- ------------------------------------------------------------ new columns

ALTER TABLE fitness_profiles ADD COLUMN friend_code TEXT;
ALTER TABLE fitness_profiles ADD COLUMN bio TEXT;
ALTER TABLE fitness_profiles ADD COLUMN cosmetic TEXT;
ALTER TABLE fitness_profiles ADD COLUMN hero_class TEXT;
ALTER TABLE fitness_profiles ADD COLUMN class_affinity TEXT;
ALTER TABLE fitness_profiles ADD COLUMN tz_offset_min INTEGER NOT NULL DEFAULT 0;
ALTER TABLE fitness_profiles ADD COLUMN streak_freezes INTEGER NOT NULL DEFAULT 0;

ALTER TABLE workout_sessions ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;
ALTER TABLE workout_sessions ADD COLUMN flagged INTEGER NOT NULL DEFAULT 0;
ALTER TABLE workout_sessions ADD COLUMN flag_reason TEXT;

ALTER TABLE personal_records ADD COLUMN exercise_name TEXT;

ALTER TABLE guilds ADD COLUMN invite_code TEXT;
ALTER TABLE guilds ADD COLUMN is_open INTEGER NOT NULL DEFAULT 1;

-- ------------------------------------------------------------ new tables (same DDL as schema.sql)

CREATE TABLE IF NOT EXISTS fitness_unlocks (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL,
  value       TEXT NOT NULL,
  source      TEXT NOT NULL,
  unlocked_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, kind, value)
);

CREATE TABLE IF NOT EXISTS season_progress (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  season_id  TEXT NOT NULL,
  xp         INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, season_id)
);

CREATE TABLE IF NOT EXISTS season_claims (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  season_id  TEXT NOT NULL,
  tier       INTEGER NOT NULL,
  claimed_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, season_id, tier)
);

CREATE TABLE IF NOT EXISTS user_blocks (
  blocker_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id)
);

CREATE TABLE IF NOT EXISTS activity_comments (
  id          TEXT PRIMARY KEY,
  activity_id TEXT NOT NULL REFERENCES activity_feed(id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  text        TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS ugc_reports (
  id          TEXT PRIMARY KEY,
  reporter_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  target_type TEXT NOT NULL,
  target_id   TEXT NOT NULL,
  reason      TEXT NOT NULL,
  snapshot    TEXT,
  status      TEXT NOT NULL DEFAULT 'open',
  created_at  INTEGER NOT NULL
);

-- ------------------------------------------------------------ indexes

CREATE UNIQUE INDEX IF NOT EXISTS idx_fitness_profiles_friend_code
  ON fitness_profiles (friend_code) WHERE friend_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_volume ON fitness_profiles (total_volume DESC);
CREATE INDEX IF NOT EXISTS idx_profiles_workouts ON fitness_profiles (total_workouts DESC);
CREATE INDEX IF NOT EXISTS idx_season_progress_board ON season_progress (season_id, xp DESC);
CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked ON user_blocks (blocked_id);
CREATE INDEX IF NOT EXISTS idx_comments_activity ON activity_comments (activity_id, created_at);
CREATE INDEX IF NOT EXISTS idx_reports_status ON ugc_reports (status, created_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_reports_once
  ON ugc_reports (reporter_id, target_type, target_id);

-- ------------------------------------------------------------ guilds: cap 50, invite codes, one guild per player

UPDATE guilds SET member_cap = 50 WHERE member_cap < 50;

-- 8 characters from the friend-code alphabet (no 0/O/1/I). The worker also
-- fills any guild still missing a code the first time it is read.
UPDATE guilds SET invite_code =
    substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
  || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
  || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
  || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
  || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
  || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
  || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
  || substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (abs(random()) % 32), 1)
WHERE invite_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_guilds_invite_code
  ON guilds (invite_code) WHERE invite_code IS NOT NULL;

-- Racing joins could put one player in two guilds. Keep the earliest
-- membership, then make it impossible.
DELETE FROM guild_members
 WHERE EXISTS (
   SELECT 1 FROM guild_members g2
    WHERE g2.user_id = guild_members.user_id
      AND (g2.joined_at < guild_members.joined_at
           OR (g2.joined_at = guild_members.joined_at AND g2.guild_id < guild_members.guild_id))
 );

CREATE UNIQUE INDEX IF NOT EXISTS idx_guild_members_one_guild ON guild_members (user_id);

-- ------------------------------------------------------------ personal records: normalised keys

-- Rows written before v2 keyed on the raw name ("Bench Press" and
-- "bench press" were different exercises). Re-key them on the lower-cased
-- trimmed name and keep the original as the display name. Rows the worker
-- writes from now on always have exercise_name set, so a re-run never
-- touches them (library exercise_id keys keep their case).
UPDATE OR IGNORE personal_records
   SET exercise_name = exercise,
       exercise = lower(trim(exercise))
 WHERE exercise_name IS NULL;

-- Rows left behind were duplicates of a key that already existed. Keep the
-- heavier weight on the surviving row, then drop the leftovers.
UPDATE personal_records
   SET weight = (SELECT MAX(l.weight) FROM personal_records l
                  WHERE l.user_id = personal_records.user_id AND l.reps = personal_records.reps
                    AND l.exercise_name IS NULL AND lower(trim(l.exercise)) = personal_records.exercise),
       estimated_1rm = ROUND((SELECT MAX(l.weight) FROM personal_records l
                  WHERE l.user_id = personal_records.user_id AND l.reps = personal_records.reps
                    AND l.exercise_name IS NULL AND lower(trim(l.exercise)) = personal_records.exercise)
                  * (1 + personal_records.reps / 30.0))
 WHERE exercise_name IS NOT NULL
   AND EXISTS (SELECT 1 FROM personal_records l
                WHERE l.user_id = personal_records.user_id AND l.reps = personal_records.reps
                  AND l.exercise_name IS NULL AND lower(trim(l.exercise)) = personal_records.exercise
                  AND l.weight > personal_records.weight);

DELETE FROM personal_records
 WHERE exercise_name IS NULL
   AND EXISTS (SELECT 1 FROM personal_records p2
                WHERE p2.user_id = personal_records.user_id AND p2.reps = personal_records.reps
                  AND p2.exercise = lower(trim(personal_records.exercise))
                  AND p2.exercise_name IS NOT NULL);

-- ------------------------------------------------------------ title and cosmetic ownership backfill

-- Rank titles for the levels players have already reached (same bands as
-- functions/_lib/unlocks.js and GameProfile.swift).
INSERT OR IGNORE INTO fitness_unlocks (user_id, kind, value, source, unlocked_at)
SELECT p.user_id, 'title', r.title, 'rank', CAST(strftime('%s', 'now') AS INTEGER)
  FROM fitness_profiles p
  JOIN (SELECT 1 AS lvl, 'Initiate' AS title
        UNION ALL SELECT 5, 'Apprentice'
        UNION ALL SELECT 10, 'Iron Disciple'
        UNION ALL SELECT 20, 'Ironbound'
        UNION ALL SELECT 30, 'Vanguard'
        UNION ALL SELECT 45, 'Warbringer'
        UNION ALL SELECT 60, 'Champion'
        UNION ALL SELECT 80, 'Ascendant'
        UNION ALL SELECT 100, 'Endgame') r
    ON p.level >= r.lvl;

-- Achievement titles (catalog in functions/_lib/game.js).
INSERT OR IGNORE INTO fitness_unlocks (user_id, kind, value, source, unlocked_at)
SELECT a.user_id, 'title', t.title, 'achievement:' || a.achievement_id, a.unlocked_at
  FROM achievements a
  JOIN (SELECT 'first_workout' AS id, 'First Blood' AS title
        UNION ALL SELECT 'workouts_10', 'Regular'
        UNION ALL SELECT 'workouts_50', 'Dedicated'
        UNION ALL SELECT 'workouts_100', 'Century Club'
        UNION ALL SELECT 'streak_7', 'One Week Strong'
        UNION ALL SELECT 'streak_30', 'Iron Will'
        UNION ALL SELECT 'volume_100k', 'Volume King'
        UNION ALL SELECT 'level_10', 'Iron Disciple'
        UNION ALL SELECT 'level_25', 'Ironbound'
        UNION ALL SELECT 'level_50', 'Legend'
        UNION ALL SELECT 'first_friend', 'Party of Two'
        UNION ALL SELECT 'guild_join', 'Banner Raised'
        UNION ALL SELECT 'raid_slayer', 'Raid Slayer') t
    ON t.id = a.achievement_id;

-- Raid reward titles and auras for every defeated raid a player hit.
INSERT OR IGNORE INTO fitness_unlocks (user_id, kind, value, source, unlocked_at)
SELECT c.user_id, 'title', b.reward_title, 'raid:' || b.id, g.defeated_at
  FROM guild_raid_contributions c
  JOIN guild_raids g ON g.id = c.raid_id
  JOIN raid_bosses b ON b.id = g.boss_id
 WHERE g.defeated_at IS NOT NULL AND (c.damage > 0 OR c.hits > 0) AND b.reward_title IS NOT NULL;

INSERT OR IGNORE INTO fitness_unlocks (user_id, kind, value, source, unlocked_at)
SELECT c.user_id, 'cosmetic', b.reward_cosmetic, 'raid:' || b.id, g.defeated_at
  FROM guild_raid_contributions c
  JOIN guild_raids g ON g.id = c.raid_id
  JOIN raid_bosses b ON b.id = g.boss_id
 WHERE g.defeated_at IS NOT NULL AND (c.damage > 0 OR c.hits > 0) AND b.reward_cosmetic IS NOT NULL;
