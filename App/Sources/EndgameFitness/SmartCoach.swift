//
//  SmartCoach.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  The on-device training engine. Everything here is plain arithmetic over
//  the lifter's own logged sets: no network, no randomness, same answer every
//  time for the same history, so the selftest can pin it down.
//
//    • per-exercise state: estimated 1RM (Epley/Brzycki blend, or the RPE
//      chart when reps in reserve were logged), best set, trend, stall,
//      fatigue signals and a readiness score
//    • five progression models: Linear, Double, RPE/RIR, percentage waves
//      (3-week wave or accumulation/intensification/realization blocks) and
//      Auto, which picks one from experience, goal and history
//    • next-session prescription with a plain reason, loads rounded to what
//      the lifter can actually load
//    • stall resets, planned deload weeks and fatigue deloads
//    • weekly sets per muscle group against simple volume landmarks
//    • missed-day nudges for weekly and rolling schedules
//

import Foundation

// MARK: - Context

/// The cycle-level settings the engine needs. `current` reads what the
/// program wizard saved; tests build one by hand.
struct CoachContext: Equatable {
    var model: ProgressionStyle = .auto
    var experience: ExperienceLevel = .beginner
    var goal: TrainingGoal = .generalFitness
    var unit: WeightUnit = .lb
    /// 0-based week of the current cycle.
    var weekInCycle: Int = 0
    /// Training weeks, not counting the deload week.
    var cycleWeeks: Int = 6
    var deloadEnabled: Bool = true

    var isDeloadWeek: Bool { deloadEnabled && weekInCycle == cycleWeeks }
    var totalWeeks: Int { cycleWeeks + (deloadEnabled ? 1 : 0) }

    static func current(profile: UserProfile? = nil, now: Date = Date()) -> CoachContext {
        let d = UserDefaults.standard
        var c = CoachContext()
        c.model = ProgressionStyle(rawValue: d.string(forKey: "progressionStyle") ?? "") ?? .auto
        c.experience = ExperienceLevel(rawValue: d.string(forKey: "progressionExperience") ?? "")
            ?? profile?.experienceLevel ?? .beginner
        c.goal = TrainingGoal(rawValue: d.string(forKey: "progressionGoal") ?? "")
            ?? profile?.primaryGoals.first ?? .generalFitness
        c.unit = TrainingUnits.current
        let weeks = d.integer(forKey: "mesocycleWeeks")
        c.cycleWeeks = weeks > 0 ? weeks : 6
        c.deloadEnabled = d.object(forKey: "deloadEnabled") as? Bool ?? true
        let start = d.double(forKey: "programStartDate")
        if start > 0 {
            c.weekInCycle = Self.weekInCycle(start: Date(timeIntervalSince1970: start), now: now,
                                             totalWeeks: c.totalWeeks)
        }
        return c
    }

    static func weekInCycle(start: Date, now: Date, totalWeeks: Int) -> Int {
        let days = Int(floor(now.timeIntervalSince(start) / 86_400))
        guard days >= 0 else { return 0 }
        return (days / 7) % max(1, totalWeeks)
    }
}

// MARK: - Progression model descriptions

extension ProgressionStyle {
    /// One honest sentence per model for the wizard.
    var explanation: String {
        switch self {
        case .auto:
            return "Smart Advisor runs the numbers on every set you log and adjusts how you progress as your training changes."
        case .linear:
            return "Same reps every session; add a fixed jump (5 lb upper, 10 lb lower, or 2.5/5 kg) whenever you complete every set. Fast, and it stops working once lifts stall."
        case .double:
            return "Work up through a rep range at one weight. When every set reaches the top, the weight goes up and you start again at the bottom."
        case .rpe:
            return "You log reps in reserve; the load is worked out from your estimated max so each top set lands near the target effort. Best once you can judge effort honestly."
        case .waves:
            return "Loads are a percentage of a training max (90% of your estimated max). Short cycles run a 3-week 5/3/1-style wave; 8+ week cycles run volume, intensity and peak blocks."
        }
    }
}

