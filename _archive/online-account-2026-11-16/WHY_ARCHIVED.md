# Why archived (2026-11-16)

Endgame Fitness moved from batesai.org accounts to **local players**: a
profile picker at launch, several players per device, no sign-in, and the
whole game (XP, levels, streaks, quests, achievements, talents, challenges,
raids, seasons, feed) computed on the device by `GameRules.swift` +
`LocalGame.swift`.

These files only make sense with a signed-in batesai.org member, so they were
taken out of the build instead of being kept behind a flag:

| File | What it was | Why it can't stay |
|---|---|---|
| `BatesAIAuth.swift.txt` | Email/password, Sign in with Apple, Google OAuth, token storage, the HTTP client for `/api/fitness/*` | Every call needs a session token; nothing core may require sign-in now. Making it "optional" would have meant keeping two copies of every game rule (server and device) in sync. |
| `AccountView.swift.txt` | Membership tier, sign out, delete batesai.org account | Replaced by a local `AccountView` (player edit, PIN, backup export/import, switch player, delete player). |
| `SignInView.swift.txt` | The sign-in screen cut out of `SocialViews.swift` | Replaced by `PlayerPickerView` (`LocalPlayerViews.swift`). |
| `GameProfileService-networked.swift.txt` | The service that synced sessions to `POST /api/fitness/sync` and read profile/quests/raids/... from the server | Replaced by `GameProfileService.swift` with the same API surface backed by `LocalGame`. |

Not lost: the server code in `App/Backend/functions` is untouched (it is the
reference the Swift port was checked against; `-ef.selftest` compares Swift
output with numbers produced by running those JS modules under node).

To bring accounts back later: restore these files, re-add a sync layer that
uploads `SessionRecord`s, and treat the server as a backup/leaderboard rather
than the rules engine.

Also removed from the running app: the AI coach (`FitnessAI` in
`ProgramsMeso.swift` now throws "not available offline"), because it called
`POST /api/fitness/ai` with the member's token.
