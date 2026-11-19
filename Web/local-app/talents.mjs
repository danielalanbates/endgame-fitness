/**
 * Talent tree definition, validation and effect math.
 *
 * Pure and dependency-free so the same module runs in the Pages Function and in
 * `node tests/talents.test.mjs`. Nothing here touches the database.
 *
 * Three branches, three tiers each. A tier-N node needs (N-1)*3 points already
 * spent in its branch plus its explicit prerequisites. Everything that changes
 * XP or streaks is applied server-side in handleSync via `applyTalentEffects`
 * and `streakShieldRanks`; the client only renders.
 */

export const TALENT_TREE = {
  version: 1,
  branches: [
    { id: 'strength',  name: 'Strength',  color: 'red',    icon: 'dumbbell.fill' },
    { id: 'endurance', name: 'Endurance', color: 'green',  icon: 'flame.fill' },
    { id: 'community', name: 'Community', color: 'purple', icon: 'person.3.fill' },
  ],
  nodes: [
    // ---- Strength: reward heavy sessions -------------------------------------
    { id: 'iron_foundation', branch: 'strength', tier: 1, max_rank: 5, requires: [],
      name: 'Iron Foundation', icon: 'dumbbell.fill',
      description: '+2% XP per rank on sessions moving at least 5,000 lb.',
      effect: { kind: 'xp_pct_heavy', per_rank: 2, min_volume: 5000 } },
    { id: 'heavy_hands', branch: 'strength', tier: 2, max_rank: 3, requires: [{ id: 'iron_foundation', rank: 3 }],
      name: 'Heavy Hands', icon: 'hand.raised.fill',
      description: '+3% XP per rank on sessions moving at least 15,000 lb.',
      effect: { kind: 'xp_pct_heavy', per_rank: 3, min_volume: 15000 } },
    { id: 'titan', branch: 'strength', tier: 3, max_rank: 1, requires: [{ id: 'heavy_hands', rank: 3 }],
      name: 'Titan', icon: 'mountain.2.fill',
      description: 'Every 10th level grants one extra talent point.',
      effect: { kind: 'bonus_point_every', levels: 10 } },

    // ---- Endurance: reward consistency ---------------------------------------
    { id: 'momentum', branch: 'endurance', tier: 1, max_rank: 5, requires: [],
      name: 'Momentum', icon: 'flame.fill',
      description: '+5% XP per rank on every workout.',
      effect: { kind: 'xp_pct', per_rank: 5 } },
    { id: 'streak_shield', branch: 'endurance', tier: 2, max_rank: 2, requires: [{ id: 'momentum', rank: 3 }],
      name: 'Streak Shield', icon: 'shield.checkered',
      description: 'Your streak survives one missed day per rank.',
      effect: { kind: 'streak_shield', days_per_rank: 1 } },
    { id: 'second_wind', branch: 'endurance', tier: 3, max_rank: 3, requires: [{ id: 'streak_shield', rank: 1 }],
      name: 'Second Wind', icon: 'wind',
      description: '+4% XP per rank while your streak is 7 days or longer.',
      effect: { kind: 'xp_pct_streak', per_rank: 4, min_streak: 7 } },

    // ---- Community: reward training with people ------------------------------
    { id: 'rally', branch: 'community', tier: 1, max_rank: 5, requires: [],
      name: 'Rally', icon: 'person.2.fill',
      description: '+1% XP per rank for each friend, up to 5 friends.',
      effect: { kind: 'xp_pct_friends', per_rank: 1, max_friends: 5 } },
    { id: 'guild_banner', branch: 'community', tier: 2, max_rank: 3, requires: [{ id: 'rally', rank: 3 }],
      name: 'Guild Banner', icon: 'flag.fill',
      description: '+3% XP per rank while you belong to a guild.',
      effect: { kind: 'xp_pct_guild', per_rank: 3 } },
    { id: 'mentor', branch: 'community', tier: 3, max_rank: 1, requires: [{ id: 'guild_banner', rank: 2 }],
      name: 'Mentor', icon: 'graduationcap.fill',
      description: 'Every 5th level grants one extra talent point.',
      effect: { kind: 'bonus_point_every', levels: 5 } },
  ],
};

