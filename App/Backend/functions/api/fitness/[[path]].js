/**
 * Endgame Fitness — profile, sync and social API. Contract: Docs/API_V2.md.
 *
 * All routes require `Authorization: Bearer <BatesAI session token>` or the
 * website's batesai_session cookie. A signed-in member with no fitness
 * profile yet gets one created on first use (lazy, private by default).
 *
 *   GET    profile                 the caller's full profile (+ talents, achievements, PRs)
 *   PUT    profile                 patch profile fields (partial body, validated)
 *   POST   sync                    two-way workout sync (see handleSync)
 *   GET    feed?before=            feed for the caller + friends + guildmates, 50 per page
 *   POST   feed/:id/react          toggle an emoji reaction
 *   GET    feed/:id/comments       comments on a feed item
 *   POST   feed/:id/comments       { text } add a comment
 *   DELETE comments/:id            delete own comment, or one on own item
 *   GET    blocks                  players the caller blocked
 *   POST   blocks                  { user_id } block (also ends any friendship)
 *   DELETE blocks/:user_id         unblock
 *   POST   reports                 { target_type, target_id, reason }
 *   GET    players/search?q=       public players by name prefix or exact friend code
 *   GET    players/:user_id        a player card
 *   GET    leaderboard?scope=      global | friends | guild, metric=xp|level|streak|volume|workouts|season
 *   GET    friends                 accepted friends + pending requests
 *   POST   friends/request         { user_id | code | email | query }
 *   POST   friends/respond         { user_id, accept: bool }
 *   DELETE friends/:id             remove a friend
 *   GET    guild                   the caller's guild + members (+ invite_code)
 *   POST   guild                   create a guild { name, motto?, emblem?, is_open? }
 *   PUT    guild                   owner: { name?, motto?, emblem?, is_open? }
 *   POST   guild/join              { guild_id } (open guilds) or { invite_code }
 *   POST   guild/leave
 *   POST   guild/invite_code/rotate  owner/officer: new invite code
 *   GET    guilds?q=               discover open guilds
 *   GET    raid                    this week's guild raid boss
 *   GET    season                  current season, tiers, progress, top 20
 *   POST   season/claim            { tier } claim a reached tier's reward
 *   GET    talents                 tree definition + allocated ranks + unspent points
 *   POST   talents/spend           { talent_id } — one point, server-validated
 *   POST   talents/respec          refund every point
 *   GET    challenges              mine: pending / active / finished (+ live standings)
 *   POST   challenges              { kind, metric, opponent_user_id | (guild), days }
 *   POST   challenges/:id/accept
 *   POST   challenges/:id/decline
 *   GET    quests                  active daily + weekly quests (generated on read)
 *   POST   quests/:id/claim        claim a completed quest → XP + feed item
 *   GET    achievements            catalog + unlocked state
 *   POST   ai                      { task, ... } coaching text (20 per day per player)
 */

import { requireUser, json, withCors, corsHeaders, now } from '../../_lib/session.js';
import { rateLimit, tooManyRequests } from '../../_lib/ratelimit.js';
import { computeStandings, settle, validateCreate } from '../../_lib/challenges.js';
import {
  TALENT_TREE, nodeById, ranksFromRows, pointsSpent, validateSpend,
  applyTalentEffects, streakShieldDays, bonusTalentPoints,
} from '../../_lib/talents.js';
import {
  boardFor, advance, eventForWorkout, eventForHealth, questDefinition, newlyUnlocked, achievementCatalog,
} from '../../_lib/game.js';
import {
  BOSS_CATALOG, bossForWeek, weekStart, hpForGuild, raidDamage, WEEK_SECS, MAX_GUILD_MEMBERS,
} from '../../_lib/raids.js';
import {
  validateProfilePatch, PROFILE_WRITABLE_FIELDS, parseTzOffset, weightUnitOf, validateGuildName, validateGuildMotto,
  validateGuildEmblem, validateComment, validateReport, canonicalEmoji, cleanSearchQuery, escapeLike,
} from '../../_lib/validate.js';
import { localDayKey, applySessionDay, effectiveStreak, MAX_STREAK_FREEZES } from '../../_lib/streaks.js';
import { classAffinity, heroClassFor, HERO_WINDOW_SECS, RECRUIT_SESSIONS } from '../../_lib/heroclass.js';
import {
  evaluateSession, xpForWorkout, bestSetsByExercise, detectPRs, MAX_SESSIONS_PER_SYNC, PULL_PAGE_SIZE,
} from '../../_lib/syncrules.js';
import { seasonAt, tierForXp, rewardFor, TIER_COUNT } from '../../_lib/seasons.js';
import { earnedFrom, rankTitlesCrossed, achievementTitle, cosmeticColor } from '../../_lib/unlocks.js';

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
    // Members who signed up on the website (or whose sign-in hook failed)
    // have no fitness row yet: create it here instead of answering 404.
    if (section !== 'ai') await ensureProfile(env, userId);

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
        if (path[1] && path[2] === 'react') response = await reactToActivity(request, env, userId, path[1]);
        else if (path[1] && path[2] === 'comments') response = await handleComments(request, env, userId, path[1]);
        else if (!path[1] && request.method === 'GET') response = await getFeed(request, env, userId);
        else response = json({ error: 'Unknown endpoint' }, 404);
        break;
      case 'comments':
        response = request.method === 'DELETE' && path[1]
          ? await deleteComment(env, userId, path[1])
          : json({ error: 'Unknown endpoint' }, 404);
        break;
      case 'blocks':
        response = await handleBlocks(request, env, userId, path);
        break;
      case 'reports':
        response = request.method === 'POST' ? await createReport(request, env, userId) : json({ error: 'POST only' }, 405);
        break;
      case 'players':
        if (path[1] === 'search') response = await searchPlayers(request, env, userId);
        else if (path[1] && request.method === 'GET') response = await getPlayer(env, userId, path[1]);
        else response = json({ error: 'Unknown endpoint' }, 404);
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
      case 'guilds':
        response = request.method === 'GET' ? await listGuilds(request, env, userId) : json({ error: 'GET only' }, 405);
        break;
      case 'season':
        if (path[1] === 'claim') response = await claimSeasonTier(request, env, userId);
        else if (!path[1]) response = await getSeason(env, userId);
        else response = json({ error: 'Unknown endpoint' }, 404);
        break;
      case 'ai':
        response = await handleAI(request, env, userId);
        break;
      case 'raid':
        response = await getRaid(env, userId);
        break;
      case 'talents':
        response = await handleTalents(request, env, userId, path);
        break;
      case 'challenges':
        response = await handleChallenges(request, env, userId, path);
        break;
      case 'quests':
        response = path[1] && path[2] === 'claim'
          ? await claimQuest(request, env, userId, path[1])
          : await getQuests(env, userId);
        break;
      case 'achievements':
        response = await getAchievements(env, userId);
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
/* Shared helpers                                                      */
/* ------------------------------------------------------------------ */

const BAD_JSON = Symbol('bad json');

/**
 * Parse a JSON body no larger than `maxBytes`. Returns the value, or BAD_JSON
 * for unreadable / oversized bodies so callers can answer 400 instead of 500.
 */
async function readJson(request, maxBytes = 64 * 1024) {
  const declared = Number(request.headers.get('Content-Length') || 0);
  if (declared > maxBytes) return BAD_JSON;
  let text;
  try { text = await request.text(); } catch { return BAD_JSON; }
  if (text.length > maxBytes) return BAD_JSON;
  if (!text.trim()) return {};
  try { return JSON.parse(text); } catch { return BAD_JSON; }
}

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const badBody = () => json({ error: 'body_invalid' }, 400);

function parseJson(text) {
  if (text === null || text === undefined || text === '') return null;
  if (typeof text === 'object') return text;
  try { return JSON.parse(text); } catch { return null; }
}

// SQL fragments. Each `?` is bound with the caller's user id, in order.
// Friends of the caller (3 binds).
const FRIEND_IDS_SQL = `SELECT CASE WHEN fr.user_low = ? THEN fr.user_high ELSE fr.user_low END
                          FROM friendships fr
                         WHERE fr.status = 'accepted' AND (fr.user_low = ? OR fr.user_high = ?)`;
// Members of the caller's guild, including the caller (1 bind).
const GUILDMATE_IDS_SQL = `SELECT gm2.user_id FROM guild_members gm2
                            WHERE gm2.guild_id IN (SELECT gm1.guild_id FROM guild_members gm1 WHERE gm1.user_id = ?)`;
/** `col` is not blocked by, and has not blocked, the caller (2 binds). */
const notBlocked = (col) => `NOT EXISTS (SELECT 1 FROM user_blocks ub
   WHERE (ub.blocker_id = ? AND ub.blocked_id = ${col}) OR (ub.blocker_id = ${col} AND ub.blocked_id = ?))`;

const pair = (a, b) => (a < b ? [a, b] : [b, a]);

/** How `viewerId` relates to `otherId`, in one query. */
async function relationship(env, viewerId, otherId) {
  if (viewerId === otherId) return { self: true, friend: false, guildmate: true, blocked: false, iBlocked: false };
  const [low, high] = pair(viewerId, otherId);
  const row = await env.DB.prepare(
    `SELECT
       EXISTS (SELECT 1 FROM friendships WHERE user_low = ? AND user_high = ? AND status = 'accepted') AS friend,
       EXISTS (SELECT 1 FROM guild_members a JOIN guild_members b ON a.guild_id = b.guild_id
                WHERE a.user_id = ? AND b.user_id = ?) AS guildmate,
       EXISTS (SELECT 1 FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?) AS i_blocked,
       EXISTS (SELECT 1 FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?) AS they_blocked`
  ).bind(low, high, viewerId, otherId, viewerId, otherId, otherId, viewerId).first();
  return {
    self: false,
    friend: !!row?.friend,
    guildmate: !!row?.guildmate,
    iBlocked: !!row?.i_blocked,
    blocked: !!row?.i_blocked || !!row?.they_blocked,
  };
}

/* ------------------------------------------------------------------ */
/* AI assist (OpenRouter, server-side key)                             */
/* ------------------------------------------------------------------ */

const AI_DAILY_LIMIT = 20;

// POST /api/fitness/ai  { task, ...payload }
// Tasks:
//   improve_workout  { workout: [{day, name, exercises:[...], minutes}], profile? }
//   build_mesocycle  { goal, experience, weeks?, days_per_week?, notes? }
// Returns { text } — for build_mesocycle the text is a strict JSON array of
// phases the client parses. 20 calls per player per day (the key is paid).
async function handleAI(request, env, userId) {
  if (request.method !== 'POST') return json({ error: 'POST only' }, 405);
  if (!env.OPENROUTER_API_KEY) return json({ error: 'AI is not configured' }, 503);

  const body = await readJson(request, 16 * 1024);
  if (body === BAD_JSON || !isObject(body)) return json({ error: 'Bad JSON' }, 400);
  const task = body.task || '';
  const clip = (v, max) => String(v ?? '').slice(0, max);

  let system, user;
  if (task === 'improve_workout') {
    system = 'You are a concise evidence-based strength coach. Review the workout plan and suggest concrete improvements: exercise selection, order, volume, balance across muscle groups, and recovery. Reply in short plain-text bullet points (no markdown headers), max ~200 words.';
    user = JSON.stringify({ workout: Array.isArray(body.workout) ? body.workout : [], profile: isObject(body.profile) ? body.profile : null });
  } else if (task === 'build_mesocycle') {
    system = 'You design training mesocycles. Reply with ONLY a JSON array, no prose, where each element is {"name": string, "weeks": int, "repRange": string like "8-12", "focus": one-sentence string, "emoji": one emoji}. 2-5 phases, total weeks matching the request (default 12).';
    user = JSON.stringify({
      goal: clip(body.goal || 'general fitness', 200),
      experience: clip(body.experience || 'intermediate', 40),
      weeks: Math.min(52, Math.max(1, Math.round(Number(body.weeks) || 12))),
      days_per_week: Math.min(7, Math.max(1, Math.round(Number(body.days_per_week) || 3))),
      notes: clip(body.notes || '', 1000),
    });
  } else {
    return json({ error: 'Unknown task' }, 400);
  }
  if (user.length > 12000) return json({ error: 'Request too large' }, 400);

  const limit = await rateLimit(env, `ai:user:${userId}`, AI_DAILY_LIMIT, 86400);
  if (!limit.ok) return tooManyRequests(limit.retryAfter);

  // OpenRouter (GLM): the Cerebras free tier started returning
  // payment_required in Aug 2026, so the paid-but-cheap GLM key is the backend.
  const res = await fetch('https://openrouter.ai/api/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${env.OPENROUTER_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'z-ai/glm-5.2',
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: user },
      ],
      max_tokens: 1400,
      temperature: 0.4,
    }),
  });
  if (!res.ok) {
    console.error('OpenRouter error', res.status, await res.text());
    return json({ error: 'AI backend error' }, 502);
  }
  const data = await res.json();
  const text = (data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || '';
  return json({ text });
}

/* ------------------------------------------------------------------ */
/* Profile                                                             */
/* ------------------------------------------------------------------ */

/**
 * Friend codes: a short, shareable handle so people can add each other in the
 * gym without typing an email. Generated lazily the first time a profile is
 * read; the unique index makes a collision a retry rather than a duplicate.
 */
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I
function randomCode(length) {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes, (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join('');
}
const randomFriendCode = () => randomCode(6);
const randomInviteCode = () => randomCode(8);

async function ensureFriendCode(env, userId, current) {
  if (current) return current;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const code = randomFriendCode();
    try {
      const res = await env.DB.prepare(
        'UPDATE fitness_profiles SET friend_code = ? WHERE user_id = ? AND friend_code IS NULL'
      ).bind(code, userId).run();
      if (res.meta && res.meta.changes === 0) break; // someone else set it meanwhile
      return code;
    } catch (e) {
      if (!/UNIQUE|constraint/i.test(String(e && e.message))) throw e;
    }
  }
  const again = await env.DB.prepare('SELECT friend_code FROM fitness_profiles WHERE user_id = ?')
    .bind(userId).first();
  return again ? again.friend_code : null;
}

