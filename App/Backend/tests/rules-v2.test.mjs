/**
 * Pure-rule tests for the v2 libraries: blocked-term filter, validation,
 * streaks, hero class, sync rules (caps, totals, PRs), seasons and unlocks.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/rules-v2.test.mjs
 */

import assert from 'node:assert/strict';
import { containsBlockedTerm, termKey, normalizeForFilter } from '../functions/_lib/profanity.js';
import {
  validateDisplayName, validateProfilePatch, sanitizeAvatarConfig, canonicalEmoji, validateComment,
  validateGuildName, cleanSearchQuery, escapeLike, parseTzOffset,
} from '../functions/_lib/validate.js';
import { localDayKey, daysBetween, applySessionDay, effectiveStreak, MAX_STREAK_FREEZES } from '../functions/_lib/streaks.js';
import { affinityCategory, classAffinity, heroClassFor } from '../functions/_lib/heroclass.js';
import {
  evaluateSession, xpForWorkout, exerciseKey, bestSetsByExercise, detectPRs, SYNC_CAPS,
} from '../functions/_lib/syncrules.js';
import {
  SEASON_ONE_START, SEASON_SECS, seasonNumberAt, seasonAt, tiersFor, tierForXp, xpRequiredForTier, rewardFor, TIER_COUNT,
} from '../functions/_lib/seasons.js';
import { rankTitlesForLevel, rankTitlesCrossed, earnedFrom, cosmeticColor } from '../functions/_lib/unlocks.js';

let passed = 0;
const test = (name, fn) => {
  try { fn(); passed += 1; console.log(`  ok   ${name}`); }
  catch (e) { console.log(`  FAIL ${name}\n       ${e.message}`); process.exitCode = 1; }
};
const rot13 = (s) => s.replace(/[a-z]/g, (c) => String.fromCharCode(((c.charCodeAt(0) - 97 + 13) % 26) + 97));
const T = Date.UTC(2026, 10, 10, 12) / 1000;

console.log('blocked-term filter');
test('catches plain, cased, leet, stretched, suffixed, spaced and camel-cased forms', () => {
  const w = rot13('fuvg');
  for (const s of [w, w.toUpperCase(), 'sh1t', `${w}ty`, 'shiiiit', 's h i t', `Big${w.charAt(0).toUpperCase()}${w.slice(1)}`]) {
    assert.equal(containsBlockedTerm(s), true, s);
  }
  // A compound-only term is caught inside a word.
  assert.equal(containsBlockedTerm(`super${rot13('shpx')}er`), true);
});
test('leaves ordinary words and names alone', () => {
  for (const s of ['Assess', 'class', 'Grasshopper', 'Spicy', 'Cocktail', 'Dickens', 'Hancock', 'therapist', 'Shiitake', 'Passion', 'Sussex']) {
    assert.equal(containsBlockedTerm(s), false, s);
  }
});
test('keys are stable 16-hex strings and normalisation undoes leetspeak', () => {
  assert.match(termKey('example'), /^[0-9a-f]{16}$/);
  assert.equal(normalizeForFilter('L3375P34K'), 'leetspeak');
});

console.log('validation');
test('display names', () => {
  assert.equal(validateDisplayName('  Iron   Mike ').value, 'Iron Mike');
  for (const bad of ['a', '', '___', 'a@b', 'x'.repeat(25), 7]) assert.equal(validateDisplayName(bad).ok, false, String(bad));
  assert.equal(validateDisplayName("D'Angelo-Ruiz.Jr").ok, true);
});
test('profile patch: unchanged echoes skip validation; titles/cosmetics must be owned', () => {
  const current = { display_name: 'x', title: 'Legacy', cosmetic: null };
  const ctx = { current, earnedTitles: new Set(['Initiate']), earnedCosmetics: new Set(['aura_gold']) };
  assert.deepEqual(validateProfilePatch({ display_name: 'x', title: 'Legacy' }, ctx), { ok: true, values: {} });
  assert.equal(validateProfilePatch({ title: 'Champion' }, ctx).error, 'title_not_earned');
  assert.deepEqual(validateProfilePatch({ title: 'Initiate', cosmetic: 'aura_gold' }, ctx).values, { title: 'Initiate', cosmetic: 'aura_gold' });
  assert.equal(validateProfilePatch({ cosmetic: 'aura_iron' }, ctx).error, 'cosmetic_not_earned');
  assert.deepEqual(validateProfilePatch({ is_public: true, units: 'kg' }, ctx).values, { is_public: 1, units: 'kg' });
  assert.equal(validateProfilePatch(null, ctx).ok, false);
  assert.equal(validateProfilePatch([1], ctx).ok, false);
});
test('avatar config allowlist and size cap', () => {
  assert.equal(sanitizeAvatarConfig({ height: 'Tall', x: 1 }).value, '{"height":"Tall"}');
  assert.equal(sanitizeAvatarConfig({ height: 'y'.repeat(4100) }).ok, false);
  assert.equal(sanitizeAvatarConfig(null).value, null);
});
test('emoji, comments, guild names, search, LIKE escaping, tz', () => {
  assert.equal(canonicalEmoji('⚔'), '⚔️');
  assert.equal(canonicalEmoji('👍'), null);
  assert.equal(validateComment('  hi \n\n\n there ').value, 'hi\n\nthere');
  assert.equal(validateGuildName('Iron & Steel!').ok, true);
  assert.equal(cleanSearchQuery(' a '), null);
  assert.equal(escapeLike('50%_off\\'), '50\\%\\_off\\\\');
  assert.equal(parseTzOffset(-420), -420);
  assert.equal(parseTzOffset(841), null);
  assert.equal(parseTzOffset('60'), null);
});

