/**
 * Talent tree validation + server-side effect math.
 * Run: node App/Backend/tests/talents.test.mjs
 */
import assert from 'node:assert/strict';
import {
  TALENT_TREE, validateSpend, xpMultiplier, applyTalentEffects,
  streakShieldDays, bonusTalentPoints, pointsSpent, ranksFromRows, POINTS_PER_TIER,
} from '../functions/_lib/talents.js';

let passed = 0;
function test(name, fn) {
  try { fn(); passed += 1; console.log(`  ok  ${name}`); }
  catch (e) { console.error(`FAIL  ${name}\n      ${e.message}`); process.exitCode = 1; }
}

// ---- tree integrity ---------------------------------------------------------
test('every prerequisite exists, is in the same branch and a lower tier', () => {
  const ids = new Map(TALENT_TREE.nodes.map((n) => [n.id, n]));
  for (const n of TALENT_TREE.nodes) {
    for (const r of n.requires) {
      const p = ids.get(r.id);
      assert.ok(p, `${n.id} requires missing ${r.id}`);
      assert.equal(p.branch, n.branch);
      assert.ok(p.tier < n.tier);
      assert.ok(r.rank <= p.max_rank);
    }
  }
});
test('three branches, every node in a declared branch', () => {
  const branches = new Set(TALENT_TREE.branches.map((b) => b.id));
  assert.equal(branches.size, 3);
  for (const n of TALENT_TREE.nodes) assert.ok(branches.has(n.branch), n.id);
});

// ---- validation -------------------------------------------------------------
test('unknown talent rejected', () => assert.equal(validateSpend({}, 5, 'nope').ok, false));
test('no points rejected', () => assert.match(validateSpend({}, 0, 'momentum').error, /No unspent/));
test('tier 1 spend ok', () => assert.equal(validateSpend({}, 1, 'momentum').ok, true));
test('max rank rejected', () => assert.match(validateSpend({ momentum: 5 }, 1, 'momentum').error, /max rank/));
test('tier 2 needs branch points and prereq', () => {
  assert.match(validateSpend({}, 5, 'streak_shield').error, new RegExp(`Spend ${POINTS_PER_TIER}`));
  assert.match(validateSpend({ momentum: 2, second_wind: 0, rally: 3 }, 5, 'streak_shield').error, /Spend/);
  assert.equal(validateSpend({ momentum: 3 }, 5, 'streak_shield').ok, true);
});
test('cross-branch points do not satisfy tier gate', () => {
  assert.equal(validateSpend({ momentum: 5 }, 5, 'guild_banner').ok, false);
});
test('tier 3 gate', () => {
  assert.equal(validateSpend({ momentum: 3, streak_shield: 1 }, 5, 'second_wind').error, `Spend ${2 * POINTS_PER_TIER} points in endurance first`);
  assert.equal(validateSpend({ momentum: 5, streak_shield: 1 }, 5, 'second_wind').ok, true);
});
test('ranksFromRows + pointsSpent', () => {
  const r = ranksFromRows([{ talent_id: 'momentum', rank: 2 }, { talent_id: 'rally', rank: '3' }]);
  assert.deepEqual(r, { momentum: 2, rally: 3 });
  assert.equal(pointsSpent(r), 5);
});

// ---- effect math ------------------------------------------------------------
test('no talents = 1.0x', () => assert.equal(xpMultiplier({}, {}), 1));
test('Momentum +5%/rank', () => {
  assert.equal(xpMultiplier({ momentum: 3 }, {}), 1.15);
  assert.equal(applyTalentEffects(100, { momentum: 5 }, {}), 125);
});
test('Iron Foundation only on heavy sessions', () => {
  assert.equal(xpMultiplier({ iron_foundation: 5 }, { volume: 4999 }), 1);
  assert.equal(xpMultiplier({ iron_foundation: 5 }, { volume: 5000 }), 1.10);
  assert.equal(xpMultiplier({ iron_foundation: 5, heavy_hands: 3 }, { volume: 20000 }), 1.19);
});
test('Second Wind needs 7-day streak', () => {
  assert.equal(xpMultiplier({ second_wind: 3 }, { streak: 6 }), 1);
  assert.equal(xpMultiplier({ second_wind: 3 }, { streak: 7 }), 1.12);
});
test('Rally caps at 5 friends; Guild Banner needs a guild', () => {
  assert.equal(xpMultiplier({ rally: 2 }, { friends: 9 }), 1.10);
  assert.equal(xpMultiplier({ rally: 2 }, { friends: 0 }), 1);
  assert.equal(xpMultiplier({ guild_banner: 3 }, { inGuild: false }), 1);
  assert.equal(xpMultiplier({ guild_banner: 3 }, { inGuild: true }), 1.09);
});
test('effects are additive, rounded', () => {
  assert.equal(applyTalentEffects(333, { momentum: 5, rally: 5 }, { friends: 5 }), 500); // 1.5x
});
test('streak shield days', () => {
  assert.equal(streakShieldDays({}), 0);
  assert.equal(streakShieldDays({ streak_shield: 2 }), 2);
});
test('bonus talent points at milestones', () => {
  assert.equal(bonusTalentPoints({}, 1, 20), 0);
  assert.equal(bonusTalentPoints({ titan: 1 }, 9, 10), 1);
  assert.equal(bonusTalentPoints({ titan: 1 }, 10, 19), 0);
  assert.equal(bonusTalentPoints({ mentor: 1 }, 1, 20), 4);
  assert.equal(bonusTalentPoints({ mentor: 1, titan: 1 }, 1, 20), 6);
});

// ---- Streak Shield, applied by the streak rules in _lib/streaks.js ----------
// (The worker's old streakAfter helper moved there as applySessionDay, which
// adds local days and streak freezes on top of the same shield rule.)
const { applySessionDay } = await import('../functions/_lib/streaks.js');
const streakAfter = (last, day, shield = 0) =>
  applySessionDay({ lastDate: last, current: last ? 3 : 0, longest: 3, freezes: 0 }, day, shield).transition;

test('streak: unshielded', () => {
  assert.equal(streakAfter(null, '2026-01-02'), 'start');
  assert.equal(streakAfter('2026-01-01', '2026-01-02'), 'continue');
  assert.equal(streakAfter('2026-01-01', '2026-01-01'), 'same-day');
  assert.equal(streakAfter('2026-01-01', '2026-01-03'), 'reset');
});
test('streak: shield forgives exactly N missed days', () => {
  assert.equal(streakAfter('2026-01-01', '2026-01-03', 1), 'continue');
  assert.equal(streakAfter('2026-01-01', '2026-01-04', 1), 'reset');
  assert.equal(streakAfter('2026-01-01', '2026-01-04', 2), 'continue');
  assert.equal(streakAfter('2026-01-01', '2026-01-05', 2), 'reset');
});
test('streak: the shield is applied before banked freezes and costs none of them', () => {
  const s = applySessionDay({ lastDate: '2026-01-01', current: 3, longest: 3, freezes: 2 }, '2026-01-04', 1);
  assert.deepEqual([s.transition, s.freezes, s.freezesUsed], ['continue', 1, 1]);
});

console.log(`\n${passed} passed${process.exitCode ? ', with failures' : ''}`);
