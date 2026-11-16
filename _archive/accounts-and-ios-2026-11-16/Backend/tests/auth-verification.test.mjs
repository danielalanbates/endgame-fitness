/**
 * Security tests for provider identity-token verification.
 *
 * Sign in with Apple on a native app is a bearer-token exchange: the device
 * hands us a JWT signed by Apple and we trade it for a BatesAI session. There
 * is no client secret involved, so the ONLY thing preventing anyone from
 * signing in as any user is that we verify the token's signature, issuer,
 * audience and expiry. An earlier revision of the worker base64-decoded the
 * payload without checking the signature; these tests exist so that can never
 * come back.
 *
 * Run: node App/Backend/tests/auth-verification.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync, mkdtempSync, mkdirSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const workerPath = join(here, '..', 'functions', 'api', 'auth', '[[path]].js');

// The worker keeps its helpers module-private. Load the source and re-export the
// two functions under test rather than loosening the production file's surface.
const source = readFileSync(workerPath, 'utf8')
  .replace(/^async function verifyProviderToken/m, 'export async function verifyProviderToken')
  .replace(/^function appleAudiences/m, 'export function appleAudiences');

// Mirror functions/api/auth/ under the scratch dir so the worker's relative
// imports (../../_lib/*.js) still resolve.
const scratch = mkdtempSync(join(tmpdir(), 'auth-test-'));
mkdirSync(join(scratch, 'api', 'auth'), { recursive: true });
cpSync(join(here, '..', 'functions', '_lib'), join(scratch, '_lib'), { recursive: true });
const modulePath = join(scratch, 'api', 'auth', 'auth.mjs');
writeFileSync(modulePath, source);

const { verifyProviderToken } = await import(`file://${modulePath}`);

const enc = new TextEncoder();
const b64u = (buf) => Buffer.from(buf).toString('base64url');

const rsaParams = {
  name: 'RSASSA-PKCS1-v1_5',
  modulusLength: 2048,
  publicExponent: new Uint8Array([1, 0, 1]),
  hash: 'SHA-256',
};

// Stand-in for Apple's signing key, plus an attacker's unrelated key.
const legit = await crypto.subtle.generateKey(rsaParams, true, ['sign', 'verify']);
const attacker = await crypto.subtle.generateKey(rsaParams, true, ['sign', 'verify']);

const jwk = await crypto.subtle.exportKey('jwk', legit.publicKey);
jwk.kid = 'apple-test-key';
jwk.alg = 'RS256';

// Serve only the legitimate public key, exactly as Apple's JWKS endpoint would.
globalThis.fetch = async () => ({ ok: true, json: async () => ({ keys: [jwk] }) });

async function mintToken(claims, key, header = { alg: 'RS256', kid: 'apple-test-key' }) {
  const h = b64u(enc.encode(JSON.stringify(header)));
  const p = b64u(enc.encode(JSON.stringify(claims)));
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', key, enc.encode(`${h}.${p}`)
  );
  return `${h}.${p}.${b64u(signature)}`;
}

const nowS = Math.floor(Date.now() / 1000);
const validClaims = {
  iss: 'https://appleid.apple.com',
  aud: 'org.batesai.endgamefitness',
  sub: '001234.deadbeef.0001',
  email: 'lifter@example.com',
  exp: nowS + 3600,
  iat: nowS,
};

const options = {
  jwksUrl: 'https://appleid.apple.com/auth/keys',
  issuers: ['https://appleid.apple.com'],
  audiences: ['org.batesai.membership', 'org.batesai.endgamefitness'],
};

let passed = 0;
let failed = 0;

function check(name, condition) {
  if (condition) {
    passed += 1;
    console.log(`  ✓ ${name}`);
  } else {
    failed += 1;
    console.error(`  ✗ ${name}`);
  }
}

console.log('Apple / Google identity-token verification\n');

check(
  'a genuine token is accepted',
  !!(await verifyProviderToken(await mintToken(validClaims, legit.privateKey), options))
);

check(
  'a token signed by a different key is rejected (forgery)',
  null === await verifyProviderToken(await mintToken(validClaims, attacker.privateKey), options)
);

check(
  'an expired token is rejected',
  null === await verifyProviderToken(
    await mintToken({ ...validClaims, exp: nowS - 60 }, legit.privateKey), options
  )
);

check(
  'a token from the wrong issuer is rejected',
  null === await verifyProviderToken(
    await mintToken({ ...validClaims, iss: 'https://evil.example' }, legit.privateKey), options
  )
);

check(
  "another app's audience is rejected",
  null === await verifyProviderToken(
    await mintToken({ ...validClaims, aud: 'com.someone.else' }, legit.privateKey), options
  )
);

check(
  'an alg:none downgrade is rejected',
  null === await verifyProviderToken(
    await mintToken(validClaims, legit.privateKey, { alg: 'none', kid: 'apple-test-key' }), options
  )
);

check(
  'an HS256 confusion attempt is rejected',
  null === await verifyProviderToken(
    await mintToken(validClaims, legit.privateKey, { alg: 'HS256', kid: 'apple-test-key' }), options
  )
);

check(
  'an unknown signing key id is rejected',
  null === await verifyProviderToken(
    await mintToken(validClaims, legit.privateKey, { alg: 'RS256', kid: 'not-a-real-kid' }), options
  )
);

check(
  'a token with no subject is rejected',
  null === await verifyProviderToken(
    await mintToken({ ...validClaims, sub: undefined }, legit.privateKey), options
  )
);

check(
  'a token issued far in the future is rejected',
  null === await verifyProviderToken(
    await mintToken({ ...validClaims, iat: nowS + 8000 }, legit.privateKey), options
  )
);

check(
  'malformed input is rejected',
  null === await verifyProviderToken('not.a.jwt', options)
);

check(
  'an audience array containing ours is accepted',
  !!(await verifyProviderToken(
    await mintToken({ ...validClaims, aud: ['other.app', 'org.batesai.endgamefitness'] }, legit.privateKey),
    options
  ))
);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
