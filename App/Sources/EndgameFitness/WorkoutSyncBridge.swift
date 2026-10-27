//
//  WorkoutSyncBridge.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://batesai.org · help@batesai.org
//
//  The seam between the training log (WorkoutTrackerMac_Enhanced.swift owns the
//  local workout store) and the game/account layer (GameProfile.swift owns the
//  upload queue and the network). Wire format: Docs/API_V2.md.
//
//  Upload: the training log builds SyncExercise/SyncSession values and hands
//  them to GameProfileService.recordWorkout; the service serialises them with
//  `wirePayload()` below.
//
//  Download: GameProfileService decodes the `sessions` the server returns from
//  POST fitness/sync into RemoteWorkout values and calls
//  `WorkoutSyncBridge.receivePulled`, which the training log installs at launch
//  to merge them into its local history.
//

import Foundation

/// One exercise's completed sets, uploaded so the server can detect personal
/// records (best weight per rep count) — the client never decides a PR itself.
struct SyncExercise: Codable, Equatable {
    struct Set: Codable, Equatable {
        var reps: Int
        /// Always pounds on the wire, whatever the display unit.
        var weight: Double
        /// Reps in reserve (0–5), when the lifter logged it.
        var rir: Int? = nil
    }
    var name: String
    /// Stable id from the bundled exercise library (free-exercise-db), when known.
    var exerciseID: String? = nil
    /// free-exercise-db category ("strength", "cardio", "stretching", …).
    var category: String? = nil
    /// Primary muscles from the library ("chest", "quadriceps", …).
    var primaryMuscles: [String]? = nil
    var sets: [Set]
}

struct SyncSession: Codable, Identifiable, Equatable {
    var id: String
    var performedAt: Int
    var name: String?
    var programID: String?
    var durationSecs: Int
    var totalVolume: Double
    var totalReps: Int
    var xpEarned: Int?
    var clientRev: Int
    var exercises: [SyncExercise]? = nil
    var notes: String? = nil
    /// A tombstone: the lifter deleted this workout. The server removes it from
    /// history (lifetime totals are adjusted) and tells other devices.
    var deleted: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, exercises, notes, deleted
        case performedAt = "performed_at"
        case programID = "program_id"
        case durationSecs = "duration_secs"
        case totalVolume = "total_volume"
        case totalReps = "total_reps"
        case xpEarned = "xp_earned"
        case clientRev = "client_rev"
    }

    /// The JSON object POST fitness/sync expects for one session (payload v2).
    func wirePayload() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "performed_at": performedAt,
            "duration_secs": durationSecs,
            "total_volume": totalVolume,
            "total_reps": totalReps,
            "client_rev": clientRev,
        ]
        if let name { dict["name"] = name }
        if let programID { dict["program_id"] = programID }
        if deleted == true { dict["deleted"] = true }
        var payload: [String: Any] = ["v": 2]
        if let exercises, !exercises.isEmpty {
            payload["exercises"] = exercises.map { exercise -> [String: Any] in
                var e: [String: Any] = [
                    "name": exercise.name,
                    "sets": exercise.sets.map { set -> [String: Any] in
                        var s: [String: Any] = ["reps": set.reps, "weight": set.weight]
                        if let rir = set.rir { s["rir"] = rir }
                        return s
                    },
                ]
                if let id = exercise.exerciseID { e["exercise_id"] = id }
                if let category = exercise.category { e["category"] = category }
                if let muscles = exercise.primaryMuscles, !muscles.isEmpty { e["primary_muscles"] = muscles }
                return e
            }
        }
        if let notes, !notes.isEmpty { payload["notes"] = notes }
        if payload.count > 1 { dict["payload"] = payload }
        return dict
    }
}

// MARK: - Pulled history (server -> device)

/// A workout as POST fitness/sync returns it in `sessions` (pull direction).
struct RemoteWorkout: Decodable, Identifiable, Equatable {
    struct Payload: Decodable, Equatable {
        var v: Int?
        var exercises: [Exercise]?
        var notes: String?
    }
    struct Exercise: Decodable, Equatable {
        var name: String
        var exerciseID: String?
        var category: String?
        var primaryMuscles: [String]?
        var sets: [Set]

        enum CodingKeys: String, CodingKey {
            case name, sets, category
            case exerciseID = "exercise_id"
            case primaryMuscles = "primary_muscles"
        }
    }
    struct Set: Decodable, Equatable {
        var reps: Int
        var weight: Double
        var rir: Int?
    }

    var id: String
    var performedAt: Int
    var name: String?
    var programID: String?
    var durationSecs: Int?
    var totalVolume: Double?
    var totalReps: Int?
    var xpEarned: Int?
    var clientRev: Int?
    var deleted: Bool?
    var updatedAt: Int?
    var payload: Payload?

    enum CodingKeys: String, CodingKey {
        case id, name, deleted, payload
        case performedAt = "performed_at"
        case programID = "program_id"
        case durationSecs = "duration_secs"
        case totalVolume = "total_volume"
        case totalReps = "total_reps"
        case xpEarned = "xp_earned"
        case clientRev = "client_rev"
        case updatedAt = "updated_at"
    }
}

@MainActor
enum WorkoutSyncBridge {
    /// Installed by the training log at launch. Called with every page of
    /// workouts the server sends back, including tombstones (`deleted == true`).
    /// Must be idempotent: the same workout can arrive more than once.
    static var receivePulled: ([RemoteWorkout]) -> Void = { _ in }

    /// Installed by the training log. Called when the signed-in account changes
    /// (sign-out, or a different member signs in) so per-account local state is
    /// swapped rather than shared. `nil` = signed out.
    static var accountChanged: (_ userID: String?) -> Void = { _ in }
}