console.log('streaks');
test('local day keys and day arithmetic', () => {
  const t = Date.UTC(2026, 9, 28, 4, 0) / 1000;
  assert.equal(localDayKey(t, 0), '2026-10-28');
  assert.equal(localDayKey(t, -420), '2026-10-27');
  assert.equal(localDayKey(t, 600), '2026-10-28');
  assert.equal(daysBetween('2026-12-31', '2027-01-02'), 2);
});
test('session transitions: start, same-day, continue, shield, freeze, reset, past', () => {
  let s = applySessionDay({ lastDate: null, current: 0, longest: 0, freezes: 0 }, '2026-11-01');
  assert.equal(s.transition, 'start');
  s = applySessionDay(s, '2026-11-01');
  assert.equal(s.transition, 'same-day');
  s = applySessionDay(s, '2026-11-02');
  assert.equal(s.current, 2);
  // One missed day, shield rank 1: free.
  s = applySessionDay(s, '2026-11-04', 1);
  assert.deepEqual([s.transition, s.current, s.freezesUsed], ['continue', 3, 0]);
  // Two missed days, no shield, two freezes: both used.
  s = applySessionDay({ ...s, freezes: 2 }, '2026-11-07');
  assert.deepEqual([s.transition, s.current, s.freezes, s.freezesUsed], ['continue', 4, 0, 2]);
  // Two missed days, one freeze: not enough, reset (the freeze is kept).
  s = applySessionDay({ ...s, freezes: 1 }, '2026-11-10');
  assert.deepEqual([s.transition, s.current, s.freezes], ['reset', 1, 1]);
  const past = applySessionDay(s, '2026-11-01');
  assert.equal(past.transition, 'past');
  assert.equal(past.lastDate, '2026-11-10');
});
test('7-day milestones bank freezes up to the cap', () => {
  let s = { lastDate: '2026-11-06', current: 6, longest: 6, freezes: MAX_STREAK_FREEZES - 1 };
  s = applySessionDay(s, '2026-11-07');
  assert.equal(s.freezes, MAX_STREAK_FREEZES);
  assert.equal(s.freezeEarned, true);
  s = applySessionDay({ ...s, current: 13, lastDate: '2026-11-13' }, '2026-11-14');
  assert.equal(s.freezes, MAX_STREAK_FREEZES);
});
test('effective streak on read', () => {
  const st = { lastDate: '2026-11-05', current: 9, freezes: 1 };
  assert.deepEqual(effectiveStreak(st, '2026-11-06'), { alive: true, current: 9, freezes: 1 });
  assert.deepEqual(effectiveStreak(st, '2026-11-07'), { alive: true, current: 9, freezes: 0 });
  assert.deepEqual(effectiveStreak(st, '2026-11-08'), { alive: false, current: 0, freezes: 1 });
  assert.deepEqual(effectiveStreak(st, '2026-11-08', 1), { alive: true, current: 9, freezes: 0 });
  assert.equal(effectiveStreak({ lastDate: null, current: 0, freezes: 0 }, '2026-11-08').alive, false);
});

