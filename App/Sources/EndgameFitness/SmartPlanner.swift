//
//  SmartPlanner.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  The Smart Advisor program planner (used when the wizard's split is
//  "Smart Advisor"). Deterministic and local: no network, no AI.
//
//  1. Goal templates turn the goal into weekly targets (strength sessions,
//     aerobic minutes, VO2max work, mobility/balance, muscle frequency).
//     Several candidate session mixes are generated per goal.
//  2. Every session type carries a fatigue score per region
//     (upper / lower / systemic). Sessions are placed over the real
//     training-day sequence (rolling runs or weekday gaps) by a recovery
//     cost: no same region trained hard on back-to-back days, no two hard
//     days in a row for health goals, hardest sessions after rest days.
//  3. Exercises come from an equipment- and injury-tagged catalog, scaled
//     to session length and experience.
//  4. Weekly sets per muscle are checked against the goal's range (built
//     from SmartCoach's MEV/MAV/MRV landmarks) and adjusted.
//  5. Each candidate is scored (frequency, volume, recovery, goal
//     coverage, balance) and the best one wins. The same score is used by
//     the selftest to compare against hand-built splits.
//  6. One week (or one or two rolling cycles) is planned and repeated, so
//     every week has the same sessions and set counts. Session length is a
//     ceiling; when sessions miss the aerobic target, brisk walks on the
//     rest-day page (`RestDayPlan`, stored apart from the rotation) make up
//     the gap.
//  7. Every session opens with a timed warm-up (pulse raise, dynamic drills
//     for the day's patterns, ramp-up sets) that counts toward its length.
//  8. Longevity loads joint-safely: lower-risk variations, 8+ reps (10+ on
//     beginners' compounds), every set 2-3 reps short of failure.
//

import Foundation

enum SmartPlanner {

    /// Bumped when the planner's output changes in a way saved programs must
    /// pick up (3: warm-ups, rest-day page, joint-safe longevity loading).
    /// Programs built by an older version are rebuilt on launch.
    static let version = 3

    // MARK: - Vocabulary

    enum Gear: Hashable { case barbell, dumbbell, kettlebell, cable, machine, pullupBar, band, bodyweight }

    enum Pattern: String, CaseIterable {
        case squat, hinge, lunge, hPush, vPush, hPull, vPull, core, carry, calf
        case biceps, triceps, lateral, rearDelt, chestIso, glute, quadIso, hamIso
        var isCompound: Bool { [.squat, .hinge, .lunge, .hPush, .vPush, .hPull, .vPull].contains(self) }
    }

    enum Intensity { case heavy, hypertrophy, foundation, general, endurance, circuit }

    enum Kind: String { case strength, mixed, zone2, intervals, gentleIntervals, mobility, recovery }

    enum Template: String { case fullBody, upper, lower, push, pull, legs, chest, back, shoulders, arms, torso, limbs }

    static let muscleGroups = ["Chest", "Back", "Shoulders", "Biceps", "Triceps", "Quads", "Hamstrings", "Glutes", "Calves", "Core"]
    static let majorGroups = ["Chest", "Back", "Shoulders", "Quads", "Hamstrings", "Glutes"]

    struct Move {
        let name: String
        let pattern: Pattern
        let gear: Set<Gear>
        let muscles: [String: Double]
        var heavy = false
        var beginner = true
        var flags: Set<String> = []
        var reps: String? = nil
        /// Only sensible as a heavy, low-rep lift (weighted pull-ups, dips).
        var heavyOnly = false
        /// Injuries this move is the preferred swap for (goblet squat for a low back).
        var safeFor: Set<String> = []
        /// Longevity (joint-safe) ranking: -1 never used, 1 preferred, 0 neutral.
        var longevity = 0
        /// A lower-risk variation only offered to longevity plans.
        var longevityOnly = false
    }

    // MARK: - Catalog (names follow the existing generateExercises pools)

