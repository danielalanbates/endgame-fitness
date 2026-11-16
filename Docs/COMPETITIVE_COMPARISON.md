# Endgame Fitness vs RP Hypertrophy vs Boostcamp — Enhanced Comparison (2026-09-04)

**Source:** Initial comparison dated 2026-09-02, verified against Swift source (where iCloud lock permits), expanded with RP/Boostcamp research.

## Executive Summary

Three distinct positioning strategies in the workout tracking/programming space:

| Competitor | Primary Moat | Audience | Price Model |
|---|---|---|---|
| **RP Hypertrophy** | Algorithmic autoregulation (MEV/MRV volume feedback loops) | Hypertrophy-focused lifters wanting science-backed progression | ~$29.99/mo (or $299.99/yr) |
| **Boostcamp** | Content distribution (100+ creator programs) + logger | Program followers (beginners to advanced) | Free core + $9.99/mo premium |
| **Endgame Fitness** | Gamification layer (RPG mechanics) + LLM program builder | Competitive/social lifters, novelty-seeking audience | TBD (TestFlight, not shipped) |

---

## Detailed Feature Analysis

### Training Science & Progression (Autoregulation)

#### RP Hypertrophy
- **Core mechanism:** Set-by-set feedback loop
  - After each set: user logs effort, soreness, pump, joint comfort, and subjective difficulty
  - Algorithm adjusts *next session's* sets/reps/weight based on cumulative feedback
  - Per-muscle volume landmarks (MEV/Minimum Effective Volume → MAV/Maximum Adaptive Volume → MRV/Maximum Recoverable Volume)
  - Ramps volume across 3–6 week mesocycles with automatic deload
- **Strength:** This is literally the product — decades of Mike Israetel research operationalized
- **Limitation:** Requires user discipline in pre/post-set logging; algorithm is proprietary black box

#### Boostcamp
- **Mechanisms offered by different programs:**
  - Program-defined progression (linear, wave-based %, AMRAP-driven)
  - Some programs include RPE/RIR targets; logging captures RPE/RIR if present
  - Custom program builder allows designers to set progression math
- **Strength:** Flexibility — thousands of programs = thousands of progressions
- **Limitation:** No *automatic* adjustment; depends entirely on program designer; no biofeedback loop

#### Endgame Fitness
- **Current method:** `estimateWeight()` → previous weight + 5 lb ($2 base increment)
- **Roadmap (false):** Claims post-workout questionnaire and feedback loop; source inspection shows **zero TTS, zero questionnaire, zero feedback loop**
- **Strength:** Simplicity; rapid logging for game XP focus
- **Critical gap:** Without per-set effort data or volume tracking, impossible to implement proper autoregulation

**Winner:** RP Hypertrophy (the defining product); Boostcamp second (program-dependent, good variety); Endgame lacks the science layer entirely.

---

### Program Design & Templates

#### RP Hypertrophy
- **16 base hypertrophy templates** (upper/lower splits, PPL variants, full-body)
- **Templates are pre-periodized:** 3–6 week blocks with defined volume ramps and built-in deloads
- **Customization:** Muscle emphasis filters (stronger/weaker muscle groups), frequency presets
- **Exercise selection:** Pre-populated with exercise subs per program; ~250+ exercise library
- **User role:** Log feedback → algorithm generates next week

#### Boostcamp
- **100+ pre-built programs** including:
  - Classics: GZCLP, 5/3/1, Starting Strength, Wendler variants
  - Creator programs: Jeff Nippard, Layne Norton, Mike Israetel, John Meadows, etc.
  - Strength, hypertrophy, powerlifting, Olympic lifting, conditioning focus
- **Custom program builder:** Full GUI for designing programs from scratch
  - Define exercises, sets/reps targets, progression rules, deload weeks
  - Share with community
- **Community curation:** Programs voted up by users; trending programs highlighted