/** "Athlete" + 4 digits: never the member's real name or email. */
function defaultDisplayName() {
  const n = crypto.getRandomValues(new Uint16Array(1))[0] % 10000;
  return `Athlete${String(n).padStart(4, '0')}`;
}

/** Create the caller's fitness row if it is missing. Private by default. */
async function ensureProfile(env, userId) {
  const row = await env.DB.prepare('SELECT 1 AS ok FROM fitness_profiles WHERE user_id = ?').bind(userId).first();
  if (row) return false;
  const t = now();
  await env.DB.prepare(
    `INSERT INTO fitness_profiles (user_id, display_name, is_public, created_at, updated_at)
     VALUES (?, ?, 0, ?, ?) ON CONFLICT(user_id) DO NOTHING`
  ).bind(userId, defaultDisplayName(), t, t).run();
  return true;
}

async function loadProfileRow(env, userId) {
  return env.DB.prepare(
    `SELECT p.*, u.email, u.avatar_url AS account_avatar
       FROM fitness_profiles p JOIN users u ON u.id = p.user_id
      WHERE p.user_id = ?`
  ).bind(userId).first();
}

async function talentRanks(env, userId) {
  const rows = await env.DB.prepare('SELECT talent_id, rank FROM talents WHERE user_id = ?').bind(userId).all();
  return { rows: rows.results || [], ranks: ranksFromRows(rows.results) };
}

/** Titles and cosmetics the player owns (stored + derived). */
async function earnedFor(env, userId, level, achievementIds) {
  const rows = await env.DB.prepare('SELECT kind, value FROM fitness_unlocks WHERE user_id = ?').bind(userId).all();
  return earnedFrom({ level, rows: rows.results || [], achievementIds });
}

/** Season XP for the season active at `t` (0 before Season 1). */
async function seasonXpOf(env, userId, t) {
  const season = seasonAt(t);
  if (!season.active) return 0;
  const row = await env.DB.prepare('SELECT xp FROM season_progress WHERE user_id = ? AND season_id = ?')
    .bind(userId, season.id).first();
  return row ? row.xp : 0;
}

/** Hero class from the last 28 days of counted sessions. */
async function computeHero(env, userId, totalWorkouts, t) {
  if ((Number(totalWorkouts) || 0) < RECRUIT_SESSIONS) {
    return { hero_class: 'recruit', class_affinity: classAffinity([]) };
  }
  const rows = await env.DB.prepare(
    `SELECT payload FROM workout_sessions
      WHERE user_id = ? AND performed_at >= ? AND deleted = 0 AND flagged = 0
      ORDER BY performed_at DESC LIMIT 200`
  ).bind(userId, t - HERO_WINDOW_SECS).all();
  const affinity = classAffinity((rows.results || []).map((r) => parseJson(r.payload)).filter(Boolean));
  return { hero_class: heroClassFor(affinity, totalWorkouts), class_affinity: affinity };
}

function streakFor(row, shieldDays, t) {
  return effectiveStreak(
    { lastDate: row.last_workout_date, current: row.current_streak, freezes: row.streak_freezes },
    localDayKey(t, row.tz_offset_min || 0),
    shieldDays
  );
}

function shapeProfile(row, ctx = {}) {
  const streak = ctx.streak || {
    alive: row.current_streak > 0, current: row.current_streak, freezes: row.streak_freezes || 0,
  };
  const earned = ctx.earned || { titles: [], cosmetics: [] };
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
    current_streak: streak.current,
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
    weight_unit: weightUnitOf(row.units),
    avatar_config: parseJson(row.avatar_config),
    title: row.title,
    cosmetic: row.cosmetic || null,
    cosmetic_color: cosmeticColor(row.cosmetic),
    bio: row.bio || null,
    is_public: !!row.is_public,
    friend_code: row.friend_code || null,
    hero_class: ctx.hero ? ctx.hero.hero_class : (row.hero_class || 'recruit'),
    class_affinity: ctx.hero ? ctx.hero.class_affinity : (parseJson(row.class_affinity) || classAffinity([])),
    earned_titles: earned.titles,
    earned_cosmetics: earned.cosmetics,
    streak_freezes: streak.freezes,
    streak_alive: !!streak.alive,
    season_xp: ctx.seasonXp || 0,
    onboarded: !!row.training_goal,
    tz_offset_min: row.tz_offset_min || 0,
  };
}

/**
 * Everything GET profile returns, computed from the stored row. Side effects
 * are limited to keeping derived columns honest: a lapsed streak is written
 * back as 0 (so it drops off the streak board) and the hero class cache is
 * refreshed when it changed.
 */
async function buildProfile(env, userId) {
  const t = now();
  let row = await loadProfileRow(env, userId);
  if (!row) return null;
  if (!row.friend_code) row = { ...row, friend_code: await ensureFriendCode(env, userId, null) };

  const { rows: talentRows, ranks } = await talentRanks(env, userId);
  const achievements = await env.DB.prepare(
    'SELECT achievement_id, unlocked_at, progress FROM achievements WHERE user_id = ?'
  ).bind(userId).all();
  const achievementRows = achievements.results || [];
  const earned = await earnedFor(env, userId, row.level, achievementRows.map((a) => a.achievement_id));
  const streak = streakFor(row, streakShieldDays(ranks), t);
  const hero = await computeHero(env, userId, row.total_workouts, t);
  const seasonXp = await seasonXpOf(env, userId, t);

  const affinityJson = JSON.stringify(hero.class_affinity);
  const lapsed = !streak.alive && row.current_streak > 0;
  if (lapsed || row.hero_class !== hero.hero_class || row.class_affinity !== affinityJson) {
    await env.DB.prepare(
      `UPDATE fitness_profiles SET hero_class = ?, class_affinity = ?,
              current_streak = CASE WHEN ? THEN 0 ELSE current_streak END
        WHERE user_id = ?`
    ).bind(hero.hero_class, affinityJson, lapsed ? 1 : 0, userId).run();
  }

  return {
    profile: shapeProfile(row, { streak, earned, hero, seasonXp }),
    talents: talentRows,
    achievements: achievementRows,
    earned,
    row,
  };
}

async function getProfile(env, userId) {
  const built = await buildProfile(env, userId);
  if (!built) return json({ error: 'Profile not found' }, 404);
  const records = await env.DB.prepare(
    `SELECT COALESCE(exercise_name, exercise) AS exercise, exercise AS exercise_key, reps, weight,
            estimated_1rm, achieved_at
       FROM personal_records WHERE user_id = ?
      ORDER BY estimated_1rm DESC LIMIT 500`
  ).bind(userId).all();
  return json({
    profile: built.profile,
    talents: built.talents,
    achievements: built.achievements,
    personal_records: records.results || [],
  });
}

// Only validated, whitelisted columns may be written by a client (see
// validateProfilePatch). Anything that determines rank (xp, level, totals,
// streaks) is derived server-side in handleSync instead, so a modified
// client cannot simply declare itself level 99 on the leaderboard.
async function updateProfile(request, env, userId) {
  const body = await readJson(request, 16 * 1024);
  if (body === BAD_JSON || !isObject(body)) return badBody();
  if (!Object.keys(body).some((k) => PROFILE_WRITABLE_FIELDS.includes(k))) {
    return json({ error: 'No writable fields supplied' }, 400);
  }

  const row = await loadProfileRow(env, userId);
  const achievements = await env.DB.prepare('SELECT achievement_id FROM achievements WHERE user_id = ?')
    .bind(userId).all();
  const earned = await earnedFor(env, userId, row.level, (achievements.results || []).map((a) => a.achievement_id));
  const check = validateProfilePatch(body, {
    current: row,
    earnedTitles: new Set(earned.titles),
    earnedCosmetics: new Set(earned.cosmetics),
    year: new Date(now() * 1000).getUTCFullYear(),
  });
  if (!check.ok) return json({ error: check.error }, 400);

  const fields = Object.keys(check.values);
  if (fields.length) {
    const assignments = fields.map((f) => `${f} = ?`).join(', ');
    await env.DB.prepare(
      `UPDATE fitness_profiles SET ${assignments}, updated_at = ? WHERE user_id = ?`
    ).bind(...fields.map((f) => check.values[f]), now(), userId).run();
  }
  return getProfile(env, userId);
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

/** Statements that credit `amount` XP to the active season (none before Season 1). */
function seasonXpStatements(env, userId, amount, t) {
  const season = seasonAt(t);
  if (!season.active || !(amount > 0)) return [];
  return [env.DB.prepare(
    `INSERT INTO season_progress (user_id, season_id, xp, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT (user_id, season_id) DO UPDATE SET xp = xp + excluded.xp, updated_at = excluded.updated_at`
  ).bind(userId, season.id, amount, t)];
}

/** Statements that record rank titles crossed between two levels. */
function rankTitleStatements(env, userId, levelBefore, levelAfter, t) {
  return rankTitlesCrossed(levelBefore, levelAfter).map((title) => env.DB.prepare(
    `INSERT OR IGNORE INTO fitness_unlocks (user_id, kind, value, source, unlocked_at)
     VALUES (?, 'title', ?, 'rank', ?)`
  ).bind(userId, title, t));
}

function unlockStatement(env, userId, kind, value, source, t) {
  return env.DB.prepare(
    `INSERT OR IGNORE INTO fitness_unlocks (user_id, kind, value, source, unlocked_at) VALUES (?, ?, ?, ?, ?)`
  ).bind(userId, kind, value, source, t);
}

function activityStatement(env, userId, kind, summary, payload, t) {
  return env.DB.prepare(
    'INSERT INTO activity_feed (id, user_id, kind, summary, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)'
  ).bind(crypto.randomUUID(), userId, kind, summary, JSON.stringify(payload || {}), t);
}

/* ------------------------------------------------------------------ */
/* Sync                                                                */
/* ------------------------------------------------------------------ */

/**
 * Two-way sync (API v2 §3). The client posts sessions it has recorded or
 * changed since its last sync and the cursor it last heard from us; we store
 * them, derive progression from the server's own recomputed totals, and
 * return a page of everything the client is missing.
 *
 * Session ids are client-generated UUIDs:
 *  - a replay (same or lower client_rev) is acknowledged without re-awarding;
 *  - a higher client_rev is an edit (lifetime totals move by the delta, XP is
 *    not re-awarded) or, with deleted: true, a delete (tombstone kept, totals
 *    reduced, XP never clawed back);
 *  - each session's writes commit atomically in one DB.batch, so a failure
 *    part-way through a sync never loses or double-counts anything.
 */
async function handleSync(request, env, userId) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const body = await readJson(request, 4 * 1024 * 1024);
  if (body === BAD_JSON || !isObject(body)) return json({ error: 'body_invalid' }, 400);

  const t = now();
  const profile = await loadProfileRow(env, userId);
  const tzIn = body.tz_offset_min === undefined ? null : parseTzOffset(body.tz_offset_min);
  const tz = tzIn ?? profile.tz_offset_min ?? 0;
  const since = Math.max(0, Math.floor(Number(body.since) || 0));

  // Evaluate, de-duplicate within the request (highest rev wins), oldest first
  // so streak arithmetic walks forward in time. Anything past the per-request
  // cap is simply not acknowledged and stays queued on the device.
  const incoming = Array.isArray(body.sessions) ? body.sessions.slice(0, MAX_SESSIONS_PER_SYNC) : [];
  const rejected = [];
  const byId = new Map();
  for (const raw of incoming) {
    const e = evaluateSession(raw, t);
    if (!e.ok) { rejected.push({ id: e.id || null, error: e.error }); continue; }
    const prev = byId.get(e.id);
    if (!prev || e.clientRev > prev.clientRev) byId.set(e.id, e);
  }
  const sessions = [...byId.values()].sort((a, b) => a.performedAt - b.performedAt || (a.id < b.id ? -1 : 1));

  const accepted = [];
  const run = {
    xp: profile.xp,
    level: profile.level,
    streak: {
      lastDate: profile.last_workout_date,
      current: profile.current_streak,
      longest: profile.longest_streak,
      freezes: profile.streak_freezes || 0,
    },
    xpGained: 0,
    pointsGained: 0,
    raidDamage: 0,
    newSessions: 0,
  };
  const levelBefore = profile.level;

  if (sessions.length) {
    const ctx = await loadSyncContext(env, userId, sessions, t);
    for (const e of sessions) {
      const existing = ctx.existing.get(e.id);
      if (existing && existing.user_id !== userId) {
        rejected.push({ id: e.id, error: 'id_conflict' });
        continue;
      }
      if (existing && e.clientRev <= existing.client_rev) {
        accepted.push(e.id); // replay: acknowledge so the client dequeues it
        continue;
      }
      try {
        if (existing) await applyRevision(env, userId, e, existing, t);
        else await applyNewSession(env, userId, e, ctx, run, tz, t);
        accepted.push(e.id);
      } catch (err) {
        // A concurrent request may have stored the same session first.
        const now2 = await env.DB.prepare('SELECT user_id, client_rev FROM workout_sessions WHERE id = ?')
          .bind(e.id).first();
        if (now2 && now2.user_id === userId && now2.client_rev >= e.clientRev) {
          accepted.push(e.id);
        } else {
          console.error('sync write failed:', err && err.stack ? err.stack : err);
          rejected.push({ id: e.id, error: 'write_failed' });
        }
      }
    }
  }

  // Apple Health numbers (steps_today / active_kcal_today) arrive on every
  // sync, sessions or not. Steps feed the "Step Count" daily quest; the
  // client's reading is trusted (it moves a quest bar, not a leaderboard).
  const healthEvent = eventForHealth(body);
  if (healthEvent) await advanceQuests(env, userId, healthEvent);

  if (tzIn !== null && tzIn !== profile.tz_offset_min) {
    await env.DB.prepare('UPDATE fitness_profiles SET tz_offset_min = ? WHERE user_id = ?').bind(tzIn, userId).run();
  }

  // Guild raid: land this batch's damage on the weekly boss. Workout XP is
  // already banked, so a raid failure can never cost someone their XP.
  let raid = null;
  if (run.raidDamage > 0) {
    try {
      raid = await applyRaidDamage(env, userId, run.raidDamage);
    } catch (e) {
      console.error('applyRaidDamage failed:', e && e.stack ? e.stack : e);
    }
  }

  // Runs after the raid step so raid_slayer can unlock in the same sync.
  const unlocked = run.newSessions > 0 || raid ? await checkAchievements(env, userId) : [];

  const pull = await pullSessions(env, userId, since, t);
  const built = await buildProfile(env, userId);

  return json({
    accepted,
    rejected,
    xp_gained: run.xpGained,
    levels_gained: Math.max(0, run.level - levelBefore),
    talent_points_gained: run.pointsGained,
    achievements_unlocked: unlocked,
    raid,
    sessions: pull.sessions,
    has_more: pull.hasMore,
    cursor: pull.cursor,
    server_time: t,
    profile: built.profile,
  });
}

