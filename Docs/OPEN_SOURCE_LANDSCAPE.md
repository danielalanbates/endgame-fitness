# Open-source fitness software landscape (checked 2026-11-17)

Research for Endgame Fitness: what exists, licences, and what we can learn or reuse.

## Summary 1

Checked 2026-11-17 against the GitHub REST API (stars, licence, last push) and the Codeberg and GitLab APIs. Partway through, the GitHub search API hit its rate limit, so the topic sweeps for 'fitness' and 'gym' are incomplete.

What the field looks like: many open-source workout loggers exist, but very few projects generate real training programs. Only about 5 serious ones do:
- **Liftosaur:** a scripting language (Liftoscript) for any progression or deload rule.
- **wger:** routines with per-week progression rules, plus the largest open exercise database (exercise data is CC-BY-SA).
- **streprogen:** a Python library that builds periodized programs with RM/% and rep-scheme progression.
- **Repstack:** a small, new, RP-style hypertrophy mesocycle progressive web app (feedback-based autoregulation, volume landmarks, deloads). It has 2 stars.
- **body.build:** a program maker based on Menno Henselmans' approach (Flutter, AGPL).

Small engines: routine-engine (MIT, movement-pattern block generator) and openweight (Apache-2.0 open JSON format for programs, templates and logs). There are many single-template 5/3/1, GZCLP and nSuns calculators and RPE calculators, all with fewer than 5 stars and mostly unlicensed. None of them is worth reusing.

Patterns:
1. The popular projects with many stars are loggers or self-hosted trackers: openGym, GymMane, workout-tracker, FitTrackee, Flex, lyftr, LiftLog, Iron. LiftLog's planner is an optional AI planner that needs its own server.
2. Workout.lol and its successor workout.cool (8.7k stars, MIT) pick exercises by muscle and equipment. They do not do periodization.
3. "AI coach" projects are a new wave in 2026: gymcoach, claude-gym-coach, suunto-gym and fitness-coach-rpg. They wrap a language model rather than using a deterministic engine.
4. Gamified fitness is almost entirely hobby or hackathon repos. The one serious, active example is Guiforge/bati, a dark-fantasy RPG (57 stars). Nothing combines real periodization with progression mechanics like XP and levels. That is the gap Endgame Fitness could fill.
5. Cardio and GPS trackers (FitoTrack, OpenTracks, RunnerUp, Feeel) do no strength programming.

Licences, for a PolyForm Noncommercial app:
- **Code under GPL/AGPL** cannot be copied in: Liftosaur, wger, streprogen, LiftLog, body.build, openGym, Iron, GymMane. Study their designs only and reimplement them yourself.
- **MIT, Apache and Unlicense are safe with attribution:** Repstack, routine-engine, workout.cool, workout.lol, openweight, Flex, free-exercise-db.
- **For exercise data, use free-exercise-db (public domain).** Avoid ExerciseDB media and the 'exercises-dataset' GIF repos (unclear rights). wger data carries share-alike obligations.
- **Unverified high star counts:** openGym (22k stars, repo created July 2026) and hasaneyldrm/exercises-dataset (23.8k) grew very fast. Treat those counts as possibly inflated.
- **Unverified FitoTrack licence:** it is shown as GPL-3.0 from memory. The Codeberg API call did not return its licence.
- **Not found:** no 'OpenLift' fitness project. That name belongs to unrelated router and elevator projects.

## Summary 2

Checked on 2026-11-17 with the GitHub API, plus HTTP 200 checks for the Codeberg, GitLab and F-Droid links. GitHub search hit its rate limit partway through, so the long tail was found through web search.

