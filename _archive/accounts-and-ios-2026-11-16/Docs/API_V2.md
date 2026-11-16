# Endgame Fitness API v2 — contract (2026-10-27)

Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
Questions: help@batesai.org · https://batesai.org

This is the contract the backend (`App/Backend/functions`) and the clients
(Swift app, PWA) build against. Everything in v1 keeps working. Old app builds
(≤ 6) must keep working: **additive changes only, no renamed fields, no
removed endpoints.** Weights on the wire are always **pounds**. Times are
**epoch seconds** unless named `*_at_ms`.

Base: `https://batesai.org/api`. Auth: `Authorization: Bearer <token>` (native)
or the `batesai_session` cookie (web).

---

## 1. Identity — `/api/auth/*`

### 1.1 Native Google sign-in (one-time code handoff) — NEW
The native app cannot receive Google's redirect (Google only knows
`https://batesai.org/membership`). Flow:

1. App opens `ASWebAuthenticationSession` on
   `GET /api/auth/oauth/google?redirect_scheme=endgamefitness`
   (callback scheme `endgamefitness`). The server accepts only the
   allow-listed scheme `endgamefitness`; anything else is ignored. It stores
   the scheme in a short-lived HttpOnly cookie `oauth_app_scheme`
   (Max-Age 300, SameSite=Lax, Secure).
2. Google returns to `/membership?code=…` (`functions/membership.js`, which
   redeems the code server-side exactly as today).
3. If the `oauth_app_scheme` cookie is present, instead of
   `302 /membership/?signed_in=1` the function mints a **one-time handoff
   code** (32 random bytes, base64url; only its SHA-256 is stored in
   `auth_handoff_codes` with `user_id`, `expires_at = now+120`, `used_at`)
   and responds `302 endgamefitness://auth?code=<code>` (and clears the
   cookie). Never put the session token itself in a URL.
4. App: `POST /api/auth/handoff {code}` → `200 {success, token, user}`
   (same shape as `POST /login`). Single use: a second redemption → 400
   `{error:"code_used"}`; expired → 400 `{error:"code_expired"}`.

Apple on the web (`GET /api/auth/oauth/apple?redirect_scheme=endgamefitness`)
follows the same handoff from its form_post callback. Native apps should still
prefer native Sign in with Apple (`POST /api/auth/native/apple`).

### 1.2 Hardening — CHANGED (no shape changes)
- Passwords: PBKDF2-SHA256 via WebCrypto, 100k iterations (Workers limit),
  16-byte salt, stored as `pbkdf2$<iter>$<salt_b64>$<hash_b64>`. Legacy
  SHA-256 hashes verify once and are re-hashed on successful login.
  Constant-time compare.
- Rate limits (D1 table `auth_rate_limits`, fixed windows): login 10 / 15 min
  per email and 30 / 15 min per IP (`CF-Connecting-IP`); register 5 / hour per
  IP; handoff 20 / 15 min per IP. Over limit → `429 {error:"rate_limited",
  retry_after}`.
- Account pre-hijack: when an OAuth/Apple identity with a **verified** email
  links to an existing `users` row that has a `password_hash` but has never
  been verified by a provider, the server clears `password_hash` and deletes
  that user's existing sessions before issuing the new one (the address owner
  wins; whoever set the password loses it). Emails from providers that are not
  verified never auto-link.
- `GET /api/auth/verify` and `/me` unchanged. `?token=` in URLs is still
  accepted for old clients but new clients must not use it.
- `restoreSession` rule for clients: **only HTTP 401 signs the user out**.
  5xx/network errors keep the stored token.

### 1.3 Password reset — not available
No email provider is configured. Clients show: "Forgot your password? Sign in
with Apple or Google using the same email, or write to help@batesai.org."

---

## 2. Profile — `/api/fitness/profile`, `/api/fitness/players/*`

### 2.1 GET profile — CHANGED (additive)
`profile` gains:

| field | type | notes |
|---|---|---|
| `bio` | string? | ≤ 160 chars |
| `hero_class` | string | computed, see 2.4 |
| `class_affinity` | {strength, endurance, mobility, athletic: number 0–1} | last 28 days |
| `earned_titles` | [string] | titles the player may equip |
| `streak_freezes` | int | banked streak-protection tokens (0–3) |
| `streak_alive` | bool | false when the streak lapsed (see 2.5) |
| `season_xp` | int | XP earned in the current season |
| `avatar_config` | object or null | parsed JSON (v1 returned a string; clients must accept both) |
| `onboarded` | bool | true once `training_goal` is set server-side |

