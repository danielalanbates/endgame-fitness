# Endgame Fitness current status

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.
Website: https://batesai.org/endgamefitness/ · Support: help@batesai.org

Updated November 18, 2026.

## Current login and deployment

- Endgame uses the existing BatesAI Google and Apple membership system. There
  is no separate Endgame or Facebook login.
- The web app is published at `https://batesai.org/endgamefitness/`. The Pages
  deployment completed at `https://f23ac02d.website-8lz.pages.dev`.
- Pages handles the `/membership` OAuth callback. The Endgame Worker now routes
  only `/api/endgame/*`; production version `2be68dff-d05a-48f7-a794-73762c6fd06a`.
- Public app source: `https://github.com/danielalanbates/endgame-fitness`.
  The private `endgame-fitness.batesai.org` repo has a `current-main` mirror
  branch; its older `main` history is preserved.
- The production Google and Apple start routes both returned 302 to their
  providers and used `https://batesai.org/membership` as the callback. Google
  state uses `SameSite=Lax`; Apple form POST uses `SameSite=None; Secure`.
- Production callback smoke checks rejected mismatched state for both GET and
  Apple form POST. The old `/api/endgame/auth/start` route now returns 404.
- Facebook App ID and App Secret were removed from the Endgame Worker after the
  new shared-session API was deployed. No secret values are stored in this repo.

## Data and session status

- The Endgame membership-link migration and website native-handoff migration
  were applied to the existing `batesai-db` database.
- Before the switch, production had zero rows in `ef_accounts`; there was no
  Facebook Endgame profile data to migrate.
- The Worker validates BatesAI session hashes against the shared `sessions`
  table and maps each BatesAI user to one stable Endgame profile.
- The app uses Secure, HttpOnly browser sessions. The Mac beta uses a
  one-use, PKCE-bound native handoff and stores its BatesAI session in Keychain.
- Google and Apple redirects and callback state rejection are verified. A full
  login using an actual Google or Apple account has not been completed in this
  run, so provider-console configuration and account access still need a real
  sign-in check.

## Verification

| Check | Result |
| --- | --- |
| BatesAI website callback tests | 6/6 pass: OAuth start, state validation, secure cookies, Apple form callback, session cookie, and one-use native PKCE exchange |
| Endgame web/backend tests | 39/39 pass: training engine, membership mapping, cookie/Bearer sessions, ownership, conflicts, friends, logout and deletion |
| Native engine self-test | 304/304 pass |
| Mac beta | Release build succeeded for Apple Silicon; a fresh local app copy is at the top level of Downloads |
| Website build | Astro static build succeeded; existing warnings remain for stale Browserslist data and an unrelated GET-only API route |
| Worker build | Wrangler dry-run passed; production deploy contains only the API custom route |
| Production smoke | App, privacy redirect, membership page, provider redirects, config and anonymous response verified |
| Browser automation | Not run to completion: Playwright's Chromium executable is not installed. No browser was installed or opened. |

## Data and product limits

- Native Mac and web training histories remain separate formats and do not sync.
- Endgame's first schema requires a `facebook_id` column. New rows use the
  internal synthetic `batesai:<user-id>` key, never a Facebook identifier.
- Program rules are conservative product choices, not proof of universal
  superiority over a qualified coach or every custom plan.
- The Mac `.app` is an unsigned local beta; signing and notarization remain
  necessary for a normal public download.

## Next work

1. Complete Google and Apple production sign-in with authorized accounts and
   verify Endgame web saves under the resulting BatesAI account.
2. Complete the Mac beta sign-in once for each provider and confirm the current
   local player and onboarding answers remain selected.
3. Install a local Playwright browser only if browser QA is needed and permitted;
   then rerun `scripts/verify/web_flow.py` against its local fixture.
4. Before introducing workout sync, define and test a versioned bridge between
   native and web training formats.

For architecture and migration details, read [`BATESAI_LOGIN.md`](BATESAI_LOGIN.md),
[`Server/README.md`](../Server/README.md), and the website repo's
`docs/ENDGAME_FITNESS_DEPLOYMENT.md`.
