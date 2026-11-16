/**
 * POST /api/fitness/sync against the real worker and a real SQLite schema:
 * server-side totals, plausibility caps, replay acks, edits, deletes, PR
 * baselines, local-day streaks with freezes, and the pull cursor.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/api-sync.test.mjs
 */

import assert from 'node:assert/strict';
import { clock, makeEnv, createUser, call, runner, session } from './lib/harness.mjs';

const { test, run } = runner('sync v2');
const DAY = 86400;

const profileRow = (env, id) => ({ ...env.DB.raw.prepare('SELECT * FROM fitness_profiles WHERE user_id = ?').get(id) });
const sync = (env, u, sessions, extra = {}) => call(env, u, 'POST', 'sync', { since: 0, sessions, ...extra });

test('lazy profile: a member with no fitness row can sync', async () => {
  const env = makeEnv();
  const u = createUser(env, { profile: false });
  const res = await sync(env, u, [session([['Bench Press', [[5, 100]]]])]);
  assert.equal(res.status, 200);
  assert.equal(res.body.accepted.length, 1);
  assert.equal(res.body.profile.is_public, false);
  assert.match(res.body.profile.display_name, /^Athlete\d{4}$/);
});

test('v2 totals are recomputed from the sets; client totals are ignored', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const s = session([['Squat', [[5, 200], [5, 200]]], ['Row', [[10, 100]]]]);
  s.total_volume = 999999; // lie
  s.total_reps = 5000;
  const res = await sync(env, u, [s]);
  assert.equal(res.status, 200);
  const row = env.DB.raw.prepare('SELECT total_volume, total_reps, flagged FROM workout_sessions WHERE id = ?').get(s.id);
  assert.equal(row.total_volume, 3000);
  assert.equal(row.total_reps, 20);
  assert.equal(row.flagged, 0);
  assert.equal(res.body.profile.total_volume, 3000);
  assert.ok(res.body.xp_gained > 0);
});

test('v1 payloads: volume from the sets, reps from the client', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const s = { id: 'v1-a', performed_at: clock.now - 60, duration_secs: 1800, total_volume: 5000, total_reps: 140, client_rev: 1,
    payload: { exercises: [{ name: 'Bench Press', sets: [{ reps: 10, weight: 100 }] }] } };
  const res = await sync(env, u, [s]);
  assert.equal(res.status, 200);
  const row = env.DB.raw.prepare('SELECT total_volume, total_reps FROM workout_sessions WHERE id = ?').get('v1-a');
  assert.equal(row.total_volume, 1000);
  assert.equal(row.total_reps, 140);
  // v1 aggregate-only session (no payload): client totals within caps.
  const agg = await sync(env, u, [{ id: 'v1-b', performed_at: clock.now - 30, duration_secs: 600, total_volume: 2500, total_reps: 50, client_rev: 1 }]);
  assert.deepEqual(agg.body.accepted, ['v1-b']);
  assert.equal(profileRow(env, u.id).total_volume, 3500);
});

test('over a cap: stored for history, flagged, earns nothing, counts toward no total', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const heavy = session([['Bench Press', [[5, 2000]]]]);
  const future = session([['Bench Press', [[5, 100]]]], { at: clock.now + 3600 });
  const res = await sync(env, u, [heavy, future]);
  assert.deepEqual(new Set(res.body.accepted), new Set([heavy.id, future.id]));
  assert.equal(res.body.xp_gained, 0);
  assert.equal(res.body.raid, null);
  const p = profileRow(env, u.id);
  assert.equal(p.total_workouts, 0);
  assert.equal(p.total_volume, 0);
  assert.equal(p.xp, 0);
  const rows = env.DB.raw.prepare('SELECT id, flagged, flag_reason, xp_earned FROM workout_sessions ORDER BY id').all();
  assert.ok(rows.every((r) => r.flagged === 1 && r.xp_earned === 0));
  assert.ok(rows.some((r) => /weight_cap/.test(r.flag_reason)));
  assert.ok(rows.some((r) => /performed_at_future/.test(r.flag_reason)));
  // Flagged sessions set no PRs and post nothing to the feed.
  assert.equal(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM personal_records').get().n, 0);
  assert.equal(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM activity_feed').get().n, 0);
  // ...but other devices still receive them.
  assert.equal(res.body.sessions.filter((s) => s.flagged).length, 2);
});

test('too many total reps (bodyweight farm) is flagged too', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const farm = session([...Array(60)].map((_, i) => [`Move ${i}`, [...Array(40)].map(() => [100, 0])]));
  const res = await sync(env, u, [farm]);
  assert.equal(res.body.xp_gained, 0);
  assert.match(env.DB.raw.prepare('SELECT flag_reason FROM workout_sessions').get().flag_reason, /reps_total_cap/);
});

