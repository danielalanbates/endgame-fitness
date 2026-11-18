/**
 * The auth worker's account deletion (DELETE /api/auth/account) still works
 * against the v2 schema: every table the fitness API added cascades from
 * users, so a member with comments, blocks, unlocks, season progress and
 * reports can delete their account and leaves nothing personal behind.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * Run: node App/Backend/tests/account-delete.test.mjs
 */

import assert from 'node:assert/strict';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { clock, makeEnv, createUser, call, runner, session } from './lib/harness.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const auth = await import(pathToFileURL(join(here, '..', 'functions', 'api', 'auth', '[[path]].js')).href);
const { test, run } = runner('account deletion with the v2 schema');

// Website tables the auth worker's explicit delete list names; they live in
// the shared batesai.org database, not in this app's schema.
const WEBSITE_TABLES = ['subscriptions', 'programs', 'meso_cycles', 'progress_metrics', 'talent_unlocks',
  'dm_sync', 'sm_progress', 'sm_profile', 'sm_plan'];

test('DELETE /api/auth/account removes the member from every v2 table', async () => {
  const env = makeEnv();
  for (const t of WEBSITE_TABLES) env.DB.raw.exec(`CREATE TABLE IF NOT EXISTS ${t} (user_id TEXT)`);
  const me = createUser(env, { name: 'Leaving' });
  const friend = createUser(env, { name: 'Staying' });
  const [low, high] = me.id < friend.id ? [me.id, friend.id] : [friend.id, me.id];
  env.DB.raw.prepare("INSERT INTO friendships VALUES (?, ?, ?, 'accepted', 1, 1)").run(low, high, me.id);

  clock.now += 3600;
  await call(env, me, 'POST', 'sync', { since: 0, sessions: [session([['Squat', [[5, 100]]]])] });
  const g = await call(env, me, 'POST', 'guild', { name: 'Short Lived' });
  await call(env, friend, 'POST', 'guild/join', { guild_id: g.body.guild_id });
  const friendPost = env.DB.raw.prepare('SELECT id FROM activity_feed WHERE user_id = ? LIMIT 1').get(me.id);
  await call(env, friend, 'POST', `feed/${friendPost.id}/comments`, { text: 'nice' });
  env.DB.raw.prepare('INSERT INTO activity_feed (id, user_id, kind, summary, created_at) VALUES (?, ?, ?, ?, ?)')
    .run('friend-post', friend.id, 'workout', 'x', clock.now);
  await call(env, me, 'POST', 'feed/friend-post/comments', { text: 'from me' });
  await call(env, me, 'POST', 'feed/friend-post/react', { emoji: '🔥' });
  await call(env, me, 'POST', 'reports', { target_type: 'user', target_id: friend.id, reason: 'test' });
  const third = createUser(env);
  await call(env, me, 'POST', 'blocks', { user_id: third.id });
  env.DB.raw.prepare("INSERT INTO season_progress VALUES (?, 's1', 10, 1)").run(me.id);
  env.DB.raw.prepare("INSERT INTO season_claims VALUES (?, 's1', 1, 1)").run(me.id);

  const request = new Request('https://batesai.org/api/auth/account', {
    method: 'DELETE', headers: { Authorization: `Bearer ${me.token}` },
  });
  const res = await auth.onRequest({ request, env, params: { path: ['account'] } });
  assert.equal(res.status, 200, await res.clone().text());

  const count = (sql) => env.DB.raw.prepare(sql).get(me.id).n;
  for (const [table, col] of [['users', 'id'], ['fitness_profiles', 'user_id'], ['workout_sessions', 'user_id'],
    ['fitness_unlocks', 'user_id'], ['season_progress', 'user_id'], ['season_claims', 'user_id'],
    ['activity_comments', 'user_id'], ['activity_reactions', 'user_id'], ['user_blocks', 'blocker_id'],
    ['guild_members', 'user_id'], ['personal_records', 'user_id'], ['xp_transactions', 'user_id']]) {
    assert.equal(count(`SELECT COUNT(*) AS n FROM ${table} WHERE ${col} = ?`), 0, table);
  }
  // Their report survives for review, without the reporter.
  assert.equal(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM ugc_reports WHERE reporter_id IS NULL').get().n, 1);
  // The guild passed to the remaining member.
  assert.equal(env.DB.raw.prepare('SELECT owner_id FROM guilds').get().owner_id, friend.id);
  // The friend's own comment went with the deleted member's post.
  assert.equal(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM activity_comments').get().n, 0);
});

await run();