The response is created lazily: if the signed-in member has no
`fitness_profiles` row (website-only members, failed sign-in hook), GET and
PUT profile and POST sync create it first instead of returning 404.

### 2.2 PUT profile — CHANGED (validation)
Writable: `display_name` (2–24 chars after trim, letters/digits/space/_-.'
only, basic profanity filter → 400 `{error:"display_name_invalid"}`), `bio`
(≤160, same filter), `title` (must be `null` or one of `earned_titles` → 400
`title_not_earned`), `is_public` (bool), `avatar_config` (object, ≤ 4 KB,
unknown keys dropped), `units` (`lb`|`kg`), `training_goal`,
`experience_level`, `equipment_level`, `body_weight`, `height_inches`,
`birth_year`, `tz_offset_min` (−840…840). Wrong types → 400, never 500.

### 2.3 Privacy defaults
New profiles are created with `is_public = 0`. Onboarding asks; the app shows
a clear toggle in Account. Private players never appear on global
leaderboards, search or public profiles; friends still see them.

### 2.4 Hero class (computed)
From the last 28 days of synced sessions, by exercise `category` in payload v2
(fallback: name heuristics): strength/powerlifting/olympic weightlifting/
strongman → strength; cardio → endurance; stretching → mobility;
plyometrics → athletic. Class by dominant share:
`juggernaut` (strength ≥ 0.6), `ranger` (endurance ≥ 0.5), `monk`
(mobility ≥ 0.4), `striker` (athletic ≥ 0.4), otherwise `paladin` (balanced).
New players: `recruit` until 3 sessions are synced.

### 2.5 Streaks — CHANGED
Days are the player's **local** days using `tz_offset_min` (sent on PUT
profile and on every sync). A missed day consumes a streak freeze if one is
banked; otherwise the streak lapses. `current_streak` is evaluated on read, so
an abandoned streak shows 0 (and drops off the streak leaderboard).
Streak freezes: +1 at every 7-day streak milestone and from season tiers, max 3.

### 2.6 Public players — NEW
- `GET /api/fitness/players/:user_id` → `{player:{user_id, display_name, level,
  xp, title, hero_class, current_streak, total_workouts, avatar_config,
  avatar_url, guild:{id,name,emblem}|null, achievements_count, is_friend,
  is_self, is_blocked}}`. 404 if private and not a friend, or either side
  blocked the other.
- `GET /api/fitness/players/search?q=` (≥ 2 chars; display name prefix or
  exact friend code) → `{players:[…same card, max 20]}`. Public players only.

---

## 3. Sync and history — `POST /api/fitness/sync` — CHANGED

### 3.1 Request (payload v2)
```json
{
  "since": 1793000000,
  "tz_offset_min": -420,
  "steps_today": 8123, "active_kcal_today": 410,
  "sessions": [{
    "id": "uuid", "performed_at": 1793000000, "name": "Push Day",
    "program_id": null, "duration_secs": 3600, "client_rev": 2,
    "total_volume": 12000, "total_reps": 120,
    "deleted": false,
    "payload": {"v": 2, "notes": "felt strong",
      "exercises": [{"name": "Bench Press", "exercise_id": "Barbell_Bench_Press_-_Medium_Grip",
        "category": "strength", "primary_muscles": ["chest"],
        "sets": [{"reps": 5, "weight": 185, "rir": 2}]}]}
  }]
}
```
Only **completed** sets are sent.

### 3.2 Server rules
- **Totals are recomputed from `payload.exercises`** when present; client
  `total_volume`/`total_reps` are used only for v1 payloads. Plausibility caps
  per session: ≤ 60 exercises, ≤ 40 sets per exercise, reps 1–100, weight
  0–1500 lb, volume ≤ 250,000 lb, duration ≤ 6 h, `performed_at` not in the
  future (+10 min) nor before 2020. A session over a cap is accepted for
  history but earns no XP/raid damage/quest progress and is flagged.
- **Idempotency:** a replay with the same or lower `client_rev` is
  **acknowledged** (its id is in `accepted`) without re-awarding anything.
- **Edits** (higher `client_rev`) adjust lifetime totals by the delta; XP is
  not re-awarded.
- **Deletes** (`deleted: true`) remove the session's contribution from
  lifetime totals, keep a tombstone row (`deleted=1`) so other devices learn
  about it, and never claw back XP.