test('replay with the same or a lower client_rev is acknowledged without re-awarding', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const s = session([['Deadlift', [[5, 300]]]], { rev: 2 });
  const first = await sync(env, u, [s]);
  const xpAfter = profileRow(env, u.id).xp;
  assert.ok(first.body.xp_gained > 0);
  const again = await sync(env, u, [s]);
  assert.deepEqual(again.body.accepted, [s.id]);
  assert.equal(again.body.xp_gained, 0);
  const older = await sync(env, u, [{ ...s, client_rev: 1 }]);
  assert.deepEqual(older.body.accepted, [s.id]);
  const p = profileRow(env, u.id);
  assert.equal(p.xp, xpAfter);
  assert.equal(p.total_workouts, 1);
  assert.equal(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM xp_transactions').get().n >= 1, true);
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM activity_feed WHERE kind = 'workout'").get().n, 1);
});

test('an edit (higher client_rev) moves lifetime totals by the delta; XP is not re-awarded', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const s = session([['Squat', [[5, 200]]]]);
  await sync(env, u, [s]);
  const before = profileRow(env, u.id);
  assert.equal(before.total_volume, 1000);
  const edited = session([['Squat', [[5, 200], [5, 220]]]], { id: s.id, rev: 2, at: s.performed_at });
  const res = await sync(env, u, [edited]);
  assert.deepEqual(res.body.accepted, [s.id]);
  assert.equal(res.body.xp_gained, 0);
  const after = profileRow(env, u.id);
  assert.equal(after.total_volume, 2100);
  assert.equal(after.total_reps, 10);
  assert.equal(after.total_workouts, 1);
  assert.equal(after.xp, before.xp);
  const pulled = res.body.sessions.find((x) => x.id === s.id);
  assert.equal(pulled.client_rev, 2);
  assert.equal(pulled.payload.exercises[0].sets.length, 2);
});

test('a delete keeps a tombstone, removes its totals and feed posts, never claws back XP', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const keep = session([['Bench Press', [[5, 100]]]], { at: clock.now - 7200 });
  const gone = session([['Bench Press', [[5, 150]]]]);
  await sync(env, u, [keep, gone]);
  const before = profileRow(env, u.id);
  const res = await sync(env, u, [{ id: gone.id, performed_at: gone.performed_at, client_rev: 2, deleted: true }]);
  assert.deepEqual(res.body.accepted, [gone.id]);
  const after = profileRow(env, u.id);
  assert.equal(after.total_workouts, 1);
  assert.equal(after.total_volume, 500);
  assert.equal(after.xp, before.xp);
  const tomb = res.body.sessions.find((x) => x.id === gone.id);
  assert.equal(tomb.deleted, true);
  assert.deepEqual(tomb.payload, {});
  const posts = env.DB.raw.prepare("SELECT payload FROM activity_feed WHERE kind = 'workout'").all();
  assert.equal(posts.length, 1);
  assert.equal(JSON.parse(posts[0].payload).session_id, keep.id);
  // Replaying the original (rev 1) after the delete changes nothing.
  const replay = await sync(env, u, [gone]);
  assert.deepEqual(replay.body.accepted, [gone.id]);
  assert.equal(profileRow(env, u.id).total_workouts, 1);
});

