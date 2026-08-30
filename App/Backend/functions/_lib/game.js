/**
 * Endgame Fitness — quest and achievement rules.
 *
 * Pure functions only: no DB, no clock, no randomness. Everything that touches
 * D1 lives in the fitness worker; this module is what the node tests import.
 *
 * Quests are picked deterministically from a catalog by hashing
 * (user id, period key), so the same user always sees the same board for a
 * given day/week no matter how many times the endpoint is hit, and no state is
 * needed to "roll" them. Progress is stored in the `quests` table under a
 * deterministic id, which makes generation an idempotent INSERT OR IGNORE.
 */

/* ------------------------------------------------------------------ */
/* Catalog                                                             */
/* ------------------------------------------------------------------ */

// metric: which event counter feeds the quest.
//   workouts  — +1 per accepted new session
//   volume    — +total_volume (lb)
//   reps      — +total_reps
//   minutes   — +duration_secs / 60
//   prs       — +1 per personal record set
//   reactions — +1 per reaction the user gives to a friend's activity
//   friends   — +1 per accepted friendship
//   steps     — today's step count from Apple Health (`steps_today` on the
//               sync payload). ABSOLUTE, not additive: progress is the highest
//               reading seen for the period, so re-syncs cannot double-count.
export const DAILY_QUESTS = Object.freeze([
  { key: 'log_workout',   title: 'Show Up',        desc: 'Log a workout today',                    metric: 'workouts',  target: 1,    xp: 40,  icon: 'figure.strengthtraining.traditional' },
  { key: 'volume_5k',     title: 'Move Iron',      desc: 'Move 5,000 lb of total volume',          metric: 'volume',    target: 5000, xp: 60,  icon: 'scalemass.fill' },
  { key: 'reps_100',      title: 'Century',        desc: 'Complete 100 reps',                      metric: 'reps',      target: 100,  xp: 50,  icon: 'repeat' },
  { key: 'minutes_30',    title: 'Half Hour Hero', desc: 'Train for 30 minutes',                   metric: 'minutes',   target: 30,   xp: 45,  icon: 'timer' },
  { key: 'react_friend',  title: 'Hype Squad',     desc: "React to a friend's activity",           metric: 'reactions', target: 1,    xp: 20,  icon: 'hands.clap.fill' },
  { key: 'volume_10k',    title: 'Heavy Day',      desc: 'Move 10,000 lb of total volume',         metric: 'volume',    target: 10000, xp: 90, icon: 'flame.fill' },
  { key: 'steps_8k',      title: 'Step Count',     desc: 'Walk 8,000 steps (Apple Health)',        metric: 'steps',     target: 8000, xp: 50,  icon: 'figure.walk', absolute: true },
]);

export const WEEKLY_QUESTS = Object.freeze([
  { key: 'workouts_3',    title: 'Consistency',    desc: 'Train 3 times this week',                metric: 'workouts',  target: 3,     xp: 150, icon: 'calendar' },
  { key: 'workouts_5',    title: 'Grinder',        desc: 'Train 5 times this week',                metric: 'workouts',  target: 5,     xp: 250, icon: 'calendar.badge.checkmark' },
  { key: 'volume_25k',    title: 'Ton Lifter',     desc: 'Move 25,000 lb this week',               metric: 'volume',    target: 25000, xp: 200, icon: 'scalemass.fill' },
  { key: 'set_pr',        title: 'New Heights',    desc: 'Set a personal record',                  metric: 'prs',       target: 1,     xp: 175, icon: 'trophy.fill' },
  { key: 'reps_500',      title: 'Volume Dealer',  desc: 'Complete 500 reps this week',            metric: 'reps',      target: 500,   xp: 180, icon: 'repeat.circle.fill' },
  { key: 'add_friend',    title: 'Party Up',       desc: 'Add a friend',                           metric: 'friends',   target: 1,     xp: 100, icon: 'person.badge.plus' },
]);

export const DAILY_COUNT = 3;
export const WEEKLY_COUNT = 2;