- Each session's writes (session row, XP row, feed, quest progress, profile
  totals) commit atomically per session (`DB.batch`).
- PRs key on `exercise_id` when present, else the lower-cased trimmed name.
  The first-ever log of an exercise is a baseline, not a PR.

### 3.3 Response — CHANGED (additive)
Adds `cursor` (int) and fixes paging. `sessions` (pull) items:
`{id, performed_at, name, program_id, duration_secs, total_volume, total_reps,
xp_earned, client_rev, deleted, updated_at, payload}` ordered by
`(updated_at, id)` ascending, max 200 per call. **Clients set
`since = cursor`** (not `server_time`) and call again while `has_more` is true.
`cursor` is the last returned row's `updated_at` when `has_more`, else
`server_time`. Old clients that use `server_time` keep working for ≤200 rows.

---

## 4. Social and safety — NEW

| Method + path | Body | Response |
|---|---|---|
| POST `fitness/feed/:id/react` | `{emoji}` (💪 🔥 👏 🏆 ⚡) | `{success, reactions:[{emoji,count,mine}]}` — **toggles** (second tap removes) |
| GET `fitness/feed?before=<created_at>` | | adds `comment_count`, `reactions[].mine`; cursor paging, 50 per page |
| GET `fitness/feed/:id/comments` | | `{comments:[{id, user_id, display_name, level, text, created_at, is_self}]}` |
| POST `fitness/feed/:id/comments` | `{text}` 1–280 chars, filtered | `201 {comment}`; only self/friends/guildmates' items; 30 comments/hour/user |
| DELETE `fitness/comments/:id` | | own comment, or a comment on own item |
| POST `fitness/blocks` | `{user_id}` | blocks hide each other everywhere (feed, comments, leaderboards, search, players, friend requests); also removes any friendship |
| DELETE `fitness/blocks/:user_id` | | |
| GET `fitness/blocks` | | `{blocked:[{user_id, display_name}]}` |
| POST `fitness/reports` | `{target_type: user\|feed_item\|comment\|guild, target_id, reason}` | `201 {success}` — stored in `ugc_reports` for review (help@batesai.org) |

Feed/leaderboard/friends queries must not bind more than 90 ids in one `IN()`
(D1 limit 100) — use joins/subqueries on `friendships` instead.

## 5. Guilds — CHANGED

- Every guild has an `invite_code` (8 chars, A–Z2–9, no ambiguous letters),
  returned in GET guild to members.
- `GET fitness/guilds?q=` → `{guilds:[{id, name, motto, emblem, member_count,
  is_open}]}` (open guilds only, max 30; empty `q` = most active).
- `POST fitness/guild/join` accepts `{guild_id}` (open guilds) **or**
  `{invite_code}` (any guild). Max 50 members.
- `POST fitness/guild/invite_code/rotate` (owner/officer) → new code.
- `PUT fitness/guild` (owner) `{name?, motto?, emblem?, is_open?}` filtered.

## 6. Seasons — NEW

8-week seasons starting Mondays (UTC), defined in `_lib/seasons.js`
(deterministic from the date; Season 1 starts 2026-11-02). Season XP =
XP earned while the season is active.

- `GET fitness/season` → `{season:{id, number, name, theme, starts_at,
  ends_at, seconds_left, tiers:[{tier, xp_required, reward:{type:
  "title"|"cosmetic"|"streak_freeze"|"talent_point", value, label}}]},
  progress:{season_xp, tier, claimed:[tier]}, leaderboard:[top 20 {rank,
  user_id, display_name, level, season_xp, is_self}]}` — 30 tiers.
- `POST fitness/season/claim {tier}` → `{success, reward, profile}`;
  titles go to `earned_titles`, cosmetics to `earned_cosmetics`.
- Leaderboard `GET fitness/leaderboard?metric=season` supported.

## 7. Cosmetics / titles ownership

`earned_titles` = rank titles for levels reached + raid reward titles +
achievement titles + season titles. `earned_cosmetics` likewise (raid auras,
season auras). Stored in `fitness_unlocks (user_id, kind, value, source,
unlocked_at)`. Equipping a cosmetic: PUT profile `{cosmetic}` must be
earned (`null` to unequip); the equipped cosmetic is returned on profile,
player cards, feed items (`author_cosmetic`) and leaderboards.

## 8. Rate limits (fitness)
`POST ai` 20/day/user; comments 30/hour; reports 20/day; friend requests
50/day; search 60/min. Over → 429 `{error:"rate_limited", retry_after}`.
