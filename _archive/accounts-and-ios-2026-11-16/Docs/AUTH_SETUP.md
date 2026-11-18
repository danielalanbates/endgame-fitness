# Endgame Fitness sign-in: how it works

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
https://batesai.org · help@batesai.org

Last rewritten 2026-10-27. It describes the code on the auth v2 branch. Endpoint
shapes are defined in `Docs/API_V2.md` §1. Where this doc and the code disagree,
the code wins. Fix this doc when that happens.

The previous version of this file described JWTs, `JWT_SECRET`, redirect URIs
under `/api/auth/oauth/*` and endpoints such as `/api/workouts`. None of that
exists. If you find instructions like that anywhere, ignore them.

---

## 1. The model

- **One membership.** There is one batesai.org account (a `users` row) per
  person. The website, the PWA at `/fitness/` and the macOS/iOS apps all use
  it. A `fitness_profiles` row is created next to it on the first sign-in from
  any path. It starts **private** (`is_public = 0`).
- **Sessions are opaque tokens, not JWTs.** Each token is 32 random bytes,
  base64url. Only its SHA-256 is stored, in `sessions` (`token_hash`,
  `expires_at`). The lifetime is a fixed 30 days and is not renewed. There is
  no signing key.
- **The same token works three ways:**
  - `Authorization: Bearer <token>` (native apps, PWA)
  - the `batesai_session` cookie (website, PWA after a Google or Apple sign-in)
  - `?token=` in the URL (old clients only; new clients must not use it)
- **Clients sign out only on HTTP 401.** A 5xx or network error keeps the
  stored token.

## 2. Where the code lives

| File | Role |
|---|---|
| `App/Backend/functions/api/auth/[[path]].js` | The whole `/api/auth/*` API: login, register, verify, me, logout, OAuth start + exchange, native Apple/Google, handoff, account deletion |
| `App/Backend/functions/membership.js` | The `/membership` landing route. Google returns here with `GET ?code=`; Apple returns here with a `POST` form. It calls the auth API on the same origin and redirects. |
| `App/Backend/functions/_lib/return-to.js` | Validates `?return_to=` (same-site paths only) and builds its cookie |
| `App/Backend/functions/_lib/ratelimit.js` | Fixed-window counters in D1 (`rate_limits`) |
| `App/Backend/functions/_lib/session.js` | `requireUser()` for `/api/fitness/*` (Bearer or cookie) |
| `App/Backend/migrations/2026-10-27-auth-v2.sql` | `user_identities`, `auth_handoff_codes` |
| `App/Backend/migrations/2026-10-27-rate-limits.sql` | `rate_limits` |
| `App/Backend/tests/auth-flows.test.mjs`, `auth-verification.test.mjs` | Tests (section 9) |

`functions/membership.js` was ported from the website repo
(`danielalanbates/website`, `functions/membership.js`), which is what runs on
batesai.org today. Without the cookies described below, it behaves exactly
like that copy.

## 3. Sign-in paths

### 3.1 Email + password (native apps, PWA)

- `POST /api/auth/register {email, password, name}`
  - Returns `201 {token, user}`.
  - `409` if the email exists.
  - `400` if the password is under 8 or over 256 characters, or the email is
    malformed or ends in `.local`. The `.local` domains are reserved for
    provider placeholders (section 4).
- `POST /api/auth/login {email, password}`
  - Returns `200 {token, user}`.
  - `401 {"error":"Invalid email or password"}` on a wrong password.

Password hashing:

- **PBKDF2-SHA256** with 100,000 iterations. That is the Cloudflare Workers
  maximum.
- 16-byte salt.
- Stored as `pbkdf2$<iterations>$<salt base64>$<hash base64>`.
- Compared in constant time.
- **Old formats** still verify once:
  - `$sha256$<salt>$<hex>`
  - bare unsalted SHA-256 hex

  On the next successful login they are re-hashed to PBKDF2.
- **`PBKDF2_ITERATIONS`** (optional env var, clamped to 10,000–100,000) sets
  the cost of *new* hashes. Each stored hash keeps its own iteration count.

**Rate limits** (D1 `rate_limits`, fixed windows). Over the limit returns
`429 {error:"rate_limited", retry_after}` plus a `Retry-After` header.

| Action | Limit |
|---|---|
| Login, per email | 10 per 15 min. The email is SHA-256'd before it becomes a bucket name. |
| Login, per IP (`CF-Connecting-IP`) | 30 per 15 min |
| Register, per IP | 5 per hour |
| Handoff, per IP | 20 per 15 min |

The limiter fails open if D1 errors.

**Not available:** password reset, email verification, password change. No
email provider is configured. The clients say: "Forgot your password? Sign in
with Apple or Google using the same email, or write to help@batesai.org."
Note that signing in with a provider may clear the password (section 4).

