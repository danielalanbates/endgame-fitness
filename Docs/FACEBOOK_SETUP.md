# Facebook sign-in setup

Last checked: 2026-11-18. Facebook is the only sign-in provider for Endgame Fitness.

## Current credential audit

The Meta App ID and App Secret were not present in the Endgame project documentation, the Google Drive Code `Documentation` folder, or the secure key files referenced by that folder. The `Documentation_Project_Management_Meta_.env` secure-store file contains email budget-alert settings; it does not contain Facebook app credentials. Both values have since been entered as Cloudflare Worker secrets. The latest name-only secret listing shows `FACEBOOK_APP_ID` and `FACEBOOK_APP_SECRET`. No secret value is stored in repository files; the App Secret was not read back or placed in chat.

## Meta dashboard status

A read-only browser report says the Meta account has one app named **BatesAI** in Development mode. The user reports saving these Endgame settings on that app: app domain `batesai.org`, privacy and data-deletion URLs `https://batesai.org/endgamefitness/privacy`, and valid OAuth redirect URI `https://batesai.org/api/endgame/auth/callback`. The redirect URI persisted after a page reload. These fields were not independently re-read during this update. The App Secret was entered directly into Wrangler and remains absent from chat and files. The app remains in Development mode. The report says the app category and icon are still missing for submission.

The repository already contains a 1024 × 1024 Endgame icon candidate at `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png`. It has not been uploaded to Meta. The requested Meta settings were the only reported Meta-side changes; no category or icon was submitted.

At the latest production check, `wrangler secret list --config Server/wrangler.toml` returned both secret names, `/api/endgame/config` returned `facebook:true`, and `/api/endgame/auth/start` returned `302` to `www.facebook.com/v27.0/dialog/oauth` with scope `public_profile` and the configured callback URI. This verifies readiness and the OAuth start redirect, not a completed Facebook callback or account login. Worker version `3037fae0-d49f-4b62-b10b-34521d4f814b` is deployed.

Do not add either value to this document, source control, screenshots, or chat. Save both directly as Cloudflare Worker secrets.

## Meta app values to configure

Create or select a Meta developer app with Facebook Login enabled. Complete Meta's app review, business verification, privacy and data-deletion requirements as Meta requires before public use.

| Meta setting | Value |
| --- | --- |
| App website / domain | `https://batesai.org/endgamefitness/` / `batesai.org` |
| Valid OAuth redirect URI | `https://batesai.org/api/endgame/auth/callback` |
| Privacy policy | `https://batesai.org/endgamefitness/privacy` |
| Data deletion instructions | `https://batesai.org/endgamefitness/privacy` |
| Permission requested | `public_profile` only |
| Graph API version | `v27.0` (configured in `Server/wrangler.toml`) |

The app does not request email, contacts, friend lists, or permission to publish. Friend invitations use Endgame's own private friend codes.

## Store credentials safely

From the project root, set each value using Wrangler's interactive prompt. Do not append the value to the command or put it in a file.

```sh
wrangler secret put FACEBOOK_APP_ID --config Server/wrangler.toml
wrangler secret put FACEBOOK_APP_SECRET --config Server/wrangler.toml
```

Then deploy the Worker:

```sh
wrangler deploy --config Server/wrangler.toml
```

Check only the secret names and readiness; never print secret values:

```sh
wrangler secret list --config Server/wrangler.toml
curl -fsS https://batesai.org/api/endgame/config
```

Expected readiness response: `{"facebook":true,"provider":"facebook"}`. If it remains false, confirm the secrets were attached to the `endgame-fitness` Worker production environment and deploy again.

## Verify before calling the app public

1. Sign in with a Meta app role account and confirm the redirect returns to Endgame.
2. Confirm the web app creates an account and saves/reloads a workout after refresh.
3. Confirm a native Mac build completes Facebook sign-in through the PKCE callback and restores the selected existing local profile and onboarding answers.
4. Test cancellation, expired OAuth state, replayed callback, and invalid native exchange.
5. Test with a Facebook account that is not an app role after Meta has enabled public/live access. A successful developer/tester login alone does not verify public access.
6. Verify mutual friend acceptance, account deletion, and the data-deletion instructions from a real account.

Until these checks pass, keep GitHub releases marked prerelease and describe Facebook sign-in as not yet active for public use. The site can be reached at [batesai.org/endgamefitness](https://batesai.org/endgamefitness/), but login is not currently available.

## Product and implementation notes

- The server exchanges the authorization code, fetches only Facebook's app-scoped ID and display name, and discards the provider access token.
- Native handoff uses a short-lived one-use code bound to PKCE. Session tokens are stored in Keychain on Mac and in HttpOnly cookies on the web.
- Training history on Mac and web is still stored in separate formats. The Facebook account mapping preserves the existing Mac player's local profile; it does not synchronize Mac and web workout logs.
- The full deployment, security, and database notes are in [`../Server/README.md`](../Server/README.md); this document is the setup checklist for the project Docs folder.

Support: [help@batesai.org](mailto:help@batesai.org) · [batesai.org](https://batesai.org)

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