    static let catalog: [Move] = [
        // Squat
        Move(name: "Back Squats", pattern: .squat, gear: [.barbell], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true, flags: ["Knee", "Low back"], longevity: -1),
        Move(name: "Barbell Box Squats", pattern: .squat, gear: [.barbell], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true, flags: ["Low back"], longevity: -1),
        Move(name: "Front Squats", pattern: .squat, gear: [.barbell], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true, beginner: false, flags: ["Knee", "Low back"], longevity: -1),
        Move(name: "Belt Squats", pattern: .squat, gear: [.machine], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true, flags: ["Knee"], safeFor: ["Low back"]),
        Move(name: "Leg Press", pattern: .squat, gear: [.machine], muscles: ["Quads": 1, "Glutes": 0.5], safeFor: ["Low back"], longevity: 1),
        Move(name: "Goblet Squats", pattern: .squat, gear: [.dumbbell, .kettlebell], muscles: ["Quads": 1, "Glutes": 0.5], safeFor: ["Low back"], longevity: 1),
        Move(name: "Safety Bar Squats", pattern: .squat, gear: [.machine], muscles: ["Quads": 1, "Glutes": 0.5], flags: ["Low back"], longevity: 1, longevityOnly: true),
        Move(name: "Pistol Squats", pattern: .squat, gear: [.bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true, beginner: false, flags: ["Knee"], reps: "3-6", heavyOnly: true, longevity: -1),
        Move(name: "Bodyweight Squats", pattern: .squat, gear: [.bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], reps: "15-20"),
        Move(name: "Box Squats", pattern: .squat, gear: [.bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], reps: "12-15"),
        // Hinge
        Move(name: "Deadlifts", pattern: .hinge, gear: [.barbell], muscles: ["Hamstrings": 1, "Glutes": 1, "Back": 0.5], heavy: true, beginner: false, flags: ["Low back"], longevity: -1),
        Move(name: "Trap Bar Deadlifts", pattern: .hinge, gear: [.machine], muscles: ["Hamstrings": 0.5, "Glutes": 1, "Quads": 0.5], heavy: true, flags: ["Low back"], longevity: -1),
        Move(name: "High-Handle Trap Bar Deadlifts", pattern: .hinge, gear: [.machine], muscles: ["Hamstrings": 0.5, "Glutes": 1, "Quads": 0.5], flags: ["Low back"], longevity: 1, longevityOnly: true),
        Move(name: "Dumbbell Romanian Deadlifts", pattern: .hinge, gear: [.dumbbell, .kettlebell], muscles: ["Hamstrings": 1, "Glutes": 0.5], flags: ["Low back"], longevity: 1, longevityOnly: true),
        Move(name: "Romanian Deadlifts", pattern: .hinge, gear: [.barbell, .dumbbell], muscles: ["Hamstrings": 1, "Glutes": 0.5], flags: ["Low back"], longevity: -1),
        Move(name: "Kettlebell Swings", pattern: .hinge, gear: [.kettlebell], muscles: ["Hamstrings": 0.5, "Glutes": 1], beginner: false, flags: ["Low back"], reps: "15-20", longevity: -1),
        Move(name: "Back Extensions", pattern: .hinge, gear: [.machine], muscles: ["Hamstrings": 0.5, "Glutes": 0.5, "Back": 0.5], flags: ["Low back"]),
        Move(name: "Single-Leg Hip Hinges", pattern: .hinge, gear: [.bodyweight], muscles: ["Hamstrings": 0.5, "Glutes": 0.5], reps: "10-12"),
        // Lunge / single leg
        Move(name: "Bulgarian Split Squats", pattern: .lunge, gear: [.dumbbell, .barbell, .bodyweight], muscles: ["Quads": 1, "Glutes": 1], beginner: false, flags: ["Knee"]),
        Move(name: "Split Squats", pattern: .lunge, gear: [.dumbbell, .kettlebell, .bodyweight], muscles: ["Quads": 1, "Glutes": 1], flags: ["Knee"], longevity: 1, longevityOnly: true),
        Move(name: "Walking Lunges", pattern: .lunge, gear: [.dumbbell, .bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], flags: ["Knee"]),
        Move(name: "Reverse Lunges", pattern: .lunge, gear: [.dumbbell, .kettlebell, .bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], flags: ["Knee"]),
        Move(name: "Step-ups", pattern: .lunge, gear: [.dumbbell, .bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], flags: ["Knee"]),
        // Horizontal push
        Move(name: "Barbell Bench Press", pattern: .hPush, gear: [.barbell], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], heavy: true, flags: ["Shoulder"], longevity: -1),
        Move(name: "Dumbbell Bench Press", pattern: .hPush, gear: [.dumbbell], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], longevity: 1),
        Move(name: "Incline Dumbbell Press", pattern: .hPush, gear: [.dumbbell], muscles: ["Chest": 1, "Shoulders": 0.5, "Triceps": 0.5]),
        Move(name: "Machine Chest Press", pattern: .hPush, gear: [.machine], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5]),
        Move(name: "Neutral-Grip Dumbbell Press", pattern: .hPush, gear: [.dumbbell], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], safeFor: ["Shoulder"], longevity: 1),
        Move(name: "Dumbbell Floor Press", pattern: .hPush, gear: [.dumbbell], muscles: ["Chest": 1, "Triceps": 0.5], safeFor: ["Shoulder"]),
        Move(name: "Weighted Dips", pattern: .hPush, gear: [.machine], muscles: ["Chest": 1, "Triceps": 1, "Shoulders": 0.5], heavy: true, beginner: false, flags: ["Shoulder"], heavyOnly: true, longevity: -1),
        Move(name: "Push-ups", pattern: .hPush, gear: [.bodyweight], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], reps: "8-15", longevity: 1),
        Move(name: "Incline Push-ups", pattern: .hPush, gear: [.bodyweight], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], reps: "10-15"),
        Move(name: "Archer Push-ups", pattern: .hPush, gear: [.bodyweight], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], heavy: true, beginner: false, reps: "4-8", heavyOnly: true, longevity: -1),
        // Vertical push
        Move(name: "Overhead Press", pattern: .vPush, gear: [.barbell], muscles: ["Shoulders": 1, "Triceps": 0.5], heavy: true, flags: ["Shoulder"], longevity: -1),
        Move(name: "Dumbbell Shoulder Press", pattern: .vPush, gear: [.dumbbell, .kettlebell], muscles: ["Shoulders": 1, "Triceps": 0.5], flags: ["Shoulder"]),
        Move(name: "Landmine Press", pattern: .vPush, gear: [.barbell], muscles: ["Shoulders": 1, "Chest": 0.5, "Triceps": 0.5], safeFor: ["Shoulder"], longevity: 1),
        Move(name: "Half-Kneeling Landmine Press", pattern: .vPush, gear: [.barbell], muscles: ["Shoulders": 1, "Triceps": 0.5], safeFor: ["Shoulder"], longevity: 1),
        Move(name: "Pike Push-ups", pattern: .vPush, gear: [.bodyweight], muscles: ["Shoulders": 1, "Triceps": 0.5], beginner: false, flags: ["Shoulder"], reps: "6-12", longevity: -1),
        Move(name: "Incline Pike Push-ups", pattern: .vPush, gear: [.bodyweight], muscles: ["Shoulders": 1, "Triceps": 0.5], flags: ["Shoulder"], reps: "6-10"),
        // Horizontal pull
        Move(name: "Barbell Rows", pattern: .hPull, gear: [.barbell], muscles: ["Back": 1, "Biceps": 0.5], heavy: true, beginner: false, flags: ["Low back"], longevity: -1),
        Move(name: "Chest-Supported Rows", pattern: .hPull, gear: [.dumbbell, .machine], muscles: ["Back": 1, "Biceps": 0.5], longevity: 1),
        Move(name: "One-Arm Dumbbell Rows", pattern: .hPull, gear: [.dumbbell, .kettlebell], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Seated Cable Rows", pattern: .hPull, gear: [.cable], muscles: ["Back": 1, "Biceps": 0.5], longevity: 1),
        Move(name: "Inverted Rows", pattern: .hPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Band Rows", pattern: .hPull, gear: [.band], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Doorframe Rows", pattern: .hPull, gear: [.bodyweight], muscles: ["Back": 1, "Biceps": 0.5], reps: "10-15"),
        Move(name: "Towel Rows", pattern: .hPull, gear: [.bodyweight], muscles: ["Back": 1, "Biceps": 0.5], reps: "10-15"),
        // Vertical pull
        Move(name: "Weighted Pull-ups", pattern: .vPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 0.5], heavy: true, beginner: false, flags: ["Shoulder"], heavyOnly: true, longevity: -1),
        Move(name: "Pull-ups", pattern: .vPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 0.5], beginner: false, flags: ["Shoulder"], reps: "5-10", longevity: -1),
        Move(name: "Lat Pulldowns", pattern: .vPull, gear: [.cable], muscles: ["Back": 1, "Biceps": 0.5], safeFor: ["Shoulder"], longevity: 1),
        Move(name: "Chin-ups", pattern: .vPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 1], beginner: false, flags: ["Shoulder"], reps: "5-10", longevity: -1),
        Move(name: "Assisted Pull-ups", pattern: .vPull, gear: [.machine], muscles: ["Back": 1, "Biceps": 0.5], flags: ["Shoulder"], longevity: 1, longevityOnly: true),
        // Needs a bar and a band; ranks with the band moves, so a gym's lat pulldown or assisted machine comes first.
        Move(name: "Band-Assisted Pull-ups", pattern: .vPull, gear: [.band], muscles: ["Back": 1, "Biceps": 0.5], flags: ["Shoulder"], reps: "5-8"),
        Move(name: "Band Lat Pulldowns", pattern: .vPull, gear: [.band], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Prone Lat Pulls", pattern: .vPull, gear: [.bodyweight], muscles: ["Back": 1], reps: "12-15"),
        // Core / carry
        Move(name: "Plank", pattern: .core, gear: [.bodyweight], muscles: ["Core": 1], reps: "40s"),
        Move(name: "Dead Bug", pattern: .core, gear: [.bodyweight], muscles: ["Core": 1], reps: "10", longevity: 1),
        Move(name: "Pallof Press", pattern: .core, gear: [.band, .cable], muscles: ["Core": 1], reps: "10", longevity: 1),
        Move(name: "Hanging Knee Raises", pattern: .core, gear: [.pullupBar], muscles: ["Core": 1], reps: "10-12", longevity: -1),
        Move(name: "Side Plank", pattern: .core, gear: [.bodyweight], muscles: ["Core": 1], reps: "30s", longevity: 1),
        Move(name: "Bird Dog", pattern: .core, gear: [.bodyweight], muscles: ["Core": 1], reps: "8", longevity: 1, longevityOnly: true),
        Move(name: "Ab Wheel Rollouts", pattern: .core, gear: [.machine], muscles: ["Core": 1], beginner: false, flags: ["Low back"], reps: "8-12", longevity: -1),
        Move(name: "Farmer's Carry", pattern: .carry, gear: [.dumbbell, .kettlebell], muscles: ["Core": 0.5, "Back": 0.5], reps: "40m", longevity: 1),
        Move(name: "Suitcase Carry", pattern: .carry, gear: [.dumbbell, .kettlebell], muscles: ["Core": 1], reps: "30m", longevity: 1),
        // Calves
        Move(name: "Standing Calf Raises", pattern: .calf, gear: [.machine], muscles: ["Calves": 1]),
        Move(name: "Dumbbell Calf Raises", pattern: .calf, gear: [.dumbbell], muscles: ["Calves": 1]),
        Move(name: "Single-Leg Calf Raises", pattern: .calf, gear: [.bodyweight], muscles: ["Calves": 1], reps: "12-15"),
        // Arms
        Move(name: "Barbell Curls", pattern: .biceps, gear: [.barbell], muscles: ["Biceps": 1]),
        Move(name: "Dumbbell Curls", pattern: .biceps, gear: [.dumbbell], muscles: ["Biceps": 1]),
        Move(name: "Hammer Curls", pattern: .biceps, gear: [.dumbbell], muscles: ["Biceps": 1]),
        Move(name: "Cable Curls", pattern: .biceps, gear: [.cable], muscles: ["Biceps": 1]),
        Move(name: "Band Curls", pattern: .biceps, gear: [.band], muscles: ["Biceps": 1]),
        Move(name: "Cable Pushdowns", pattern: .triceps, gear: [.cable], muscles: ["Triceps": 1], longevity: 1),
        Move(name: "Overhead Dumbbell Extensions", pattern: .triceps, gear: [.dumbbell], muscles: ["Triceps": 1]),
        Move(name: "Skull Crushers", pattern: .triceps, gear: [.barbell, .dumbbell], muscles: ["Triceps": 1], longevity: -1),
        Move(name: "Band Pushdowns", pattern: .triceps, gear: [.band], muscles: ["Triceps": 1]),
        Move(name: "Diamond Push-ups", pattern: .triceps, gear: [.bodyweight], muscles: ["Triceps": 1, "Chest": 0.5], reps: "8-15"),
        // Shoulders
        Move(name: "Lateral Raises", pattern: .lateral, gear: [.dumbbell], muscles: ["Shoulders": 1]),
        Move(name: "Cable Lateral Raises", pattern: .lateral, gear: [.cable], muscles: ["Shoulders": 1]),
        Move(name: "Band Lateral Raises", pattern: .lateral, gear: [.band], muscles: ["Shoulders": 1]),
        Move(name: "Prone Y-T-W Raises", pattern: .lateral, gear: [.bodyweight], muscles: ["Shoulders": 1, "Back": 0.25], reps: "10"),
        Move(name: "Face Pulls", pattern: .rearDelt, gear: [.cable], muscles: ["Shoulders": 0.5, "Back": 0.5]),
        Move(name: "Band Face Pulls", pattern: .rearDelt, gear: [.band], muscles: ["Shoulders": 0.5, "Back": 0.5]),
        Move(name: "Rear Delt Flyes", pattern: .rearDelt, gear: [.dumbbell], muscles: ["Shoulders": 0.5, "Back": 0.5]),
        Move(name: "Reverse Snow Angels", pattern: .rearDelt, gear: [.bodyweight], muscles: ["Shoulders": 0.5, "Back": 0.5], reps: "10-12"),
        // Chest isolation
        Move(name: "Cable Flyes", pattern: .chestIso, gear: [.cable], muscles: ["Chest": 1]),
        Move(name: "Pec Deck", pattern: .chestIso, gear: [.machine], muscles: ["Chest": 1], flags: ["Shoulder"]),
        Move(name: "Dumbbell Flyes", pattern: .chestIso, gear: [.dumbbell], muscles: ["Chest": 1], flags: ["Shoulder"]),
        // Glutes / hamstrings / quads isolation
        Move(name: "Barbell Hip Thrusts", pattern: .glute, gear: [.barbell], muscles: ["Glutes": 1, "Hamstrings": 0.5], heavy: true),
        Move(name: "Hip Thrusts", pattern: .glute, gear: [.dumbbell, .machine], muscles: ["Glutes": 1, "Hamstrings": 0.5], longevity: 1),
        Move(name: "Glute Bridges", pattern: .glute, gear: [.bodyweight], muscles: ["Glutes": 1, "Hamstrings": 0.5], reps: "12-20", longevity: 1),
        Move(name: "Single-Leg Glute Bridges", pattern: .glute, gear: [.bodyweight], muscles: ["Glutes": 1, "Hamstrings": 0.5], reps: "10-12"),
        Move(name: "Leg Curls", pattern: .hamIso, gear: [.machine], muscles: ["Hamstrings": 1]),
        Move(name: "Sliding Leg Curls", pattern: .hamIso, gear: [.bodyweight], muscles: ["Hamstrings": 1], reps: "6-10"),
        Move(name: "Nordic Curls", pattern: .hamIso, gear: [.bodyweight], muscles: ["Hamstrings": 1], beginner: false, reps: "4-6", longevity: -1),
        Move(name: "Leg Extensions", pattern: .quadIso, gear: [.machine], muscles: ["Quads": 1], flags: ["Knee"]),
        Move(name: "Wall Sits", pattern: .quadIso, gear: [.bodyweight], muscles: ["Quads": 1], reps: "45s"),
    ]

    /// Mobility, balance and stability pools: (name, scheme, injury flags, gear needed or nil).
    struct Drill { let name: String; let scheme: String; var flags: Set<String> = []; var gear: Set<Gear>? = nil }
    static let mobilityPool: [Drill] = [
        Drill(name: "Cat-Cow", scheme: "2x10"), Drill(name: "World's Greatest Stretch", scheme: "2x5"),
        Drill(name: "Hip Flexor Stretch", scheme: "2x45s"), Drill(name: "Thoracic Rotations", scheme: "2x10"),
        Drill(name: "90/90 Hip Switches", scheme: "2x8"), Drill(name: "Deep Squat Hold", scheme: "2x30s", flags: ["Knee"]),
        Drill(name: "Hamstring Floss", scheme: "2x10"), Drill(name: "Shoulder CARs", scheme: "2x5"),
        Drill(name: "Ankle Rocks", scheme: "2x10"), Drill(name: "Couch Stretch", scheme: "2x45s", flags: ["Knee"]),
        Drill(name: "Child's Pose", scheme: "2x45s"), Drill(name: "Thread the Needle", scheme: "2x8"),
    ]
    static let balancePool: [Drill] = [
        Drill(name: "Single-Leg Balance", scheme: "3x30s"), Drill(name: "Tandem Stance", scheme: "3x30s"),
        Drill(name: "Heel-to-Toe Walk", scheme: "3x10"), Drill(name: "Single-Leg Clock Reaches", scheme: "2x6", flags: ["Knee"]),
        Drill(name: "Eyes-Closed Single-Leg Balance", scheme: "3x20s"),
    ]
    static let stabilityPool: [Drill] = [
        Drill(name: "Dead Bug", scheme: "3x10"), Drill(name: "Bird Dog", scheme: "3x8"),
        Drill(name: "Side Plank", scheme: "3x30s"), Drill(name: "Glute Bridge Hold", scheme: "3x30s"),
        Drill(name: "Pallof Press", scheme: "3x10", gear: [.band, .cable]),
    ]

    // MARK: - Plan model

    struct Item {
        /// `warmup`: the timed warm-up that opens every session (pulse raise,
        /// dynamic drills, ramp-up sets); never a tracked lift.
        /// `outside`: done outside the session (an extra daily walk); no session time.
        enum Kind { case warmup, lift, cardio, intervals, mobility, balance, stability, walk, outside }
        var kind: Kind
        var name: String
        var sets = 1
        var reps = ""
        var minutes = 0.0
        var pattern: Pattern? = nil
        var muscles: [String: Double] = [:]
        var perSet = 0.0
        var heavyLoad = false
        var aerobic = 0.0      // moderate-equivalent aerobic minutes
        var gear: Set<Gear> = []
        /// One of a session's guaranteed push / pull / lower lifts.
        var essential = false
        /// Done as an antagonist superset: rest is shared, so each set costs less time.
        var superset = false
        /// A dynamic warm-up drill (counts as mobility work).
        var warmDrill = false
        var duration: Double {
            switch kind {
            case .lift: return superset ? Double(sets) * perSet * 0.65 + 0.5 : Double(sets) * perSet + 1
            case .outside: return 0
            default: return minutes
            }
        }
        var text: String {
            switch kind {
            case .lift: return "\(name) \(sets)x\(reps)"
            case .warmup, .cardio, .walk, .outside: return "\(name) \(Int(minutes)) min"
            case .intervals, .mobility, .balance, .stability: return "\(name) \(reps)"
            }
        }
    }

    struct Spec {
        var kind: Kind
        var template: Template? = nil
        var intensity: Intensity = .general
        var variant = 0
        /// Hand-built split sessions: the groups and label as the split defines them.
        var groups: [Template] = []
        var label: String? = nil

        var fatigue: [Int] {
            switch kind {
            case .strength:
                let ts = groups.isEmpty ? [template ?? .fullBody] : groups
                var f = [0, 0, 0]
                for t in ts { let tf = SmartPlanner.fatigue(of: t); for r in 0..<3 { f[r] = max(f[r], tf[r]) } }
                return f
            // Strength + Zone 2 is hard for every region its lifts load.
            case .mixed:
                switch template ?? .fullBody {
                case .upper: return [3, 1, 2]
                case .lower: return [0, 3, 2]
                default: return [2, 3, 2]
                }
            case .zone2: return [0, 1, 1]
            case .intervals: return [0, 2, 3]
            case .gentleIntervals: return [0, 2, 2]
            case .mobility, .recovery: return [0, 0, 0]
            }
        }
        var isHard: Bool { (fatigue.max() ?? 0) >= 3 }
        var load: Int { fatigue.reduce(0, +) }
    }

    struct Session {
        var spec: Spec
        var label: String
        var items: [Item]
        var budget: Double
        var fatigue: [Int] { spec.fatigue }
        var isHard: Bool { spec.isHard }
        /// Whole session, warm-up included (it is listed as its own items).
        var minutes: Double { items.reduce(0) { $0 + $1.duration } }
        var warmupMinutes: Double { items.filter { $0.kind == .warmup }.reduce(0) { $0 + $1.minutes } }
        var hasStrength: Bool { items.contains { $0.kind == .lift } }
        var aerobic: Double { items.reduce(0) { $0 + $1.aerobic } }
        var mobilityMinutes: Double { items.filter { [.mobility, .balance, .stability].contains($0.kind) || $0.warmDrill }.reduce(0) { $0 + $1.minutes } }
        var hasBalance: Bool { items.contains { $0.kind == .balance } }
        func sets(of group: String) -> Double {
            items.reduce(0) { $0 + Double($1.sets) * ($1.kind == .lift ? ($1.muscles[group] ?? 0) : 0) }
        }
        /// Core sets done as stability drills (Dead Bug 3x10 on a mobility day).
        var stabilityCoreSets: Double { items.filter { $0.kind == .stability }.reduce(0) { $0 + Double($1.sets) * ($1.muscles["Core"] ?? 0) } }
    }

    struct Slot { let label: String; let day: Int; let restBefore: Int; var cycle = 0 }

    struct Plan {
        let config: ProgramConfig
        let slots: [Slot]
        var sessions: [Session]
        let blockDays: Int
        /// Brisk-walk minutes prescribed outside the sessions (0 = none), on
        /// `walkDaysPerWeek` days (the rest days, or every day).
        var restDayWalk = 0.0
        var walkDaysPerWeek = 0.0
        /// When the rest days cannot hold the gap: an extra walk outside the
        /// session on each training day (`trainingWalkDaysPerWeek` days).
        var trainingDayWalk = 0.0
        var trainingWalkDaysPerWeek = 0.0
        var weeks: Double { Double(blockDays) / 7 }

        /// Session length is a ceiling: each entry carries its own time.
        var scheduledWorkouts: [ScheduledWorkout] {
            let note = SmartPlanner.loadingNote(Ctx(config: config))
            return zip(slots, sessions).map { slot, s in
                ScheduledWorkout(dayOfWeek: slot.label, workoutType: s.label, exercises: s.items.map(\.text),
                                 estimatedDuration: max(10, min(config.sessionLength, Int(s.minutes.rounded()))),
                                 notes: s.hasStrength ? SmartPlanner.joinedNote(note, SmartPlanner.bodyweightNote(s.items)) : nil)
            }
        }

        /// What to do on the days off; stored apart from `scheduledWorkouts`.
        var restDayPlan: RestDayPlan { SmartPlanner.restDayPlan(config: config, walk: restDayWalk) }
    }

    // MARK: - Context

    struct Ctx {
        let config: ProgramConfig
        var goal: TrainingGoal { config.primaryGoal }
        var beginner: Bool { config.experienceLevel == .beginner }
        var injuries: Set<String> { config.injuries }
        var length: Double { Double(min(120, max(15, config.sessionLength))) }
        var gear: Set<Gear> {
            switch config.equipment {
            case .fullGym: return [.barbell, .dumbbell, .kettlebell, .cable, .machine, .pullupBar, .band, .bodyweight]
            case .homeGym: return [.barbell, .dumbbell, .kettlebell, .pullupBar, .band, .bodyweight]
            case .minimal: return [.dumbbell, .kettlebell, .band, .pullupBar, .bodyweight]
            case .bodyweight: return [.bodyweight]
            }
        }
        var healthGoal: Bool { ![.buildMuscle, .getStronger].contains(goal) }
        /// Longevity: lower-risk variations, 8+ reps, every set 2-3 reps short of failure.
        var jointSafe: Bool { goal == .longevity }
        var maxExercises: Int {
            switch config.experienceLevel { case .beginner: return 5; case .intermediate: return 7; case .advanced: return 8; case .expert: return 9 }
        }
        var maxSets: Int { beginner ? 4 : 5 }
        var compoundSets: Int {
            switch config.experienceLevel { case .beginner: return 2; case .intermediate: return 3; case .advanced, .expert: return 4 }
        }
        var isoSets: Int { beginner ? 2 : 3 }
    }

    static func fatigue(of t: Template) -> [Int] {
        switch t {
        case .fullBody, .limbs: return [2, 3, 3]
        case .upper, .push, .pull, .chest, .torso: return [3, 0, 2]
        case .back: return [3, 1, 2]
        case .shoulders: return [3, 0, 1]
        case .arms: return [2, 0, 1]
        case .lower, .legs: return [0, 3, 3]
        }
    }

    static func patterns(_ t: Template, variant: Int) -> [Pattern] {
        switch t {
        case .fullBody:
            switch variant % 3 {
            case 0: return [.squat, .hPush, .hPull, .hamIso, .core, .vPull, .lateral, .glute, .calf, .biceps, .triceps]
            case 1: return [.hinge, .vPush, .vPull, .lunge, .carry, .hPush, .hamIso, .rearDelt, .triceps, .biceps]
            default: return [.squat, .hPush, .hPull, .hinge, .core, .vPush, .lateral, .rearDelt, .biceps, .triceps]
            }
        case .upper: return [.hPush, .hPull, .vPull, .vPush, .chestIso, .lateral, .triceps, .biceps, .rearDelt]
        case .lower:
            return variant % 2 == 0 ? [.squat, .hinge, .lunge, .hamIso, .calf, .core, .glute, .quadIso]
                                    : [.hinge, .squat, .glute, .quadIso, .hamIso, .calf, .core, .lunge]
        case .push: return [.hPush, .vPush, .chestIso, .lateral, .triceps, .hPush]
        case .pull: return [.vPull, .hPull, .rearDelt, .biceps, .hPull, .biceps]
        case .legs: return [.squat, .hinge, .lunge, .quadIso, .hamIso, .calf, .glute, .core]
        case .chest: return [.hPush, .hPush, .chestIso, .hPush, .triceps]
        case .back: return [.vPull, .hPull, .hPull, .vPull, .rearDelt]
        case .shoulders: return [.vPush, .lateral, .rearDelt, .vPush, .lateral]
        case .arms: return [.biceps, .triceps, .biceps, .triceps, .biceps, .triceps]
        case .torso: return [.hPush, .hPull, .vPush, .vPull, .chestIso, .rearDelt]
        case .limbs: return [.squat, .hinge, .biceps, .triceps, .lunge, .calf]
        }
    }

    static func fallback(_ p: Pattern) -> [Pattern] {
        switch p {
        case .lunge, .hinge, .squat: return [.glute]
        case .vPull: return [.hPull]
        case .vPush, .rearDelt: return [.lateral]
        case .chestIso, .triceps: return [.hPush]
        case .quadIso: return [.squat]
        case .hamIso: return [.hinge, .glute]
        case .carry: return [.core]
        default: return []
        }
    }

    /// How well a move can be loaded with this gear: 0 barbell/machine,
    /// 1 dumbbell/kettlebell/cable/bar, 2 band, 3 bodyweight only.
    static func gearRank(_ m: Move, ctx: Ctx) -> Int {
        let g = m.gear.intersection(ctx.gear)
        if !g.isDisjoint(with: [.barbell, .machine]) { return 0 }
        if !g.isDisjoint(with: [.dumbbell, .kettlebell, .cable, .pullupBar]) { return 1 }
        return g.contains(.band) ? 2 : 3
    }

    /// Candidates for one pattern, best first: loadable gear before band
    /// before bodyweight (a lower tier only when the higher one is missing or
    /// blocked), injury-preferred swaps first within the tier.
    static func ranked(_ q: Pattern, ctx: Ctx, intensity: Intensity, used: Set<String>) -> [Move] {
        var c = catalog.filter { $0.pattern == q && !$0.gear.isDisjoint(with: ctx.gear) && $0.flags.isDisjoint(with: ctx.injuries) }
        // Longevity: joint-safe variations only (no barbell back/front squats,
        // conventional deadlifts, barbell bench/rows, strict pull-ups, ab wheel).
        c = ctx.jointSafe ? c.filter { $0.longevity >= 0 } : c.filter { !$0.longevityOnly }
        // Beginners never fall back to a move marked not for beginners.
        if ctx.beginner { c = c.filter(\.beginner) }
        if intensity == .heavy { let h = c.filter(\.heavy); if !h.isEmpty { c = h } }
        else { let l = c.filter { !$0.heavyOnly }; if !l.isEmpty { c = l } }
        // Circuits and strength-endurance: dumbbells/machines over max-effort barbell lifts.
        if intensity == .endurance || intensity == .circuit { let l = c.filter { !$0.heavy }; if !l.isEmpty { c = l } }
        c = c.filter { !used.contains($0.name) }
        guard !c.isEmpty else { return [] }
        if q != .core && q != .carry {
            func tier(_ m: Move) -> Int { min(2, max(0, gearRank(m, ctx: ctx) - 1)) }
            let best = c.map(tier).min()!
            c = c.filter { tier($0) == best }
        }
        let order = Dictionary(uniqueKeysWithValues: catalog.enumerated().map { ($1.name, $0) })
        return c.sorted { a, b in
            let sa = a.safeFor.isDisjoint(with: ctx.injuries) ? 1 : 0, sb = b.safeFor.isDisjoint(with: ctx.injuries) ? 1 : 0
            if sa != sb { return sa < sb }
            if ctx.jointSafe && a.longevity != b.longevity { return a.longevity > b.longevity }
            let ra = gearRank(a, ctx: ctx), rb = gearRank(b, ctx: ctx)
            if ra != rb { return ra < rb }
            return order[a.name, default: 0] < order[b.name, default: 0]
        }
    }

    /// `present`: patterns the session already has; a fallback pattern is
    /// never used to add a second variant of one of them.
    static func pick(_ p: Pattern, variant: Int, ctx: Ctx, intensity: Intensity, used: Set<String>,
                     present: Set<Pattern> = []) -> Move? {
        let chain = [p] + fallback(p).filter { !present.contains($0) }
        for (qi, q) in chain.enumerated() {
            let c = ranked(q, ctx: ctx, intensity: intensity, used: used)
            guard !c.isEmpty else { continue }
            // Heavy work with only bodyweight options in this pattern (a hinge
            // with a bad back): a heavy-capable fallback lift goes first.
            if qi == 0 && intensity == .heavy && !c.contains(where: \.heavy) && gearRank(c[0], ctx: ctx) >= 2 {
                for f in chain.dropFirst() {
                    if let h = ranked(f, ctx: ctx, intensity: .heavy, used: used).first(where: \.heavy) { return h }
                }
            }
            // Longevity: rotate only among the moves that rank best for joint
            // safety (an injury swap, then the longevity score), never past them
            // to a lower-ranked variation for the sake of variety.
            if ctx.jointSafe {
                func key(_ m: Move) -> (Int, Int) { (m.safeFor.isDisjoint(with: ctx.injuries) ? 1 : 0, m.longevity) }
                let top = key(c[0])
                let best = c.filter { key($0) == top }
                return best[variant % min(best.count, 3)]
            }
            return c[variant % min(c.count, 3)]
        }
        return nil
    }

    static func reps(_ i: Intensity, compound: Bool, ctx: Ctx) -> String {
        switch i {
        case .heavy: return compound ? (ctx.beginner ? "5" : ctx.config.experienceLevel == .intermediate ? "4-6" : "3-5") : "8-12"
        // Beginners stay at 8+ reps on compounds while they learn the lifts.
        case .hypertrophy: return compound ? (ctx.beginner ? "8-12" : "6-10") : "10-15"
        // Longevity: moderate loads, never below 8 reps (10-15 for beginners).
        case .foundation: return compound ? (ctx.beginner ? "10-15" : "8-12") : (ctx.beginner ? "12-15" : "10-15")
        case .general: return compound ? "8-12" : "10-15"
        case .endurance: return compound ? "12-15" : "15-20"
        case .circuit: return compound ? "10-12" : "12-15"
        }
    }

    static func perSet(_ i: Intensity, compound: Bool) -> Double {
        guard compound else { return i == .circuit ? 1.5 : 2.0 }
        switch i {
        case .heavy: return 3.5
        case .hypertrophy, .foundation: return 2.75
        case .general: return 2.5
        case .endurance: return 2.0
        case .circuit: return 1.75
        }
    }

    // MARK: - Session builders

    /// 0 push, 1 pull, 2 lower: the three movements every strength session keeps.
    static func region(_ p: Pattern?) -> Int? {
        switch p {
        case .hPush?, .vPush?: return 0
        case .hPull?, .vPull?: return 1
        case .squat?, .hinge?, .lunge?: return 2
        default: return nil
        }
    }

    static func makeItem(_ m: Move, sets: Int, intensity: Intensity, ctx: Ctx) -> Item {
        let compound = m.pattern.isCompound
        var r = m.reps ?? (intensity == .heavy && compound && !m.heavy ? "6-8" : reps(intensity, compound: compound, ctx: ctx))
        // Longevity: no set below 8 reps, 10 on beginners' compounds (band-assisted
        // pull-ups take more band, push-ups go to an incline when needed).
        if ctx.jointSafe, let lo = Int(r.split(separator: "-").first ?? ""), lo < (ctx.beginner && compound ? 10 : 8) {
            r = compound ? reps(.foundation, compound: true, ctx: ctx) : "8-12"
        }
        return Item(kind: .lift, name: m.name, sets: sets, reps: r, pattern: m.pattern, muscles: m.muscles,
                    perSet: perSet(intensity, compound: compound), heavyLoad: intensity == .heavy && compound && m.heavy, gear: m.gear)
    }

    /// Lifts for one strength block within `budget` minutes (the warm-up is
    /// planned separately and already taken off the budget).
    /// One push, one pull and one lower movement always stay; when time is
    /// short the push and pull become an antagonist superset, then extra sets
    /// and extra lifts go before any of those three movements.
    static func strengthItems(patterns input: [Pattern], variant: Int, intensity: Intensity, budget: Double,
                              ctx: Ctx, used: inout Set<String>) -> [Item] {
        var pats = input
        // Size: core and carries only after the muscles that need the time.
        if ctx.goal == .buildMuscle {
            pats = pats.filter { $0 != .core && $0 != .carry } + pats.filter { $0 == .core || $0 == .carry }
        }
        // The first pattern of each region that yields a lift of that region
        // (a blocked overhead press falls to the bench press, not to raises).
        var ess: [Int] = []
        for r in 0..<3 {
            if let i = pats.indices.first(where: { region(pats[$0]) == r
                && region(pick(pats[$0], variant: variant, ctx: ctx, intensity: intensity, used: used)?.pattern) == r }) { ess.append(i) }
        }
        ess.sort()
        pats = ess.map { pats[$0] } + pats.enumerated().filter { !ess.contains($0.offset) }.map(\.element)
        var items: [Item] = []
        var present = Set<Pattern>()
        for (k, p) in pats.enumerated() where items.count < ctx.maxExercises {
            guard let m = pick(p, variant: variant, ctx: ctx, intensity: intensity, used: used, present: present) else { continue }
            if m.pattern != p && present.contains(m.pattern) { continue }
            let compound = m.pattern.isCompound
            var sets = compound ? (intensity == .heavy ? ctx.compoundSets : min(3, ctx.compoundSets)) : ctx.isoSets
            if intensity == .heavy && compound && !ctx.beginner { sets += 1 }
            used.insert(m.name); present.insert(m.pattern)
            var it = makeItem(m, sets: sets, intensity: intensity, ctx: ctx)
            it.essential = k < ess.count && region(m.pattern) != nil
            items.append(it)
        }
        func time() -> Double { items.reduce(0) { $0 + $1.duration } }
        func superset() {
            guard let pu = items.firstIndex(where: { $0.essential && region($0.pattern) == 0 }),
                  let pl = items.firstIndex(where: { $0.essential && region($0.pattern) == 1 }), !items[pu].superset else { return }
            items[pu].superset = true; items[pl].superset = true
            if pl != pu + 1 { let pull = items.remove(at: pl); items.insert(pull, at: pl > pu ? pu + 1 : pu) }
        }
        // Short sessions superset straight away, so a fourth lift still fits.
        if ctx.length <= 40 && time() > budget { superset() }
        while time() > budget, let i = items.lastIndex(where: { !$0.essential && $0.sets > 2 }) { items[i].sets -= 1 }
        while time() > budget, let i = items.lastIndex(where: { $0.essential && $0.sets > 3 }) { items[i].sets -= 1 }
        while time() > budget && items.count > 4, let i = items.lastIndex(where: { !$0.essential }) { items.remove(at: i) }
        if time() > budget { superset() }
        while time() > budget, let i = items.lastIndex(where: { !$0.essential }) { items.remove(at: i) }
        while time() > budget, let i = items.lastIndex(where: { $0.sets > 2 }) { items[i].sets -= 1 }
        while time() > budget, let i = items.lastIndex(where: { $0.sets > 1 }) { items[i].sets -= 1 }
        while time() > budget && items.count > 1 { items.removeLast() }
        // Time left: add sets to compounds first, then one extra set to
        // accessories. The volume check later trims anything over the range.
        for compoundPass in [true, false] {
            var grew = true
            while grew {
                grew = false
                for i in items.indices where (items[i].pattern?.isCompound ?? false) == compoundPass {
                    let cap = compoundPass ? ctx.maxSets : ctx.isoSets + 1
                    let step = items[i].superset ? items[i].perSet * 0.65 : items[i].perSet
                    if items[i].sets < cap && time() + step <= budget {
                        items[i].sets += 1; grew = true
                    }
                }
            }
        }
        return items
    }

    /// `coreFirst`: a lifting day's closing block when the warm-up already
    /// covered mobility and no lift trains the core: core stability, then balance.
    static func drills(minutes: Double, balance: Bool, stability: Bool, offset: Int, ctx: Ctx, used: inout Set<String>,
                       coreFirst: Bool = false) -> [Item] {
        guard minutes >= 2 else { return [] }
        let ok: (Drill) -> Bool = { d in d.flags.isDisjoint(with: ctx.injuries) && (d.gear.map { !$0.isDisjoint(with: ctx.gear) } ?? true) }
        let mob = mobilityPool.filter(ok), bal = balancePool.filter(ok), stab = stabilityPool.filter(ok)
        var order: [(Item.Kind, [Drill], Double)] = [(.mobility, mob, 2.5)]
        if balance { order.append((.balance, bal, 3)) }
        order.append((.mobility, mob, 2.5))
        if stability { order.append((.stability, stab, 3)) }
        if coreFirst { order = [(.stability, stab.filter { $0.name != "Glute Bridge Hold" }, 2.5), (.balance, bal, 2.5), (.mobility, mob, 2.5)] }
        var items: [Item] = []
        var spent = 0.0
        var counters: [Item.Kind: Int] = [:]
        var k = 0
        while spent + 2.5 <= minutes + 0.5 && k < 40 {
            let (kind, pool, t) = order[k % order.count]
            k += 1
            guard !pool.isEmpty else { continue }
            var n = counters[kind, default: 0]
            var d = pool[(offset + n) % pool.count]
            var tries = 0
            while used.contains(d.name) && tries < pool.count { n += 1; tries += 1; d = pool[(offset + n) % pool.count] }
            counters[kind] = n + 1
            if used.contains(d.name) { continue }
            used.insert(d.name)
            var it = Item(kind: kind, name: d.name, reps: d.scheme, minutes: t)
            // Core stability work (Dead Bug 3x10, Side Plank 3x30s) counts as core sets.
            if kind == .stability && d.name != "Glute Bridge Hold" {
                it.sets = Int(d.scheme.split(separator: "x").first ?? "") ?? 0
                it.muscles = ["Core": 1]
            }
            items.append(it)
            spent += t
        }
        return items
    }

    static func zone2Name(_ ctx: Ctx) -> String {
        if ctx.gear.contains(.machine) { return "Zone 2 Cardio (bike, rower or incline walk)" }
        if ctx.injuries.contains("Knee") { return "Zone 2 Cardio (cycling, swimming or brisk walk)" }
        return "Zone 2 Cardio (brisk walk or easy jog)"
    }

    /// Mobility and recovery days open with a gentle pulse raise.
    static func gentleRaise(_ minutes: Double) -> Item {
        Item(kind: .warmup, name: "Warm-up: Gentle Pulse Raise (slow walk, marching, arm swings)", minutes: minutes, aerobic: minutes * 0.5)
    }

    static func zone2(_ minutes: Double, ctx: Ctx) -> Item {
        Item(kind: .cardio, name: zone2Name(ctx), minutes: minutes.rounded(), aerobic: minutes.rounded())
    }

    static func strengthLabel(_ t: Template, _ i: Intensity, variant: Int) -> String {
        let tag: String
        switch i {
        case .heavy: tag = "Heavy"
        case .hypertrophy: tag = "Hypertrophy"
        case .endurance: tag = "Strength-Endurance"
        case .circuit: tag = "Strength Circuit"
        default: tag = "Strength"
        }
        // Every distinct workout has its own name, so its lifts and set
        // counts can be tracked from one week to the next.
        let letter = ["A", "B", "C", "D", "E", "F"][variant % 6]
        switch t {
        case .fullBody: return "Full Body \(tag) \(letter)"
        case .upper: return "Upper Body \(tag) \(letter)"
        case .lower: return "Lower Body \(tag) \(letter)"
        case .push: return "Push \(tag) \(letter)"
        case .pull: return "Pull \(tag) \(letter)"
        case .legs: return "Legs \(tag) \(letter)"
        default: return "\(t.rawValue.capitalized) \(tag) \(letter)"
        }
    }

    /// Longest a session of this type runs. The chosen session length is a
    /// ceiling, not a target: cardio and recovery days are not padded with
    /// drills, and strength/size plans keep Zone 2 short (interference).
    static func sessionCap(_ kind: Kind, ctx: Ctx) -> Double {
        let len = ctx.length
        switch kind {
        case .strength, .mixed: return len
        case .intervals: return min(len, ctx.goal == .longevity ? 55 : 50)
        case .gentleIntervals: return min(len, ctx.goal == .longevity ? 50 : 45)
        case .mobility: return min(len, ctx.goal == .increaseFlexibility ? 45 : 40)
        case .recovery: return min(len, 40)
        case .zone2: return ctx.healthGoal ? len : min(len, 45)
        }
    }

    static func intervalMode(_ ctx: Ctx) -> String {
        if ctx.gear.contains(.machine) { return "bike or rower" }
        if ctx.injuries.contains("Knee") { return "bike or uphill walk" }
        return "hill run or fast uphill walk"
    }

    // MARK: - Warm-up

    /// A dynamic warm-up drill: (name with its dose, body area, injury flags, gear needed or nil).
    struct WarmDrill { let name: String; var flags: Set<String> = []; var gear: Set<Gear>? = nil }

    /// Dynamic drills by the area the session loads (0 push, 1 pull, 2 knee-dominant, 3 hip hinge, 4 running/cycling).
    static let warmDrills: [Int: [WarmDrill]] = [
        0: [WarmDrill(name: "Scapular Push-ups (10)"), WarmDrill(name: "Wall Slides (10)", flags: ["Shoulder"]),
            WarmDrill(name: "Band Pull-Aparts (15)", gear: [.band, .cable]), WarmDrill(name: "Arm Circles (10 each way)")],
        1: [WarmDrill(name: "Open-Book T-Spine Rotations (8 each side)"), WarmDrill(name: "Band Pull-Aparts (15)", gear: [.band, .cable]),
            WarmDrill(name: "Arm Circles (10 each way)"), WarmDrill(name: "Prone Swimmers (8)")],
        2: [WarmDrill(name: "Leg Swings (10 each leg)"), WarmDrill(name: "Knee-to-Wall Ankle Rocks (10 each side)"),
            WarmDrill(name: "Spiderman Lunge with Reach (5 each side)", flags: ["Knee"]), WarmDrill(name: "Slow Bodyweight Box Squats (8)")],
        3: [WarmDrill(name: "Hip Hinge Drill (10)"), WarmDrill(name: "Bodyweight Glute Bridges (12)"),
            WarmDrill(name: "Leg Swings (10 each leg)"), WarmDrill(name: "Inchworm Walkouts (5)", flags: ["Low back"])],
        4: [WarmDrill(name: "Leg Swings (10 each leg)"), WarmDrill(name: "Walking Knee Hugs (8 each leg)"),
            WarmDrill(name: "Knee-to-Wall Ankle Rocks (10 each side)"), WarmDrill(name: "Build-up Efforts (3 x 20 s, getting faster)")],
    ]

    /// Warm-up minutes for a strength or Strength + Zone 2 session:
    /// (pulse raise, number of 1-minute drills, ramp-up sets).
    /// Ramp-up sets: 2-3 lighter sets with changeovers take about 3 minutes
    /// (2 in short sessions, which use fewer and smaller jumps).
    /// Strength and size keep 3 drills at 45+ min so the lifts keep their time;
    /// health goals take a 4th (mobility is part of the goal).
    static func strengthWarmup(_ len: Double, ctx: Ctx) -> (raise: Double, drills: Int, ramp: Double) {
        if len >= 45 { return (5, ctx.healthGoal ? 4 : 3, 3) }
        if len >= 30 { return (3, 3, 2) }
        return (2, 3, 2)
    }

    /// A lift that takes external load with this gear (bar, dumbbell,
    /// kettlebell, cable or machine): only those have a working weight to
    /// ramp up to. Push-ups, pull-ups or single-leg hinges get a practice set.
    static func isLoadable(_ it: Item, ctx: Ctx) -> Bool {
        !it.gear.intersection(ctx.gear).isDisjoint(with: [.barbell, .dumbbell, .kettlebell, .cable, .machine])
    }

    static func pulseRaiseName(_ ctx: Ctx) -> String {
        if ctx.gear.contains(.machine) { return "Warm-up: Easy Cardio (bike, rower or brisk incline walk)" }
        if ctx.injuries.contains("Knee") { return "Warm-up: Easy Cardio (bike or brisk walk)" }
        return "Warm-up: Easy Cardio (brisk walk, marching or easy jog)"
    }

    /// `count` 1-minute dynamic drills for the given areas, taken in turn:
    /// each area's list in order, skipping drills already taken, blocked by
    /// an injury, missing their gear, or in `exclude`.
    static func warmDrillItems(areas: [Int], count: Int, ctx: Ctx, exclude: Set<String> = []) -> [Item] {
        var out: [Item] = []
        var taken = exclude
        let areas = areas.isEmpty ? [2, 0, 1] : areas
        var k = 0
        while out.count < count && k < 40 {
            let a = areas[k % areas.count]
            k += 1
            guard let d = (warmDrills[a] ?? []).first(where: { d in
                d.flags.isDisjoint(with: ctx.injuries) && (d.gear.map { !$0.isDisjoint(with: ctx.gear) } ?? true) && !taken.contains(d.name)
            }) else { continue }
            taken.insert(d.name)
            out.append(Item(kind: .warmup, name: "Warm-up: \(d.name)", minutes: 1, warmDrill: true))
        }
        return out
    }

    static let buildUps = "Build-up Efforts (3 x 20 s, getting faster)"

    /// The warm-up for a lifting session, built from its lifts: an easy
    /// pulse raise, dynamic drills for the patterns the session loads, and
    /// ramp-up sets on the first main lift.
    static func liftWarmup(for lifts: [Item], ctx: Ctx, len: Double) -> [Item] {
        let w = strengthWarmup(len, ctx: ctx)
        var areas: [Int] = []
        for it in lifts {
            let a: Int?
            switch it.pattern {
            case .hPush?, .vPush?: a = 0
            case .hPull?, .vPull?: a = 1
            case .squat?, .lunge?: a = 2
            case .hinge?: a = 3
            default: a = nil
            }
            if let a, !areas.contains(a) { areas.append(a) }
        }
        var items = [Item(kind: .warmup, name: pulseRaiseName(ctx), minutes: w.raise)]
        let first = lifts.first(where: { $0.kind == .lift && ($0.pattern?.isCompound ?? false) }) ?? lifts.first(where: { $0.kind == .lift })
        // Bodyweight first lift: no working weight to build to, so one easy
        // practice set (1 min; the session simply runs that much shorter).
        let loadable = first.map { isLoadable($0, ctx: ctx) } ?? false
        items += warmDrillItems(areas: areas, count: w.drills, ctx: ctx)
        if let first {
            if loadable {
                items.append(Item(kind: .warmup, name: "Warm-up: Ramp-up Sets for \(first.name) (2-3 lighter sets building to your working weight)",
                                  minutes: w.ramp))
            } else {
                items.append(Item(kind: .warmup, name: "Warm-up: Practice Set of \(first.name) (1 easy set at half your reps)", minutes: 1))
            }
        } else if w.ramp > 0 {
            items += warmDrillItems(areas: areas, count: Int(w.ramp), ctx: ctx, exclude: Set(items.map { String($0.name.dropFirst(9)) }))
        }
        return items
    }

    /// Minutes a lifting session's warm-up takes (planned before the lifts are picked).
    static func liftWarmupMinutes(_ len: Double, ctx: Ctx) -> Double {
        let w = strengthWarmup(len, ctx: ctx)
        return w.raise + Double(w.drills) + w.ramp
    }

    /// `avoid`: drills (and lifts) from the neighbouring day, not repeated.
    static func build(_ spec: Spec, ctx: Ctx, avoid: Set<String> = []) -> Session {
        let len = sessionCap(spec.kind, ctx: ctx)
        var used = avoid
        var items: [Item] = []
        var label: String
        let mobFinisher: Double = ctx.goal == .longevity || ctx.goal == .increaseFlexibility
            ? (len >= 45 ? 10 : 5) : (len >= 45 ? 5 : 0)
        var budget = len
        switch spec.kind {
        case .strength:
            let groups = spec.groups.isEmpty ? [spec.template ?? .fullBody] : spec.groups
            var pats: [Pattern] = []
            if groups.count == 1 {
                pats = patterns(groups[0], variant: spec.variant)
            } else {
                let lists = groups.map { patterns($0, variant: spec.variant) }
                for i in 0..<(lists.map(\.count).max() ?? 0) { for l in lists where i < l.count { pats.append(l[i]) } }
            }
            // The warm-up's dynamic drills already cover part of the mobility,
            // so the closing mobility block is shorter than on other days.
            // (Flexibility keeps the full block: mobility is its goal.)
            let finisher = spec.groups.isEmpty ? (mobFinisher >= 10 && ctx.goal != .increaseFlexibility ? 5 : mobFinisher) : 0
            // The warm-up's time comes off the lifts, never the other way round.
            budget = len - finisher - liftWarmupMinutes(len, ctx: ctx)
            items = strengthItems(patterns: pats, variant: spec.variant, intensity: spec.intensity,
                                  budget: budget, ctx: ctx, used: &used)
            items = liftWarmup(for: items, ctx: ctx, len: len) + items
            // Longevity: no core lift in the session -> the closing block starts with core stability.
            let noCore = !items.contains { $0.kind == .lift && ($0.pattern == .core || $0.pattern == .carry) }
            items += drills(minutes: finisher, balance: ctx.goal == .longevity, stability: false, offset: spec.variant * 3, ctx: ctx, used: &used,
                            coreFirst: ctx.jointSafe && noCore)
            // "Heavy" only when a heavy-capable lift is actually in the session.
            let shown = spec.intensity == .heavy && !items.contains(where: \.heavyLoad) ? Intensity.endurance : spec.intensity
            label = spec.label ?? strengthLabel(groups[0], shown, variant: spec.variant)
            if spec.label == nil && items.contains(where: \.superset) { label += " (Push/Pull Superset)" }
        case .mixed:
            let t = spec.template ?? .fullBody
            let warm = liftWarmupMinutes(len, ctx: ctx)
            let fin = len >= 45 ? min(mobFinisher, 8) : 0
            // Lifts keep their share; at least 10 minutes of Zone 2 stay after them.
            budget = max(8, min(max((len * 0.55).rounded(), min(len, 20)) - 5, len - warm - fin - 10))
            items = strengthItems(patterns: patterns(t, variant: spec.variant), variant: spec.variant,
                                  intensity: spec.intensity, budget: budget, ctx: ctx, used: &used)
            let lifted = items.reduce(0) { $0 + $1.duration }
            items = liftWarmup(for: items, ctx: ctx, len: len) + items
            let rest = max(10, len - lifted - items.filter { $0.kind == .warmup }.reduce(0) { $0 + $1.minutes } - fin)
            if ctx.goal == .increaseFlexibility {
                items += drills(minutes: rest + fin, balance: true, stability: true, offset: spec.variant * 2, ctx: ctx, used: &used)
                label = "Strength + Mobility \(["A", "B", "C", "D", "E", "F"][spec.variant % 6])"
            } else {
                // Longevity: core stability comes before Zone 2 when no lift trains the core.
                let noCore = !items.contains { $0.kind == .lift && ($0.pattern == .core || $0.pattern == .carry) }
                var z = rest
                if ctx.jointSafe && noCore && fin == 0 && rest >= 12.5 {
                    items += drills(minutes: 2.5, balance: false, stability: true, offset: spec.variant * 2 + 5, ctx: ctx, used: &used, coreFirst: true)
                    z = rest - items.filter { $0.kind == .stability }.reduce(0) { $0 + $1.minutes }
                }
                items.append(zone2(z, ctx: ctx))
                items += drills(minutes: fin, balance: ctx.goal == .longevity, stability: false, offset: spec.variant * 2 + 5, ctx: ctx, used: &used,
                                coreFirst: ctx.jointSafe && noCore)
                label = "Strength + Zone 2 \(["A", "B", "C", "D", "E", "F"][spec.variant % 6])"
            }
        case .zone2:
            let mob: Double = len >= 40 ? (ctx.healthGoal ? 10 : 5) : 0
            // A gradual build into Zone 2 is the warm-up.
            let build: Double = len >= 30 ? 5 : 3
            items = [Item(kind: .warmup, name: "Warm-up: Easy Build to Zone 2 (start very easy, raise the pace gradually)",
                          minutes: build, aerobic: build),
                     zone2(len - mob - build, ctx: ctx)]
            items += drills(minutes: mob, balance: ctx.goal == .longevity, stability: false, offset: spec.variant * 4 + 1, ctx: ctx, used: &used)
            label = ctx.goal == .longevity && mob > 0 ? "Zone 2 + Mobility & Balance" : (mob > 0 ? "Zone 2 + Mobility" : "Zone 2 Cardio")
        case .intervals:
            // Short sessions: a shorter warm-up and 3-min efforts keep at
            // least 12 minutes at high intensity.
            let short = len < 45
            let warm: Double = short ? 6 : 10, cool: Double = short ? 4 : 5
            let bal: Double = ctx.goal == .longevity && len >= 45 ? 5 : 0
            let hard = short ? 3 : 4, easy = short ? 2 : 3
            let reps = short ? min(5, max(3, Int((len - warm - cool) / 5))) : min(6, max(4, Int((len - warm - cool - bal) / 7)))
            let block = Double(reps * (hard + easy))
            // Warm-up: easy cardio, then dynamic leg drills and build-ups.
            let nDrills = short ? 2 : 3
            let raise = warm - Double(nDrills)
            items = [Item(kind: .warmup, name: "Warm-up: Easy Cardio (same machine or route as the intervals)", minutes: raise, aerobic: raise)]
            // Leg drills, then build-up efforts last, so the first hard effort
            // never comes cold.
            items += warmDrillItems(areas: [4], count: nDrills - 1, ctx: ctx, exclude: [buildUps])
            items.append(Item(kind: .warmup, name: "Warm-up: \(buildUps)", minutes: 1, warmDrill: true))
            items += [Item(kind: .intervals, name: "VO2max Intervals: \(hard) min hard / \(easy) min easy (\(intervalMode(ctx)))", sets: reps,
                          reps: "\(reps)x\(hard * 60)s", minutes: block, aerobic: Double(reps * hard * 2 + reps * easy)),
                     Item(kind: .cardio, name: "Easy Cool-down", minutes: cool, aerobic: cool)]
            items += drills(minutes: min(bal, max(0, len - warm - cool - block)), balance: true, stability: false,
                            offset: spec.variant * 2 + 3, ctx: ctx, used: &used)
            label = ctx.goal == .longevity && items.contains(where: { $0.kind == .balance }) ? "VO2max Intervals + Balance" : "VO2max Intervals"
        case .gentleIntervals:
            let short = len < 40
            let warm: Double = short ? 5 : 8, cool: Double = short ? 3 : 5
            let bal: Double = ctx.goal == .longevity && !short ? 5 : 0
            let reps = min(10, max(4, Int((len - warm - cool - bal) / 3)))
            let block = Double(reps * 3)
            let raise = warm - 2
            items = [Item(kind: .warmup, name: "Warm-up: Easy Walk, building to brisk", minutes: raise, aerobic: raise)]
            items += warmDrillItems(areas: [4], count: 2, ctx: ctx, exclude: [buildUps])
            items += [Item(kind: .intervals, name: "Uphill Walk Intervals: 1 min brisk / 2 min easy", sets: reps,
                          reps: "\(reps)x60s", minutes: block, aerobic: Double(reps * 4)),
                     Item(kind: .cardio, name: "Easy Cool-down", minutes: cool, aerobic: cool)]
            items += drills(minutes: min(max(bal, 2.5), max(0, len - warm - cool - block)), balance: true, stability: false,
                            offset: spec.variant * 2 + 3, ctx: ctx, used: &used)
            label = items.contains(where: { $0.kind == .balance }) ? "Gentle Intervals + Balance" : "Gentle Intervals"
        case .mobility:
            let raise: Double = 3
            items = [gentleRaise(raise)]
            let walk: Double = len >= 40 && ctx.goal != .increaseFlexibility ? 12 : 0
            if walk > 0 { items.append(Item(kind: .walk, name: "Easy Walk", minutes: walk, aerobic: walk * 0.5)) }
            items += drills(minutes: len - walk - raise, balance: true, stability: true, offset: spec.variant * 5, ctx: ctx, used: &used)
            label = "Mobility, Balance & Core"
        case .recovery:
            let raise: Double = 3
            let walk = (len * 0.6).rounded() - raise
            items = [gentleRaise(raise), Item(kind: .walk, name: "Easy Walk", minutes: walk, aerobic: walk * 0.5)]
            items += drills(minutes: len - walk - raise, balance: false, stability: false, offset: spec.variant * 5 + 2, ctx: ctx, used: &used)
            label = "Recovery: Easy Walk + Mobility"
        }
        return Session(spec: spec, label: label, items: items, budget: budget)
    }

    // MARK: - Training-day sequence

    static func weekdays(for config: ProgramConfig) -> [String] {
        let weekOrder = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        var days = weekOrder.filter { config.weekdays.contains($0) }
        if days.count < config.daysPerWeek {
            for d in weekOrder where !days.contains(d) && days.count < config.daysPerWeek { days.append(d) }
            days = weekOrder.filter { days.contains($0) }
        }
        return Array(days.prefix(max(1, config.daysPerWeek)))
    }

    /// One block of training slots: 2 weeks (weekly) or enough rolling cycles
    /// to cover ~2 weeks (max 42 entries). `start` aligns weekly slot 0 with
    /// the first training day on/after the program start.
    /// `cycleMultiple`: rolling blocks hold a whole number of planning units.
    static func slots(for config: ProgramConfig, start: Date?, calendar: Calendar = .current,
                      cycleMultiple: Int = 1) -> (slots: [Slot], blockDays: Int) {
        if config.scheduleMode == .rolling {
            let on = max(1, config.daysOn), off = max(0, config.daysOff), cycle = on + off
            let k = max(1, cycleMultiple)
            var c = max(1, Int((14.0 / Double(cycle)).rounded(.up)))
            c = Int((Double(c) / Double(k)).rounded(.up)) * k
            while c > k && c * on > 42 { c -= k }
            var out: [Slot] = []
            for ci in 0..<c {
                for d in 0..<on {
                    out.append(Slot(label: "Day \(d + 1) · Cycle \(ci + 1)", day: ci * cycle + d, restBefore: d == 0 ? off : 0, cycle: ci))
                }
            }
            return (out, c * cycle)
        }
        let weekOrder = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let days = weekdays(for: config)
        var startIdx = 0
        if let start {
            startIdx = (calendar.component(.weekday, from: start) + 5) % 7  // Monday = 0
        }
        let offs = days.map { ((weekOrder.firstIndex(of: $0) ?? 0) - startIdx + 7) % 7 }
        let order = zip(days, offs).sorted { $0.1 < $1.1 }
        var out: [Slot] = []
        for w in 0..<2 {
            for (name, o) in order {
                out.append(Slot(label: "\(name) · Wk \(w + 1)", day: w * 7 + o, restBefore: 0, cycle: w))
            }
        }
        var fixed: [Slot] = []
        for (i, s) in out.enumerated() {
            let prev = i == 0 ? out[out.count - 1].day - 14 : out[i - 1].day
            fixed.append(Slot(label: s.label, day: s.day, restBefore: max(0, s.day - prev - 1), cycle: s.cycle))
        }
        return (fixed, 14)
    }

    /// Most hard sessions that fit with none on consecutive days.
    static func hardCapacity(_ slots: [Slot]) -> Int {
        guard !slots.isEmpty else { return 0 }
        if slots.allSatisfy({ $0.restBefore == 0 }) { return max(1, slots.count / 2) }
        var runs: [Int] = []
        let start = slots.firstIndex { $0.restBefore > 0 } ?? 0
        var len = 0
        for k in 0..<slots.count {
            let s = slots[(start + k) % slots.count]
            if s.restBefore > 0 && len > 0 { runs.append(len); len = 0 }
            len += 1
        }
        runs.append(len)
        return runs.reduce(0) { $0 + ($1 + 1) / 2 }
    }

    // MARK: - Placement (recovery model)

    static func decay(_ rest: Int) -> Double { rest == 0 ? 1 : rest == 1 ? 0.35 : 0.1 }

    /// Both sessions load the same body region (upper or lower) hard.
    static func overlap(_ a: [Int], _ b: [Int]) -> Bool { (a[0] >= 2 && b[0] >= 2) || (a[1] >= 2 && b[1] >= 2) }

    /// Recovery cost of a sequence. Lower is better.
    static func cost(_ specs: [Spec], slots: [Slot], health: Bool, blockDays: Int) -> Double {
        let n = specs.count
        guard n > 1 else { return 0 }
        var c = 0.0
        let fat = specs.map(\.fatigue)
        for i in 0..<n {
            let j = (i + 1) % n
            let d = decay(slots[j].restBefore)
            let a = fat[i], b = fat[j]
            c += Double(max(0, a[0] - 1) * max(0, b[0] - 1)) * 3 * d
            c += Double(max(0, a[1] - 1) * max(0, b[1] - 1)) * 3 * d
            c += Double(max(0, a[2] - 1) * max(0, b[2] - 1)) * (health ? 4 : 1) * d
            // Two hard days in a row: barred when they load the same region;
            // tolerated (VO2max after an upper-only day) when they do not.
            if specs[i].isHard && specs[j].isHard { c += (overlap(a, b) ? (health ? 50 : 3) : (health ? 6 : 1)) * d }
            if specs[i].kind == specs[j].kind && specs[i].kind != .strength && slots[j].restBefore == 0 { c += 1 }
            // Intervals sit just before a rest day when they can.
            if (specs[i].kind == .intervals || specs[i].kind == .gentleIntervals) && slots[j].restBefore > 0 { c -= 10 }
            // Hardest sessions straight after rest.
            c -= 0.4 * Double(specs[j].load) * Double(min(2, slots[j].restBefore))
        }
        // Every cycle gets the same number of strength days.
        var perCycle: [Int: Int] = [:]
        for (i, s) in specs.enumerated() { perCycle[slots[i].cycle, default: 0] += s.kind == .strength || s.kind == .mixed ? 1 : 0 }
        if perCycle.count > 1 { c += 4 * Double(perCycle.values.max()! - perCycle.values.min()!) }
        // Spread repeats of a session type evenly over the block.
        var byKey: [String: [Int]] = [:]
        for (i, s) in specs.enumerated() where s.kind != .mobility && s.kind != .recovery {
            byKey["\(s.kind.rawValue)|\(s.template?.rawValue ?? "")", default: []].append(slots[i].day)
        }
        for (key, days) in byKey where days.count > 1 {
            let ideal = Double(blockDays) / Double(days.count)
            let w = key.hasPrefix("zone2") ? 0.1 : 0.5
            for k in 0..<days.count {
                let gap = k + 1 < days.count ? days[k + 1] - days[k] : days[0] + blockDays - days[k]
                c += max(0, ideal - Double(gap)) * w
            }
        }
        return c
    }

    static func place(_ input: [Spec], slots: [Slot], health: Bool, blockDays: Int) -> [Spec] {
        let n = slots.count
        guard input.count == n, n > 1 else { return input }
        // Initial order: hard sessions on non-adjacent slots, after rests first.
        let hard = input.filter(\.isHard).sorted { $0.load > $1.load }
        var others = input.filter { !$0.isHard }
        var taken = [Bool](repeating: false, count: n)
        var order = [Spec?](repeating: nil, count: n)
        let prio = (0..<n).sorted { (slots[$0].restBefore, -$0) > (slots[$1].restBefore, -$1) }
        func blocked(_ p: Int) -> Bool {
            let prev = (p - 1 + n) % n, next = (p + 1) % n
            return (slots[p].restBefore == 0 && taken[prev]) || (slots[next].restBefore == 0 && taken[next])
        }
        var h = 0
        for pass in 0..<2 {
            for p in prio where h < hard.count && order[p] == nil && (pass == 1 || !blocked(p)) {
                order[p] = hard[h]; taken[p] = true; h += 1
            }
        }
        // Others round-robin by kind for variety.
        others.sort { $0.kind.rawValue < $1.kind.rawValue }
        var groups: [[Spec]] = []
        for s in others {
            if let gi = groups.firstIndex(where: { $0[0].kind == s.kind }) { groups[gi].append(s) } else { groups.append([s]) }
        }
        var rr: [Spec] = []
        while groups.contains(where: { !$0.isEmpty }) {
            for gi in groups.indices where !groups[gi].isEmpty { rr.append(groups[gi].removeFirst()) }
        }
        var oi = 0
        for p in 0..<n where order[p] == nil { order[p] = rr[oi]; oi += 1 }
        var seq = order.map { $0! }
        // Local search: best-improvement pairwise swaps.
        var best = cost(seq, slots: slots, health: health, blockDays: blockDays)
        for _ in 0..<200 {
            var bestSwap: (Int, Int)? = nil
            var bestCost = best - 1e-9
            for i in 0..<n {
                for j in (i + 1)..<n {
                    if seq[i].kind == seq[j].kind && seq[i].template == seq[j].template && seq[i].intensity == seq[j].intensity { continue }
                    seq.swapAt(i, j)
                    let c = cost(seq, slots: slots, health: health, blockDays: blockDays)
                    seq.swapAt(i, j)
                    if c < bestCost { bestCost = c; bestSwap = (i, j) }
                }
            }
            guard let (i, j) = bestSwap else { break }
            seq.swapAt(i, j); best = bestCost
        }
        return seq
    }

    /// Variants in order of appearance: Full Body A, B, C, A... A Strength +
    /// Zone 2 day shares the counter with strength days of the same template,
    /// so it never repeats the lifts of the strength day next to it.
    static func assignVariants(_ specs: [Spec]) -> [Spec] {
        var counts: [String: Int] = [:]
        return specs.map { s in
            var s = s
            let kind = s.kind == .mixed && s.groups.isEmpty ? Kind.strength.rawValue : s.kind.rawValue
            let key = "\(kind)|\(s.template?.rawValue ?? (s.kind == .mixed ? Template.fullBody.rawValue : s.groups.map(\.rawValue).joined()))|\(s.label ?? "")"
            s.variant = counts[key, default: 0]
            counts[key, default: 0] += 1
            return s
        }
    }

    // MARK: - Goal templates

    static func strengthIntensity(_ goal: TrainingGoal) -> Intensity {
        switch goal {
        case .buildMuscle: return .hypertrophy
        case .getStronger: return .heavy
        case .longevity: return .foundation
        case .improveEndurance: return .endurance
        case .loseWeight: return .circuit
        case .increaseFlexibility, .generalFitness: return .general
        }
    }

    static func candidates(ctx: Ctx, slots: [Slot], blockDays: Int) -> [[Spec]] {
        let n = slots.count
        let w = Double(blockDays) / 7
        let f = Double(n) / w
        func blk(_ perWeek: Double) -> Int { Int((perWeek * w).rounded()) }
        let intensity = strengthIntensity(ctx.goal)
        var out: [[Spec]] = []

        func fill(_ base: [Spec], restKinds: [Kind]) -> [Spec] {
            var s = base
            var k = 0
            while s.count < n { s.append(Spec(kind: restKinds[k % restKinds.count])); k += 1 }
            return Array(s.prefix(n))
        }

        if ctx.goal == .buildMuscle || ctx.goal == .getStronger {
            let cap = ctx.goal == .buildMuscle ? (ctx.beginner ? 4.0 : 6.0) : (ctx.beginner ? 3.0 : 4.0)
            var perWeekOptions = [min(f, cap)]
            if min(f, cap) - 1 >= 2 { perWeekOptions.append(min(f, cap) - 1) }
            for pw in perWeekOptions {
                let s = max(1, min(n, blk(pw)))
                var templates: [[Spec]] = []
                let i = intensity
                templates.append((0..<s).map { _ in Spec(kind: .strength, template: .fullBody, intensity: i) })
                // Size at 2-3 sessions a week: full body only, so every muscle
                // is trained each session (upper/lower would give 1.5x a week).
                let fullBodyOnly = ctx.goal == .buildMuscle && pw < 3.5
                if s >= 2 && !fullBodyOnly {
                    if ctx.goal == .getStronger {
                        let cyc: [Spec] = [Spec(kind: .strength, template: .upper, intensity: .heavy), Spec(kind: .strength, template: .lower, intensity: .heavy),
                                           Spec(kind: .strength, template: .upper, intensity: .hypertrophy), Spec(kind: .strength, template: .lower, intensity: .hypertrophy)]
                        templates.append((0..<s).map { cyc[$0 % 4] })
                        let lu: [Spec] = [Spec(kind: .strength, template: .lower, intensity: .heavy), Spec(kind: .strength, template: .upper, intensity: .heavy),
                                          Spec(kind: .strength, template: .fullBody, intensity: .heavy)]
                        templates.append((0..<s).map { lu[$0 % 3] })
                    } else {
                        templates.append((0..<s).map { Spec(kind: .strength, template: $0 % 2 == 0 ? .upper : .lower, intensity: i) })
                    }
                }
                if ctx.goal == .buildMuscle && !ctx.beginner && pw >= 5 {
                    let ppl: [Template] = [.push, .pull, .legs]
                    let pul: [Template] = [.push, .pull, .legs, .upper, .lower]
                    templates.append((0..<s).map { Spec(kind: .strength, template: ppl[$0 % 3], intensity: i) })
                    templates.append((0..<s).map { Spec(kind: .strength, template: pul[$0 % 5], intensity: i) })
                }
                for t in templates {
                    out.append(fill(t, restKinds: [.zone2, .recovery]))
                    if n - s >= 2 { out.append(fill(t, restKinds: [.zone2, .mobility])) }
                }
            }
            return out
        }

        // Health goals: strength, VO2 work, aerobic and mobility as weekly targets.
        // Longevity on two days a week: both are Strength + Zone 2 (walks on
        // rest days cover the rest of the aerobic target).
        if ctx.goal == .longevity && f <= 2.5 {
            return [(0..<n).map { _ in Spec(kind: .mixed, template: .fullBody, intensity: intensity) }]
        }
        let strengthOpts: [Double]
        var intervalOpts: [Double]
        var mixedOpts: [Double] = [0, 1, 2]
        let restKinds: [[Kind]]
        switch ctx.goal {
        case .longevity:
            // Short sessions may trade the VO2max day for a second strength day
            // (they cannot pair an upper day with it); the score decides.
            strengthOpts = [2, 2.5, 3]; intervalOpts = f >= 3 ? (ctx.length < 45 ? [1, 0] : [1]) : [0]
            restKinds = [[.zone2, .mobility], [.zone2, .zone2, .mobility], [.zone2, .recovery]]
        case .loseWeight:
            strengthOpts = f >= 3 ? [3] : [2]; intervalOpts = f >= 6 && !ctx.beginner ? [1, 2] : f >= 4 ? [1] : [0]
            restKinds = [[.zone2], [.zone2, .recovery]]
        case .improveEndurance:
            // Mostly aerobic: a long Zone 2 day and an interval day come
            // first; strength is 1 session at 3 days a week, 2 from 4 days.
            strengthOpts = f <= 2.5 ? [0] : f <= 3.5 ? [1] : [2]
            intervalOpts = f >= 5 && !ctx.beginner ? [1, 2] : [1]
            mixedOpts = [0]
            restKinds = f >= 5 ? [[.zone2], [.zone2, .zone2, .recovery]] : [[.zone2]]
        case .increaseFlexibility:
            strengthOpts = [2]; intervalOpts = [0]
            restKinds = [[.mobility], [.mobility, .mobility, .zone2]]
        default:
            strengthOpts = [2, 3]; intervalOpts = f >= 4 ? [1] : [0]
            restKinds = [[.zone2, .mobility], [.mobility, .zone2]]
        }
        if intervalOpts.isEmpty { intervalOpts = [0] }
        let cap = hardCapacity(slots)
        let intervalKind: Kind = ctx.beginner ? .gentleIntervals : .intervals
        for so in strengthOpts {
            for io in intervalOpts {
                for mo in mixedOpts {
                    var s = blk(so), i = max(io > 0 ? 1 : 0, blk(io)), m = blk(mo)
                    if f <= 2.5 { s = min(s, n); m = 0 }
                    if ctx.goal == .improveEndurance { i = min(i, max(0, n - 1)) }
                    while s + i + m > n && m > 0 { m -= 1 }
                    while s + i + m > n && i > 0 { i -= 1 }
                    while s + i + m > n && s > 1 { s -= 1 }
                    // Strength + Zone 2 counts as hard, like any loaded day.
                    let hardI = intervalKind == .intervals ? i : 0
                    var excess = s + hardI + m - cap
                    while excess > 0 && m > 0 { m -= 1; excess -= 1 }
                    // VO2max may follow an upper-only strength day (legs rested):
                    // tried both with that pairing and with one strength day fewer.
                    // Short sessions never pair: an upper day under 45 min leaves the
                    // week with almost no hinge, hamstring or core work.
                    for pair in excess > 0 && hardI > 0 && s >= 2 && ctx.length >= 45 ? [true, false] : [false] {
                        var s = s, i = i, excess = excess
                        var upper = 0
                        if pair { upper = 1; excess -= 1 }
                        while excess > 0 && s > 1 { s -= 1; excess -= 1 }
                        while excess > 0 && i > 0 { i -= 1; excess -= 1 }
                        if i == 0 || s < 2 { upper = 0 }
                        var base: [Spec] = []
                        base += (0..<s).map { k in Spec(kind: .strength, template: k < upper ? .upper : .fullBody, intensity: intensity) }
                        base += (0..<i).map { _ in Spec(kind: intervalKind) }
                        base += (0..<m).map { _ in Spec(kind: .mixed, template: .fullBody, intensity: intensity) }
                        for rk in restKinds { out.append(fill(base, restKinds: rk)) }
                    }
                }
            }
        }
        if f <= 2.5 && ctx.goal != .improveEndurance {
            out.append((0..<n).map { _ in Spec(kind: .mixed, template: .fullBody, intensity: intensity) })
        }
        return out
    }

    // MARK: - Volume

    struct VolumeLine: Equatable {
        let group: String
        var sets: Double          // per week
        let target: ClosedRange<Int>
        let mrv: Int
        var inRange: Bool { sets >= Double(target.lowerBound) - 0.01 && sets <= Double(target.upperBound) + 0.01 }
        var status: String { sets < Double(target.lowerBound) ? "under" : sets > Double(target.upperBound) ? "over" : "ok" }
    }

    /// Weekly set range per landmark group for this goal and lifter.
    static func targetRange(group: String, config: ProgramConfig) -> ClosedRange<Int> {
        guard let lm = SmartCoach.landmarks.first(where: { $0.group == group }) else { return 0...0 }
        let beginner = config.experienceLevel == .beginner
        var lo: Int, hi: Int
        switch config.primaryGoal {
        case .buildMuscle:
            lo = beginner ? lm.mev : (lm.mev + lm.mav.lowerBound) / 2
            hi = beginner ? lm.mav.lowerBound + 2 : lm.mav.upperBound
        case .getStronger:
            lo = max(3, Int(Double(lm.mev) * 0.75))
            hi = beginner ? lm.mav.lowerBound : lm.mav.lowerBound + 2
        default:
            // Health goals: big movers get real work; arms and calves ride
            // along on compounds and need no direct floor.
            lo = majorGroups.contains(group) || group == "Core" ? max(2, Int((Double(lm.mev) * 0.5).rounded(.up))) : 0
            hi = beginner ? max(lo + 2, Int(Double(lm.mav.lowerBound) * 0.8)) : lm.mav.lowerBound
        }
        // No planned deloads over a long block: stay further from the ceiling.
        if !config.includeDeload && config.mesocycleWeeks >= 6 { hi = max(lo, Int(Double(hi) * 0.9)) }
        hi = min(hi, lm.mrv)
        return lo...max(lo, hi)
    }

    /// Pure: weekly sets per muscle group across the plan vs the goal range.
    static func volumeReport(_ plan: Plan) -> [VolumeLine] {
        muscleGroups.map { g in
            let total = plan.sessions.reduce(0) { $0 + $1.sets(of: g) }
            let lm = SmartCoach.landmarks.first { $0.group == g }
            return VolumeLine(group: g, sets: total / plan.weeks, target: targetRange(group: g, config: plan.config), mrv: lm?.mrv ?? 99)
        }
    }

    /// The volume report with core stability drills counted as core sets
    /// (floors only: the caps stay on lifted sets).
    static func longevityFloorReport(_ plan: Plan) -> [VolumeLine] {
        let drillCore = plan.sessions.reduce(0) { $0 + $1.stabilityCoreSets } / plan.weeks
        return volumeReport(plan).map { l in
            var l = l
            if l.group == "Core" { l.sets += drillCore }
            return l
        }
    }

    static func isoPattern(for group: String) -> [Pattern] {
        switch group {
        case "Chest": return [.chestIso, .hPush]
        case "Back": return [.hPull, .vPull]
        case "Shoulders": return [.lateral, .vPush]
        case "Biceps": return [.biceps]
        case "Triceps": return [.triceps]
        case "Quads": return [.quadIso, .squat]
        case "Hamstrings": return [.hamIso, .hinge]
        case "Glutes": return [.glute]
        case "Calves": return [.calf]
        default: return [.core]
        }
    }

    /// Moves weekly sets into each group's range. The top of the range is a
    /// hard cap: sets and accessories come off (sessions end early) rather
    /// than run over. Glute work over range with hamstrings short is swapped
    /// for a hamstring move. Size fills the largest shortfall first and keeps
    /// core/carries out until every major muscle has its minimum. Added sets
    /// go on the exercise already there for a pattern, not on a second variant.
    static func adjustVolume(_ plan: inout Plan, ctx: Ctx) {
        let size = ctx.goal == .buildMuscle
        let weeks = plan.weeks
        func lo(_ l: VolumeLine) -> Double { Double(l.target.lowerBound) }
        func hi(_ l: VolumeLine) -> Double { Double(min(l.mrv, l.target.upperBound)) }
        func majorsUnder(_ r: [VolumeLine]) -> Bool { r.contains { majorGroups.contains($0.group) && $0.sets < lo($0) - 0.01 } }
        func liftCount(_ si: Int) -> Int { plan.sessions[si].items.filter { $0.kind == .lift }.count }
        func step(_ it: Item) -> Double { it.superset ? it.perSet * 0.65 : it.perSet }
        func setCap(_ it: Item) -> Int { (it.pattern?.isCompound ?? false) || size ? ctx.maxSets : ctx.isoSets + 1 }
        func patternsIn(_ si: Int) -> Set<Pattern> { Set(plan.sessions[si].items.compactMap { $0.kind == .lift ? $0.pattern : nil }) }
        /// Lift names in this session and on the days right before and after it
        /// (no lift is added that repeats a neighbouring day's lift).
        func taken(_ si: Int) -> Set<String> {
            let n = plan.sessions.count
            var out = Set(plan.sessions[si].items.map(\.name))
            if n > 1 {
                if plan.slots[si].restBefore == 0 { out.formUnion(plan.sessions[(si - 1 + n) % n].items.filter { $0.kind == .lift }.map(\.name)) }
                let nx = (si + 1) % n
                if plan.slots[nx].restBefore == 0 { out.formUnion(plan.sessions[nx].items.filter { $0.kind == .lift }.map(\.name)) }
            }
            return out
        }

        if size && majorsUnder(volumeReport(plan)) {
            for si in plan.sessions.indices {
                plan.sessions[si].items.removeAll { $0.kind == .lift && !$0.essential && ($0.pattern == .core || $0.pattern == .carry) }
            }
        }
        var stuck = Set<String>(), stuckOver = Set<String>()
        for _ in 0..<600 {
            let report = volumeReport(plan)
            let by = Dictionary(uniqueKeysWithValues: report.map { ($0.group, $0) })
            // Removing `delta` sets of `it` keeps every other group at or above its floor.
            func safeToCut(_ it: Item, _ delta: Int, except g: String) -> Bool {
                it.muscles.allSatisfy { mg, wgt in
                    guard mg != g, let l = by[mg], l.sets >= lo(l) - 0.01 else { return true }
                    return l.sets - wgt * Double(delta) / weeks >= lo(l) - 0.01
                }
            }
            // 1) Glutes over while hamstrings are short: glute accessory -> hamstring move.
            if let gl = by["Glutes"], let hm = by["Hamstrings"], gl.sets > hi(gl) + 0.01, hm.sets < hi(hm) - 0.5 {
                var swapped = false
                outer: for si in plan.sessions.indices {
                    for ii in plan.sessions[si].items.indices where plan.sessions[si].items[ii].kind == .lift && plan.sessions[si].items[ii].pattern == .glute {
                        let it = plan.sessions[si].items[ii]
                        let used = taken(si)
                        var present = patternsIn(si); present.remove(.glute)
                        for p in [Pattern.hamIso, .hinge] where !present.contains(p) {
                            guard let m = ranked(p, ctx: ctx, intensity: plan.sessions[si].spec.intensity, used: used)
                                .first(where: { ($0.muscles["Hamstrings"] ?? 0) >= 1 }) else { continue }
                            if hm.sets + Double(it.sets) * 0.5 / weeks > hi(hm) + 0.01 { continue }
                            var n = makeItem(m, sets: it.sets, intensity: plan.sessions[si].spec.intensity, ctx: ctx)
                            n.superset = false
                            plan.sessions[si].items[ii] = n
                            swapped = true; break outer
                        }
                    }
                }
                if swapped { continue }
            }
            // 2) Over the cap: trim. Isolation for the group first, then its
            //    main lifts, then lifts it only assists; extras are removed
            //    once at 2 sets. Essential push/pull/lower lifts are never removed.
            if let over = report.filter({ $0.sets > hi($0) + 0.01 && !stuckOver.contains($0.group) })
                .max(by: { $0.sets - hi($0) < $1.sets - hi($1) }) {
                let g = over.group
                var best: (si: Int, ii: Int, remove: Bool, key: (Int, Double, Int))? = nil
                for si in plan.sessions.indices {
                    for (ii, it) in plan.sessions[si].items.enumerated() where it.kind == .lift {
                        let w = it.muscles[g] ?? 0
                        guard w > 0 else { continue }
                        let primary = w >= (it.muscles.values.max() ?? 0)
                        let iso = !(it.pattern?.isCompound ?? false)
                        let tier = iso && primary ? 0 : primary ? 1 : iso ? 2 : 3
                        var remove = false
                        if it.sets > 2 {
                            guard safeToCut(it, 1, except: g) else { continue }
                        } else if !it.essential && liftCount(si) > 3 {
                            guard safeToCut(it, it.sets, except: g) else { continue }
                            remove = true
                        } else { continue }
                        let key = (tier, -w, -it.sets)
                        if best == nil || key < best!.key { best = (si, ii, remove, key) }
                    }
                }
                if let b = best {
                    if b.remove { plan.sessions[b.si].items.remove(at: b.ii) } else { plan.sessions[b.si].items[b.ii].sets -= 1 }
                    continue
                }
                stuckOver.insert(g)
                continue
            }
            // 3) Under the floor: add, largest shortfall first for size.
            let holdCore = size && majorsUnder(report)
            var unders = report.filter { $0.sets < lo($0) - 0.01 && !stuck.contains($0.group) && !(holdCore && $0.group == "Core") }
            if size { unders.sort { lo($0) - $0.sets > lo($1) - $1.sets } }
            else { unders.sort { $0.sets / max(1, lo($0)) < $1.sets / max(1, lo($1)) } }
            guard let under = unders.first else { break }
            let g = under.group
            func wouldExceed(_ it: Item, _ delta: Int = 1) -> Bool {
                it.muscles.contains { mg, wgt in
                    guard let l = by[mg] else { return false }
                    return l.sets + wgt * Double(delta) / weeks > hi(l) + 0.01
                }
            }
            func canGive(_ it: Item, to receiver: Item?) -> Bool {
                guard it.kind == .lift, it.sets > 2, (it.muscles[g] ?? 0) == 0 else { return false }
                if it.pattern?.isCompound ?? false {
                    guard let rc = receiver, rc.pattern?.isCompound ?? false, it.sets > ctx.compoundSets else { return false }
                }
                return it.muscles.allSatisfy { mg, wgt in
                    guard let l = by[mg] else { return true }
                    return l.sets - wgt / weeks >= lo(l) + 1
                }
            }
            var done = false
            // a) a set on an existing lift where there is time; b) or shifted from a lift with room
            for si in plan.sessions.indices.sorted(by: { plan.sessions[$0].budget - plan.sessions[$0].strengthMinutes > plan.sessions[$1].budget - plan.sessions[$1].strengthMinutes }) {
                let s = plan.sessions[si]
                guard let ii = s.items.indices.filter({ i in
                    let it = s.items[i]
                    return it.kind == .lift && (it.muscles[g] ?? 0) >= 1 && it.sets < setCap(it) && !wouldExceed(it) })
                    .first else { continue }
                let it = s.items[ii]
                if s.strengthMinutes + step(it) <= s.budget + 0.01 {
                    plan.sessions[si].items[ii].sets += 1; done = true; break
                }
                if let di = s.items.indices.first(where: { canGive(s.items[$0], to: it) }),
                   s.strengthMinutes - step(s.items[di]) + step(it) <= s.budget + 0.01 {
                    plan.sessions[si].items[di].sets -= 1
                    plan.sessions[si].items[ii].sets += 1
                    done = true; break
                }
            }
            // c) an accessory on a strength day that already trains that region
            if !done {
                let region = ["Chest", "Back", "Shoulders", "Biceps", "Triceps"].contains(g) ? 0 : g == "Core" ? -1 : 1
                for si in plan.sessions.indices where plan.sessions[si].spec.kind == .strength
                    && (region < 0 || plan.sessions[si].fatigue[region] >= 2) {
                    let s = plan.sessions[si]
                    let present = patternsIn(si)
                    // The pattern is already in the session: no second variant of it.
                    if isoPattern(for: g).contains(where: { present.contains($0) }) { continue }
                    guard liftCount(si) < ctx.maxExercises else { continue }
                    var mv: Move? = nil
                    for p in isoPattern(for: g) {
                        if let m = pick(p, variant: 0, ctx: ctx, intensity: s.spec.intensity, used: taken(si), present: present),
                           (m.muscles[g] ?? 0) >= 1, !present.contains(m.pattern) { mv = m; break }
                    }
                    guard let m = mv else { continue }
                    let n = makeItem(m, sets: 2, intensity: s.spec.intensity, ctx: ctx)
                    if wouldExceed(n, 2) { continue }
                    let need = 2 * n.perSet + 1
                    var freed: [Int] = []
                    var room = s.budget - s.strengthMinutes
                    for di in s.items.indices where room < need && canGive(s.items[di], to: nil) {
                        freed.append(di); room += step(s.items[di])
                    }
                    guard room >= need else { continue }
                    for di in freed { plan.sessions[si].items[di].sets -= 1 }
                    let at = plan.sessions[si].items.lastIndex { $0.kind == .lift }.map { $0 + 1 } ?? 0
                    plan.sessions[si].items.insert(n, at: at)
                    done = true; break
                }
            }
            // d) size: an accessory for a muscle already at its minimum makes
            //    way for one that is short (largest shortfall first).
            if !done && size {
                let region = ["Chest", "Back", "Shoulders", "Biceps", "Triceps"].contains(g) ? 0 : g == "Core" ? -1 : 1
                search: for si in plan.sessions.indices where plan.sessions[si].spec.kind == .strength
                    && (region < 0 || plan.sessions[si].fatigue[region] >= 2) {
                    let present = patternsIn(si)
                    guard !isoPattern(for: g).contains(where: { present.contains($0) }) else { continue }
                    for ii in plan.sessions[si].items.indices {
                        let it = plan.sessions[si].items[ii]
                        guard it.kind == .lift, !it.essential, !(it.pattern?.isCompound ?? false),
                              (it.muscles[g] ?? 0) == 0,
                              it.muscles.allSatisfy({ mg, w in by[mg].map { $0.sets - w * Double(it.sets) / weeks >= lo($0) - 0.01 } ?? true })
                        else { continue }
                        for p in isoPattern(for: g) where !(p.isCompound) {
                            guard let m = ranked(p, ctx: ctx, intensity: plan.sessions[si].spec.intensity, used: taken(si)).first,
                                  (m.muscles[g] ?? 0) >= 1 else { continue }
                            var n = makeItem(m, sets: it.sets, intensity: plan.sessions[si].spec.intensity, ctx: ctx)
                            if wouldExceed(n, it.sets) { continue }
                            if plan.sessions[si].strengthMinutes - it.duration + n.duration > plan.sessions[si].budget + 0.01 { continue }
                            n.superset = false
                            plan.sessions[si].items[ii] = n
                            done = true; break search
                        }
                    }
                }
            }
            if !done { stuck.insert(g) }
        }
    }

    // MARK: - Quality score

    struct Quality {
        var frequency = 0.0, volume = 0.0, recovery = 0.0, coverage = 0.0, balance = 0.0
        var total: Double { frequency * 20 + volume * 20 + recovery * 25 + coverage * 25 + balance * 10 }
    }

    struct WeeklyStats {
        var strengthSessions = 0.0, aerobic = 0.0, vo2 = 0.0, mobility = 0.0, balanceSessions = 0.0
        var lowerHeavy = 0.0, upperHeavy = 0.0, sessions = 0.0
    }

    static func stats(_ plan: Plan) -> WeeklyStats {
        var s = WeeklyStats()
        for x in plan.sessions {
            if x.hasStrength { s.strengthSessions += 1 }
            s.aerobic += x.aerobic
            if x.items.contains(where: { $0.kind == .intervals }) { s.vo2 += 1 }
            s.mobility += x.mobilityMinutes
            if x.hasBalance { s.balanceSessions += 1 }
            if x.items.contains(where: { $0.heavyLoad && ($0.pattern == .squat || $0.pattern == .hinge) }) { s.lowerHeavy += 1 }
            if x.items.contains(where: { $0.heavyLoad && ($0.pattern == .hPush || $0.pattern == .vPush) }) { s.upperHeavy += 1 }
        }
        let w = plan.weeks
        s.aerobic += (plan.restDayWalk * plan.walkDaysPerWeek + plan.trainingDayWalk * plan.trainingWalkDaysPerWeek) * w
        s.strengthSessions /= w; s.aerobic /= w; s.vo2 /= w; s.mobility /= w; s.balanceSessions /= w
        s.lowerHeavy /= w; s.upperHeavy /= w; s.sessions = Double(plan.sessions.count) / w
        return s
    }

    /// Pure recovery penalty: same region hard on back-to-back days, and
    /// (health goals) two hard sessions in a row, plus heavy lower days < 48 h apart.
    static func recoveryPenalty(_ plan: Plan) -> Double {
        let n = plan.sessions.count
        guard n > 1 else { return 0 }
        let health = Ctx(config: plan.config).healthGoal
        var p = 0.0
        for i in 0..<n {
            let j = (i + 1) % n
            let d = decay(plan.slots[j].restBefore)
            let a = plan.sessions[i].fatigue, b = plan.sessions[j].fatigue
            for r in 0..<3 { p += Double(max(0, a[r] - 1) * max(0, b[r] - 1)) * d }
            if health && plan.sessions[i].isHard && plan.sessions[j].isHard && plan.slots[j].restBefore == 0 { p += overlap(a, b) ? 4 : 1 }
            if a[1] >= 3 && b[1] >= 3 && plan.slots[j].restBefore == 0 { p += 2 }
        }
        return p
    }

    static func qualityScore(_ plan: Plan) -> Quality {
        var q = Quality()
        let w = plan.weeks
        let n = Double(max(1, plan.sessions.count))
        // Frequency: sessions per week with >= 2 sets for each major group.
        q.frequency = majorGroups.map { g in
            let hits = Double(plan.sessions.filter { $0.sets(of: g) >= 2 }.count) / w
            return min(hits, 2) / 2
        }.reduce(0, +) / Double(majorGroups.count)
        // Volume: weekly sets inside the goal range.
        let report = volumeReport(plan)
        q.volume = report.map { l -> Double in
            if l.sets < Double(l.target.lowerBound) { return l.sets / Double(max(1, l.target.lowerBound)) }
            if l.sets > Double(l.target.upperBound) { return Double(l.target.upperBound) / l.sets }
            return 1
        }.reduce(0, +) / Double(report.count)
        q.recovery = max(0, 1 - recoveryPenalty(plan) / n / 4)
        // Goal coverage.
        let st = stats(plan)
        let f = st.sessions
        func ratio(_ v: Double, _ lo: Double, _ hi: Double = .infinity) -> Double {
            if lo <= 0 { return v > hi ? hi / v : 1 }
            if v < lo { return (v / lo) * (v / lo) }   // missing a weekly target costs more than overshooting
            if v > hi { return hi / v }
            return 1
        }
        var parts: [Double] = []
        switch plan.config.primaryGoal {
        case .longevity:
            parts = [ratio(st.strengthSessions, min(2, f), 3), ratio(st.aerobic, 150), ratio(st.vo2, f >= 3 ? 0.6 : 0, 1.2),
                     ratio(st.mobility, 60), ratio(st.balanceSessions, min(2, f))]
        case .generalFitness:
            parts = [ratio(st.strengthSessions, min(2, f), 4), ratio(st.aerobic, 120), ratio(st.mobility, 30)]
        case .increaseFlexibility:
            parts = [ratio(st.strengthSessions, min(2, f), 3), ratio(st.mobility, 120)]
        case .improveEndurance:
            parts = [ratio(st.aerobic, 200), ratio(st.strengthSessions, f <= 2.5 ? 0 : f <= 3.5 ? 1 : 2, 3), ratio(st.vo2, f >= 2 ? 1 : 0, 2)]
        case .loseWeight:
            parts = [ratio(st.strengthSessions, min(3, f), 4), ratio(st.aerobic, 150), ratio(st.vo2, f >= 4 ? 1 : 0, 2)]
        case .buildMuscle:
            parts = [ratio(st.strengthSessions, min(3, f), 6)]
        case .getStronger:
            parts = [ratio(st.strengthSessions, min(3, f), 5), ratio(st.lowerHeavy, min(2, f), 3), ratio(st.upperHeavy, min(2, f), 3)]
        }
        q.coverage = parts.reduce(0, +) / Double(max(1, parts.count))
        // Balance: push vs pull, knee vs hip dominant.
        var push = 0.0, pull = 0.0, knee = 0.0, hip = 0.0
        for s in plan.sessions {
            for it in s.items where it.kind == .lift {
                let v = Double(it.sets)
                switch it.pattern {
                case .hPush?, .vPush?, .chestIso?: push += v
                case .hPull?, .vPull?, .rearDelt?: pull += v
                case .squat?, .lunge?, .quadIso?: knee += v
                case .hinge?, .glute?, .hamIso?: hip += v
                default: break
                }
            }
        }
        func even(_ a: Double, _ b: Double) -> Double { max(a, b) == 0 ? 0 : min(a, b) / max(a, b) }
        q.balance = (even(push, pull) + even(knee, hip)) / 2
        return q
    }

    // MARK: - Entry points

    static func drillNames(_ s: Session) -> Set<String> {
        Set(s.items.filter { [.lift, .mobility, .balance, .stability].contains($0.kind) }.map(\.name))
    }

    /// Builds the sessions in order; a day's lifts and drills are not repeated
    /// from the day before (the block repeats, so the first day also checks the last).
    static func realize(_ specs: [Spec], ctx: Ctx, slots: [Slot], blockDays: Int, adjust: Bool) -> Plan {
        var sessions: [Session] = []
        for (i, sp) in specs.enumerated() {
            let avoid = i > 0 && slots[i].restBefore == 0 ? drillNames(sessions[i - 1]) : []
            sessions.append(build(sp, ctx: ctx, avoid: avoid))
        }
        if sessions.count > 2 && slots[0].restBefore == 0 {
            var avoid = drillNames(sessions[sessions.count - 1])
            if slots[1].restBefore == 0 { avoid.formUnion(drillNames(sessions[1])) }
            sessions[0] = build(specs[0], ctx: ctx, avoid: avoid)
        }
        var plan = Plan(config: ctx.config, slots: slots, sessions: sessions, blockDays: blockDays)
        if adjust { adjustVolume(&plan, ctx: ctx) }
        return plan
    }

    static func restDaysPerWeek(_ c: ProgramConfig) -> Double {
        if c.scheduleMode == .rolling { return Double(max(0, c.daysOff)) * 7 / Double(max(1, c.daysOn + max(0, c.daysOff))) }
        return Double(max(0, 7 - weekdays(for: c).count))
    }

    /// The longest rest-day walk: past this a rest day stops being recovery.
    static let maxRestDayWalk = 30.0

    /// When the sessions alone miss the goal's weekly aerobic minutes, a
    /// brisk walk outside the sessions makes up the gap: first on each rest
    /// day (20-30 min, recovery pace), then, only for what the rest days
    /// cannot hold, an extra walk on training days, done outside the session.
    /// (Zone 2 days already run the full session length for health goals.)
    static func addRestDayWalks(_ p: inout Plan, ctx: Ctx) {
        let target: Double
        switch ctx.goal {
        case .longevity, .loseWeight: target = 150
        case .generalFitness: target = 120
        default: return
        }
        let rd = restDaysPerWeek(ctx.config)
        let have = p.sessions.reduce(0) { $0 + $1.aerobic } / p.weeks
        let gap = target - have
        guard gap > 0.5 else { return }
        var left = gap
        if rd > 0.01 {
            let per = min(maxRestDayWalk, max(20, (gap / rd / 5).rounded(.up) * 5))
            p.restDayWalk = per
            p.walkDaysPerWeek = rd
            left -= per * rd
        }
        // Rest-day walks live on the rest-day page (`restDayPlan`), never in a
        // training session. Only what the rest days cannot hold goes on the
        // training days, as an extra walk outside the session.
        let td = Double(p.sessions.count) / p.weeks
        guard left > 0.5, td > 0.01 else { return }
        let per = min(30, max(10, (left / td / 5).rounded(.up) * 5))
        p.trainingDayWalk = per
        p.trainingWalkDaysPerWeek = td
        for i in p.sessions.indices {
            p.sessions[i].items.append(Item(kind: .outside, name: "Extra Brisk Walk (any time today, outside this session)", minutes: per))
        }
    }

    /// The rest-day program: an easy recovery prescription for the days off.
    /// `walk`: brisk-walk minutes the plan needs on rest days (0 = none needed).
    static func restDayPlan(config: ProgramConfig, walk: Double = 0) -> RestDayPlan {
        let ctx = Ctx(config: config)
        // The same minutes the plan counted (`walk`), never more than a recovery walk.
        let minutes = Int(min(maxRestDayWalk, walk > 0 ? walk : (ctx.healthGoal ? 25 : 20)))
        var items = ["Brisk Walk (Zone 1-2, easy enough to talk) \(minutes) min",
                     "Easy Mobility Flow (hips, spine, shoulders) 10 min",
                     "Optional: Foam Rolling (calves, quads, upper back) 5 min",
                     "Optional: Slow Breathing (4 s in, 6 s out) 5 min"]
        if ctx.injuries.contains("Knee") { items[0] = "Easy Walk or Cycling (Zone 1-2, easy enough to talk) \(minutes) min" }
        var note = "Recovery, not training: keep everything easy. Skip it if you feel run down."
        if walk > 0 { note += " The walk counts toward your weekly aerobic minutes." }
        return RestDayPlan(title: RestDayPlan.recoveryTitle, exercises: items, note: note, estimatedDuration: minutes + 10)
    }

    /// Catalog moves done with bodyweight, a band or a pull-up bar only: tracked
    /// as reps (optional added load), never as a weight to pick. Timed ones ("40s")
    /// stay timed; heavy-only loaded variants (Weighted Pull-ups) stay weighted.
    static let bodyweightOnlyMoves: [String: SetTracking] = {
        var out: [String: SetTracking] = [:]
        for m in catalog where m.gear.isSubset(of: [.bodyweight, .band, .pullupBar]) && !m.heavyOnly {
            out[ExerciseLibrary.normalize(m.name)] = (m.reps?.hasSuffix("s") ?? false) ? .timed : .bodyweight
        }
        return out
    }()

    static func bodyweightTracking(name: String) -> SetTracking? {
        bodyweightOnlyMoves[ExerciseLibrary.normalize(ProgramTargetParser.parse(name).name)]
    }

    /// How a session's bodyweight/band lifts progress, since they have no weight to add.
    static func bodyweightNote(_ items: [Item]) -> String? {
        let names = items.filter { $0.kind == .lift && !$0.gear.isEmpty && $0.gear.isSubset(of: [.bodyweight, .band]) }.map(\.name)
        guard !names.isEmpty else { return nil }
        let list = names.prefix(3).joined(separator: ", ")
        return "No weight for \(list): lower slowly (about 3 s), add reps up to the top of the range, then move to a harder version (single-leg, feet elevated, a stronger band)."
    }

    static func joinedNote(_ parts: String?...) -> String? {
        let t = parts.compactMap { $0 }.joined(separator: " ")
        return t.isEmpty ? nil : t
    }

    /// Coaching cue shown with a session's lifts.
    static func loadingNote(_ ctx: Ctx) -> String? {
        if ctx.jointSafe {
            return "Joint-safe loading: stop every working set 2-3 reps short of failure (RPE 7-8), never below 8 reps, controlled tempo (about 3 s down). No max-effort sets."
        }
        if ctx.beginner { return "Stop every set with 2-3 good reps left (RPE 7-8). Form first; add weight only when every set looks the same." }
        return nil
    }

    /// Planning units: a week (weekly) or 1-2 whole cycles (rolling). The
    /// unit is planned once and repeated, so every week/cycle of the block
    /// has the same sessions and set counts and progression can be tracked.
    static func units(for config: ProgramConfig, start: Date?, calendar: Calendar) -> [(unit: [Slot], unitDays: Int, block: [Slot], blockDays: Int)] {
        if config.scheduleMode == .rolling {
            let on = max(1, config.daysOn), cycle = on + max(0, config.daysOff)
            let k1 = on >= 3 ? 1 : on == 2 ? 2 : 3
            var out: [(unit: [Slot], unitDays: Int, block: [Slot], blockDays: Int)] = []
            // Two-cycle units only where a weekly dose needs alternating
            // (VO2max every other cycle); otherwise every cycle is identical.
            let healthGoal = ![.buildMuscle, .getStronger].contains(config.primaryGoal)
            for k in [k1, 2 * k1] where k == k1 || (healthGoal && k * on <= 42) {
                let b = slots(for: config, start: start, calendar: calendar, cycleMultiple: k)
                out.append((Array(b.slots.prefix(k * on)), k * cycle, b.slots, b.blockDays))
            }
            return out
        }
        let b = slots(for: config, start: start, calendar: calendar)
        return [(Array(b.slots.prefix(b.slots.count / 2)), 7, b.slots, b.blockDays)]
    }

    /// The Smart Advisor program: best-scoring candidate for this config.
    static func plan(for config: ProgramConfig, start: Date? = nil, calendar: Calendar = .current) -> Plan {
        let ctx = Ctx(config: config)
        var best: Plan? = nil, bestScore = -Double.infinity
        var fallbackPlan: Plan? = nil, fallbackScore = -Double.infinity
        for u in units(for: config, start: start, calendar: calendar) {
            for cand in candidates(ctx: ctx, slots: u.unit, blockDays: u.unitDays) where cand.count == u.unit.count {
                let placed = assignVariants(place(cand, slots: u.unit, health: ctx.healthGoal, blockDays: u.unitDays))
                var up = realize(placed, ctx: ctx, slots: u.unit, blockDays: u.unitDays, adjust: true)
                addRestDayWalks(&up, ctx: ctx)
                var p = Plan(config: config, slots: u.block, sessions: u.block.indices.map { up.sessions[$0 % up.sessions.count] },
                             blockDays: u.blockDays)
                p.restDayWalk = up.restDayWalk
                p.walkDaysPerWeek = up.walkDaysPerWeek
                p.trainingDayWalk = up.trainingDayWalk
                p.trainingWalkDaysPerWeek = up.trainingWalkDaysPerWeek
                let sc = qualityScore(p).total
                // Size: no cardio or walk days while a major muscle is under its
                // minimum. Rolling: every cycle gets the same strength days.
                var perCycle: [Int: Int] = [:]
                for (sl, s) in zip(u.unit, up.sessions) { perCycle[sl.cycle, default: 0] += s.hasStrength ? 1 : 0 }
                // Longevity: no major muscle group, and no core (lifts or stability
                // drills), left under its minimum.
                let under = longevityFloorReport(p).filter { $0.sets < Double($0.target.lowerBound) - 0.01 }.map(\.group)
                if (ctx.goal == .buildMuscle && p.sessions.contains(where: { $0.spec.kind != .strength })
                    && under.contains(where: majorGroups.contains))
                    || (ctx.goal == .longevity && under.contains(where: { majorGroups.contains($0) || $0 == "Core" }))
                    || (perCycle.values.max() ?? 0) - (perCycle.values.min() ?? 0) > (config.daysOn >= 4 ? 0 : 1) {
                    if sc > fallbackScore + 1e-9 { fallbackScore = sc; fallbackPlan = p }
                    continue
                }
                if sc > bestScore + 1e-9 { bestScore = sc; best = p }
            }
        }
        if let b = best ?? fallbackPlan { return b }
        let (slots, blockDays) = self.slots(for: config, start: start, calendar: calendar)
        return Plan(config: config, slots: slots, sessions: [], blockDays: blockDays)
    }

    /// A hand-built split over the same days, run through the same exercise
    /// engine (no recovery placement, no volume check, no conditioning), so
    /// the selftest can compare like for like.
    static func naivePlan(for config: ProgramConfig, split: ProgramSplit, start: Date? = nil) -> Plan {
        let ctx = Ctx(config: config)
        let (slots, blockDays) = self.slots(for: config, start: start)
        let rotation = split.rotation
        let base = strengthIntensity(config.primaryGoal)
        let specs: [Spec] = (0..<slots.count).map { k in
            let s = rotation[k % rotation.count]
            let groups: [Template] = s.groups.map {
                switch $0 {
                case "Upper": return .upper
                case "Lower": return .lower
                case "Push": return .push
                case "Pull": return .pull
                case "Legs": return .legs
                case "Chest": return .chest
                case "Back": return .back
                case "Shoulders": return .shoulders
                case "Arms": return .arms
                default: return .fullBody
                }
            }
            let i: Intensity = s.focus == "strength" ? .heavy : s.focus == "hypertrophy" ? .hypertrophy : base
            return Spec(kind: .strength, template: groups.first, intensity: i, groups: groups, label: s.label)
        }
        var plan = realize(assignVariants(specs), ctx: ctx, slots: slots, blockDays: blockDays, adjust: false)
        if config.primaryGoal == .longevity {
            // The explicit-split path appends these two to every session.
            for i in plan.sessions.indices {
                plan.sessions[i].items.append(Item(kind: .mobility, name: "Mobility Flow", reps: "10 min", minutes: 10))
                plan.sessions[i].items.append(zone2(15, ctx: ctx))
            }
        }
        return plan
    }
}

