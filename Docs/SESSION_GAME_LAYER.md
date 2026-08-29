# Session Game Layer ("combat log")

_Added 2026-08-29. Client-only. Source: `App/Sources/EndgameFitness/SessionGameLayer.swift`._

Makes the live workout feel like a game: rest countdown after every set,
floating XP / PR / Combo pop-ups, and a shareable summary card on finish.

## What it does

| Feature | Where | Notes |
|---|---|---|
| Rest timer | `RestTimerBar` above the exercise list | Auto-starts on set log. Default 90 s (`defaultRestTime`, same key as the existing Settings field). Per-exercise override via the timer field on each exercise card (`sessionGame.rest.<name>`). -15 / +15 / Skip. |
| iOS background notification | `SessionGame.scheduleRestNotification` | "Rest over — next set". Permission requested lazily the first time a rest timer starts. Scheduled up front; iOS does not present it while the app is frontmost (no UN delegate), and it is cancelled when the timer ends in-app. macOS: none. |
| Haptics | `Platform.impact(_:)`, `Platform.success()`, `Platform.tick()` | iOS only. Medium impact per set, success on PR and rest end, light tick in the last 3 s. Toggle `sessionGame.haptics`. |
| Sound | `Platform.beep()` at rest end | Off by default (`sessionGame.restSound`). |
| XP pop-ups | `XPPopupOverlay` over the session scroll view | "+N XP" rises and fades 1.8 s. "PR!" when Epley e1RM beats every prior set of that exercise name in local history. "Combo xN" for N >= 2 consecutive sets hitting the planned rep target (first un-logged planned set's reps, else median of logged reps, else 8). Combo resets on a missed target. Toggle `sessionGame.xpPopups`. |
| Running XP badge | `SessionXPBadge` in the header | "N XP est." plus combo multiplier. |
| Summary | `SessionSummaryView` sheet after the existing celebration | Volume, sets, duration, est. XP, PRs, streak, share card. |
| Share card | `ShareCardView` rendered via `ImageRenderer` (2x) | macOS: Copy to pasteboard (`Platform.copyImageToPasteboard`). iOS: `ShareLink`. |
| Settings | `SessionGameSettingsSection` inside `SettingsView` | Rest timer on/off, XP pop-ups, haptics, rest sound. All `@AppStorage`. |

## XP is an estimate

XP is awarded server-side (`Backend/functions/api/fitness/[[path]].js`,
`xpForWorkout`). `XPEstimator` mirrors that formula exactly
(`volume^0.8 * 0.35 + reps * 0.5 + min(minutes, 120) * 1.5`, floor 10). Per-set
pop-ups show the marginal volume+rep contribution of that set. Every place the
number appears says "est." and the summary states that the profile updates on
sync. If the server formula changes, change `XPEstimator.sessionXP` too.

## Hooks in `WorkoutTrackerMac_Enhanced.swift`

All tagged `// SessionGameLayer hook`:

- `startNewWorkout` / `startScheduledWorkout`: `SessionGame.shared.sessionStarted()`.
- `addSetToExercise`: calls `SessionGame.shared.setLogged(...)`. **Also removed a
  broken guard** (`sessions.firstIndex(where: currentWorkout?.id)`) that always
  failed because an active workout is only appended to `sessions` on
  completion, so "Add Set" silently did nothing before.
- `completeWorkout`: sets `workout.duration` (was never set; the server received 0).
- `WorkoutView`: `SessionXPBadge` in header, `RestTimerBar` above exercises,
  `.overlay(XPPopupOverlay())`, summary snapshot in the celebration `onComplete`,
  `.sheet(item: $sessionSummary)`.
- `ExerciseCard`: `ExerciseRestOverride` field; removed the legacy
  `RestTimer(duration: 90)` (it was never displayed, only beeped).
- `SettingsView`: `SessionGameSettingsSection()`.

`Platform.swift` gained `PlatformImage`, `Platform.impact(_:)`, and
`Platform.copyImageToPasteboard(_:)`.

## Verification

- `swiftc -typecheck` passes for macOS 14 and iOS 17 simulator (2026-08-29).
- **Not run on any device or simulator.** Animations, notification delivery,
  haptics, ShareLink and pasteboard behaviour are unverified.
