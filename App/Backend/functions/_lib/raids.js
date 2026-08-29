/**
 * Guild Raids — boss catalog, weekly rotation and damage maths.
 * Import-only (files under functions/_lib/ are not routed).
 *
 * Every guild fights the same boss in a given week. The boss is chosen
 * deterministically from the week number so no cron job or shared state is
 * needed: two workers on two continents agree on the boss for free.
 */

export const WEEK_SECS = 7 * 24 * 60 * 60;

// 1970-01-05 00:00:00 UTC was a Monday. Weeks start Monday 00:00 UTC, which
// matches ISO-8601 week boundaries.
const MONDAY_EPOCH = 345600;

/** Epoch seconds of the Monday 00:00 UTC that starts the week containing `epoch`. */
export function weekStart(epoch) {
  const e = Math.floor(Number(epoch) || 0);
  return MONDAY_EPOCH + Math.floor((e - MONDAY_EPOCH) / WEEK_SECS) * WEEK_SECS;
}

/** Zero-based number of weeks since the anchor Monday. */
export function weekIndex(epoch) {
  return Math.floor((weekStart(epoch) - MONDAY_EPOCH) / WEEK_SECS);
}

/**
 * Fixed catalog. `id` is the primary key in raid_bosses; `base_hp` is the hp
 * for a one-person guild and is multiplied by the member count when a raid is
 * opened (see hpForGuild). One hp point == one pound of volume.
 */
export const BOSS_CATALOG = [
  {
    id: 'ironjaw',
    name: 'Ironjaw the Plate Hoarder',
    flavor: 'He has every 45 in the building and he is not re-racking them.',
    symbol: 'dumbbell.fill',
    gradient: ['#8E8E93', '#1C1C1E'],
    base_hp: 60000,
    reward_xp: 400,
    reward_title: 'Plate Liberator',
    reward_cosmetic: 'aura_iron',
  },
  {
    id: 'cardio_wraith',
    name: 'The Cardio Wraith',
    flavor: 'Whispers "just one more mile" from inside the treadmill.',
    symbol: 'figure.run',
    gradient: ['#5AC8FA', '#1D3557'],
    base_hp: 55000,
    reward_xp: 380,
    reward_title: 'Wraith Runner',
    reward_cosmetic: 'aura_mist',
  },
  {
    id: 'chalk_golem',
    name: 'Chalk Golem',
    flavor: 'Leaves a handprint on everything. Everything.',
    symbol: 'hand.raised.fill',
    gradient: ['#F2F2F7', '#8E8E93'],
    base_hp: 70000,
    reward_xp: 450,
    reward_title: 'Dusted',
    reward_cosmetic: 'aura_chalk',
  },
  {
    id: 'squat_rack_curler',
    name: 'The Squat-Rack Curler',
    flavor: 'Twenty-pound curls, forty-minute sets, zero shame.',
    symbol: 'figure.strengthtraining.traditional',
    gradient: ['#FF9F0A', '#7A2E00'],
    base_hp: 65000,
    reward_xp: 420,
    reward_title: 'Rack Reclaimer',
    reward_cosmetic: 'aura_ember',
  },
  {
    id: 'doms_dragon',
    name: 'DOMS, the Two-Day Dragon',
    flavor: 'You do not feel its bite today. You will feel it on Thursday.',
    symbol: 'flame.fill',
    gradient: ['#FF375F', '#3A0A1A'],
    base_hp: 80000,
    reward_xp: 500,
    reward_title: 'Dragonsore',
    reward_cosmetic: 'aura_crimson',
  },
  {
    id: 'plateau_titan',
    name: 'Plateau Titan',
    flavor: 'Has held the same bench number for six years and calls it consistency.',
    symbol: 'mountain.2.fill',
    gradient: ['#30D158', '#0B3D20'],
    base_hp: 90000,
    reward_xp: 550,
    reward_title: 'Plateau Breaker',
    reward_cosmetic: 'aura_verdant',
  },
  {
    id: 'mirror_lich',
    name: 'The Mirror Lich',
    flavor: 'Feeds on flexing. Weakens with every rep you do not film.',
    symbol: 'sparkles',
    gradient: ['#BF5AF2', '#2A0A3D'],
    base_hp: 75000,
    reward_xp: 480,
    reward_title: 'Unfilmed',
    reward_cosmetic: 'aura_violet',
  },
  {
    id: 'rest_day_hydra',
    name: 'Rest-Day Hydra',
    flavor: 'Skip one session and two excuses grow back.',
    symbol: 'bolt.heart.fill',
    gradient: ['#FFD60A', '#5A4500'],
    base_hp: 85000,
    reward_xp: 520,
    reward_title: 'Hydra Slayer',
    reward_cosmetic: 'aura_gold',
  },
];

/** The boss every guild fights in the week containing `epoch`. */
export function bossForWeek(epoch) {
  return BOSS_CATALOG[weekIndex(epoch) % BOSS_CATALOG.length];
}

/** Boss hp scales with guild size so a 3-person crew and a 25-person crew both have a fight. */
export function hpForGuild(boss, memberCount) {
  const members = Math.min(25, Math.max(1, Math.floor(Number(memberCount) || 1)));
  return Math.round(boss.base_hp * members);
}

export const DAMAGE_PER_LB = 1;
export const DAMAGE_PER_PR = 250;
export const MAX_PRS_PER_SESSION = 20; // the client reports PRs, so bound the blast radius

/**
 * Damage one synced session deals. Volume is sum(reps * weight) in lb as
 * reported by the client; each new personal record is worth a flat bonus.
 */
export function raidDamage({ total_volume = 0, pr_count = 0 } = {}) {
  const volume = Math.max(0, Number(total_volume) || 0);
  const prs = Math.min(MAX_PRS_PER_SESSION, Math.max(0, Math.floor(Number(pr_count) || 0)));
  return Math.round(volume * DAMAGE_PER_LB + prs * DAMAGE_PER_PR);
}
