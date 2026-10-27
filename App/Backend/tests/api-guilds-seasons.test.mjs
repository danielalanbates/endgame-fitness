/**
 * Guilds (§5), seasons (§6), the AI rate limit (§8) and the older game
 * endpoints (talents, challenges, quests, raids) against the real worker.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/api-guilds-seasons.test.mjs
 */

import assert from 'node:assert/strict';
import { clock, makeEnv, createUser, call, runner, session } from './lib/harness.mjs';
import { SEASON_ONE_START, xpRequiredForTier } from '../functions/_lib/seasons.js';

const { test, run } = runner('guilds, seasons, game');
const CODE = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/;

test('guild create: validated name, invite code for members, case-insensitive uniqueness', async () => {
  const env = makeEnv();
  const owner = createUser(env);
  assert.equal((await call(env, owner, 'POST', 'guild', { name: 'ab' })).body.error, 'name_invalid');
  assert.equal((await call(env, owner, 'POST', 'guild', { name: 'x'.repeat(33) })).body.error, 'name_invalid');
  assert.equal((await call(env, owner, 'POST', 'guild', { name: 'Iron <b>' })).body.error, 'name_invalid');
  assert.equal((await call(env, owner, 'POST', 'guild', { name: 'Iron Club', motto: 'm'.repeat(81) })).body.error, 'motto_invalid');
  const res = await call(env, owner, 'POST', 'guild', { name: '  Iron   Club ', motto: 'Lift together', emblem: 'shield.fill' });
  assert.equal(res.status, 201);
  const g = await call(env, owner, 'GET', 'guild');
  assert.equal(g.body.guild.name, 'Iron Club');
  assert.match(g.body.guild.invite_code, CODE);
  assert.equal(g.body.guild.member_cap, 50);
  assert.equal(g.body.guild.is_open, true);
  assert.equal(g.body.your_role, 'owner');
  const other = createUser(env);
  assert.equal((await call(env, other, 'POST', 'guild', { name: 'iron club' })).status, 409);
});

test('discovery lists open guilds only; join by id (open) or by invite code (any)', async () => {
  const env = makeEnv();
  const a = createUser(env);
  const b = createUser(env);
  const joiner = createUser(env);
  await call(env, a, 'POST', 'guild', { name: 'Open Gym' });
  await call(env, b, 'POST', 'guild', { name: 'Secret Society', is_open: false });
  const list = await call(env, joiner, 'GET', 'guilds');
  assert.deepEqual(list.body.guilds.map((g) => g.name), ['Open Gym']);
  for (const k of ['id', 'name', 'motto', 'emblem', 'member_count', 'is_open']) assert.ok(k in list.body.guilds[0]);
  assert.equal((await call(env, joiner, 'GET', 'guilds', undefined, { query: 'q=gym' })).body.guilds.length, 1);
  assert.equal((await call(env, joiner, 'GET', 'guilds', undefined, { query: 'q=zzz' })).body.guilds.length, 0);

  const secret = env.DB.raw.prepare("SELECT id, invite_code FROM guilds WHERE name = 'Secret Society'").get();
  assert.equal((await call(env, joiner, 'POST', 'guild/join', { guild_id: secret.id })).status, 403);
  assert.equal((await call(env, joiner, 'POST', 'guild/join', { invite_code: 'ZZZZZZZZ' })).status, 404);
  const byCode = await call(env, joiner, 'POST', 'guild/join', { invite_code: secret.invite_code.toLowerCase() });
  assert.equal(byCode.status, 200);
  assert.equal((await call(env, joiner, 'GET', 'guild')).body.guild.name, 'Secret Society');
  // One guild at a time.
  const open = env.DB.raw.prepare("SELECT id FROM guilds WHERE name = 'Open Gym'").get();
  assert.equal((await call(env, joiner, 'POST', 'guild/join', { guild_id: open.id })).status, 409);
  assert.equal((await call(env, joiner, 'POST', 'guild/join', {})).status, 400);
});

