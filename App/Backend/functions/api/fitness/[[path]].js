/**
 * Endgame Fitness — profile, sync and social API.
 *
 * All routes require `Authorization: Bearer <BatesAI session token>`.
 *
 *   GET    profile                 the caller's full profile
 *   PUT    profile                 patch profile fields (partial body)
 *   POST   sync                    two-way workout sync (see handleSync)
 *   GET    feed                    activity feed for the caller + friends
 *   POST   feed/:id/react          add an emoji reaction
 *   GET    leaderboard?scope=      global | friends | guild, metric=xp|streak|volume
 *   GET    friends                 accepted friends + pending requests
 *   POST   friends/request         { email } or { user_id }
 *   POST   friends/respond         { user_id, accept: bool }
 *   DELETE friends/:id             remove a friend
 *   GET    guild                   the caller's guild + members
 *   POST   guild                   create a guild { name, motto }
 *   POST   guild/join              { guild_id }
 *   POST   guild/leave
 *   GET    challenges              mine: pending / active / finished (+ live standings)
 *   POST   challenges              { kind, metric, opponent_user_id | (guild), days }
 *   POST   challenges/:id/accept
 *   POST   challenges/:id/decline
 */

import { requireUser, json, withCors, corsHeaders, now } from '../../_lib/session.js';
import { computeStandings, settle, validateCreate } from '../../_lib/challenges.js';

export async function onRequest(context) {
  const { request, env, params } = context;
  const origin = request.headers.get('Origin');

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders(env, origin) });
  }

  const userId = await requireUser(request, env);
  if (!userId) return withCors(json({ error: 'Unauthorized' }, 401), env, origin);

  const path = params.path || [];
  const section = path[0] || '';

  try {
    let response;
    switch (section) {
      case 'profile':
        response = request.method === 'PUT'
          ? await updateProfile(request, env, userId)
          : await getProfile(env, userId);
        break;
      case 'sync':
        response = await handleSync(request, env, userId);
        break;
      case 'feed':
        response = path[1] && path[2] === 'react'
          ? await reactToActivity(request, env, userId, path[1])
          : await getFeed(env, userId);
        break;
      case 'leaderboard':
        response = await getLeaderboard(request, env, userId);
        break;
      case 'friends':
        response = await handleFriends(request, env, userId, path);
        break;
      case 'guild':
        response = await handleGuild(request, env, userId, path);
        break;
      case 'challenges':
        response = await handleChallenges(request, env, userId, path);
        break;
      default:
        response = json({ error: 'Unknown endpoint' }, 404);
    }
    return withCors(response, env, origin);
  } catch (error) {
    console.error('Fitness API error:', error && error.stack ? error.stack : error);
    return withCors(json({ error: 'Internal server error' }, 500), env, origin);
  }
}

/* ------------------------------------------------------------------ */
/* Profile                                                             */
/* ------------------------------------------------------------------ */

async function getProfile(env, userId) {
  const profile = await env.DB.prepare(
    `SELECT p.*, u.email, u.avatar_url AS account_avatar
       FROM fitness_profiles p JOIN users u ON u.id = p.user_id
      WHERE p.user_id = ?`
  ).bind(userId).first();

  if (!profile) return json({ error: 'Profile not found' }, 404);

  const talents = await env.DB.prepare('SELECT talent_id, rank FROM talents WHERE user_id = ?')
    .bind(userId).all();
  const achievements = await env.DB.prepare(
    'SELECT achievement_id, unlocked_at, progress FROM achievements WHERE user_id = ?'
  ).bind(userId).all();
  const records = await env.DB.prepare(
    'SELECT exercise, reps, weight, estimated_1rm, achieved_at FROM personal_records WHERE user_id = ?'
  ).bind(userId).all();

  return json({
    profile: shapeProfile(profile),
    talents: talents.results || [],
    achievements: achievements.results || [],
    personal_records: records.results || [],
  });
}

// Only these columns may be written by a client. Anything that determines rank
// (xp, level, totals, streaks) is derived server-side in handleSync instead, so
// a modified client cannot simply declare itself level 99 on the leaderboard.
const WRITABLE_PROFILE_FIELDS = new Set([
  'display_name', 'training_goal', 'experience_level', 'equipment_level',
  'body_weight', 'height_inches', 'birth_year', 'units',
  'avatar_config', 'title', 'is_public',
]);

async function updateProfile(request, env, userId) {
  const body = await request.json().catch(() => ({}));
  const fields = Object.keys(body).filter((k) => WRITABLE_PROFILE_FIELDS.has(k));
  if (!fields.length) return json({ error: 'No writable fields supplied' }, 400);

  const assignments = fields.map((f) => `${f} = ?`).join(', ');
  const values = fields.map((f) => (f === 'avatar_config' && typeof body[f] === 'object'
    ? JSON.stringify(body[f])
    : body[f]));

  await env.DB.prepare(
    `UPDATE fitness_profiles SET ${assignments}, updated_at = ? WHERE user_id = ?`
  ).bind(...values, now(), userId).run();

  return getProfile(env, userId);
}

