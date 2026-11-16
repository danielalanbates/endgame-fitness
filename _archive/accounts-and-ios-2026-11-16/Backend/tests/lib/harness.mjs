/**
 * Integration harness: the real fitness worker (functions/api/fitness/[[path]].js)
 * driven with Request objects against schema.sql + every migration loaded
 * into node:sqlite through the D1 adapter.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * The clock is controllable: the worker and the rate limiter read
 * Date.now(), which the harness pins to `clock.now` (epoch seconds).
 */

import { createHash, randomUUID } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { readdirSync } from 'node:fs';
import { D1Database, applySqlFile, applyStatements } from './d1.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const backend = join(here, '..', '..');

export const clock = { now: Date.UTC(2026, 9, 27, 18, 0, 0) / 1000 }; // Tue 2026-10-27 18:00Z
const realNow = Date.now;
Date.now = () => clock.now * 1000;
export const restoreClock = () => { Date.now = realNow; };

const worker = await import(pathToFileURL(join(backend, 'functions', 'api', 'fitness', '[[path]].js')).href);

export function freshDatabase() {
  const db = new D1Database();
  applySqlFile(db, join(backend, 'schema.sql'));
  const dir = join(backend, 'migrations');
  for (const f of readdirSync(dir).filter((n) => n.endsWith('.sql')).sort()) applyStatements(db, join(dir, f));
  return db;
}

export function makeEnv(extra = {}) {
  return { DB: freshDatabase(), ...extra };
}

const sha256 = (s) => createHash('sha256').update(s).digest('hex');

/**
 * Create a membership user (users + sessions rows, as the auth worker does).
 * `profile: false` skips the fitness row so lazy creation can be tested.
 */
export function createUser(env, { name = 'Player', email, profile = true, isPublic = 1, level = 1, xp = 0 } = {}) {
  const id = randomUUID();
  const token = randomUUID();
  const t = clock.now;
  const raw = env.DB.raw;
  raw.prepare('INSERT INTO users (id, email, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)')
    .run(id, email || `${id}@example.com`, name, t, t);
  raw.prepare('INSERT INTO sessions (id, user_id, token_hash, expires_at) VALUES (?, ?, ?, ?)')
    .run(randomUUID(), id, sha256(token), t + 86400 * 365);
  if (profile) {
    raw.prepare(
      `INSERT INTO fitness_profiles (user_id, display_name, is_public, level, xp, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    ).run(id, name, isPublic, level, xp, t, t);
  }
  return { id, token, name };
}

/** Call the worker. Returns { status, body, headers }. */
export async function call(env, user, method, path, body, { query = '', headers = {} } = {}) {
  const url = `https://batesai.org/api/fitness/${path}${query ? `?${query}` : ''}`;
  const init = { method, headers: { ...headers } };
  if (user) init.headers.Authorization = `Bearer ${user.token}`;
  if (body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
    init.headers['Content-Type'] = 'application/json';
  }
  const request = new Request(url, init);
  const segments = path.split('/').filter(Boolean);
  const response = await worker.onRequest({ request, env, params: { path: segments } });
  const text = await response.text();
  let parsed = null;
  try { parsed = text ? JSON.parse(text) : null; } catch { parsed = text; }
  return { status: response.status, body: parsed, headers: response.headers };
}

/** A tiny test runner: async tests in order, failures reported, exit code set. */
export function runner(title) {
  const tests = [];
  const test = (name, fn) => tests.push({ name, fn });
  const run = async () => {
    console.log(title);
    let passed = 0;
    for (const { name, fn } of tests) {
      try {
        await fn();
        passed += 1;
        console.log(`  ok   ${name}`);
      } catch (e) {
        console.log(`  FAIL ${name}\n       ${e && e.stack ? e.stack.split('\n').slice(0, 6).join('\n       ') : e}`);
        process.exitCode = 1;
      }
    }
    console.log(`\n${passed}/${tests.length} passed`);
    restoreClock();
  };
  return { test, run };
}

/** A payload v2 session. exercises: [[name, [[reps, weight], ...], extra?], ...] */
export function session(exercises, { id = randomUUID(), at = clock.now - 60, rev = 1, duration = 3600, name = 'Workout', ...rest } = {}) {
  return {
    id,
    performed_at: at,
    name,
    duration_secs: duration,
    client_rev: rev,
    total_volume: 0,
    total_reps: 0,
    payload: {
      v: 2,
      exercises: exercises.map(([exName, sets, extra = {}]) => ({
        name: exName,
        ...extra,
        sets: sets.map(([reps, weight]) => ({ reps, weight })),
      })),
    },
    ...rest,
  };
}