/** Everything the per-session loop needs, loaded once per sync. */
async function loadSyncContext(env, userId, sessions, t) {
  const ids = sessions.map((s) => s.id);
  const existingRows = await env.DB.prepare(
    `SELECT id, user_id, client_rev, deleted, flagged, total_volume, total_reps
       FROM workout_sessions WHERE id IN (${ids.map(() => '?').join(',')})`
  ).bind(...ids).all();
  const existing = new Map((existingRows.results || []).map((r) => [r.id, r]));

  const { ranks } = await talentRanks(env, userId);
  const social = await env.DB.prepare(
    `SELECT (SELECT COUNT(*) FROM friendships
              WHERE status = 'accepted' AND (user_low = ? OR user_high = ?)) AS friends,
            EXISTS (SELECT 1 FROM guild_members WHERE user_id = ?) AS in_guild`
  ).bind(userId, userId, userId).first();

  // Personal records so far, keyed the same way new ones are written.
  const prRows = await env.DB.prepare(
    'SELECT exercise, reps, weight FROM personal_records WHERE user_id = ? LIMIT 5000'
  ).bind(userId).all();
  const known = new Map();
  for (const r of prRows.results || []) {
    if (!known.has(r.exercise)) known.set(r.exercise, new Map());
    const m = known.get(r.exercise);
    m.set(r.reps, Math.max(m.get(r.reps) || 0, r.weight));
  }

  let quests = [];
  if (sessions.some((s) => !existing.has(s.id) && !s.deleted && !s.flagged)) {
    await ensureBoard(env, userId, t);
    quests = await activeQuestRows(env, userId);
  }

  return {
    existing,
    ranks,
    friendCount: social?.friends || 0,
    inGuild: !!social?.in_guild,
    shieldDays: streakShieldDays(ranks),
    known,
    quests,
  };
}

