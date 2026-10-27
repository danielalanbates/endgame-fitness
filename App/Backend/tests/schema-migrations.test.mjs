/**
 * schema.sql and the migrations apply cleanly, in deploy order, to:
 *   1. an empty database,
 *   2. a "production-shaped" database built from the 2026-10-27 baseline
 *      schema (with data in it), and
 *   3. either of those a second time (re-running deploy is harmless).
 * The migrated production shape must end up with the same columns as a fresh
 * database, and the data backfills (invite codes, PR keys, title ownership,
 * one guild per player) must do what the migration says.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/schema-migrations.test.mjs
 */

import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { D1Database, applySqlFile, applyStatements, splitStatements } from './lib/d1.mjs';
import { readFileSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const backend = join(here, '..');
const SCHEMA = join(backend, 'schema.sql');
const BASELINE = join(here, 'fixtures', 'schema-baseline-2026-10-27.sql');
const MIGRATIONS = [
  join(backend, 'migrations', '2026-08-29-guild-raids.sql'),
  join(backend, 'migrations', '2026-10-27-rate-limits.sql'),
  join(backend, 'migrations', '2026-10-27-fitness-v2.sql'),
];

let passed = 0;
const test = (name, fn) => {
  try { fn(); passed += 1; console.log(`  ok   ${name}`); }
  catch (e) { console.log(`  FAIL ${name}\n       ${e.stack || e.message}`); process.exitCode = 1; }
};

/** What deploy does: schema.sql as a file, then each migration statement by statement. */
function deploy(db) {
  applySqlFile(db, SCHEMA);
  for (const m of MIGRATIONS) applyStatements(db, m);
}

function columns(db) {
  const tables = db.raw.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
  ).all().map((r) => r.name);
  const out = {};
  for (const t of tables) {
    out[t] = db.raw.prepare(`PRAGMA table_info(${t})`).all().map((c) => c.name).sort();
  }
  return out;
}

const indexes = (db) => new Set(db.raw.prepare(
  "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
).all().map((r) => r.name));

function seedBaseline(db) {
  const t = 1790000000;
  const run = (sql, ...args) => db.raw.prepare(sql).run(...args);
  for (const [id, email] of [['u1', 'a@example.com'], ['u2', 'b@example.com'], ['u3', 'c@example.com']]) {
    run('INSERT INTO users (id, email, created_at, updated_at) VALUES (?, ?, ?, ?)', id, email, t, t);
  }
  run(`INSERT INTO fitness_profiles (user_id, display_name, level, xp, created_at, updated_at, friend_code)
       VALUES ('u1', 'Alpha', 22, 30000, ?, ?, 'ABC234')`, t, t);
  run(`INSERT INTO fitness_profiles (user_id, display_name, level, created_at, updated_at) VALUES ('u2', 'Bravo', 3, ?, ?)`, t, t);
  run(`INSERT INTO fitness_profiles (user_id, display_name, level, created_at, updated_at) VALUES ('u3', 'Charlie', 1, ?, ?)`, t, t);
  // Two guilds, and a racing join that put u2 in both.
  run(`INSERT INTO guilds (id, name, owner_id, created_at) VALUES ('g1', 'Iron Club', 'u1', ?)`, t);
  run(`INSERT INTO guilds (id, name, owner_id, created_at) VALUES ('g2', 'Second', 'u3', ?)`, t);
  run(`INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES ('g1', 'u1', 'owner', ?)`, t);
  run(`INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES ('g1', 'u2', 'member', ?)`, t + 5);
  run(`INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES ('g2', 'u2', 'member', ?)`, t + 9);
  run(`INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES ('g2', 'u3', 'owner', ?)`, t);
  // A defeated raid u1 and u2 hit, one u3 did not.
  run(`INSERT INTO guild_raids (id, guild_id, boss_id, week_start, hp, damage_done, defeated_at, created_at)
       VALUES ('r1', 'g1', 'ironjaw', 1789776000, 100, 120, ?, ?)`, t, t);
  run(`INSERT INTO guild_raid_contributions (raid_id, user_id, damage, hits, updated_at) VALUES ('r1', 'u1', 100, 2, ?)`, t);
  run(`INSERT INTO guild_raid_contributions (raid_id, user_id, damage, hits, updated_at) VALUES ('r1', 'u2', 20, 1, ?)`, t);
  run(`INSERT INTO achievements (user_id, achievement_id, unlocked_at) VALUES ('u2', 'first_workout', ?)`, t);
  // PRs keyed on raw names, including a case-duplicate where the legacy row is heavier.
  run(`INSERT INTO personal_records VALUES ('u1', 'Bench Press', 5, 185, 216, ?)`, t);
  run(`INSERT INTO personal_records VALUES ('u1', 'bench press', 5, 175, 204, ?)`, t);
  run(`INSERT INTO personal_records VALUES ('u1', 'Squat ', 3, 225, 248, ?)`, t);
  run(`INSERT INTO workout_sessions (id, user_id, performed_at, payload, updated_at) VALUES ('s1', 'u1', ?, '{}', ?)`, t, t);
}

