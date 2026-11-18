//
//  HistoryMerge.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Merging pulled workouts into local history, as plain functions so the rules
//  are easy to read and to test:
//    • match by id (case-insensitive; a web-app id that is not a UUID is kept
//      in `remoteID`)
//    • a tombstone deletes the local copy unless the local copy is newer, and
//      is remembered so the workout never comes back
//    • a higher clientRev replaces the local copy; the same or a lower one is
//      ignored, so replays are harmless. A local session with no revision
//      (saved by a build before revisions existed) counts as revision 1: it
//      is the copy that was uploaded, and it may hold sets older builds never
//      sent (bodyweight sets with no load), so its own upload must not
//      overwrite it
//    • every pulled set is a completed set
//

import Foundation

enum HistoryMerge {
    struct Result {
        var sessions: [WorkoutSession]
        var tombstones: [String: Int]
        var changed: Bool
    }

    static func merge(_ remotes: [RemoteWorkout], into sessions: [WorkoutSession],
                      tombstones: [String: Int]) -> Result {
        var list = sessions
        var dead = tombstones
        var indexByID: [String: Int] = [:]
        for (i, s) in list.enumerated() {
            indexByID[s.syncID.lowercased()] = i
            indexByID[s.id.uuidString.lowercased()] = i
        }
        var changed = false
        var removed: Set<Int> = []

        for remote in remotes {
            let key = remote.id.lowercased()
            let rev = max(remote.clientRev ?? 1, 1)
            let localIndex = indexByID[key].flatMap { removed.contains($0) ? nil : $0 }

            if remote.deleted == true {
                if let i = localIndex, max(list[i].clientRev, 1) <= rev {
                    removed.insert(i)
                    changed = true
                }
                if (dead[key] ?? 0) < rev { dead[key] = rev; changed = true }
                continue
            }
            if let deletedRev = dead[key], deletedRev >= rev { continue }

            if let i = localIndex {
                guard rev > max(list[i].clientRev, 1) else { continue }
                list[i] = session(from: remote, localID: list[i].id)
                changed = true
            } else {
                list.append(session(from: remote, localID: nil))
                indexByID[key] = list.count - 1
                changed = true
            }
        }
        let kept = list.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        return Result(sessions: kept.sorted { $0.date < $1.date }, tombstones: dead, changed: changed)
    }

    /// A pulled workout as a local session.
    static func session(from remote: RemoteWorkout, localID: UUID?) -> WorkoutSession {
        let uuid = UUID(uuidString: remote.id)
        let exercises: [Exercise] = (remote.payload?.exercises ?? []).map { e in
            var exercise = Exercise(
                name: e.name,
                sets: e.sets.map { ExerciseSet(reps: $0.reps, weight: $0.weight, completed: true, rir: $0.rir) },
                exerciseID: e.exerciseID,
                category: e.category,
                primaryMuscles: e.primaryMuscles
            )
            attachLibraryMatch(&exercise)
            return exercise
        }
        let hasDetail = !exercises.isEmpty
        return WorkoutSession(
            id: localID ?? uuid ?? UUID(),
            date: Date(timeIntervalSince1970: TimeInterval(remote.performedAt)),
            programName: remote.name,
            exercises: exercises,
            notes: remote.payload?.notes,
            duration: remote.durationSecs.map(TimeInterval.init),
            completed: true,
            clientRev: max(remote.clientRev ?? 1, 1),
            updatedAt: remote.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            remoteID: uuid == nil ? remote.id : nil,
            syncedTotalVolume: hasDetail ? nil : remote.totalVolume,
            syncedTotalReps: hasDetail ? nil : remote.totalReps,
            xpEarned: remote.xpEarned
        )
    }

    /// Fills the library id, category and muscles for a free-text name when the
    /// library has an unambiguous match. The lifter's name is kept, minus any
    /// "4x10" scheme suffix older programs left in it.
    static func attachLibraryMatch(_ exercise: inout Exercise) {
        let cleaned = ProgramTargetParser.parse(exercise.name).name
        if !cleaned.isEmpty, cleaned != exercise.name { exercise.name = cleaned }
        guard exercise.exerciseID == nil, let entry = ExerciseLibrary.shared.match(name: exercise.name) else { return }
        exercise.exerciseID = entry.id
        if exercise.category == nil { exercise.category = entry.category }
        if exercise.primaryMuscles?.isEmpty ?? true { exercise.primaryMuscles = entry.primary }
    }
}