### 3.2 Native Sign in with Apple (macOS / iOS)

1. The app runs `ASAuthorizationAppleIDProvider` with a SHA-256-hashed nonce.
2. It sends `POST /api/auth/native/apple {identity_token, nonce, full_name?}`.
3. The server checks the token's RS256 signature against Apple's JWKS, plus
   issuer, expiry and audience.
4. It returns `{success, token, user}`.

Accepted audiences:

- `APPLE_CLIENT_ID` / `OAUTH_APPLE_CLIENT_ID` (default `org.batesai.membership`)
- anything in `APPLE_NATIVE_CLIENT_IDS`
- `org.batesai.endgamefitness`
- `com.batesllc.EndgameFitnessMobile`

The nonce is compared verbatim or after hashing. Older builds sent the raw
nonce. The server does not issue nonces itself, so the nonce check is not
replay protection.

### 3.3 Native Google: one-time code handoff (API_V2 §1.1)

Google only redirects to `https://batesai.org/membership`. The app cannot
receive that redirect itself, so the browser sign-in ends by handing the app a
short-lived code.

```
App ── ASWebAuthenticationSession ──▶ GET /api/auth/oauth/google?redirect_scheme=endgamefitness
        302 to Google; Set-Cookie: google_oauth_state, oauth_app_scheme=endgamefitness
        (Max-Age 300, SameSite=Lax, Secure, HttpOnly)
Google ──▶ GET /membership?code=…&state=…          (functions/membership.js)
        membership.js ──▶ POST /api/auth/oauth/google {authorization_code, app_scheme}
                          (same-origin subrequest; the server redeems Google's code,
                           resolves the member, mints the handoff code)
        ◀── {success, handoff_code}
        302 endgamefitness://auth?code=<43 chars>   (Cache-Control: no-store; cookies cleared)
App ──▶ POST /api/auth/handoff {code}
        ◀── 200 {success, token, user}               (same shape as /login)
```

- **The code:** 32 random bytes, base64url. Only `sha256(code)` is stored, in
  `auth_handoff_codes`. It expires after 120 s and redeems once (a conditional
  `UPDATE … RETURNING`).
- **Errors from `POST /handoff`:** `400 {error:"code_used"}`,
  `{error:"code_expired"}` or `{error:"invalid_code"}`.
- **No session in the browser.** No session or `batesai_session` cookie is
  created during the browser leg. The token never appears in a URL.
- **Failures still reach the app.** Any failure while `oauth_app_scheme` is set
  redirects to `endgamefitness://auth?error=<reason>`, so the sheet does not
  strand on a web page. Reasons: `access_denied`, `state_mismatch`,
  `code_replayed`, `not_configured`, `token_rejected`, `account_exists`,
  `server_error`.
- **Allow-listed schemes only.** `APP_SCHEMES` holds just `endgamefitness`, in
  both the auth worker and `membership.js`. Any other `redirect_scheme` is
  ignored, and the cookie is re-validated when it is read.
- **Leftover cookies are cleared.** A plain web sign-in (no `redirect_scheme`)
  clears any `oauth_app_scheme` cookie left by an abandoned attempt.

`POST /api/auth/native/google {id_token}` also exists, for a future native
Google SDK. It needs that SDK's client IDs in `GOOGLE_NATIVE_CLIENT_IDS`. The
apps do not use it today.

### 3.4 Google on the web (membership page, PWA)

1. A link to `GET /api/auth/oauth/google`, optionally with
   `?return_to=/fitness/` or another same-site path. The return path is held in
   the `oauth_return_to` cookie (Lax, 10 min).
2. Google sends the user back to `/membership?code=…`.
3. `membership.js` redeems the code server-side, copies the `batesai_session`
   cookie onto its response, and 302s to `/membership/?signed_in=1`. With a
   return path it goes to `<path>?signed_in=1`.
4. Failures go to `/membership/?error=<reason>`, or
   `<path>?signin_error=<reason>` when a return path is set.

### 3.5 Sign in with Apple on the web (form_post)

1. `GET /api/auth/oauth/apple` 302s to Apple with:
   - `response_type=code id_token`
   - `response_mode=form_post`
   - `redirect_uri=https://batesai.org/membership`
2. Apple POSTs the form to `/membership`.
3. `membership.js` passes the `id_token` to `POST /api/auth/oauth/apple`.
4. The redirects are the same as Google's.

The identity token is verified against Apple's public keys, so **no Apple
client secret or .p8 key is needed**.

