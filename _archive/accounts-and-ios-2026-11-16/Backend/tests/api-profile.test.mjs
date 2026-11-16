/**
 * GET/PUT /api/fitness/profile and players/* against the real worker: lazy
 * creation, validation, title/cosmetic ownership, hero class, privacy.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/api-profile.test.mjs
 */

import assert from 'node:assert/strict';
import { clock, makeEnv, createUser, call, runner, session } from './lib/harness.mjs';

const { test, run } = runner('profile v2');

// A blocked term for the filter tests, ROT13-encoded so no such word sits in
// the source in plain text.
const rot13 = (s) => s.replace(/[a-z]/gi, (c) => {
  const base = c <= 'Z' ? 65 : 97;
  return String.fromCharCode(((c.charCodeAt(0) - base + 13) % 26) + base);
});
const BLOCKED = rot13('fuvg');

test('lazy creation: website-only member gets a private, anonymous profile on GET', async () => {
  const env = makeEnv();
  const u = createUser(env, { name: 'Real Name', profile: false });
  const res = await call(env, u, 'GET', 'profile');
  assert.equal(res.status, 200);
  const p = res.body.profile;
  assert.equal(p.is_public, false);
  assert.match(p.display_name, /^Athlete\d{4}$/);
  assert.equal(p.hero_class, 'recruit');
  assert.deepEqual(p.class_affinity, { strength: 0, endurance: 0, mobility: 0, athletic: 0 });
  assert.deepEqual(p.earned_titles, ['Initiate']);
  assert.deepEqual(p.earned_cosmetics, []);
  assert.equal(p.streak_freezes, 0);
  assert.equal(p.streak_alive, false);
  assert.equal(p.season_xp, 0);
  assert.equal(p.onboarded, false);
  assert.match(p.friend_code, /^[A-Z2-9]{6}$/);
  assert.equal(p.weight_unit, 'lb');
});

test('lazy creation on PUT too', async () => {
  const env = makeEnv();
  const u = createUser(env, { profile: false });
  const res = await call(env, u, 'PUT', 'profile', { training_goal: 'Get strong', tz_offset_min: 60 });
  assert.equal(res.status, 200);
  assert.equal(res.body.profile.onboarded, true);
  assert.equal(res.body.profile.tz_offset_min, 60);
});

test('display name: 2–24 chars, allowed characters only, filtered', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const camel = `The${BLOCKED.charAt(0).toUpperCase()}${BLOCKED.slice(1)}`;
  for (const bad of ['a', 'x'.repeat(25), 'bad@name', 'name<script>', '   ', '...', camel, `${BLOCKED}ty`, BLOCKED.replace('i', '1'), 42, null]) {
    const res = await call(env, u, 'PUT', 'profile', { display_name: bad });
    assert.equal(res.status, 400, `accepted ${JSON.stringify(bad)}`);
    assert.equal(res.body.error, 'display_name_invalid');
  }
  for (const good of ["Zoë O'Neil", 'iron_mike-2', 'Ana  Silva ', '李小龙']) {
    const res = await call(env, u, 'PUT', 'profile', { display_name: good });
    assert.equal(res.status, 200, `rejected ${good}`);
  }
  assert.equal((await call(env, u, 'GET', 'profile')).body.profile.display_name, '李小龙');
  const collapsed = await call(env, u, 'PUT', 'profile', { display_name: '  Ana   Silva ' });
  assert.equal(collapsed.body.profile.display_name, 'Ana Silva');
});

test('the filter does not trip on ordinary words', async () => {
  const env = makeEnv();
  const u = createUser(env);
  for (const name of ['Class Act', 'Assessor', 'Grasshopper', 'Spicy Lifter', 'Cocktail Hour', 'Dickens', 'Passion']) {
    const res = await call(env, u, 'PUT', 'profile', { display_name: name });
    assert.equal(res.status, 200, `${name} was blocked`);
  }
});

