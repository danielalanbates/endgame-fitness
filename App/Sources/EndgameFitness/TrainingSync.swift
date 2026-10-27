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

    /// Merges a page of pulled workouts (rules: HistoryMerge.swift). Safe to
    /// call repeatedly with the same data: the same revision changes nothing.
    func mergePulled(_ remotes: [RemoteWorkout]) {
        guard !remotes.isEmpty else { return }
        let result = HistoryMerge.merge(remotes, into: sessions, tombstones: tombstones)
        guard result.changed else { return }
        sessions = result.sessions
        tombstones = result.tombstones
        saveSessionsNow()
    }

    static func attachLibraryMatch(_ exercise: inout Exercise) {
        HistoryMerge.attachLibraryMatch(&exercise)
    }
}