function shapeProfile(row) {
  let avatar = null;
  try { avatar = row.avatar_config ? JSON.parse(row.avatar_config) : null; } catch { /* keep null */ }
  return {
    user_id: row.user_id,
    email: row.email,
    display_name: row.display_name,
    avatar_url: row.account_avatar,
    level: row.level,
    xp: row.xp,
    xp_for_next_level: xpForLevel(row.level + 1),
    xp_for_current_level: xpForLevel(row.level),
    talent_points: row.talent_points,
    prestige: row.prestige,
    current_streak: row.current_streak,
    longest_streak: row.longest_streak,
    last_workout_date: row.last_workout_date,
    total_workouts: row.total_workouts,
    total_volume: row.total_volume,
    total_reps: row.total_reps,
    training_goal: row.training_goal,
    experience_level: row.experience_level,
    equipment_level: row.equipment_level,
    body_weight: row.body_weight,
    height_inches: row.height_inches,
    birth_year: row.birth_year,
    units: row.units,
    avatar_config: avatar,
    title: row.title,
    is_public: !!row.is_public,
  };
}

/* ------------------------------------------------------------------ */
/* Progression                                                         */
/* ------------------------------------------------------------------ */

/**
 * Total XP required to have reached `level`. Mildly superlinear so early levels
 * come fast and later ones feel earned: L2 at 100, L10 ≈ 4.4k, L50 ≈ 140k.
 */
export function xpForLevel(level) {
  if (level <= 1) return 0;
  const n = level - 1;
  return Math.round(100 * n + 15 * n * n + 0.9 * n * n * n);
}

function levelForXp(xp) {
  let level = 1;
  while (level < 200 && xp >= xpForLevel(level + 1)) level += 1;
  return level;
}

/**
 * XP for one session. Volume is the backbone so heavy days count, but it is
 * dampened (^0.8) so a single monster session cannot out-earn a consistent week,
 * and duration is capped to stop an idle timer farming XP.
 */
function xpForWorkout({ total_volume = 0, total_reps = 0, duration_secs = 0 }) {
  const volumeXp = Math.pow(Math.max(total_volume, 0), 0.8) * 0.35;
  const repXp = Math.max(total_reps, 0) * 0.5;
  const timeXp = Math.min(Math.max(duration_secs, 0) / 60, 120) * 1.5;
  return Math.max(10, Math.round(volumeXp + repXp + timeXp));
}

function streakAfter(lastDate, performedDate) {
  // Returns 'continue' | 'reset' | 'same-day' given two YYYY-MM-DD strings.
  if (!lastDate) return 'continue';
  if (lastDate === performedDate) return 'same-day';
  const last = Date.parse(`${lastDate}T00:00:00Z`);
  const cur = Date.parse(`${performedDate}T00:00:00Z`);
  if (Number.isNaN(last) || Number.isNaN(cur)) return 'continue';
  const days = Math.round((cur - last) / 86400000);
  return days === 1 ? 'continue' : days <= 0 ? 'same-day' : 'reset';
}

const isoDay = (epochSeconds) => new Date(epochSeconds * 1000).toISOString().slice(0, 10);

/* ------------------------------------------------------------------ */
/* Sync                                                                */
/* ------------------------------------------------------------------ */

/**
 * Two-way sync. The client posts sessions it has recorded since its last sync
 * and the timestamp it last heard from us; we persist the new ones, recompute
 * progression from the server's own totals, and return anything the client is
 * missing. Session ids are client-generated UUIDs, which makes the upsert
 * idempotent — a retried request cannot double-count XP.
 */