// MARK: - Exercise state

struct ExerciseExposure: Equatable {
    let date: Date
    /// Heaviest completed set's load (lb).
    let topWeight: Double
    /// Reps on the heaviest set (best if several).
    let topReps: Int
    /// Best estimated 1RM among the session's sets.
    let e1RM: Double
    /// Sets at the top weight.
    let workingSets: [ExerciseSet]
    /// Average RIR of working sets, when logged.
    let averageRIR: Double?
}

struct ExerciseState: Equatable {
    let key: String
    /// Oldest first.
    let exposures: [ExerciseExposure]
    /// Recent e1RM (mean of the last two exposures, smooths one off day).
    let e1RM: Double
    let bestE1RM: Double
    let bestSet: ExerciseSet?
    let recentRIR: Double?
    /// e1RM change in lb per week over the last six exposures (least squares).
    let trendPerWeek: Double
    /// No e1RM gain over the last three exposures.
    let isStalled: Bool
    /// Missed the bottom of the rep range two sessions running.
    let missedRepsTwice: Bool
    /// Same or lower load, effort climbing (RIR dropping) over three sessions.
    let effortCreep: Bool
    /// 0–100. Starts at 100; fatigue signals, stalls and long gaps lower it.
    let readiness: Int

    var needsDeload: Bool { missedRepsTwice || effortCreep }
}

enum SmartCoach {

    // MARK: Estimated 1RM

    static func epley(weight: Double, reps: Int) -> Double {
        guard reps > 0, weight > 0 else { return 0 }
        return reps == 1 ? weight : weight * (1 + Double(reps) / 30)
    }

    static func brzycki(weight: Double, reps: Int) -> Double {
        guard reps > 0, weight > 0, reps < 37 else { return 0 }
        return weight * 36 / (37 - Double(reps))
    }

    /// Epley and Brzycki agree at 10 reps; below it Brzycki runs low and
    /// Epley high, so the mean is used up to 10 and Epley alone above.
    /// With reps in reserve logged, the RPE chart is used instead.
    static func e1RM(weight: Double, reps: Int, rir: Int? = nil) -> Double {
        guard reps > 0, weight > 0 else { return 0 }
        if let rir, rir >= 0 {
            let pct = percentOf1RM(reps: reps, rpe: 10 - Double(min(rir, 4)))
            return pct > 0 ? weight / pct : 0
        }
        if reps == 1 { return weight }
        if reps <= 10 { return (epley(weight: weight, reps: reps) + brzycki(weight: weight, reps: reps)) / 2 }
        return epley(weight: weight, reps: reps)
    }

    /// Reps-to-failure → fraction of 1RM (the common RPE chart, RPE 10 row).
    private static let rtfTable: [Double] = [1.0, 0.955, 0.922, 0.892, 0.863, 0.837, 0.811, 0.786,
                                             0.762, 0.739, 0.707, 0.680, 0.653, 0.626, 0.599]

    /// Fraction of 1RM for `reps` at `rpe` (6–10, halves allowed). Reps to
    /// failure = reps + (10 − RPE); fractional values interpolate.
    static func percentOf1RM(reps: Int, rpe: Double) -> Double {
        guard reps > 0 else { return 0 }
        let rtf = Double(reps) + (10 - min(10, max(5, rpe)))
        let i = max(0, rtf - 1)
        let lo = Int(floor(i)), hi = lo + 1
        func v(_ k: Int) -> Double {
            if k < rtfTable.count { return rtfTable[k] }
            return max(0.4, rtfTable.last! - Double(k - rtfTable.count + 1) * 0.027)
        }
        let f = i - Double(lo)
        return v(lo) * (1 - f) + v(hi) * f
    }

    /// Load (lb) for `reps` at `rpe` from an e1RM (lb).
    static func load(e1RM: Double, reps: Int, rpe: Double) -> Double {
        e1RM * percentOf1RM(reps: reps, rpe: rpe)
    }