export const POINTS_PER_TIER = 3;

const byId = new Map(TALENT_TREE.nodes.map((n) => [n.id, n]));
export const nodeById = (id) => byId.get(id) || null;

/** rows: [{talent_id, rank}] -> { id: rank } */
export function ranksFromRows(rows) {
  const ranks = {};
  for (const r of rows || []) if (r && r.talent_id) ranks[r.talent_id] = Number(r.rank) || 0;
  return ranks;
}

export function pointsSpent(ranks) {
  return Object.values(ranks).reduce((s, r) => s + (Number(r) || 0), 0);
}

export function pointsSpentInBranch(ranks, branch) {
  let total = 0;
  for (const [id, rank] of Object.entries(ranks)) {
    const node = byId.get(id);
    if (node && node.branch === branch) total += Number(rank) || 0;
  }
  return total;
}

/**
 * Can one more point go into `talentId`? Returns { ok: true } or { ok: false, error }.
 */
export function validateSpend(ranks, unspent, talentId) {
  const node = byId.get(talentId);
  if (!node) return { ok: false, error: 'Unknown talent' };
  if ((Number(unspent) || 0) < 1) return { ok: false, error: 'No unspent talent points' };
  const current = Number(ranks[talentId]) || 0;
  if (current >= node.max_rank) return { ok: false, error: 'Talent is already at max rank' };
  const needed = (node.tier - 1) * POINTS_PER_TIER;
  if (pointsSpentInBranch(ranks, node.branch) < needed) {
    return { ok: false, error: `Spend ${needed} points in ${node.branch} first` };
  }
  for (const req of node.requires) {
    if ((Number(ranks[req.id]) || 0) < req.rank) {
      const reqNode = byId.get(req.id);
      return { ok: false, error: `Requires ${reqNode ? reqNode.name : req.id} rank ${req.rank}` };
    }
  }
  return { ok: true };
}

/** Effects summed across all ranks; the multiplier is additive (1 + sum of pct / 100). */
export function xpMultiplier(ranks, ctx = {}) {
  const { volume = 0, streak = 0, friends = 0, inGuild = false } = ctx;
  let pct = 0;
  for (const node of TALENT_TREE.nodes) {
    const rank = Number(ranks[node.id]) || 0;
    if (rank <= 0) continue;
    const e = node.effect;
    switch (e.kind) {
      case 'xp_pct':         pct += e.per_rank * rank; break;
      case 'xp_pct_heavy':   if (volume >= e.min_volume) pct += e.per_rank * rank; break;
      case 'xp_pct_streak':  if (streak >= e.min_streak) pct += e.per_rank * rank; break;
      case 'xp_pct_friends': pct += e.per_rank * rank * Math.min(Math.max(friends, 0), e.max_friends); break;
      case 'xp_pct_guild':   if (inGuild) pct += e.per_rank * rank; break;
      default: break;
    }
  }
  return 1 + pct / 100;
}

export function applyTalentEffects(baseXp, ranks, ctx) {
  return Math.round(baseXp * xpMultiplier(ranks, ctx));
}

/** How many missed days a streak may survive. */
export function streakShieldDays(ranks) {
  const node = byId.get('streak_shield');
  const rank = Number(ranks.streak_shield) || 0;
  return node ? rank * node.effect.days_per_rank : 0;
}

/**
 * Extra talent points for levels crossed in (levelBefore, levelAfter], on top of
 * the one point every level already grants.
 */
export function bonusTalentPoints(ranks, levelBefore, levelAfter) {
  let bonus = 0;
  for (const node of TALENT_TREE.nodes) {
    if (node.effect.kind !== 'bonus_point_every') continue;
    if ((Number(ranks[node.id]) || 0) <= 0) continue;
    for (let l = levelBefore + 1; l <= levelAfter; l += 1) {
      if (l % node.effect.levels === 0) bonus += 1;
    }
  }
  return bonus;
}
