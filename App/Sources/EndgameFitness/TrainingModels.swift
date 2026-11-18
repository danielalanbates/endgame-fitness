//
//  TrainingModels.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  The training log's data model: a session holds exercises, an exercise holds
//  sets. Weights are always stored in POUNDS; the display unit is a setting
//  (see TrainingUnits.swift).
//
//  Every type decodes tolerantly (decodeIfPresent with a default for each
//  field) so a field added later — RIR, a library id, a sync revision — never
//  makes an older history file unreadable. Losing a lifter's history because a
//  new optional field was missing is the one bug this file exists to prevent.
//

import Foundation

// MARK: - Set tracking

/// What a set records. Decided by the exercise (library category/equipment,
/// else the name), not by the lifter.
enum SetTracking: String, Codable, CaseIterable {
    /// Load × reps: barbell, dumbbell, cable, machine, kettlebell.
    case weighted
    /// Reps with optional added load: push-ups, pull-ups, dips.
    case bodyweight
    /// A duration: cardio, stretching, holds such as a plank.
    case timed
}

// MARK: - Set

struct ExerciseSet: Codable, Identifiable, Equatable {
    let id: UUID
    var reps: Int
    /// Pounds. For bodyweight movements this is ADDED load (0 = bodyweight only).
    var weight: Double
    /// Only completed sets count anywhere: volume, PRs, sync, charts, streaks.
    var completed: Bool
    var restTime: TimeInterval?
    /// Reps in reserve (0–5), when the lifter logged it.
    var rir: Int?
    /// Seconds, for timed sets.
    var durationSecs: Int?
    var completedAt: Date?

    init(id: UUID = UUID(), reps: Int = 0, weight: Double = 0, completed: Bool = false,
         restTime: TimeInterval? = nil, rir: Int? = nil, durationSecs: Int? = nil, completedAt: Date? = nil) {
        self.id = id
        self.reps = reps
        self.weight = weight
        self.completed = completed
        self.restTime = restTime
        self.rir = rir
        self.durationSecs = durationSecs
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, reps, weight, completed, restTime, rir, durationSecs, completedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        reps = (try? c.decodeIfPresent(Int.self, forKey: .reps)) ?? 0
        weight = (try? c.decodeIfPresent(Double.self, forKey: .weight)) ?? 0
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? false
        restTime = try? c.decodeIfPresent(TimeInterval.self, forKey: .restTime)
        rir = try? c.decodeIfPresent(Int.self, forKey: .rir)
        durationSecs = try? c.decodeIfPresent(Int.self, forKey: .durationSecs)
        completedAt = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
    }

    /// Reps × load for a completed set; 0 otherwise.
    var volume: Double { completed ? Double(max(reps, 0)) * max(weight, 0) : 0 }

    /// True when the set carries enough to be ticked off.
    func isLoggable(as tracking: SetTracking) -> Bool {
        switch tracking {
        case .timed: return (durationSecs ?? 0) > 0
        // A load of 0 is allowed (an empty bar, a band): the reps are what
        // make a set real.
        case .bodyweight, .weighted: return reps > 0
        }
    }
}

// MARK: - Exercise

struct Exercise: Codable, Identifiable, Equatable {
    let id: UUID
    /// What the lifter sees. Kept as typed (or as the program named it).
    var name: String
    var sets: [ExerciseSet]
    var muscleGroup: String?
    var notes: String?
    /// Stable id from the bundled library (free-exercise-db), when known.
    var exerciseID: String?
    /// Library category: strength, cardio, stretching, plyometrics, …
    var category: String?
    var primaryMuscles: [String]?
    var tracking: SetTracking?
    /// Program prescription, when the session came from a program day.
    var targetSets: Int?
    var targetRepMin: Int?
    var targetRepMax: Int?
    var targetSeconds: Int?
    /// Pounds, when the program prescribes a load.
    var targetLoadLb: Double?

