/**
 * Social and safety endpoints against the real worker (API v2 §4):
 * reactions, feed paging, comments, blocks, reports, friends, leaderboards,
 * and the D1 100-bound-parameter limit.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/api-social.test.mjs
 */

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { clock, makeEnv, createUser, call, runner, session } from './lib/harness.mjs';

const { test, run } = runner('social + safety');

const rot13 = (s) => s.replace(/[a-z]/g, (c) => String.fromCharCode(((c.charCodeAt(0) - 97 + 13) % 26) + 97));
const BLOCKED = rot13('fuvg');

function befriend(env, a, b) {
  const [low, high] = a.id < b.id ? [a.id, b.id] : [b.id, a.id];
  env.DB.raw.prepare(
    "INSERT INTO friendships (user_low, user_high, requested_by, status, created_at, updated_at) VALUES (?, ?, ?, 'accepted', 1, 1)"
  ).run(low, high, a.id);
}

function post(env, user, summary = 'did a thing', at = clock.now) {
  const id = randomUUID();
  env.DB.raw.prepare('INSERT INTO activity_feed (id, user_id, kind, summary, payload, created_at) VALUES (?, ?, ?, ?, ?, ?)')
    .run(id, user.id, 'workout', summary, '{}', at);
  return id;
}

test('reactions toggle, report `mine`, and only allow the reaction set', async () => {
  const env = makeEnv();
  const a = createUser(env);
  const b = createUser(env);
  befriend(env, a, b);
  const item = post(env, b);
  let res = await call(env, a, 'POST', `feed/${item}/react`, { emoji: '💪' });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.reactions, [{ emoji: '💪', count: 1, mine: true }]);
  res = await call(env, b, 'POST', `feed/${item}/react`, { emoji: '💪' });
  assert.deepEqual(res.body.reactions, [{ emoji: '💪', count: 2, mine: true }]);
  res = await call(env, a, 'POST', `feed/${item}/react`, { emoji: '💪' }); // second tap removes
  assert.equal(res.body.reacted, false);
  assert.deepEqual(res.body.reactions, [{ emoji: '💪', count: 1, mine: false }]);
  assert.equal((await call(env, a, 'POST', `feed/${item}/react`, { emoji: '😀' })).body.error, 'emoji_invalid');
  assert.equal((await call(env, a, 'POST', `feed/${item}/react`, { emoji: 'x'.repeat(500) })).status, 400);
  // The v1 PWA's ⚔️ still works, with or without the variation selector.
  assert.equal((await call(env, a, 'POST', `feed/${item}/react`, { emoji: '⚔' })).status, 200);
  assert.equal((await call(env, a, 'POST', `feed/${item}/react`, { emoji: '⚡️' })).body.reactions.find((r) => r.emoji === '⚡').mine, true);
  // Strangers cannot react.
  const stranger = createUser(env);
  assert.equal((await call(env, stranger, 'POST', `feed/${item}/react`, { emoji: '🔥' })).status, 403);
  assert.equal((await call(env, stranger, 'POST', 'feed/nope/react', { emoji: '🔥' })).status, 404);
});

test('feed: self + friends + guildmates, 50 per page, before= cursor, comment_count', async () => {
  const env = makeEnv();
  const me = createUser(env);
  const friend = createUser(env);
  const mate = createUser(env);
  const stranger = createUser(env);
  befriend(env, me, friend);
  const g = await call(env, me, 'POST', 'guild', { name: 'Feed Guild' });
  env.DB.raw.prepare("INSERT INTO guild_members (guild_id, user_id, role, joined_at) VALUES (?, ?, 'member', 1)").run(g.body.guild_id, mate.id);
  env.DB.raw.prepare('DELETE FROM activity_feed').run();
  const ids = [];
  for (let i = 0; i < 70; i += 1) {
    const who = [me, friend, mate][i % 3];
    // Pairs of items share a second, like a sync posting workout + PR together.
    ids.push(post(env, who, `item ${i}`, clock.now - 1000 + Math.floor(i / 2)));
  }
  post(env, stranger, 'hidden');
  await call(env, friend, 'POST', `feed/${ids[69]}/comments`, { text: 'nice' });

  const page1 = await call(env, me, 'GET', 'feed');
  assert.equal(page1.status, 200);
  assert.equal(page1.body.has_more, true);
  assert.ok(page1.body.items.length <= 50 && page1.body.items.length >= 48);
  assert.equal(page1.body.items[0].comment_count, page1.body.items[0].id === ids[69] ? 1 : 0);
  const last = page1.body.items[page1.body.items.length - 1];
  const page2 = await call(env, me, 'GET', 'feed', undefined, { query: `before=${last.created_at}` });
  const all = [...page1.body.items, ...page2.body.items].map((i) => i.id);
  assert.equal(new Set(all).size, 70, 'no item lost or repeated across pages');
  assert.ok(!all.some((id) => !ids.includes(id)), 'no stranger items');
  assert.equal(page2.body.has_more, false);
  for (const k of ['reactions', 'comment_count', 'author_cosmetic', 'is_self', 'display_name', 'summary']) {
    assert.ok(k in page1.body.items[0], `feed item missing ${k}`);
  }
});

