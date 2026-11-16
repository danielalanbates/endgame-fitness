/**
 * Streak rules: local days, talent shields and streak freezes.
 * Import-only (files under functions/_lib/ are not routed). Pure: no DB, no
 * clock — callers pass `now` and the player's tz offset.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * A streak counts consecutive local days with at least one synced session.
 * Missed days are forgiven first by the Streak Shield talent (free, every
 * time), then by banked streak freezes (one per missed day, consumed). A gap
 * that neither covers ends the streak.
 *
 * Freezes: +1 at every 7-day milestone and from season tiers, max 3 banked.
 */

export const MAX_STREAK_FREEZES = 3;
export const FREEZE_MILESTONE_DAYS = 7;

const DAY_MS = 86400000;

/** 'YYYY-MM-DD' of the player's local calendar day for an epoch-seconds instant. */
export function localDayKey(epochSeconds, tzOffsetMin = 0) {
  const offset = Number(tzOffsetMin) || 0;
  return new Date((Number(epochSeconds) + offset * 60) * 1000).toISOString().slice(0, 10);
}

/** Whole days from day key `a` to day key `b` (b − a). NaN on a bad key. */
export function daysBetween(a, b) {
  const ta = Date.parse(`${a}T00:00:00Z`);
  const tb = Date.parse(`${b}T00:00:00Z`);
  return Math.round((tb - ta) / DAY_MS);
}

/**
 * How a gap of missed days is covered.
 * Returns { alive, freezesUsed }.
 */
function cover(missed, shieldDays, freezes) {
  if (missed <= shieldDays) return { alive: true, freezesUsed: 0 };
  const needed = missed - shieldDays;
  if (needed <= freezes) return { alive: true, freezesUsed: needed };
  return { alive: false, freezesUsed: 0 };
}

/**
 * Apply one new session on local day `day` to the stored streak state.
 *
 * state: { lastDate, current, longest, freezes }
 * Returns the next state plus { transition: 'start'|'continue'|'same-day'|'reset'|'past',
 * freezesUsed, freezeEarned }.
 * A session on a day before `lastDate` (synced late) leaves the streak alone.
 */
export function applySessionDay(state, day, shieldDays = 0) {
  const lastDate = state.lastDate || null;
  let current = Math.max(0, Number(state.current) || 0);
  let longest = Math.max(0, Number(state.longest) || 0);
  let freezes = Math.min(MAX_STREAK_FREEZES, Math.max(0, Number(state.freezes) || 0));
  let transition;
  let freezesUsed = 0;
  let freezeEarned = false;

  const gap = lastDate ? daysBetween(lastDate, day) : NaN;
  if (!lastDate || Number.isNaN(gap) || current === 0) {
    // First session ever, an unreadable stored date, or a streak already lapsed.
    if (lastDate && !Number.isNaN(gap) && gap < 0) {
      return { lastDate, current, longest, freezes, transition: 'past', freezesUsed, freezeEarned };
    }
    if (lastDate && gap === 0 && current > 0) transition = 'same-day';
    else { current = 1; transition = 'start'; }
  } else if (gap < 0) {
    return { lastDate, current, longest, freezes, transition: 'past', freezesUsed, freezeEarned };
  } else if (gap === 0) {
    transition = 'same-day';
  } else {
    const c = cover(gap - 1, shieldDays, freezes);
    if (c.alive) {
      freezes -= c.freezesUsed;
      freezesUsed = c.freezesUsed;
      current += 1;
      transition = 'continue';
    } else {
      current = 1;
      transition = 'reset';
    }
  }

  if (transition === 'continue' && current % FREEZE_MILESTONE_DAYS === 0 && freezes < MAX_STREAK_FREEZES) {
    freezes += 1;
    freezeEarned = true;
  }
  longest = Math.max(longest, current);
  const nextDate = transition === 'same-day' ? lastDate : day;
  return { lastDate: nextDate, current, longest, freezes, transition, freezesUsed, freezeEarned };
}

/**
 * The streak as of local day `today`, without writing anything: a gap that
 * the shield and the banked freezes cover keeps it alive (and shows the
 * freezes it would use); otherwise it reads as 0.
 *
 * Returns { alive, current, freezes } where `freezes` is what remains banked.
 */
export function effectiveStreak(state, today, shieldDays = 0) {
  const current = Math.max(0, Number(state.current) || 0);
  const freezes = Math.min(MAX_STREAK_FREEZES, Math.max(0, Number(state.freezes) || 0));
  if (!state.lastDate || current === 0) return { alive: false, current: 0, freezes };
  const gap = daysBetween(state.lastDate, today);
  if (Number.isNaN(gap) || gap <= 1) return { alive: true, current, freezes };
  const c = cover(gap - 1, shieldDays, freezes);
  return c.alive
    ? { alive: true, current, freezes: freezes - c.freezesUsed }
    : { alive: false, current: 0, freezes };
}
