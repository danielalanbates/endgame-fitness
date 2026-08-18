/**
 * Quest generation and achievement rules — pure-function tests.
 * Run: node App/Backend/tests/game-rules.test.mjs
 */
import assert from 'node:assert/strict';
import {
  boardFor, pickDeterministic, dayKey, weekKey, dayEnd, weekEnd, advance,
  eventForWorkout, newlyUnlocked, achievementCatalog, DAILY_QUESTS, WEEKLY_QUESTS,
  DAILY_COUNT, WEEKLY_COUNT, questId,
} from '../functions/_lib/game.js';

let passed = 0;
const test = (name, fn) => { fn(); passed += 1; console.log(`  ok  ${name}`); };

const T = Date.UTC(2026, 7, 18, 15, 0, 0) / 1000; // Tue 2026-08-18 15:00Z

test('period keys', () => {
  assert.equal(dayKey(T), '2026-08-18');
  assert.equal(weekKey(T), '2026-W34');
  assert.equal(dayEnd(T), Date.UTC(2026, 7, 19) / 1000);
  assert.equal(weekEnd(T), Date.UTC(2026, 7, 24) / 1000); // next Monday 00:00Z
  // Sunday belongs to the week that started the previous Monday.
  const sun = Date.UTC(2026, 7, 23, 23, 0) / 1000;
  assert.equal(weekKey(sun), '2026-W34');
  assert.equal(weekEnd(sun), Date.UTC(2026, 7, 24) / 1000);
  // ISO edge: 2027-01-01 is a Friday → week 53 of 2026.
  assert.equal(weekKey(Date.UTC(2027, 0, 1) / 1000), '2026-W53');
});

test('board is deterministic per user + period', () => {
  const a = boardFor('user-a', T);
  const b = boardFor('user-a', T + 3600);         // same day, later
  assert.deepEqual(a.map((q) => q.id), b.map((q) => q.id));
  assert.equal(a.filter((q) => q.kind === 'daily').length, DAILY_COUNT);
  assert.equal(a.filter((q) => q.kind === 'weekly').length, WEEKLY_COUNT);
  // no duplicate keys within a kind
  const keys = a.map((q) => `${q.kind}:${q.key}`);
  assert.equal(new Set(keys).size, keys.length);
  // ids embed user, kind, period, key
  assert.equal(a[0].id, questId('user-a', 'daily', '2026-08-18', a[0].key));
});

test('board changes across days and users (not stuck on one roll)', () => {
  const days = new Set();
  for (let d = 0; d < 14; d += 1) {
    days.add(boardFor('user-a', T + d * 86400).filter((q) => q.kind === 'daily').map((q) => q.key).join(','));
  }
  assert.ok(days.size > 3, `expected variety across days, got ${days.size}`);
  const users = new Set();
  for (let i = 0; i < 20; i += 1) {
    users.add(boardFor(`user-${i}`, T).filter((q) => q.kind === 'daily').map((q) => q.key).join(','));
  }
  assert.ok(users.size > 3, `expected variety across users, got ${users.size}`);
});

test('weekly board is stable across the whole week and rolls on Monday', () => {
  const mon = Date.UTC(2026, 7, 17, 1) / 1000;
  const sun = Date.UTC(2026, 7, 23, 23) / 1000;
  const nextMon = Date.UTC(2026, 7, 24, 1) / 1000;
  const w = (t) => boardFor('user-a', t).filter((q) => q.kind === 'weekly').map((q) => q.id).join('|');
  assert.equal(w(mon), w(sun));
  assert.notEqual(w(mon), w(nextMon));
});

test('pickDeterministic never repeats and respects count', () => {
  const picks = pickDeterministic(DAILY_QUESTS, 3, 'seed');
  assert.equal(picks.length, 3);
  assert.equal(new Set(picks.map((p) => p.key)).size, 3);
  assert.deepEqual(pickDeterministic(WEEKLY_QUESTS, 2, 'x'), pickDeterministic(WEEKLY_QUESTS, 2, 'x'));
  assert.equal(pickDeterministic(WEEKLY_QUESTS, 99, 'x').length, WEEKLY_QUESTS.length);
});

test('advance applies the right metric and caps at target', () => {
  const ev = eventForWorkout({ total_volume: 6000, total_reps: 80, duration_secs: 1500 });
  assert.equal(advance({ quest_key: 'log_workout', target: 1, progress: 0 }, ev), 1);
  assert.equal(advance({ quest_key: 'volume_5k', target: 5000, progress: 0 }, ev), 5000); // capped
  assert.equal(advance({ quest_key: 'reps_100', target: 100, progress: 30 }, ev), 100);
  assert.equal(advance({ quest_key: 'minutes_30', target: 30, progress: 0 }, ev), 25);
  assert.equal(advance({ quest_key: 'react_friend', target: 1, progress: 0 }, ev), 0); // untouched
  assert.equal(advance({ quest_key: 'react_friend', target: 1, progress: 0 }, { reactions: 1 }), 1);
  assert.equal(advance({ quest_key: 'set_pr', target: 1, progress: 0 }, eventForWorkout({ prs: 2 })), 1);
  assert.equal(advance({ quest_key: 'nope', target: 1, progress: 0.5 }, ev), 0.5);
});

test('achievement rules', () => {
  assert.deepEqual(newlyUnlocked({}, []), []);
  const ids = (s, have = []) => newlyUnlocked(s, have).map((a) => a.id);
  assert.deepEqual(ids({ total_workouts: 1 }), ['first_workout']);
  assert.deepEqual(ids({ total_workouts: 10 }), ['first_workout', 'workouts_10']);
  assert.deepEqual(ids({ total_workouts: 10 }, ['first_workout']), ['workouts_10']);
  assert.deepEqual(ids({ longest_streak: 30 }), ['streak_7', 'streak_30']);
  assert.deepEqual(ids({ total_volume: 100000 }), ['volume_100k']);
  assert.deepEqual(ids({ level: 25 }), ['level_10', 'level_25']);
  assert.deepEqual(ids({ friend_count: 1 }), ['first_friend']);
  assert.deepEqual(ids({ in_guild: true }), ['guild_join']);
  // already unlocked never comes back
  assert.deepEqual(ids({ total_workouts: 500, level: 99, longest_streak: 99, total_volume: 1e9, friend_count: 9, in_guild: true },
    achievementCatalog().map((a) => a.id)), []);
});

test('catalog is JSON-safe and complete', () => {
  const cat = achievementCatalog();
  assert.equal(cat.length, 12);
  for (const a of cat) {
    assert.ok(a.id && a.title && a.rarity && a.xp > 0 && a.icon, JSON.stringify(a));
    assert.equal(typeof a.rule, 'undefined');
  }
  JSON.stringify(cat);
  for (const q of [...DAILY_QUESTS, ...WEEKLY_QUESTS]) {
    assert.ok(q.key && q.title && q.metric && q.target > 0 && q.xp > 0, q.key);
  }
});

console.log(`\n${passed} tests passed`);