extension SmartPlanner.Session {
    /// Minutes the lifts take (the warm-up is its own items, outside `budget`).
    var strengthMinutes: Double {
        items.filter { $0.kind == .lift }.reduce(0) { $0 + $1.duration }
    }
}

extension SmartPlanner {
    /// `-ef.plandump`: prints sample plans and scores (developer aid).
    /// A wizard config for tests and the dump: weekly days are fixed picks.
    static func sampleConfig(_ g: TrainingGoal, _ e: ExperienceLevel = .intermediate, rolling: (Int, Int)? = nil, perWeek: Int = 4,
                             len: Int = 60, eq: EquipmentLevel = .fullGym, inj: Set<String> = [], days: [String]? = nil) -> ProgramConfig {
            var c = ProgramConfig()
            c.primaryGoal = g; c.experienceLevel = e; c.sessionLength = len; c.equipment = eq; c.injuries = inj
            if let r = rolling { c.scheduleMode = .rolling; c.daysOn = r.0; c.daysOff = r.1 } else {
                c.daysPerWeek = perWeek
                let all = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
                let picks: [Int: [String]] = [2: ["Monday", "Thursday"], 3: ["Monday", "Wednesday", "Friday"],
                                              4: ["Monday", "Tuesday", "Thursday", "Friday"], 5: ["Monday", "Tuesday", "Wednesday", "Friday", "Saturday"],
                                              6: Array(all.prefix(6)), 7: all]
                c.weekdays = Set(days ?? picks[perWeek] ?? [])
            }
            return c
    }