test('a session deleted before it ever synced is stored as a tombstone only', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const res = await sync(env, u, [{ id: 'never', performed_at: clock.now - 10, client_rev: 1, deleted: true }]);
  assert.deepEqual(res.body.accepted, ['never']);
  assert.equal(profileRow(env, u.id).total_workouts, 0);
  assert.equal(res.body.sessions[0].deleted, true);
});

test("another member's session id is rejected, not overwritten", async () => {
  const env = makeEnv();
  const a = createUser(env);
  const b = createUser(env);
  const s = session([['Squat', [[5, 100]]]]);
  await sync(env, a, [s]);
  const res = await sync(env, b, [{ ...s, client_rev: 5 }]);
  assert.deepEqual(res.body.accepted, []);
  assert.deepEqual(res.body.rejected, [{ id: s.id, error: 'id_conflict' }]);
  assert.equal(env.DB.raw.prepare('SELECT user_id FROM workout_sessions WHERE id = ?').get(s.id).user_id, a.id);
});

test('garbage in the session list is rejected item by item, never a 500', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const res = await sync(env, u, [null, 7, { id: 42 }, { id: '' }, session([['Curl', [[10, 30]]]], { id: 'ok-1' })]);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.accepted, ['ok-1']);
  assert.equal(res.body.rejected.length, 4);
  assert.equal((await call(env, u, 'POST', 'sync', '{not json')).status, 400);
  assert.equal((await call(env, u, 'POST', 'sync', [])).status, 400);
});

test('only the first 50 sessions are handled per request; the rest stay queued', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const many = [...Array(60)].map((_, i) => session([['Curl', [[10, 30]]]], { at: clock.now - 600 + i }));
  const res = await sync(env, u, many);
  assert.equal(res.body.accepted.length, 50);
  const rest = await sync(env, u, many);
  assert.equal(rest.body.accepted.length, 50); // the same 50 again: all replays, acked
  assert.equal(profileRow(env, u.id).total_workouts, 50);
  const last = await sync(env, u, many.slice(50));
  assert.equal(last.body.accepted.length, 10);
  assert.equal(profileRow(env, u.id).total_workouts, 60);
});

test('PRs: first log of an exercise is a baseline, beating it is a PR, names normalise', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const prPosts = () => env.DB.raw.prepare("SELECT COUNT(*) AS n FROM activity_feed WHERE kind = 'pr'").get().n;
  await sync(env, u, [session([['Bench Press', [[5, 185]]]], { at: clock.now - 4000 })]);
  assert.equal(prPosts(), 0, 'baseline is not a PR');
  const rec = env.DB.raw.prepare('SELECT exercise, exercise_name, weight FROM personal_records').get();
  assert.deepEqual({ ...rec }, { exercise: 'bench press', exercise_name: 'Bench Press', weight: 185 });

  await sync(env, u, [session([['  bench press ', [[5, 195]]]], { at: clock.now - 3000 })]);
  assert.equal(prPosts(), 1, 'beating the weight at a known rep count is a PR');

  // New rep count with a lower estimated 1RM: recorded, not a PR.
  await sync(env, u, [session([['Bench Press', [[3, 200]]]], { at: clock.now - 2000 })]);
  assert.equal(prPosts(), 1);
  assert.equal(env.DB.raw.prepare("SELECT weight FROM personal_records WHERE reps = 3").get().weight, 200);
  // New rep count that beats the best estimated 1RM: a PR.
  await sync(env, u, [session([['Bench Press', [[3, 230]]]], { at: clock.now - 1000 })]);
  assert.equal(prPosts(), 2);
});

test('PRs: keyed on exercise_id when present', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const id = 'Barbell_Bench_Press_-_Medium_Grip';
  await sync(env, u, [session([['Bench Press', [[5, 185]], { exercise_id: id, category: 'strength' }]], { at: clock.now - 500 })]);
  await sync(env, u, [session([['Flat Bench', [[5, 190]], { exercise_id: id }]])]);
  const rows = env.DB.raw.prepare('SELECT exercise, weight FROM personal_records').all();
  assert.deepEqual(rows.map((r) => ({ ...r })), [{ exercise: id, weight: 190 }]);
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) AS n FROM activity_feed WHERE kind = 'pr'").get().n, 1);
  const prof = await call(env, u, 'GET', 'profile');
  assert.equal(prof.body.personal_records[0].exercise, 'Flat Bench');
  assert.equal(prof.body.personal_records[0].exercise_key, id);
});