test('comments: visible items only, filtered, 1–280 chars, delete rules, 30/hour', async () => {
  const env = makeEnv();
  const owner = createUser(env, { name: 'Owner' });
  const friend = createUser(env, { name: 'Friend' });
  const other = createUser(env, { name: 'Other' });
  befriend(env, owner, friend);
  befriend(env, owner, other);
  const item = post(env, owner);
  const c1 = await call(env, friend, 'POST', `feed/${item}/comments`, { text: '  strong work  ' });
  assert.equal(c1.status, 201);
  assert.equal(c1.body.comment.text, 'strong work');
  assert.equal(c1.body.comment.is_self, true);
  assert.equal((await call(env, friend, 'POST', `feed/${item}/comments`, { text: '' })).body.error, 'text_invalid');
  assert.equal((await call(env, friend, 'POST', `feed/${item}/comments`, { text: 'x'.repeat(281) })).body.error, 'text_invalid');
  assert.equal((await call(env, friend, 'POST', `feed/${item}/comments`, { text: `${BLOCKED} lift` })).body.error, 'text_blocked');
  assert.equal((await call(env, friend, 'POST', `feed/${item}/comments`, { text: 5 })).status, 400);
  // A stranger can neither read nor comment.
  const stranger = createUser(env);
  assert.equal((await call(env, stranger, 'GET', `feed/${item}/comments`)).status, 404);
  assert.equal((await call(env, stranger, 'POST', `feed/${item}/comments`, { text: 'hi' })).status, 404);

  const c2 = await call(env, other, 'POST', `feed/${item}/comments`, { text: 'me too' });
  const list = await call(env, owner, 'GET', `feed/${item}/comments`);
  assert.deepEqual(list.body.comments.map((c) => c.text), ['strong work', 'me too']);
  for (const k of ['id', 'user_id', 'display_name', 'level', 'text', 'created_at', 'is_self']) assert.ok(k in list.body.comments[0]);
  // Delete: not someone else's comment on someone else's item...
  assert.equal((await call(env, friend, 'DELETE', `comments/${c2.body.comment.id}`)).status, 403);
  // ...but your own, or any comment on your own item.
  assert.equal((await call(env, friend, 'DELETE', `comments/${c1.body.comment.id}`)).status, 200);
  assert.equal((await call(env, owner, 'DELETE', `comments/${c2.body.comment.id}`)).status, 200);
  assert.equal((await call(env, owner, 'GET', `feed/${item}/comments`)).body.comments.length, 0);
  assert.equal((await call(env, owner, 'DELETE', 'comments/missing')).status, 404);

  // One comment already posted this hour (rejected ones never count).
  let res;
  for (let i = 0; i < 29; i += 1) res = await call(env, friend, 'POST', `feed/${item}/comments`, { text: `rep ${i}` });
  assert.equal(res.status, 201);
  res = await call(env, friend, 'POST', `feed/${item}/comments`, { text: 'one more' });
  assert.equal(res.status, 429);
  assert.equal(res.body.error, 'rate_limited');
});