Apple's POST back is cross-site, so only `SameSite=None` cookies arrive with
it. The Apple start route therefore sets `apple_oauth_state`, the
`oauth_return_to` cookie (for `?return_to=`) and `oauth_app_scheme` (for
`?redirect_scheme=`) all as `SameSite=None`. That means the PWA's "Continue
with Apple" (`?return_to=/fitness/`) and an app handoff via
`?redirect_scheme=endgamefitness` both work on this path. The apps should
still prefer native Sign in with Apple (3.2).

## 4. Identity linking and the pre-hijack rule (API_V2 §1.2)

`user_identities(provider, provider_sub, user_id, email, verified, …)` holds
every Apple and Google identity attached to a membership. It replaces the
single `users.oauth_provider/oauth_id` slot. That slot is still written when it
is empty, but it is never overwritten. It used to flip-flop when one person
used both providers.

Each provider sign-in resolves in this order:

1. `(provider, sub)` in `user_identities`, then in the legacy slot.
2. Otherwise, a `users` row with the same email, **only if the provider says
   the email is verified** (`email_verified`).
   - An unverified provider email never links. The API answers
     `409 {code:"account_exists"}`, which `membership.js` maps to the reason
     `account_exists`.
   - **Pre-hijack fix.** Anyone can register someone else's address with a
     password. So when a verified identity links to a row that has a password
     but has never been verified by any provider:
     - the password is cleared (set to `''`, which already means "no
       password");
     - **every session of that row is deleted** before the new one is issued.

     The owner of the address keeps the account. Whoever set the password loses
     access. A row that some provider has verified keeps its password and
     sessions when another provider is added.
3. Otherwise, a new member is created.
   - If the provider withheld the email, the row uses a placeholder
     `<sub>@<provider>.local` email. Placeholders never link, and
     `/register` refuses `.local` addresses.

Starter display names are cut down to 2–24 characters of letters, digits,
spaces and `_-.'`. Anything shorter becomes "Athlete".

**Residual risk.** The migration backfills every pre-existing legacy link as
`verified = 1`. The old code linked without checking verification, so an
account that was pre-hijacked *before* this change keeps whatever password it
has.

## 5. Account deletion

Either `DELETE /api/auth/account` or `POST /api/auth/account/delete`, with a
Bearer token or the cookie.

1. Owned guilds pass to the longest-serving member. A guild with no other
   members is deleted.
2. One D1 batch then deletes the member's rows from the website and fitness
   tables. That includes `dm_sync`, `sm_progress`, `sm_profile` and `sm_plan`
   (website features), plus `user_identities`, `auth_handoff_codes`, the
   member's email rate-limit bucket, friendships, challenges and the `users`
   row.
3. Tables that do not exist on the database are skipped (looked up in
   `sqlite_master`). A missing website-only table cannot block a deletion.

**Not done:**

- Sign in with Apple tokens are not revoked. Apple's revoke endpoint needs a
  client secret we deliberately do not hold.
- A Stripe subscription is not cancelled. Its `subscriptions` row is deleted.

## 6. Tables

| Table | Created by | Notes |
|---|---|---|
| `users` | `schema.sql` (shared with the website) | `password_hash` = `''` means no password |
| `sessions` | `schema.sql` | `token_hash` = SHA-256 hex |
| `fitness_profiles` | `schema.sql` | created on first sign-in, private by default |
| `user_identities` | `migrations/2026-10-27-auth-v2.sql` | PK `(provider, provider_sub)`; backfilled from the legacy slot |
| `auth_handoff_codes` | `migrations/2026-10-27-auth-v2.sql` | PK `code_hash`; rows older than a day are pruned when a code is minted |
| `rate_limits` | `migrations/2026-10-27-rate-limits.sql` | windows older than a day are pruned on about 1% of limited requests |

The migrations are idempotent. D1 has no `ADD COLUMN IF NOT EXISTS`, so new
state goes into new tables. Apply the migrations **before** deploying the
worker. The worker degrades without them: sign-in falls back to the legacy
columns and deletion skips the missing tables. Only the handoff needs
`auth_handoff_codes`.

## 7. Configuration

Pages environment variables. Keep secrets out of git.

| Name | Needed for | Value |
|---|---|---|
| `DB` (binding) | everything | D1 `batesai-db` |
| `OAUTH_GOOGLE_CLIENT_ID` | Google web + handoff | the web OAuth client (live: `831703789636-tln3ll…apps.googleusercontent.com`) |
| `OAUTH_GOOGLE_CLIENT_SECRET` (secret) | Google code exchange | from Google Cloud Console |
| `APPLE_CLIENT_ID` or `OAUTH_APPLE_CLIENT_ID` | optional | Services ID; defaults to `org.batesai.membership` |
| `APPLE_NATIVE_CLIENT_IDS` | optional | extra comma-separated Apple audiences |
| `GOOGLE_NATIVE_CLIENT_IDS` | only for `native/google` | comma-separated client IDs |
| `ALLOWED_ORIGINS` | CORS | e.g. `https://batesai.org` |
| `PBKDF2_ITERATIONS` | optional | 10,000–100,000; default 100,000 |

`JWT_SECRET` and `OAUTH_APPLE_CLIENT_SECRET` are **not** used by the current
flows. `deploy.sh` still prints them in its reminder text.

Outside Cloudflare:

- **Google Cloud Console:** the web OAuth client must list
  `https://batesai.org/membership` as an authorized redirect URI. It does
  today: the live start route uses it.
- **Apple Developer, Services ID `org.batesai.membership`:** return URLs must
  include `https://batesai.org/membership`. Probed 2026-10-27 with read-only
  GETs: Apple's authorize page answered 200 for both `/membership` and
  `/api/auth/apple/callback`, and 403 for an unregistered URL.
  `wrangler.toml` in the website repo still names
  `/api/auth/apple/callback`, but no route serves that path. The flow uses
  `/membership`.
- **App ID `org.batesai.endgamefitness`:** has the Sign in with Apple
  capability. The entitlement is in `App/project.yml`. The
  `ASWebAuthenticationSession` callback scheme `endgamefitness` does not need
  a `CFBundleURLTypes` entry.

## 8. Deploying

`App/Backend/deploy.sh` copies the auth and fitness workers and `_lib/*.js`,
applies `schema.sql` and every migration, and then deploys.

**It does not yet copy `functions/membership.js`.** Until it does, copy that
file over the website repo's copy by hand, or production keeps the old
callback. With the old callback, the native Google handoff and the Apple
return path do not work. The website's copy and this one must not drift.

Order: migrations first, then the functions. Deploy the auth worker and
`membership.js` together. A new `membership.js` talking to an old worker gets
no `handoff_code` and sends the app `error=server_error`.

## 9. What is verified, and what is not

Verified here (2026-10-27):

- `node App/Backend/tests/auth-flows.test.mjs`: 97 checks. They run against
  `node:sqlite` loaded with the real `schema.sql` and migrations, with fake
  Google/Apple keys and no network. They cover:
  - the handoff: single use, expiry, hash-only storage, 120 s TTL, cookie flags
    and the scheme allow-list;
  - the full Google and Apple `/membership` flows with and without the app
    cookie or a return path;
  - PBKDF2 round trip and rehash of both legacy formats;
  - the pre-hijack rule, unverified emails and legacy-slot resolution;
  - 429s on every limit;
  - logout;
  - account deletion.

  Deliberately breaking the pre-hijack clear, the single-use check, the
  verified-email check, the constant-time compare, the email limit, the rehash
  or the scheme handling each makes the suite fail.
- `node App/Backend/tests/auth-verification.test.mjs`: 12 checks on JWT
  signature, issuer, audience and expiry.
- Live read-only checks:
  - `GET /api/auth/oauth/google?redirect_scheme=endgamefitness` → 302 to Google
    with `redirect_uri=https://batesai.org/membership`. It sets no app cookie
    yet: production is still on the old worker.
  - `GET /api/auth/handoff` → 404: not deployed.

**Not verified:**

- **None of the above has run on Cloudflare.** It is untested against real D1
  or the real Workers runtime.
- A real Google sign-in end to end has never been completed against
  production. See the website repo's `docs/membership-oauth.md`.
- Apple web form_post has not been completed with a real Apple ID, and
  Safari's handling of the `SameSite=None` cookies on that POST is unconfirmed.
- Native Sign in with Apple has never been run on a device (`Docs/STATUS.md`).
- The native handoff needs the app to open the URL above, read `?code=` (or
  `?error=`) and call `POST /api/auth/handoff`. Check `BatesAIAuth.swift`
  before claiming it works.
- **PBKDF2 CPU time on Workers is unmeasured.** It is about 14 ms on an Apple
  Silicon Mac in Node. If batesai.org runs on the Workers Free plan (10 ms CPU
  per request), login and register may hit CPU-limit errors (1102). Test one
  login right after deploying. `PBKDF2_ITERATIONS` lowers the cost of new
  hashes only.
- **iOS home-screen PWA:** an OAuth trip out of a standalone web app may
  finish in Safari rather than in the app window. Email and password still
  work there.

## 10. Known gaps

- No password reset, email verification or password change. No email
  provider is configured.
- Sessions have a fixed 30-day lifetime with no refresh. Expired rows are never
  purged.
- `?token=` is still accepted, for old clients.
- `users.membership_tier` is never written by Stripe. The paid tier shows as
  `free`.
- Deletion does not revoke Apple tokens or cancel Stripe (section 5).
- There is no UI to link a second provider to a signed-in account. Linking
  happens only by verified email.