test('streaks: days are local days (tz_offset_min), not UTC days', async () => {
  const env = makeEnv();
  const u = createUser(env);
  clock.now = Date.UTC(2026, 9, 28, 20, 0) / 1000;
  // 04:00Z and 16:00Z on the 28th are the 27th 21:00 and the 28th 09:00 in UTC−7.
  const evening = session([['Squat', [[5, 100]]]], { at: Date.UTC(2026, 9, 28, 4, 0) / 1000 });
  const morning = session([['Squat', [[5, 100]]]], { at: Date.UTC(2026, 9, 28, 16, 0) / 1000 });
  const res = await sync(env, u, [evening, morning], { tz_offset_min: -420 });
  assert.equal(res.body.profile.current_streak, 2);
  assert.equal(res.body.profile.tz_offset_min, -420);
  assert.equal(profileRow(env, u.id).last_workout_date, '2026-10-28');
});

test('streaks: a missed day uses a banked freeze; with none banked the streak resets', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const d = (day, h = 12) => Date.UTC(2026, 10, day, h) / 1000;
  clock.now = d(1, 20);
  await sync(env, u, [session([['Squat', [[5, 100]]]], { at: d(1) })]);
  env.DB.raw.prepare('UPDATE fitness_profiles SET streak_freezes = 1 WHERE user_id = ?').run(u.id);
  clock.now = d(3, 20);
  let res = await sync(env, u, [session([['Squat', [[5, 100]]]], { at: d(3) })]); // missed the 2nd
  assert.equal(res.body.profile.current_streak, 2);
  assert.equal(res.body.profile.streak_freezes, 0);
  clock.now = d(5, 20);
  res = await sync(env, u, [session([['Squat', [[5, 100]]]], { at: d(5) })]); // missed the 4th, no freeze
  assert.equal(res.body.profile.current_streak, 1);
});

test('streaks: every 7-day milestone banks a freeze (max 3)', async () => {
  const env = makeEnv();
  const u = createUser(env);
  env.DB.raw.prepare('UPDATE fitness_profiles SET streak_freezes = 2 WHERE user_id = ?').run(u.id);
  const sessions = [];
  for (let day = 1; day <= 14; day += 1) sessions.push(session([['Row', [[10, 50]]]], { at: Date.UTC(2026, 10, day, 12) / 1000 }));
  clock.now = Date.UTC(2026, 10, 14, 20) / 1000;
  const res = await sync(env, u, sessions);
  assert.equal(res.body.profile.current_streak, 14);
  assert.equal(res.body.profile.streak_freezes, 3);
});

test('streaks: an abandoned streak reads as 0 and drops off the streak leaderboard', async () => {
  const env = makeEnv();
  const u = createUser(env);
  clock.now = Date.UTC(2026, 10, 2, 20) / 1000;
  await sync(env, u, [1, 2].map((day) => session([['Squat', [[5, 100]]]], { at: Date.UTC(2026, 10, day, 12) / 1000 })));
  assert.equal(profileRow(env, u.id).current_streak, 2);
  clock.now = Date.UTC(2026, 10, 6, 20) / 1000;
  const prof = await call(env, u, 'GET', 'profile');
  assert.equal(prof.body.profile.current_streak, 0);
  assert.equal(prof.body.profile.streak_alive, false);
  assert.equal(profileRow(env, u.id).current_streak, 0);
  assert.equal(profileRow(env, u.id).longest_streak, 2);
});

