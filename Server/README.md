# Endgame Fitness server and deployment

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.

Website: https://batesai.org/endgamefitness/ · Support: help@batesai.org

## Architecture

- Cloudflare Pages serves the app at `/endgamefitness/` and handles the shared
  BatesAI `/membership` OAuth callback.
- This Worker owns only `/api/endgame/*`; it does not serve the production app
  path after the shared-account migration.
- BatesAI Membership is the identity system. Google and Apple sign-in are
  initiated and completed by the website. The Worker validates the opaque
  `batesai_session` against the existing `sessions` table in `batesai-db`.
- `ef_membership_links` maps a BatesAI user ID to one stable Endgame profile.
  The first version of `ef_accounts` requires a `facebook_id` column, so new
  rows store the synthetic internal key `batesai:<user-id>` there. It is not a
  Facebook identifier and is never returned by the API.
- Account deletion in Endgame deletes its profile, workout state and friend
  edges, then revokes the current shared BatesAI session. BatesAI account
  deletion removes linked Endgame rows and outstanding native handoff codes.

## Local verification

```sh
node --test Web/local-app/tests/*.test.mjs Server/tests/*.test.mjs
node scripts/build-web.mjs
wrangler deploy --config Server/wrangler.toml --dry-run
xcodegen generate --spec App/project.yml
xcodebuild -project App/EndgameFitness.xcodeproj -scheme EndgameFitness-macOS \
  -configuration Release -derivedDataPath "$PWD/.local/DerivedData" \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO build
```

The browser tests use a local database fixture. Real Google and Apple callback
completion must still be checked on production with authorized test accounts.
The user-facing Mac beta is the local `.app`; test builds without signing do
not constitute a public release.

## Production migrations and deployment

Apply the Endgame mapping table before deploying code that reads it:

```sh
wrangler d1 execute batesai-db --remote --config Server/wrangler.toml --file Server/migrations/0002_batesai_membership.sql
wrangler deploy --config Server/wrangler.toml
```

The website Pages repo applies `migrations/0003_auth_handoff.sql` and stages
the built Endgame files in `public/endgamefitness/` as part of
`scripts/deploy_site.sh`. Its full publishing contract is in the website repo's
`docs/ENDGAME_FITNESS_DEPLOYMENT.md`. Deploy Pages first, then redeploy this
Worker if retiring an older `/endgamefitness*` route. Do not use GitHub Actions
or GitHub-hosted compute for local builds and publishing.

## Security behavior

- Only the website verifies Google/Apple provider responses. Provider tokens
  and client secrets never enter Endgame.
- Browser writes require exact `https://batesai.org` origin and JSON content.
  Native requests use an Authorization bearer token.
- Cloud saves are account-owned, structurally validated and use optimistic
  revisions. Stale writes return `409`.
- Friends must mutually accept before aggregate stats are shared. The social
  API does not return workout details, credentials, or internal account keys.
- Keep OAuth credentials in Cloudflare secret storage. Keep training exports
  in ignored local storage; do not commit them or place them in documentation.

## Future work

- Run a real Google and Apple sign-in check before claiming provider-level
  end-to-end validation.
- Add a scheduled cleanup for expired shared session and handoff rows after
  reviewing the database's existing retention jobs.
- Validate a versioned bridge before syncing native and web training histories.
- Consider rebuilding `ef_accounts` with a provider-neutral identity schema
  after checking live counts and preserving an encrypted backup.
