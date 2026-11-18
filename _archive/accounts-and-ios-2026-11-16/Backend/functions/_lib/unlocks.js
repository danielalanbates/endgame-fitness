/**
 * Titles and cosmetics a player owns (API v2 §7). Import-only (files under
 * functions/_lib/ are not routed). Pure: no DB.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Ownership is stored in fitness_unlocks (user_id, kind, value, source,
 * unlocked_at), written when a level, achievement, raid kill or season tier
 * is earned. Rank and achievement titles are also derived from the level and
 * the achievements table on read, so a missed write can never take a title
 * away from someone who has earned it.
 */

import { ACHIEVEMENTS } from './game.js';
import { BOSS_CATALOG } from './raids.js';
import { seasonCosmetics } from './seasons.js';

// Same bands as FitnessProfile.rankTitle in GameProfile.swift.
export const RANK_TITLES = Object.freeze([
  { level: 1, title: 'Initiate' },
  { level: 5, title: 'Apprentice' },
  { level: 10, title: 'Iron Disciple' },
  { level: 20, title: 'Ironbound' },
  { level: 30, title: 'Vanguard' },
  { level: 45, title: 'Warbringer' },
  { level: 60, title: 'Champion' },
  { level: 80, title: 'Ascendant' },
  { level: 100, title: 'Endgame' },
]);

/** Rank titles for every band `level` has reached. */
export function rankTitlesForLevel(level) {
  const l = Number(level) || 1;
  return RANK_TITLES.filter((r) => l >= r.level).map((r) => r.title);
}

/** Rank titles newly reached when going from `before` to `after`. */
export function rankTitlesCrossed(before, after) {
  return RANK_TITLES.filter((r) => r.level > (Number(before) || 1) && r.level <= (Number(after) || 1))
    .map((r) => r.title);
}

const ACHIEVEMENT_TITLE = new Map(ACHIEVEMENTS.map((a) => [a.id, a.title]));
export const achievementTitle = (id) => ACHIEVEMENT_TITLE.get(id) || null;

const RAID_AURA_COLORS = {
  aura_iron: '#B3B3CC', aura_mist: '#99CCE6', aura_chalk: '#E6E6F2', aura_ember: '#FF9F0A',
  aura_crimson: '#FF3333', aura_verdant: '#33CC66', aura_violet: '#CC66E6', aura_gold: '#FFD60A',
};

/** Every cosmetic id the server can grant → { label, color, source }. */
export function cosmeticCatalog() {
  const out = {};
  for (const boss of BOSS_CATALOG) {
    if (!boss.reward_cosmetic) continue;
    const word = boss.reward_cosmetic.replace(/^aura_/, '');
    out[boss.reward_cosmetic] = {
      label: `${word.charAt(0).toUpperCase()}${word.slice(1)} Aura`,
      color: RAID_AURA_COLORS[boss.reward_cosmetic] || null,
      source: 'raid',
    };
  }
  for (const [id, v] of Object.entries(seasonCosmetics())) out[id] = { ...v, source: 'season' };
  return out;
}

const CATALOG = cosmeticCatalog();
/** Hex colour for an equipped cosmetic id, or null for unknown ids. */
export const cosmeticColor = (id) => (id && CATALOG[id] ? CATALOG[id].color : null);

/**
 * Merge stored unlock rows with the derived ones.
 * rows: [{kind, value}]; achievementIds: iterable of unlocked achievement ids.
 * Returns { titles: [string], cosmetics: [string] } — sorted, de-duplicated.
 */
export function earnedFrom({ level, rows, achievementIds }) {
  const titles = new Set(rankTitlesForLevel(level));
  const cosmetics = new Set();
  for (const id of achievementIds || []) {
    const t = achievementTitle(id);
    if (t) titles.add(t);
  }
  for (const r of rows || []) {
    if (!r || !r.value) continue;
    if (r.kind === 'title') titles.add(r.value);
    else if (r.kind === 'cosmetic') cosmetics.add(r.value);
  }
  return { titles: [...titles].sort(), cosmetics: [...cosmetics].sort() };
}
