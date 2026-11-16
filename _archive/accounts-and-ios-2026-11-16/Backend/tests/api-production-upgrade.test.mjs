/**
 * The upgrade path end to end: a database in the 2026-10-27 production shape
 * (baseline schema + pre-v2 migrations, with v1-era rows in it) gets the
 * deploy (schema.sql, then the v2 migration statement by statement), and the
 * new worker then serves the old members correctly.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/api-production-upgrade.test.mjs
 */

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { D1Database, applySqlFile, applyStatements } from './lib/d1.mjs';
import { clock, call, runner, session } from './lib/harness.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const backend = join(here, '..');
const { test, run } = runner('production upgrade');

function productionDb() {
  const db = new D1Database();
  applySqlFile(db, join(here, 'fixtures', 'schema-baseline-2026-10-27.sql'));
  applyStatements(db, join(backend, 'migrations', '2026-08-29-guild-raids.sql'));
  applyStatements(db, join(backend, 'migrations', '2026-10-27-rate-limits.sql'));
  const t = clock.now - 30 * 86400;
  const run1 = (sql, ...a) => db.raw.prepare(sql).run(...a);
  run1("INSERT INTO users (id, email, name, created_at, updated_at) VALUES ('old', 'old@example.com', 'Old Timer', ?, ?)", t, t);
  run1("INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES ('s', 'old', ?, ?)",
    createHash('sha256').update('old-token').digest('hex'), clock.now + 86400);
  // A v1-era profile: public by the old default, a free-text title, UTC streak.
  run1(`INSERT INTO fitness_profiles (user_id, display_name, level, xp, current_streak, longest_streak,
          last_workout_date, total_workouts, total_volume, total_reps, title, avatar_config, created_at, updated_at)
        VALUES ('old', 'Old Timer', 6, 1100, 3, 9, ?, 4, 20000, 300, 'Custom Title', '{"height":"Tall"}', ?, ?)`,
  new Date((clock.now - 86400) * 1000).toISOString().slice(0, 10), t, t);
  run1(`INSERT INTO workout_sessions (id, user_id, performed_at, name, duration_secs, total_volume, total_reps,
          xp_earned, payload, client_rev, updated_at)
        VALUES ('legacy-1', 'old', ?, 'Push', 3600, 5000, 75, 300, ?, 1, ?)`,
  t, JSON.stringify({ id: 'legacy-1', exercises: [{ name: 'Bench Press', sets: [{ reps: 5, weight: 185 }] }] }), t);
  run1("INSERT INTO personal_records VALUES ('old', 'Bench Press', 5, 185, 216, ?)", t);
  run1("INSERT INTO guilds (id, name, owner_id, created_at) VALUES ('g', 'Veterans', 'old', ?)", t);
  run1("INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES ('g', 'old', 'owner', ?)", t);
  // Deploy.
  applySqlFile(db, join(backend, 'schema.sql'));
  for (const m of ['2026-08-29-guild-raids.sql', '2026-10-27-rate-limits.sql', '2026-10-27-fitness-v2.sql']) {
    applyStatements(db, join(backend, 'migrations', m));
  }
  return db;
}

const env = { DB: productionDb() };
const old = { id: 'old', token: 'old-token' };

test('an existing member reads a full v2 profile; their settings are untouched', async () => {
  const res = await call(env, old, 'GET', 'profile');
  assert.equal(res.status, 200);
  const p = res.body.profile;
  assert.equal(p.is_public, true, 'existing public players stay public');
  assert.equal(p.title, 'Custom Title', 'legacy free-text title is not wiped');
  assert.deepEqual(p.avatar_config, { height: 'Tall' });
  assert.equal(p.current_streak, 3);
  assert.equal(p.streak_alive, true);
  assert.ok(p.earned_titles.includes('Apprentice'));
  assert.equal(res.body.personal_records[0].exercise, 'Bench Press');
  assert.equal(res.body.personal_records[0].exercise_key, 'bench press');
});

test('their guild has an invite code and the v2 cap', async () => {
  const g = await call(env, old, 'GET', 'guild');
  assert.match(g.body.guild.invite_code, /^[A-Z2-9]{8}$/);
  assert.equal(g.body.guild.member_cap, 50);
});

test('a v1-style sync after the upgrade: legacy PR is the baseline, history pulls with tombstone flags', async () => {
  const res = await call(env, old, 'POST', 'sync', {
    since: 0,
    sessions: [session([['Bench Press', [[5, 190]]]], { id: 'new-1' })],
  });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.accepted, ['new-1']);
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM activity_feed WHERE kind = 'pr'").get().n, 1,
    '190 beats the migrated 185 record');
  const legacy = res.body.sessions.find((s) => s.id === 'legacy-1');
  assert.equal(legacy.deleted, false);
  assert.equal(legacy.payload.exercises[0].name, 'Bench Press');
  assert.equal(res.body.profile.total_workouts, 5);
});

test('build 6 echoing its whole Account form still saves', async () => {
  const res = await call(env, old, 'PUT', 'profile', { display_name: 'Old Timer 2', title: 'Custom Title' });
  assert.equal(res.status, 200);
  assert.equal(res.body.profile.display_name, 'Old Timer 2');
});

await run();
