/**
 * Sync rules (API v2 §3): session sanitising, server-side totals, plausibility
 * caps, XP for a session and personal-record detection.
 * Import-only (files under functions/_lib/ are not routed). Pure: no DB,
 * no clock — callers pass `nowEpoch`.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Weights on the wire are always pounds.
 */

import { cleanText } from './validate.js';

export const SYNC_CAPS = Object.freeze({
  maxExercises: 60,
  maxSetsPerExercise: 40,
  minReps: 1,
  maxReps: 100,
  maxWeightLb: 1500,
  maxVolumeLb: 250000,
  // Not in the v2 contract's list: without it a payload of 2,400 bodyweight
  // sets of 100 reps would be "plausible" and worth ~120k XP.
  maxSessionReps: 5000,
  maxDurationSecs: 6 * 3600,
  futureSlackSecs: 600,
  earliestPerformedAt: 1577836800, // 2020-01-01T00:00:00Z
  maxPayloadChars: 200000,
});

/** Sessions handled per POST sync; the rest stay queued client-side (not in `accepted`). */
export const MAX_SESSIONS_PER_SYNC = 50;
/** Pull page size (rows of `sessions` per response). */
export const PULL_PAGE_SIZE = 200;

/**
 * XP for one session. Volume is the backbone so heavy days count, but it is
 * dampened (^0.8) so a single monster session cannot out-earn a consistent
 * week, and duration is capped to stop an idle timer farming XP. A session
 * with no reps and under five minutes earns nothing (no empty-session farm).
 */
export function xpForWorkout({ total_volume = 0, total_reps = 0, duration_secs = 0 }) {
  const volume = Math.max(Number(total_volume) || 0, 0);
  const reps = Math.max(Number(total_reps) || 0, 0);
  const secs = Math.max(Number(duration_secs) || 0, 0);
  const volumeXp = Math.pow(volume, 0.8) * 0.35;
  const repXp = reps * 0.5;
  const timeXp = Math.min(secs / 60, 120) * 1.5;
  const xp = Math.round(volumeXp + repXp + timeXp);
  if (reps <= 0 && secs < 300) return 0;
  return Math.max(10, xp);
}

/** Epley estimated one-rep max. */
export const estimated1RM = (weight, reps) => Math.round(weight * (1 + reps / 30));

/** PR key: the library exercise_id when present, else the lower-cased trimmed name. */
export function exerciseKey(exercise) {
  if (!exercise || typeof exercise !== 'object') return '';
  const id = typeof exercise.exercise_id === 'string' ? exercise.exercise_id.trim() : '';
  if (id) return id.slice(0, 120);
  const name = cleanText(exercise.name || exercise.exercise || '');
  return name.toLowerCase().slice(0, 120);
}

const str = (v, max) => (typeof v === 'string' && v.trim() ? cleanText(v).slice(0, max) : null);

/**
 * Turn one client session into what the server stores. Never throws.
 *
 * Returns { ok: false, error } for something that cannot be stored at all
 * (no usable id), else { ok: true, ...fields } where `flagged` is true when a
 * plausibility cap was exceeded (stored for history, earns nothing).
 */