    init(id: UUID = UUID(), name: String, sets: [ExerciseSet] = [], muscleGroup: String? = nil,
         notes: String? = nil, exerciseID: String? = nil, category: String? = nil,
         primaryMuscles: [String]? = nil, tracking: SetTracking? = nil,
         targetSets: Int? = nil, targetRepMin: Int? = nil, targetRepMax: Int? = nil, targetSeconds: Int? = nil,
         targetLoadLb: Double? = nil) {
        self.id = id
        self.name = name
        self.sets = sets
        self.muscleGroup = muscleGroup
        self.notes = notes
        self.exerciseID = exerciseID
        self.category = category
        self.primaryMuscles = primaryMuscles
        self.tracking = tracking
        self.targetSets = targetSets
        self.targetRepMin = targetRepMin
        self.targetRepMax = targetRepMax
        self.targetSeconds = targetSeconds
        self.targetLoadLb = targetLoadLb
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sets, muscleGroup, notes, exerciseID, category, primaryMuscles, tracking
        case targetSets, targetRepMin, targetRepMax, targetSeconds, targetLoadLb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Exercise"
        sets = (try? c.decodeIfPresent(LossyList<ExerciseSet>.self, forKey: .sets))?.items ?? []
        muscleGroup = try? c.decodeIfPresent(String.self, forKey: .muscleGroup)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        exerciseID = try? c.decodeIfPresent(String.self, forKey: .exerciseID)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        primaryMuscles = try? c.decodeIfPresent([String].self, forKey: .primaryMuscles)
        // An unknown raw value from a newer build falls back to inference.
        let rawTracking: String? = try? c.decodeIfPresent(String.self, forKey: .tracking)
        tracking = rawTracking.flatMap(SetTracking.init(rawValue:))
        targetSets = try? c.decodeIfPresent(Int.self, forKey: .targetSets)
        targetRepMin = try? c.decodeIfPresent(Int.self, forKey: .targetRepMin)
        targetRepMax = try? c.decodeIfPresent(Int.self, forKey: .targetRepMax)
        targetSeconds = try? c.decodeIfPresent(Int.self, forKey: .targetSeconds)
        targetLoadLb = try? c.decodeIfPresent(Double.self, forKey: .targetLoadLb)
    }

    var completedSets: [ExerciseSet] { sets.filter(\.completed) }

    /// Completed sets only. Planned (unticked) rows never count.
    var totalVolume: Double { sets.reduce(0) { $0 + $1.volume } }

    /// How sets are entered for this exercise.
    var resolvedTracking: SetTracking {
        tracking ?? ExerciseLibrary.shared.tracking(forID: exerciseID, name: name)
    }

    /// The key history, PRs and progression group by: the library id when
    /// known, otherwise the cleaned, lower-cased name.
    var identityKey: String { ExerciseIdentity.key(exerciseID: exerciseID, name: name) }

    /// Muscles for charts: library muscles, else the old free-text group.
    var musclesForStats: [String] {
        if let primaryMuscles, !primaryMuscles.isEmpty { return primaryMuscles }
        if let id = exerciseID, let entry = ExerciseLibrary.shared.entry(id: id) { return entry.primary }
        if let group = muscleGroup, !group.isEmpty { return [group.lowercased()] }
        return []
    }
}

// MARK: - Session

struct WorkoutSession: Codable, Identifiable, Equatable {
    let id: UUID
    var date: Date
    var programName: String?
    var exercises: [Exercise]
    var notes: String?
    var duration: TimeInterval?
    var completed: Bool
    /// Revision for sync: 1 when first recorded, +1 on every edit. The server
    /// ignores a replay with the same or a lower revision.
    var clientRev: Int
    var updatedAt: Date?
    /// The server's id when it is not one of our UUIDs (sessions logged on the
    /// web app). Uploads use it so an edit never creates a duplicate.
    var remoteID: String?
    /// Totals reported by the server for summary-only (v1) sessions that came
    /// down without per-set detail.
    var syncedTotalVolume: Double?
    var syncedTotalReps: Int?
    var xpEarned: Int?

    init(id: UUID = UUID(), date: Date = Date(), programName: String? = nil, exercises: [Exercise] = [],
         notes: String? = nil, duration: TimeInterval? = nil, completed: Bool = false,
         clientRev: Int = 0, updatedAt: Date? = nil, remoteID: String? = nil,
         syncedTotalVolume: Double? = nil, syncedTotalReps: Int? = nil, xpEarned: Int? = nil) {
        self.id = id
        self.date = date
        self.programName = programName
        self.exercises = exercises
        self.notes = notes
        self.duration = duration
        self.completed = completed
        self.clientRev = clientRev
        self.updatedAt = updatedAt
        self.remoteID = remoteID
        self.syncedTotalVolume = syncedTotalVolume
        self.syncedTotalReps = syncedTotalReps
        self.xpEarned = xpEarned
    }

