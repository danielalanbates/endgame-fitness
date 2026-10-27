//
//  TrainingSync.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://batesai.org · help@batesai.org
//
//  The training log's side of sync (wire format: Docs/API_V2.md §3):
//    • upload: a finished, edited or deleted session becomes a SyncSession
//      and goes to the queue GameProfileService owns
//    • download: pulled sessions merge into local history by id — tombstones
//      delete, a higher clientRev wins, the same revision is a no-op
//    • accounts: each batesai.org member gets their own local store
//
//  Only completed sets are uploaded. Timed sets (planks, cardio) have no reps
//  field on the wire and stay on the device; the session's duration still
//  counts.
//

import Foundation
import Combine

extension WorkoutManager {
    // MARK: Upload

    /// The wire form of a session. Weights are pounds, rounded to 0.1.
    func syncPayload(for session: WorkoutSession, deleted: Bool = false) -> SyncSession {
        let exercises: [SyncExercise] = session.exercises.compactMap { exercise in
            let sets = exercise.completedSets.filter { $0.reps >= 1 }
            guard !sets.isEmpty else { return nil }
            let library = exercise.exerciseID.flatMap { ExerciseLibrary.shared.entry(id: $0) }
            return SyncExercise(
                name: ProgramTargetParser.parse(exercise.name).name,
                exerciseID: exercise.exerciseID,
                category: exercise.category ?? library?.category,
                primaryMuscles: exercise.primaryMuscles ?? library?.primary,
                sets: sets.map { .init(reps: $0.reps, weight: ($0.weight * 10).rounded() / 10, rir: $0.rir) }
            )
        }
        let volume = exercises.reduce(0.0) { total, e in total + e.sets.reduce(0) { $0 + Double($1.reps) * $1.weight } }
        let reps = exercises.reduce(0) { total, e in total + e.sets.reduce(0) { $0 + $1.reps } }
        return SyncSession(
            id: session.syncID,
            performedAt: Int(session.date.timeIntervalSince1970),
            name: session.displayName,
            programID: nil,
            durationSecs: Int(session.duration ?? 0),
            totalVolume: volume,
            totalReps: reps,
            xpEarned: nil,
            clientRev: max(session.clientRev, 1),
            exercises: exercises.isEmpty ? nil : exercises,
            notes: session.notes,
            deleted: deleted ? true : nil
        )
    }

    /// Queues a new or edited session for upload.
    func uploadSession(_ session: WorkoutSession) {
        let payload = syncPayload(for: session)
        let performedAt = session.date
        Task { @MainActor in
            if let enqueue = WorkoutSyncBridge.enqueue {
                enqueue(payload)
            } else {
                GameProfileService.shared.recordWorkout(
                    id: payload.id,
                    name: payload.name,
                    performedAt: performedAt,
                    durationSecs: payload.durationSecs,
                    totalVolume: payload.totalVolume,
                    totalReps: payload.totalReps,
                    exercises: payload.exercises
                )
            }
        }
    }

    /// Queues a tombstone. Without the enqueue hook the delete stays local.
    func uploadDeletion(of session: WorkoutSession) {
        let payload = syncPayload(for: session, deleted: true)
        Task { @MainActor in
            WorkoutSyncBridge.enqueue?(payload)
        }
    }

    // MARK: Hooks

    /// Installs the bridge callbacks. Called once from the App initialiser,
    /// before RootView's first sync.
    @MainActor
    func installSyncHooks() {
        guard authObserver == nil else { return }
        WorkoutSyncBridge.receivePulled = { remotes in
            WorkoutManager.shared.mergePulled(remotes)
        }
        WorkoutSyncBridge.accountChanged = { userID in
            WorkoutManager.shared.switchAccount(to: userID)
        }
        // Also follow the auth state directly, so the right store is active
        // before the first pull even if nothing calls accountChanged. A nil
        // user while the stored session is still being checked (or offline)
        // keeps the last account's store.
        authObserver = BatesAIAuth.shared.$user
            .map { $0?.id }
            .removeDuplicates()
            .sink { userID in
                if let userID {
                    WorkoutManager.shared.switchAccount(to: userID)
                } else if !BatesAIAuth.shared.isRestoring {
                    WorkoutManager.shared.switchAccount(to: nil)
                }
            }
    }

    // MARK: Accounts

    /// Saves the current account's log, then loads `userID`'s (nil = the
    /// signed-out local store). Idempotent.
    func switchAccount(to userID: String?) {
        let key = WorkoutStore.accountKey(forUserID: userID)
        guard key != WorkoutStore.shared.accountKey else { return }
        flushActiveWorkout()
        saveSessionsNow()
        WorkoutStore.shared.activate(key)
        applySnapshot(WorkoutStore.shared.load(key))
    }

    // MARK: Download

    /// Merges a page of pulled workouts. Safe to call repeatedly with the same
    /// data: the same revision changes nothing.
    func mergePulled(_ remotes: [RemoteWorkout]) {
        guard !remotes.isEmpty else { return }
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
                if let i = localIndex, list[i].clientRev <= rev {
                    removed.insert(i)
                    changed = true
                }
                if (dead[key] ?? 0) < rev { dead[key] = rev; changed = true }
                continue
            }
            if let deletedRev = dead[key], deletedRev >= rev { continue }

            if let i = localIndex {
                guard rev > list[i].clientRev else { continue }
                list[i] = Self.session(from: remote, localID: list[i].id)
                changed = true
            } else {
                list.append(Self.session(from: remote, localID: nil))
                indexByID[key] = list.count - 1
                changed = true
            }
        }
        guard changed else { return }
        sessions = list.enumerated().filter { !removed.contains($0.offset) }.map(\.element).sorted { $0.date < $1.date }
        tombstones = dead
        saveSessionsNow()
    }

    /// A pulled workout as a local session. Every pulled set is a completed set.
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