    static func dumpSamples() {
        let samples: [(String, ProgramConfig)] = [
            ("longevity 4on/1off", sampleConfig(.longevity, rolling: (4, 1))),
            ("size 4/wk", sampleConfig(.buildMuscle)),
            ("strength 3/wk", sampleConfig(.getStronger, perWeek: 3)),
            ("fat loss 5/wk", sampleConfig(.loseWeight, perWeek: 5)),
            ("endurance 3on/1off", sampleConfig(.improveEndurance, rolling: (3, 1))),
            ("flex 3/wk bw", sampleConfig(.increaseFlexibility, perWeek: 3, eq: .bodyweight)),
            ("general beginner 3/wk", sampleConfig(.generalFitness, .beginner, perWeek: 3)),
            ("longevity beginner 3/wk", sampleConfig(.longevity, .beginner, perWeek: 3)),
            ("longevity beginner 3/wk 30", sampleConfig(.longevity, .beginner, perWeek: 3, len: 30)),
            ("longevity int 4/wk 30", sampleConfig(.longevity, perWeek: 4, len: 30)),
            ("size advanced 6/wk", sampleConfig(.buildMuscle, .advanced, perWeek: 6)),
        ]
        for (name, c) in samples {
            let p = plan(for: c)
            let q = qualityScore(p)
            print("== \(name): score \(String(format: "%.1f", q.total)) f\(String(format: "%.2f", q.frequency)) v\(String(format: "%.2f", q.volume)) r\(String(format: "%.2f", q.recovery)) c\(String(format: "%.2f", q.coverage)) b\(String(format: "%.2f", q.balance))")
            for (slot, s) in zip(p.slots, p.sessions) {
                print("  [\(slot.restBefore)] \(slot.label): \(s.label) (\(Int(s.minutes)) min) \(s.isHard ? "HARD" : "")")
                print("      " + s.items.map(\.text).joined(separator: " | "))
            }
            if let note = p.scheduledWorkouts.first(where: { $0.notes != nil })?.notes { print("  lifting note: \(note)") }
            let rd = p.restDayPlan
            print("  rest day: \(rd.title): " + rd.exercises.joined(separator: " | ") + " (\(rd.note))")
            print("  volume: " + volumeReport(p).map { "\($0.group) \(String(format: "%.1f", $0.sets)) [\($0.target.lowerBound)-\($0.target.upperBound)]" }.joined(separator: ", "))
            for split in ProgramSplit.allCases where split != .auto {
                let nq = qualityScore(naivePlan(for: c, split: split))
                print("  naive \(split.rawValue): \(String(format: "%.1f", nq.total)) f\(String(format: "%.2f", nq.frequency)) v\(String(format: "%.2f", nq.volume)) r\(String(format: "%.2f", nq.recovery)) c\(String(format: "%.2f", nq.coverage)) b\(String(format: "%.2f", nq.balance))")
            }
        }
    }
}