test('member cap 50 is enforced', async () => {
  const env = makeEnv();
  const owner = createUser(env);
  const created = await call(env, owner, 'POST', 'guild', { name: 'Full House' });
  const gid = created.body.guild_id;
  for (let i = 0; i < 49; i += 1) {
    const u = createUser(env);
    env.DB.raw.prepare("INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES (?, ?, 'member', 1)").run(gid, u.id);
  }
  const late = createUser(env);
  const res = await call(env, late, 'POST', 'guild/join', { guild_id: gid });
  assert.equal(res.status, 409);
  assert.equal(res.body.error, 'Guild is full');
  // A legacy guild row still capped at 25 is raised to the v2 cap of 50 by the
  // migration; the worker never lets a stored cap exceed 50.
  env.DB.raw.prepare('UPDATE guilds SET member_cap = 500 WHERE id = ?').run(gid);
  assert.equal((await call(env, late, 'POST', 'guild/join', { guild_id: gid })).status, 409);
});

test('rotate invite code (owner/officer only); PUT guild (owner only, filtered)', async () => {
  const env = makeEnv();
  const owner = createUser(env);
  const member = createUser(env);
  await call(env, owner, 'POST', 'guild', { name: 'Rotators' });
  const before = (await call(env, owner, 'GET', 'guild')).body.guild.invite_code;
  await call(env, member, 'POST', 'guild/join', { invite_code: before });
  assert.equal((await call(env, member, 'POST', 'guild/invite_code/rotate')).status, 403);
  const rot = await call(env, owner, 'POST', 'guild/invite_code/rotate');
  assert.equal(rot.status, 200);
  assert.match(rot.body.invite_code, CODE);
  assert.notEqual(rot.body.invite_code, before);
  const third = createUser(env);
  assert.equal((await call(env, third, 'POST', 'guild/join', { invite_code: before })).status, 404);

  assert.equal((await call(env, member, 'PUT', 'guild', { motto: 'mine now' })).status, 403);
  assert.equal((await call(env, owner, 'PUT', 'guild', { name: 'x' })).body.error, 'name_invalid');
  assert.equal((await call(env, owner, 'PUT', 'guild', { is_open: 'no' })).body.error, 'is_open_invalid');
  const put = await call(env, owner, 'PUT', 'guild', { name: 'Rotators Prime', motto: 'Again', is_open: false });
  assert.equal(put.status, 200);
  assert.equal(put.body.guild.name, 'Rotators Prime');
  assert.equal(put.body.guild.is_open, false);
  // An officer may rotate.
  env.DB.raw.prepare("UPDATE guild_members SET role = 'officer' WHERE user_id = ?").run(member.id);
  assert.equal((await call(env, member, 'POST', 'guild/invite_code/rotate')).status, 200);
});

test('a guild created before invite codes gets one the first time it is read', async () => {
  const env = makeEnv();
  const owner = createUser(env);
  await call(env, owner, 'POST', 'guild', { name: 'Old Guard' });
  env.DB.raw.prepare('UPDATE guilds SET invite_code = NULL').run();
  const g = await call(env, owner, 'GET', 'guild');
  assert.match(g.body.guild.invite_code, CODE);
});