console.log('hero class');
test('category mapping and name fallback', () => {
  assert.equal(affinityCategory({ category: 'Olympic Weightlifting' }), 'strength');
  assert.equal(affinityCategory({ category: 'plyometrics' }), 'athletic');
  assert.equal(affinityCategory({ name: 'Barbell Row' }), 'strength');
  assert.equal(affinityCategory({ name: 'Crunches' }), 'strength');
  assert.equal(affinityCategory({ name: 'Morning Run' }), 'endurance');
  assert.equal(affinityCategory({ name: "Farmer's Walk" }), 'strength');
  assert.equal(affinityCategory({ name: 'Hip Flexor Stretch' }), 'mobility');
  assert.equal(affinityCategory({ name: 'Box Jump' }), 'athletic');
});
test('classes by dominant share; recruit under 3 sessions; paladin when balanced', () => {
  const ex = (category, sets) => ({ category, sets: Array(sets).fill({ reps: 1, weight: 0 }) });
  const aff = classAffinity([{ exercises: [ex('strength', 7), ex('cardio', 3)] }]);
  assert.deepEqual(aff, { strength: 0.7, endurance: 0.3, mobility: 0, athletic: 0 });
  assert.equal(heroClassFor(aff, 2), 'recruit');
  assert.equal(heroClassFor(aff, 3), 'juggernaut');
  assert.equal(heroClassFor({ strength: 0.3, endurance: 0.5, mobility: 0.2, athletic: 0 }, 10), 'ranger');
  assert.equal(heroClassFor({ strength: 0.2, endurance: 0, mobility: 0.4, athletic: 0.4 }, 10), 'monk');
  assert.equal(heroClassFor({ strength: 0.1, endurance: 0, mobility: 0.4, athletic: 0.5 }, 10), 'striker');
  assert.equal(heroClassFor({ strength: 0.4, endurance: 0.3, mobility: 0.3, athletic: 0 }, 10), 'paladin');
});

console.log('sync rules');
test('caps flag (not reject) and totals come from the sets for v2', () => {
  const base = { id: 's', performed_at: T - 60, duration_secs: 3600, client_rev: 1 };
  const ok = evaluateSession({ ...base, total_volume: 1, payload: { v: 2, exercises: [{ name: 'A', sets: [{ reps: 5, weight: 100 }, { reps: 0, weight: 100 }] }] } }, T);
  assert.deepEqual([ok.totalVolume, ok.totalReps, ok.flagged], [500, 5, false]);
  const cases = [
    [{ duration_secs: SYNC_CAPS.maxDurationSecs + 1 }, 'duration_cap'],
    [{ performed_at: T + 601 }, 'performed_at_future'],
    [{ performed_at: Date.UTC(2019, 11, 31) / 1000 }, 'performed_at_too_old'],
    [{ payload: { v: 2, exercises: [{ name: 'A', sets: [{ reps: 101, weight: 1 }] }] } }, 'reps_cap'],
    [{ payload: { v: 2, exercises: [{ name: 'A', sets: [{ reps: 1, weight: 1501 }] }] } }, 'weight_cap'],
    [{ payload: { v: 2, exercises: [{ name: 'A', sets: Array(41).fill({ reps: 1, weight: 1 }) }] } }, 'set_cap'],
    [{ payload: { v: 2, exercises: Array(61).fill({ name: 'A', sets: [{ reps: 1, weight: 1 }] }) } }, 'exercise_cap'],
    [{ payload: { v: 2, exercises: Array(20).fill({ name: 'A', sets: Array(20).fill({ reps: 50, weight: 30 }) }) } }, 'volume_cap'],
  ];
  for (const [patch, reason] of cases) {
    const e = evaluateSession({ ...base, ...patch }, T);
    assert.equal(e.ok, true);
    assert.equal(e.flagged, true, reason);
    assert.match(e.flagReason, new RegExp(reason));
  }
  assert.equal(evaluateSession({ id: '' }, T).ok, false);
  assert.equal(evaluateSession({ id: 'x'.repeat(65) }, T).ok, false);
});
test('XP: no empty-session farm, floor of 10 for real work', () => {
  assert.equal(xpForWorkout({ total_volume: 0, total_reps: 0, duration_secs: 60 }), 0);
  assert.equal(xpForWorkout({ total_volume: 0, total_reps: 1, duration_secs: 0 }), 10);
  assert.ok(xpForWorkout({ total_volume: 12000, total_reps: 120, duration_secs: 3600 }) > 500);
});
test('PR keys and detection: baseline, beat, new rep count by e1RM', () => {
  assert.equal(exerciseKey({ name: '  Bench  Press ' }), 'bench press');
  assert.equal(exerciseKey({ name: 'Bench', exercise_id: 'Barbell_Bench' }), 'Barbell_Bench');
  const known = new Map();
  const ex = (sets) => [{ key: 'bench press', name: 'Bench Press', sets: sets.map(([reps, weight]) => ({ reps, weight })) }];
  let r = detectPRs(bestSetsByExercise(ex([[5, 185], [5, 180], [8, 150]])), known);
  assert.equal(r.prCount, 0);
  assert.equal(r.upserts.length, 2);
  r = detectPRs(bestSetsByExercise(ex([[5, 185]])), known);
  assert.deepEqual([r.prCount, r.upserts.length], [0, 0]);
  r = detectPRs(bestSetsByExercise(ex([[5, 190], [3, 190]])), known);
  assert.equal(r.prCount, 1, '5 reps beats 185; 3x190 is a new rep count below the best e1RM');
  r = detectPRs(bestSetsByExercise(ex([[1, 260]])), known);
  assert.equal(r.prCount, 1, 'single at 260 beats every e1RM on record');
  assert.equal(known.get('bench press').get(1), 260);
});