test('streaks: the streak board zeroes lapsed streaks before ranking (shield talent honoured)', async () => {
  const env = makeEnv();
  const a = createUser(env, { name: 'Lapsed' });
  const b = createUser(env, { name: 'Shielded' });
  const set = (id, streak, date) => env.DB.raw.prepare(
    'UPDATE fitness_profiles SET current_streak = ?, last_workout_date = ? WHERE user_id = ?'
  ).run(streak, date, id);
  clock.now = Date.UTC(2026, 10, 10, 12) / 1000;
  set(a.id, 30, '2026-11-07'); // missed the 8th and 9th
  set(b.id, 5, '2026-11-08');  // missed the 9th, has one shield rank
  env.DB.raw.prepare("INSERT INTO talents (user_id, talent_id, rank) VALUES (?, 'streak_shield', 1)").run(b.id);
  const res = await call(env, a, 'GET', 'leaderboard', undefined, { query: 'metric=streak' });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.entries.map((e) => [e.display_name, e.current_streak]), [['Shielded', 5], ['Lapsed', 0]]);
  assert.equal(profileRow(env, a.id).current_streak, 0);
});

test('pull: pages by (updated_at, id) with a cursor; has_more is honest', async () => {
  const env = makeEnv();
  const u = createUser(env);
  clock.now = Date.UTC(2026, 10, 20, 12) / 1000;
  const all = [];
  for (let batch = 0; batch < 6; batch += 1) {
    const list = [...Array(45)].map((_, i) => session([['Curl', [[10, 20]]]], { at: clock.now - 10000 + batch * 100 + i }));
    all.push(...list);
    await sync(env, u, list);
    clock.now += 1;
  }
  const seen = new Set();
  let since = 0;
  let calls = 0;
  for (;;) {
    const res = await call(env, u, 'POST', 'sync', { since, sessions: [] });
    calls += 1;
    for (const s of res.body.sessions) seen.add(s.id);
    assert.ok(res.body.sessions.length <= 200);
    // Ascending (updated_at, id).
    const keys = res.body.sessions.map((s) => `${s.updated_at}|${s.id}`);
    assert.deepEqual(keys, [...keys].sort());
    if (!res.body.has_more) break;
    assert.equal(res.body.cursor, res.body.sessions[res.body.sessions.length - 1].updated_at);
    since = res.body.cursor;
    assert.ok(calls < 10);
  }
  assert.equal(seen.size, all.length);
  assert.ok(calls >= 2);
});

test('pull: a page never ends part-way through a second, and the final cursor trails server_time', async () => {
  const env = makeEnv();
  const u = createUser(env);
  clock.now = Date.UTC(2026, 10, 21, 12) / 1000;
  // 190 sessions in one second, then 30 in the next: the first page must stop
  // at the boundary rather than at row 200.
  for (let i = 0; i < 4; i += 1) await sync(env, u, [...Array(i < 3 ? 50 : 40)].map((_, k) => session([['Curl', [[10, 20]]]], { at: clock.now - 5000 + i * 60 + k })));
  clock.now += 1;
  await sync(env, u, [...Array(30)].map((_, k) => session([['Curl', [[10, 20]]]], { at: clock.now - 100 + k })));
  const first = await call(env, u, 'POST', 'sync', { since: 0, sessions: [] });
  assert.equal(first.body.has_more, true);
  assert.equal(first.body.sessions.length, 190);
  const second = await call(env, u, 'POST', 'sync', { since: first.body.cursor, sessions: [] });
  assert.equal(second.body.has_more, false);
  assert.equal(second.body.sessions.length, 30);
  assert.equal(second.body.cursor, second.body.server_time - 1);
});

test('pull: v1 clients that page with server_time still get every row when there are ≤ 200', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const s = session([['Curl', [[10, 20]]]]);
  const first = await sync(env, u, [s]);
  assert.equal(first.body.sessions.length, 1);
  clock.now += 5;
  const later = await call(env, u, 'POST', 'sync', { since: first.body.server_time, sessions: [] });
  assert.equal(later.status, 200);
  assert.equal(later.body.sessions.length, 0);
  assert.equal(later.body.has_more, false);
});

await run();