    // MARK: Plate rounding

    /// The smallest load jump the lifter can make for this exercise, in the
    /// display unit: barbell = two of the smallest plate, dumbbells 5 lb /
    /// 2 kg, everything else 5 lb / 2.5 kg.
    static func increment(equipment: String?, unit: WeightUnit) -> Double {
        switch equipment?.lowercased() {
        case "barbell", "e-z curl bar":
            return (PlateMath.plates(for: unit).min() ?? (unit == .kg ? 1.25 : 2.5)) * 2
        case "dumbbell":
            return unit == .kg ? 2 : 5
        case "kettlebells":
            return unit == .kg ? 4 : 5
        default:
            return unit == .kg ? 2.5 : 5
        }
    }

    /// Rounds a load (lb) to the nearest loadable step in the lifter's unit
    /// and returns pounds again. Never below zero.
    static func roundToLoadable(_ pounds: Double, unit: WeightUnit, equipment: String? = "barbell") -> Double {
        guard pounds > 0 else { return 0 }
        let step = increment(equipment: equipment, unit: unit)
        let display = TrainingUnits.toDisplay(pounds, unit)
        let rounded = max(step, (display / step).rounded() * step)
        return TrainingUnits.toPounds(max(0, rounded), from: unit)
    }

    // MARK: State

    static func exposures(key: String, history: [WorkoutSession], excluding: UUID? = nil) -> [ExerciseExposure] {
        var out: [ExerciseExposure] = []
        for session in history.sorted(by: { $0.date < $1.date }) where session.id != excluding {
            let sets = session.exercises.filter { $0.identityKey == key }
                .flatMap(\.completedSets).filter { $0.reps > 0 }
            guard !sets.isEmpty else { continue }
            let top = sets.map(\.weight).max() ?? 0
            let working = sets.filter { abs($0.weight - top) < 0.01 }
            let rirs = working.compactMap(\.rir)
            let best = sets.map { e1RM(weight: $0.weight, reps: $0.reps, rir: $0.rir) }.max() ?? 0
            out.append(ExerciseExposure(date: session.date, topWeight: top,
                                        topReps: working.map(\.reps).max() ?? 0, e1RM: best,
                                        workingSets: working,
                                        averageRIR: rirs.isEmpty ? nil : Double(rirs.reduce(0, +)) / Double(rirs.count)))
        }
        return out
    }

    /// Least-squares slope of e1RM against days, scaled to a week.
    static func trendPerWeek(_ points: [ExerciseExposure]) -> Double {
        guard points.count >= 2, let first = points.first?.date else { return 0 }
        let xs = points.map { $0.date.timeIntervalSince(first) / 86_400 }
        let ys = points.map(\.e1RM)
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let den = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard den > 0 else { return 0 }
        let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return num / den * 7
    }