/** Store a session the server has never seen (or its tombstone). */
async function applyNewSession(env, userId, e, ctx, run, tz, t) {
  const insertSession = (xp, deleted) => env.DB.prepare(
    `INSERT INTO workout_sessions
       (id, user_id, performed_at, name, program_id, duration_secs, total_volume, total_reps,
        xp_earned, payload, client_rev, updated_at, deleted, flagged, flag_reason)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    e.id, userId, e.performedAt, deleted ? null : e.name, e.programId, e.durationSecs,
    e.totalVolume, e.totalReps, xp, deleted ? '{}' : e.payloadJson, e.clientRev, t,
    deleted ? 1 : 0, e.flagged ? 1 : 0, e.flagReason
  );

  // Deleted before it ever synced, or over a plausibility cap: kept for
  // history (and so other devices learn about it), earns nothing.
  if (e.deleted || e.flagged) {
    await env.DB.batch([insertSession(0, e.deleted)]);
    return;
  }

  // Streak first so Second Wind sees the streak this session produces.
  const streak = applySessionDay(run.streak, localDayKey(e.performedAt, tz), ctx.shieldDays);
  const baseXp = xpForWorkout({ total_volume: e.totalVolume, total_reps: e.totalReps, duration_secs: e.durationSecs });
  const xp = applyTalentEffects(baseXp, ctx.ranks, {
    volume: e.totalVolume, streak: streak.current, friends: ctx.friendCount, inGuild: ctx.inGuild,
  });

  // PRs against the records so far (snapshot so a failed batch can be undone).
  const candidates = bestSetsByExercise(e.exercises);
  const snapshot = new Map([...candidates.keys()].map((k) => [k, ctx.known.has(k) ? new Map(ctx.known.get(k)) : null]));
  const { upserts, prCount } = detectPRs(candidates, ctx.known);

  const newXp = run.xp + xp;
  const newLevel = levelForXp(newXp);
  const levelsGained = Math.max(0, newLevel - run.level);
  const points = levelsGained + bonusTalentPoints(ctx.ranks, run.level, newLevel);

  const stmts = [
    insertSession(xp, false),
    env.DB.prepare(
      'INSERT INTO xp_transactions (id, user_id, amount, reason, source_id, created_at) VALUES (?, ?, ?, ?, ?, ?)'
    ).bind(crypto.randomUUID(), userId, xp, 'workout', e.id, t),
    env.DB.prepare(
      `UPDATE fitness_profiles
          SET xp = xp + ?, level = ?, talent_points = talent_points + ?,
              current_streak = ?, longest_streak = MAX(longest_streak, ?), last_workout_date = ?,
              streak_freezes = ?, total_workouts = total_workouts + 1,
              total_volume = total_volume + ?, total_reps = total_reps + ?, updated_at = ?
        WHERE user_id = ?`
    ).bind(
      xp, newLevel, points, streak.current, streak.longest, streak.lastDate, streak.freezes,
      e.totalVolume, e.totalReps, t, userId
    ),
    ...upserts.map((u) => env.DB.prepare(
      `INSERT INTO personal_records (user_id, exercise, reps, weight, estimated_1rm, achieved_at, exercise_name)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (user_id, exercise, reps) DO UPDATE SET
         weight = excluded.weight, estimated_1rm = excluded.estimated_1rm,
         achieved_at = excluded.achieved_at, exercise_name = excluded.exercise_name
       WHERE excluded.weight > personal_records.weight`
    ).bind(userId, u.key, u.reps, u.weight, u.e1rm, e.performedAt, u.name)),
    activityStatement(env, userId, 'workout',
      `finished ${e.name || 'a workout'} — ${Math.round(e.totalVolume).toLocaleString('en-US')} lb moved`,
      { session_id: e.id, xp }, t),
    ...seasonXpStatements(env, userId, xp, t),
    ...rankTitleStatements(env, userId, run.level, newLevel, t),
  ];
  if (prCount > 0) {
    stmts.push(activityStatement(env, userId, 'pr', `set ${prCount} new personal record${prCount === 1 ? '' : 's'}`,
      { session_id: e.id, count: prCount }, t));
  }
  if (levelsGained > 0) {
    stmts.push(activityStatement(env, userId, 'level_up', `reached level ${newLevel}`, { level: newLevel }, t));
  }

  // Quest progress for this session, applied to in-memory rows only once the
  // batch has committed.
  const event = eventForWorkout({
    total_volume: e.totalVolume, total_reps: e.totalReps, duration_secs: e.durationSecs, prs: prCount,
  });
  const questChanges = [];
  for (const row of ctx.quests) {
    if (row.completed_at) continue;
    const next = advance(row, event);
    if (next === row.progress) continue;
    const done = next >= row.target;
    questChanges.push({ row, next, completedAt: done ? t : null });
    stmts.push(env.DB.prepare('UPDATE quests SET progress = ?, completed_at = ? WHERE id = ? AND completed_at IS NULL')
      .bind(next, done ? t : null, row.id));
  }

  try {
    await env.DB.batch(stmts);
  } catch (err) {
    for (const [k, v] of snapshot) { if (v) ctx.known.set(k, v); else ctx.known.delete(k); }
    throw err;
  }

  for (const c of questChanges) { c.row.progress = c.next; c.row.completed_at = c.completedAt; }
  run.streak = { lastDate: streak.lastDate, current: streak.current, longest: streak.longest, freezes: streak.freezes };
  run.xp = newXp;
  run.level = newLevel;
  run.xpGained += xp;
  run.pointsGained += points;
  run.newSessions += 1;
  // Raid damage: only brand-new counted sessions hit the boss, and the PR bonus
  // uses the server-verified PR count.
  run.raidDamage += raidDamage({ total_volume: e.totalVolume, pr_count: prCount });
}

/**
 * A higher client_rev for a session we already have: an edit or a delete.
 * Lifetime totals move by the difference between what the old and the new
 * version count for; XP is never re-awarded or clawed back. Both statements
 * are guarded on the revision we read, so a racing duplicate request changes
 * nothing twice.
 */
async function applyRevision(env, userId, e, existing, t) {
  const oldCounts = !existing.deleted && !existing.flagged;
  const newCounts = !e.deleted && !e.flagged;
  const dWorkouts = (newCounts ? 1 : 0) - (oldCounts ? 1 : 0);
  const dVolume = (newCounts ? e.totalVolume : 0) - (oldCounts ? Number(existing.total_volume) || 0 : 0);
  const dReps = (newCounts ? e.totalReps : 0) - (oldCounts ? Number(existing.total_reps) || 0 : 0);

  const stmts = [];
  if (dWorkouts || dVolume || dReps) {
    stmts.push(env.DB.prepare(
      `UPDATE fitness_profiles
          SET total_workouts = MAX(0, total_workouts + ?), total_volume = MAX(0, total_volume + ?),
              total_reps = MAX(0, total_reps + ?), updated_at = ?
        WHERE user_id = ?
          AND EXISTS (SELECT 1 FROM workout_sessions WHERE id = ? AND user_id = ? AND client_rev = ?)`
    ).bind(dWorkouts, dVolume, dReps, t, userId, e.id, userId, existing.client_rev));
  }
  if (e.deleted) {
    stmts.push(env.DB.prepare(
      `UPDATE workout_sessions
          SET deleted = 1, name = NULL, payload = '{}', client_rev = ?, updated_at = ?
        WHERE id = ? AND user_id = ? AND client_rev = ?`
    ).bind(e.clientRev, t, e.id, userId, existing.client_rev));
    // The workout is gone, so are the posts announcing it.
    stmts.push(env.DB.prepare(
      `DELETE FROM activity_feed
        WHERE user_id = ? AND kind IN ('workout', 'pr') AND json_extract(payload, '$.session_id') = ?`
    ).bind(userId, e.id));
  } else {
    stmts.push(env.DB.prepare(
      `UPDATE workout_sessions
          SET performed_at = ?, name = ?, program_id = ?, duration_secs = ?, total_volume = ?,
              total_reps = ?, payload = ?, client_rev = ?, updated_at = ?, deleted = 0,
              flagged = ?, flag_reason = ?
        WHERE id = ? AND user_id = ? AND client_rev = ?`
    ).bind(
      e.performedAt, e.name, e.programId, e.durationSecs, e.totalVolume, e.totalReps, e.payloadJson,
      e.clientRev, t, e.flagged ? 1 : 0, e.flagReason, e.id, userId, existing.client_rev
    ));
  }
  await env.DB.batch(stmts);
}

/**
 * One page of the caller's sessions changed after `since`, ordered by
 * (updated_at, id). A page never ends part-way through a second, so the
 * next call's `updated_at > cursor` cannot skip a row; when there are no
 * more rows the cursor is one second behind server_time, so a row written by
 * another device in this same second is picked up next time (clients merge
 * idempotently, so the repeat is harmless).
 */
async function pullSessions(env, userId, since, t) {
  const cols = `id, performed_at, name, program_id, duration_secs, total_volume, total_reps, xp_earned,
                payload, client_rev, updated_at, deleted, flagged`;
  const rows = (await env.DB.prepare(
    `SELECT ${cols} FROM workout_sessions
      WHERE user_id = ? AND updated_at > ?
      ORDER BY updated_at ASC, id ASC
      LIMIT ?`
  ).bind(userId, since, PULL_PAGE_SIZE + 1).all()).results || [];

  const hasMore = rows.length > PULL_PAGE_SIZE;
  let page = rows.slice(0, PULL_PAGE_SIZE);
  if (hasMore) {
    const lastTs = page[page.length - 1].updated_at;
    if (rows[PULL_PAGE_SIZE].updated_at === lastTs) {
      const trimmed = page.filter((r) => r.updated_at !== lastTs);
      page = trimmed.length ? trimmed : (await env.DB.prepare(
        `SELECT ${cols} FROM workout_sessions WHERE user_id = ? AND updated_at = ? ORDER BY id ASC`
      ).bind(userId, lastTs).all()).results || [];
    }
  }
  const cursor = hasMore ? page[page.length - 1].updated_at : Math.max(since, t - 1);
  return {
    hasMore,
    cursor,
    sessions: page.map((r) => ({
      id: r.id,
      performed_at: r.performed_at,
      name: r.name,
      program_id: r.program_id,
      duration_secs: r.duration_secs,
      total_volume: r.total_volume,
      total_reps: r.total_reps,
      xp_earned: r.xp_earned,
      client_rev: r.client_rev,
      deleted: !!r.deleted,
      flagged: !!r.flagged,
      updated_at: r.updated_at,
      payload: parseJson(r.payload),
    })),
  };
}

/* ------------------------------------------------------------------ */
/* Activity feed                                                       */
/* ------------------------------------------------------------------ */

async function pushActivity(env, userId, kind, summary, payload) {
  try {
    await activityStatement(env, userId, kind, summary, payload, now()).run();
  } catch (e) {
    console.error('pushActivity failed:', e && e.message);
  }
}

const FEED_PAGE = 50;

/** Feed items owned by self, friends or guildmates, never by a blocked player. */
function visibleFeedWhere() {
  return `(f.user_id = ? OR f.user_id IN (${FRIEND_IDS_SQL}) OR f.user_id IN (${GUILDMATE_IDS_SQL}))
          AND ${notBlocked('f.user_id')}`;
}
const visibleFeedBinds = (userId) => [userId, userId, userId, userId, userId, userId, userId];

async function reactionSummaries(env, userId, activityIds) {
  const map = new Map();
  if (!activityIds.length) return map;
  const rows = await env.DB.prepare(
    `SELECT activity_id, emoji, COUNT(*) AS count, MAX(user_id = ?) AS mine
       FROM activity_reactions WHERE activity_id IN (${activityIds.map(() => '?').join(',')})
      GROUP BY activity_id, emoji ORDER BY MIN(created_at)`
  ).bind(userId, ...activityIds).all();
  for (const r of rows.results || []) {
    if (!map.has(r.activity_id)) map.set(r.activity_id, []);
    map.get(r.activity_id).push({ emoji: r.emoji, count: r.count, mine: !!r.mine });
  }
  return map;
}

// GET feed?before=<created_at>[&before_id=<id>] — newest first, 50 per page.
async function getFeed(request, env, userId) {
  const url = new URL(request.url);
  const before = Math.floor(Number(url.searchParams.get('before')) || 0) || null;
  const beforeId = url.searchParams.get('before_id') || null;

  let cursorSql = '';
  const cursorBinds = [];
  if (before && beforeId) {
    cursorSql = 'AND (f.created_at < ? OR (f.created_at = ? AND f.id < ?))';
    cursorBinds.push(before, before, beforeId);
  } else if (before) {
    cursorSql = 'AND f.created_at < ?';
    cursorBinds.push(before);
  }

  const rows = (await env.DB.prepare(
    `SELECT f.id, f.user_id, f.kind, f.summary, f.payload, f.created_at,
            p.display_name, p.level, p.cosmetic, p.title, u.avatar_url,
            (SELECT COUNT(*) FROM activity_comments c
              WHERE c.activity_id = f.id AND ${notBlocked('c.user_id')}) AS comment_count
       FROM activity_feed f
       JOIN fitness_profiles p ON p.user_id = f.user_id
       JOIN users u ON u.id = f.user_id
      WHERE ${visibleFeedWhere()} ${cursorSql}
      ORDER BY f.created_at DESC, f.id DESC
      LIMIT ?`
  ).bind(userId, userId, ...visibleFeedBinds(userId), ...cursorBinds, FEED_PAGE + 1).all()).results || [];

  const hasMore = rows.length > FEED_PAGE;
  let page = rows.slice(0, FEED_PAGE);
  // A client pages with before=<last item's created_at>. Several items can
  // share one second (a sync posts workout + PR + level-up together), so never
  // end a page part-way through a second unless the whole page is one second.
  if (hasMore && !beforeId && rows[FEED_PAGE].created_at === page[page.length - 1].created_at) {
    const lastTs = page[page.length - 1].created_at;
    const trimmed = page.filter((r) => r.created_at !== lastTs);
    if (trimmed.length) page = trimmed;
  }

  const reactions = await reactionSummaries(env, userId, page.map((r) => r.id));
  const items = page.map((row) => ({
    id: row.id,
    user_id: row.user_id,
    display_name: row.display_name,
    level: row.level,
    avatar_url: row.avatar_url,
    author_cosmetic: row.cosmetic || null,
    author_cosmetic_color: cosmeticColor(row.cosmetic),
    author_title: row.title || null,
    kind: row.kind,
    summary: row.summary,
    payload: parseJson(row.payload),
    created_at: row.created_at,
    reactions: reactions.get(row.id) || [],
    comment_count: row.comment_count || 0,
    is_self: row.user_id === userId,
  }));
  const last = items[items.length - 1];
  return json({
    items,
    has_more: hasMore,
    next_before: hasMore && last ? last.created_at : null,
    next_before_id: hasMore && last ? last.id : null,
  });
}

/** The feed item if the caller may see it (self, friend or guildmate; not blocked). */
async function visibleActivity(env, userId, activityId) {
  return env.DB.prepare(
    `SELECT f.id, f.user_id, f.summary FROM activity_feed f
      WHERE f.id = ? AND ${visibleFeedWhere()}`
  ).bind(activityId, ...visibleFeedBinds(userId)).first();
}

// POST feed/:id/react { emoji } — toggles: a second tap removes the reaction.
async function reactToActivity(request, env, userId, activityId) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const body = await readJson(request);
  if (body === BAD_JSON || !isObject(body)) return badBody();
  if (!body.emoji) return json({ error: 'emoji is required' }, 400);
  const emoji = canonicalEmoji(body.emoji);
  if (!emoji) return json({ error: 'emoji_invalid' }, 400);

  const activity = await visibleActivity(env, userId, activityId);
  if (!activity) {
    const exists = await env.DB.prepare('SELECT 1 AS ok FROM activity_feed WHERE id = ?').bind(activityId).first();
    return exists ? json({ error: 'Not permitted' }, 403) : json({ error: 'Activity not found' }, 404);
  }

  const removed = await env.DB.prepare(
    'DELETE FROM activity_reactions WHERE activity_id = ? AND user_id = ? AND emoji = ?'
  ).bind(activityId, userId, emoji).run();
  let added = false;
  if (!removed.meta || removed.meta.changes === 0) {
    const ins = await env.DB.prepare(
      `INSERT INTO activity_reactions (activity_id, user_id, emoji, created_at)
       VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`
    ).bind(activityId, userId, emoji, now()).run();
    added = !!(ins.meta && ins.meta.changes > 0);
  }

  if (added && activity.user_id !== userId) await advanceQuests(env, userId, { reactions: 1 });

  const summary = await reactionSummaries(env, userId, [activityId]);
  return json({ success: true, reacted: added, reactions: summary.get(activityId) || [] });
}

/* ------------------------------------------------------------------ */
/* Comments, blocks, reports                                           */
/* ------------------------------------------------------------------ */

const COMMENTS_PER_HOUR = 30;
const REPORTS_PER_DAY = 20;

async function handleComments(request, env, userId, activityId) {
  const activity = await visibleActivity(env, userId, activityId);
  if (!activity) return json({ error: 'Activity not found' }, 404);

  if (request.method === 'GET') {
    const rows = await env.DB.prepare(
      `SELECT c.id, c.user_id, c.text, c.created_at, p.display_name, p.level, p.cosmetic
         FROM activity_comments c JOIN fitness_profiles p ON p.user_id = c.user_id
        WHERE c.activity_id = ? AND ${notBlocked('c.user_id')}
        ORDER BY c.created_at ASC, c.rowid ASC
        LIMIT 200`
    ).bind(activityId, userId, userId).all();
    return json({ comments: (rows.results || []).map((r) => shapeComment(r, userId, activity.user_id)) });
  }

  if (request.method === 'POST') {
    const body = await readJson(request, 8 * 1024);
    if (body === BAD_JSON || !isObject(body)) return badBody();
    const check = validateComment(body.text);
    if (!check.ok) return json({ error: check.error }, 400);

    const limit = await rateLimit(env, `comments:user:${userId}`, COMMENTS_PER_HOUR, 3600);
    if (!limit.ok) return tooManyRequests(limit.retryAfter);

    const id = crypto.randomUUID();
    const t = now();
    await env.DB.prepare(
      'INSERT INTO activity_comments (id, activity_id, user_id, text, created_at) VALUES (?, ?, ?, ?, ?)'
    ).bind(id, activityId, userId, check.value, t).run();
    const me = await env.DB.prepare('SELECT display_name, level, cosmetic FROM fitness_profiles WHERE user_id = ?')
      .bind(userId).first();
    return json({
      comment: shapeComment({ id, user_id: userId, text: check.value, created_at: t, ...me }, userId, activity.user_id),
    }, 201);
  }

  return json({ error: 'Method not allowed' }, 405);
}

function shapeComment(row, viewerId, itemOwnerId) {
  return {
    id: row.id,
    user_id: row.user_id,
    display_name: row.display_name,
    level: row.level,
    cosmetic: row.cosmetic || null,
    text: row.text,
    created_at: row.created_at,
    is_self: row.user_id === viewerId,
    can_delete: row.user_id === viewerId || itemOwnerId === viewerId,
  };
}

// DELETE comments/:id — your own comment, or any comment on your own item.
async function deleteComment(env, userId, commentId) {
  const row = await env.DB.prepare(
    `SELECT c.user_id, f.user_id AS owner_id FROM activity_comments c
       JOIN activity_feed f ON f.id = c.activity_id WHERE c.id = ?`
  ).bind(commentId).first();
  if (!row) return json({ error: 'Comment not found' }, 404);
  if (row.user_id !== userId && row.owner_id !== userId) return json({ error: 'Not permitted' }, 403);
  await env.DB.prepare('DELETE FROM activity_comments WHERE id = ?').bind(commentId).run();
  return json({ success: true });
}

async function handleBlocks(request, env, userId, path) {
  const target = path[1] || '';

  if (request.method === 'GET' && !target) {
    const rows = await env.DB.prepare(
      `SELECT b.blocked_id AS user_id, COALESCE(p.display_name, 'Player') AS display_name, b.created_at
         FROM user_blocks b LEFT JOIN fitness_profiles p ON p.user_id = b.blocked_id
        WHERE b.blocker_id = ? ORDER BY b.created_at DESC`
    ).bind(userId).all();
    return json({ blocked: rows.results || [] });
  }

  if (request.method === 'POST' && !target) {
    const body = await readJson(request);
    if (body === BAD_JSON || !isObject(body)) return badBody();
    const otherId = typeof body.user_id === 'string' ? body.user_id : '';
    if (!otherId) return json({ error: 'user_id is required' }, 400);
    if (otherId === userId) return json({ error: 'You cannot block yourself' }, 400);
    const exists = await env.DB.prepare('SELECT 1 AS ok FROM users WHERE id = ?').bind(otherId).first();
    if (!exists) return json({ error: 'Player not found' }, 404);
    const [low, high] = pair(userId, otherId);
    await env.DB.batch([
      env.DB.prepare('INSERT OR IGNORE INTO user_blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)')
        .bind(userId, otherId, now()),
      env.DB.prepare('DELETE FROM friendships WHERE user_low = ? AND user_high = ?').bind(low, high),
      // An open duel invite between the two is withdrawn too.
      env.DB.prepare(
        `UPDATE challenges SET status = 'declined'
          WHERE kind = 'duel' AND status = 'pending'
            AND ((creator_id = ? AND opponent_id = ?) OR (creator_id = ? AND opponent_id = ?))`
      ).bind(userId, otherId, otherId, userId),
    ]);
    return json({ success: true });
  }

  if (request.method === 'DELETE' && target) {
    await env.DB.prepare('DELETE FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?').bind(userId, target).run();
    return json({ success: true });
  }

  return json({ error: 'Unknown endpoint' }, 404);
}

// POST reports { target_type, target_id, reason } — stored for human review.
async function createReport(request, env, userId) {
  const body = await readJson(request, 8 * 1024);
  if (body === BAD_JSON) return badBody();
  const check = validateReport(body);
  if (!check.ok) return json({ error: check.error }, 400);

  const limit = await rateLimit(env, `reports:user:${userId}`, REPORTS_PER_DAY, 86400);
  if (!limit.ok) return tooManyRequests(limit.retryAfter);

  // Keep a copy of the reported text so a later edit or delete cannot erase
  // the evidence.
  let snapshot = null;
  if (check.target_type === 'comment') {
    const r = await env.DB.prepare('SELECT user_id, text FROM activity_comments WHERE id = ?').bind(check.target_id).first();
    if (r) snapshot = JSON.stringify(r);
  } else if (check.target_type === 'feed_item') {
    const r = await env.DB.prepare('SELECT user_id, summary FROM activity_feed WHERE id = ?').bind(check.target_id).first();
    if (r) snapshot = JSON.stringify(r);
  } else if (check.target_type === 'user') {
    const r = await env.DB.prepare('SELECT display_name, bio, title FROM fitness_profiles WHERE user_id = ?')
      .bind(check.target_id).first();
    if (r) snapshot = JSON.stringify(r);
  } else if (check.target_type === 'guild') {
    const r = await env.DB.prepare('SELECT name, motto, emblem FROM guilds WHERE id = ?').bind(check.target_id).first();
    if (r) snapshot = JSON.stringify(r);
  }

  await env.DB.prepare(
    `INSERT OR IGNORE INTO ugc_reports (id, reporter_id, target_type, target_id, reason, snapshot, status, created_at)
     VALUES (?, ?, ?, ?, ?, ?, 'open', ?)`
  ).bind(crypto.randomUUID(), userId, check.target_type, check.target_id, check.reason, snapshot, now()).run();
  return json({ success: true }, 201);
}

/* ------------------------------------------------------------------ */
/* Players                                                             */
/* ------------------------------------------------------------------ */

const SEARCH_PER_MINUTE = 60;

// Columns for a player card; binds: viewer (2) for is_friend.
const CARD_COLUMNS = `p.user_id, p.display_name, p.level, p.xp, p.title, p.cosmetic, p.bio, p.hero_class,
  p.current_streak, p.last_workout_date, p.streak_freezes, p.tz_offset_min, p.total_workouts,
  p.avatar_config, p.is_public, u.avatar_url,
  COALESCE((SELECT t.rank FROM talents t WHERE t.user_id = p.user_id AND t.talent_id = 'streak_shield'), 0) AS shield_rank,
  (SELECT COUNT(*) FROM achievements a WHERE a.user_id = p.user_id) AS achievements_count,
  (SELECT gm.guild_id FROM guild_members gm WHERE gm.user_id = p.user_id LIMIT 1) AS guild_id,
  EXISTS (SELECT 1 FROM friendships fr WHERE fr.status = 'accepted'
           AND ((fr.user_low = p.user_id AND fr.user_high = ?) OR (fr.user_high = p.user_id AND fr.user_low = ?))) AS is_friend`;

async function guildsById(env, ids) {
  const unique = [...new Set(ids.filter(Boolean))];
  const map = new Map();
  if (!unique.length) return map;
  const rows = await env.DB.prepare(
    `SELECT id, name, emblem FROM guilds WHERE id IN (${unique.map(() => '?').join(',')})`
  ).bind(...unique).all();
  for (const g of rows.results || []) map.set(g.id, { id: g.id, name: g.name, emblem: g.emblem });
  return map;
}

/** Effective streak for a card/leaderboard row (shield from the talents subquery). */
function streakOfRow(row, t) {
  return effectiveStreak(
    { lastDate: row.last_workout_date, current: row.current_streak, freezes: row.streak_freezes },
    localDayKey(t, row.tz_offset_min || 0),
    Number(row.shield_rank) || 0
  );
}

function shapeCard(row, viewerId, guilds, t, heroOverride) {
  return {
    user_id: row.user_id,
    display_name: row.display_name,
    level: row.level,
    xp: row.xp,
    title: row.title || null,
    cosmetic: row.cosmetic || null,
    cosmetic_color: cosmeticColor(row.cosmetic),
    bio: row.bio || null,
    hero_class: heroOverride || row.hero_class || (row.total_workouts < RECRUIT_SESSIONS ? 'recruit' : 'paladin'),
    current_streak: streakOfRow(row, t).current,
    total_workouts: row.total_workouts,
    avatar_config: parseJson(row.avatar_config),
    avatar_url: row.avatar_url,
    guild: (row.guild_id && guilds.get(row.guild_id)) || null,
    achievements_count: row.achievements_count || 0,
    is_friend: !!row.is_friend,
    is_self: row.user_id === viewerId,
    is_blocked: false,
  };
}

// GET players/:user_id
async function getPlayer(env, userId, playerId) {
  const rel = await relationship(env, userId, playerId);
  if (rel.blocked) return json({ error: 'Player not found' }, 404);
  const row = await env.DB.prepare(
    `SELECT ${CARD_COLUMNS} FROM fitness_profiles p JOIN users u ON u.id = p.user_id WHERE p.user_id = ?`
  ).bind(userId, userId, playerId).first();
  // Private players are visible only to themselves, friends and guildmates
  // (who already see each other on the guild roster).
  if (!row || (!row.is_public && !rel.self && !rel.friend && !rel.guildmate)) {
    return json({ error: 'Player not found' }, 404);
  }
  const t = now();
  const hero = row.hero_class ? null : (await computeHero(env, playerId, row.total_workouts, t)).hero_class;
  const guilds = await guildsById(env, [row.guild_id]);
  return json({ player: shapeCard(row, userId, guilds, t, hero) });
}

// GET players/search?q= — public players by display-name prefix or exact friend code.
async function searchPlayers(request, env, userId) {
  if (request.method !== 'GET') return json({ error: 'GET only' }, 405);
  const q = cleanSearchQuery(new URL(request.url).searchParams.get('q'));
  if (!q) return json({ error: 'q must be 2-32 characters' }, 400);

  const limit = await rateLimit(env, `search:user:${userId}`, SEARCH_PER_MINUTE, 60);
  if (!limit.ok) return tooManyRequests(limit.retryAfter);

  const code = q.toUpperCase();
  const rows = await env.DB.prepare(
    `SELECT ${CARD_COLUMNS}
       FROM fitness_profiles p JOIN users u ON u.id = p.user_id
      WHERE p.is_public = 1 AND p.user_id != ?
        AND (p.display_name LIKE ? ESCAPE '\\' OR p.friend_code = ?)
        AND ${notBlocked('p.user_id')}
      ORDER BY (p.friend_code = ?) DESC, p.xp DESC, p.user_id ASC
      LIMIT 20`
  ).bind(userId, userId, userId, `${escapeLike(q)}%`, code, userId, userId, code).all();
  const list = rows.results || [];
  const guilds = await guildsById(env, list.map((r) => r.guild_id));
  const t = now();
  return json({ players: list.map((r) => shapeCard(r, userId, guilds, t)) });
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
  season: 'COALESCE(sp.xp, 0)',
};

/**
 * Write 0 over every streak that has lapsed (local day, shield and freezes
 * considered) so ORDER BY current_streak is honest. Idempotent; a lapsed
 * streak can never come back, so this only ever brings stored state in line
 * with what a read would compute.
 */
async function zeroLapsedStreaks(env, t) {
  await env.DB.prepare(
    `UPDATE fitness_profiles SET current_streak = 0
      WHERE current_streak > 0 AND last_workout_date IS NOT NULL
        AND julianday(date(?, 'unixepoch', printf('%+d minutes', tz_offset_min)))
            - julianday(last_workout_date) - 1
            > streak_freezes + COALESCE((SELECT t.rank FROM talents t
                                          WHERE t.user_id = fitness_profiles.user_id
                                            AND t.talent_id = 'streak_shield'), 0)`
  ).bind(t).run();
}

async function getLeaderboard(request, env, userId) {
  const url = new URL(request.url);
  const scope = url.searchParams.get('scope') || 'global';
  const metric = url.searchParams.get('metric') || 'xp';
  const column = METRIC_COLUMNS[metric];
  if (!column) return json({ error: 'Unknown metric' }, 400);
  if (!['global', 'friends', 'guild'].includes(scope)) return json({ error: 'Unknown scope' }, 400);

  const t = now();
  const season = seasonAt(t);
  if (metric === 'streak') await zeroLapsedStreaks(env, t);

  let where;
  let binds;
  if (scope === 'friends') {
    where = `(p.user_id = ? OR p.user_id IN (${FRIEND_IDS_SQL}))`;
    binds = [userId, userId, userId, userId];
  } else if (scope === 'guild') {
    const membership = await env.DB.prepare('SELECT guild_id FROM guild_members WHERE user_id = ?')
      .bind(userId).first();
    if (!membership) return json({ entries: [], scope, metric, you: null });
    where = 'p.user_id IN (SELECT user_id FROM guild_members WHERE guild_id = ?)';
    binds = [membership.guild_id];
  } else {
    // Private players never appear on the global board.
    where = 'p.is_public = 1';
    binds = [];
    if (metric === 'season') where += ' AND COALESCE(sp.xp, 0) > 0';
  }

  const select = `SELECT p.user_id, p.display_name, p.level, p.xp, p.current_streak, p.last_workout_date,
            p.streak_freezes, p.tz_offset_min, p.total_volume, p.total_workouts, p.title, p.cosmetic,
            p.hero_class, u.avatar_url, COALESCE(sp.xp, 0) AS season_xp,
            COALESCE((SELECT t.rank FROM talents t WHERE t.user_id = p.user_id AND t.talent_id = 'streak_shield'), 0) AS shield_rank
       FROM fitness_profiles p
       JOIN users u ON u.id = p.user_id
       LEFT JOIN season_progress sp ON sp.user_id = p.user_id AND sp.season_id = ?`;
  const rows = await env.DB.prepare(
    `${select}
      WHERE ${where} AND ${notBlocked('p.user_id')}
      ORDER BY ${column} DESC, p.user_id ASC
      LIMIT 100`
  ).bind(season.id, ...binds, userId, userId).all();

  const shape = (row, rank) => ({
    rank,
    user_id: row.user_id,
    display_name: row.display_name,
    level: row.level,
    xp: row.xp,
    current_streak: streakOfRow(row, t).current,
    total_volume: row.total_volume,
    total_workouts: row.total_workouts,
    season_xp: season.active ? row.season_xp : 0,
    title: row.title,
    cosmetic: row.cosmetic || null,
    cosmetic_color: cosmeticColor(row.cosmetic),
    hero_class: row.hero_class || null,
    avatar_url: row.avatar_url,
    is_self: row.user_id === userId,
  });
  const entries = (rows.results || []).map((row, index) => shape(row, index + 1));

  // Your rank even outside the top 100 (global board, public players only).
  let you = entries.find((e) => e.is_self) || null;
  if (!you && scope === 'global') {
    const mine = await env.DB.prepare(
      `${select} WHERE p.user_id = ? AND p.is_public = 1`
    ).bind(season.id, userId).first();
    if (mine) {
      const ahead = await env.DB.prepare(
        `SELECT COUNT(*) AS n FROM fitness_profiles p
           LEFT JOIN season_progress sp ON sp.user_id = p.user_id AND sp.season_id = ?
          WHERE ${where} AND ${notBlocked('p.user_id')}
            AND (${column} > ? OR (${column} = ? AND p.user_id < ?))`
      ).bind(season.id, ...binds, userId, userId,
        metricValue(mine, metric), metricValue(mine, metric), userId).first();
      you = shape(mine, (ahead?.n || 0) + 1);
    }
  }

  return json({ scope, metric, entries, you, season_id: season.active ? season.id : null });
}

function metricValue(row, metric) {
  switch (metric) {
    case 'streak': return row.current_streak;
    case 'volume': return row.total_volume;
    case 'workouts': return row.total_workouts;
    case 'season': return row.season_xp;
    default: return row.xp;
  }
}

/* ------------------------------------------------------------------ */
/* Friends                                                             */
/* ------------------------------------------------------------------ */

const FRIEND_REQUESTS_PER_DAY = 50;

async function handleFriends(request, env, userId, path) {
  const action = path[1] || '';

  if (request.method === 'GET' && !action) {
    const rows = await env.DB.prepare(
      `SELECT f.*, p.display_name, p.level, p.current_streak, p.xp, p.is_public, u.avatar_url,
              CASE WHEN f.user_low = ? THEN f.user_high ELSE f.user_low END AS other_id
         FROM friendships f
         JOIN fitness_profiles p
           ON p.user_id = CASE WHEN f.user_low = ? THEN f.user_high ELSE f.user_low END
         JOIN users u ON u.id = p.user_id
        WHERE (f.user_low = ? OR f.user_high = ?)
          AND ${notBlocked('p.user_id')}`
    ).bind(userId, userId, userId, userId, userId, userId).all();

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
        if (row.requested_by === userId) {
          // A request sent by email or id must not reveal a private player's
          // profile before they accept.
          outgoing.push(row.is_public ? entry : {
            user_id: row.other_id, display_name: 'Pending request', level: 1, xp: 0, current_streak: 0, avatar_url: null,
          });
        } else {
          incoming.push(entry);
        }
      }
    }
    return json({ friends, incoming_requests: incoming, outgoing_requests: outgoing });
  }

  if (action === 'request' && request.method === 'POST') {
    const body = await readJson(request);
    if (body === BAD_JSON || !isObject(body)) return badBody();

    const limit = await rateLimit(env, `friend_requests:user:${userId}`, FRIEND_REQUESTS_PER_DAY, 86400);
    if (!limit.ok) return tooManyRequests(limit.retryAfter);

    let targetId = typeof body.user_id === 'string' ? body.user_id : null;

    // One field, two shapes: "ABC234" is a friend code, anything with an @ is
    // an email. The client sends whichever the user typed as `query`.
    const query = String(body.query || '').trim();
    const code = String(body.code || (query && !query.includes('@') ? query : '')).trim().toUpperCase();
    const email = String(body.email || (query.includes('@') ? query : '')).trim().toLowerCase();

    if (!targetId && code) {
      const target = await env.DB.prepare('SELECT user_id FROM fitness_profiles WHERE friend_code = ?')
        .bind(code).first();
      if (!target) return json({ error: 'No player has that friend code' }, 404);
      targetId = target.user_id;
    }
    if (!targetId && email) {
      const target = await env.DB.prepare('SELECT id FROM users WHERE email = ?')
        .bind(email).first();
      // Deliberately the same response whether or not the account exists, so this
      // endpoint can't be used to enumerate which emails are registered.
      if (!target) return json({ success: true, status: 'pending' });
      targetId = target.id;
    }
    if (!targetId) return json({ error: 'user_id, code or email is required' }, 400);
    if (targetId === userId) return json({ error: 'You cannot friend yourself' }, 400);

    const exists = await env.DB.prepare('SELECT 1 AS ok FROM users WHERE id = ?').bind(targetId).first();
    if (!exists) return json({ error: 'Player not found' }, 404);

    // Blocked either way: look exactly like a sent request, store nothing.
    const rel = await relationship(env, userId, targetId);
    if (rel.blocked) return json({ success: true, status: 'pending' });

    const [low, high] = pair(userId, targetId);
    const existing = await env.DB.prepare(
      'SELECT status FROM friendships WHERE user_low = ? AND user_high = ?'
    ).bind(low, high).first();
    if (existing) return json({ success: true, status: existing.status });

    await env.DB.prepare(
      `INSERT OR IGNORE INTO friendships (user_low, user_high, requested_by, status, created_at, updated_at)
       VALUES (?, ?, ?, 'pending', ?, ?)`
    ).bind(low, high, userId, now(), now()).run();

    return json({ success: true, status: 'pending' });
  }

  if (action === 'respond' && request.method === 'POST') {
    const body = await readJson(request);
    if (body === BAD_JSON || !isObject(body)) return badBody();
    const { user_id: otherId, accept } = body;
    if (!otherId || typeof otherId !== 'string') return json({ error: 'user_id is required' }, 400);

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
      // Both sides gained a friend.
      for (const uid of [userId, otherId]) {
        await advanceQuests(env, uid, { friends: 1 });
        await checkAchievements(env, uid);
      }
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

/** Give a guild an invite code if it has none (older rows). */
async function ensureInviteCode(env, guild) {
  if (guild.invite_code) return guild.invite_code;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      const code = randomInviteCode();
      const res = await env.DB.prepare('UPDATE guilds SET invite_code = ? WHERE id = ? AND invite_code IS NULL')
        .bind(code, guild.id).run();
      if (res.meta && res.meta.changes > 0) return code;
      break;
    } catch (e) {
      if (!/UNIQUE|constraint/i.test(String(e && e.message))) throw e;
    }
  }
  const row = await env.DB.prepare('SELECT invite_code FROM guilds WHERE id = ?').bind(guild.id).first();
  return row ? row.invite_code : null;
}

function shapeGuild(row, memberCount) {
  return {
    id: row.id,
    name: row.name,
    motto: row.motto,
    owner_id: row.owner_id,
    emblem: row.emblem,
    member_cap: Math.min(row.member_cap || MAX_GUILD_MEMBERS, MAX_GUILD_MEMBERS),
    created_at: row.created_at,
    invite_code: row.invite_code || null,
    is_open: row.is_open === undefined ? true : !!row.is_open,
    member_count: memberCount,
  };
}

/**
 * Join atomically: the insert only lands while the guild is under its cap and
 * the player is in no guild (backed by the one-guild-per-player index).
 */
async function joinGuild(env, userId, guild, t) {
  const cap = Math.min(guild.member_cap || MAX_GUILD_MEMBERS, MAX_GUILD_MEMBERS);
  let res;
  try {
    res = await env.DB.prepare(
      `INSERT INTO guild_members (guild_id, user_id, role, joined_at)
       SELECT ?, ?, 'member', ?
        WHERE (SELECT COUNT(*) FROM guild_members WHERE guild_id = ?) < ?
          AND NOT EXISTS (SELECT 1 FROM guild_members WHERE user_id = ?)`
    ).bind(guild.id, userId, t, guild.id, cap, userId).run();
  } catch (e) {
    if (/UNIQUE|constraint/i.test(String(e && e.message))) return json({ error: 'Leave your current guild first' }, 409);
    throw e;
  }
  if (!res.meta || res.meta.changes === 0) {
    const mine = await env.DB.prepare('SELECT 1 AS ok FROM guild_members WHERE user_id = ?').bind(userId).first();
    return mine ? json({ error: 'Leave your current guild first' }, 409) : json({ error: 'Guild is full' }, 409);
  }
  await checkAchievements(env, userId);
  return json({ success: true, guild_id: guild.id });
}

async function handleGuild(request, env, userId, path) {
  const action = path[1] || '';
  const t = now();

  if (request.method === 'GET' && !action) {
    const membership = await env.DB.prepare(
      'SELECT guild_id, role FROM guild_members WHERE user_id = ?'
    ).bind(userId).first();
    if (!membership) return json({ guild: null, members: [] });

    const guild = await env.DB.prepare('SELECT * FROM guilds WHERE id = ?')
      .bind(membership.guild_id).first();
    if (!guild) return json({ guild: null, members: [] });
    guild.invite_code = await ensureInviteCode(env, guild);
    const members = await env.DB.prepare(
      `SELECT m.role, m.joined_at, p.user_id, p.display_name, p.level, p.xp,
              p.current_streak, p.cosmetic, u.avatar_url
         FROM guild_members m
         JOIN fitness_profiles p ON p.user_id = m.user_id
         JOIN users u ON u.id = m.user_id
        WHERE m.guild_id = ?
        ORDER BY p.xp DESC`
    ).bind(membership.guild_id).all();
    const list = members.results || [];
    return json({ guild: shapeGuild(guild, list.length), members: list, your_role: membership.role });
  }

  if (request.method === 'POST' && !action) {
    const body = await readJson(request);
    if (body === BAD_JSON || !isObject(body)) return badBody();
    if (!body.name || !String(body.name).trim()) return json({ error: 'name is required' }, 400);
    const name = validateGuildName(body.name);
    if (!name.ok) return json({ error: name.error }, 400);
    const motto = validateGuildMotto(body.motto);
    if (!motto.ok) return json({ error: motto.error }, 400);
    const emblem = validateGuildEmblem(body.emblem);
    if (!emblem.ok) return json({ error: emblem.error }, 400);
    if (body.is_open !== undefined && typeof body.is_open !== 'boolean') return json({ error: 'is_open_invalid' }, 400);

    const existing = await env.DB.prepare('SELECT guild_id FROM guild_members WHERE user_id = ?')
      .bind(userId).first();
    if (existing) return json({ error: 'Leave your current guild first' }, 409);

    const taken = await env.DB.prepare('SELECT id FROM guilds WHERE name = ? COLLATE NOCASE').bind(name.value).first();
    if (taken) return json({ error: 'That guild name is taken' }, 409);

    const guildId = crypto.randomUUID();
    try {
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO guilds (id, name, motto, owner_id, emblem, member_cap, created_at, invite_code, is_open)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
        ).bind(guildId, name.value, motto.value, userId, emblem.value, MAX_GUILD_MEMBERS, t,
          randomInviteCode(), body.is_open === false ? 0 : 1),
        env.DB.prepare(
          `INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES (?, ?, 'owner', ?)`
        ).bind(guildId, userId, t),
      ]);
    } catch (e) {
      if (/UNIQUE|constraint/i.test(String(e && e.message))) {
        return json({ error: 'That guild name is taken, or you already joined a guild' }, 409);
      }
      throw e;
    }

    await checkAchievements(env, userId);
    return json({ success: true, guild_id: guildId }, 201);
  }

  if (request.method === 'PUT' && !action) {
    const body = await readJson(request);
    if (body === BAD_JSON || !isObject(body)) return badBody();
    const membership = await env.DB.prepare('SELECT guild_id, role FROM guild_members WHERE user_id = ?')
      .bind(userId).first();
    if (!membership) return json({ error: 'You are not in a guild' }, 404);
    if (membership.role !== 'owner') return json({ error: 'Only the guild owner can edit the guild' }, 403);

    const values = {};
    if (body.name !== undefined) {
      const r = validateGuildName(body.name);
      if (!r.ok) return json({ error: r.error }, 400);
      const taken = await env.DB.prepare('SELECT id FROM guilds WHERE name = ? COLLATE NOCASE AND id != ?')
        .bind(r.value, membership.guild_id).first();
      if (taken) return json({ error: 'That guild name is taken' }, 409);
      values.name = r.value;
    }
    if (body.motto !== undefined) {
      const r = validateGuildMotto(body.motto);
      if (!r.ok) return json({ error: r.error }, 400);
      values.motto = r.value;
    }
    if (body.emblem !== undefined) {
      const r = validateGuildEmblem(body.emblem);
      if (!r.ok) return json({ error: r.error }, 400);
      values.emblem = r.value;
    }
    if (body.is_open !== undefined) {
      if (typeof body.is_open !== 'boolean') return json({ error: 'is_open_invalid' }, 400);
      values.is_open = body.is_open ? 1 : 0;
    }
    const fields = Object.keys(values);
    if (!fields.length) return json({ error: 'No writable fields supplied' }, 400);
    try {
      await env.DB.prepare(`UPDATE guilds SET ${fields.map((f) => `${f} = ?`).join(', ')} WHERE id = ?`)
        .bind(...fields.map((f) => values[f]), membership.guild_id).run();
    } catch (e) {
      if (/UNIQUE|constraint/i.test(String(e && e.message))) return json({ error: 'That guild name is taken' }, 409);
      throw e;
    }
    const guild = await env.DB.prepare('SELECT * FROM guilds WHERE id = ?').bind(membership.guild_id).first();
    const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM guild_members WHERE guild_id = ?')
      .bind(membership.guild_id).first();
    return json({ success: true, guild: shapeGuild(guild, count?.n || 0) });
  }

  if (action === 'join' && request.method === 'POST') {
    const body = await readJson(request);
    if (body === BAD_JSON || !isObject(body)) return badBody();
    const inviteCode = typeof body.invite_code === 'string' ? body.invite_code.trim().toUpperCase() : '';
    const guildId = typeof body.guild_id === 'string' ? body.guild_id : '';
    if (!inviteCode && !guildId) return json({ error: 'guild_id or invite_code is required' }, 400);

    let guild;
    if (inviteCode) {
      guild = await env.DB.prepare('SELECT * FROM guilds WHERE invite_code = ?').bind(inviteCode).first();
      if (!guild) return json({ error: 'No guild has that invite code' }, 404);
    } else {
      guild = await env.DB.prepare('SELECT * FROM guilds WHERE id = ?').bind(guildId).first();
      if (!guild) return json({ error: 'Guild not found' }, 404);
      if (guild.is_open === 0) return json({ error: 'This guild is invite-only' }, 403);
    }
    return joinGuild(env, userId, guild, t);
  }

  if (action === 'invite_code' && path[2] === 'rotate' && request.method === 'POST') {
    const membership = await env.DB.prepare('SELECT guild_id, role FROM guild_members WHERE user_id = ?')
      .bind(userId).first();
    if (!membership) return json({ error: 'You are not in a guild' }, 404);
    if (!['owner', 'officer'].includes(membership.role)) {
      return json({ error: 'Only guild owners and officers can change the invite code' }, 403);
    }
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const code = randomInviteCode();
      try {
        await env.DB.prepare('UPDATE guilds SET invite_code = ? WHERE id = ?').bind(code, membership.guild_id).run();
        return json({ success: true, invite_code: code });
      } catch (e) {
        if (!/UNIQUE|constraint/i.test(String(e && e.message))) throw e;
      }
    }
    return json({ error: 'Could not generate a code, try again' }, 503);
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
        await env.DB.batch([
          env.DB.prepare(`UPDATE guild_members SET role = 'owner' WHERE guild_id = ? AND user_id = ?`)
            .bind(membership.guild_id, heir.user_id),
          env.DB.prepare('UPDATE guilds SET owner_id = ? WHERE id = ?').bind(heir.user_id, membership.guild_id),
        ]);
      } else {
        await env.DB.prepare('DELETE FROM guilds WHERE id = ?').bind(membership.guild_id).run();
      }
    }
    return json({ success: true });
  }

  return json({ error: 'Unknown endpoint' }, 404);
}

// GET guilds?q= — open guilds by name, or the most populated when q is empty.
async function listGuilds(request, env, userId) {
  const raw = new URL(request.url).searchParams.get('q') || '';
  const q = raw.trim() ? cleanSearchQuery(raw) : '';
  if (raw.trim() && !q) return json({ error: 'q must be 2-32 characters' }, 400);
  if (q) {
    const limit = await rateLimit(env, `search:user:${userId}`, SEARCH_PER_MINUTE, 60);
    if (!limit.ok) return tooManyRequests(limit.retryAfter);
  }
  const rows = await env.DB.prepare(
    `SELECT g.id, g.name, g.motto, g.emblem, g.is_open,
            (SELECT COUNT(*) FROM guild_members m WHERE m.guild_id = g.id) AS member_count
       FROM guilds g
      WHERE g.is_open = 1 ${q ? "AND g.name LIKE ? ESCAPE '\\'" : ''}
        AND ${notBlocked('g.owner_id')}
      ORDER BY member_count DESC, g.created_at DESC
      LIMIT 30`
  ).bind(...(q ? [`%${escapeLike(q)}%`] : []), userId, userId).all();
  return json({
    guilds: (rows.results || []).map((g) => ({
      id: g.id, name: g.name, motto: g.motto, emblem: g.emblem, member_count: g.member_count, is_open: !!g.is_open,
    })),
  });
}

/* ------------------------------------------------------------------ */
/* Seasons                                                             */
/* ------------------------------------------------------------------ */

async function seasonProgress(env, userId, season) {
  if (!season.active) return { season_xp: 0, tier: 0, claimed: [] };
  const row = await env.DB.prepare('SELECT xp FROM season_progress WHERE user_id = ? AND season_id = ?')
    .bind(userId, season.id).first();
  const claims = await env.DB.prepare(
    'SELECT tier FROM season_claims WHERE user_id = ? AND season_id = ? ORDER BY tier'
  ).bind(userId, season.id).all();
  const xp = row ? row.xp : 0;
  return { season_xp: xp, tier: tierForXp(xp), claimed: (claims.results || []).map((r) => r.tier) };
}

// GET season
async function getSeason(env, userId) {
  const t = now();
  const season = seasonAt(t);
  const progress = await seasonProgress(env, userId, season);
  let leaderboard = [];
  if (season.active) {
    const rows = await env.DB.prepare(
      `SELECT sp.user_id, sp.xp AS season_xp, p.display_name, p.level, p.cosmetic
         FROM season_progress sp JOIN fitness_profiles p ON p.user_id = sp.user_id
        WHERE sp.season_id = ? AND sp.xp > 0 AND p.is_public = 1 AND ${notBlocked('sp.user_id')}
        ORDER BY sp.xp DESC, sp.user_id ASC
        LIMIT 20`
    ).bind(season.id, userId, userId).all();
    leaderboard = (rows.results || []).map((r, i) => ({
      rank: i + 1,
      user_id: r.user_id,
      display_name: r.display_name,
      level: r.level,
      season_xp: r.season_xp,
      cosmetic: r.cosmetic || null,
      is_self: r.user_id === userId,
    }));
  }
  const next = season.tiers.find((tier) => tier.xp_required > progress.season_xp) || null;
  return json({
    season: {
      id: season.id,
      number: season.number,
      name: season.name,
      theme: season.theme,
      status: season.status,
      starts_at: season.starts_at,
      ends_at: season.ends_at,
      seconds_left: Math.max(0, season.ends_at - t),
      seconds_until_start: Math.max(0, season.starts_at - t),
      tiers: season.tiers,
    },
    progress: { ...progress, next_tier_xp: next ? next.xp_required : null },
    leaderboard,
  });
}

// POST season/claim { tier }
async function claimSeasonTier(request, env, userId) {
  if (request.method !== 'POST') return json({ error: 'POST only' }, 405);
  const body = await readJson(request);
  if (body === BAD_JSON || !isObject(body)) return badBody();
  const tier = body.tier;
  if (!Number.isInteger(tier) || tier < 1 || tier > TIER_COUNT) return json({ error: 'tier_invalid' }, 400);

  const t = now();
  const season = seasonAt(t);
  if (!season.active) return json({ error: 'season_not_active' }, 409);
  const progress = await seasonProgress(env, userId, season);
  if (progress.tier < tier) return json({ error: 'tier_locked' }, 409);
  if (progress.claimed.includes(tier)) return json({ error: 'already_claimed' }, 409);

  const reward = rewardFor(season.number, tier);
  const stmts = [
    env.DB.prepare('INSERT INTO season_claims (user_id, season_id, tier, claimed_at) VALUES (?, ?, ?, ?)')
      .bind(userId, season.id, tier, t),
  ];
  if (reward.type === 'title' || reward.type === 'cosmetic') {
    stmts.push(unlockStatement(env, userId, reward.type, reward.value, `season:${season.id}`, t));
  } else if (reward.type === 'streak_freeze') {
    const p = await env.DB.prepare('SELECT streak_freezes FROM fitness_profiles WHERE user_id = ?').bind(userId).first();
    // Banked freezes are capped: keep the tier unclaimed until one is used.
    if ((p?.streak_freezes || 0) >= MAX_STREAK_FREEZES) return json({ error: 'streak_freezes_full' }, 409);
    stmts.push(env.DB.prepare(
      'UPDATE fitness_profiles SET streak_freezes = MIN(?, streak_freezes + 1), updated_at = ? WHERE user_id = ?'
    ).bind(MAX_STREAK_FREEZES, t, userId));
  } else if (reward.type === 'talent_point') {
    stmts.push(env.DB.prepare(
      'UPDATE fitness_profiles SET talent_points = talent_points + 1, updated_at = ? WHERE user_id = ?'
    ).bind(t, userId));
  }
  try {
    await env.DB.batch(stmts);
  } catch (e) {
    if (/UNIQUE|constraint/i.test(String(e && e.message))) return json({ error: 'already_claimed' }, 409);
    throw e;
  }
  const built = await buildProfile(env, userId);
  return json({ success: true, tier, reward, profile: built.profile });
}

/* ------------------------------------------------------------------ */
/* Talents                                                             */
/* ------------------------------------------------------------------ */

async function talentState(env, userId) {
  const profile = await env.DB.prepare('SELECT talent_points FROM fitness_profiles WHERE user_id = ?')
    .bind(userId).first();
  if (!profile) return null;
  const rows = await env.DB.prepare('SELECT talent_id, rank FROM talents WHERE user_id = ?')
    .bind(userId).all();
  const ranks = ranksFromRows(rows.results);
  return {
    tree: TALENT_TREE,
    ranks,
    unspent: profile.talent_points,
    spent: pointsSpent(ranks),
  };
}

async function handleTalents(request, env, userId, path) {
  const action = path[1] || '';

  if (request.method === 'GET' && !action) {
    const state = await talentState(env, userId);
    return state ? json(state) : json({ error: 'Profile not found' }, 404);
  }

  if (action === 'spend' && request.method === 'POST') {
    const body = await readJson(request);
    if (body === BAD_JSON || !isObject(body)) return badBody();
    const talentId = body.talent_id;
    if (!talentId || typeof talentId !== 'string') return json({ error: 'talent_id is required' }, 400);

    const state = await talentState(env, userId);
    if (!state) return json({ error: 'Profile not found' }, 404);
    const check = validateSpend(state.ranks, state.unspent, talentId);
    if (!check.ok) return json({ error: check.error }, 409);
    const node = nodeById(talentId);

    // Take the point first (only while one exists), then raise the rank (only
    // while below max). If a racing request already maxed the talent, the
    // point is handed back, so a race can neither overspend nor lose a point.
    const dec = await env.DB.prepare(
      'UPDATE fitness_profiles SET talent_points = talent_points - 1, updated_at = ? WHERE user_id = ? AND talent_points > 0'
    ).bind(now(), userId).run();
    if (!dec.meta || dec.meta.changes === 0) return json({ error: 'No unspent talent points' }, 409);
    const up = await env.DB.prepare(
      `INSERT INTO talents (user_id, talent_id, rank) VALUES (?, ?, 1)
       ON CONFLICT (user_id, talent_id) DO UPDATE SET rank = rank + 1 WHERE rank < ?`
    ).bind(userId, talentId, node.max_rank).run();
    if (!up.meta || up.meta.changes === 0) {
      await env.DB.prepare('UPDATE fitness_profiles SET talent_points = talent_points + 1 WHERE user_id = ?')
        .bind(userId).run();
      return json({ error: 'Talent is already at max rank' }, 409);
    }
    return json({ success: true, ...(await talentState(env, userId)) });
  }

  if (action === 'respec' && request.method === 'POST') {
    const state = await talentState(env, userId);
    if (!state) return json({ error: 'Profile not found' }, 404);
    await env.DB.batch([
      env.DB.prepare('DELETE FROM talents WHERE user_id = ?').bind(userId),
      env.DB.prepare(
        'UPDATE fitness_profiles SET talent_points = talent_points + ?, updated_at = ? WHERE user_id = ?'
      ).bind(state.spent, now(), userId),
    ]);
    return json({ success: true, refunded: state.spent, ...(await talentState(env, userId)) });
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
  const body = await readJson(request);
  if (body === BAD_JSON || !isObject(body)) return badBody();
  const v = validateCreate(body);
  if (!v.ok) return json({ error: v.error }, 400);

  const t = now();
  const challengeId = crypto.randomUUID();
  const endsAt = t + v.days * 86400;

  if (v.kind === 'duel') {
    const opponentId = String(body.opponent_user_id);
    if (opponentId === userId) return json({ error: 'You cannot duel yourself' }, 400);
    const rel = await relationship(env, userId, opponentId);
    if (!rel.friend || rel.blocked) return json({ error: 'You can only duel a friend' }, 403);

    const open = await env.DB.prepare(
      `SELECT id FROM challenges
        WHERE kind = 'duel' AND status IN ('pending','active')
          AND ((creator_id = ? AND opponent_id = ?) OR (creator_id = ? AND opponent_id = ?))`
    ).bind(userId, opponentId, opponentId, userId).first();
    if (open) return json({ error: 'You already have an open duel with this friend' }, 409);

    // Duels start when accepted; starts_at is provisional until then.
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO challenges (id, kind, metric, creator_id, opponent_id, guild_id, starts_at, ends_at, status, created_at)
         VALUES (?, 'duel', ?, ?, ?, NULL, ?, ?, 'pending', ?)`
      ).bind(challengeId, v.metric, userId, opponentId, t, endsAt, t),
      ...[userId, opponentId].map((uid) => env.DB.prepare(
        'INSERT INTO challenge_participants (challenge_id, user_id, joined_at) VALUES (?, ?, ?)'
      ).bind(challengeId, uid, t)),
    ]);
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

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO challenges (id, kind, metric, creator_id, opponent_id, guild_id, starts_at, ends_at, status, created_at)
       VALUES (?, 'guild', ?, ?, NULL, ?, ?, ?, 'active', ?)`
    ).bind(challengeId, v.metric, userId, membership.guild_id, t, endsAt, t),
    env.DB.prepare(
      `INSERT INTO challenge_participants (challenge_id, user_id, joined_at)
       SELECT ?, user_id, ? FROM guild_members WHERE guild_id = ?`
    ).bind(challengeId, t, membership.guild_id),
  ]);
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

/** Counted (not deleted, not flagged) sessions of a challenge's participants in its window. */
async function sessionsInWindow(env, challengeId, startsAt, endsAt) {
  const map = new Map();
  const rows = await env.DB.prepare(
    `SELECT user_id, performed_at, total_volume FROM workout_sessions
      WHERE user_id IN (SELECT user_id FROM challenge_participants WHERE challenge_id = ?)
        AND performed_at >= ? AND performed_at < ? AND deleted = 0 AND flagged = 0`
  ).bind(challengeId, startsAt, endsAt).all();
  for (const r of rows.results || []) {
    if (!map.has(r.user_id)) map.set(r.user_id, []);
    map.get(r.user_id).push(r);
  }
  return map;
}

/** Standings + lazy settlement for one challenge row. */
async function hydrateChallenge(env, row, userId) {
  const participants = await loadParticipants(env, row.id);
  const sessions = await sessionsInWindow(env, row.id, row.starts_at, row.ends_at);
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
        // awardXp is the one XP-outside-sync helper: xp txn, level/talent-point
        // recompute and the level-up feed post all live there.
        await awardXp(env, award.user_id, award.amount, award.reason, row.id);
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
  // Open challenges, plus only the 10 most recent finished ones (the response
  // never shows more), so the per-challenge hydrate stays bounded.
  const rows = await env.DB.prepare(
    `SELECT * FROM (
       SELECT c.* FROM challenges c JOIN challenge_participants cp ON cp.challenge_id = c.id
        WHERE cp.user_id = ? AND c.status IN ('pending','active')
        ORDER BY c.created_at DESC LIMIT 30)
     UNION ALL
     SELECT * FROM (
       SELECT c.* FROM challenges c JOIN challenge_participants cp ON cp.challenge_id = c.id
        WHERE cp.user_id = ? AND c.status = 'finished'
        ORDER BY c.created_at DESC LIMIT 10)`
  ).bind(userId, userId).all();

  const pending = [];
  const active = [];
  const finished = [];
  for (const row of rows.results || []) {
    const c = await hydrateChallenge(env, row, userId);
    if (c.status === 'pending') pending.push(c);
    else if (c.status === 'active') active.push(c);
    else if (c.status === 'finished') finished.push(c);
  }
  finished.sort((a, b) => b.ends_at - a.ends_at);
  return json({ pending, active, finished: finished.slice(0, 10), server_time: now() });
}

/* ------------------------------------------------------------------ */
/* Quests & achievements                                               */
/* ------------------------------------------------------------------ */

/**
 * Award XP outside the sync path (quest claims, achievements, challenges,
 * raids). Re-reads the profile so it composes with whatever handleSync just
 * wrote, pays the same talent bonus points a sync level-up would, credits
 * the season and records crossed rank titles — all in one batch. Returns
 * levels gained.
 */
async function awardXp(env, userId, amount, reason, sourceId) {
  const profile = await env.DB.prepare('SELECT xp, level FROM fitness_profiles WHERE user_id = ?')
    .bind(userId).first();
  if (!profile) return 0;
  const t = now();
  const newXp = profile.xp + amount;
  const newLevel = levelForXp(newXp);
  const gained = Math.max(0, newLevel - profile.level);
  let points = gained;
  if (gained > 0) points += bonusTalentPoints((await talentRanks(env, userId)).ranks, profile.level, newLevel);

  const stmts = [
    env.DB.prepare(
      `UPDATE fitness_profiles SET xp = xp + ?, level = ?, talent_points = talent_points + ?, updated_at = ?
        WHERE user_id = ?`
    ).bind(amount, newLevel, points, t, userId),
    env.DB.prepare(
      'INSERT INTO xp_transactions (id, user_id, amount, reason, source_id, created_at) VALUES (?, ?, ?, ?, ?, ?)'
    ).bind(crypto.randomUUID(), userId, amount, reason, sourceId || null, t),
    ...seasonXpStatements(env, userId, amount, t),
    ...rankTitleStatements(env, userId, profile.level, newLevel, t),
  ];
  if (gained > 0) stmts.push(activityStatement(env, userId, 'level_up', `reached level ${newLevel}`, { level: newLevel }, t));
  await env.DB.batch(stmts);
  return gained;
}

/**
 * Make sure the user's board for right now exists. Deterministic ids make this
 * an idempotent INSERT OR IGNORE, so it is safe to call on every read/event.
 */
async function ensureBoard(env, userId, epoch = now()) {
  const board = boardFor(userId, epoch);
  const stmt = env.DB.prepare(
    `INSERT OR IGNORE INTO quests
       (id, user_id, quest_key, kind, target, progress, xp_reward, expires_at, completed_at, claimed)
     VALUES (?, ?, ?, ?, ?, 0, ?, ?, NULL, 0)`
  );
  await env.DB.batch(board.map((q) => stmt.bind(q.id, userId, q.key, q.kind, q.target, q.xp, q.expires_at)));
  return board;
}

function shapeQuest(row) {
  const def = questDefinition(row.quest_key) || {};
  return {
    id: row.id,
    quest_key: row.quest_key,
    kind: row.kind,
    title: def.title || row.quest_key,
    description: def.desc || '',
    icon: def.icon || 'checkmark.seal.fill',
    metric: def.metric || null,
    target: row.target,
    progress: row.progress,
    xp_reward: row.xp_reward,
    expires_at: row.expires_at,
    completed_at: row.completed_at,
    claimed: !!row.claimed,
  };
}

async function activeQuestRows(env, userId) {
  const rows = await env.DB.prepare(
    `SELECT * FROM quests WHERE user_id = ? AND expires_at > ?
      ORDER BY CASE kind WHEN 'daily' THEN 0 ELSE 1 END, quest_key`
  ).bind(userId, now()).all();
  return rows.results || [];
}

async function getQuests(env, userId) {
  await ensureBoard(env, userId);
  const rows = await activeQuestRows(env, userId);
  const quests = rows.map(shapeQuest);
  return json({
    daily: quests.filter((q) => q.kind === 'daily'),
    weekly: quests.filter((q) => q.kind === 'weekly'),
    server_time: now(),
  });
}

/**
 * Apply an event ({workouts, volume, reps, minutes, prs, reactions, friends,
 * steps}) to every active, unfinished quest. Completion is recorded here; XP
 * is paid out on claim so the player gets the moment. (Synced sessions update
 * quests inside their own batch instead; see applyNewSession.)
 */
async function advanceQuests(env, userId, event) {
  try {
    await ensureBoard(env, userId);
    const rows = await activeQuestRows(env, userId);
    const stmts = [];
    for (const row of rows) {
      if (row.completed_at) continue;
      const next = advance(row, event);
      if (next === row.progress) continue;
      const done = next >= row.target;
      stmts.push(env.DB.prepare('UPDATE quests SET progress = ?, completed_at = ? WHERE id = ? AND completed_at IS NULL')
        .bind(next, done ? now() : null, row.id));
    }
    if (stmts.length) await env.DB.batch(stmts);
  } catch (e) {
    console.error('advanceQuests failed:', e && e.message);
  }
}

async function claimQuest(request, env, userId, questId) {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const row = await env.DB.prepare('SELECT * FROM quests WHERE id = ? AND user_id = ?')
    .bind(questId, userId).first();
  if (!row) return json({ error: 'Quest not found' }, 404);
  if (!row.completed_at) return json({ error: 'Quest not complete' }, 409);
  if (row.claimed) return json({ success: true, xp_gained: 0, levels_gained: 0, quest: shapeQuest(row) });

  // Flip claimed first with a guard so a double-tap cannot pay twice.
  const flip = await env.DB.prepare(
    'UPDATE quests SET claimed = 1 WHERE id = ? AND user_id = ? AND claimed = 0'
  ).bind(questId, userId).run();
  if (!flip.meta || flip.meta.changes === 0) {
    return json({ success: true, xp_gained: 0, levels_gained: 0, quest: shapeQuest({ ...row, claimed: 1 }) });
  }

  const gained = await awardXp(env, userId, row.xp_reward, 'quest', row.id);
  const def = questDefinition(row.quest_key);
  await pushActivity(env, userId, 'quest',
    `completed the ${row.kind} quest "${def ? def.title : row.quest_key}"`,
    { quest_key: row.quest_key, kind: row.kind, xp: row.xp_reward });

  return json({
    success: true,
    xp_gained: row.xp_reward,
    levels_gained: gained,
    quest: shapeQuest({ ...row, claimed: 1 }),
  });
}

/** Snapshot the numbers the achievement rules look at, and what is unlocked already (one query). */
async function achievementStats(env, userId) {
  const p = await env.DB.prepare(
    `SELECT p.level, p.total_workouts, p.total_volume, p.longest_streak,
            (SELECT COUNT(*) FROM friendships
              WHERE status = 'accepted' AND (user_low = p.user_id OR user_high = p.user_id)) AS friend_count,
            EXISTS (SELECT 1 FROM guild_members WHERE user_id = p.user_id) AS in_guild,
            (SELECT COUNT(*) FROM guild_raid_contributions c JOIN guild_raids g ON g.id = c.raid_id
              WHERE c.user_id = p.user_id AND c.damage > 0 AND g.defeated_at IS NOT NULL) AS raids_won,
            (SELECT group_concat(achievement_id) FROM achievements WHERE user_id = p.user_id) AS have
       FROM fitness_profiles p WHERE p.user_id = ?`
  ).bind(userId).first();
  if (!p) return null;
  return {
    stats: {
      level: p.level,
      total_workouts: p.total_workouts,
      total_volume: p.total_volume,
      longest_streak: p.longest_streak,
      friend_count: p.friend_count || 0,
      in_guild: !!p.in_guild,
      raids_won: p.raids_won || 0,
    },
    have: p.have ? String(p.have).split(',') : [],
  };
}

/** Unlock anything newly earned. Returns the ids unlocked on this call. */
async function checkAchievements(env, userId) {
  try {
    const snapshot = await achievementStats(env, userId);
    if (!snapshot) return [];
    const fresh = newlyUnlocked(snapshot.stats, snapshot.have);
    const ids = [];
    for (const a of fresh) {
      const ins = await env.DB.prepare(
        `INSERT OR IGNORE INTO achievements (user_id, achievement_id, unlocked_at, progress) VALUES (?, ?, ?, 1.0)`
      ).bind(userId, a.id, now()).run();
      if (!ins.meta || ins.meta.changes === 0) continue; // raced; already paid
      const title = achievementTitle(a.id);
      if (title) await unlockStatement(env, userId, 'title', title, `achievement:${a.id}`, now()).run();
      await awardXp(env, userId, a.xp, 'achievement', a.id);
      await pushActivity(env, userId, 'achievement', `unlocked "${a.title}"`,
        { achievement_id: a.id, rarity: a.rarity, xp: a.xp });
      ids.push(a.id);
    }
    // Level-based rules may become true only after the XP just paid.
    if (ids.length) {
      const again = await checkAchievements(env, userId);
      ids.push(...again);
    }
    return ids;
  } catch (e) {
    console.error('checkAchievements failed:', e && e.message);
    return [];
  }
}

async function getAchievements(env, userId) {
  const rows = await env.DB.prepare(
    'SELECT achievement_id, unlocked_at FROM achievements WHERE user_id = ?'
  ).bind(userId).all();
  const unlockedAt = new Map((rows.results || []).map((r) => [r.achievement_id, r.unlocked_at]));
  const items = achievementCatalog().map((a) => ({
    ...a,
    unlocked: unlockedAt.has(a.id),
    unlocked_at: unlockedAt.get(a.id) || null,
  }));
  return json({
    achievements: items,
    unlocked_count: unlockedAt.size,
    total_count: items.length,
  });
}

/* ------------------------------------------------------------------ */
/* Guild raids                                                         */
/* ------------------------------------------------------------------ */

// The catalog lives in code (_lib/raids.js); raid_bosses mirrors it so
// guild_raids has a foreign key. Upsert lazily so a fresh database works
// without anyone remembering to seed it.
async function ensureBossRow(env, boss) {
  await env.DB.prepare(
    `INSERT OR IGNORE INTO raid_bosses
       (id, name, flavor, symbol, gradient, base_hp, reward_xp, reward_title, reward_cosmetic)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    boss.id, boss.name, boss.flavor, boss.symbol, JSON.stringify(boss.gradient),
    boss.base_hp, boss.reward_xp, boss.reward_title, boss.reward_cosmetic
  ).run();
}