// MARK: - Rest-day program

/// What to do on a rest day: an easy recovery prescription. Stored on its own
/// (UserDefaults) when a program is built, never as an entry in
/// `weeklySchedule`, so training-day indexing, session counts, streaks and
/// adherence are unchanged. `scheduleSignature` ties it to the program it was
/// built for; any other program gets the default plan for the saved goal.
struct RestDayPlan: Codable, Equatable {
    var title: String
    /// Entries with their scheme ("Brisk Walk ... 25 min"), like `ScheduledWorkout.exercises`.
    var exercises: [String]
    var note: String
    var estimatedDuration: Int
    var scheduleSignature: String? = nil

    var plannedExercises: [PlannedExercise] { exercises.map(ProgramTargetParser.parse) }

    /// The plan as an optional session that can be started and logged.
    var asScheduledWorkout: ScheduledWorkout {
        var w = ScheduledWorkout(dayOfWeek: "Rest Day", workoutType: title, exercises: exercises,
                                 estimatedDuration: estimatedDuration, notes: note)
        w.normalizePlan()
        return w
    }

    static let storageKey = "restDayPlan.v1"
    static let recoveryTitle = "Rest Day: Active Recovery"

    static func stored(_ d: UserDefaults = .standard) -> RestDayPlan? {
        d.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(RestDayPlan.self, from: $0) }
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.storageKey) }
    }

    static func clear(_ d: UserDefaults = .standard) { d.removeObject(forKey: storageKey) }

    /// The rest-day plan for `date`, or nil on a training day. Pure, so the
    /// selftest can check both schedule modes.
    static func forDate(_ date: Date, start: Date, rolling: Bool, daysOn: Int, daysOff: Int, weekdays: [String],
                        plan: RestDayPlan?, calendar: Calendar = .current) -> RestDayPlan? {
        guard let plan else { return nil }
        let idx = WorkoutManager.trainingDayIndex(on: date, start: start, rolling: rolling, daysOn: daysOn,
                                                  daysOff: daysOff, weekdays: weekdays, calendar: calendar)
        // Before the program starts nothing is scheduled: not a rest day either.
        guard idx == nil, calendar.startOfDay(for: date) >= calendar.startOfDay(for: start) else { return nil }
        return plan
    }
}
