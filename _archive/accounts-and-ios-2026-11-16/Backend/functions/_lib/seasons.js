/**
 * Seasons (API v2 §6): deterministic 8-week seasons with a 30-tier reward
 * track. Import-only (files under functions/_lib/ are not routed). Pure: no
 * DB, no clock — callers pass `epoch`.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Like the raid rotation, everything is derived from the date: Season 1 starts
 * Monday 2026-11-02 00:00 UTC and every season lasts exactly 8 weeks, so no
 * cron job or seasons table is needed and every worker agrees on the season.
 * Season XP is the XP earned while a season is active (season_progress is
 * bumped wherever XP is paid out).
 */

export const SEASON_ONE_START = Date.UTC(2026, 10, 2) / 1000; // Mon 2026-11-02T00:00:00Z
export const SEASON_WEEKS = 8;
export const SEASON_SECS = SEASON_WEEKS * 7 * 86400;
export const TIER_COUNT = 30;

// Themes rotate in this order (season 1 = Iron Dawn, season 7 = Iron Dawn again
// with its own number). Each theme brings two aura cosmetics.
export const SEASON_THEMES = Object.freeze([
  {
    key: 'iron_dawn', name: 'Iron Dawn',
    theme: 'First light on the platform. Build the base everything else stands on.',
    auras: [
      { id: 'aura_dawn', label: 'Dawn Aura', color: '#FFB347' },
      { id: 'aura_daybreak', label: 'Daybreak Aura', color: '#FF7A45' },
    ],
  },
  {
    key: 'frostforge', name: 'Frostforge',
    theme: 'Cold iron, steady breath. Consistency through the dark months.',
    auras: [
      { id: 'aura_frost', label: 'Frost Aura', color: '#8FD3FF' },
      { id: 'aura_glacier', label: 'Glacier Aura', color: '#4A90E2' },
    ],
  },
  {
    key: 'stormbreak', name: 'Stormbreak',
    theme: 'Speed and power. Every session hits like thunder.',
    auras: [
      { id: 'aura_storm', label: 'Storm Aura', color: '#7B8CDE' },
      { id: 'aura_thunder', label: 'Thunder Aura', color: '#FFE066' },
    ],
  },
  {
    key: 'verdant_rise', name: 'Verdant Rise',
    theme: 'Growth season. Add a little every week and watch it compound.',
    auras: [
      { id: 'aura_sprout', label: 'Sprout Aura', color: '#7ED957' },
      { id: 'aura_grove', label: 'Grove Aura', color: '#2E8B57' },
    ],
  },
  {
    key: 'emberfall', name: 'Emberfall',
    theme: 'The long, hot grind. Show up when it is hard.',
    auras: [
      { id: 'aura_cinder', label: 'Cinder Aura', color: '#FF6B3D' },
      { id: 'aura_inferno', label: 'Inferno Aura', color: '#D7263D' },
    ],
  },
  {
    key: 'starfall', name: 'Starfall',
    theme: 'Finish the year strong. Chase the numbers you wrote down in January.',
    auras: [
      { id: 'aura_star', label: 'Star Aura', color: '#C7B8FF' },
      { id: 'aura_nova', label: 'Nova Aura', color: '#F5E663' },
    ],
  },
]);

// Title ranks awarded at tiers 5, 10, 15, 20, 25, 30, prefixed with the theme.
const TITLE_RANKS = ['Wanderer', 'Contender', 'Stalwart', 'Vanquisher', 'Paragon', 'Eternal'];
const TALENT_POINT_TIERS = new Set([4, 9, 14, 19, 24, 29]);
const COSMETIC_TIERS = [12, 27];

/** Season number at `epoch` (0 before Season 1 starts). */
export function seasonNumberAt(epoch) {
  const e = Number(epoch) || 0;
  if (e < SEASON_ONE_START) return 0;
  return Math.floor((e - SEASON_ONE_START) / SEASON_SECS) + 1;
}

export const seasonId = (number) => `s${number}`;

/** Static definition of season `number` (≥ 1). */
export function seasonDefinition(number) {
  const n = Math.max(1, Math.floor(Number(number) || 1));
  const theme = SEASON_THEMES[(n - 1) % SEASON_THEMES.length];
  const startsAt = SEASON_ONE_START + (n - 1) * SEASON_SECS;
  return {
    id: seasonId(n),
    number: n,
    name: `Season ${n}: ${theme.name}`,
    theme: theme.theme,
    theme_key: theme.key,
    starts_at: startsAt,
    ends_at: startsAt + SEASON_SECS,
    tiers: tiersFor(n),
  };
}

/**
 * The season to show at `epoch`: the active one, or Season 1 marked
 * `upcoming` before launch. `active` is false before Season 1.
 */
export function seasonAt(epoch) {
  const n = seasonNumberAt(epoch);
  const def = seasonDefinition(Math.max(1, n));
  return { ...def, active: n >= 1, status: n >= 1 ? 'active' : 'upcoming' };
}

/** Cumulative season XP needed to reach `tier` (1-based). */
export function xpRequiredForTier(tier) {
  const t = Math.max(0, Math.floor(Number(tier) || 0));
  return 300 * t + 10 * t * (t - 1);
}

/** Highest tier reached with `seasonXp` (0–30). */
export function tierForXp(seasonXp) {
  const xp = Number(seasonXp) || 0;
  let tier = 0;
  while (tier < TIER_COUNT && xp >= xpRequiredForTier(tier + 1)) tier += 1;
  return tier;
}

/** The reward for `tier` of season `number`. */
export function rewardFor(number, tier) {
  const theme = SEASON_THEMES[(Math.max(1, number) - 1) % SEASON_THEMES.length];
  if (tier % 5 === 0) {
    const title = `${theme.name} ${TITLE_RANKS[tier / 5 - 1]}`;
    return { type: 'title', value: title, label: `Title: ${title}` };
  }
  const cosmeticIndex = COSMETIC_TIERS.indexOf(tier);
  if (cosmeticIndex >= 0) {
    const aura = theme.auras[cosmeticIndex];
    return { type: 'cosmetic', value: aura.id, label: aura.label, color: aura.color };
  }
  if (TALENT_POINT_TIERS.has(tier)) return { type: 'talent_point', value: 1, label: '+1 talent point' };
  return { type: 'streak_freeze', value: 1, label: '+1 streak freeze' };
}

export function tiersFor(number) {
  const tiers = [];
  for (let tier = 1; tier <= TIER_COUNT; tier += 1) {
    tiers.push({ tier, xp_required: xpRequiredForTier(tier), reward: rewardFor(number, tier) });
  }
  return tiers;
}

/** Every season aura id → { label, color } (for rendering an equipped cosmetic). */
export function seasonCosmetics() {
  const out = {};
  for (const theme of SEASON_THEMES) for (const a of theme.auras) out[a.id] = { label: a.label, color: a.color };
  return out;
}
