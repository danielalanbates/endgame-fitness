# Endgame Fitness deployment

Facebook is the only identity provider. The Worker serves the web app and isolated `/api/endgame/*` routes; the rest of batesai.org stays on its existing Pages deployment. No GitHub compute is used.

## Local checks

From the repository root:

```sh
node --test Web/local-app/tests/*.test.mjs Server/tests/*.test.mjs
node scripts/build-web.mjs
wrangler deploy --config Server/wrangler.toml --dry-run
```

## Provision and deploy

```sh
wrangler d1 execute batesai-db --remote --config Server/wrangler.toml --file Server/migrations/0001_endgame.sql
wrangler deploy --config Server/wrangler.toml
```

The migration is additive and uses only `ef_` tables. Do not run membership migrations or recreate the existing database.

## Required Meta setup (external dependency)

1. Register an appropriate Meta developer app and enable Facebook Login for the web. Complete any required business verification, app review, data handling questions and public/live-mode requirements in Meta's dashboard.
2. Set the website URL to `https://batesai.org/endgamefitness/` and register this **exact** Valid OAuth Redirect URI: `https://batesai.org/api/endgame/auth/callback`.
3. Set privacy policy and data-deletion instructions to `https://batesai.org/endgamefitness/privacy.html`. The instructions explain in-app deletion and the support fallback. This build does not claim an automatic Meta signed-request deletion callback.
4. Request only `public_profile`. The app does not request email, friend lists or posting permissions. Sign-in does not automatically expose Facebook contacts.
5. Set `FACEBOOK_APP_ID` and `FACEBOOK_APP_SECRET` using `wrangler secret put <NAME> --config Server/wrangler.toml`. Use interactive secret input. Never put credentials in source, screenshots, shell arguments or PRs.
6. Test with a Meta app tester and then a non-role public account. A configured development-mode Meta app is **not** evidence that public sign-in works.

Without the credentials, `/config` returns `facebook:false`, `/auth/start` returns 503, and both clients display an explicit unavailable state. There is no demo bypass or alternate login in production.

## Security and identity

- Facebook authorization-code exchange occurs server-side; the token is used to fetch the app-scoped Facebook identifier and name, then discarded. HMAC `appsecret_proof` is attached to Graph calls.
- The account key is the Facebook app-scoped identifier, never a claimed email or unverified client-supplied identity.
- OAuth uses a random state, short expiry, HttpOnly state cookie and atomic single-use consumption.
- Native callbacks carry a 60-second one-use code bound to an S256 PKCE verifier held in app memory. They never carry the session or Facebook access token.
- Opaque 256-bit session tokens expire in 30 days. Only SHA-256 hashes are stored. Web tokens use secure HttpOnly SameSite cookies; native tokens use Keychain.
- Cookie mutations require exact same-origin JSON requests. Native requests use Authorization headers.
- Account cloud saves require ownership, structural validation and optimistic revision matching. A stale save returns 409 rather than overwriting another device.
- Friends require mutual acceptance. Only name and aggregate totals are exposed; raw workouts and Facebook IDs are never returned in the social endpoint.
- Self-reported training is not independently verified. XP is derived from validated sets but is not an anti-cheat guarantee; no public competitive ranking is advertised.

## Limitations and next pathways

- Real Facebook login cannot be verified until the Meta app credentials and public/live status exist.
- Native and browser training models are different. They do not share a training log yet. Design a versioned migration before attempting bidirectional sync; never overwrite native history with a reduced web schema.
- Mac's first Facebook account adopts the selected existing local player once; subsequent identities get separate native profiles. Preserve that mapping and the bundle identifier.
- A future friend discovery flow can request eligible Facebook friends only after reviewing Meta's permissions and consent constraints. Do not assume the full Facebook friend graph is available.
- Consider finer-grained per-session writes and server-issued quest claims before large scale. Current full-state writes are limited to 3 MB and use revision checks.
- Expired OAuth states are cleaned on login start; expired sessions/native codes should get a scheduled retention cleanup before large scale.
- The web engine is conservative and deterministic. Its choices are not proof of universal superiority over coach-designed or custom programs.

References: [Meta manual login](https://developers.facebook.com/docs/facebook-login/guides/advanced/manual-flow/), [secure Graph requests](https://developers.facebook.com/docs/graph-api/guides/secure-requests/), [Graph versions](https://developers.facebook.com/docs/graph-api/changelog/versions/), [Workers static assets](https://developers.cloudflare.com/workers/static-assets/).
