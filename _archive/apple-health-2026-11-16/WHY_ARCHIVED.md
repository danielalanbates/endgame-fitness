# Apple Health / wearables — archived 2026-11-16

Daniel: "we're not gonna sync anything with peoples' wearables yet or apple health".

Removed from the app:
- `HealthKitManager.swift` (moved here unchanged)
- Dashboard `HealthCard` (steps + active energy) — `HealthCard.swift.txt`
- Settings "Apple Health" section (connect + save workouts to Health)
- Saving finished workouts to Apple Health
- Feeding Health steps into quests; the "Step Count" daily quest (definition kept in `GameRules.archivedQuests`)

To restore: move the file back into App/Sources/EndgameFitness, run xcodegen, and re-add the call sites from git history (commit that created this folder).
