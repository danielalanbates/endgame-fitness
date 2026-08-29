-- Guild Raids (2026-08-29). D1-safe: every statement is IF NOT EXISTS /
-- INSERT OR IGNORE, so it can be applied more than once.
--
--   npx wrangler d1 execute batesai-db --remote --file=App/Backend/migrations/2026-08-29-guild-raids.sql

-- The boss catalog. The source of truth is functions/_lib/raids.js; this
-- table mirrors it so raid rows have a foreign key and so hp/rewards can be
-- inspected in SQL. The worker upserts any missing row on first use.
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

INSERT OR IGNORE INTO raid_bosses (id, name, flavor, symbol, gradient, base_hp, reward_xp, reward_title, reward_cosmetic) VALUES
  ('ironjaw',           'Ironjaw the Plate Hoarder',  'He has every 45 in the building and he is not re-racking them.',        'dumbbell.fill',                        '["#8E8E93","#1C1C1E"]', 60000, 400, 'Plate Liberator', 'aura_iron'),
  ('cardio_wraith',     'The Cardio Wraith',          'Whispers "just one more mile" from inside the treadmill.',             'figure.run',                           '["#5AC8FA","#1D3557"]', 55000, 380, 'Wraith Runner',   'aura_mist'),
  ('chalk_golem',       'Chalk Golem',                'Leaves a handprint on everything. Everything.',                        'hand.raised.fill',                     '["#F2F2F7","#8E8E93"]', 70000, 450, 'Dusted',          'aura_chalk'),
  ('squat_rack_curler', 'The Squat-Rack Curler',      'Twenty-pound curls, forty-minute sets, zero shame.',                   'figure.strengthtraining.traditional',  '["#FF9F0A","#7A2E00"]', 65000, 420, 'Rack Reclaimer',  'aura_ember'),
  ('doms_dragon',       'DOMS, the Two-Day Dragon',   'You do not feel its bite today. You will feel it on Thursday.',        'flame.fill',                           '["#FF375F","#3A0A1A"]', 80000, 500, 'Dragonsore',      'aura_crimson'),
  ('plateau_titan',     'Plateau Titan',              'Has held the same bench number for six years and calls it consistency.','mountain.2.fill',                     '["#30D158","#0B3D20"]', 90000, 550, 'Plateau Breaker', 'aura_verdant'),
  ('mirror_lich',       'The Mirror Lich',            'Feeds on flexing. Weakens with every rep you do not film.',            'sparkles',                             '["#BF5AF2","#2A0A3D"]', 75000, 480, 'Unfilmed',        'aura_violet'),
  ('rest_day_hydra',    'Rest-Day Hydra',             'Skip one session and two excuses grow back.',                          'bolt.heart.fill',                      '["#FFD60A","#5A4500"]', 85000, 520, 'Hydra Slayer',    'aura_gold');
