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
//

import Foundation

enum SmartPlanner {

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
    }

    // MARK: - Catalog (names follow the existing generateExercises pools)

    static let catalog: [Move] = [
        // Squat
        Move(name: "Back Squats", pattern: .squat, gear: [.barbell], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true, flags: ["Knee"]),
        Move(name: "Barbell Box Squats", pattern: .squat, gear: [.barbell], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true),
        Move(name: "Front Squats", pattern: .squat, gear: [.barbell], muscles: ["Quads": 1, "Glutes": 0.5], heavy: true, beginner: false, flags: ["Knee"]),
        Move(name: "Leg Press", pattern: .squat, gear: [.machine], muscles: ["Quads": 1, "Glutes": 0.5]),
        Move(name: "Goblet Squats", pattern: .squat, gear: [.dumbbell, .kettlebell], muscles: ["Quads": 1, "Glutes": 0.5]),
        Move(name: "Bodyweight Squats", pattern: .squat, gear: [.bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], reps: "15-20"),
        Move(name: "Box Squats", pattern: .squat, gear: [.bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], reps: "12-15"),
        // Hinge
        Move(name: "Deadlifts", pattern: .hinge, gear: [.barbell], muscles: ["Hamstrings": 1, "Glutes": 1, "Back": 0.5], heavy: true, beginner: false, flags: ["Low back"]),
        Move(name: "Trap Bar Deadlifts", pattern: .hinge, gear: [.machine], muscles: ["Hamstrings": 0.5, "Glutes": 1, "Quads": 0.5], heavy: true, flags: ["Low back"]),
        Move(name: "Romanian Deadlifts", pattern: .hinge, gear: [.barbell, .dumbbell], muscles: ["Hamstrings": 1, "Glutes": 0.5], flags: ["Low back"]),
        Move(name: "Kettlebell Swings", pattern: .hinge, gear: [.kettlebell], muscles: ["Hamstrings": 0.5, "Glutes": 1], beginner: false, flags: ["Low back"], reps: "15-20"),
        Move(name: "Back Extensions", pattern: .hinge, gear: [.machine], muscles: ["Hamstrings": 0.5, "Glutes": 0.5, "Back": 0.5], flags: ["Low back"]),
        Move(name: "Single-Leg Hip Hinges", pattern: .hinge, gear: [.bodyweight], muscles: ["Hamstrings": 0.5, "Glutes": 0.5], reps: "10-12"),
        // Lunge / single leg
        Move(name: "Bulgarian Split Squats", pattern: .lunge, gear: [.dumbbell, .barbell, .bodyweight], muscles: ["Quads": 1, "Glutes": 1], beginner: false, flags: ["Knee"]),
        Move(name: "Walking Lunges", pattern: .lunge, gear: [.dumbbell, .bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], flags: ["Knee"]),
        Move(name: "Reverse Lunges", pattern: .lunge, gear: [.dumbbell, .kettlebell, .bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], flags: ["Knee"]),
        Move(name: "Step-ups", pattern: .lunge, gear: [.dumbbell, .bodyweight], muscles: ["Quads": 1, "Glutes": 0.5], flags: ["Knee"]),
        // Horizontal push
        Move(name: "Barbell Bench Press", pattern: .hPush, gear: [.barbell], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], heavy: true),
        Move(name: "Dumbbell Bench Press", pattern: .hPush, gear: [.dumbbell], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5]),
        Move(name: "Incline Dumbbell Press", pattern: .hPush, gear: [.dumbbell], muscles: ["Chest": 1, "Shoulders": 0.5, "Triceps": 0.5]),
        Move(name: "Machine Chest Press", pattern: .hPush, gear: [.machine], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5]),
        Move(name: "Weighted Dips", pattern: .hPush, gear: [.machine], muscles: ["Chest": 1, "Triceps": 1, "Shoulders": 0.5], heavy: true, beginner: false, flags: ["Shoulder"], heavyOnly: true),
        Move(name: "Push-ups", pattern: .hPush, gear: [.bodyweight], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], reps: "8-15"),
        Move(name: "Incline Push-ups", pattern: .hPush, gear: [.bodyweight], muscles: ["Chest": 1, "Triceps": 0.5, "Shoulders": 0.5], reps: "10-15"),
        // Vertical push
        Move(name: "Overhead Press", pattern: .vPush, gear: [.barbell], muscles: ["Shoulders": 1, "Triceps": 0.5], heavy: true, flags: ["Shoulder"]),
        Move(name: "Dumbbell Shoulder Press", pattern: .vPush, gear: [.dumbbell, .kettlebell], muscles: ["Shoulders": 1, "Triceps": 0.5], flags: ["Shoulder"]),
        Move(name: "Landmine Press", pattern: .vPush, gear: [.barbell], muscles: ["Shoulders": 1, "Chest": 0.5, "Triceps": 0.5]),
        Move(name: "Pike Push-ups", pattern: .vPush, gear: [.bodyweight], muscles: ["Shoulders": 1, "Triceps": 0.5], beginner: false, flags: ["Shoulder"], reps: "6-12"),
        // Horizontal pull
        Move(name: "Barbell Rows", pattern: .hPull, gear: [.barbell], muscles: ["Back": 1, "Biceps": 0.5], heavy: true, beginner: false, flags: ["Low back"]),
        Move(name: "Chest-Supported Rows", pattern: .hPull, gear: [.dumbbell, .machine], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "One-Arm Dumbbell Rows", pattern: .hPull, gear: [.dumbbell, .kettlebell], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Seated Cable Rows", pattern: .hPull, gear: [.cable], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Inverted Rows", pattern: .hPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Band Rows", pattern: .hPull, gear: [.band], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Doorframe Rows", pattern: .hPull, gear: [.bodyweight], muscles: ["Back": 1, "Biceps": 0.5], reps: "10-15"),
        Move(name: "Towel Rows", pattern: .hPull, gear: [.bodyweight], muscles: ["Back": 1, "Biceps": 0.5], reps: "10-15"),
        // Vertical pull
        Move(name: "Weighted Pull-ups", pattern: .vPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 0.5], heavy: true, beginner: false, heavyOnly: true),
        Move(name: "Pull-ups", pattern: .vPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 0.5], beginner: false, reps: "5-10"),
        Move(name: "Lat Pulldowns", pattern: .vPull, gear: [.cable], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Chin-ups", pattern: .vPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 1], beginner: false, reps: "5-10"),
        Move(name: "Band-Assisted Pull-ups", pattern: .vPull, gear: [.pullupBar], muscles: ["Back": 1, "Biceps": 0.5], reps: "5-8"),
        Move(name: "Band Lat Pulldowns", pattern: .vPull, gear: [.band], muscles: ["Back": 1, "Biceps": 0.5]),
        Move(name: "Prone Lat Pulls", pattern: .vPull, gear: [.bodyweight], muscles: ["Back": 1], reps: "12-15"),
        // Core / carry
        Move(name: "Plank", pattern: .core, gear: [.bodyweight], muscles: ["Core": 1], reps: "40s"),
        Move(name: "Dead Bug", pattern: .core, gear: [.bodyweight], muscles: ["Core": 1], reps: "10"),
        Move(name: "Pallof Press", pattern: .core, gear: [.band, .cable], muscles: ["Core": 1], reps: "10"),
        Move(name: "Hanging Knee Raises", pattern: .core, gear: [.pullupBar], muscles: ["Core": 1], reps: "10-12"),
        Move(name: "Side Plank", pattern: .core, gear: [.bodyweight], muscles: ["Core": 1], reps: "30s"),
        Move(name: "Ab Wheel Rollouts", pattern: .core, gear: [.machine], muscles: ["Core": 1], beginner: false, flags: ["Low back"], reps: "8-12"),
        Move(name: "Farmer's Carry", pattern: .carry, gear: [.dumbbell, .kettlebell], muscles: ["Core": 0.5, "Back": 0.5], reps: "40m"),
        Move(name: "Suitcase Carry", pattern: .carry, gear: [.dumbbell, .kettlebell], muscles: ["Core": 1], reps: "30m"),
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
        Move(name: "Cable Pushdowns", pattern: .triceps, gear: [.cable], muscles: ["Triceps": 1]),
        Move(name: "Overhead Dumbbell Extensions", pattern: .triceps, gear: [.dumbbell], muscles: ["Triceps": 1]),
        Move(name: "Skull Crushers", pattern: .triceps, gear: [.barbell, .dumbbell], muscles: ["Triceps": 1]),
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
        Move(name: "Pec Deck", pattern: .chestIso, gear: [.machine], muscles: ["Chest": 1]),
        Move(name: "Dumbbell Flyes", pattern: .chestIso, gear: [.dumbbell], muscles: ["Chest": 1]),
        // Glutes / hamstrings / quads isolation
        Move(name: "Barbell Hip Thrusts", pattern: .glute, gear: [.barbell], muscles: ["Glutes": 1, "Hamstrings": 0.5], heavy: true),
        Move(name: "Hip Thrusts", pattern: .glute, gear: [.dumbbell, .machine], muscles: ["Glutes": 1, "Hamstrings": 0.5]),
        Move(name: "Glute Bridges", pattern: .glute, gear: [.bodyweight], muscles: ["Glutes": 1, "Hamstrings": 0.5], reps: "12-20"),
        Move(name: "Single-Leg Glute Bridges", pattern: .glute, gear: [.bodyweight], muscles: ["Glutes": 1, "Hamstrings": 0.5], reps: "10-12"),
        Move(name: "Leg Curls", pattern: .hamIso, gear: [.machine], muscles: ["Hamstrings": 1]),
        Move(name: "Sliding Leg Curls", pattern: .hamIso, gear: [.bodyweight], muscles: ["Hamstrings": 1], reps: "8-12"),
        Move(name: "Nordic Curls", pattern: .hamIso, gear: [.bodyweight], muscles: ["Hamstrings": 1], beginner: false, reps: "4-6"),
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
        enum Kind { case lift, cardio, intervals, mobility, balance, stability, walk }
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
        var duration: Double { kind == .lift ? Double(sets) * perSet + 1 : minutes }
        var text: String {
            switch kind {
            case .lift: return "\(name) \(sets)x\(reps)"
            case .cardio, .walk: return "\(name) \(Int(minutes)) min"
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
            case .mixed: return [1, 2, 2]
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
        var minutes: Double { items.reduce(0) { $0 + $1.duration } + (items.contains { $0.kind == .lift } ? 5 : 0) }
        var hasStrength: Bool { items.contains { $0.kind == .lift } }
        var aerobic: Double { items.reduce(0) { $0 + $1.aerobic } }
        var mobilityMinutes: Double { items.filter { [.mobility, .balance, .stability].contains($0.kind) }.reduce(0) { $0 + $1.minutes } }
        var hasBalance: Bool { items.contains { $0.kind == .balance } }
        func sets(of group: String) -> Double {
            items.reduce(0) { $0 + Double($1.sets) * ($1.kind == .lift ? ($1.muscles[group] ?? 0) : 0) }
        }
    }

    struct Slot { let label: String; let day: Int; let restBefore: Int }

    struct Plan {
        let config: ProgramConfig
        let slots: [Slot]
        var sessions: [Session]
        let blockDays: Int
        var weeks: Double { Double(blockDays) / 7 }

        var scheduledWorkouts: [ScheduledWorkout] {
            zip(slots, sessions).map { slot, s in
                ScheduledWorkout(dayOfWeek: slot.label, workoutType: s.label,
                                 exercises: s.items.map(\.text), estimatedDuration: config.sessionLength)
            }
        }
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
            case 0: return [.squat, .hPush, .hPull, .glute, .core, .vPull, .lateral, .calf, .biceps, .triceps]
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

    static func pick(_ p: Pattern, variant: Int, ctx: Ctx, intensity: Intensity, used: Set<String>) -> Move? {
        for q in [p] + fallback(p) {
            var c = catalog.filter { $0.pattern == q && !$0.gear.isDisjoint(with: ctx.gear) && $0.flags.isDisjoint(with: ctx.injuries) }
            if ctx.beginner { let b = c.filter(\.beginner); if !b.isEmpty { c = b } }
            if intensity == .heavy { let h = c.filter(\.heavy); if !h.isEmpty { c = h } }
            else { let l = c.filter { !$0.heavyOnly }; if !l.isEmpty { c = l } }
            // Circuits and strength-endurance: dumbbells/machines over max-effort barbell lifts.
            if intensity == .endurance || intensity == .circuit { let l = c.filter { !$0.heavy }; if !l.isEmpty { c = l } }
            c = c.filter { !used.contains($0.name) }
            // With weights available, bodyweight/band versions are the fallback,
            // and variety rotates through the best few options only.
            if !ctx.gear.isDisjoint(with: [.barbell, .dumbbell, .kettlebell, .machine]) {
                let basic: Set<Gear> = [.bodyweight, .band]
                c = c.filter { !$0.gear.isSubset(of: basic) } + c.filter { $0.gear.isSubset(of: basic) }
            }
            if !c.isEmpty { return c[variant % min(c.count, 3)] }
        }
        return nil
    }

    static func reps(_ i: Intensity, compound: Bool, ctx: Ctx) -> String {
        switch i {
        case .heavy: return compound ? (ctx.beginner ? "5" : ctx.config.experienceLevel == .intermediate ? "4-6" : "3-5") : "8-12"
        case .hypertrophy: return compound ? "6-10" : "10-15"
        case .foundation: return compound ? (ctx.beginner ? "8-12" : "6-10") : "10-15"
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

    /// Lifts for one strength block, filling `budget` minutes (warm-up included).
    static func strengthItems(patterns: [Pattern], variant: Int, intensity: Intensity, budget: Double,
                              ctx: Ctx, used: inout Set<String>) -> [Item] {
        var items: [Item] = []
        var spent = 5.0
        for p in patterns where items.count < ctx.maxExercises {
            guard let m = pick(p, variant: variant, ctx: ctx, intensity: intensity, used: used) else { continue }
            let compound = m.pattern.isCompound
            let ps = perSet(intensity, compound: compound)
            // Heavy work starts with more sets per lift; volume work spreads
            // the same time over more exercises.
            var sets = compound ? (intensity == .heavy ? ctx.compoundSets : min(3, ctx.compoundSets)) : ctx.isoSets
            if intensity == .heavy && compound && !ctx.beginner { sets += 1 }
            while sets > 2 && spent + Double(sets) * ps + 1 > budget { sets -= 1 }
            if spent + Double(sets) * ps + 1 > budget && !items.isEmpty { continue }
            used.insert(m.name)
            let r = m.reps ?? (intensity == .heavy && compound && !m.heavy ? "6-8" : reps(intensity, compound: compound, ctx: ctx))
            items.append(Item(kind: .lift, name: m.name, sets: sets, reps: r, pattern: m.pattern, muscles: m.muscles,
                              perSet: ps, heavyLoad: intensity == .heavy && compound && m.heavy, gear: m.gear))
            spent += Double(sets) * ps + 1
        }
        // Time left after the pool: add sets to compounds first, then a
        // single extra set to accessories.
        for compoundPass in [true, false] {
            var grew = true
            while grew {
                grew = false
                for i in items.indices where (items[i].pattern?.isCompound ?? false) == compoundPass {
                    let cap = compoundPass ? ctx.maxSets : ctx.isoSets + 1
                    if items[i].sets < cap && spent + items[i].perSet <= budget {
                        items[i].sets += 1; spent += items[i].perSet; grew = true
                    }
                }
            }
        }
        return items
    }

    static func drills(minutes: Double, balance: Bool, stability: Bool, offset: Int, ctx: Ctx, used: inout Set<String>) -> [Item] {
        guard minutes >= 2 else { return [] }
        let ok: (Drill) -> Bool = { d in d.flags.isDisjoint(with: ctx.injuries) && (d.gear.map { !$0.isDisjoint(with: ctx.gear) } ?? true) }
        let mob = mobilityPool.filter(ok), bal = balancePool.filter(ok), stab = stabilityPool.filter(ok)
        var order: [(Item.Kind, [Drill], Double)] = [(.mobility, mob, 2.5)]
        if balance { order.append((.balance, bal, 3)) }
        order.append((.mobility, mob, 2.5))
        if stability { order.append((.stability, stab, 3)) }
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
            items.append(Item(kind: kind, name: d.name, reps: d.scheme, minutes: t))
            spent += t
        }
        return items
    }

    static func zone2Name(_ ctx: Ctx) -> String {
        if ctx.gear.contains(.machine) { return "Zone 2 Cardio (bike, rower or incline walk)" }
        if ctx.injuries.contains("Knee") { return "Zone 2 Cardio (cycling, swimming or brisk walk)" }
        return "Zone 2 Cardio (brisk walk or easy jog)"
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
        switch t {
        case .fullBody: return "Full Body \(tag) \(["A", "B", "C"][variant % 3])"
        case .upper: return "Upper Body \(tag)"
        case .lower: return "Lower Body \(tag)"
        case .push: return "Push \(tag)"
        case .pull: return "Pull \(tag)"
        case .legs: return "Legs \(tag)"
        default: return "\(t.rawValue.capitalized) \(tag)"
        }
    }

    static func build(_ spec: Spec, ctx: Ctx) -> Session {
        let len = ctx.length
        var used = Set<String>()
        var items: [Item] = []
        let label: String
        let mobFinisher: Double = ctx.goal == .longevity || ctx.goal == .increaseFlexibility
            ? (len >= 45 ? 10 : 5) : (len >= 45 ? 5 : 0)
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
            let finisher = spec.groups.isEmpty ? mobFinisher : 0
            items = strengthItems(patterns: pats, variant: spec.variant, intensity: spec.intensity,
                                  budget: len - finisher, ctx: ctx, used: &used)
            items += drills(minutes: finisher, balance: ctx.goal == .longevity, stability: false, offset: spec.variant * 3, ctx: ctx, used: &used)
            label = spec.label ?? strengthLabel(groups[0], spec.intensity, variant: spec.variant)
        case .mixed:
            let sBudget = (len * 0.55).rounded()
            items = strengthItems(patterns: patterns(.fullBody, variant: spec.variant), variant: spec.variant,
                                  intensity: spec.intensity, budget: sBudget, ctx: ctx, used: &used)
            let fin = len >= 45 ? min(mobFinisher, 8) : 0
            let rest = len - sBudget - fin
            if ctx.goal == .increaseFlexibility {
                items += drills(minutes: rest + fin, balance: true, stability: true, offset: spec.variant * 2, ctx: ctx, used: &used)
                label = "Strength + Mobility"
            } else {
                items.append(zone2(rest, ctx: ctx))
                items += drills(minutes: fin, balance: ctx.goal == .longevity, stability: false, offset: spec.variant * 2 + 5, ctx: ctx, used: &used)
                label = "Strength + Zone 2"
            }
        case .zone2:
            let mob = len >= 40 ? (ctx.goal == .longevity && len >= 60 ? 15.0 : 10.0) : 0
            items = [zone2(len - mob, ctx: ctx)]
            items += drills(minutes: mob, balance: ctx.goal == .longevity, stability: false, offset: spec.variant * 4 + 1, ctx: ctx, used: &used)
            label = ctx.goal == .longevity && len >= 60 ? "Zone 2 + Mobility & Balance" : (mob > 0 ? "Zone 2 + Mobility" : "Zone 2 Cardio")
        case .intervals:
            let acc = len >= 45 ? 10.0 : 0
            let reps = min(6, max(2, Int((len - 15 - acc) / 7)))
            let spare = max(0, len - 15 - Double(reps * 7))
            let mod: String
            if ctx.gear.contains(.machine) { mod = "bike or rower" }
            else if ctx.injuries.contains("Knee") { mod = "bike or uphill walk" }
            else { mod = "hill run or fast uphill walk" }
            items = [Item(kind: .cardio, name: "Easy Warm-up Cardio", minutes: 10, aerobic: 10),
                     Item(kind: .intervals, name: "VO2max Intervals: 4 min hard / 3 min easy (\(mod))", sets: reps,
                          reps: "\(reps)x240s", minutes: Double(reps * 7), aerobic: Double(reps * 4 * 2 + reps * 3)),
                     Item(kind: .cardio, name: "Easy Cool-down", minutes: 5, aerobic: 5)]
            items += drills(minutes: spare, balance: true, stability: true, offset: spec.variant * 2 + 3, ctx: ctx, used: &used)
            label = ctx.goal == .longevity ? "VO2max Intervals + Balance" : "VO2max Intervals"
        case .gentleIntervals:
            let acc = len >= 45 ? 10.0 : 0
            let reps = min(10, max(4, Int((len - 13 - acc) / 3)))
            let spare = max(0, len - 13 - Double(reps * 3))
            items = [Item(kind: .cardio, name: "Brisk Walk Warm-up", minutes: 8, aerobic: 8),
                     Item(kind: .intervals, name: "Uphill Walk Intervals: 1 min brisk / 2 min easy", sets: reps,
                          reps: "\(reps)x60s", minutes: Double(reps * 3), aerobic: Double(reps * 4)),
                     Item(kind: .cardio, name: "Easy Cool-down", minutes: 5, aerobic: 5)]
            items += drills(minutes: spare, balance: true, stability: true, offset: spec.variant * 2 + 3, ctx: ctx, used: &used)
            label = "Gentle Intervals + Balance"
        case .mobility:
            let walk = len >= 45 ? (len * 0.33).rounded() : 0
            if walk > 0 { items.append(Item(kind: .walk, name: "Easy Walk", minutes: walk, aerobic: walk * 0.5)) }
            items += drills(minutes: len - walk, balance: true, stability: true, offset: spec.variant * 5, ctx: ctx, used: &used)
            label = "Mobility, Balance & Core"
        case .recovery:
            let walk = (len * 0.5).rounded()
            items = [Item(kind: .walk, name: "Easy Walk", minutes: walk, aerobic: walk * 0.5)]
            items += drills(minutes: len - walk, balance: false, stability: false, offset: spec.variant * 5 + 2, ctx: ctx, used: &used)
            label = "Recovery: Easy Walk + Mobility"
        }
        let budget = spec.kind == .mixed ? (len * 0.55).rounded()
            : spec.kind == .strength ? len - (spec.groups.isEmpty ? mobFinisher : 0) : len
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
    static func slots(for config: ProgramConfig, start: Date?, calendar: Calendar = .current) -> (slots: [Slot], blockDays: Int) {
        if config.scheduleMode == .rolling {
            let on = max(1, config.daysOn), off = max(0, config.daysOff), cycle = on + off
            var c = max(1, Int((14.0 / Double(cycle)).rounded(.up)))
            while c > 1 && c * on > 42 { c -= 1 }
            var out: [Slot] = []
            for ci in 0..<c {
                for d in 0..<on {
                    out.append(Slot(label: "Day \(d + 1) · Cycle \(ci + 1)", day: ci * cycle + d, restBefore: d == 0 ? off : 0))
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
                out.append(Slot(label: "\(name) · Wk \(w + 1)", day: w * 7 + o, restBefore: 0))
            }
        }
        var fixed: [Slot] = []
        for (i, s) in out.enumerated() {
            let prev = i == 0 ? out[out.count - 1].day - 14 : out[i - 1].day
            fixed.append(Slot(label: s.label, day: s.day, restBefore: max(0, s.day - prev - 1)))
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
            if specs[i].isHard && specs[j].isHard { c += (health ? 50 : 3) * d }
            if specs[i].kind == specs[j].kind && specs[i].kind != .strength && slots[j].restBefore == 0 { c += 1 }
            // Hardest sessions straight after rest.
            c -= 0.4 * Double(specs[j].load) * Double(min(2, slots[j].restBefore))
        }
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

    /// Variants in order of appearance: Full Body A, B, C, A...
    static func assignVariants(_ specs: [Spec]) -> [Spec] {
        var counts: [String: Int] = [:]
        return specs.map { s in
            var s = s
            let key = "\(s.kind.rawValue)|\(s.template?.rawValue ?? s.groups.map(\.rawValue).joined())|\(s.label ?? "")"
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
                if s >= 2 {
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
        let strengthOpts: [Double]
        var intervalOpts: [Double]
        let restKinds: [[Kind]]
        switch ctx.goal {
        case .longevity:
            strengthOpts = [2, 2.5, 3]; intervalOpts = f >= 3 ? [1] : [0]
            restKinds = [[.zone2, .mobility], [.zone2, .zone2, .mobility], [.zone2, .recovery]]
        case .loseWeight:
            strengthOpts = f >= 3 ? [3] : [2]; intervalOpts = f >= 6 && !ctx.beginner ? [1, 2] : f >= 4 ? [1] : [0]
            restKinds = [[.zone2], [.zone2, .recovery]]
        case .improveEndurance:
            strengthOpts = [2]; intervalOpts = f >= 5 && !ctx.beginner ? [1, 2] : f >= 3 ? [1] : [0]
            restKinds = [[.zone2], [.zone2, .zone2, .recovery]]
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
                for mo in [0.0, 1, 2] {
                    var s = blk(so), i = blk(io), m = blk(mo)
                    if f <= 2.5 { s = min(s, n); m = 0 }
                    while s + i + m > n && m > 0 { m -= 1 }
                    while s + i + m > n && i > 0 { i -= 1 }
                    while s + i + m > n && s > 1 { s -= 1 }
                    let hardI = intervalKind == .intervals ? i : 0
                    var excess = s + hardI - cap
                    while excess > 0 && s > 1 { s -= 1; m += 1; excess -= 1 }
                    while excess > 0 && i > 0 { i -= 1; excess -= 1 }
                    var base: [Spec] = []
                    base += (0..<s).map { _ in Spec(kind: .strength, template: .fullBody, intensity: intensity) }
                    base += (0..<i).map { _ in Spec(kind: intervalKind) }
                    base += (0..<m).map { _ in Spec(kind: .mixed, intensity: intensity) }
                    for rk in restKinds { out.append(fill(base, restKinds: rk)) }
                }
            }
        }
        if f <= 2.5 {
            out.append((0..<n).map { _ in Spec(kind: .mixed, intensity: intensity) })
        }
        return out
    }

    // MARK: - Volume

    struct VolumeLine: Equatable {
        let group: String
        let sets: Double          // per week
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

    /// Moves weekly sets into each group's range: trims overs, adds where
    /// time allows, shifts sets from groups with room, adds accessories.
    static func adjustVolume(_ plan: inout Plan, ctx: Ctx) {
        var stuck = Set<String>()
        for _ in 0..<400 {
            let report = volumeReport(plan)
            var changed = false
            // Over the range: drop a set from the biggest contributor.
            if let over = report.filter({ $0.sets > Double($0.target.upperBound) + 0.01 })
                .max(by: { $0.sets - Double($0.target.upperBound) < $1.sets - Double($1.target.upperBound) }) {
                // Trim where the group is the lift's main target; a main lift is
                // never cut for a group it only assists (glutes on squats).
                var bestIdx: (Int, Int)? = nil, bestW = 0.0
                for (si, s) in plan.sessions.enumerated() {
                    for (ii, it) in s.items.enumerated() where it.kind == .lift && it.sets > 2 {
                        let wgt = it.muscles[over.group] ?? 0
                        let primary = wgt > 0 && wgt >= (it.muscles.values.max() ?? 0)
                        let isolation = !(it.pattern?.isCompound ?? false)
                        guard primary || (isolation && wgt > 0) else { continue }
                        let rank = wgt + (primary ? 1 : 0)
                        if rank > bestW { bestW = rank; bestIdx = (si, ii) }
                    }
                }
                if let (si, ii) = bestIdx { plan.sessions[si].items[ii].sets -= 1; changed = true; continue }
            }
            let byGroup = Dictionary(uniqueKeysWithValues: report.map { ($0.group, $0) })
            let unders = report.filter { $0.sets < Double($0.target.lowerBound) - 0.01 && !stuck.contains($0.group) }
                .sorted { $0.sets / Double(max(1, $0.target.lowerBound)) < $1.sets / Double(max(1, $1.target.lowerBound)) }
            guard let under = unders.first else { break }
            let g = under.group
            // Room a group has to give a set without dropping under its floor.
            // Main lifts only give sets to other main lifts.
            func canGive(_ it: Item, to receiver: Item?) -> Bool {
                guard it.kind == .lift, it.sets > 2, (it.muscles[g] ?? 0) == 0 else { return false }
                if it.pattern?.isCompound ?? false {
                    guard let rc = receiver, rc.pattern?.isCompound ?? false, it.sets > ctx.compoundSets else { return false }
                }
                return it.muscles.allSatisfy { mg, wgt in
                    guard let l = byGroup[mg] else { return true }
                    return l.sets - wgt / plan.weeks >= Double(l.target.lowerBound) + 1
                }
            }
            // a) add a set where there is time
            var done = false
            for si in plan.sessions.indices.sorted(by: { plan.sessions[$0].budget - plan.sessions[$0].strengthMinutes > plan.sessions[$1].budget - plan.sessions[$1].strengthMinutes }) {
                let s = plan.sessions[si]
                guard let ii = s.items.indices.filter({ i in
                    let it = s.items[i]
                    let cap = (it.pattern?.isCompound ?? false) ? ctx.maxSets : ctx.isoSets + 1
                    return it.kind == .lift && (it.muscles[g] ?? 0) >= 1 && it.sets < cap })
                    .first else { continue }
                let it = s.items[ii]
                let wouldExceed = it.muscles.contains { mg, wgt in
                    guard let l = byGroup[mg] else { return false }
                    return l.sets + wgt / plan.weeks > Double(min(l.mrv, l.target.upperBound)) + 0.01
                }
                if wouldExceed { continue }
                if s.strengthMinutes + it.perSet <= s.budget + 0.01 {
                    plan.sessions[si].items[ii].sets += 1; done = true; break
                }
                // b) shift a set from a lift whose groups have room
                if let di = s.items.indices.first(where: { canGive(s.items[$0], to: it) }),
                   s.strengthMinutes - s.items[di].perSet + it.perSet <= s.budget + 0.01 {
                    plan.sessions[si].items[di].sets -= 1
                    plan.sessions[si].items[ii].sets += 1
                    done = true; break
                }
            }
            // c) add an accessory to a strength session with room
            if !done {
                // Only on a day that already trains that region (no curls on leg day).
                let region = ["Chest", "Back", "Shoulders", "Biceps", "Triceps"].contains(g) ? 0 : g == "Core" ? -1 : 1
                for si in plan.sessions.indices where plan.sessions[si].spec.kind == .strength
                    && (region < 0 || plan.sessions[si].fatigue[region] >= 2) {
                    let s = plan.sessions[si]
                    guard s.items.filter({ $0.kind == .lift }).count < ctx.maxExercises else { continue }
                    var used = Set(s.items.map(\.name))
                    var mv: Move? = nil
                    for p in isoPattern(for: g) {
                        if let m = pick(p, variant: 0, ctx: ctx, intensity: s.spec.intensity, used: used), (m.muscles[g] ?? 0) >= 1 { mv = m; break }
                    }
                    guard let m = mv else { continue }
                    let ps = perSet(s.spec.intensity, compound: m.pattern.isCompound)
                    let need = 2 * ps + 1
                    var freed: [Int] = []
                    var room = s.budget - s.strengthMinutes
                    for di in s.items.indices where room < need && canGive(s.items[di], to: nil) {
                        freed.append(di); room += s.items[di].perSet
                    }
                    guard room >= need else { continue }
                    for di in freed { plan.sessions[si].items[di].sets -= 1 }
                    used.insert(m.name)
                    let r = m.reps ?? reps(s.spec.intensity, compound: m.pattern.isCompound, ctx: ctx)
                    let lifts = plan.sessions[si].items.lastIndex { $0.kind == .lift }.map { $0 + 1 } ?? 0
                    plan.sessions[si].items.insert(Item(kind: .lift, name: m.name, sets: 2, reps: r, pattern: m.pattern, muscles: m.muscles,
                                                        perSet: ps, gear: m.gear), at: lifts)
                    done = true; break
                }
            }
            if done { changed = true } else { stuck.insert(g) }
            if !changed && stuck.count >= muscleGroups.count { break }
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
            if health && plan.sessions[i].isHard && plan.sessions[j].isHard && plan.slots[j].restBefore == 0 { p += 4 }
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
            parts = [ratio(st.strengthSessions, min(2, f), 3), ratio(st.aerobic, 150), ratio(st.vo2, f >= 3 ? 1 : 0, 2),
                     ratio(st.mobility, 60), ratio(st.balanceSessions, min(2, f))]
        case .generalFitness:
            parts = [ratio(st.strengthSessions, min(2, f), 4), ratio(st.aerobic, 120), ratio(st.mobility, 30)]
        case .increaseFlexibility:
            parts = [ratio(st.strengthSessions, min(2, f), 3), ratio(st.mobility, 120)]
        case .improveEndurance:
            parts = [ratio(st.aerobic, 200), ratio(st.strengthSessions, min(2, f), 3), ratio(st.vo2, f >= 3 ? 1 : 0, 2)]
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

    static func realize(_ specs: [Spec], ctx: Ctx, slots: [Slot], blockDays: Int, adjust: Bool) -> Plan {
        var plan = Plan(config: ctx.config, slots: slots, sessions: specs.map { build($0, ctx: ctx) }, blockDays: blockDays)
        if adjust { adjustVolume(&plan, ctx: ctx) }
        return plan
    }

    /// The Smart Advisor program: best-scoring candidate for this config.
    static func plan(for config: ProgramConfig, start: Date? = nil, calendar: Calendar = .current) -> Plan {
        let ctx = Ctx(config: config)
        let (slots, blockDays) = self.slots(for: config, start: start, calendar: calendar)
        var best: Plan? = nil
        var bestScore = -Double.infinity
        for cand in candidates(ctx: ctx, slots: slots, blockDays: blockDays) where cand.count == slots.count {
            let placed = assignVariants(place(cand, slots: slots, health: ctx.healthGoal, blockDays: blockDays))
            let p = realize(placed, ctx: ctx, slots: slots, blockDays: blockDays, adjust: true)
            let sc = qualityScore(p).total
            if sc > bestScore + 1e-9 { bestScore = sc; best = p }
        }
        return best ?? Plan(config: config, slots: slots, sessions: [], blockDays: blockDays)
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
    /// Minutes the lifting part takes (warm-up included).
    var strengthMinutes: Double {
        let lifts = items.filter { $0.kind == .lift }
        return lifts.isEmpty ? 0 : lifts.reduce(5) { $0 + $1.duration }
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
            print("  volume: " + volumeReport(p).map { "\($0.group) \(String(format: "%.1f", $0.sets)) [\($0.target.lowerBound)-\($0.target.upperBound)]" }.joined(separator: ", "))
            for split in ProgramSplit.allCases where split != .auto {
                let nq = qualityScore(naivePlan(for: c, split: split))
                print("  naive \(split.rawValue): \(String(format: "%.1f", nq.total)) f\(String(format: "%.2f", nq.frequency)) v\(String(format: "%.2f", nq.volume)) r\(String(format: "%.2f", nq.recovery)) c\(String(format: "%.2f", nq.coverage)) b\(String(format: "%.2f", nq.balance))")
            }
        }
    }
}