test('season: upcoming before 2026-11-02, then 30 tiers, season XP, claims, leaderboard', async () => {
  const env = makeEnv();
  const u = createUser(env, { name: 'Seasonal' });
  clock.now = SEASON_ONE_START - 3600;
  let s = await call(env, u, 'GET', 'season');
  assert.equal(s.status, 200);
  assert.equal(s.body.season.status, 'upcoming');
  assert.equal(s.body.season.number, 1);
  assert.equal(s.body.season.tiers.length, 30);
  assert.equal((await call(env, u, 'POST', 'season/claim', { tier: 1 })).body.error, 'season_not_active');
  // XP before the season starts does not count.
  await call(env, u, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 300], [5, 300]]]])] });
  clock.now = SEASON_ONE_START + 3600;
  s = await call(env, u, 'GET', 'season');
  assert.equal(s.body.season.status, 'active');
  assert.equal(s.body.progress.season_xp, 0);

  const res = await call(env, u, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 300], [5, 300], [5, 300]]]])] });
  const earned = res.body.xp_gained;
  assert.ok(earned >= xpRequiredForTier(1), `earned ${earned}`);
  assert.equal(res.body.profile.season_xp, earned);
  s = await call(env, u, 'GET', 'season');
  assert.equal(s.body.progress.season_xp, earned);
  assert.ok(s.body.progress.tier >= 1);
  assert.deepEqual(s.body.progress.claimed, []);
  assert.equal(s.body.leaderboard[0].user_id, u.id);
  assert.equal(s.body.leaderboard[0].is_self, true);

  assert.equal((await call(env, u, 'POST', 'season/claim', { tier: 30 })).body.error, 'tier_locked');
  assert.equal((await call(env, u, 'POST', 'season/claim', { tier: 0 })).body.error, 'tier_invalid');
  assert.equal((await call(env, u, 'POST', 'season/claim', { tier: '1' })).body.error, 'tier_invalid');
  const claim = await call(env, u, 'POST', 'season/claim', { tier: 1 });
  assert.equal(claim.status, 200);
  assert.equal(claim.body.reward.type, 'streak_freeze');
  assert.equal(claim.body.profile.streak_freezes, 1);
  assert.equal((await call(env, u, 'POST', 'season/claim', { tier: 1 })).body.error, 'already_claimed');

  // Title tier: the title lands in earned_titles and can be equipped.
  env.DB.raw.prepare('UPDATE season_progress SET xp = ? WHERE user_id = ?').run(xpRequiredForTier(5), u.id);
  const title = await call(env, u, 'POST', 'season/claim', { tier: 5 });
  assert.equal(title.body.reward.type, 'title');
  assert.ok(title.body.profile.earned_titles.includes(title.body.reward.value));
  assert.equal((await call(env, u, 'PUT', 'profile', { title: title.body.reward.value })).status, 200);
  // Talent point tier.
  const tp = await call(env, u, 'POST', 'season/claim', { tier: 4 });
  assert.equal(tp.body.reward.type, 'talent_point');
  // Freezes are capped at 3: a freeze tier stays claimable until one is used.
  env.DB.raw.prepare('UPDATE fitness_profiles SET streak_freezes = 3 WHERE user_id = ?').run(u.id);
  assert.equal((await call(env, u, 'POST', 'season/claim', { tier: 2 })).body.error, 'streak_freezes_full');

  const board = await call(env, u, 'GET', 'leaderboard', undefined, { query: 'metric=season' });
  assert.equal(board.status, 200);
  assert.equal(board.body.entries[0].user_id, u.id);
  assert.equal(board.body.entries[0].season_xp, xpRequiredForTier(5));
});