// rarity drives the client tint: common | rare | epic | legendary
export const ACHIEVEMENTS = Object.freeze([
  { id: 'first_workout', title: 'First Blood',    desc: 'Complete your first workout',      rarity: 'common',    xp: 50,   icon: 'figure.strengthtraining.traditional', rule: (s) => s.total_workouts >= 1 },
  { id: 'workouts_10',   title: 'Regular',        desc: 'Complete 10 workouts',             rarity: 'common',    xp: 100,  icon: '10.circle.fill',      rule: (s) => s.total_workouts >= 10 },
  { id: 'workouts_50',   title: 'Dedicated',      desc: 'Complete 50 workouts',             rarity: 'rare',      xp: 250,  icon: '50.circle.fill',      rule: (s) => s.total_workouts >= 50 },
  { id: 'workouts_100',  title: 'Century Club',   desc: 'Complete 100 workouts',            rarity: 'epic',      xp: 500,  icon: 'medal.fill',          rule: (s) => s.total_workouts >= 100 },
  { id: 'streak_7',      title: 'One Week Strong', desc: 'Train 7 days in a row',           rarity: 'rare',      xp: 200,  icon: 'flame.fill',          rule: (s) => s.longest_streak >= 7 },
  { id: 'streak_30',     title: 'Iron Will',      desc: 'Train 30 days in a row',           rarity: 'legendary', xp: 750,  icon: 'flame.circle.fill',   rule: (s) => s.longest_streak >= 30 },
  { id: 'volume_100k',   title: 'Volume King',    desc: 'Move 100,000 lb lifetime',         rarity: 'epic',      xp: 400,  icon: 'crown.fill',          rule: (s) => s.total_volume >= 100000 },
  { id: 'level_10',      title: 'Iron Disciple',  desc: 'Reach level 10',                   rarity: 'common',    xp: 100,  icon: 'arrow.up.circle.fill', rule: (s) => s.level >= 10 },
  { id: 'level_25',      title: 'Ironbound',      desc: 'Reach level 25',                   rarity: 'rare',      xp: 300,  icon: 'star.circle.fill',    rule: (s) => s.level >= 25 },
  { id: 'level_50',      title: 'Legend',         desc: 'Reach level 50',                   rarity: 'legendary', xp: 1000, icon: 'sparkles',            rule: (s) => s.level >= 50 },
  { id: 'first_friend',  title: 'Party of Two',   desc: 'Add your first friend',            rarity: 'common',    xp: 50,   icon: 'person.2.fill',       rule: (s) => s.friend_count >= 1 },
  { id: 'guild_join',    title: 'Banner Raised',  desc: 'Join or found a guild',            rarity: 'common',    xp: 75,   icon: 'shield.lefthalf.filled', rule: (s) => !!s.in_guild },
  { id: 'raid_slayer',   title: 'Raid Slayer',    desc: 'Help your guild defeat a weekly raid boss', rarity: 'rare', xp: 150, icon: 'bolt.shield.fill', rule: (s) => s.raids_won >= 1 },
]);

/* ------------------------------------------------------------------ */
/* Periods                                                             */
/* ------------------------------------------------------------------ */

const DAY = 86400;

/** 'YYYY-MM-DD' in UTC for an epoch-seconds timestamp. */
export function dayKey(epoch) {
  return new Date(epoch * 1000).toISOString().slice(0, 10);
}

