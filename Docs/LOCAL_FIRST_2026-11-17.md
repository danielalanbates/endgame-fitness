# Local-first training and mobile parity — 2026-11-17

Copyright © 2026 Daniel Bates / Bates LLC. All rights reserved.
Contact: https://batesai.org · help@batesai.org

## Source and scope

The baseline is main at e667b52, the merge of PR #5 (`sync-drive-2026-11-17`).
Direct Google Drive access was unavailable in this environment; no claim is made
that its code folder was directly inspected or updated. All work is in the Linux
/workspace checkout, with no writes to Daniel's Mac. The existing LICENSE already
contains PolyForm Noncommercial and the 10% commercial rider; it is preserved.

## Delivered behavior

- Native launch opens local training without mandatory membership. Saved
  `userProfile.v1` answers repair a missing onboarding-completed flag.
- Online membership restore happens when Community is opened. New signed-out
  native workouts stay in WorkoutManager instead of queuing for a later account.
  Previously queued online workouts are retained. Signed-in workouts still sync.
- Native slider positions at exactly zero survive relaunch; scheduled workouts
  no longer prefill 135 lb. Community buttons have 44 pt minimum touch heights.
- `/fitness/` opens a local web profile, equipment/goal-based full-body plans,
  workout logging, local XP, a weekly consistency goal, history and sharing.
- Active web sets persist before the UI acknowledges a change and survive
  navigation and reload. Editing a set clears its completion check.
- JSON backups restore validated profiles/history/drafts after confirmation.
  Invalid stored JSON is preserved for recovery instead of overwritten.
- Old online features remain in App.tsx through an explicit online-account entry.
  No existing membership or server data is deleted or automatically migrated.
- Service-worker cleanup only removes caches belonging to Endgame Fitness.

## Programming rules and limits

`src/localTraining.ts` is the pure rule layer. Plans alternate full-body A/B,
cover knee/hip/push/pull-or-shoulder-control/core, and start at 2–3 working sets.
Higher weekly frequency reduces sets per session. Strength uses six reps with
loads; muscle uses ten; fitness uses twelve. Loads start at zero, not an invented
strength estimate. Next-load suggestions add 2.5% only when every prior set is
complete at the current target. Users choose an available, appropriate increment.

This is a transparent starting template, not proof of superiority to a coach or
an individually authored plan. Advanced users currently receive the same basic
structure, and bodyweight prone raises are explicitly not a loaded pulling
substitute. Training recommendations need further development and evaluation:
recovery/readiness, injury constraints, periodization, exercise substitution,
fatigue models, unit conversion, and progression based on effort ratings.

Local XP uses 50 completion XP plus 10 per completed set, capped at 250 total;
levels use quadratic thresholds. It is deliberately separate from server-ranked
XP and never submitted as trusted ranking evidence. Rest-day messaging avoids
making the displayed consecutive-day streak a requirement to train every day.

## Verification

| Check | Result |
| --- | --- |
| TypeScript + production Vite build | Passed |
| Local rules tests | 6 passed; includes 108 plan combinations |
| Existing backend tests | 63 passed (auth, quests, talents, challenges, raids) |
| Chromium functional smoke | Passed |
| 5 tabs × 4 widths (320/390/768/1280) | No horizontal overflow |
| Reload recovery, profile changes, backup round trip | Passed |
| Corrupt local storage preservation + restore | Passed |
| Native Apple platform compilation / runtime | Not available on Linux; pending CI/Xcode |
| HealthKit, notifications, haptics, native sharing | Not exercised |
| Facebook integration / account-free multiplayer | Not implemented |

Run from Web/fitness-pwa:

```sh
npm ci
npm test  # Node 22.18+ or 24 (native TypeScript stripping)
npm run build
npm run dev -- --host 0.0.0.0
# Separate shell, with Playwright installed outside the project if desired:
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node tests/browser-smoke.mjs
```

The browser script expects Chromium at `/usr/bin/chromium`, uses synthetic data,
writes only /tmp test backups/screenshots and closes its browser. It runs once;
it is not an automated takeover or repeating test loop.

## Follow-up pathways

1. Compile and exercise every native screen on iPhone and Mac; validate local
   onboarding recovery, sign-out, membership restore and offline training.
2. Add an explicit export/migration bridge from an existing server account into
   the local web profile; never guess or overwrite personal training answers.
3. Bring native local quests/progression to parity with local web progression.
4. Choose an optional social transport: native share cards first; opt-in friend
   connections second. Facebook linking requires credentials and product review.
5. Add local data conflict handling for simultaneous browser tabs and IndexedDB
   for larger histories; localStorage is currently synchronous and device scoped.
6. Keep public releases separate from betas. No release or native .app is
   claimed until native build and feature validation complete. No private mirror
   was created or overwritten because no current private app target was established.

## CI and deployment findings

- Native CI initially exposed a Swift type-check timeout in Community. The view
  is split into smaller properties, and its macOS path now uses the shared
  platform background instead of an iOS-only color initializer.
- iOS CI then exposed an obsolete Xcode 16.2 pin whose simulator SDK no longer
  matches installed runner runtimes. CI now uses the runner's default Xcode,
  builds each target once, and packages a macOS beta .app artifact on success.
- The website source/build was merged in website PR #14. The original cross-repo
  deployment failed to read the private website repo; a workflow in website
  removes that cross-repo dependency.
- The replacement website deployment run 44147908316 did not start: GitHub's
  annotation reports failed account payments or an exhausted spending limit.
  Local wrangler also reports no authentication. Live publication is blocked;
  no successful production deployment is claimed. The website workflow requires
  CLOUDFLARE_API_TOKEN in that repo's Actions secrets once billing is resolved.
