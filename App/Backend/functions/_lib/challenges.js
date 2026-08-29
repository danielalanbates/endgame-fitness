/**
 * Challenge math — pure functions, no DB, no I/O. Everything here is unit
 * tested by App/Backend/tests/challenges.test.mjs.
 *
 * A challenge is a window [starts_at, ends_at) over each participant's
 * workout_sessions. Standings are always recomputed from those sessions, never
 * stored, so a re-synced or edited workout is reflected automatically and a
 * modified client cannot inflate its own score.
 */

export const CHALLENGE_KINDS = new Set(['duel', 'guild']);
export const CHALLENGE_METRICS = new Set(['volume', 'workouts', 'streak']);
export const MIN_DAYS = 1;
export const MAX_DAYS = 30;

// XP awards on settlement. Kept modest next to xpForWorkout so a duel is a
// motivator, not a farm.
export const XP_WIN = 150;
export const XP_DRAW = 60;
export const XP_LOSS = 25;
export const XP_GUILD_TOP = 120;
export const XP_GUILD_PART = 20;

const isoDay = (epochSeconds) => new Date(epochSeconds * 1000).toISOString().slice(0, 10);

/**
 * Longest run of consecutive UTC days with at least one session.
 * `days` may contain duplicates and be unordered.
 */
export function longestStreakOfDays(days) {
  const uniq = [...new Set(days)].sort();
  let best = 0;
  let run = 0;
  let prev = null;
  for (const d of uniq) {
    const t = Date.parse(`${d}T00:00:00Z`);
    if (Number.isNaN(t)) continue;
    if (prev !== null && t - prev === 86400000) run += 1;
    else run = 1;
    prev = t;
    if (run > best) best = run;
  }
  return best;
}

/**
 * Score one participant's sessions for a metric.
 * sessions: [{ performed_at, total_volume }] already filtered to the window.
 */
export function scoreSessions(metric, sessions) {
  switch (metric) {
    case 'volume':
      return sessions.reduce((sum, s) => sum + (Number(s.total_volume) || 0), 0);
    case 'workouts':
      return sessions.length;
    case 'streak':
      return longestStreakOfDays(sessions.map((s) => isoDay(Number(s.performed_at) || 0)));
    default:
      throw new Error(`Unknown metric ${metric}`);
  }
}

/** True when a session falls inside the challenge window (start inclusive, end exclusive). */
export function inWindow(session, startsAt, endsAt) {
  const t = Number(session.performed_at) || 0;
  return t >= startsAt && t < endsAt;
}

/**
 * Standings for a challenge.
 * participants: [{ user_id, display_name?, ... }]
 * sessionsByUser: Map<user_id, [{performed_at,total_volume}]> (any range; filtered here)
 * Returns rows sorted best-first with rank (ties share a rank).
 */
export function computeStandings({ metric, starts_at, ends_at }, participants, sessionsByUser) {
  const rows = participants.map((p) => {
    const all = sessionsByUser.get(p.user_id) || [];
    const mine = all.filter((s) => inWindow(s, starts_at, ends_at));
    return { ...p, score: scoreSessions(metric, mine), sessions: mine.length };
  });
  rows.sort((a, b) => b.score - a.score || String(a.user_id).localeCompare(String(b.user_id)));
  let rank = 0;
  let lastScore = null;
  rows.forEach((row, i) => {
    if (row.score !== lastScore) { rank = i + 1; lastScore = row.score; }
    row.rank = rank;
  });
  return rows;
}

/**
 * Decide the outcome once ends_at has passed.
 * Returns { winner_id|null, draw:boolean, awards:[{user_id, amount, reason}] }.
 * A duel where nobody scored is a draw with no XP (no free XP for ignoring it).
 */
export function settle(challenge, standings) {
  if (!standings.length) return { winner_id: null, draw: true, awards: [] };
  const top = standings[0].score;
  const leaders = standings.filter((r) => r.score === top);
  const nobodyScored = top <= 0;

  if (challenge.kind === 'duel') {
    if (nobodyScored) return { winner_id: null, draw: true, awards: [] };
    if (leaders.length > 1) {
      return {
        winner_id: null,
        draw: true,
        awards: standings.map((r) => ({ user_id: r.user_id, amount: XP_DRAW, reason: 'challenge_draw' })),
      };
    }
    const winner = leaders[0].user_id;
    return {
      winner_id: winner,
      draw: false,
      awards: standings.map((r) => ({
        user_id: r.user_id,
        amount: r.user_id === winner ? XP_WIN : XP_LOSS,
        reason: r.user_id === winner ? 'challenge_win' : 'challenge_loss',
      })),
    };
  }

  // guild: everyone who logged something gets participation XP, the top gets more.
  if (nobodyScored) return { winner_id: null, draw: true, awards: [] };
  const winner = leaders.length === 1 ? leaders[0].user_id : null;
  const awards = standings
    .filter((r) => r.score > 0)
    .map((r) => ({
      user_id: r.user_id,
      amount: r.score === top ? XP_GUILD_TOP : XP_GUILD_PART,
      reason: r.score === top ? 'challenge_guild_top' : 'challenge_guild_part',
    }));
  return { winner_id: winner, draw: leaders.length > 1, awards };
}

/** Validate a create payload; returns { ok, error?, kind, metric, days }. */
export function validateCreate(body) {
  const kind = String(body.kind || 'duel');
  const metric = String(body.metric || 'volume');
  const days = body.days === undefined || body.days === null ? 7 : Math.round(Number(body.days));
  if (!CHALLENGE_KINDS.has(kind)) return { ok: false, error: 'kind must be duel or guild' };
  if (!CHALLENGE_METRICS.has(metric)) return { ok: false, error: 'metric must be volume, workouts or streak' };
  if (days < MIN_DAYS || days > MAX_DAYS) return { ok: false, error: `days must be ${MIN_DAYS}-${MAX_DAYS}` };
  if (kind === 'duel' && !body.opponent_user_id) return { ok: false, error: 'opponent_user_id is required for a duel' };
  return { ok: true, kind, metric, days };
}