async function handleSync(request, env, userId) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const body = await request.json().catch(() => ({}));
  const incoming = Array.isArray(body.sessions) ? body.sessions : [];
  const since = Number(body.since) || 0;

  const profile = await env.DB.prepare('SELECT * FROM fitness_profiles WHERE user_id = ?')
    .bind(userId).first();
  if (!profile) return json({ error: 'Profile not found' }, 404);

  let xpGained = 0;
  const accepted = [];
  const levelBefore = profile.level;

  let currentStreak = profile.current_streak;
  let longestStreak = profile.longest_streak;
  let lastWorkoutDate = profile.last_workout_date;
  let totalWorkouts = profile.total_workouts;
  let totalVolume = profile.total_volume;
  let totalReps = profile.total_reps;

  // Oldest first so streak arithmetic walks forward in time.
  incoming.sort((a, b) => (a.performed_at || 0) - (b.performed_at || 0));

  for (const session of incoming) {
    if (!session || !session.id) continue;

    const existing = await env.DB.prepare(
      'SELECT id, client_rev FROM workout_sessions WHERE id = ? AND user_id = ?'
    ).bind(session.id, userId).first();

    const performedAt = Number(session.performed_at) || now();
    const volume = Number(session.total_volume) || 0;
    const reps = Number(session.total_reps) || 0;
    const duration = Number(session.duration_secs) || 0;
    const rev = Number(session.client_rev) || 1;

    if (existing) {
      // Only accept a strictly newer revision; ignore stale replays.
      if (rev <= existing.client_rev) continue;
      await env.DB.prepare(
        `UPDATE workout_sessions
            SET performed_at = ?, name = ?, program_id = ?, duration_secs = ?,
                total_volume = ?, total_reps = ?, payload = ?, client_rev = ?, updated_at = ?
          WHERE id = ? AND user_id = ?`
      ).bind(
        performedAt, session.name || null, session.program_id || null, duration,
        volume, reps, JSON.stringify(session.payload ?? session), rev, now(),
        session.id, userId
      ).run();
      accepted.push(session.id);
      continue;
    }

    const xp = xpForWorkout({ total_volume: volume, total_reps: reps, duration_secs: duration });

    await env.DB.prepare(
      `INSERT INTO workout_sessions
         (id, user_id, performed_at, name, program_id, duration_secs,
          total_volume, total_reps, xp_earned, payload, client_rev, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).bind(
      session.id, userId, performedAt, session.name || null, session.program_id || null,
      duration, volume, reps, xp, JSON.stringify(session.payload ?? session), rev, now()
    ).run();

    xpGained += xp;
    totalWorkouts += 1;
    totalVolume += volume;
    totalReps += reps;

    const day = isoDay(performedAt);
    const transition = streakAfter(lastWorkoutDate, day);
    if (transition === 'continue') currentStreak += 1;
    else if (transition === 'reset') currentStreak = 1;
    if (transition !== 'same-day') lastWorkoutDate = day;
    longestStreak = Math.max(longestStreak, currentStreak);

    await env.DB.prepare(
      'INSERT INTO xp_transactions (id, user_id, amount, reason, source_id, created_at) VALUES (?, ?, ?, ?, ?, ?)'
    ).bind(crypto.randomUUID(), userId, xp, 'workout', session.id, now()).run();

    await pushActivity(env, userId, 'workout',
      `finished ${session.name || 'a workout'} — ${Math.round(volume).toLocaleString()} lb moved`,
      { session_id: session.id, xp });

    accepted.push(session.id);
  }

  const newXp = profile.xp + xpGained;
  const newLevel = levelForXp(newXp);
  const levelsGained = Math.max(0, newLevel - levelBefore);

  await env.DB.prepare(
    `UPDATE fitness_profiles
        SET xp = ?, level = ?, talent_points = talent_points + ?,
            current_streak = ?, longest_streak = ?, last_workout_date = ?,
            total_workouts = ?, total_volume = ?, total_reps = ?, updated_at = ?
      WHERE user_id = ?`
  ).bind(
    newXp, newLevel, levelsGained, currentStreak, longestStreak, lastWorkoutDate,
    totalWorkouts, totalVolume, totalReps, now(), userId
  ).run();

  if (levelsGained > 0) {
    await pushActivity(env, userId, 'level_up', `reached level ${newLevel}`, { level: newLevel });
  }

  // Hand back everything the client hasn't seen. Capped so a fresh install with
  // years of history pages through instead of timing out on one request.
  const remote = await env.DB.prepare(
    `SELECT id, performed_at, name, program_id, duration_secs, total_volume,
            total_reps, xp_earned, payload, client_rev, updated_at
       FROM workout_sessions
      WHERE user_id = ? AND updated_at > ?
      ORDER BY updated_at ASC
      LIMIT 500`
  ).bind(userId, since).all();

  const sessions = (remote.results || []).map((row) => {
    let payload = null;
    try { payload = JSON.parse(row.payload); } catch { /* leave null */ }
    return { ...row, payload };
  });

  return json({
    accepted,
    xp_gained: xpGained,
    levels_gained: levelsGained,
    sessions,
    has_more: sessions.length === 500,
    server_time: now(),
    profile: shapeProfile(
      await env.DB.prepare(
        `SELECT p.*, u.email, u.avatar_url AS account_avatar
           FROM fitness_profiles p JOIN users u ON u.id = p.user_id WHERE p.user_id = ?`
      ).bind(userId).first()
    ),
  });
}

/* ------------------------------------------------------------------ */
/* Activity feed                                                       */
/* ------------------------------------------------------------------ */

async function pushActivity(env, userId, kind, summary, payload) {
  try {
    await env.DB.prepare(
      'INSERT INTO activity_feed (id, user_id, kind, summary, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)'
    ).bind(crypto.randomUUID(), userId, kind, summary, JSON.stringify(payload || {}), now()).run();
  } catch (e) {
    console.error('pushActivity failed:', e && e.message);
  }
}

async function friendIdsOf(env, userId) {
  const rows = await env.DB.prepare(
    `SELECT user_low, user_high FROM friendships
      WHERE status = 'accepted' AND (user_low = ? OR user_high = ?)`
  ).bind(userId, userId).all();
  return (rows.results || []).map((r) => (r.user_low === userId ? r.user_high : r.user_low));
}

async function getFeed(env, userId) {
  const ids = await friendIdsOf(env, userId);
  ids.push(userId);
  const placeholders = ids.map(() => '?').join(',');

  const rows = await env.DB.prepare(
    `SELECT f.*, p.display_name, p.level, u.avatar_url
       FROM activity_feed f
       JOIN fitness_profiles p ON p.user_id = f.user_id
       JOIN users u ON u.id = f.user_id
      WHERE f.user_id IN (${placeholders})
      ORDER BY f.created_at DESC
      LIMIT 100`
  ).bind(...ids).all();

  const items = [];
  for (const row of rows.results || []) {
    const reactions = await env.DB.prepare(
      'SELECT emoji, COUNT(*) AS count FROM activity_reactions WHERE activity_id = ? GROUP BY emoji'
    ).bind(row.id).all();
    let payload = null;
    try { payload = row.payload ? JSON.parse(row.payload) : null; } catch { /* leave null */ }
    items.push({
      id: row.id,
      user_id: row.user_id,
      display_name: row.display_name,
      level: row.level,
      avatar_url: row.avatar_url,
      kind: row.kind,
      summary: row.summary,
      payload,
      created_at: row.created_at,
      reactions: reactions.results || [],
      is_self: row.user_id === userId,
    });
  }
  return json({ items });
}

async function reactToActivity(request, env, userId, activityId) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const { emoji } = await request.json().catch(() => ({}));
  if (!emoji) return json({ error: 'emoji is required' }, 400);

  const activity = await env.DB.prepare('SELECT user_id FROM activity_feed WHERE id = ?')
    .bind(activityId).first();
  if (!activity) return json({ error: 'Activity not found' }, 404);

  // You may only react to your own posts or a friend's.
  if (activity.user_id !== userId) {
    const friends = await friendIdsOf(env, userId);
    if (!friends.includes(activity.user_id)) return json({ error: 'Not permitted' }, 403);
  }

  await env.DB.prepare(
    `INSERT INTO activity_reactions (activity_id, user_id, emoji, created_at)
     VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`
  ).bind(activityId, userId, emoji, now()).run();

  return json({ success: true });
}

/* ------------------------------------------------------------------ */
/* Leaderboard                                                         */
/* ------------------------------------------------------------------ */

const METRIC_COLUMNS = {
  xp: 'p.xp',
  level: 'p.xp',
  streak: 'p.current_streak',
  volume: 'p.total_volume',
  workouts: 'p.total_workouts',
};

async function getLeaderboard(request, env, userId) {
  const url = new URL(request.url);
  const scope = url.searchParams.get('scope') || 'global';
  const metric = url.searchParams.get('metric') || 'xp';
  const column = METRIC_COLUMNS[metric];
  if (!column) return json({ error: 'Unknown metric' }, 400);

  let where = 'p.is_public = 1';
  let binds = [];

  if (scope === 'friends') {
    const ids = await friendIdsOf(env, userId);
    ids.push(userId);
    where = `p.user_id IN (${ids.map(() => '?').join(',')})`;
    binds = ids;
  } else if (scope === 'guild') {
    const membership = await env.DB.prepare('SELECT guild_id FROM guild_members WHERE user_id = ?')
      .bind(userId).first();
    if (!membership) return json({ entries: [], scope, metric, you: null });
    where = 'p.user_id IN (SELECT user_id FROM guild_members WHERE guild_id = ?)';
    binds = [membership.guild_id];
  }

  const rows = await env.DB.prepare(
    `SELECT p.user_id, p.display_name, p.level, p.xp, p.current_streak,
            p.total_volume, p.total_workouts, p.title, u.avatar_url
       FROM fitness_profiles p JOIN users u ON u.id = p.user_id
      WHERE ${where}
      ORDER BY ${column} DESC
      LIMIT 100`
  ).bind(...binds).all();

  const entries = (rows.results || []).map((row, index) => ({
    rank: index + 1,
    ...row,
    is_self: row.user_id === userId,
  }));

  return json({
    scope,
    metric,
    entries,
    you: entries.find((e) => e.is_self) || null,
  });
}

/* ------------------------------------------------------------------ */
/* Friends                                                             */
/* ------------------------------------------------------------------ */

const pair = (a, b) => (a < b ? [a, b] : [b, a]);

async function handleFriends(request, env, userId, path) {
  const action = path[1] || '';

  if (request.method === 'GET' && !action) {
    const rows = await env.DB.prepare(
      `SELECT f.*, p.display_name, p.level, p.current_streak, p.xp, u.avatar_url,
              CASE WHEN f.user_low = ? THEN f.user_high ELSE f.user_low END AS other_id
         FROM friendships f
         JOIN fitness_profiles p
           ON p.user_id = CASE WHEN f.user_low = ? THEN f.user_high ELSE f.user_low END
         JOIN users u ON u.id = p.user_id
        WHERE f.user_low = ? OR f.user_high = ?`
    ).bind(userId, userId, userId, userId).all();

    const friends = [];
    const incoming = [];
    const outgoing = [];
    for (const row of rows.results || []) {
      const entry = {
        user_id: row.other_id,
        display_name: row.display_name,
        level: row.level,
        xp: row.xp,
        current_streak: row.current_streak,
        avatar_url: row.avatar_url,
      };
      if (row.status === 'accepted') friends.push(entry);
      else if (row.status === 'pending') {
        (row.requested_by === userId ? outgoing : incoming).push(entry);
      }
    }
    return json({ friends, incoming_requests: incoming, outgoing_requests: outgoing });
  }

  if (action === 'request' && request.method === 'POST') {
    const body = await request.json().catch(() => ({}));
    let targetId = body.user_id;

    if (!targetId && body.email) {
      const target = await env.DB.prepare('SELECT id FROM users WHERE email = ?')
        .bind(String(body.email).toLowerCase()).first();
      // Deliberately the same response whether or not the account exists, so this
      // endpoint can't be used to enumerate which emails are registered.
      if (!target) return json({ success: true, status: 'pending' });
      targetId = target.id;
    }
    if (!targetId) return json({ error: 'user_id or email is required' }, 400);
    if (targetId === userId) return json({ error: 'You cannot friend yourself' }, 400);

    const [low, high] = pair(userId, targetId);
    const existing = await env.DB.prepare(
      'SELECT status FROM friendships WHERE user_low = ? AND user_high = ?'
    ).bind(low, high).first();
    if (existing) return json({ success: true, status: existing.status });

    await env.DB.prepare(
      `INSERT INTO friendships (user_low, user_high, requested_by, status, created_at, updated_at)
       VALUES (?, ?, ?, 'pending', ?, ?)`
    ).bind(low, high, userId, now(), now()).run();

    return json({ success: true, status: 'pending' });
  }

  if (action === 'respond' && request.method === 'POST') {
    const { user_id: otherId, accept } = await request.json().catch(() => ({}));
    if (!otherId) return json({ error: 'user_id is required' }, 400);

    const [low, high] = pair(userId, otherId);
    const row = await env.DB.prepare(
      'SELECT requested_by, status FROM friendships WHERE user_low = ? AND user_high = ?'
    ).bind(low, high).first();
    if (!row || row.status !== 'pending') return json({ error: 'No pending request' }, 404);
    // Only the recipient may accept — otherwise the requester could self-approve.
    if (row.requested_by === userId) return json({ error: 'Cannot respond to your own request' }, 403);

    if (accept) {
      await env.DB.prepare(
        `UPDATE friendships SET status = 'accepted', updated_at = ? WHERE user_low = ? AND user_high = ?`
      ).bind(now(), low, high).run();
    } else {
      await env.DB.prepare('DELETE FROM friendships WHERE user_low = ? AND user_high = ?')
        .bind(low, high).run();
    }
    return json({ success: true, status: accept ? 'accepted' : 'declined' });
  }

  if (request.method === 'DELETE' && action) {
    const [low, high] = pair(userId, action);
    await env.DB.prepare('DELETE FROM friendships WHERE user_low = ? AND user_high = ?')
      .bind(low, high).run();
    return json({ success: true });
  }

  return json({ error: 'Unknown endpoint' }, 404);
}

/* ------------------------------------------------------------------ */
/* Guilds                                                              */
/* ------------------------------------------------------------------ */

async function handleGuild(request, env, userId, path) {
  const action = path[1] || '';

  if (request.method === 'GET' && !action) {
    const membership = await env.DB.prepare(
      'SELECT guild_id, role FROM guild_members WHERE user_id = ?'
    ).bind(userId).first();
    if (!membership) return json({ guild: null, members: [] });

    const guild = await env.DB.prepare('SELECT * FROM guilds WHERE id = ?')
      .bind(membership.guild_id).first();
    const members = await env.DB.prepare(
      `SELECT m.role, m.joined_at, p.user_id, p.display_name, p.level, p.xp,
              p.current_streak, u.avatar_url
         FROM guild_members m
         JOIN fitness_profiles p ON p.user_id = m.user_id
         JOIN users u ON u.id = m.user_id
        WHERE m.guild_id = ?
        ORDER BY p.xp DESC`
    ).bind(membership.guild_id).all();

    return json({ guild, members: members.results || [], your_role: membership.role });
  }

  if (request.method === 'POST' && !action) {
    const { name, motto, emblem } = await request.json().catch(() => ({}));
    if (!name || !String(name).trim()) return json({ error: 'name is required' }, 400);

    const existing = await env.DB.prepare('SELECT guild_id FROM guild_members WHERE user_id = ?')
      .bind(userId).first();
    if (existing) return json({ error: 'Leave your current guild first' }, 409);

    const taken = await env.DB.prepare('SELECT id FROM guilds WHERE name = ?').bind(name).first();
    if (taken) return json({ error: 'That guild name is taken' }, 409);

    const guildId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO guilds (id, name, motto, owner_id, emblem, created_at) VALUES (?, ?, ?, ?, ?, ?)'
    ).bind(guildId, String(name).trim(), motto || null, userId, emblem || null, now()).run();
    await env.DB.prepare(
      `INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES (?, ?, 'owner', ?)`
    ).bind(guildId, userId, now()).run();

    return json({ success: true, guild_id: guildId }, 201);
  }

  if (action === 'join' && request.method === 'POST') {
    const { guild_id: guildId } = await request.json().catch(() => ({}));
    if (!guildId) return json({ error: 'guild_id is required' }, 400);

    const existing = await env.DB.prepare('SELECT guild_id FROM guild_members WHERE user_id = ?')
      .bind(userId).first();
    if (existing) return json({ error: 'Leave your current guild first' }, 409);

    const guild = await env.DB.prepare('SELECT member_cap FROM guilds WHERE id = ?')
      .bind(guildId).first();
    if (!guild) return json({ error: 'Guild not found' }, 404);

    const count = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM guild_members WHERE guild_id = ?'
    ).bind(guildId).first();
    if ((count?.n || 0) >= guild.member_cap) return json({ error: 'Guild is full' }, 409);

    await env.DB.prepare(
      `INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES (?, ?, 'member', ?)`
    ).bind(guildId, userId, now()).run();
    return json({ success: true });
  }

  if (action === 'leave' && request.method === 'POST') {
    const membership = await env.DB.prepare(
      'SELECT guild_id, role FROM guild_members WHERE user_id = ?'
    ).bind(userId).first();
    if (!membership) return json({ error: 'You are not in a guild' }, 404);

    await env.DB.prepare('DELETE FROM guild_members WHERE user_id = ?').bind(userId).run();

    // An owner leaving hands the guild to the longest-serving remaining member
    // rather than orphaning it.
    if (membership.role === 'owner') {
      const heir = await env.DB.prepare(
        'SELECT user_id FROM guild_members WHERE guild_id = ? ORDER BY joined_at ASC LIMIT 1'
      ).bind(membership.guild_id).first();
      if (heir) {
        await env.DB.prepare(
          `UPDATE guild_members SET role = 'owner' WHERE guild_id = ? AND user_id = ?`
        ).bind(membership.guild_id, heir.user_id).run();
        await env.DB.prepare('UPDATE guilds SET owner_id = ? WHERE id = ?')
          .bind(heir.user_id, membership.guild_id).run();
      } else {
        await env.DB.prepare('DELETE FROM guilds WHERE id = ?').bind(membership.guild_id).run();
      }
    }
    return json({ success: true });
  }

  return json({ error: 'Unknown endpoint' }, 404);
}

/* ------------------------------------------------------------------ */
/* Challenges                                                          */
/* ------------------------------------------------------------------ */

async function handleChallenges(request, env, userId, path) {
  const id = path[1] || '';
  const action = path[2] || '';

  if (request.method === 'GET' && !id) return listChallenges(env, userId);
  if (request.method === 'POST' && !id) return createChallenge(request, env, userId);
  if (request.method === 'POST' && id && (action === 'accept' || action === 'decline')) {
    return respondToChallenge(env, userId, id, action === 'accept');
  }
  return json({ error: 'Unknown endpoint' }, 404);
}

async function createChallenge(request, env, userId) {
  const body = await request.json().catch(() => ({}));
  const v = validateCreate(body);
  if (!v.ok) return json({ error: v.error }, 400);

  const t = now();
  const challengeId = crypto.randomUUID();
  const endsAt = t + v.days * 86400;

  if (v.kind === 'duel') {
    const opponentId = String(body.opponent_user_id);
    if (opponentId === userId) return json({ error: 'You cannot duel yourself' }, 400);
    const friends = await friendIdsOf(env, userId);
    if (!friends.includes(opponentId)) return json({ error: 'You can only duel a friend' }, 403);

    const open = await env.DB.prepare(
      `SELECT id FROM challenges
        WHERE kind = 'duel' AND status IN ('pending','active')
          AND ((creator_id = ? AND opponent_id = ?) OR (creator_id = ? AND opponent_id = ?))`
    ).bind(userId, opponentId, opponentId, userId).first();
    if (open) return json({ error: 'You already have an open duel with this friend' }, 409);

    // Duels start when accepted; starts_at is provisional until then.
    await env.DB.prepare(
      `INSERT INTO challenges (id, kind, metric, creator_id, opponent_id, guild_id, starts_at, ends_at, status, created_at)
       VALUES (?, 'duel', ?, ?, ?, NULL, ?, ?, 'pending', ?)`
    ).bind(challengeId, v.metric, userId, opponentId, t, endsAt, t).run();
    for (const uid of [userId, opponentId]) {
      await env.DB.prepare(
        'INSERT INTO challenge_participants (challenge_id, user_id, joined_at) VALUES (?, ?, ?)'
      ).bind(challengeId, uid, t).run();
    }
    return json({ success: true, challenge_id: challengeId, status: 'pending' }, 201);
  }

  // guild challenge: creator must be owner/officer; enrol every current member.
  const membership = await env.DB.prepare('SELECT guild_id, role FROM guild_members WHERE user_id = ?')
    .bind(userId).first();
  if (!membership) return json({ error: 'You are not in a guild' }, 404);
  if (!['owner', 'officer'].includes(membership.role)) {
    return json({ error: 'Only guild owners and officers can start a guild challenge' }, 403);
  }
  const running = await env.DB.prepare(
    `SELECT id FROM challenges WHERE guild_id = ? AND status = 'active'`
  ).bind(membership.guild_id).first();
  if (running) return json({ error: 'Your guild already has an active challenge' }, 409);

  await env.DB.prepare(
    `INSERT INTO challenges (id, kind, metric, creator_id, opponent_id, guild_id, starts_at, ends_at, status, created_at)
     VALUES (?, 'guild', ?, ?, NULL, ?, ?, ?, 'active', ?)`
  ).bind(challengeId, v.metric, userId, membership.guild_id, t, endsAt, t).run();
  const members = await env.DB.prepare('SELECT user_id FROM guild_members WHERE guild_id = ?')
    .bind(membership.guild_id).all();
  for (const m of members.results || []) {
    await env.DB.prepare(
      'INSERT INTO challenge_participants (challenge_id, user_id, joined_at) VALUES (?, ?, ?)'
    ).bind(challengeId, m.user_id, t).run();
  }
  await pushActivity(env, userId, 'challenge', `started a ${v.days}-day guild ${v.metric} challenge`,
    { challenge_id: challengeId, metric: v.metric });
  return json({ success: true, challenge_id: challengeId, status: 'active' }, 201);
}

async function respondToChallenge(env, userId, challengeId, accept) {
  const row = await env.DB.prepare('SELECT * FROM challenges WHERE id = ?').bind(challengeId).first();
  if (!row) return json({ error: 'Challenge not found' }, 404);
  if (row.kind !== 'duel' || row.status !== 'pending') return json({ error: 'Nothing to respond to' }, 409);
  // Only the invited side may answer — the creator cannot self-accept.
  if (row.opponent_id !== userId) return json({ error: 'Not your invite' }, 403);

  const t = now();
  if (accept) {
    // The clock starts now, for the originally requested duration.
    const days = Math.max(1, Math.round((row.ends_at - row.starts_at) / 86400));
    await env.DB.prepare(
      `UPDATE challenges SET status = 'active', starts_at = ?, ends_at = ? WHERE id = ?`
    ).bind(t, t + days * 86400, challengeId).run();
    await pushActivity(env, userId, 'challenge', `accepted a ${days}-day ${row.metric} duel`,
      { challenge_id: challengeId, metric: row.metric, opponent_id: row.creator_id });
    return json({ success: true, status: 'active' });
  }
  await env.DB.prepare(`UPDATE challenges SET status = 'declined' WHERE id = ?`).bind(challengeId).run();
  return json({ success: true, status: 'declined' });
}

async function loadParticipants(env, challengeId) {
  const rows = await env.DB.prepare(
    `SELECT cp.user_id, p.display_name, p.level, u.avatar_url
       FROM challenge_participants cp
       JOIN fitness_profiles p ON p.user_id = cp.user_id
       JOIN users u ON u.id = cp.user_id
      WHERE cp.challenge_id = ?`
  ).bind(challengeId).all();
  return rows.results || [];
}

async function sessionsInWindow(env, userIds, startsAt, endsAt) {
  const map = new Map();
  if (!userIds.length) return map;
  const rows = await env.DB.prepare(
    `SELECT user_id, performed_at, total_volume FROM workout_sessions
      WHERE user_id IN (${userIds.map(() => '?').join(',')})
        AND performed_at >= ? AND performed_at < ?`
  ).bind(...userIds, startsAt, endsAt).all();
  for (const r of rows.results || []) {
    if (!map.has(r.user_id)) map.set(r.user_id, []);
    map.get(r.user_id).push(r);
  }
  return map;
}

/** Standings + lazy settlement for one challenge row. */
async function hydrateChallenge(env, row, userId) {
  const participants = await loadParticipants(env, row.id);
  const sessions = await sessionsInWindow(env, participants.map((p) => p.user_id), row.starts_at, row.ends_at);
  const standings = computeStandings(row, participants, sessions);

  if (row.status === 'active' && now() >= row.ends_at) {
    // Claim the settlement atomically so two concurrent GETs cannot double-award.
    const claimed = await env.DB.prepare(
      `UPDATE challenges SET status = 'finished', settled_at = ? WHERE id = ? AND status = 'active'`
    ).bind(now(), row.id).run();
    if (claimed.meta && claimed.meta.changes === 1) {
      const outcome = settle(row, standings);
      await env.DB.prepare('UPDATE challenges SET winner_id = ? WHERE id = ?')
        .bind(outcome.winner_id, row.id).run();
      for (const award of outcome.awards) {
        await env.DB.prepare(
          'INSERT INTO xp_transactions (id, user_id, amount, reason, source_id, created_at) VALUES (?, ?, ?, ?, ?, ?)'
        ).bind(crypto.randomUUID(), award.user_id, award.amount, award.reason, row.id, now()).run();
        await env.DB.prepare('UPDATE fitness_profiles SET xp = xp + ?, updated_at = ? WHERE user_id = ?')
          .bind(award.amount, now(), award.user_id).run();
        // Level is derived from total XP; recompute so a challenge can level you up too.
        const prof = await env.DB.prepare('SELECT xp, level FROM fitness_profiles WHERE user_id = ?')
          .bind(award.user_id).first();
        if (prof) {
          const lvl = levelForXp(prof.xp);
          if (lvl > prof.level) {
            await env.DB.prepare(
              'UPDATE fitness_profiles SET level = ?, talent_points = talent_points + ? WHERE user_id = ?'
            ).bind(lvl, lvl - prof.level, award.user_id).run();
            await pushActivity(env, award.user_id, 'level_up', `reached level ${lvl}`, { level: lvl });
          }
        }
      }
      const name = (uid) => (participants.find((p) => p.user_id === uid) || {}).display_name || 'someone';
      if (outcome.winner_id) {
        await pushActivity(env, outcome.winner_id, 'challenge',
          row.kind === 'duel'
            ? `won a ${row.metric} duel against ${name(standings.find((s) => s.user_id !== outcome.winner_id)?.user_id)}`
            : `topped the guild ${row.metric} challenge`,
          { challenge_id: row.id, metric: row.metric, kind: row.kind });
      } else if (row.kind === 'duel' && outcome.awards.length) {
        await pushActivity(env, row.creator_id, 'challenge', `drew a ${row.metric} duel`, { challenge_id: row.id });
      }
      row = { ...row, status: 'finished', winner_id: outcome.winner_id, settled_at: now() };
    } else {
      row = (await env.DB.prepare('SELECT * FROM challenges WHERE id = ?').bind(row.id).first()) || row;
    }
  }

  return {
    id: row.id,
    kind: row.kind,
    metric: row.metric,
    creator_id: row.creator_id,
    opponent_id: row.opponent_id,
    guild_id: row.guild_id,
    starts_at: row.starts_at,
    ends_at: row.ends_at,
    status: row.status,
    winner_id: row.winner_id,
    is_creator: row.creator_id === userId,
    awaiting_me: row.status === 'pending' && row.opponent_id === userId,
    standings: standings.map((s) => ({
      user_id: s.user_id,
      display_name: s.display_name,
      level: s.level,
      avatar_url: s.avatar_url,
      score: s.score,
      sessions: s.sessions,
      rank: s.rank,
      is_self: s.user_id === userId,
    })),
  };
}

async function listChallenges(env, userId) {
  const rows = await env.DB.prepare(
    `SELECT c.* FROM challenges c
       JOIN challenge_participants cp ON cp.challenge_id = c.id
      WHERE cp.user_id = ? AND c.status IN ('pending','active','finished')
      ORDER BY c.created_at DESC
      LIMIT 40`
  ).bind(userId).all();

  const pending = [];
  const active = [];
  const finished = [];
  for (const row of rows.results || []) {
    const c = await hydrateChallenge(env, row, userId);
    if (c.status === 'pending') pending.push(c);
    else if (c.status === 'active') active.push(c);
    else if (c.status === 'finished') finished.push(c);
  }
  return json({ pending, active, finished: finished.slice(0, 10), server_time: now() });
}