/** The caller's guild id, or null. */
async function guildIdOf(env, userId) {
  const row = await env.DB.prepare('SELECT guild_id FROM guild_members WHERE user_id = ?')
    .bind(userId).first();
  return row ? row.guild_id : null;
}

/**
 * Find or open the guild's raid for the week containing `at`. hp is fixed at
 * creation from the member count, so the boss does not grow when someone joins.
 */
async function currentRaid(env, guildId, at = now()) {
  const start = weekStart(at);
  const raid = await env.DB.prepare(
    'SELECT * FROM guild_raids WHERE guild_id = ? AND week_start = ?'
  ).bind(guildId, start).first();
  if (raid) return raid;

  const boss = bossForWeek(at);
  await ensureBossRow(env, boss);
  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM guild_members WHERE guild_id = ?')
    .bind(guildId).first();
  const hp = hpForGuild(boss, count?.n || 1);

  // INSERT OR IGNORE + re-select handles two members syncing in the same second.
  await env.DB.prepare(
    `INSERT OR IGNORE INTO guild_raids (id, guild_id, boss_id, week_start, hp, damage_done, created_at)
     VALUES (?, ?, ?, ?, ?, 0, ?)`
  ).bind(crypto.randomUUID(), guildId, boss.id, start, hp, now()).run();

  return env.DB.prepare(
    'SELECT * FROM guild_raids WHERE guild_id = ? AND week_start = ?'
  ).bind(guildId, start).first();
}