test('bio ≤ 160 chars, filtered, null clears', async () => {
  const env = makeEnv();
  const u = createUser(env);
  assert.equal((await call(env, u, 'PUT', 'profile', { bio: 'Lifting since 2019.\nPowerlifting meets twice a year.' })).status, 200);
  assert.equal((await call(env, u, 'PUT', 'profile', { bio: 'x'.repeat(161) })).body.error, 'bio_invalid');
  assert.equal((await call(env, u, 'PUT', 'profile', { bio: `so ${BLOCKED.toUpperCase()}` })).body.error, 'bio_invalid');
  assert.equal((await call(env, u, 'PUT', 'profile', { bio: ['nope'] })).body.error, 'bio_invalid');
  const cleared = await call(env, u, 'PUT', 'profile', { bio: null });
  assert.equal(cleared.body.profile.bio, null);
});

test('wrong types are a 400, never a 500', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const cases = [
    [{ is_public: 'yes' }, 'is_public_invalid'],
    [{ body_weight: 'heavy' }, 'body_weight_invalid'],
    [{ body_weight: -5 }, 'body_weight_invalid'],
    [{ height_inches: 500 }, 'height_inches_invalid'],
    [{ birth_year: 1800 }, 'birth_year_invalid'],
    [{ units: 'stone' }, 'units_invalid'],
    [{ tz_offset_min: 900 }, 'tz_offset_invalid'],
    [{ tz_offset_min: '60' }, 'tz_offset_invalid'],
    [{ avatar_config: [1, 2] }, 'avatar_config_invalid'],
    [{ avatar_config: 'not json' }, 'avatar_config_invalid'],
    [{ training_goal: { a: 1 } }, 'training_goal_invalid'],
    [{ title: 7 }, 'title_invalid'],
  ];
  for (const [body, error] of cases) {
    const res = await call(env, u, 'PUT', 'profile', body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.error, error, JSON.stringify(body));
  }
  assert.equal((await call(env, u, 'PUT', 'profile', 'null')).status, 400);
  assert.equal((await call(env, u, 'PUT', 'profile', '{broken')).status, 400);
  assert.equal((await call(env, u, 'PUT', 'profile', { nothing_writable: 1 })).status, 400);
});

test('avatar_config: unknown keys dropped, ≤ 4 KB, returned as an object', async () => {
  const env = makeEnv();
  const u = createUser(env);
  const res = await call(env, u, 'PUT', 'profile', {
    avatar_config: { height: 'Tall', bodyType: 'Athletic', muscleLevel: 40, hasEyes: true, outfit: null, evil: 'x', nested: { a: 1 } },
  });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.profile.avatar_config, { height: 'Tall', bodyType: 'Athletic', muscleLevel: 40, hasEyes: true, outfit: null });
  const big = await call(env, u, 'PUT', 'profile', { avatar_config: { height: 'x'.repeat(5000) } });
  assert.equal(big.body.error, 'avatar_config_invalid');
  // v1 sent a JSON string; it is still accepted.
  const v1 = await call(env, u, 'PUT', 'profile', { avatar_config: JSON.stringify({ skinColor: 'Gold' }) });
  assert.deepEqual(v1.body.profile.avatar_config, { skinColor: 'Gold' });
});

test('units: lb|kg (and v1 imperial|metric) round-trip; weight_unit follows', async () => {
  const env = makeEnv();
  const u = createUser(env);
  assert.equal((await call(env, u, 'PUT', 'profile', { units: 'kg' })).body.profile.weight_unit, 'kg');
  const v1 = await call(env, u, 'PUT', 'profile', { units: 'metric' });
  assert.equal(v1.body.profile.units, 'metric');
  assert.equal(v1.body.profile.weight_unit, 'kg');
});

test('title must be earned; rank titles come from the level; null unequips', async () => {
  const env = makeEnv();
  const u = createUser(env, { level: 12, xp: 6000 });
  assert.equal((await call(env, u, 'PUT', 'profile', { title: 'Ascendant' })).body.error, 'title_not_earned');
  assert.equal((await call(env, u, 'PUT', 'profile', { title: 'Plate Liberator' })).body.error, 'title_not_earned');
  const ok = await call(env, u, 'PUT', 'profile', { title: 'Iron Disciple' });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.profile.title, 'Iron Disciple');
  assert.deepEqual(ok.body.profile.earned_titles, ['Apprentice', 'Initiate', 'Iron Disciple']);
  const off = await call(env, u, 'PUT', 'profile', { title: null });
  assert.equal(off.body.profile.title, null);
});

