# BatesAI account sign-in for Endgame Fitness

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.
Website: https://batesai.org/endgamefitness/ · Support: help@batesai.org

## Provider choice

Endgame uses the existing BatesAI Google and Apple membership providers. It
does not maintain separate Endgame credentials or call Facebook for login.
Provider secrets and provider ID tokens stay in BatesAI's website auth service.

## Browser sequence

1. The app links to `/api/auth/oauth/google?return_to=%2Fendgamefitness%2F` or
   the Apple equivalent.
2. The Pages Function starts OAuth with a random state. State and a validated
   same-site return path live in a five-minute HttpOnly cookie. Apple uses
   `SameSite=None; Secure` because its callback is a cross-site form POST.
3. Google returns by GET and Apple by POST to `https://batesai.org/membership`.
   `functions/membership.js` checks state before forwarding the code to
   `/api/auth/oauth/{provider}`.
4. A successful browser flow sets the existing `batesai_session` cookie, then
   redirects to the original app path. The cookie is Secure, HttpOnly,
   SameSite=Lax, and valid for 30 days.
5. Endgame sends same-origin requests to `/api/endgame/*`. The Worker hashes
   the cookie token and checks the existing `sessions` table before serving
   account data.

## Native Mac sequence

The Mac app opens the same Google or Apple website flow in
`ASWebAuthenticationSession`. It holds a random verifier in memory and passes
only its S256 challenge to the website. After provider verification,
`functions/membership.js` removes the temporary browser session and creates a
60-second, one-use code bound to that challenge. It redirects to
`endgamefitness://auth?code=...`. The app sends the code and verifier to
`/api/auth/native/handoff`, receives a new BatesAI session token, and stores it
in Keychain. The custom URL never contains a reusable session token.

The first membership account on a Mac adopts the currently selected local
player. This keeps existing workouts and setup answers. Later membership
accounts receive separate local profiles. The web app and Mac still use
different training formats and do not sync workout histories.

## Data model

The existing BatesAI `users` and `sessions` tables remain authoritative. New
Endgame identities are mapped by `ef_membership_links` to the Endgame
`ef_accounts` row. The first Endgame table version requires a `facebook_id`
column; the migration uses the synthetic internal key `batesai:<user-id>` in
that column. This key is never returned to clients. Production was checked
before the switch and had zero Endgame account rows, so no Endgame identity
records required provider migration.

The website D1 migration adds `auth_handoff_codes`. Endgame D1 migration
`Server/migrations/0002_batesai_membership.sql` adds the membership map. The
website account-deletion handler removes both tables' Endgame data and pending
handoffs. Endgame profile deletion removes Endgame records and revokes the
current shared session.

## Local checks

```sh
npm test
node --test Web/local-app/tests/*.test.mjs Server/tests/*.test.mjs
node scripts/build-web.mjs
xcodegen generate --spec App/project.yml
```

Website callback tests mock provider and database responses. They verify state,
SameSite cookies, account session creation, Apple form parsing, and one-use
PKCE redemption. Endgame tests verify session mapping, cookie/Bearer auth,
ownership, revision conflicts, friend permissions, deletion, and workout rules.
The browser flow additionally covers plan setup, workouts, rewards, backup
import/export, search and party actions when a Playwright browser binary is
available. A successful local build does not prove provider-console settings.

## Future pathways

- Keep browser-based membership as the default so provider setup stays in one
  place and the app does not ship provider SDK configuration.
- If native Google or Apple SDKs are introduced later, use the existing
  `/api/auth/native/google` and `/api/auth/native/apple` identity-token routes
  with signature, issuer, audience and nonce validation. Do not add a second
  Endgame user database.
- Replace the legacy `facebook_id` column with a provider-neutral schema only
  after checking production row counts, keeping a backup, and writing a tested
  migration. Do not reuse email as the permanent identity key.
- Run full production Google and Apple callbacks with authorized accounts
  before claiming real-provider end-to-end validation.