function bossById(id) {
  return BOSS_CATALOG.find((b) => b.id === id) || BOSS_CATALOG[0];
}

async function upsertContribution(env, raidId, userId, damage) {
  await env.DB.prepare(
    `INSERT INTO guild_raid_contributions (raid_id, user_id, damage, hits, updated_at)
     VALUES (?, ?, ?, 1, ?)
     ON CONFLICT (raid_id, user_id)
     DO UPDATE SET damage = damage + excluded.damage, hits = hits + 1, updated_at = excluded.updated_at`
  ).bind(raidId, userId, damage, now()).run();
}

/**
 * Land `damage` on the caller's guild boss. Called from handleSync after XP is
 * banked. Returns a summary for the sync response, or null if not in a guild.
 */
async function applyRaidDamage(env, userId, damage) {
  const guildId = await guildIdOf(env, userId);
  if (!guildId) return null;

  const raid = await currentRaid(env, guildId);
  if (!raid) return null;
  const boss = bossById(raid.boss_id);

  await upsertContribution(env, raid.id, userId, damage);

  if (raid.defeated_at) {
    // Boss already down this week; the hit is still recorded above so the
    // contributor list stays honest. A first hit after the kill still counts
    // as taking part, so the reward title and aura are theirs too.
    await env.DB.batch([
      unlockStatement(env, userId, 'title', boss.reward_title, `raid:${boss.id}`, now()),
      unlockStatement(env, userId, 'cosmetic', boss.reward_cosmetic, `raid:${boss.id}`, now()),
    ]);
    return {
      boss_id: boss.id, boss_name: boss.name, damage, hp: raid.hp,
      damage_done: Math.min(raid.damage_done, raid.hp),
      defeated: true, just_defeated: false, reward_xp: 0,
      reward_title: null, reward_cosmetic: null,
    };
  }

  // Atomic increment; the defeat check reads back the result.
  await env.DB.prepare('UPDATE guild_raids SET damage_done = damage_done + ? WHERE id = ?')
    .bind(damage, raid.id).run();
  const after = await env.DB.prepare('SELECT damage_done FROM guild_raids WHERE id = ?')
    .bind(raid.id).first();
  const damageDone = after?.damage_done || 0;

  let justDefeated = false;
  let rewardXp = 0;
  if (damageDone >= raid.hp) {
    // Only the request that flips defeated_at pays out, so a race between two
    // final blows cannot double-reward (same guard checkAchievements uses).
    const flip = await env.DB.prepare(
      'UPDATE guild_raids SET defeated_at = ? WHERE id = ? AND defeated_at IS NULL'
    ).bind(now(), raid.id).run();
    if (flip.meta && flip.meta.changes > 0) {
      justDefeated = true;
      rewardXp = boss.reward_xp;
      await rewardRaidContributors(env, raid.id, guildId, boss, userId);
    }
  }

  return {
    boss_id: boss.id,
    boss_name: boss.name,
    damage,
    hp: raid.hp,
    damage_done: Math.min(damageDone, raid.hp),
    defeated: damageDone >= raid.hp,
    just_defeated: justDefeated,
    reward_xp: rewardXp,
    // Reward cosmetics ride along on the killing sync so the client can equip
    // them immediately (RaidHit.reward_title / reward_cosmetic). Ownership is
    // recorded server-side, so PUT profile accepts them.
    reward_title: justDefeated ? boss.reward_title : null,
    reward_cosmetic: justDefeated ? boss.reward_cosmetic : null,
  };
}