    static func state(key: String, history: [WorkoutSession], repRange: ClosedRange<Int>? = nil,
                      excluding: UUID? = nil, now: Date = Date()) -> ExerciseState? {
        let ex = exposures(key: key, history: history, excluding: excluding)
        guard let last = ex.last else { return nil }
        let recent = ex.suffix(2).map(\.e1RM)
        let e1 = recent.reduce(0, +) / Double(recent.count)
        let bestE1 = ex.map(\.e1RM).max() ?? 0

        var bestSet: ExerciseSet?
        var bestSetE1 = 0.0
        for e in ex { for s in e.workingSets where e1RM(weight: s.weight, reps: s.reps) > bestSetE1 {
            bestSetE1 = e1RM(weight: s.weight, reps: s.reps); bestSet = s
        } }

        // Stall: the last three exposures never beat what came before them.
        var stalled = false
        if ex.count >= 4 {
            let before = ex.dropLast(3).map(\.e1RM).max() ?? 0
            let lastThree = ex.suffix(3).map(\.e1RM).max() ?? 0
            stalled = lastThree <= before * 1.005
        }

        // Missed reps: bottom of the range not reached, twice running.
        var missedTwice = false
        if let range = repRange, ex.count >= 2 {
            missedTwice = ex.suffix(2).allSatisfy { e in
                e.workingSets.contains { $0.reps < range.lowerBound }
            }
        }

        // Effort creep: three exposures with RIR logged, load not rising, RIR
        // falling each time by a total of 2 or more.
        var creep = false
        let lastThree = Array(ex.suffix(3))
        if lastThree.count == 3, lastThree.allSatisfy({ $0.averageRIR != nil }) {
            let r = lastThree.map { $0.averageRIR! }
            let w = lastThree.map(\.topWeight)
            creep = r[1] <= r[0] && r[2] <= r[1] && r[0] - r[2] >= 2 && w[2] <= w[0] + 0.01
        }

        var readiness = 100
        if missedTwice { readiness -= 30 }
        if creep { readiness -= 25 }
        if stalled { readiness -= 15 }
        if let rir = last.averageRIR, rir < 1 { readiness -= 10 }
        let gapDays = now.timeIntervalSince(last.date) / 86_400
        if gapDays > 14 { readiness -= 15 }

        return ExerciseState(key: key, exposures: ex, e1RM: e1, bestE1RM: bestE1, bestSet: bestSet,
                             recentRIR: last.averageRIR, trendPerWeek: trendPerWeek(Array(ex.suffix(6))),
                             isStalled: stalled, missedRepsTwice: missedTwice, effortCreep: creep,
                             readiness: max(0, min(100, readiness)))
    }

    // MARK: Auto model choice

    /// Which concrete model Auto runs, from experience, goal and how much
    /// history this exercise has.
    static func resolvedModel(_ ctx: CoachContext, state: ExerciseState?) -> ProgressionStyle {
        guard ctx.model == .auto else { return ctx.model }
        let exposures = state?.exposures.count ?? 0
        switch ctx.experience {
        case .beginner:
            // Linear until it stops working or there's a lot of history.
            if (state?.isStalled ?? false) || exposures >= 24 { return .double }
            return .linear
        case .intermediate:
            return ctx.goal == .getStronger ? .waves : .double
        case .advanced, .expert:
            if ctx.goal == .getStronger { return .waves }
            // RPE needs logged effort; without it, double progression.
            let hasRIR = state?.exposures.suffix(3).contains { $0.averageRIR != nil } ?? false
            return hasRIR || exposures == 0 ? .rpe : .double
        }
    }

    // MARK: Prescription

    struct PlannedLoad: Equatable {
        let reps: Int
        let weightLb: Double
    }

    struct Prescription: Equatable {
        enum Kind: Equatable { case baseline, increase, hold, addReps, reset, deload, bodyweight, percentage, autoregulated }
        let model: ProgressionStyle
        let kind: Kind
        /// One row per planned set.
        let sets: [PlannedLoad]
        let targetRPE: Double?
        let reason: String

        var topLoad: Double { sets.map(\.weightLb).max() ?? 0 }
        var topReps: Int { sets.last?.reps ?? 0 }
    }

    /// Percentages for the 3-week wave (5/3/1-style): week → [(% TM, reps)].
    static let waveWeeks: [[(Double, Int)]] = [
        [(0.65, 5), (0.75, 5), (0.85, 5)],
        [(0.70, 3), (0.80, 3), (0.90, 3)],
        [(0.75, 5), (0.85, 3), (0.95, 1)],
    ]

    enum Block: String { case accumulation = "Accumulation", intensification = "Intensification", realization = "Realization" }

    /// 40% / 40% / 20% of the training weeks.
    static func block(week: Int, cycleWeeks: Int) -> Block {
        let w = max(1, cycleWeeks)
        let a = max(1, Int((Double(w) * 0.4).rounded()))
        let i = max(1, Int((Double(w) * 0.4).rounded()))
        if week < a { return .accumulation }
        if week < a + i || w < 3 { return .intensification }
        return .realization
    }

