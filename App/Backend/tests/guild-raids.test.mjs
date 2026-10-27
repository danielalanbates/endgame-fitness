/**
 * Guild raid unit tests: damage maths and the deterministic weekly boss
 * rotation. No framework — plain assertions.
 *
 * Run: node App/Backend/tests/guild-raids.test.mjs
 */

import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import assert from 'node:assert/strict';

const here = dirname(fileURLToPath(import.meta.url));

// _lib/raids.js is an ES module with a .js extension and no package.json, so
// node would treat it as CommonJS. Copy it to a .mjs scratch file to import.
const source = readFileSync(join(here, '..', 'functions', '_lib', 'raids.js'), 'utf8');
const scratch = mkdtempSync(join(tmpdir(), 'raids-test-'));
const modulePath = join(scratch, 'raids.mjs');
writeFileSync(modulePath, source);

const {
  BOSS_CATALOG, WEEK_SECS, weekStart, weekIndex, bossForWeek, hpForGuild,
  raidDamage, DAMAGE_PER_LB, DAMAGE_PER_PR, MAX_PRS_PER_SESSION,
} = await import(`file://${modulePath}`);

let passed = 0;
const test = (name, fn) => {
  try { fn(); passed += 1; console.log(`  ok   ${name}`); }
  catch (e) { console.log(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
};

const utc = (iso) => Math.floor(Date.parse(iso) / 1000);

console.log('damage');
test('volume alone: 1 damage per lb', () => {
  assert.equal(raidDamage({ total_volume: 12345 }), 12345 * DAMAGE_PER_LB);
});
test('each PR adds a flat 250', () => {
  assert.equal(raidDamage({ total_volume: 1000, pr_count: 2 }), 1000 + 2 * DAMAGE_PER_PR);
  assert.equal(DAMAGE_PER_PR, 250);
});
test('rounds to an integer', () => {
  assert.equal(raidDamage({ total_volume: 100.4 }), 100);
  assert.equal(Number.isInteger(raidDamage({ total_volume: 99.5, pr_count: 1 })), true);
});
test('negative, NaN and missing inputs deal 0 (not negative) damage', () => {
  assert.equal(raidDamage({ total_volume: -500 }), 0);
  assert.equal(raidDamage({ total_volume: 'nope', pr_count: 'x' }), 0);
  assert.equal(raidDamage(), 0);
  assert.equal(raidDamage({ total_volume: 10, pr_count: -3 }), 10);
});
test('PR count is capped so a patched client cannot mint damage', () => {
  assert.equal(raidDamage({ total_volume: 0, pr_count: 10000 }), MAX_PRS_PER_SESSION * DAMAGE_PER_PR);
});
test('fractional PR counts floor', () => {
  assert.equal(raidDamage({ total_volume: 0, pr_count: 1.9 }), DAMAGE_PER_PR);
});

console.log('week rotation');
test('weekStart is Monday 00:00 UTC', () => {
  // 2026-08-29 is a Saturday; its week began Monday 2026-08-24.
  assert.equal(weekStart(utc('2026-08-29T15:00:00Z')), utc('2026-08-24T00:00:00Z'));
  const d = new Date(weekStart(utc('2026-08-29T15:00:00Z')) * 1000);
  assert.equal(d.getUTCDay(), 1);
});
test('a Monday at 00:00 starts its own week; one second earlier is the previous week', () => {
  const monday = utc('2026-08-24T00:00:00Z');
  assert.equal(weekStart(monday), monday);
  assert.equal(weekStart(monday - 1), monday - WEEK_SECS);
});
test('Sunday 23:59:59 UTC still belongs to the same week as the preceding Monday', () => {
  assert.equal(weekStart(utc('2026-08-30T23:59:59Z')), utc('2026-08-24T00:00:00Z'));
  assert.equal(weekStart(utc('2026-08-31T00:00:00Z')), utc('2026-08-31T00:00:00Z'));
});
test('weekIndex is stable across a week and increments by exactly one', () => {
  const a = weekIndex(utc('2026-08-24T00:00:00Z'));
  assert.equal(weekIndex(utc('2026-08-30T23:59:59Z')), a);
  assert.equal(weekIndex(utc('2026-08-31T00:00:00Z')), a + 1);
});
test('catalog has 8 bosses with unique ids', () => {
  assert.equal(BOSS_CATALOG.length, 8);
  assert.equal(new Set(BOSS_CATALOG.map((b) => b.id)).size, 8);
  for (const b of BOSS_CATALOG) {
    assert.ok(b.name && b.flavor && b.symbol && b.base_hp > 0 && b.reward_xp > 0 && b.reward_title);
    assert.equal(b.gradient.length, 2);
  }
});
test('bossForWeek is deterministic within a week', () => {
  const a = bossForWeek(utc('2026-08-24T00:00:00Z'));
  const b = bossForWeek(utc('2026-08-30T23:59:59Z'));
  assert.equal(a.id, b.id);
});
test('bossForWeek cycles through the whole catalog in order', () => {
  const start = utc('2026-08-24T00:00:00Z');
  const seen = [];
  for (let w = 0; w < BOSS_CATALOG.length; w += 1) seen.push(bossForWeek(start + w * WEEK_SECS).id);
  assert.deepEqual([...seen].sort(), BOSS_CATALOG.map((b) => b.id).sort());
  assert.equal(bossForWeek(start + BOSS_CATALOG.length * WEEK_SECS).id, seen[0]);
  const i = BOSS_CATALOG.findIndex((b) => b.id === seen[0]);
  assert.equal(seen[1], BOSS_CATALOG[(i + 1) % BOSS_CATALOG.length].id);
});
test('this week (2026-08-29) resolves to a catalog boss', () => {
  const boss = bossForWeek(utc('2026-08-29T12:00:00Z'));
  assert.ok(BOSS_CATALOG.some((b) => b.id === boss.id));
});

console.log('hp scaling');
test('hp scales linearly with members and is clamped 1..50 (the guild cap)', () => {
  const boss = BOSS_CATALOG[0];
  assert.equal(hpForGuild(boss, 1), boss.base_hp);
  assert.equal(hpForGuild(boss, 4), boss.base_hp * 4);
  assert.equal(hpForGuild(boss, 0), boss.base_hp);
  assert.equal(hpForGuild(boss, 999), boss.base_hp * 50);
  assert.equal(hpForGuild(boss, 30), boss.base_hp * 30);
});

console.log('achievement catalog');
const game = await import(`file://${join(here, '..', 'functions', '_lib', 'game.js')}`);
test('raid_slayer is in the shared achievement catalog and unlocks on raids_won', () => {
  const entry = game.achievementCatalog().find((a) => a.id === 'raid_slayer');
  assert.ok(entry, 'raid_slayer missing from game.js ACHIEVEMENTS');
  assert.ok(entry.xp > 0 && entry.title && entry.icon);
  const base = { total_workouts: 0, longest_streak: 0, total_volume: 0, level: 1, friend_count: 0, in_guild: false };
  assert.equal(game.newlyUnlocked({ ...base, raids_won: 0 }, []).some((a) => a.id === 'raid_slayer'), false);
  assert.equal(game.newlyUnlocked({ ...base, raids_won: 1 }, []).some((a) => a.id === 'raid_slayer'), true);
  assert.equal(game.newlyUnlocked({ ...base, raids_won: 1 }, ['raid_slayer']).some((a) => a.id === 'raid_slayer'), false);
});

console.log(`\n${passed} passed${process.exitCode ? ', some FAILED' : ''}`);
