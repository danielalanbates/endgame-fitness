# Challenges (friend duels + guild challenges) and the Home "Today" cluster

Branch `feat/social`. Backend = Cloudflare Pages Function on D1; client = SwiftUI (macOS + iOS).

## Design

A challenge is a time window `[starts_at, ends_at)` over each participant's `workout_sessions`.
**Standings are never stored.** Every GET recomputes them from `workout_sessions` (pure math in
`App/Backend/functions/_lib/challenges.js`), so a late sync or an edited session is reflected
automatically and a modified client cannot inflate a counter.

- `kind`: `duel` (creator + one accepted friend) or `guild` (every current guild member enrolled at
  creation; late joiners are not enrolled). Guild challenges can only be started by owner/officer,
  one active per guild. Duels are one open (pending/active) per friend pair.
- `metric`: `volume` (sum of total_volume), `workouts` (session count), `streak` (longest run of
  consecutive UTC days with a session inside the window).
- Duel lifecycle: `pending` (created; only `opponent_id` may accept/decline) -> `active` (clock starts
  at accept for the originally requested `days`) -> `finished`. `declined` is terminal and hidden.
- Guild challenges start `active` immediately.
- Settlement is lazy: the first GET after `ends_at` claims the row with a conditional
  `UPDATE ... WHERE status='active'` (so two concurrent readers cannot double-award), decides the
  winner, inserts `xp_transactions` (`challenge_win|loss|draw|guild_top|guild_part`), bumps
  `fitness_profiles.xp` (+level/talent_points if a level boundary is crossed), and posts
  `activity_feed` items (`kind='challenge'`).
- XP: duel win 150 / loss 25 / draw 60 (a duel nobody trained in awards nothing); guild top 120,
  every member who logged something 20.

## Schema (appended to `App/Backend/schema.sql`, all IF NOT EXISTS)

`challenges(id, kind, metric, creator_id, opponent_id, guild_id, starts_at, ends_at, status,
winner_id, settled_at, created_at)` and `challenge_participants(challenge_id, user_id, joined_at)`.

## Endpoints (`/api/fitness/challenges`, Bearer session token)

| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `challenges` | – | `{pending, active, finished(<=10), server_time}`; each item has `standings[]` (`user_id, display_name, level, score, sessions, rank, is_self`), `awaiting_me`, `is_creator`, `winner_id`. Runs settlement for ended active rows. |
| POST | `challenges` | `{kind, metric, opponent_user_id?, days(1-30, default 7)}` | 201 `{challenge_id, status}`; 403 if not a friend / not officer; 409 if an open duel/guild challenge exists. |
| POST | `challenges/:id/accept` | – | opponent only; 403 for creator, 409 if not pending. |
| POST | `challenges/:id/decline` | – | opponent only. |

## Client

- `GameProfile.swift`: `Challenge` + `Challenge.Standing` models; `GameProfileService.loadChallenges()`,
  `createChallenge(kind:metric:opponentUserID:days:) -> String?` (error message or nil),
  `respondToChallenge(id:accept:)`; `active/pending/finishedChallenges` published; loaded in `loadAll()`.
- `ChallengeViews.swift`: `ChallengesView` (invites accept/decline, active with `HeadToHeadBar`, recent
  results), `CreateChallengeSheet` (friend picker from `game.friends` or guild), `LiveDuelCard`
  (compact, on Home), plus the Home cluster: `TodayCardCluster` (streak flame, `XPRing` XP-to-next-level,
  today's scheduled workout CTA -> `startScheduledWorkout`/`startNewWorkout`, `FriendsStrip` from the
  feed with a green dot for workouts < 90 min old, "See all" -> Community tab 7).
- `CommunityView` gained a `Challenges` segment (macOS split view and iOS Community tab both route
  through it). `DashboardView` gained the Today cluster at the top; nothing else in it was rewritten.

## Verified

- `swiftc -parse-as-library -target arm64-apple-macos14.0 *.swift` -> 0 errors, binary produced.
- `node --check` on `[[path]].js` and `_lib/challenges.js`.
- `node App/Backend/tests/challenges.test.mjs` -> 7 passed (window filtering, ties/ranks, streak math,
  duel win/draw/no-XP, guild awards, create validation — this caught a real bug: `days: 0` was
  silently defaulting to 7).
- `node App/Backend/tests/auth-verification.test.mjs` -> 12 passed.

## Not verified / undone

- Not deployed; schema not applied to remote D1 (`npx wrangler d1 execute batesai-db --remote --file=App/Backend/schema.sql`).
- No live end-to-end run against D1 (no local wrangler/D1 in this run); D1 handler logic is reviewed, not executed.
- iOS build not compiled locally (no iOS SDK on this machine); iOS-only code paths are `#if os(iOS)` guarded and mirror existing patterns.
- No push notifications for invites; invites appear on next `loadChallenges()`/tab open.