    static func blockScheme(_ b: Block) -> (sets: Int, reps: Int, pct: Double) {
        switch b {
        case .accumulation: return (4, 8, 0.70)
        case .intensification: return (4, 5, 0.80)
        case .realization: return (3, 2, 0.90)
        }
    }

    static func targetRPE(goal: TrainingGoal) -> Double {
        switch goal {
        case .getStronger: return 8.5
        case .buildMuscle: return 8
        default: return 7.5
        }
    }

    private static func w(_ lb: Double, _ unit: WeightUnit) -> String { TrainingUnits.weight(lb, unit) }

    private static func step(_ lb: Double, _ unit: WeightUnit) -> String {
        let v = TrainingUnits.toDisplay(lb, unit)
        return "\(TrainingUnits.number((v * 10).rounded() / 10)) \(unit.label)"
    }

    /// The next session for one exercise. nil for timed work or when there's
    /// nothing to go on (no history and no prescribed load).
    static func prescribe(exercise: Exercise, history: [WorkoutSession], excluding: UUID? = nil,
                          context ctx: CoachContext, now: Date = Date()) -> Prescription? {
        let tracking = exercise.resolvedTracking
        guard tracking != .timed else { return nil }
        let range = ProgressionEngine.repRange(for: exercise)
        let st = state(key: exercise.identityKey, history: history, repRange: range, excluding: excluding, now: now)
        let model = resolvedModel(ctx, state: st)
        let unit = ctx.unit
        let equipment = exercise.exerciseID.flatMap { ExerciseLibrary.shared.entry(id: $0) }?.equipment
            ?? (tracking == .bodyweight ? "body only" : "barbell")
        let lower = ProgressionEngine.isLowerBody(exercise)
        let jump = TrainingUnits.progressionStepPounds(lowerBody: lower, unit: unit)
        let setCount = max(1, min(exercise.targetSets ?? st?.exposures.last?.workingSets.count ?? 3, 10))
        func rnd(_ lb: Double) -> Double { roundToLoadable(lb, unit: unit, equipment: equipment) }
        func rows(_ reps: Int, _ lb: Double, _ n: Int = setCount) -> [PlannedLoad] {
            Array(repeating: PlannedLoad(reps: reps, weightLb: lb), count: max(1, n))
        }

        guard let st, let last = st.exposures.last else {
            if let load = exercise.targetLoadLb, load > 0 {
                return Prescription(model: model, kind: .baseline, sets: rows(range.lowerBound, rnd(load)), targetRPE: nil,
                                    reason: "Program load. Today sets your baseline.")
            }
            return nil
        }
        let top = last.topWeight
        let bodyweightOnly = top <= 0

        // 1. Planned deload week.
        if ctx.isDeloadWeek {
            let load = bodyweightOnly ? 0 : rnd(top * 0.9)
            let n = max(1, (setCount + 1) / 2)
            return Prescription(model: model, kind: .deload, sets: rows(range.lowerBound, load, n), targetRPE: 6,
                                reason: "Deload week: half the sets\(bodyweightOnly ? "" : " at ~90%"), stop well short of failure.")
        }

        // 2. Fatigue deload.
        if st.needsDeload && !bodyweightOnly {
            let load = rnd(top * 0.9)
            let why = st.missedRepsTwice ? "missed the bottom of \(range.lowerBound)–\(range.upperBound) two sessions running"
                                         : "effort has climbed three sessions at the same load"
            return Prescription(model: model, kind: .deload, sets: rows(range.lowerBound, load, max(1, setCount - 1)),
                                targetRPE: 7, reason: "−10% to \(w(load, unit)): \(why). One lighter session, then build back.")
        }

        let working = last.workingSets
        let allHitTop = working.allSatisfy { $0.reps >= range.upperBound && ($0.rir ?? 1) >= 1 }

        switch model {
        case .linear, .auto:
            let reps = range.lowerBound
            if bodyweightOnly {
                let best = working.map(\.reps).max() ?? reps
                return Prescription(model: .linear, kind: .bodyweight, sets: rows(min(best + 1, range.upperBound + 5), 0),
                                    targetRPE: nil, reason: "Bodyweight: add a rep per set. Last best \(best).")
            }
            if st.isStalled {
                let load = rnd(top * 0.9)
                return Prescription(model: .linear, kind: .reset, sets: rows(reps, load), targetRPE: nil,
                                    reason: "Reset −10% to \(w(load, unit)): no gain in 3 sessions. You'll pass the old weight in a few weeks.")
            }
            let hit = working.allSatisfy { $0.reps >= reps }
            if hit {
                let load = rnd(top + jump)
                return Prescription(model: .linear, kind: .increase, sets: rows(reps, load), targetRPE: nil,
                                    reason: "+\(step(load - top, unit)): hit \(working.count)×\(reps) at \(w(top, unit)) last time.")
            }
            return Prescription(model: .linear, kind: .hold, sets: rows(reps, top), targetRPE: nil,
                                reason: "Same weight: last time fell short of \(reps) on a set. Complete every set to move up.")

        case .double:
            if st.isStalled && !bodyweightOnly {
                let load = rnd(top * 0.9)
                return Prescription(model: .double, kind: .reset, sets: rows(range.lowerBound, load), targetRPE: nil,
                                    reason: "Reset −10% to \(w(load, unit)): no gain in 3 sessions. Work back up the \(range.lowerBound)–\(range.upperBound) range.")
            }
            if allHitTop {
                if bodyweightOnly {
                    return Prescription(model: .double, kind: .bodyweight, sets: rows(range.upperBound, 0), targetRPE: nil,
                                        reason: "Top of the range on every set: add load or a harder variation.")
                }
                let load = rnd(top + jump)
                return Prescription(model: .double, kind: .increase, sets: rows(range.lowerBound, load), targetRPE: nil,
                                    reason: "+\(step(load - top, unit)): every set reached \(range.upperBound) last time. Back to \(range.lowerBound) reps.")
            }
            let best = working.map(\.reps).max() ?? range.lowerBound
            let next = min(max(best + 1, range.lowerBound), range.upperBound)
            return Prescription(model: .double, kind: .addReps, sets: rows(next, top), targetRPE: nil,
                                reason: "Same weight, aim for \(next) reps. Reach \(range.upperBound) on every set and the load goes up.")

        case .rpe:
            if bodyweightOnly {
                return Prescription(model: .rpe, kind: .bodyweight, sets: rows(range.upperBound, 0), targetRPE: 8,
                                    reason: "Bodyweight: stop each set with about 2 reps left.")
            }
            var rpe = targetRPE(goal: ctx.goal)
            if st.isStalled { rpe -= 1 }
            let reps = ctx.goal == .getStronger ? range.lowerBound : (range.lowerBound + range.upperBound) / 2
            let load = rnd(load(e1RM: st.e1RM, reps: reps, rpe: rpe))
            let stallNote = st.isStalled ? " Stalled 3 sessions, so one point easier this time." : ""
            return Prescription(model: .rpe, kind: .autoregulated, sets: rows(reps, load), targetRPE: rpe,
                                reason: "\(reps) reps @ RPE \(TrainingUnits.number(rpe)) from e1RM \(w(st.e1RM, unit)).\(stallNote) Log RIR so the next load adjusts.")

        case .waves:
            if bodyweightOnly {
                let best = working.map(\.reps).max() ?? range.lowerBound
                return Prescription(model: .waves, kind: .bodyweight, sets: rows(best + 1, 0), targetRPE: nil,
                                    reason: "Bodyweight: waves need a load. Add a rep per set.")
            }
            let tm = st.e1RM * 0.9
            if ctx.cycleWeeks >= 8 {
                let b = block(week: ctx.weekInCycle, cycleWeeks: ctx.cycleWeeks)
                let s = blockScheme(b)
                let load = rnd(tm * s.pct)
                return Prescription(model: .waves, kind: .percentage, sets: rows(s.reps, load, s.sets), targetRPE: nil,
                                    reason: "\(b.rawValue) block: \(s.sets)×\(s.reps) at \(Int(s.pct * 100))% of training max \(w(tm, unit)).")
            }
            let wk = ctx.weekInCycle % 3
            let plan = waveWeeks[wk].map { PlannedLoad(reps: $0.1, weightLb: rnd(tm * $0.0)) }
            let topPct = Int((waveWeeks[wk].last!.0) * 100)
            return Prescription(model: .waves, kind: .percentage, sets: plan, targetRPE: nil,
                                reason: "Wave week \(wk + 1): ramp to \(Int(topPct))% of training max \(w(tm, unit)). Last set: as many good reps as you can.")
        }
    }

