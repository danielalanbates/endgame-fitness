//
//  ProgressionEngine.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Everything that reads training history to decide what comes next:
//    • program targets ("Bench Press 4x8-12" -> name + 4 sets of 8–12 reps)
//    • last time's sets for the "previous" column
//    • double progression: hit the top of the rep range on every working set
//      with at least 1 rep in reserve, and the load goes up next session
//      (+5 lb upper body / +10 lb lower body, or +2.5 / +5 kg)
//    • planned sets for a new exercise: from history, else the program target,
//      else empty
//    • personal records by the server's rule: best weight per rep count, with
//      the first log of an exercise at a rep count as the baseline (not a PR)
//
//  Only completed sets are ever read.
//

import Foundation

// MARK: - Program targets

/// One exercise of a program day with its prescription.
struct PlannedExercise: Codable, Equatable, Hashable {
    var name: String
    var sets: Int?
    var repMin: Int?
    var repMax: Int?
    var seconds: Int?
    /// Pounds, when the program prescribes a load.
    var loadLb: Double?

    var hasTarget: Bool { sets != nil || repMin != nil || seconds != nil }

    /// "4 × 8–12", "3 × 30s", "10 min" — empty when nothing is prescribed.
    var schemeText: String {
        var reps = ""
        if let repMin, let repMax { reps = repMin == repMax ? "\(repMin)" : "\(repMin)–\(repMax)" }
        else if let seconds { reps = seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds)s" }
        if let sets, sets > 1 || !reps.isEmpty {
            return reps.isEmpty ? "\(sets) sets" : "\(sets) × \(reps)"
        }
        return reps
    }
}