#### Endgame Fitness
- **16 presets + 11 style modulators** (hard/steady/endurance/powerlifting/conditioning)
- **4-step wizard:** Duration → muscle emphasis → intensity → equipment
- **Periodization:** Phases (hypertrophy → strength → endurance) editible but **don't drive the schedule**
  - Phase logic changes *suggested* sets/reps + tip text only
  - Actual workout schedule persists unchanged; phases are cosmetic
- **Exercise library:** 48 hand-coded exercises (name + difficulty string)
  - No videos, no equipment tags, no substitutions, no search
- **LLM builder:** Backend `build_mesocycle()` calls Claude to generate 4–12 week block given user preferences; code path exists and is real

**Winner:** Boostcamp (sheer content volume + full custom builder) > RP (polished, pre-periodized) > Endgame (limited library; wizard generates but doesn't adapt; phases are decorative).

---

### Exercise Library & Reference

| Dimension | Endgame | RP | Boostcamp |
|---|---|---|---|
| Exercise count | ~48 hardcoded | 250+ | 400+ |
| Videos | ❌ none | ✅ form videos | ✅ demo videos |
| Equipment tags | ❌ | ✅ (dumbbell, barbell, machine, cable, etc.) | ✅ |
| Substitutions | ❌ | ✅ (e.g., barbell bench → dumbbell bench → machine press) | ✅ |
| Search | ❌ | ✅ (by muscle, equipment, difficulty) | ✅ (by muscle, category) |
| Notes/cues | ❌ (only difficulty) | ✅ (form cues) | ✅ (exercise notes) |

**Verdict:** Boostcamp/RP vastly superior; Endgame library is show-level only.

---

### Session Logging & Feedback

#### RP Hypertrophy
- **Per-set capture:**
  - Reps, weight, target RIR
  - *Post-set prompt:* soreness (0–10), pump (0–10), perceived difficulty vs. target RIR, joint discomfort
- **Real-time cues:** Indicates if session is tracking RIR targets
- **Post-workout summary:** Volume load (tonnage), average effort, vs. session history

#### Boostcamp
- **Per-set capture:**
  - Reps, weight
  - Optional: RPE/RIR (if program defines targets)
  - Set type: warmup, working, drop, myo-reps, AMRAP
  - Notes field (freeform)
- **Program alignment:** Shows target vs. achieved for each set
- **History:** Stores complete session, allows edit/redo

#### Endgame Fitness
- **Per-set capture:**
  - Reps, weight, completed ✓
  - No RIR, no RPE, no effort feedback
- **Special logic:**
  - PR detection (Epley e1RM callouts)
  - Rest timer auto-start (90s default, ±15s, per-exercise override)
  - XP calculation based on reps + weight (hardcoded formula)
  - Combo counter (consecutive sets without failure)
  - Level-up overlay on session completion
- **No post-workout feedback loop:** Logging is write-only; doesn't influence future sessions

**Winner:** RP (tight feedback loops, autoregulation) > Boostcamp (flexible per-program) > Endgame (game focus, no science).

---

### Cross-Device Sync & Cloud Architecture

#### RP Hypertrophy
- **Cloud-first:** All data synced to RP servers
- **Platforms:** iOS, Android, web
- **Session sync:** Real-time; seamless switching between devices
- **Account model:** Email/social login; subscription-tied account

#### Boostcamp
- **Cloud-first:** All data synced to Boostcamp servers
- **Platforms:** iOS, Android
- **Session sync:** Automatic via cloud; no local-only mode
- **Account model:** Email/social login; free tier uses device ID (no account needed initially), but login enables sync

#### Endgame Fitness
- **Local JSON per device:** Workout history stored in `/App Group/shared-workouts.json` per device
  - iOS and macOS do NOT sync history between each other
  - Only game profile (XP/levels/talents) syncs via old online backend
- **Consequence:** A user with iPhone + Mac sees different workout history on each device; terrible UX for a "native macOS" claim
- **Backend exists but unused for fitness data:** old online backend handles auth + game state; fitness data never sent to cloud

**Winner:** RP/Boostcamp (seamless cross-device) >> Endgame (broken by design).

---

### Gamification & Social Features

#### RP Hypertrophy
- **None** (pure algorithm-driven coaching)
- Philosophy: data-driven, not engagement-driven

#### Boostcamp
- **Streaks/badges:** Track workout consistency
- **Leaderboards:** Community-wide leaderboards per program
- **Program communities:** Followers of popular programs can see others' progress
- **No in-app challenges, raids, or competitive PvP**

#### Endgame Fitness
- **Unmatched in this space:**
  - **XP/leveling system:** Gain XP per set; level up with overlay animation
  - **Talent tree:** ~60 talents across 6 trees (Strength, Hypertrophy, Endurance, Recovery, Social, Mastery)
    - Respec available at cost (in-game currency)
    - Effects are cosmetic or stat-buff (e.g., "+5% XP gain", "+10s rest time default")
  - **Daily quests:** "Complete 3 sets of squats", "Walk 10k steps", "Hit chest volume target"
  - **Guild raids:** Multi-week server events where players hit fitness targets to defeat boss (HP pool damage is summed raid-wide)
  - **1v1 XP duels:** Challenge another player to out-XP them over a week
  - **Share cards:** Screenshot progress (reps, weight, PR) as shareable image
  - **Combo counter:** Consecutive sets without rep failure; resets on failure; feeds XP bonus
  - **Achievements:** Unlock badges (e.g., "First PR", "100 XP in session")
  - **Feed + reactions:** Post workouts to social feed; others can react (👍, ❤️, 💪, 🔥)
  - **Friends list:** Add by friend code or email; see their feed, join their guild

**Verdict:** Endgame is the *only* app in this trio (or Fitbod, Hevy, Strong) with a true RPG layer. RP/Boostcamp are purely functional.

---

### Wearables, Integrations, & Health Ecosystem

#### RP Hypertrophy
- **Apple Health:** Logs workouts (export)
- **Apple Watch:** Companion app (view workouts, receive cues)
- **Wearables:** Reads HR data if available (passive)
- **Third-party:** No Strava, Whoop, Garmin explicit integrations (but standard Health/Watch ecosystem)

#### Boostcamp
- **Apple Health:** Sync strength workouts
- **Apple Watch:** Companion app (view in-progress workout, edit sets)
- **Wearables:** Standard Health/Watch integration
- **No explicit Whoop/Garmin/Strava integrations**

#### Endgame Fitness
- **HealthKit read (narrow scope):**
  - Reads: Steps, active energy, body mass (requested but never queried — dead code)
  - Writes: Strength workouts (standard format)
  - Status: iOS only; untested on device
- **Apple Watch:** No Watch app
- **Wearables:** No integration layer
- **Avatar system:** Reads HR during avatar display (proof of concept) but never invoked from main app
- **Assessment:** Feature-gated but non-functional; roadmap claims not met

**Winner:** RP ≈ Boostcamp (basic ecosystem) >> Endgame (untested, partial).

---

### Platforms & Native Support

#### RP Hypertrophy
- iOS, Android, web (responsive)
- No desktop native app

#### Boostcamp
- iOS, Android
- No web or desktop

#### Endgame Fitness
- **iOS:** Native SwiftUI (TestFlight 1.0.0(6), invite unaccepted as of Sep 4)
- **macOS:** Native native SwiftUI, 14.0+ (unique among the three; only Endgame has desktop)
- **Android/web:** None
- **Status:** Both apps in TestFlight; builds valid but unshipped

**Verdict:** Endgame's macOS advantage is neutralized by workout sync failure (local JSON per device).

---

### Authentication & Privacy

#### RP Hypertrophy
- Email + social (Google, Apple)
- Standard OAuth2

#### Boostcamp
- Email + social
- Standard OAuth2

#### Endgame Fitness
- **Sign in with Apple** (native, secure)
- **Google auth** (secret configured but integration incomplete)
- **Email** (basic)
- **Token storage:** Keychain (iOS best practice)
- **Server validation:** JWKS verification for tokens (correct implementation)
- **No password reset:** Uses Apple/Google flows (limits self-hosted account recovery)

**Verdict:** Endgame's auth is solid but limited scope.

---

### Monetization & Pricing

#### RP Hypertrophy
- **Subscription-only:** $29.99/mo or $299.99/yr (~$25/mo)
- **Includes:** All program templates, volume feedback, autoregulation, community
- **Upsell:** RP Diet app (separate subscription, ~$13/mo)
- **No ads, no freemium tier**

#### Boostcamp
- **Freemium:**
  - Core: Free (access ~50 popular free programs, 1 custom program design, no premium features)
  - Premium: $9.99/mo or $79.99/yr (~$6.67/mo)
    - Unlimited custom programs, program sync, advanced analytics
- **Philosophy:** Low barrier to entry; conversion funnel based on custom builder value
- **No ads**

#### Endgame Fitness
- **TBD** (TestFlight only; not shipped)
- **Likely models discussed in code comments:** battle pass, cosmetics (avatar skins), premium talents
- **No pricing locked in**

**Verdict:** RP is premium science ($300/yr); Boostcamp is freemium entry (~$100/yr if converting); Endgame is unreleased/unknown.

---

### Use Cases & Ideal User

| User Profile | Preferred App | Why |
|---|---|---|
| Hypertrophy-focused lifter who trusts the science and logs consistently | **RP Hypertrophy** | MEV/MRV feedback is the gold standard; autoregulation is proven |
| Strength/powerlifting athlete or program follower | **Boostcamp** | 100+ creator programs; 5/3/1, GZCLP, etc. all available free |
| Beginner seeking simple logging + community motivation | **Boostcamp** (free) | No paywall; trending programs; friend leaderboards |
| Competitive/social lifter who wants gamified progression + PvP | **Endgame Fitness** | Raids, duels, talents, quests; no competitor has RPG layer |
| Mac user or multi-device user | **RP** or **Boostcamp** (cloud-synced) | Endgame's local-only history breaks the iOS+Mac advantage |
| User who wants LLM-generated programs | **Endgame Fitness** | Only app with real Claude integration for mesocycle building |

---

## Feature-by-Feature Matrix (Condensed)

| Feature | Endgame | RP | Boostcamp |
|---|---|---|---|
| Set logging (reps/weight) | ✅ | ✅ | ✅ |
| RPE/RIR capture | ❌ | ✅ | ✅ (optional) |
| Post-set feedback loop | ❌ | ✅ | ⚠️ (manual only) |
| Volume landmarks (MEV/MRV) | ❌ | ✅ | ❌ |
| Auto-periodization | ❌ | ✅ | ⚠️ (program-defined) |
| Mesocycle deload logic | ❌ (dead code) | ✅ (automatic) | ⚠️ (if program includes) |
| Program templates | 16 presets | 16 hypertrophy-focused | 100+ (library) |
| Exercise library | 48 (no videos) | 250+ (w/ videos) | 400+ (w/ videos) |
| Custom program builder | ✅ (LLM) | ❌ | ✅ (full GUI) |
| Rest timer | ✅ | ✅ | ✅ |
| 1RM/plate calc tools | ✅ | ✅ (1RM only) | ✅ (plate calc, 1RM) |
| History/charts | ✅ (calendar, progress) | ✅ (volume, load) | ✅ (e1RM, volume) |
| PR detection | ✅ (e1RM) | ✅ | ✅ |
| AI features | ✅ (LLM mesocycle builder; hardcoded coach) | ❌ | ❌ |
| Gamification | ✅✅ (raids, talents, duels, quests, combo) | ❌ | ⚠️ (streaks, badges) |
| Social/feed | ✅ (feed, reactions, leaderboards) | ❌ | ⚠️ (program communities, LBs) |
| Guilds/group challenges | ✅ (guild raids) | ❌ | ❌ |
| Avatar | ⚠️ (written, not invoked) | ❌ | ❌ |
| HealthKit | ⚠️ (reads narrow; writes workouts) | ✅ | ✅ |
| Watch app | ❌ | ✅ | ✅ |
| Cross-device sync | ❌ (local JSON per device) | ✅ | ✅ |
| Platforms | iOS + macOS | iOS, Android, web | iOS, Android |
| Price | TBD | $29.99/mo | Free–$9.99/mo |
| Status | TestFlight | Shipped, mature | Shipped, mature |

---

## Honest Assessment

### Endgame Fitness Competitive Advantages
1. **Unmatched RPG layer:** Raids, talents, duels, quests, combo counter — **no competitor does this at all**
2. **Native macOS:** Only desktop-native app in the space
3. **Real LLM mesocycle builder:** Claude-generated 4–12 week blocks; backend is working
4. **All-in-one tools:** Plate calc, 1RM, TDEE, macros, rep-max charts
5. **Social gamification:** Feed + reactions + guilds + leaderboards

### Critical Gaps (Training Science)
1. **No RIR/RPE logging** ← RP's entire moat
2. **No per-muscle volume tracking** ← Blocks deload logic, MEV/MRV ramps
3. **Schedule isn't structured** ← Exercises are plain text ("Squats 8-12"); no `ProgramExercise` targets for autoregulation or "hit your sets" flow
4. **No cross-device sync** ← Workout history is device-local; iPhone + Mac see different histories
5. **Roadmap is exaggerated** ← Post-workout questionnaire, TTS coaching, avatar evolution all claim-not-implemented

### Competitive Positioning

**If Endgame positions as a science-first hypertrophy coach:** It loses immediately to RP (RP has 8+ years of validated research operationalized; Endgame has string-based progression).

**If Endgame positions as a gamified social tracker for lifters who want PvP + community:** It wins decisively (raid bosses, duels, guilds = unique). RP/Boostcamp aren't in that market.

**The fatal trap:** Trying to be both. Endgame has *neither* the autoregulation depth of RP *nor* the program library of Boostcamp. It's positioned as all three, but ships none fully.

---

## Highest-Impact Improvements (Rank-Ordered for Endgame)

1. **Structured `ProgramExercise` targets** (target sets/reps/weight) feeding the logger
   - Enables "hit your prescribed sets" flow
   - Unblocks analytics (% of target achieved per session)
   - ~3 days of Swift + backend schema work
   
2. **RIR field on `ExerciseSet` + simple last-session-beat progression**
   - Single int field: RIR (0–5 range)
   - If last session beat reps @ weight: suggest +5 lb
   - If last session fell short: hold weight
   - ~2 days work; immediate differentiation from Boostcamp's program-defined-only progression
   
3. **Per-muscle weekly set counter** (enables deload + volume talent)
   - Track sets/week per muscle group
   - Deload toggle becomes live logic (scale to 50% on deload week)
   - Feed volume into talent effects ("High Volume" talent +2% XP per extra 2 sets)
   - ~2 days; ties game layer to training science
   
4. **Sync workout JSON through old online backend**
   - Ship iOS + Mac workouts to cloud `/api/fitness/workouts`
   - Merge local JSON on re-sync
   - ~1 day; fixes the cross-device sync disaster
   
5. **Wire up orphaned avatar**
   - Call `AvatarEvolutionEngine.update()` after workout
   - Display avatar in workout summary screen
   - ~1 day; already written, just needs call sites

**Effort estimate:** ~2 weeks total (prioritize 1, 2, 4 first).

---

## Conclusion

Endgame's moat is gamification. RP's moat is autoregulation. Boostcamp's moat is content. Today, Endgame loses on science (Endgame < Boostcamp < RP) but wins on novelty (Endgame >> Boostcamp, RP). The product is positioned correctly but incompletely.

To ship successfully, Endgame must choose: (a) **play the game layer,** not science (raid-driven competitive social app), or (b) **implement true autoregulation** (RIR + volume + deload). Doing both half-way serves no audience well.

