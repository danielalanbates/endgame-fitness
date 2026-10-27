/**
 * Hero class: what kind of athlete the last 28 days of training says you are.
 * Import-only (files under functions/_lib/ are not routed). Pure: no DB.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Each completed set is one vote for its exercise's category (payload v2
 * `category`, from the bundled free-exercise-db library; older payloads fall
 * back to name keywords). The class follows the dominant share:
 *
 *   juggernaut  strength  ≥ 0.6
 *   ranger      endurance ≥ 0.5
 *   monk        mobility  ≥ 0.4
 *   striker     athletic  ≥ 0.4
 *   paladin     balanced (none of the above)
 *   recruit     fewer than 3 sessions synced ever
 */

export const HERO_WINDOW_SECS = 28 * 86400;
export const RECRUIT_SESSIONS = 3;
export const HERO_CLASSES = Object.freeze(['recruit', 'juggernaut', 'ranger', 'monk', 'striker', 'paladin']);

const CATEGORY_MAP = {
  strength: 'strength',
  powerlifting: 'strength',
  'olympic weightlifting': 'strength',
  strongman: 'strength',
  cardio: 'endurance',
  stretching: 'mobility',
  plyometrics: 'athletic',
};

// Checked in order; first match wins. Anything unmatched counts as strength,
// which is what an unlabelled lift in this app almost always is.
const NAME_RULES = [
  ['strength', /farmer|carry|yoke|sled/],
  ['mobility', /stretch|yoga|mobility|foam roll|pilates|cat.cow|pigeon|child'?s pose/],
  ['athletic', /plyo|box jump|jump squat|broad jump|burpee|bound|skater|sprint|agility|tuck jump|depth jump|jump rope|clap push/],
  ['endurance', /\brun|jog|treadmill|cycl|bike|elliptical|rowing machine|\brower\b|erg\b|swim|walk|hike|stair|cardio|ski erg|assault|airdyne/],
];

/** strength | endurance | mobility | athletic for one payload exercise. */
export function affinityCategory(exercise) {
  const cat = String((exercise && exercise.category) || '').trim().toLowerCase();
  if (CATEGORY_MAP[cat]) return CATEGORY_MAP[cat];
  const name = String((exercise && (exercise.name || exercise.exercise)) || '').toLowerCase();
  for (const [bucket, re] of NAME_RULES) if (re.test(name)) return bucket;
  return 'strength';
}

/**
 * payloads: parsed session payloads (objects with `exercises`).
 * Returns shares {strength, endurance, mobility, athletic} summing to 1, or
 * all zeros when there were no sets.
 */
export function classAffinity(payloads) {
  const votes = { strength: 0, endurance: 0, mobility: 0, athletic: 0 };
  let total = 0;
  for (const payload of payloads || []) {
    const exercises = payload && Array.isArray(payload.exercises) ? payload.exercises : [];
    for (const ex of exercises) {
      const sets = Array.isArray(ex && ex.sets) ? ex.sets.length : 0;
      const weight = Math.max(1, sets); // an exercise with no set rows still counts once
      votes[affinityCategory(ex)] += weight;
      total += weight;
    }
  }
  if (!total) return votes;
  const round = (v) => Math.round((v / total) * 1000) / 1000;
  return {
    strength: round(votes.strength),
    endurance: round(votes.endurance),
    mobility: round(votes.mobility),
    athletic: round(votes.athletic),
  };
}

const THRESHOLDS = [
  ['juggernaut', 'strength', 0.6],
  ['ranger', 'endurance', 0.5],
  ['monk', 'mobility', 0.4],
  ['striker', 'athletic', 0.4],
];

/** The class for an affinity and the player's lifetime synced session count. */
export function heroClassFor(affinity, totalSessions) {
  if ((Number(totalSessions) || 0) < RECRUIT_SESSIONS) return 'recruit';
  const a = affinity || {};
  let best = null;
  for (const [cls, key, min] of THRESHOLDS) {
    const share = Number(a[key]) || 0;
    if (share >= min && (!best || share > best.share)) best = { cls, share };
  }
  return best ? best.cls : 'paladin';
}