test('v1 compatibility: echoing back an existing (pre-v2) title or name is allowed', async () => {
  const env = makeEnv();
  const u = createUser(env, { name: 'x' }); // a name the v2 rules would reject
  env.DB.raw.prepare("UPDATE fitness_profiles SET title = 'Self Styled' WHERE user_id = ?").run(u.id);
  // Build 6's Account screen sends display_name + title together.
  const res = await call(env, u, 'PUT', 'profile', { display_name: 'x', title: 'Self Styled' });
  assert.equal(res.status, 200);
  const changed = await call(env, u, 'PUT', 'profile', { display_name: 'New Name', title: 'Self Styled' });
  assert.equal(changed.status, 200);
  assert.equal(changed.body.profile.display_name, 'New Name');
});

test('cosmetic must be earned; raid kills grant title + aura that PUT then accepts', async () => {
  const env = makeEnv();
  const u = createUser(env);
  assert.equal((await call(env, u, 'PUT', 'profile', { cosmetic: 'aura_iron' })).body.error, 'cosmetic_not_earned');
  // Found a guild whose raid boss has 1 hp left, then sync one session.
  const g = await call(env, u, 'POST', 'guild', { name: 'Solo Club' });
  assert.equal(g.status, 201);
  await call(env, u, 'GET', 'raid');
  env.DB.raw.prepare('UPDATE guild_raids SET hp = 100').run();
  const res = await call(env, u, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 100]]]])] });
  assert.equal(res.body.raid.just_defeated, true);
  const { reward_title: title, reward_cosmetic: aura } = res.body.raid;
  assert.ok(res.body.profile.earned_titles.includes(title));
  assert.ok(res.body.profile.earned_cosmetics.includes(aura));
  const equip = await call(env, u, 'PUT', 'profile', { title, cosmetic: aura });
  assert.equal(equip.status, 200);
  assert.equal(equip.body.profile.cosmetic, aura);
  assert.match(equip.body.profile.cosmetic_color, /^#[0-9A-F]{6}$/i);
  // The card, the feed and the leaderboard carry the equipped cosmetic too.
  const feed = await call(env, u, 'GET', 'feed');
  assert.equal(feed.body.items[0].author_cosmetic, aura);
  const card = await call(env, u, 'GET', `players/${u.id}`);
  assert.equal(card.body.player.cosmetic, aura);
  const board = await call(env, u, 'GET', 'leaderboard', undefined, { query: 'scope=guild' });
  assert.equal(board.body.entries[0].cosmetic, aura);
});

test('levelling up records rank titles in fitness_unlocks', async () => {
  const env = makeEnv();
  const u = createUser(env, { level: 4, xp: xpFor(5) - 10 });
  await call(env, u, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 200]]]])] });
  const rows = env.DB.raw.prepare("SELECT value, source FROM fitness_unlocks WHERE user_id = ? AND kind = 'title' AND source = 'rank'").all(u.id);
  assert.deepEqual(rows.map((r) => [r.value, r.source]), [['Apprentice', 'rank']]);
  // First Blood (achievement title) is earned by the first workout.
  const p = await call(env, u, 'GET', 'profile');
  assert.ok(p.body.profile.earned_titles.includes('First Blood'));
  assert.ok(p.body.profile.earned_titles.includes('Apprentice'));
});

function xpFor(level) {
  const n = level - 1;
  return Math.round(100 * n + 15 * n * n + 0.9 * n * n * n);
}