    // MARK: Weekly volume landmarks

    struct Landmark: Equatable {
        let group: String
        /// Minimum effective, maximum adaptive (range), maximum recoverable sets per week.
        let mev: Int
        let mav: ClosedRange<Int>
        let mrv: Int
    }

    /// A simple, commonly used table of weekly hard sets per muscle group.
    static let landmarks: [Landmark] = [
        Landmark(group: "Chest", mev: 8, mav: 12...20, mrv: 22),
        Landmark(group: "Back", mev: 10, mav: 14...22, mrv: 25),
        Landmark(group: "Shoulders", mev: 8, mav: 16...22, mrv: 26),
        Landmark(group: "Biceps", mev: 8, mav: 14...20, mrv: 26),
        Landmark(group: "Triceps", mev: 6, mav: 10...14, mrv: 18),
        Landmark(group: "Quads", mev: 8, mav: 12...18, mrv: 20),
        Landmark(group: "Hamstrings", mev: 6, mav: 10...16, mrv: 20),
        Landmark(group: "Glutes", mev: 4, mav: 8...12, mrv: 16),
        Landmark(group: "Calves", mev: 8, mav: 12...16, mrv: 20),
        Landmark(group: "Core", mev: 4, mav: 10...16, mrv: 25),
    ]

    /// Library muscle names → landmark group.
    static func group(forMuscle muscle: String) -> String? {
        switch muscle.lowercased() {
        case "chest", "pectorals": return "Chest"
        case "lats", "middle back", "lower back", "traps", "back": return "Back"
        case "shoulders", "delts": return "Shoulders"
        case "biceps", "forearms": return "Biceps"
        case "triceps": return "Triceps"
        case "quadriceps", "quads", "legs": return "Quads"
        case "hamstrings": return "Hamstrings"
        case "glutes", "abductors", "adductors": return "Glutes"
        case "calves": return "Calves"
        case "abdominals", "abs", "core": return "Core"
        default: return nil
        }
    }

