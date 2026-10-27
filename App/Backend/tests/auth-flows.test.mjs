/**
 * Auth v2 flow tests (Docs/API_V2.md §1): native handoff codes, PBKDF2
 * passwords with legacy rehash, rate limits, the account pre-hijack rule,
 * identity linking and account deletion.
 *
 * Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
 * https://batesai.org · help@batesai.org
 *
 * No network. D1 is emulated with node:sqlite running the real schema.sql and
 * migrations; Google/Apple are emulated with locally generated RSA keys served
 * as their JWKS; functions/membership.js reaches the auth worker through a
 * fetch stub, exactly as its same-origin subrequest does in production.
 *
 * Run: node App/Backend/tests/auth-flows.test.mjs
 */

import { DatabaseSync } from 'node:sqlite';
import { cpSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const backend = join(here, '..');

// Load the workers from a scratch copy of functions/ marked as ESM, so module
// type detection never depends on what sits above this repo on disk.
const scratch = mkdtempSync(join(tmpdir(), 'auth-flows-'));
cpSync(join(backend, 'functions'), join(scratch, 'functions'), { recursive: true });
writeFileSync(join(scratch, 'package.json'), '{"type":"module"}');
const auth = await import(pathToFileURL(join(scratch, 'functions', 'api', 'auth', '[[path]].js')).href);
const membership = await import(pathToFileURL(join(scratch, 'functions', 'membership.js')).href);

/* ------------------------------------------------------------------ */
/* D1 on node:sqlite                                                   */
/* ------------------------------------------------------------------ */

function makeD1(db) {
  const norm = (args) => args.map((v) => {
    // D1 rejects undefined binds; mirror that so a missing value fails here too.
    if (v === undefined) throw new Error("D1_TYPE_ERROR: Type 'undefined' not supported");
    if (typeof v === 'boolean') return v ? 1 : 0;
    return v;
  });
  class Statement {
    constructor(sql, args = []) { this.sql = sql; this.args = args; }
    bind(...args) { return new Statement(this.sql, norm(args)); }
    rows() { return db.prepare(this.sql).all(...this.args).map((r) => ({ ...r })); }
    exec() {
      if (/\breturning\b/i.test(this.sql)) {
        const results = this.rows();
        return { success: true, results, meta: { changes: results.length } };
      }
      const info = db.prepare(this.sql).run(...this.args);
      return { success: true, results: [], meta: { changes: Number(info.changes) } };
    }
    async first(column) {
      const row = db.prepare(this.sql).get(...this.args);
      if (!row) return null;
      return column ? (row[column] ?? null) : { ...row };
    }
    async all() { return { success: true, results: this.rows() }; }
    async run() { return this.exec(); }
  }
  return {
    prepare: (sql) => new Statement(sql),
    async batch(statements) {
      db.exec('BEGIN');
      try {
        const out = statements.map((s) => s.exec());
        db.exec('COMMIT');
        return out;
      } catch (e) {
        db.exec('ROLLBACK');
        throw e;
      }
    },
  };
}

const sqlite = new DatabaseSync(':memory:');
sqlite.exec('PRAGMA foreign_keys = ON'); // D1 enforces foreign keys
// schema.sql documents the friend_code column as a hand-applied ALTER (live D1
// has it) but leaves the statement commented out, so a fresh database needs it
// run explicitly before the index that references it.
sqlite.exec(readFileSync(join(backend, 'schema.sql'), 'utf8')
  .replace('-- ALTER TABLE fitness_profiles ADD COLUMN friend_code TEXT;',
    'ALTER TABLE fitness_profiles ADD COLUMN friend_code TEXT;'));
const migrations = readdirSync(join(backend, 'migrations')).filter((f) => f.endsWith('.sql')).sort();
for (let pass = 0; pass < 2; pass++) {
  // Twice: deploy.sh re-runs every migration on each deploy.
  for (const file of migrations) sqlite.exec(readFileSync(join(backend, 'migrations', file), 'utf8'));
}
const DB = makeD1(sqlite);
const q = (sql, ...args) => sqlite.prepare(sql).all(...args).map((r) => ({ ...r }));
const q1 = (sql, ...args) => q(sql, ...args)[0] || null;

/* ------------------------------------------------------------------ */
/* Fake Google + Apple                                                 */
/* ------------------------------------------------------------------ */

const ORIGIN = 'https://batesai.org';
const GOOGLE_CLIENT = 'test-client.apps.googleusercontent.com';
const env = { DB, OAUTH_GOOGLE_CLIENT_ID: GOOGLE_CLIENT, OAUTH_GOOGLE_CLIENT_SECRET: 'test-secret' };

const rsa = { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' };
const googleKey = await crypto.subtle.generateKey(rsa, true, ['sign', 'verify']);
const appleKey = await crypto.subtle.generateKey(rsa, true, ['sign', 'verify']);
const jwkOf = async (pair, kid) => ({ ...(await crypto.subtle.exportKey('jwk', pair.publicKey)), kid, alg: 'RS256' });
const googleJwk = await jwkOf(googleKey, 'google-test');
const appleJwk = await jwkOf(appleKey, 'apple-test');

const b64u = (s) => Buffer.from(s).toString('base64url');
async function mint(pair, kid, claims) {
  const h = b64u(JSON.stringify({ alg: 'RS256', kid }));
  const p = b64u(JSON.stringify(claims));
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(`${h}.${p}`));
  return `${h}.${p}.${Buffer.from(sig).toString('base64url')}`;
}
const nowS = () => Math.floor(Date.now() / 1000);
const googleToken = (sub, email, extra = {}) => mint(googleKey, 'google-test', {
  iss: 'https://accounts.google.com', aud: GOOGLE_CLIENT, sub, email, email_verified: true,
  name: 'Test Lifter', exp: nowS() + 3600, iat: nowS(), ...extra,
});
const appleToken = (sub, email, extra = {}) => mint(appleKey, 'apple-test', {
  iss: 'https://appleid.apple.com', aud: 'org.batesai.membership', sub,
  ...(email ? { email, email_verified: 'true' } : {}), exp: nowS() + 3600, iat: nowS(), ...extra,
});

// Google authorization codes the fake token endpoint will redeem (single use).
const googleCodes = new Map();

async function callAuth(request) {
  const path = new URL(request.url).pathname.replace(/^\/api\/auth\/?/, '').split('/').filter(Boolean);
  return auth.onRequest({ request, env, params: { path } });
}

globalThis.fetch = async (input, init) => {
  const req = input instanceof Request ? input : new Request(input, init);
  const url = new URL(req.url);
  if (url.href === 'https://www.googleapis.com/oauth2/v3/certs') return Response.json({ keys: [googleJwk] });
  if (url.href === 'https://appleid.apple.com/auth/keys') return Response.json({ keys: [appleJwk] });
  if (url.href === 'https://oauth2.googleapis.com/token') {
    const code = new URLSearchParams(await req.text()).get('code');
    const idToken = googleCodes.get(code);
    googleCodes.delete(code);
    return idToken ? Response.json({ id_token: idToken }) : Response.json({ error: 'invalid_grant' }, { status: 400 });
  }
  if (url.origin === ORIGIN && url.pathname.startsWith('/api/auth/')) return callAuth(req);
  throw new Error(`unexpected fetch: ${url.href}`);
};

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

let ipSeq = 0;
const freshIp = () => `198.51.100.${(ipSeq++ % 250) + 1}`;

async function api(method, path, { body, token, cookie, ip } = {}) {
  const headers = { 'CF-Connecting-IP': ip || freshIp() };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  if (cookie) headers.Cookie = cookie;
  const res = await callAuth(new Request(`${ORIGIN}/api/auth/${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }));
  const text = await res.text();
  let data = null;
  try { data = JSON.parse(text); } catch { /* redirect or empty */ }
  return { status: res.status, data, headers: res.headers };
}

/** Set-Cookie list -> { name: { value, raw } } */
function cookiesOf(headers) {
  const out = {};
  for (const raw of headers.getSetCookie()) {
    const [pair] = raw.split(';');
    const i = pair.indexOf('=');
    out[pair.slice(0, i)] = { value: pair.slice(i + 1), raw };
  }
  return out;
}
const jar = (obj) => Object.entries(obj).map(([k, v]) => `${k}=${v}`).join('; ');

async function startOAuth(provider, query) {
  const res = await callAuth(new Request(`${ORIGIN}/api/auth/oauth/${provider}${query}`, { method: 'GET' }));
  return { status: res.status, location: res.headers.get('Location'), cookies: cookiesOf(res.headers) };
}

function membershipGet(query, cookie) {
  const request = new Request(`${ORIGIN}/membership${query}`, { headers: cookie ? { Cookie: cookie } : {} });
  return membership.onRequestGet({ request, env, next: () => new Response('static page') });
}

function membershipPost(form, cookie) {
  const request = new Request(`${ORIGIN}/membership`, {
    method: 'POST', headers: cookie ? { Cookie: cookie } : {}, body: new URLSearchParams(form),
  });
  return membership.onRequestPost({ request, env });
}

const sha256Hex = async (s) => Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))).toString('hex');
const userByEmail = (email) => q1('SELECT * FROM users WHERE email = ?', email);

let passed = 0;
let failed = 0;
function check(name, condition, detail) {
  if (condition) {
    passed += 1;
    console.log(`  ✓ ${name}`);
  } else {
    failed += 1;
    console.error(`  ✗ ${name}${detail === undefined ? '' : ` — ${JSON.stringify(detail)}`}`);
  }
}

/* ------------------------------------------------------------------ */
/* Migration                                                           */
/* ------------------------------------------------------------------ */

console.log('Migration\n');
check('auth-v2 migration is idempotent (applied twice above) and creates both tables',
  q("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('user_identities','auth_handoff_codes')").length === 2);

/* ------------------------------------------------------------------ */
/* Passwords                                                           */
/* ------------------------------------------------------------------ */

console.log('\nPasswords (PBKDF2 + legacy rehash)\n');
{
  const reg = await api('POST', 'register', { body: { email: 'Alice@Example.com ', password: 'correct horse', name: 'Alice' } });
  check('register succeeds', reg.status === 201 && reg.data.token, reg);
  const row = userByEmail('alice@example.com');
  const parts = (row?.password_hash || '').split('$');
  check('new hash is pbkdf2$100000$salt$hash', parts[0] === 'pbkdf2' && parts[1] === '100000' && parts.length === 4, row?.password_hash);
  check('16-byte salt, 32-byte hash', Buffer.from(parts[2] || '', 'base64').length === 16 && Buffer.from(parts[3] || '', 'base64').length === 32);
  check('login with the right password', (await api('POST', 'login', { body: { email: 'alice@example.com', password: 'correct horse' } })).status === 200);
  check('login with the wrong password is 401', (await api('POST', 'login', { body: { email: 'alice@example.com', password: 'wrong horse' } })).status === 401);
  check('a non-string password is 400', (await api('POST', 'login', { body: { email: 'alice@example.com', password: 12345678 } })).status === 400);

  const profile = q1('SELECT display_name, is_public FROM fitness_profiles WHERE user_id = ?', row.id);
  check('a new fitness profile starts private', profile && profile.is_public === 0, profile);

  // Legacy salted SHA-256: $sha256$<salt>$<hex(sha256(password + salt))>
  const salt = 'a1b2c3d4e5f60718';
  const legacy = `$sha256$${salt}$${await sha256Hex(`old password${salt}`)}`;
  sqlite.prepare('INSERT INTO users (id, email, password_hash, name, created_at, updated_at) VALUES (?, ?, ?, ?, 1, 1)')
    .run('legacy-1', 'legacy@example.com', legacy, 'Legacy');
  check('wrong password against a legacy hash is 401',
    (await api('POST', 'login', { body: { email: 'legacy@example.com', password: 'nope nope' } })).status === 401);
  check('a failed login does not rehash', userByEmail('legacy@example.com').password_hash === legacy);
  check('legacy salted hash still logs in',
    (await api('POST', 'login', { body: { email: 'legacy@example.com', password: 'old password' } })).status === 200);
  check('…and is transparently rehashed to PBKDF2', userByEmail('legacy@example.com').password_hash.startsWith('pbkdf2$100000$'));
  check('…and the rehashed password still works',
    (await api('POST', 'login', { body: { email: 'legacy@example.com', password: 'old password' } })).status === 200);

  sqlite.prepare('INSERT INTO users (id, email, password_hash, name, created_at, updated_at) VALUES (?, ?, ?, ?, 1, 1)')
    .run('legacy-2', 'oldest@example.com', await sha256Hex('ancient pass'), 'Oldest');
  check('unsalted legacy hash logs in',
    (await api('POST', 'login', { body: { email: 'oldest@example.com', password: 'ancient pass' } })).status === 200);
  check('…and is rehashed', userByEmail('oldest@example.com').password_hash.startsWith('pbkdf2$'));

  // A cheaper PBKDF2 cost is upgraded on the next login at the default cost.
  const cheapEnv = { ...env, PBKDF2_ITERATIONS: '20000' };
  const cheap = await auth.onRequest({
    request: new Request(`${ORIGIN}/api/auth/register`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': freshIp() },
      body: JSON.stringify({ email: 'cheap@example.com', password: 'cheap password' }),
    }),
    env: cheapEnv, params: { path: ['register'] },
  });
  check('PBKDF2_ITERATIONS lowers the cost of new hashes', cheap.status === 201 && userByEmail('cheap@example.com').password_hash.startsWith('pbkdf2$20000$'));
  await api('POST', 'login', { body: { email: 'cheap@example.com', password: 'cheap password' } });
  check('…and a login at the default cost upgrades it', userByEmail('cheap@example.com').password_hash.startsWith('pbkdf2$100000$'));

  check('register rejects a short password', (await api('POST', 'register', { body: { email: 'b@example.com', password: 'short' } })).status === 400);
  check('register rejects an over-long password', (await api('POST', 'register', { body: { email: 'b@example.com', password: 'x'.repeat(257) } })).status === 400);
  check('register rejects a malformed email', (await api('POST', 'register', { body: { email: 'not-an-email', password: 'long enough' } })).status === 400);
  check('register refuses the provider placeholder domains',
    (await api('POST', 'register', { body: { email: '000123.abc@apple.local', password: 'long enough' } })).status === 400);
  check('register refuses a duplicate email (409)',
    (await api('POST', 'register', { body: { email: 'alice@example.com', password: 'another one' } })).status === 409);
}

/* ------------------------------------------------------------------ */
/* Handoff codes                                                       */
/* ------------------------------------------------------------------ */

console.log('\nHandoff codes (POST /api/auth/handoff)\n');
{
  const user = userByEmail('alice@example.com');
  const code = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
  sqlite.prepare('INSERT INTO auth_handoff_codes (code_hash, user_id, scheme, created_at, expires_at) VALUES (?, ?, ?, ?, ?)')
    .run(await sha256Hex(code), user.id, 'endgamefitness', nowS(), nowS() + 120);

  const first = await api('POST', 'handoff', { body: { code } });
  check('a fresh code redeems for {success, token, user}', first.status === 200 && first.data.success === true
    && typeof first.data.token === 'string' && first.data.user?.id === user.id, first);
  check('the token it returns is a working session',
    (await api('GET', 'verify', { token: first.data.token })).data?.user?.id === user.id);
  const second = await api('POST', 'handoff', { body: { code } });
  check('a second redemption is 400 code_used', second.status === 400 && second.data.error === 'code_used', second);

  const stale = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
  sqlite.prepare('INSERT INTO auth_handoff_codes (code_hash, user_id, scheme, created_at, expires_at) VALUES (?, ?, ?, ?, ?)')
    .run(await sha256Hex(stale), user.id, 'endgamefitness', nowS() - 200, nowS() - 80);
  const expired = await api('POST', 'handoff', { body: { code: stale } });
  check('an expired code is 400 code_expired', expired.status === 400 && expired.data.error === 'code_expired', expired);

  const unknown = await api('POST', 'handoff', { body: { code: 'A'.repeat(43) } });
  check('an unknown code is 400 invalid_code', unknown.status === 400 && unknown.data.error === 'invalid_code', unknown);
  const junk = await api('POST', 'handoff', { body: { code: 'short' } });
  check('a malformed code is 400 invalid_code', junk.status === 400 && junk.data.error === 'invalid_code', junk);
  check('GET /handoff is 405', (await api('GET', 'handoff')).status === 405);
}

/* ------------------------------------------------------------------ */
/* Native Google sign-in through /membership                           */
/* ------------------------------------------------------------------ */

console.log('\nNative Google sign-in (redirect_scheme -> /membership -> handoff)\n');
{
  const start = await startOAuth('google', '?redirect_scheme=endgamefitness');
  const appCookie = start.cookies.oauth_app_scheme;
  check('start redirects to Google with /membership as redirect_uri',
    start.status === 302 && start.location.includes(encodeURIComponent(`${ORIGIN}/membership`)));
  check('start sets oauth_app_scheme (Max-Age 300, Lax, Secure, HttpOnly)',
    appCookie?.value === 'endgamefitness' && /Max-Age=300/.test(appCookie.raw) && /SameSite=Lax/.test(appCookie.raw)
    && /Secure/.test(appCookie.raw) && /HttpOnly/.test(appCookie.raw), appCookie);
  const evil = await startOAuth('google', '?redirect_scheme=evilapp');
  check('a scheme off the allow-list is ignored', !evil.cookies.oauth_app_scheme);

  const state = start.cookies.google_oauth_state.value;
  const cookie = jar({ google_oauth_state: state, oauth_app_scheme: 'endgamefitness' });
  googleCodes.set('g-code-1', await googleToken('google-sub-1', 'dana@example.com'));
  const cb = await membershipGet(`?code=g-code-1&state=${state}`, cookie);
  const location = cb.headers.get('Location') || '';
  const match = location.match(/^endgamefitness:\/\/auth\?code=([A-Za-z0-9_-]{43})$/);
  const cbCookies = cookiesOf(cb.headers);
  check('callback 302s to endgamefitness://auth?code=…', cb.status === 302 && !!match, location);
  check('no web session cookie is set on the app path', !cbCookies.batesai_session);
  check('the app-scheme cookie is cleared', cbCookies.oauth_app_scheme && /Max-Age=0/.test(cbCookies.oauth_app_scheme.raw));
  check('the redirect is marked no-store', cb.headers.get('Cache-Control') === 'no-store');

  const dana = userByEmail('dana@example.com');
  check('no session row exists until the app redeems', q1('SELECT COUNT(*) AS n FROM sessions WHERE user_id = ?', dana.id).n === 0);
  const stored = q1('SELECT * FROM auth_handoff_codes WHERE user_id = ?', dana.id);
  check('only the SHA-256 of the code is stored', stored && stored.code_hash === await sha256Hex(match?.[1] || '')
    && !JSON.stringify(q('SELECT * FROM auth_handoff_codes')).includes(match?.[1] || '#'));
  check('the code lives 120 seconds', stored && stored.expires_at - stored.created_at === 120, stored);

  const redeemed = await api('POST', 'handoff', { body: { code: match?.[1] } });
  check('the app redeems it for a session', redeemed.status === 200 && redeemed.data.user?.email === 'dana@example.com', redeemed);
  check('…exactly once', (await api('POST', 'handoff', { body: { code: match?.[1] } })).data?.error === 'code_used');

  // Web behaviour without the cookie is unchanged.
  googleCodes.set('g-code-2', await googleToken('google-sub-1', 'dana@example.com'));
  const web = await membershipGet(`?code=g-code-2&state=${state}`, jar({ google_oauth_state: state }));
  check('without the cookie: 302 /membership/?signed_in=1', web.status === 302 && web.headers.get('Location') === `${ORIGIN}/membership/?signed_in=1`);
  check('…with the batesai_session cookie', !!cookiesOf(web.headers).batesai_session?.value);

  googleCodes.set('g-code-3', await googleToken('google-sub-1', 'dana@example.com'));
  const back = await membershipGet(`?code=g-code-3&state=${state}`, jar({ google_oauth_state: state, oauth_return_to: '/fitness/' }));
  check('with return_to=/fitness/: lands on /fitness/?signed_in=1', back.headers.get('Location') === `${ORIGIN}/fitness/?signed_in=1`);

  const denied = await membershipGet('?error=access_denied', jar({ oauth_app_scheme: 'endgamefitness' }));
  check('a refused consent screen goes back to the app as an error',
    denied.headers.get('Location') === 'endgamefitness://auth?error=access_denied');
  const replay = await membershipGet(`?code=spent&state=${state}`, jar({ google_oauth_state: state, oauth_app_scheme: 'endgamefitness' }));
  check('a spent Google code reaches the app as code_replayed',
    replay.headers.get('Location') === 'endgamefitness://auth?error=code_replayed');
  const planted = await membershipGet('?error=access_denied', jar({ oauth_app_scheme: 'javascript' }));
  check('a planted, unlisted scheme cookie is never redirected to', !String(planted.headers.get('Location')).startsWith('javascript'));

  const plain = await callAuth(new Request(`${ORIGIN}/api/auth/oauth/google`, { headers: { Cookie: 'oauth_app_scheme=endgamefitness' } }));
  const plainCookie = cookiesOf(plain.headers).oauth_app_scheme;
  check('a plain web sign-in clears a leftover app-scheme cookie', plainCookie && /Max-Age=0/.test(plainCookie.raw));
}

/* ------------------------------------------------------------------ */
/* Apple on the web (form_post)                                        */
/* ------------------------------------------------------------------ */

console.log('\nSign in with Apple on the web (form_post)\n');
{
  const start = await startOAuth('apple', '?redirect_scheme=endgamefitness');
  check('apple start sets oauth_app_scheme with SameSite=None (cross-site POST back)',
    start.cookies.oauth_app_scheme?.value === 'endgamefitness' && /SameSite=None/.test(start.cookies.oauth_app_scheme.raw));
  const pwa = await startOAuth('apple', '?return_to=/fitness/');
  check('apple start honours return_to with a SameSite=None cookie',
    pwa.cookies.oauth_return_to?.value === '/fitness/' && /SameSite=None/.test(pwa.cookies.oauth_return_to.raw));
  const bad = await startOAuth('apple', '?return_to=//evil.example/');
  check('an unsafe return_to is ignored', !bad.cookies.oauth_return_to);

  const state = start.cookies.apple_oauth_state.value;
  const idToken = await appleToken('apple-sub-1', 'erin@example.com');
  const appRes = await membershipPost({ id_token: idToken, state }, jar({ apple_oauth_state: state, oauth_app_scheme: 'endgamefitness' }));
  const m = (appRes.headers.get('Location') || '').match(/^endgamefitness:\/\/auth\?code=([A-Za-z0-9_-]{43})$/);
  check('form_post with the app cookie 302s to endgamefitness://auth?code=…', !!m, appRes.headers.get('Location'));
  const redeemed = await api('POST', 'handoff', { body: { code: m?.[1] } });
  check('…and the code redeems for the Apple member', redeemed.status === 200 && redeemed.data.user?.email === 'erin@example.com');

  const web = await membershipPost({ id_token: await appleToken('apple-sub-1', 'erin@example.com'), state }, jar({ apple_oauth_state: state }));
  check('without the cookie: /membership/?signed_in=1 plus session cookie',
    web.headers.get('Location') === `${ORIGIN}/membership/?signed_in=1` && !!cookiesOf(web.headers).batesai_session);
  const back = await membershipPost({ id_token: await appleToken('apple-sub-1', 'erin@example.com') }, jar({ oauth_return_to: '/fitness/' }));
  check('with return_to: /fitness/?signed_in=1', back.headers.get('Location') === `${ORIGIN}/fitness/?signed_in=1`);
  const cancelled = await membershipPost({ error: 'user_cancelled_authorize' }, jar({ oauth_return_to: '/fitness/' }));
  check('a cancelled Apple sign-in returns to the PWA with signin_error',
    cancelled.headers.get('Location') === `${ORIGIN}/fitness/?signin_error=access_denied`);
}

/* ------------------------------------------------------------------ */
/* Account pre-hijack + identity linking                               */
/* ------------------------------------------------------------------ */

console.log('\nAccount pre-hijack and identity linking\n');
{
  // A stranger registers the victim's address first.
  const squat = await api('POST', 'register', { body: { email: 'victim@example.com', password: 'stranger pass' } });
  check('a stranger can register an unclaimed address', squat.status === 201);
  const victimId = squat.data.user.id;

  // The real owner arrives with a Google-verified email.
  const owner = await api('POST', 'native/google', { body: { id_token: await googleToken('google-victim', 'victim@example.com') } });
  check('the verified owner signs in to the same membership', owner.status === 200 && owner.data.user.id === victimId);
  check("the stranger's password is cleared", userByEmail('victim@example.com').password_hash === '');
  check("the stranger's session is revoked", (await api('GET', 'verify', { token: squat.data.token })).status === 401);
  check("the stranger's password no longer logs in",
    (await api('POST', 'login', { body: { email: 'victim@example.com', password: 'stranger pass' } })).status === 401);
  check("the owner's new session works", (await api('GET', 'verify', { token: owner.data.token })).status === 200);
  check('the identity is recorded as verified',
    q1('SELECT verified FROM user_identities WHERE provider = ? AND provider_sub = ?', 'google', 'google-victim')?.verified === 1);

  // An unverified provider email never links.
  await api('POST', 'register', { body: { email: 'frank@example.com', password: 'franks pass' } });
  const unverified = await api('POST', 'native/google', {
    body: { id_token: await googleToken('google-frank', 'frank@example.com', { email_verified: false }) },
  });
  check('an unverified provider email is refused with 409 account_exists',
    unverified.status === 409 && unverified.data.code === 'account_exists', unverified);
  check('…the password account is untouched',
    (await api('POST', 'login', { body: { email: 'frank@example.com', password: 'franks pass' } })).status === 200);
  check('…and nothing was linked', !q1('SELECT 1 FROM user_identities WHERE provider_sub = ?', 'google-frank'));

  // A member some provider already verified keeps their password and sessions.
  const hash = userByEmail('alice@example.com').password_hash;
  sqlite.prepare("UPDATE users SET oauth_provider = 'google', oauth_id = 'google-alice' WHERE email = 'alice@example.com'").run();
  const aliceLogin = await api('POST', 'login', { body: { email: 'alice@example.com', password: 'correct horse' } });
  const aliceApple = await api('POST', 'native/apple', { body: { identity_token: await appleToken('apple-alice', 'alice@example.com') } });
  check('a verified member adds Apple to the same membership', aliceApple.status === 200 && aliceApple.data.user.email === 'alice@example.com');
  check('…keeps their password', userByEmail('alice@example.com').password_hash === hash);
  check('…keeps their other sessions', (await api('GET', 'verify', { token: aliceLogin.data.token })).status === 200);
  check('…and the legacy slot is not overwritten', userByEmail('alice@example.com').oauth_provider === 'google');
  const again = await api('POST', 'native/apple', { body: { identity_token: await appleToken('apple-alice', 'rotated@privaterelay.appleid.com') } });
  check('Apple resolves by sub afterwards, even with a different email', again.data?.user?.email === 'alice@example.com', again);

  // Provider with no email: placeholder account, stable across sign-ins, never links.
  const noEmail1 = await api('POST', 'native/apple', { body: { identity_token: await appleToken('apple-quiet', null) } });
  const noEmail2 = await api('POST', 'native/apple', { body: { identity_token: await appleToken('apple-quiet', null) } });
  check('an Apple sign-in without email gets a placeholder account',
    noEmail1.status === 200 && noEmail1.data.user.email === 'apple-quiet@apple.local');
  check('…that the same sub resolves to every time', noEmail2.data?.user?.id === noEmail1.data.user.id);

  // The web callbacks apply the same rule (they used to skip the verified flag).
  await api('POST', 'register', { body: { email: 'gina@example.com', password: 'ginas pass' } });
  const webUnverified = await api('POST', 'oauth/google', {
    body: { id_token: await googleToken('google-gina', 'gina@example.com', { email_verified: false }) },
  });
  check('POST oauth/google refuses to link an unverified email too', webUnverified.status === 409);

  // Legacy rows created before user_identities resolve and get backfilled.
  sqlite.prepare("INSERT INTO users (id, email, password_hash, name, oauth_provider, oauth_id, created_at, updated_at) VALUES ('legacy-g', 'hank@example.com', '', 'Hank', 'google', 'google-hank', 1, 1)").run();
  const hank = await api('POST', 'native/google', { body: { id_token: await googleToken('google-hank', 'hank.new@example.com') } });
  check('a legacy single-slot link still resolves by sub', hank.data?.user?.id === 'legacy-g', hank);
  check('…and is copied into user_identities', !!q1("SELECT 1 FROM user_identities WHERE provider_sub = 'google-hank' AND user_id = 'legacy-g'"));

  const named = await api('POST', 'native/google', {
    body: { id_token: await googleToken('google-ivy', 'ivy@example.com', { name: '  <b>Ivy</b>   Lifts!!!  ' }) },
  });
  const ivyProfile = q1('SELECT display_name, is_public FROM fitness_profiles WHERE user_id = ?', named.data.user.id);
  check('starter display names are held to the profile name rules', ivyProfile?.display_name === 'bIvyb Lifts' && ivyProfile.is_public === 0, ivyProfile);
}

/* ------------------------------------------------------------------ */
/* Logout                                                              */
/* ------------------------------------------------------------------ */

console.log('\nLogout\n');
{
  const creds = { email: 'legacy@example.com', password: 'old password' };
  const bearer = (await api('POST', 'login', { body: creds })).data.token;
  const cookie = (await api('POST', 'login', { body: creds })).data.token;
  const out = await api('POST', 'logout', { token: bearer, cookie: `batesai_session=${cookie}` });
  check('logout ends the Bearer session', (await api('GET', 'verify', { token: bearer })).status === 401);
  check('…and the cookie session sent alongside it', (await api('GET', 'verify', { cookie: `batesai_session=${cookie}` })).status === 401);
  check('…and clears the cookie', /Max-Age=0/.test(cookiesOf(out.headers).batesai_session?.raw || ''));
}

/* ------------------------------------------------------------------ */
/* Rate limits                                                         */
/* ------------------------------------------------------------------ */

console.log('\nRate limits\n');
{
  // Freeze the clock mid-window so a test run can never straddle a window edge.
  const realNow = Date.now;
  const frozen = (Math.floor(realNow() / 3600000) * 3600 + 2250) * 1000;
  Date.now = () => frozen;
  try {
    let last;
    for (let i = 0; i < 11; i++) {
      last = await api('POST', 'login', { body: { email: 'target@example.com', password: `guess ${i}` } });
    }
    check('the 11th login for one email in 15 min is 429 rate_limited', last.status === 429 && last.data.error === 'rate_limited', last);
    check('…with retry_after and a Retry-After header', last.data.retry_after > 0 && last.headers.get('Retry-After') === String(last.data.retry_after));
    check('emails are hashed in bucket names', !q('SELECT bucket FROM rate_limits').some((r) => r.bucket.includes('@')));

    for (let i = 0; i < 30; i++) {
      last = await api('POST', 'login', { body: { email: `spray${i}@example.com`, password: 'whatever1' }, ip: '192.0.2.10' });
    }
    check('30 logins from one IP are allowed', last.status === 401, last);
    last = await api('POST', 'login', { body: { email: 'spray-final@example.com', password: 'whatever1' }, ip: '192.0.2.10' });
    check('the 31st login from one IP is 429', last.status === 429, last);

    for (let i = 0; i < 6; i++) {
      last = await api('POST', 'register', { body: { email: `farm${i}@example.com`, password: 'long enough' }, ip: '192.0.2.20' });
    }
    check('the 6th registration from one IP in an hour is 429', last.status === 429, last);
    check('…and it created nothing', !userByEmail('farm5@example.com'));

    for (let i = 0; i < 21; i++) {
      last = await api('POST', 'handoff', { body: { code: 'B'.repeat(43) }, ip: '192.0.2.30' });
    }
    check('the 21st handoff attempt from one IP is 429', last.status === 429, last);
  } finally {
    Date.now = realNow;
  }
}

/* ------------------------------------------------------------------ */
/* Account deletion                                                    */
/* ------------------------------------------------------------------ */

console.log('\nAccount deletion\n');
{
  const reg = await api('POST', 'register', { body: { email: 'leaving@example.com', password: 'goodbye pass' } });
  const id = reg.data.user.id;
  await api('POST', 'login', { body: { email: 'leaving@example.com', password: 'wrong guess' } }); // rate-limit row
  sqlite.prepare("INSERT INTO user_identities (provider, provider_sub, user_id, email, verified, created_at) VALUES ('google', 'google-leaving', ?, 'leaving@example.com', 1, 1)").run(id);
  sqlite.prepare("INSERT INTO auth_handoff_codes (code_hash, user_id, scheme, created_at, expires_at) VALUES ('h-leaving', ?, 'endgamefitness', 1, 2)").run(id);
  const bucket = `login:email:${await sha256Hex('leaving@example.com')}`;
  check('setup: an email rate-limit row exists', !!q1('SELECT 1 FROM rate_limits WHERE bucket = ?', bucket));

  const del = await api('DELETE', 'account', { token: reg.data.token });
  check('DELETE /account succeeds even though website-only tables are absent here', del.status === 200 && del.data.deleted === true, del);
  check('the users row is gone', !q1('SELECT 1 FROM users WHERE id = ?', id));
  check('sessions are gone', !q1('SELECT 1 FROM sessions WHERE user_id = ?', id));
  check('user_identities rows are gone', !q1('SELECT 1 FROM user_identities WHERE user_id = ?', id));
  check('auth_handoff_codes rows are gone', !q1('SELECT 1 FROM auth_handoff_codes WHERE user_id = ?', id));
  check('the fitness profile is gone', !q1('SELECT 1 FROM fitness_profiles WHERE user_id = ?', id));
  check("the member's email rate-limit row is gone", !q1('SELECT 1 FROM rate_limits WHERE bucket = ?', bucket));
  check('the deleted token no longer verifies', (await api('GET', 'verify', { token: reg.data.token })).status === 401);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
