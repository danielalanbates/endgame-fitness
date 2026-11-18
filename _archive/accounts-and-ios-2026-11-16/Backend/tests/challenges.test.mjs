/**
 * Challenge standings + settlement math. Dependency-free.
 * Run: node App/Backend/tests/challenges.test.mjs
 */
import assert from 'node:assert/strict';
import {
  computeStandings, settle, scoreSessions, longestStreakOfDays, validateCreate,
  XP_WIN, XP_LOSS, XP_DRAW, XP_GUILD_TOP, XP_GUILD_PART,
} from '../functions/_lib/challenges.js';

const DAY = 86400;
const T0 = 1_700_000_000;
const s = (dayOffset, vol) => ({ performed_at: T0 + dayOffset * DAY + 3600, total_volume: vol });
let passed = 0;
function test(name, fn) { fn(); passed += 1; console.log('  ok  ' + name); }

test('longestStreakOfDays counts consecutive UTC days, ignores dupes/order', () => {
  assert.equal(longestStreakOfDays([]), 0);
  assert.equal(longestStreakOfDays(['2024-01-03', '2024-01-01', '2024-01-02', '2024-01-02']), 3);
  assert.equal(longestStreakOfDays(['2024-01-01', '2024-01-03']), 1);
  assert.equal(longestStreakOfDays(['2024-01-31', '2024-02-01']), 2);
});

test('scoreSessions per metric', () => {
  const sess = [s(0, 1000), s(0, 500), s(1, 200), s(3, 50)];
  assert.equal(scoreSessions('volume', sess), 1750);
  assert.equal(scoreSessions('workouts', sess), 4);
  assert.equal(scoreSessions('streak', sess), 2);
  assert.throws(() => scoreSessions('bogus', sess));
});

test('computeStandings filters to window and ranks with ties', () => {
  const ch = { metric: 'volume', starts_at: T0, ends_at: T0 + 7 * DAY };
  const parts = [{ user_id: 'a' }, { user_id: 'b' }, { user_id: 'c' }];
  const map = new Map([
    ['a', [s(-1, 99999), s(1, 100), s(2, 100)]],   // day -1 outside window
    ['b', [s(3, 200), s(7, 5000)]],                // day 7 == ends_at → excluded
    ['c', []],
  ]);
  const st = computeStandings(ch, parts, map);
  assert.deepEqual(st.map((r) => [r.user_id, r.score, r.rank, r.sessions]),
    [['a', 200, 1, 2], ['b', 200, 1, 1], ['c', 0, 3, 0]]);
});

test('duel: clear winner awards win/loss XP', () => {
  const ch = { kind: 'duel', metric: 'workouts', starts_at: T0, ends_at: T0 + DAY };
  const st = computeStandings(ch, [{ user_id: 'a' }, { user_id: 'b' }],
    new Map([['a', [s(0, 1), s(0, 1)]], ['b', [s(0, 1)]]]));
  const out = settle(ch, st);
  assert.equal(out.winner_id, 'a');
  assert.equal(out.draw, false);
  assert.deepEqual(out.awards.sort((x, y) => x.user_id.localeCompare(y.user_id)), [
    { user_id: 'a', amount: XP_WIN, reason: 'challenge_win' },
    { user_id: 'b', amount: XP_LOSS, reason: 'challenge_loss' },
  ]);
});

test('duel: tie is a draw with draw XP; nobody trained = no XP', () => {
  const ch = { kind: 'duel', metric: 'volume', starts_at: T0, ends_at: T0 + DAY };
  const tie = settle(ch, computeStandings(ch, [{ user_id: 'a' }, { user_id: 'b' }],
    new Map([['a', [s(0, 100)]], ['b', [s(0, 100)]]])));
  assert.equal(tie.winner_id, null);
  assert.equal(tie.draw, true);
  assert.deepEqual(tie.awards.map((a) => a.amount), [XP_DRAW, XP_DRAW]);

  const empty = settle(ch, computeStandings(ch, [{ user_id: 'a' }, { user_id: 'b' }], new Map()));
  assert.equal(empty.winner_id, null);
  assert.deepEqual(empty.awards, []);
});

test('guild: top gets top XP, others who trained get participation, idle get nothing', () => {
  const ch = { kind: 'guild', metric: 'workouts', starts_at: T0, ends_at: T0 + 3 * DAY };
  const st = computeStandings(ch, [{ user_id: 'a' }, { user_id: 'b' }, { user_id: 'c' }],
    new Map([['a', [s(0, 1), s(1, 1)]], ['b', [s(0, 1)]]]));
  const out = settle(ch, st);
  assert.equal(out.winner_id, 'a');
  assert.deepEqual(out.awards, [
    { user_id: 'a', amount: XP_GUILD_TOP, reason: 'challenge_guild_top' },
    { user_id: 'b', amount: XP_GUILD_PART, reason: 'challenge_guild_part' },
  ]);
  const tied = settle(ch, computeStandings(ch, [{ user_id: 'a' }, { user_id: 'b' }],
    new Map([['a', [s(0, 1)]], ['b', [s(1, 1)]]])));
  assert.equal(tied.winner_id, null);
  assert.equal(tied.draw, true);
  assert.deepEqual(tied.awards.map((a) => a.amount), [XP_GUILD_TOP, XP_GUILD_TOP]);
});

test('validateCreate', () => {
  assert.equal(validateCreate({ kind: 'duel', metric: 'volume', opponent_user_id: 'x', days: 7 }).ok, true);
  assert.equal(validateCreate({ kind: 'duel', metric: 'volume' }).ok, false);
  assert.equal(validateCreate({ kind: 'raid' }).ok, false);
  assert.equal(validateCreate({ kind: 'guild', metric: 'reps' }).ok, false);
  assert.equal(validateCreate({ kind: 'guild', metric: 'streak', days: 0 }).ok, false);
  assert.equal(validateCreate({ kind: 'guild', metric: 'streak', days: 31 }).ok, false);
  const d = validateCreate({ kind: 'guild', metric: 'streak' });
  assert.deepEqual([d.ok, d.days], [true, 7]);
});

console.log(`\n${passed} tests passed`);