    struct VolumeStatus: Equatable, Identifiable {
        enum Level: Equatable { case under, maintenance, productive, high, over }
        let landmark: Landmark
        let sets: Int
        let level: Level
        let advice: String
        var id: String { landmark.group }
    }

    static func volumeStatus(group: String, sets: Int) -> VolumeStatus? {
        guard let lm = landmarks.first(where: { $0.group == group }) else { return nil }
        let level: VolumeStatus.Level
        let advice: String
        if sets < lm.mev {
            level = .under
            advice = "\(group) under target: add \(lm.mev - sets) set\(lm.mev - sets == 1 ? "" : "s") this week."
        } else if sets < lm.mav.lowerBound {
            level = .maintenance
            advice = "\(group) at maintenance. \(lm.mav.lowerBound - sets) more to grow."
        } else if sets <= lm.mav.upperBound {
            level = .productive
            advice = "\(group) on target (\(lm.mav.lowerBound)–\(lm.mav.upperBound))."
        } else if sets <= lm.mrv {
            level = .high
            advice = "\(group) high. Fine for a block, watch recovery."
        } else {
            level = .over
            advice = "\(group) over what most people recover from: cut \(sets - lm.mrv) set\(sets - lm.mrv == 1 ? "" : "s")."
        }
        return VolumeStatus(landmark: lm, sets: sets, level: level, advice: advice)
    }