**Gamified fitness: one big habit RPG, then a long tail of tiny repos.** Habitica (about 14.3k stars, plus native iOS and Android clients) is the only mature open-source RPG-for-self-improvement project, and it is a habit tracker, not a training engine. It has no idea of sets, load or progression. Every real "fitness RPG" on GitHub is a solo or hobby project with 0 to 60 stars, often in a "Solo Leveling" anime style. Examples are Bati (57 stars), Monarch, SoloLeveling (iOS), QuestFit, LEVELR and gylleus/fitness-rpg. Recurring ideas:
- XP per set, rep, step or run, plus stat attributes (STR/VIT and so on).
- Ranks E to S, daily quests, dungeons or bosses, classes unlocked by level.
- Anti-cheat: camera pose checks, GPS checks, or XP computed on the server.

None of them pairs a real periodization or autoregulation engine with game mechanics. That gap is wide open and is where Endgame Fitness can stand out.

**Trackers are a crowded field with real progression in only a few.**
- Mature cross-platform loggers: LiftLog (MAUI), Flex (formerly Flexify, Flutter), wger plus its Flutter app, FastNFitness, LibreFit, GymRoutines (Codeberg), Iron (SwiftUI iOS, quiet since 2024) and its forks. Most only log sets and show graphs.
- Rule-based progression: Liftosaur (Liftoscript, AGPL, 782 stars, the most capable), wger (automatic progression rules), GymMane (F-Droid, adds rep or weight progression, deloads and stall tips), and streprogen (a Python library).
- No open-source project does RIR- or RPE-driven autoregulation or mesocycle volume landmarks the way RP Hypertrophy and Repstack do.
- iOS and macOS are thin. Iron is stale and newer SwiftUI repos have 0 stars, so a polished native Mac app has almost no open-source competitors.

**Self-hosted and web.** Workout.cool (MIT, about 8.7k stars) is the momentum leader for coaching platforms. SparkyFitness (about 6.8k stars, AI-heavy, family-focused), Ryot (tracks workouts among other media), Endurain and FitTrackee (both outdoor/GPS), jovandeginste/workout-tracker and wingfit cover self-hosting. GoldenCheetah leads endurance analytics.

**Social and competitive.** Very little exists. Habitica has parties, guilds and challenges. beaverfy/fitness-challenges is tiny. OpenPowerlifting/OpenLifter cover meet results and running meets, not social training. Accountless local or LAN social, as Endgame has it, has no open-source equivalent.

**Data.** free-exercise-db (Unlicense, about 2.1k stars) and wrkout/exercises.json (Unlicense) are public domain and safe to bundle. ExerciseDB API is AGPL.

**Licences against PolyForm Noncommercial.**
- Most strong projects are GPL or AGPL: Habitica, wger, Liftosaur, LiftLog, Iron, LibreFit, GymRoutines, openScale, Ryot, Endurain, FitTrackee. Their code cannot be copied into a closed or PolyForm-NC app. Only their ideas, user experience and maths can be reused.
- Code that can be reused with attribution: MIT (Workout.cool, Flex, Monarch, SoloLeveling, wael), BSD-3 (FastNFitness, beaverhabits), Apache-2.0 (fitness-challenges) and Unlicense (exercise datasets).

**Curated lists.** awesome-selfhosted "Health and Fitness" tag page (verified). woop/awesome-quantified-self. GitHub topic pages fitness-rpg and workout-tracker (both verified). The repo "awesome-health-fitness-oss" appears only in an awesome.ecosyste.ms index and could not be verified, so it is left out. No repo named "awesome-fitness" with real traction was found.

## Projects