    enum CodingKeys: String, CodingKey {
        case id, date, programName, exercises, notes, duration, completed
        case clientRev, updatedAt, remoteID, syncedTotalVolume, syncedTotalReps, xpEarned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A session without an id or a date is not recoverable as history;
        // let it fail so the lossy list can skip it (and the file is kept).
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        programName = try? c.decodeIfPresent(String.self, forKey: .programName)
        exercises = (try? c.decodeIfPresent(LossyList<Exercise>.self, forKey: .exercises))?.items ?? []
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        duration = try? c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? true
        clientRev = (try? c.decodeIfPresent(Int.self, forKey: .clientRev)) ?? 0
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        remoteID = try? c.decodeIfPresent(String.self, forKey: .remoteID)
        syncedTotalVolume = try? c.decodeIfPresent(Double.self, forKey: .syncedTotalVolume)
        syncedTotalReps = try? c.decodeIfPresent(Int.self, forKey: .syncedTotalReps)
        xpEarned = try? c.decodeIfPresent(Int.self, forKey: .xpEarned)
    }

    /// The id the server knows this session by.
    var syncID: String { remoteID ?? id.uuidString }

    var completedSets: [ExerciseSet] { exercises.flatMap(\.completedSets) }
    var completedSetCount: Int { exercises.reduce(0) { $0 + $1.completedSets.count } }

    /// Completed sets only (lb). Falls back to the server's total for sessions
    /// that arrived without per-set detail.
    var totalVolume: Double {
        let local = exercises.reduce(0) { $0 + $1.totalVolume }
        if local == 0, completedSetCount == 0, let synced = syncedTotalVolume { return synced }
        return local
    }

    var totalReps: Int {
        let local = completedSets.reduce(0) { $0 + max($1.reps, 0) }
        if local == 0, completedSetCount == 0, let synced = syncedTotalReps { return synced }
        return local
    }

    /// True when the session holds real, completed work. Empty sessions saved
    /// by older builds stay in the file but are ignored by stats and streaks.
    var hasCompletedWork: Bool {
        completedSetCount > 0 || (syncedTotalReps ?? 0) > 0 || (syncedTotalVolume ?? 0) > 0
    }

    /// A rest-day recovery session (started from the rest-day plan): logged
    /// like any session, but not a training day for adherence or the weekly goal.
    var isRecoverySession: Bool { programName == RestDayPlan.recoveryTitle }

    var displayName: String {
        if let programName, !programName.isEmpty { return programName }
        return "Workout"
    }
}

// MARK: - Identity

enum ExerciseIdentity {
    /// Name -> key, so history scans don't re-parse the same names. Main
    /// thread only, like the rest of the training log.
    private static var cache: [String: String] = [:]

    /// Library id when known, otherwise a normalised name, so "Squats",
    /// "squat" and "Squats 5x5" group together.
    static func key(exerciseID: String?, name: String) -> String {
        if let exerciseID, !exerciseID.isEmpty { return exerciseID }
        if let cached = cache[name] { return cached }
        let key: String
        if let match = ExerciseLibrary.shared.match(name: name) {
            key = match.id
        } else {
            key = "name:" + ExerciseLibrary.normalize(ProgramTargetParser.parse(name).name)
        }
        cache[name] = key
        return key
    }
}

// MARK: - Lossy decoding

/// Decodes an array element by element, skipping the ones that fail instead of
/// failing the whole array. `dropped` reports how many were skipped.
struct LossyList<Element: Decodable>: Decodable {
    var items: [Element]
    var dropped: Int

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else {
                // A failed decode does not advance the container; consume the
                // element so the loop moves on.
                _ = try? container.decode(Skip.self)
                dropped += 1
            }
        }
        self.items = items
        self.dropped = dropped
    }
}

// MARK: - Dates

enum TrainingJSON {
    /// Store and export format: ISO 8601 dates.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Reads ISO 8601 strings (with or without fractional seconds) and the
    /// numeric reference-date format older exports used.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            if let seconds = try? c.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try c.decode(String.self)
            if let date = isoPlain.date(from: text) ?? isoFractional.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unreadable date \(text)")
        }
        return decoder
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