/**
 * On defeat every contributor gets the boss's XP through awardXp (level,
 * talent points and level_up feed handled there), the boss's reward title
 * and aura, a raid_defeated feed item, and an achievement pass so
 * `raid_slayer` (_lib/game.js) unlocks. The syncing user is skipped here for
 * achievements because handleSync runs checkAchievements right after.
 */
async function rewardRaidContributors(env, raidId, guildId, boss, slayerId) {
  const rows = await env.DB.prepare(
    'SELECT user_id, damage FROM guild_raid_contributions WHERE raid_id = ? AND damage > 0'
  ).bind(raidId).all();
  const guild = await env.DB.prepare('SELECT name FROM guilds WHERE id = ?').bind(guildId).first();
  const guildName = guild?.name || 'your guild';
  const t = now();

  const contributors = rows.results || [];
  const unlocks = [];
  for (const row of contributors) {
    unlocks.push(unlockStatement(env, row.user_id, 'title', boss.reward_title, `raid:${boss.id}`, t));
    unlocks.push(unlockStatement(env, row.user_id, 'cosmetic', boss.reward_cosmetic, `raid:${boss.id}`, t));
  }
  if (unlocks.length) await env.DB.batch(unlocks);

  for (const row of contributors) {
    const uid = row.user_id;
    await awardXp(env, uid, boss.reward_xp, 'raid', raidId);
    const finalBlow = uid === slayerId;
    await pushActivity(env, uid, 'raid_defeated',
      finalBlow
        ? `landed the final blow on ${boss.name} with ${guildName}`
        : `helped ${guildName} defeat ${boss.name} — ${Math.round(row.damage).toLocaleString('en-US')} damage`,
      { raid_id: raidId, boss_id: boss.id, damage: row.damage, xp: boss.reward_xp, final_blow: finalBlow });
    if (!finalBlow) await checkAchievements(env, uid);
  }
}