enum ProgramTargetParser {
    private static let patterns: [(NSRegularExpression, (([Int]) -> PlannedExercise))] = {
        func rx(_ p: String) -> NSRegularExpression {
            // Patterns are constants; a failure here is a programming error.
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            // 3x12-15
            (rx(#"\s+(\d{1,2})\s*[x×]\s*(\d{1,3})\s*[-–]\s*(\d{1,3})$"#),
             { PlannedExercise(name: "", sets: $0[0], repMin: $0[1], repMax: $0[2]) }),
            // 3x30s
            (rx(#"\s+(\d{1,2})\s*[x×]\s*(\d{1,4})\s*s(?:ec)?$"#),
             { PlannedExercise(name: "", sets: $0[0], seconds: $0[1]) }),
            // 4x30m (a distance: keep the set count only)
            (rx(#"\s+(\d{1,2})\s*[x×]\s*(\d{1,4})\s*m$"#),
             { PlannedExercise(name: "", sets: $0[0]) }),
            // 5x5
            (rx(#"\s+(\d{1,2})\s*[x×]\s*(\d{1,3})\+?$"#),
             { PlannedExercise(name: "", sets: $0[0], repMin: $0[1], repMax: $0[1]) }),
            // 10 min
            (rx(#"\s+(\d{1,3})\s*min(?:utes?)?$"#),
             { PlannedExercise(name: "", sets: 1, seconds: $0[0] * 60) }),
            // 8-12 (rep range only)
            (rx(#"\s+(\d{1,3})\s*[-–]\s*(\d{1,3})$"#),
             { PlannedExercise(name: "", repMin: $0[0], repMax: $0[1]) }),
        ]
    }()

    /// Splits a trailing scheme off a program exercise name. Names without a
    /// scheme come back unchanged with no targets.
    static func parse(_ raw: String) -> PlannedExercise {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        for (regex, build) in patterns {
            guard let m = regex.firstMatch(in: text, range: range) else { continue }
            var numbers: [Int] = []
            for i in 1..<m.numberOfRanges {
                if let r = Range(m.range(at: i), in: text), let n = Int(text[r]) { numbers.append(n) }
            }
            guard numbers.count == m.numberOfRanges - 1, let whole = Range(m.range, in: text) else { continue }
            var plan = build(numbers)
            plan.name = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let lo = plan.repMin, let hi = plan.repMax, lo > hi { plan.repMin = hi; plan.repMax = lo }
            if plan.name.isEmpty { return PlannedExercise(name: text) }
            return plan
        }
        return PlannedExercise(name: text)
    }
}

// MARK: - Rep range settings

enum ProgressionSettings {
    private static func key(_ identity: String) -> String { "progression.range.\(identity)" }

    /// The lifter's own rep range for an exercise, if they set one.
    static func customRange(for identity: String) -> ClosedRange<Int>? {
        guard let pair = UserDefaults.standard.array(forKey: key(identity)) as? [Int], pair.count == 2,
              pair[0] >= 1, pair[1] >= pair[0] else { return nil }
        return pair[0]...pair[1]
    }

    static func setCustomRange(_ range: ClosedRange<Int>?, for identity: String) {
        if let range { UserDefaults.standard.set([range.lowerBound, range.upperBound], forKey: key(identity)) }
        else { UserDefaults.standard.removeObject(forKey: key(identity)) }
    }
}

// MARK: - Engine

struct ProgressionSuggestion: Equatable {
    enum Kind: Equatable {
        /// Every working set reached the top of the range with reps in reserve.
        case increaseLoad
        /// Same load; beat last time's reps.
        case addReps
        /// Bodyweight at the top of the range: add load or a harder variation.
        case topOfRangeBodyweight
    }
    let kind: Kind
    let weightLb: Double?
    let targetReps: Int
    let range: ClosedRange<Int>
    let lastSets: [ExerciseSet]
}

enum ProgressionEngine {
    /// Rep range: the program's target, else the lifter's override, else a
    /// default by movement type (compound 6–10, isolation 10–15, else 8–12).
    static func repRange(for exercise: Exercise) -> ClosedRange<Int> {
        if let lo = exercise.targetRepMin, let hi = exercise.targetRepMax, lo >= 1, hi >= lo { return lo...hi }
        if let custom = ProgressionSettings.customRange(for: exercise.identityKey) { return custom }
        let mechanic = exercise.exerciseID.flatMap { ExerciseLibrary.shared.entry(id: $0) }?.mechanic
        switch mechanic {
        case "compound": return 6...10
        case "isolation": return 10...15
        default: return 8...12
        }
    }

    static func isLowerBody(_ exercise: Exercise) -> Bool {
        ExerciseLibrary.isLowerBody(muscles: exercise.musclesForStats)
    }

    /// Completed sets from the most recent session (other than `excluding`)
    /// that includes this exercise, plus that session's date.
    static func lastPerformance(of exercise: Exercise, in sessions: [WorkoutSession],
                                excluding: UUID? = nil) -> (date: Date, sets: [ExerciseSet])? {
        let key = exercise.identityKey
        var best: (date: Date, sets: [ExerciseSet])?
        for session in sessions where session.id != excluding {
            if let current = best, session.date <= current.date { continue }
            let sets = session.exercises.filter { $0.identityKey == key }.flatMap(\.completedSets)
            if !sets.isEmpty { best = (session.date, sets) }
        }
        return best
    }

    /// Double progression, from last time's completed sets.
    static func suggestion(for exercise: Exercise, history: [WorkoutSession],
                           excluding: UUID? = nil, unit: WeightUnit = TrainingUnits.current) -> ProgressionSuggestion? {
        let tracking = exercise.resolvedTracking
        guard tracking != .timed, let last = lastPerformance(of: exercise, in: history, excluding: excluding) else { return nil }
        let range = repRange(for: exercise)
        let topWeight = last.sets.map(\.weight).max() ?? 0
        let working = last.sets.filter { abs($0.weight - topWeight) < 0.01 && $0.reps > 0 }
        guard !working.isEmpty else { return nil }
        let reachedTop = working.allSatisfy { $0.reps >= range.upperBound && ($0.rir ?? 1) >= 1 }
        let bestReps = working.map(\.reps).max() ?? range.lowerBound

        if reachedTop {
            if tracking == .weighted || topWeight > 0 {
                let step = TrainingUnits.progressionStepPounds(lowerBody: isLowerBody(exercise), unit: unit)
                return ProgressionSuggestion(kind: .increaseLoad, weightLb: topWeight + step,
                                             targetReps: range.lowerBound, range: range, lastSets: last.sets)
            }
            return ProgressionSuggestion(kind: .topOfRangeBodyweight, weightLb: nil,
                                         targetReps: range.upperBound, range: range, lastSets: last.sets)
        }
        return ProgressionSuggestion(kind: .addReps, weightLb: topWeight > 0 ? topWeight : nil,
                                     targetReps: min(bestReps + 1, range.upperBound), range: range, lastSets: last.sets)
    }

    /// The planned (unticked) rows for an exercise added to a workout: from
    /// history, else from the program target, else empty fields.
    static func plannedSets(for exercise: Exercise, history: [WorkoutSession], excluding: UUID? = nil) -> [ExerciseSet] {
        let tracking = exercise.resolvedTracking
        let last = lastPerformance(of: exercise, in: history, excluding: excluding)?.sets ?? []
        let suggestion = self.suggestion(for: exercise, history: history, excluding: excluding)
        let defaultCount = tracking == .timed ? 1 : 3
        let count = max(1, min(exercise.targetSets ?? (last.isEmpty ? defaultCount : last.count), 10))

        return (0..<count).map { i in
            let previous = last.indices.contains(i) ? last[i] : last.last
            switch tracking {
            case .timed:
                return ExerciseSet(durationSecs: previous?.durationSecs ?? exercise.targetSeconds)
            case .weighted, .bodyweight:
                if let suggestion, suggestion.kind == .increaseLoad, let w = suggestion.weightLb {
                    return ExerciseSet(reps: suggestion.targetReps, weight: w)
                }
                if let previous {
                    return ExerciseSet(reps: previous.reps, weight: previous.weight)
                }
                let reps = exercise.targetRepMin ?? 0
                return ExerciseSet(reps: reps, weight: exercise.targetLoadLb ?? 0)
            }
        }
    }

    // MARK: Personal records

    /// Best weight at exactly `reps` before this set, across history and the
    /// earlier completed sets of the current workout. nil = no baseline yet.
    static func previousBest(atReps reps: Int, key: String, history: [WorkoutSession],
                             current: WorkoutSession?, excludingSet: UUID) -> Double? {
        var best: Double?
        func consider(_ sets: [ExerciseSet]) {
            for s in sets where s.completed && s.reps == reps && s.weight > 0 && s.id != excludingSet {
                best = max(best ?? 0, s.weight)
            }
        }
        for session in history {
            for e in session.exercises where e.identityKey == key { consider(e.sets) }
        }
        if let current {
            for e in current.exercises where e.identityKey == key { consider(e.sets) }
        }
        return best
    }

    /// A PR by the server's rule: more weight than ever before at this rep
    /// count. The first time a rep count is logged is the baseline.
    static func isPersonalRecord(_ set: ExerciseSet, in exercise: Exercise, history: [WorkoutSession],
                                 current: WorkoutSession?) -> Bool {
        guard set.completed, set.reps > 0, set.weight > 0 else { return false }
        guard let best = previousBest(atReps: set.reps, key: exercise.identityKey, history: history,
                                      current: current, excludingSet: set.id) else { return false }
        return set.weight > best + 0.001
    }

    /// Epley estimated one-rep max.
    static func e1RM(weight: Double, reps: Int) -> Double {
        guard reps > 0, weight > 0 else { return 0 }
        return reps == 1 ? weight : weight * (1 + Double(reps) / 30)
    }
}

// MARK: - Records and muscle volume (Progress tab)

struct ExerciseRecord: Identifiable {
    struct RepMax: Identifiable {
        let reps: Int
        let weight: Double
        let date: Date
        var id: Int { reps }
    }
    let key: String
    let name: String
    let bestE1RM: Double
    let bestSetWeight: Double
    let bestSetReps: Int
    let bestDate: Date
    /// Best weight at each rep count — the same table the server keeps.
    let repMaxes: [RepMax]
    let sessionCount: Int
    var id: String { key }
}

struct MuscleWeek: Identifiable {
    let muscle: String
    let sets: Int
    let volume: Double
    var id: String { muscle }
}

enum TrainingStats {
    static func records(from sessions: [WorkoutSession]) -> [ExerciseRecord] {
        struct Acc {
            var name: String
            var best: (e1rm: Double, weight: Double, reps: Int, date: Date)?
            var repMax: [Int: (Double, Date)] = [:]
            var sessions: Set<UUID> = []
        }
        var table: [String: Acc] = [:]
        for session in sessions.sorted(by: { $0.date < $1.date }) {
            for exercise in session.exercises {
                let sets = exercise.completedSets.filter { $0.reps > 0 && $0.weight > 0 }
                guard !sets.isEmpty else { continue }
                let key = exercise.identityKey
                var acc = table[key] ?? Acc(name: ProgramTargetParser.parse(exercise.name).name)
                acc.name = ProgramTargetParser.parse(exercise.name).name
                acc.sessions.insert(session.id)
                for s in sets {
                    let e = ProgressionEngine.e1RM(weight: s.weight, reps: s.reps)
                    if e > (acc.best?.e1rm ?? 0) { acc.best = (e, s.weight, s.reps, session.date) }
                    if s.weight > (acc.repMax[s.reps]?.0 ?? 0) { acc.repMax[s.reps] = (s.weight, session.date) }
                }
                table[key] = acc
            }
        }
        return table.compactMap { key, acc in
            guard let best = acc.best else { return nil }
            let maxes = acc.repMax.map { ExerciseRecord.RepMax(reps: $0.key, weight: $0.value.0, date: $0.value.1) }
                .sorted { $0.reps < $1.reps }
            return ExerciseRecord(key: key, name: acc.name, bestE1RM: best.e1rm, bestSetWeight: best.weight,
                                  bestSetReps: best.reps, bestDate: best.date, repMaxes: maxes,
                                  sessionCount: acc.sessions.count)
        }
        .sorted { $0.bestE1RM > $1.bestE1RM }
    }

    /// Completed sets and volume per primary muscle over the trailing `days`.
    static func muscleWeek(from sessions: [WorkoutSession], days: Int = 7, now: Date = Date()) -> [MuscleWeek] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        var sets: [String: Int] = [:]
        var volume: [String: Double] = [:]
        for session in sessions where session.date >= start && session.date <= now {
            for exercise in session.exercises {
                let done = exercise.completedSets
                guard !done.isEmpty else { continue }
                for muscle in exercise.musclesForStats {
                    sets[muscle, default: 0] += done.count
                    volume[muscle, default: 0] += done.reduce(0) { $0 + $1.volume }
                }
            }
        }
        return sets.map { MuscleWeek(muscle: $0.key, sets: $0.value, volume: volume[$0.key] ?? 0) }
            .sorted { $0.sets == $1.sets ? $0.muscle < $1.muscle : $0.sets > $1.sets }
    }
}