test('AI endpoint: 20 calls per player per day, then 429; bad bodies are 400', async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({ choices: [{ message: { content: 'Do more squats.' } }] }), { status: 200 });
  try {
    const env = makeEnv({ OPENROUTER_API_KEY: 'test-key' });
    const u = createUser(env);
    assert.equal((await call(env, u, 'POST', 'ai', '{oops')).status, 400);
    assert.equal((await call(env, u, 'POST', 'ai', { task: 'write_poem' })).status, 400);
    let res;
    for (let i = 0; i < 20; i += 1) res = await call(env, u, 'POST', 'ai', { task: 'improve_workout', workout: [] });
    assert.equal(res.status, 200);
    assert.equal(res.body.text, 'Do more squats.');
    res = await call(env, u, 'POST', 'ai', { task: 'improve_workout', workout: [] });
    assert.equal(res.status, 429);
    assert.equal(res.body.error, 'rate_limited');
    assert.ok(Number(res.headers.get('Retry-After')) > 0);
    // Another player has their own allowance.
    const other = createUser(env);
    assert.equal((await call(env, other, 'POST', 'ai', { task: 'build_mesocycle', goal: 'strength' })).status, 200);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('talents: spend validates, cannot lose a point at max rank, respec refunds', async () => {
  const env = makeEnv();
  const u = createUser(env);
  env.DB.raw.prepare('UPDATE fitness_profiles SET talent_points = 10 WHERE user_id = ?').run(u.id);
  for (let i = 0; i < 5; i += 1) assert.equal((await call(env, u, 'POST', 'talents/spend', { talent_id: 'momentum' })).status, 200);
  const max = await call(env, u, 'POST', 'talents/spend', { talent_id: 'momentum' });
  assert.equal(max.status, 409);
  const state = await call(env, u, 'GET', 'talents');
  assert.equal(state.body.unspent, 5);
  assert.equal(state.body.ranks.momentum, 5);
  assert.equal((await call(env, u, 'POST', 'talents/spend', {})).status, 400);
  const respec = await call(env, u, 'POST', 'talents/respec');
  assert.equal(respec.body.refunded, 5);
  assert.equal(respec.body.unspent, 10);
});

test('quest claims pay talent bonus points (Mentor) and credit the season', async () => {
  const env = makeEnv();
  clock.now = SEASON_ONE_START + 86400;
  const u = createUser(env, { level: 4, xp: 600 }); // L5 at 698 XP
  env.DB.raw.prepare("INSERT INTO talents (user_id, talent_id, rank) VALUES (?, 'mentor', 1)").run(u.id);
  await call(env, u, 'GET', 'quests');
  const quest = env.DB.raw.prepare("SELECT id FROM quests WHERE user_id = ? AND kind = 'weekly' LIMIT 1").get(u.id);
  env.DB.raw.prepare('UPDATE quests SET progress = target, completed_at = ?, xp_reward = 200 WHERE id = ?').run(clock.now, quest.id);
  const res = await call(env, u, 'POST', `quests/${quest.id}/claim`);
  assert.equal(res.status, 200);
  assert.equal(res.body.levels_gained, 1); // 4 → 5
  const p = env.DB.raw.prepare('SELECT level, talent_points FROM fitness_profiles WHERE user_id = ?').get(u.id);
  assert.equal(p.level, 5);
  assert.equal(p.talent_points, 2, 'one point for the level + one Mentor bonus at level 5');
  const sp = env.DB.raw.prepare('SELECT xp FROM season_progress WHERE user_id = ?').get(u.id);
  assert.equal(sp.xp, 200);
  // Double claim pays nothing.
  assert.equal((await call(env, u, 'POST', `quests/${quest.id}/claim`)).body.xp_gained, 0);
});

test('duels: friends only, standings ignore flagged and deleted sessions', async () => {
  const env = makeEnv();
  const a = createUser(env);
  const b = createUser(env);
  const stranger = createUser(env);
  assert.equal((await call(env, a, 'POST', 'challenges', { kind: 'duel', metric: 'volume', opponent_user_id: stranger.id, days: 3 })).status, 403);
  await call(env, a, 'POST', 'friends/request', { user_id: b.id });
  await call(env, b, 'POST', 'friends/respond', { user_id: a.id, accept: true });
  const duel = await call(env, a, 'POST', 'challenges', { kind: 'duel', metric: 'volume', opponent_user_id: b.id, days: 3 });
  assert.equal(duel.status, 201);
  await call(env, b, 'POST', `challenges/${duel.body.challenge_id}/accept`);
  clock.now += 60;
  const good = session([['Squat', [[5, 100]]]], { at: clock.now - 10 });
  const cheat = session([['Squat', [[5, 2000]]]], { at: clock.now - 5 });
  const gone = session([['Squat', [[5, 300]]]], { at: clock.now - 3 });
  await call(env, a, 'POST', 'sync', { since: 0, sessions: [good, cheat, gone] });
  await call(env, a, 'POST', 'sync', { since: 0, sessions: [{ id: gone.id, client_rev: 2, deleted: true, performed_at: gone.performed_at }] });
  const list = await call(env, a, 'GET', 'challenges');
  const mine = list.body.active[0].standings.find((s) => s.is_self);
  assert.equal(mine.score, 500);
  assert.equal(mine.sessions, 1);
});

test('raid: a kill pays every contributor XP, title and aura', async () => {
  const env = makeEnv();
  const a = createUser(env);
  const b = createUser(env);
  const g = await call(env, a, 'POST', 'guild', { name: 'Raiders' });
  await call(env, b, 'POST', 'guild/join', { guild_id: g.body.guild_id });
  await call(env, a, 'GET', 'raid');
  env.DB.raw.prepare('UPDATE guild_raids SET hp = 1500').run();
  await call(env, b, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 100]]]])] });
  const kill = await call(env, a, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[10, 100]]]])] });
  assert.equal(kill.body.raid.just_defeated, true);
  for (const uid of [a.id, b.id]) {
    const owned = env.DB.raw.prepare('SELECT kind, value FROM fitness_unlocks WHERE user_id = ? AND source LIKE ?').all(uid, 'raid:%');
    assert.deepEqual(owned.map((r) => r.kind).sort(), ['cosmetic', 'title']);
  }
  const bp = await call(env, b, 'GET', 'profile');
  assert.ok(bp.body.profile.earned_titles.includes(kill.body.raid.reward_title));
  assert.equal((await call(env, b, 'GET', 'achievements')).body.achievements.find((x) => x.id === 'raid_slayer').unlocked, true);
});