export function evaluateSession(session, nowEpoch) {
  if (!session || typeof session !== 'object') return { ok: false, error: 'session_invalid' };
  const id = typeof session.id === 'string' ? session.id.trim() : '';
  if (!id || id.length > 64) return { ok: false, error: 'id_invalid', id: typeof session.id === 'string' ? session.id : null };

  const reasons = [];
  const flag = (r) => { if (!reasons.includes(r)) reasons.push(r); };

  let performedAt = Math.floor(Number(session.performed_at));
  if (!Number.isFinite(performedAt) || performedAt <= 0) performedAt = nowEpoch;
  if (performedAt > nowEpoch + SYNC_CAPS.futureSlackSecs) flag('performed_at_future');
  if (performedAt < SYNC_CAPS.earliestPerformedAt) flag('performed_at_too_old');

  let durationSecs = Math.round(Number(session.duration_secs) || 0);
  if (durationSecs < 0) durationSecs = 0;
  if (durationSecs > SYNC_CAPS.maxDurationSecs) flag('duration_cap');

  let clientRev = Math.floor(Number(session.client_rev) || 1);
  if (clientRev < 1) clientRev = 1;
  clientRev = Math.min(clientRev, 1e9);

  const payload = session.payload && typeof session.payload === 'object' && !Array.isArray(session.payload)
    ? session.payload : null;
  const version = payload && Number(payload.v) >= 2 ? 2 : 1;
  const rawExercises = payload && Array.isArray(payload.exercises) ? payload.exercises : [];
  if (rawExercises.length > SYNC_CAPS.maxExercises) flag('exercise_cap');

  const exercises = [];
  let volume = 0;
  let reps = 0;
  for (const ex of rawExercises.slice(0, SYNC_CAPS.maxExercises * 2)) {
    if (!ex || typeof ex !== 'object') continue;
    const key = exerciseKey(ex);
    if (!key) continue;
    const rawSets = Array.isArray(ex.sets) ? ex.sets : [];
    if (rawSets.length > SYNC_CAPS.maxSetsPerExercise) flag('set_cap');
    const sets = [];
    for (const set of rawSets.slice(0, SYNC_CAPS.maxSetsPerExercise * 2)) {
      if (!set || typeof set !== 'object') continue;
      const r = Math.round(Number(set.reps));
      if (!Number.isFinite(r) || r < SYNC_CAPS.minReps) continue; // not a working set
      const w = Number(set.weight) || 0;
      if (r > SYNC_CAPS.maxReps) flag('reps_cap');
      if (w < 0 || w > SYNC_CAPS.maxWeightLb) flag('weight_cap');
      sets.push({ reps: r, weight: w });
      reps += r;
      volume += r * Math.max(w, 0);
    }
    exercises.push({
      key,
      name: str(ex.name, 120) || key,
      category: str(ex.category, 40),
      sets,
    });
  }

  // v2: the server's own sum is the truth. v1: volume from the sets when the
  // client sent them (identical for honest v1 clients), reps from the client
  // because v1 native drops bodyweight sets from the payload.
  let totalVolume;
  let totalReps;
  if (version >= 2) {
    totalVolume = volume;
    totalReps = reps;
  } else {
    const clientVolume = Math.max(0, Number(session.total_volume) || 0);
    totalVolume = rawExercises.length ? volume : clientVolume;
    totalReps = Math.max(0, Math.round(Number(session.total_reps) || 0));
  }
  totalVolume = Math.round(totalVolume * 100) / 100;
  if (totalVolume > SYNC_CAPS.maxVolumeLb) flag('volume_cap');
  if (totalReps > SYNC_CAPS.maxSessionReps) flag('reps_total_cap');

  let payloadJson = JSON.stringify(payload || {});
  if (payloadJson.length > SYNC_CAPS.maxPayloadChars) {
    flag('payload_cap');
    payloadJson = JSON.stringify({ v: version, truncated: true });
  }

  return {
    ok: true,
    id,
    performedAt,
    name: str(session.name, 120),
    programId: str(session.program_id, 64),
    durationSecs,
    clientRev,
    deleted: session.deleted === true,
    version,
    exercises,
    totalVolume,
    totalReps,
    flagged: reasons.length > 0,
    flagReason: reasons.length ? reasons.join(',') : null,
    payloadJson,
  };
}

/** Best weight at each rep count per exercise key: Map<key, {key, name, best: Map<reps, weight>}>. */
export function bestSetsByExercise(exercises) {
  const out = new Map();
  for (const ex of exercises || []) {
    for (const set of ex.sets || []) {
      if (!(set.weight > 0) || set.reps < 1 || set.reps > SYNC_CAPS.maxReps) continue;
      if (!out.has(ex.key)) out.set(ex.key, { key: ex.key, name: ex.name, best: new Map() });
      const best = out.get(ex.key).best;
      if (!best.has(set.reps) || best.get(set.reps) < set.weight) best.set(set.reps, set.weight);
    }
  }
  return out;
}

/**
 * Compare a session's best sets with the stored records.
 *
 * known: Map<key, Map<reps, weight>> — the player's records so far (mutated:
 * the session's records are merged in so the next session in the same sync
 * compares against them).
 *
 * Rules:
 *  - The first-ever log of an exercise is a baseline: recorded, not a PR.
 *  - Beating the weight at a rep count already on record is a PR.
 *  - A new rep count for a known exercise is recorded, and is a PR only if
 *    its estimated 1RM beats the best estimated 1RM on record (so varying
 *    the rep count cannot farm PRs).
 *
 * Returns { upserts: [{key, name, reps, weight, e1rm}], prCount }.
 */
export function detectPRs(candidates, known) {
  const upserts = [];
  let prCount = 0;
  for (const { key, name, best } of candidates.values()) {
    const records = known.get(key);
    if (!records || records.size === 0) {
      const fresh = new Map();
      for (const [reps, weight] of best) {
        upserts.push({ key, name, reps, weight, e1rm: estimated1RM(weight, reps) });
        fresh.set(reps, weight);
      }
      known.set(key, fresh);
      continue;
    }
    let bestE1rm = 0;
    for (const [reps, weight] of records) bestE1rm = Math.max(bestE1rm, estimated1RM(weight, reps));
    for (const [reps, weight] of best) {
      const e1rm = estimated1RM(weight, reps);
      if (records.has(reps)) {
        if (weight > records.get(reps)) {
          upserts.push({ key, name, reps, weight, e1rm });
          prCount += 1;
        }
      } else {
        upserts.push({ key, name, reps, weight, e1rm });
        if (e1rm > bestE1rm) prCount += 1;
      }
    }
    for (const u of upserts) if (u.key === key) records.set(u.reps, Math.max(records.get(u.reps) || 0, u.weight));
  }
  return { upserts, prCount };
}