// GET /api/fitness/raid
async function getRaid(env, userId) {
  const guildId = await guildIdOf(env, userId);
  if (!guildId) return json({ raid: null, reason: 'no_guild' });

  const at = now();
  const raid = await currentRaid(env, guildId, at);
  if (!raid) return json({ raid: null, reason: 'unavailable' });
  const boss = bossById(raid.boss_id);

  const top = await env.DB.prepare(
    `SELECT c.user_id, c.damage, c.hits, p.display_name, p.level, u.avatar_url
       FROM guild_raid_contributions c
       JOIN fitness_profiles p ON p.user_id = c.user_id
       JOIN users u ON u.id = c.user_id
      WHERE c.raid_id = ?
      ORDER BY c.damage DESC
      LIMIT 10`
  ).bind(raid.id).all();
  const mine = await env.DB.prepare(
    'SELECT damage, hits FROM guild_raid_contributions WHERE raid_id = ? AND user_id = ?'
  ).bind(raid.id, userId).first();
  const members = await env.DB.prepare('SELECT COUNT(*) AS n FROM guild_members WHERE guild_id = ?')
    .bind(guildId).first();

  const damageDone = Math.min(raid.damage_done, raid.hp);
  return json({
    raid: {
      id: raid.id,
      guild_id: guildId,
      week_start: raid.week_start,
      ends_at: raid.week_start + WEEK_SECS,
      seconds_left: Math.max(0, raid.week_start + WEEK_SECS - at),
      boss: {
        id: boss.id,
        name: boss.name,
        flavor: boss.flavor,
        symbol: boss.symbol,
        gradient: boss.gradient,
        reward_xp: boss.reward_xp,
        reward_title: boss.reward_title,
        reward_cosmetic: boss.reward_cosmetic,
      },
      hp: raid.hp,
      damage_done: damageDone,
      hp_remaining: Math.max(0, raid.hp - damageDone),
      defeated: !!raid.defeated_at,
      defeated_at: raid.defeated_at,
      member_count: members?.n || 0,
      contributors: (top.results || []).map((r, i) => ({
        rank: i + 1,
        user_id: r.user_id,
        display_name: r.display_name,
        level: r.level,
        avatar_url: r.avatar_url,
        damage: r.damage,
        hits: r.hits,
        is_self: r.user_id === userId,
      })),
      my_damage: mine?.damage || 0,
      my_hits: mine?.hits || 0,
    },
  });
}
