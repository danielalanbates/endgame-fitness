# AI features archived 2026-11-16

Daniel asked to take AI generation out and build the app as normal software.
Every AI feature below was removed from the app and kept here verbatim.
None of them worked offline anyway: `FitnessAI.complete` already threw
"AI coaching isn't available in the offline, local-players version yet."

| File | What it was | Where it was wired |
|---|---|---|
| FitnessAI.swift.txt | `enum FitnessAI`: `complete`, `improveWorkout`, `buildMesocycle` (old `POST /api/fitness/ai` backend) | ProgramsMeso.swift, `// MARK: - AI service` |
| CustomBuilderAICoachReview.swift.txt | "AI Coach Review" card: `aiSuggestions/aiBusy/aiError` state, `aiSection`, `runAI()` | `CustomWorkoutBuilderView` in ProgramsMeso.swift, shown above "Save Program" |
| AIMesocycleBuilder.swift.txt | "AI Mesocycle Builder" card, its `.sheet`, and `AIMesocycleBuilderView` | `MesocycleView` in ProgramsMeso.swift (card above "Your Phases") |
| GenerateAIWorkout.swift.txt | `WorkoutManager.generateAIWorkout()` (fixed templates named "AI ...", no callers) | WorkoutTrackerMac_Enhanced.swift, after `setFullBodyProgram()` |

## What replaced them
- Programs tab "AI Generate Workout" -> "Quick Program Builder" (`QuickProgramQuestionnaireView`, was `AIWorkoutQuestionnaireView`). It was always fixed templates; only the name changed. Workout names lost the "AI " prefix.
- Mesocycle "AI Mesocycle Builder" -> "Start From a Template" card using `MesoPhase.template(goal:weeks:)` (deterministic). Hand-editable phases unchanged.
- Dashboard "AI Coach" card -> `TrainingInsightCard` ("Your Training"); it was always computed from logged history.

## How to restore
1. Paste `FitnessAI.swift.txt` back into ProgramsMeso.swift and point `complete` at a working backend.
2. Re-add the state vars, `aiSection` usage and functions from `CustomBuilderAICoachReview.swift.txt` into `CustomWorkoutBuilderView`.
3. Re-add `@State private var showAIBuilder = false`, the card, the sheet and `AIMesocycleBuilderView` into `MesocycleView`.
4. Build and run `-ef.selftest`.