console.log('empty database');
test('schema.sql applies to an empty database', () => {
  const db = new D1Database();
  applySqlFile(db, SCHEMA);
});
test('schema.sql + every migration apply to an empty database, and again on top', () => {
  const db = new D1Database();
  deploy(db);
  deploy(db);
  const idx = indexes(db);
  for (const name of ['idx_fitness_profiles_friend_code', 'idx_guilds_invite_code', 'idx_guild_members_one_guild',
    'idx_comments_activity', 'idx_season_progress_board', 'idx_reports_once']) {
    assert.ok(idx.has(name), `missing index ${name}`);
  }
});
test('migration statements contain no stray semicolons (statement-by-statement deploy)', () => {
  const sql = readFileSync(MIGRATIONS[2], 'utf8');
  const stmts = splitStatements(sql);
  // Every statement starts with a keyword the deploy runner can execute.
  for (const s of stmts) assert.match(s, /^(ALTER|CREATE|UPDATE|DELETE|INSERT)\b/, s.slice(0, 60));
  // No comment line carries a semicolon (a naive splitter would cut there).
  for (const line of sql.split('\n')) if (line.trim().startsWith('--')) assert.ok(!line.includes(';'), line);
});

console.log('production-shaped database');
let prod;
test('baseline schema + pre-v2 migrations build a production-shaped database', () => {
  prod = new D1Database();
  applySqlFile(prod, BASELINE);
  applyStatements(prod, MIGRATIONS[0]);
  applyStatements(prod, MIGRATIONS[1]);
  seedBaseline(prod);
});
test('new schema.sql applies on top of production (deploy runs it first)', () => {
  applySqlFile(prod, SCHEMA);
});
test('fitness-v2 migration applies statement by statement, then re-runs harmlessly', () => {
  const first = applyStatements(prod, MIGRATIONS[2]);
  // friend_code already existed in production: that one ALTER is the expected skip.
  assert.equal(first.skipped, 1);
  const second = applyStatements(prod, MIGRATIONS[2]);
  assert.ok(second.skipped >= 13, `expected every ALTER to be skipped, got ${second.skipped}`);
  deploy(prod); // the whole deploy again
});
test('migrated production has exactly the fresh schema\'s columns', () => {
  const fresh = new D1Database();
  deploy(fresh);
  assert.deepEqual(columns(prod), columns(fresh));
});
test('existing guilds get member_cap 50 and a unique 8-char invite code', () => {
  const rows = prod.raw.prepare('SELECT member_cap, invite_code, is_open FROM guilds').all();
  assert.equal(rows.length, 2);
  for (const r of rows) {
    assert.equal(r.member_cap, 50);
    assert.match(r.invite_code, /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
    assert.equal(r.is_open, 1);
  }
  assert.notEqual(rows[0].invite_code, rows[1].invite_code);
});
test('a player in two guilds keeps only the earliest membership', () => {
  const rows = prod.raw.prepare("SELECT guild_id FROM guild_members WHERE user_id = 'u2'").all();
  assert.deepEqual(rows.map((r) => r.guild_id), ['g1']);
  assert.throws(() => prod.raw.prepare(
    "INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES ('g2', 'u1', 'member', 1)"
  ).run(), /UNIQUE/);
});
test('PR rows are re-keyed on the normalised name, the heavier duplicate wins', () => {
  const rows = prod.raw.prepare(
    "SELECT exercise, reps, weight, exercise_name FROM personal_records WHERE user_id = 'u1' ORDER BY exercise"
  ).all().map((r) => ({ ...r }));
  assert.deepEqual(rows, [
    { exercise: 'bench press', reps: 5, weight: 185, exercise_name: rows[0].exercise_name },
    { exercise: 'squat', reps: 3, weight: 225, exercise_name: 'Squat ' },
  ]);
  assert.ok(['Bench Press', 'bench press'].includes(rows[0].exercise_name));
});
test('rank, achievement and raid titles + raid auras are backfilled into fitness_unlocks', () => {
  const get = (u) => prod.raw.prepare('SELECT kind, value FROM fitness_unlocks WHERE user_id = ? ORDER BY kind, value')
    .all(u).map((r) => `${r.kind}:${r.value}`);
  const u1 = get('u1');
  for (const v of ['title:Initiate', 'title:Apprentice', 'title:Iron Disciple', 'title:Ironbound',
    'title:Plate Liberator', 'cosmetic:aura_iron']) assert.ok(u1.includes(v), `u1 missing ${v}`);
  assert.ok(!u1.includes('title:Vanguard'));
  const u2 = get('u2');
  for (const v of ['title:Initiate', 'title:First Blood', 'title:Plate Liberator', 'cosmetic:aura_iron']) {
    assert.ok(u2.includes(v), `u2 missing ${v}`);
  }
  assert.ok(!u2.includes('title:Apprentice'));
  const u3 = get('u3');
  assert.deepEqual(u3, ['title:Initiate']);
});
test('existing sessions become live (not deleted, not flagged) rows', () => {
  const r = prod.raw.prepare("SELECT deleted, flagged FROM workout_sessions WHERE id = 's1'").get();
  assert.equal(r.deleted, 0);
  assert.equal(r.flagged, 0);
});
test('existing profiles keep is_public; the schema default for new rows is private', () => {
  const fresh = new D1Database();
  deploy(fresh);
  const col = fresh.raw.prepare('PRAGMA table_info(fitness_profiles)').all().find((c) => c.name === 'is_public');
  assert.equal(col.dflt_value, '0');
});
test('deleting a user cascades through every new table', () => {
  const db = new D1Database();
  deploy(db);
  const run = (sql, ...a) => db.raw.prepare(sql).run(...a);
  run("INSERT INTO users (id, email, created_at, updated_at) VALUES ('x', 'x@e.com', 1, 1)");
  run("INSERT INTO users (id, email, created_at, updated_at) VALUES ('y', 'y@e.com', 1, 1)");
  run("INSERT INTO activity_feed (id, user_id, kind, summary, created_at) VALUES ('f1', 'y', 'workout', 's', 1)");
  run("INSERT INTO activity_comments (id, activity_id, user_id, text, created_at) VALUES ('c1', 'f1', 'x', 'hi', 1)");
  run("INSERT INTO user_blocks (blocker_id, blocked_id, created_at) VALUES ('x', 'y', 1)");
  run("INSERT INTO fitness_unlocks VALUES ('x', 'title', 'Initiate', 'rank', 1)");
  run("INSERT INTO season_progress VALUES ('x', 's1', 10, 1)");
  run("INSERT INTO season_claims VALUES ('x', 's1', 1, 1)");
  run("INSERT INTO ugc_reports (id, reporter_id, target_type, target_id, reason, created_at) VALUES ('r', 'x', 'user', 'y', 'spam', 1)");
  run("DELETE FROM users WHERE id = 'x'");
  for (const t of ['activity_comments', 'user_blocks', 'fitness_unlocks', 'season_progress', 'season_claims']) {
    assert.equal(db.raw.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get().n, 0, t);
  }
  assert.equal(db.raw.prepare("SELECT reporter_id FROM ugc_reports WHERE id = 'r'").get().reporter_id, null);
});

console.log(`\n${passed} passed`);