| Project | Category | Licence | Stars | Last active | Programming depth | Notes |
|---|---|---|---|---|---|---|
| [Liftosaur](https://github.com/astashov/liftosaur) | program engine/scripting | AGPL-3.0 | 782 (2026-11-17) | 2026-11-17 | Deepest open engine. Liftoscript language lets any progression or deload rule be written; ships 5/3/1, GZCLP, Starting Strength, PPL programs; simple and advanced progression editors. | Best model for a program DSL and its progress/update hooks. AGPL, so learn the design and reimplement; do not copy code into a PolyForm NC app. |
| [wger](https://github.com/wger-project/wger) | self-hosted manager | AGPL-3.0 (code); exercise data CC-BY-SA-4.0 | 7,283 (2026-11-17) | 2026-11-16 | Moderate. Routines with per-iteration/week config and progression rules (weight, reps, sets, RIR changes over weeks); also nutrition and bodyweight. | Largest open exercise and translation database, available through its public API. Using the data brings CC-BY-SA attribution and share-alike duties. Do not copy AGPL code. |
| [streprogen](https://github.com/tommyod/streprogen) | program generator library | GPL-3.0 | 40 | 2026-11-15 | Real periodization. Generates multi-week programs from 1RM/%, rep-scaling functions, intensity and volume progression curves, and RM-based set/rep scheme optimisation. | Good reference for the maths of intensity and volume curves. GPL, so reimplement the formulas rather than vendoring the code. |
| [Repstack](https://github.com/wulfland/Repstack) | program engine/scripting (RP-style hypertrophy) | MIT | 2 | 2026-10-20 | RP-style. Program generator, 4-6 week mesocycles, scheduled deloads, autoregulation from pump/soreness/recovery feedback, volume landmarks, templates (upper/lower, PPL, full body). | MIT, so it is the most directly reusable mesocycle and autoregulation logic (keep the copyright notice). Very young project; verify the code quality. |
| [body.build](https://github.com/Dieterbe/body.build) | program engine/scripting | AGPL-3.0 | 40 | 2026-10-22 | Program maker built on Menno Henselmans' evidence-based method (volume per muscle, exercise anatomy/articulation model); tracker in progress. | Strong reference for muscle-volume accounting using an anatomy model. AGPL, so ideas only. |
| [routine-engine](https://github.com/sugarshaneaz/routine-engine) | program generator library | MIT | 2 | 2026-08-13 | Deterministic week builder: slots filled by movement pattern from available equipment, 4-week blocks (base, base, +1 set, deload), seeded pure-function exercise selection, splits scale with days/week. | MIT, small and readable. Its movement-pattern slots and equipment substitution are directly reusable ideas or code. |
| [openweight](https://github.com/radupana/openweight) | program format/standard | Apache-2.0 | 8 | 2026-03-03 | No engine. Schemas for Program, WorkoutTemplate (targets in reps, % and RPE), WorkoutLog and LifterProfile. | Worth adopting as an import/export format so Endgame programs are portable. Apache is compatible. |
| [LiftLog](https://github.com/LiamMorrow/LiftLog) | tracker/logger | AGPL-3.0 | 611 | 2026-11-16 | Light. Plans with simple progression; AI planner needs a self-hosted server or Pro; documented .liftlogplan file format. | Its end-to-end encrypted, accountless social feed is close to Endgame's accountless social model and worth studying. AGPL, so do not copy code. |
| [workout.cool](https://github.com/Snouzy/workout-cool) | program generator / coaching platform | MIT | 8,694 | 2026-11-02 | Light to moderate. Builds workout plans from an exercise database, by muscle and equipment; progress tracking; no real periodization engine. | Successor to workout.lol by the same author. MIT, so UI flows and the exercise picker are reusable with attribution. |
| [workout.lol](https://github.com/workout-lol/workout-lol) | program generator (simple) | MIT | 1,572 | 2024-09-27 | Minimal. Picks exercises for selected muscles and equipment; no progression. | Dormant and superseded by workout.cool. Its muscle-map picker UI is MIT. |
| [free-exercise-db](https://github.com/yuhonas/free-exercise-db) | exercise database | Unlicense (public domain) | 2,146 | 2026-09-27 | None (data only: 800+ exercises with muscles, equipment, level, instructions, images) | Safest exercise data and images to bundle in a PolyForm NC app; no obligations. |
| [exercemus/exercises](https://github.com/exercemus/exercises) | exercise database | MIT | 52 | 2025-07-31 | None (exercise list merged from exercemus, wger and exercises.json) | Repo is MIT, but some content comes from wger (CC-BY-SA). Check where each record came from before bundling it. |
| [ExerciseDB API](https://github.com/ExerciseDB/exercisedb-api) | exercise database | AGPL-3.0 (code); media separately licensed | 766 | 2025-11-25 | None | Avoid bundling its GIFs and media. The many 'exercises-dataset' GIF repos, such as hasaneyldrm/exercises-dataset (23.8k stars, no licence stated), probably share that media and have unclear rights. |
| [openGym](https://github.com/DuarteSantos8/openGym) | self-hosted manager / tracker | AGPL-3.0 | 22,433 (repo created 2026-07-18; growth unusually fast) | 2026-11-17 | Logger and bodyweight tracker with routines; no evident periodization engine | The star count may be inflated. Useful as a reference for the self-hosted and Watch user experience. AGPL. |
| [GymMane](https://github.com/InlitX/GymMane) | tracker/logger | GPL-3.0 | 1,805 | 2026-11-16 | Logger with routines; no generator | Offline, no-account approach. GPL. |
| [workout-tracker](https://github.com/jovandeginste/workout-tracker) | self-hosted manager | Not stated by the GitHub API (NOASSERTION) | 1,253 | 2026-11-17 | None. Mostly GPS/cardio workouts for family and friends. | Not a programming tool. |
| [FitTrackee](https://github.com/SamR1/FitTrackee) | self-hosted manager / wearable-cardio | AGPL-3.0 | 1,177 | 2026-11-04 | None (outdoor activity tracker) | Cardio only. |
| [Flex](https://github.com/brandonp2412/Flex) | tracker/logger | MIT | 458 | 2026-11-16 | Logger with plans, graphs and rest timers; no autoregulation | MIT, so its rest timer and graph UI can be reused. Successor to brandonp2412/Massive (archived, GPL). |
| [lyftr](https://github.com/Cawlumm/lyftr) | self-hosted manager | MIT | 375 | 2026-11-16 | Logger plus nutrition; no generator | MIT; shows the self-hosted demand. |
| [gymcoach](https://github.com/gymcoach-app/gymcoach) | tracker with AI coach | MIT | 196 | 2026-11-17 | An AI coach using your own language model reads your log and suggests training; no deterministic engine | Example of the 2026 AI-coach trend. MIT. |
| [LiftTrace](https://github.com/TraceApps/lifttrace) | self-hosted manager | AGPL-3.0 | 126 | 2026-11-16 | Logger | Logger only. |
| [Iron](https://github.com/karimknaebel/Iron) | tracker/logger | GPL-3.0 | 234 | 2024-11-17 | Logger with workout plans | Native SwiftUI reference, relevant if Endgame goes native on Apple platforms. GPL; dormant. |
| [wingfit](https://github.com/itskovacs/wingfit) | self-hosted manager | CC BY-NC-SA 4.0 (per README; GitHub API shows NOASSERTION) | 538 | 2025-08-11 | Workout planning calendar, personal records, smartwatch data; no generator | Non-commercial, but share-alike, so do not mix it into a PolyForm-licensed codebase. |
| [Bati](https://github.com/Guiforge/bati) | gamified fitness | Not stated by the GitHub API (NOASSERTION) | 57 | 2026-11-17 | Light; RPG wrapper around workouts | Closest active gamified competitor. Licence unclear, so treat as all rights reserved. |
| [fitness-coach-rpg](https://github.com/k1ein-chen/fitness-coach-rpg) | gamified fitness / AI skill | MIT | 102 | 2026-11-16 | AI-generated coaching plus training records | MIT; ideas for tying stats and story progression to training. |
| [OpenLifter](https://gitlab.com/openpowerlifting/openlifter) | meet management | AGPL-3.0 | 22 (GitLab) | 2026-07-18 | None (runs powerlifting meets) | Out of scope. Listed because 'OpenLift' does not exist as a fitness project; the name belongs to unrelated router and elevator repos. |
| [Feeel](https://gitlab.com/enjoyingfoss/feeel) | bodyweight home-workout app | AGPL-3.0 | 111 (GitLab; GitHub mirror EnjoyingFOSS/feeel 112) | 2026-08-25 | Fixed and custom timed bodyweight routines; no progression | Its CC-licensed exercise images and guided-timer user experience are a reference. |
| [FitoTrack](https://codeberg.org/jannis/FitoTrack) | wearable/cardio | GPL-3.0 (not confirmed by the API in this check) | 440 (Codeberg) | 2026-11-12 | None (GPS tracking) | Cardio only. |
| [OpenTracks](https://codeberg.org/OpenTracksApp/OpenTracks) | wearable/cardio | Apache-2.0 | 150 (Codeberg); GitHub repo archived with 1,399 stars | 2026-11-10 | None | Cardio only. Apache is compatible if sensor or Bluetooth heart-rate code is ever needed. |
| [RunnerUp](https://github.com/jonasoreland/runnerup) | wearable/cardio | GPL-3.0 | 967 | 2026-11-08 | Interval workout builder for runs | Cardio interval builder; GPL. |
| [proof-531](https://github.com/alexcheuk/proof-531) | 5/3/1 calculator/tracker | Not stated by the GitHub API (NOASSERTION) | 4 | 2026-07-18 | Single template (5/3/1 plus Boring But Big), training-max cycles | Best of the many tiny 5/3/1, GZCLP and nSuns calculators. All have fewer than 5 stars and most are unlicensed. Write templates yourself instead. |
| [zack/rpe](https://github.com/zack/rpe) | RPE/autoregulation calculator | AGPL-3.0 | 4 | 2026-11-14 | RPE/e1RM chart calculator only | RPE tables are public-domain knowledge (Tuchscherer/RTS chart); implement them directly. No meaningful open periodization library exists beyond streprogen. |
| [Habitica (server + habitica-ios + habitica-android)](https://github.com/HabitRPG/habitica) | gamified fitness / habit RPG | GPL-3.0 code (GitHub shows NOASSERTION because of mixed art licences); iOS and Android clients GPL-3.0 | ~14.3k (iOS 860, Android 1.8k), 2026-11-17 | 2026-11-17 | None for training. Habits, dailies and to-dos earn XP, gold and drops; missed dailies cost HP; parties, quests, bosses, guilds, challenges. | The reference design for social accountability: a missed daily hurts the whole party. Copyleft, so borrow mechanics only. https://github.com/HabitRPG/habitica-ios and https://github.com/HabitRPG/habitica-android |
| [Monarch](https://github.com/pronzzz/monarch) | gamified fitness | MIT | 0, 2026-11-17 | 2026-10-20 | Low. Converts steps, training, sleep, meals and study into XP | MIT, so its XP and stat formulas can be reused with attribution. A good template for class unlocks. |
| [SoloLeveling (DecodedXR)](https://github.com/DecodedXR/SoloLeveling) | gamified fitness | MIT | 0, 2026-11-17 | 2026-09-30 | Low; checks performed work rather than prescribing it | The only native-Apple open-source fitness RPG found. Its anti-cheat idea is relevant to Endgame's local and social leaderboards. MIT. |
| [QuestFit](https://github.com/Jala-AnirudhSai/questfit) | gamified fitness / social | none stated | 0, 2026-11-17 | 2026-11-08 | Logging only | Co-op boss battles from shared workouts fit Endgame's accountless social features. No licence, so ideas only. |
| [FastNFitness](https://github.com/brodeurlv/fastnfitness) | tracker/logger | BSD-3-Clause | 322, 2026-11-17 | 2026-11-15 | Low. Body, cardio and strength logging | Permissive licence. A long-lived, simple Android logger. |
| [LibreFit](https://github.com/LibreFitOrg/LibreFit) | tracker/logger | GPL-3.0 | 249, 2026-11-17 | 2026-10-03 | Low-medium. Logs set, rep, rest and load; workout planning | A newer privacy-focused F-Droid app. GPL, ideas only. |
| [GymRoutines](https://codeberg.org/noahjutz/GymRoutines) | tracker/logger | GPL-3.0 | unknown (Codeberg) | F-Droid repo update 2025-04-22 | Low. Routines and statistics | Lives on Codeberg. Clean Compose reference. GPL. |
| [GymMane](https://f-droid.org/packages/com.gymmane.app/) | tracker/logger with progression | GPL-3.0-only (per F-Droid) | unknown (source repo not located; F-Droid page verified) | F-Droid update ~Nov 2026 | Medium. Automatic rep or weight progression rules, deload weeks, stall-triggered deload tip | The most progression-aware F-Droid tracker after wger. Stall detection is a feature Endgame should match. |
| [Ryot](https://github.com/IgnisDa/ryot) | self-hosted manager | GPL-3.0 | ~3.7k, 2026-11-17 | 2026-11-17 | Low-medium. Workout logging, templates, measurements, among other media tracking | Popular general life tracker with a solid fitness module. Ideas only. |
| [SparkyFitness](https://github.com/CodeWithCJ/SparkyFitness) | self-hosted manager | NOASSERTION (custom) | ~6.8k, 2026-11-17 | 2026-11-17 | Low-medium. Food, exercise and health tracking for families; AI features | Shows strong demand for a family-shared fitness tracker, similar to Endgame's local multi-player angle. Relies on AI, unlike Endgame. |
| [Endurain](https://github.com/endurain-project/endurain) | wearable/cardio | AGPL-3.0 | ~2.4k, 2026-11-17 | 2026-11-17 | Low (activity tracking, imports) | Self-hosted Strava alternative. Not strength-focused. |
| [openScale](https://github.com/oliexdev/openScale) | tracker/logger (body metrics) | GPL-3.0 | ~2.7k, 2026-11-17 | 2026-11-17 | None (body weight and composition) | Reference for Bluetooth scale protocols if Endgame adds body-weight import. |
| [GoldenCheetah](https://github.com/GoldenCheetah/GoldenCheetah) | wearable/cardio analytics | GPL-3.0 | ~2.3k, 2026-11-17 | 2026-11-16 | High for endurance (PMC/CTL/ATL training load, power models) | The established open-source model for fatigue and fitness load (Banister impulse-response, PMC). Worth borrowing the ideas for strength fatigue modelling. |
| [Loop Habit Tracker](https://github.com/iSoron/uhabits) | habit tracker | GPL-3.0 | ~10.4k, 2026-11-17 | 2026-10-22 | None | Its habit-strength formula is a forgiving alternative to brittle streaks, good for consistency mechanics. |
| [Beaver Habits](https://github.com/daya0576/beaverhabits) | habit tracker | BSD-3-Clause | ~1.9k, 2026-11-17 | 2026-11-16 | None | Permissive licence. A contrast to the gamification-heavy approach. |
| [fitness-challenges (beaverfy)](https://github.com/beaverfy/fitness-challenges) | social/competitive fitness | Apache-2.0 | 2, 2026-11-17 | 2025-09-17 | None | One of the very few open-source social-challenge projects, which shows the space is empty. Permissive licence. |
| [awesome-selfhosted: Health and Fitness tag](https://awesome-selfhosted.net/tags/health-and-fitness.html) | curated list | CC-BY-SA-3.0 (list) | main repo ~338k, 2026-11-17 | 2026-11-16 | N/A | Lists wger, Endurain, FitTrackee, Dreeve and others. Also see woop/awesome-quantified-self (~2.8k stars) and https://github.com/topics/fitness-rpg and https://github.com/topics/workout-tracker. |