console.log('seasons');
test('deterministic 8-week seasons from 2026-11-02', () => {
  assert.equal(new Date(SEASON_ONE_START * 1000).toISOString(), '2026-11-02T00:00:00.000Z');
  assert.equal(new Date(SEASON_ONE_START * 1000).getUTCDay(), 1);
  assert.equal(seasonNumberAt(SEASON_ONE_START - 1), 0);
  assert.equal(seasonNumberAt(SEASON_ONE_START), 1);
  assert.equal(seasonNumberAt(SEASON_ONE_START + SEASON_SECS - 1), 1);
  assert.equal(seasonNumberAt(SEASON_ONE_START + SEASON_SECS), 2);
  const s2 = seasonAt(SEASON_ONE_START + SEASON_SECS + 5);
  assert.equal(s2.id, 's2');
  assert.equal(s2.ends_at - s2.starts_at, 56 * 86400);
  assert.equal(new Date(s2.starts_at * 1000).getUTCDay(), 1);
  assert.equal(seasonAt(0).status, 'upcoming');
});
test('30 increasing tiers, every tier has a typed reward, titles every 5', () => {
  const tiers = tiersFor(1);
  assert.equal(tiers.length, TIER_COUNT);
  for (let i = 1; i < tiers.length; i += 1) assert.ok(tiers[i].xp_required > tiers[i - 1].xp_required);
  for (const t of tiers) assert.ok(['title', 'cosmetic', 'streak_freeze', 'talent_point'].includes(t.reward.type));
  assert.deepEqual(tiers.filter((t) => t.reward.type === 'title').map((t) => t.tier), [5, 10, 15, 20, 25, 30]);
  assert.equal(tiers.filter((t) => t.reward.type === 'cosmetic').length, 2);
  assert.notEqual(rewardFor(1, 5).value, rewardFor(2, 5).value);
  assert.equal(tierForXp(0), 0);
  assert.equal(tierForXp(xpRequiredForTier(1)), 1);
  assert.equal(tierForXp(xpRequiredForTier(7) - 1), 6);
  assert.equal(tierForXp(1e9), 30);
});

console.log('unlocks');
test('rank titles and earned sets', () => {
  assert.deepEqual(rankTitlesForLevel(1), ['Initiate']);
  assert.deepEqual(rankTitlesForLevel(20), ['Initiate', 'Apprentice', 'Iron Disciple', 'Ironbound']);
  assert.deepEqual(rankTitlesCrossed(4, 10), ['Apprentice', 'Iron Disciple']);
  assert.deepEqual(rankTitlesCrossed(10, 10), []);
  const e = earnedFrom({ level: 5, achievementIds: ['first_workout'], rows: [{ kind: 'title', value: 'Plate Liberator' }, { kind: 'cosmetic', value: 'aura_iron' }] });
  assert.deepEqual(e.titles, ['Apprentice', 'First Blood', 'Initiate', 'Plate Liberator']);
  assert.deepEqual(e.cosmetics, ['aura_iron']);
  assert.match(cosmeticColor('aura_gold'), /^#/);
  assert.match(cosmeticColor('aura_dawn'), /^#/);
  assert.equal(cosmeticColor('aura_unknown'), null);
});

console.log(`\n${passed} passed`);