    /// Completed sets per landmark group over the trailing 7 days, every
    /// group listed (zero included), worst first.
    static func weeklyVolume(from sessions: [WorkoutSession], now: Date = Date()) -> [VolumeStatus] {
        var counts: [String: Int] = [:]
        for row in TrainingStats.muscleWeek(from: sessions, days: 7, now: now) {
            if let g = group(forMuscle: row.muscle) { counts[g, default: 0] += row.sets }
        }
        let order: [VolumeStatus.Level: Int] = [.under: 0, .over: 1, .maintenance: 2, .high: 3, .productive: 4]
        return landmarks.compactMap { volumeStatus(group: $0.group, sets: counts[$0.group] ?? 0) }
            .sorted { (order[$0.level] ?? 9, $0.landmark.group) < (order[$1.level] ?? 9, $1.landmark.group) }
    }

    // MARK: Adherence

    /// Rolling schedule: how many training slots in a row, ending yesterday,
    /// passed with nothing logged (looks back at most `lookback` days).
    static func missedRollingDays(start: Date, daysOn: Int, daysOff: Int, logged: [Date], now: Date,
                                  lookback: Int = 7, calendar: Calendar = .current) -> Int {
        let loggedDays = Set(logged.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        if loggedDays.contains(today) { return 0 }
        var missed = 0
        for back in 1...max(1, lookback) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today), day >= calendar.startOfDay(for: start) else { break }
            if loggedDays.contains(day) { break }
            if WorkoutManager.rollingSlot(on: day, start: start, daysOn: daysOn, daysOff: daysOff, calendar: calendar) != nil {
                missed += 1
            }
        }
        return missed
    }

    /// Weekly schedule: scheduled weekdays in the last `lookback` days with no
    /// session that day, counting back until a logged day.
    static func missedWeeklyDays(weekdays: Set<String>, logged: [Date], now: Date, lookback: Int = 6,
                                 calendar: Calendar = .current) -> [String] {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let loggedDays = Set(logged.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)
        var missed: [String] = []
        for back in 1...max(1, lookback) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { break }
            if loggedDays.contains(day) { break }
            let name = names[calendar.component(.weekday, from: day) - 1]
            if weekdays.contains(name) { missed.append(name) }
        }
        return missed
    }
}

// MARK: - Session review (post-workout)

struct SessionReview: Equatable {
    struct Line: Equatable, Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }
    /// New best estimated 1RM per exercise.
    let records: [Line]
    /// What the engine will prescribe next time.
    let nextTime: [Line]

    static let empty = SessionReview(records: [], nextTime: [])

    /// `before` is history without this workout; `after` includes it.
    static func make(workout: WorkoutSession, before: [WorkoutSession], after: [WorkoutSession],
                     context: CoachContext) -> SessionReview {
        var records: [Line] = []
        var next: [Line] = []
        var seen = Set<String>()
        for exercise in workout.exercises where !exercise.completedSets.isEmpty {
            let key = exercise.identityKey
            guard seen.insert(key).inserted else { continue }
            let name = ProgramTargetParser.parse(exercise.name).name
            let old = SmartCoach.state(key: key, history: before)?.bestE1RM ?? 0
            let new = SmartCoach.state(key: key, history: after)?.bestE1RM ?? 0
            if old > 0, new > old + 0.5 {
                records.append(Line(name: name, text: "e1RM \(TrainingUnits.weight(new, context.unit)) (was \(TrainingUnits.weight(old, context.unit)))"))
            }
            if let p = SmartCoach.prescribe(exercise: exercise, history: after, context: context) {
                let load = p.topLoad > 0 ? "\(TrainingUnits.weight(p.topLoad, context.unit)) × \(p.topReps)" : "\(p.topReps) reps"
                next.append(Line(name: name, text: "\(load). \(p.reason)"))
            }
        }
        return SessionReview(records: records, nextTime: next)
    }
}