test('blocks hide both players from each other everywhere and end the friendship', async () => {
  const env = makeEnv();
  const a = createUser(env, { name: 'Alpha' });
  const b = createUser(env, { name: 'Bravo' });
  const c = createUser(env, { name: 'Charlie' });
  befriend(env, a, b);
  befriend(env, a, c);
  befriend(env, b, c);
  const bItem = post(env, b, 'bravo post');
  const cItem = post(env, c, 'charlie post');
  await call(env, b, 'POST', `feed/${cItem}/comments`, { text: 'from bravo' });

  const blk = await call(env, a, 'POST', 'blocks', { user_id: b.id });
  assert.equal(blk.status, 200);
  assert.equal((await call(env, a, 'POST', 'blocks', { user_id: a.id })).status, 400);
  assert.equal((await call(env, a, 'POST', 'blocks', { user_id: 'nobody' })).status, 404);
  assert.deepEqual((await call(env, a, 'GET', 'blocks')).body.blocked.map((x) => x.user_id), [b.id]);

  // Friendship gone.
  assert.ok(!(await call(env, a, 'GET', 'friends')).body.friends.some((f) => f.user_id === b.id));
  // Feed, both directions.
  assert.ok(!(await call(env, a, 'GET', 'feed')).body.items.some((i) => i.id === bItem));
  // Comments by the blocked player on a third party's item are hidden, and counted out.
  const cs = await call(env, a, 'GET', `feed/${cItem}/comments`);
  assert.equal(cs.body.comments.length, 0);
  const feedItem = (await call(env, a, 'GET', 'feed')).body.items.find((i) => i.id === cItem);
  assert.equal(feedItem.comment_count, 0);
  // ...but C still sees it.
  assert.equal((await call(env, c, 'GET', `feed/${cItem}/comments`)).body.comments.length, 1);
  // Player card, search, leaderboard.
  assert.equal((await call(env, a, 'GET', `players/${b.id}`)).status, 404);
  assert.equal((await call(env, b, 'GET', `players/${a.id}`)).status, 404);
  assert.ok(!(await call(env, a, 'GET', 'players/search', undefined, { query: 'q=Bra' })).body.players.length);
  assert.ok(!(await call(env, b, 'GET', 'players/search', undefined, { query: 'q=Alp' })).body.players.length);
  const board = await call(env, a, 'GET', 'leaderboard');
  assert.ok(!board.body.entries.some((e) => e.user_id === b.id));
  // Friend requests from the blocked side look sent but store nothing.
  const req = await call(env, b, 'POST', 'friends/request', { user_id: a.id });
  assert.deepEqual(req.body, { success: true, status: 'pending' });
  assert.equal(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM friendships WHERE requested_by = ?').get(b.id).n, 1); // only b↔c
  // Unblock restores visibility (not the friendship).
  assert.equal((await call(env, a, 'DELETE', `blocks/${b.id}`)).status, 200);
  assert.equal((await call(env, a, 'GET', `players/${b.id}`)).status, 200);
});

test('reports: validated, stored with a snapshot, 20/day', async () => {
  const env = makeEnv();
  const a = createUser(env);
  const b = createUser(env, { name: 'Reported' });
  const res = await call(env, a, 'POST', 'reports', { target_type: 'user', target_id: b.id, reason: 'Offensive name' });
  assert.equal(res.status, 201);
  const row = env.DB.raw.prepare('SELECT * FROM ugc_reports').get();
  assert.equal(row.reporter_id, a.id);
  assert.equal(JSON.parse(row.snapshot).display_name, 'Reported');
  assert.equal((await call(env, a, 'POST', 'reports', { target_type: 'planet', target_id: 'x', reason: 'r' })).body.error, 'target_type_invalid');
  assert.equal((await call(env, a, 'POST', 'reports', { target_type: 'user', target_id: b.id, reason: '' })).body.error, 'reason_invalid');
  assert.equal((await call(env, a, 'POST', 'reports', { target_type: 'user', reason: 'x' })).body.error, 'target_id_invalid');
  let last;
  for (let i = 0; i < 20; i += 1) {
    last = await call(env, a, 'POST', 'reports', { target_type: 'comment', target_id: `c${i}`, reason: 'spam' });
  }
  assert.equal(last.status, 429);
});

test('friends: unknown ids are a 404 (not a 500), private previews are masked, 50 requests/day', async () => {
  const env = makeEnv();
  const a = createUser(env);
  const priv = createUser(env, { name: 'Secret Name', isPublic: 0 });
  assert.equal((await call(env, a, 'POST', 'friends/request', { user_id: 'no-such-user' })).status, 404);
  assert.equal((await call(env, a, 'POST', 'friends/request', { user_id: priv.id })).status, 200);
  const out = (await call(env, a, 'GET', 'friends')).body.outgoing_requests;
  assert.equal(out.length, 1);
  assert.equal(out[0].display_name, 'Pending request');
  // The recipient sees the requester normally.
  assert.equal((await call(env, priv, 'GET', 'friends')).body.incoming_requests.length, 1);
  let last;
  for (let i = 0; i < 50; i += 1) last = await call(env, a, 'POST', 'friends/request', { email: `nobody${i}@example.com` });
  assert.equal(last.status, 429);
});

test('friends leaderboard and feed work with 120 friends (no IN() over 100 binds)', async () => {
  const env = makeEnv();
  const me = createUser(env);
  for (let i = 0; i < 120; i += 1) {
    const f = createUser(env, { name: `Friend ${i}`, xp: i * 10 });
    befriend(env, me, f);
    post(env, f, `p${i}`, clock.now - i);
  }
  const board = await call(env, me, 'GET', 'leaderboard', undefined, { query: 'scope=friends&metric=xp' });
  assert.equal(board.status, 200);
  assert.equal(board.body.entries.length, 100);
  assert.equal(board.body.entries[0].display_name, 'Friend 119');
  const feed = await call(env, me, 'GET', 'feed');
  assert.equal(feed.status, 200);
  assert.equal(feed.body.items.length, 50);
  const sync = await call(env, me, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 100]]]])] });
  assert.equal(sync.status, 200);
});

test('leaderboard: private players off the global board; `you` ranks outside the top 100', async () => {
  const env = makeEnv();
  const me = createUser(env, { name: 'Me', xp: 5 });
  const priv = createUser(env, { name: 'Hidden', xp: 99999, isPublic: 0 });
  for (let i = 0; i < 105; i += 1) createUser(env, { name: `P${i}`, xp: 100 + i });
  const res = await call(env, me, 'GET', 'leaderboard');
  assert.equal(res.body.entries.length, 100);
  assert.ok(!res.body.entries.some((e) => e.user_id === priv.id));
  assert.equal(res.body.you.rank, 106);
  assert.equal(res.body.you.is_self, true);
  assert.equal((await call(env, me, 'GET', 'leaderboard', undefined, { query: 'metric=nope' })).status, 400);
});

await run();