test('hero class: recruit under 3 sessions, then by dominant category share', async () => {
  const env = makeEnv();
  const lifter = createUser(env);
  const runnerU = createUser(env);
  const sync = (u, list) => call(env, u, 'POST', 'sync', { since: 0, sessions: list });
  await sync(lifter, [0, 1].map((i) => session([['Bench Press', [[5, 100]], { category: 'strength' }]], { at: clock.now - 9000 + i })));
  assert.equal((await call(env, lifter, 'GET', 'profile')).body.profile.hero_class, 'recruit');
  await sync(lifter, [session([['Deadlift', [[5, 200], [5, 200]], { category: 'powerlifting' }], ['Stretch', [[1, 0]], { category: 'stretching' }]])]);
  const p = (await call(env, lifter, 'GET', 'profile')).body.profile;
  assert.equal(p.hero_class, 'juggernaut');
  assert.ok(p.class_affinity.strength >= 0.6);

  // v1 payloads without a category fall back to name keywords.
  await sync(runnerU, [0, 1, 2].map((i) => session([['Treadmill Run', [[1, 0]]], ['Rowing Machine', [[1, 0]]]], { at: clock.now - 5000 + i })));
  const r = (await call(env, runnerU, 'GET', 'profile')).body.profile;
  assert.equal(r.hero_class, 'ranger');
  assert.equal(r.class_affinity.endurance, 1);
});

test('players: public card; private players hidden from strangers but not from friends', async () => {
  const env = makeEnv();
  const viewer = createUser(env, { name: 'Viewer' });
  const pub = createUser(env, { name: 'Public One', isPublic: 1 });
  const priv = createUser(env, { name: 'Private One', isPublic: 0 });
  const card = await call(env, viewer, 'GET', `players/${pub.id}`);
  assert.equal(card.status, 200);
  for (const k of ['user_id', 'display_name', 'level', 'xp', 'title', 'hero_class', 'current_streak', 'total_workouts',
    'avatar_config', 'avatar_url', 'guild', 'achievements_count', 'is_friend', 'is_self', 'is_blocked']) {
    assert.ok(k in card.body.player, `card missing ${k}`);
  }
  assert.equal(card.body.player.is_friend, false);
  assert.equal((await call(env, viewer, 'GET', `players/${priv.id}`)).status, 404);
  assert.equal((await call(env, viewer, 'GET', 'players/not-a-user')).status, 404);
  // Become friends: now visible.
  await call(env, viewer, 'POST', 'friends/request', { user_id: priv.id });
  await call(env, priv, 'POST', 'friends/respond', { user_id: viewer.id, accept: true });
  const friendCard = await call(env, viewer, 'GET', `players/${priv.id}`);
  assert.equal(friendCard.status, 200);
  assert.equal(friendCard.body.player.is_friend, true);
  // Self is always visible.
  assert.equal((await call(env, priv, 'GET', `players/${priv.id}`)).body.player.is_self, true);
});

test('players/search: ≥ 2 chars, name prefix or exact friend code, public only, max 20', async () => {
  const env = makeEnv();
  const me = createUser(env, { name: 'Searcher' });
  for (let i = 0; i < 25; i += 1) createUser(env, { name: `Lifter ${String(i).padStart(2, '0')}` });
  const hidden = createUser(env, { name: 'Lifter Private', isPublic: 0 });
  assert.equal((await call(env, me, 'GET', 'players/search', undefined, { query: 'q=L' })).status, 400);
  const res = await call(env, me, 'GET', 'players/search', undefined, { query: 'q=lift' });
  assert.equal(res.status, 200);
  assert.equal(res.body.players.length, 20);
  assert.ok(!res.body.players.some((p) => p.user_id === hidden.id));
  // Exact friend code.
  const target = createUser(env, { name: 'Coded' });
  env.DB.raw.prepare("UPDATE fitness_profiles SET friend_code = 'QWE234' WHERE user_id = ?").run(target.id);
  const byCode = await call(env, me, 'GET', 'players/search', undefined, { query: 'q=qwe234' });
  assert.equal(byCode.body.players[0].user_id, target.id);
  // LIKE wildcards are literal.
  const wild = await call(env, me, 'GET', 'players/search', undefined, { query: 'q=%25%25' });
  assert.equal(wild.body.players.length, 0);
});

test('players/search is rate limited (60/min)', async () => {
  const env = makeEnv();
  const me = createUser(env);
  let last;
  for (let i = 0; i < 61; i += 1) last = await call(env, me, 'GET', 'players/search', undefined, { query: 'q=ab' });
  assert.equal(last.status, 429);
  assert.equal(last.body.error, 'rate_limited');
  assert.ok(last.body.retry_after > 0);
  clock.now += 61;
  assert.equal((await call(env, me, 'GET', 'players/search', undefined, { query: 'q=ab' })).status, 200);
});

await run();