/** ISO week key 'YYYY-Www' (weeks start Monday, UTC). */
export function weekKey(epoch) {
  const d = new Date(epoch * 1000);
  const date = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const dayNum = date.getUTCDay() || 7;           // Mon=1 … Sun=7
  date.setUTCDate(date.getUTCDate() + 4 - dayNum); // Thursday of this week
  const yearStart = Date.UTC(date.getUTCFullYear(), 0, 1);
  const week = Math.ceil(((date - yearStart) / 86400000 + 1) / 7);
  return `${date.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

/** Epoch seconds at which the current UTC day ends. */
export function dayEnd(epoch) {
  return (Math.floor(epoch / DAY) + 1) * DAY;
}

/** Epoch seconds at which the current ISO week (Mon–Sun, UTC) ends. */
export function weekEnd(epoch) {
  const dayStart = Math.floor(epoch / DAY) * DAY;
  const dow = new Date(epoch * 1000).getUTCDay() || 7; // Mon=1 … Sun=7
  return dayStart + (8 - dow) * DAY;
}

/* ------------------------------------------------------------------ */
/* Deterministic selection                                             */
/* ------------------------------------------------------------------ */

/** FNV-1a 32-bit. Stable across runtimes; good enough to shuffle a catalog. */
export function hash32(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i += 1) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/**
 * Pick `count` distinct entries from `catalog` for `seed`. Same seed → same
 * picks, same order. Uses a seeded Fisher–Yates over indices.
 */
export function pickDeterministic(catalog, count, seed) {
  const idx = catalog.map((_, i) => i);
  let state = hash32(seed) || 1;
  const next = () => {
    // xorshift32
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state;
  };
  for (let i = idx.length - 1; i > 0; i -= 1) {
    const j = next() % (i + 1);
    [idx[i], idx[j]] = [idx[j], idx[i]];
  }
  return idx.slice(0, Math.min(count, catalog.length)).map((i) => catalog[i]);
}

export function questId(userId, kind, periodKey, questKey) {
  return `${userId}:${kind}:${periodKey}:${questKey}`;
}

/**
 * The full board (daily + weekly definitions with ids and expiries) a user
 * should have at `epoch`. Pure — the worker turns this into INSERT OR IGNOREs.
 */
export function boardFor(userId, epoch) {
  const dk = dayKey(epoch);
  const wk = weekKey(epoch);
  const daily = pickDeterministic(DAILY_QUESTS, DAILY_COUNT, `${userId}|daily|${dk}`).map((q) => ({
    ...q, kind: 'daily', period: dk, id: questId(userId, 'daily', dk, q.key), expires_at: dayEnd(epoch),
  }));
  const weekly = pickDeterministic(WEEKLY_QUESTS, WEEKLY_COUNT, `${userId}|weekly|${wk}`).map((q) => ({
    ...q, kind: 'weekly', period: wk, id: questId(userId, 'weekly', wk, q.key), expires_at: weekEnd(epoch),
  }));
  return [...daily, ...weekly];
}

export function questDefinition(questKey) {
  return DAILY_QUESTS.find((q) => q.key === questKey) || WEEKLY_QUESTS.find((q) => q.key === questKey) || null;
}

/* ------------------------------------------------------------------ */
/* Progress                                                            */
/* ------------------------------------------------------------------ */

/**
 * Given a quest row ({quest_key, target, progress}) and an event
 * ({metric counts}), return the new progress (capped at target).
 * `event` is e.g. { workouts: 1, volume: 5200, reps: 80, minutes: 42 }.
 */
export function advance(quest, event) {
  const def = questDefinition(quest.quest_key);
  if (!def) return Number(quest.progress) || 0;
  const delta = Number(event[def.metric]) || 0;
  if (delta <= 0) return Number(quest.progress) || 0;
  const progress = Number(quest.progress) || 0;
  // Absolute metrics (steps) report a running total, so take the max instead of summing.
  const next = def.absolute ? Math.max(progress, delta) : progress + delta;
  return Math.min(Number(quest.target), next);
}

/** Convert the Health fields on a sync payload into a quest event (or null). */
export function eventForHealth({ steps_today = 0 } = {}) {
  const steps = Math.max(0, Math.floor(Number(steps_today) || 0));
  return steps > 0 ? { steps } : null;
}

/** Convert a synced session into a quest event. */
export function eventForWorkout({ total_volume = 0, total_reps = 0, duration_secs = 0, prs = 0 }) {
  return {
    workouts: 1,
    volume: Math.max(0, Number(total_volume) || 0),
    reps: Math.max(0, Number(total_reps) || 0),
    minutes: Math.max(0, (Number(duration_secs) || 0) / 60),
    prs: Math.max(0, Number(prs) || 0),
  };
}

/* ------------------------------------------------------------------ */
/* Achievements                                                        */
/* ------------------------------------------------------------------ */

/**
 * Evaluate every rule against `stats` and return the definitions that are met
 * but not in `unlocked` (an iterable of ids). Order is catalog order.
 */
export function newlyUnlocked(stats, unlocked) {
  const have = new Set(unlocked || []);
  const s = {
    total_workouts: 0, longest_streak: 0, total_volume: 0, level: 1,
    friend_count: 0, in_guild: false, raids_won: 0, ...stats,
  };
  return ACHIEVEMENTS.filter((a) => !have.has(a.id) && a.rule(s));
}

/** Catalog without the rule closures (JSON-safe). */
export function achievementCatalog() {
  return ACHIEVEMENTS.map(({ rule, ...rest }) => rest);
}