test('v1 shapes survive: profile, feed, leaderboard, friends, guild, quests keep their v1 fields', async () => {
  const env = makeEnv();
  const u = createUser(env);
  await call(env, u, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 100]]]])] });
  const p = (await call(env, u, 'GET', 'profile')).body;
  for (const k of ['user_id', 'email', 'display_name', 'avatar_url', 'level', 'xp', 'xp_for_next_level', 'xp_for_current_level',
    'talent_points', 'prestige', 'current_streak', 'longest_streak', 'last_workout_date', 'total_workouts', 'total_volume',
    'total_reps', 'training_goal', 'experience_level', 'equipment_level', 'body_weight', 'height_inches', 'birth_year',
    'units', 'avatar_config', 'title', 'is_public', 'friend_code']) {
    assert.ok(k in p.profile, `profile missing ${k}`);
  }
  assert.equal(typeof p.profile.is_public, 'boolean');
  for (const k of ['talents', 'achievements', 'personal_records']) assert.ok(Array.isArray(p[k]));
  const s = (await call(env, u, 'POST', 'sync', { since: 0, sessions: [] })).body;
  for (const k of ['accepted', 'xp_gained', 'levels_gained', 'talent_points_gained', 'achievements_unlocked', 'raid',
    'sessions', 'has_more', 'server_time', 'profile']) assert.ok(k in s, `sync missing ${k}`);
  assert.equal(typeof s.sessions[0].deleted, 'boolean');
  const q = (await call(env, u, 'GET', 'quests')).body;
  assert.equal(q.daily.length, 3);
  assert.equal(q.weekly.length, 2);
  const lb = (await call(env, u, 'GET', 'leaderboard', undefined, { query: 'scope=friends' })).body;
  for (const k of ['rank', 'user_id', 'display_name', 'level', 'xp', 'current_streak', 'total_volume', 'total_workouts',
    'title', 'avatar_url', 'is_self']) assert.ok(k in lb.entries[0], `leaderboard missing ${k}`);
  assert.equal((await call(env, null, 'GET', 'profile')).status, 401);
  assert.equal((await call(env, u, 'GET', 'nope')).status, 404);
  const pre = await call(env, null, 'OPTIONS', 'profile');
  assert.equal(pre.status, 204);
});

await run();
