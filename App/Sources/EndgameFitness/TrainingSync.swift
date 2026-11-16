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
//    • players: each local player gets their own store (LocalPlayers.swift)
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
        WorkoutSyncBridge.enqueue = { session in
            GameProfileService.shared.enqueue(session)
        }
        WorkoutSyncBridge.receivePulled = { remotes in
            WorkoutManager.shared.mergePulled(remotes)
        }
        WorkoutSyncBridge.accountChanged = { userID in
            WorkoutManager.shared.switchAccount(to: userID)
        }
        // Follow the local player: their training log becomes the active store,
        // then the game loads their progress (seeded once from that log).
        authObserver = LocalPlayerStore.shared.$currentID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { id in
                MainActor.assumeIsolated {
                    let manager = WorkoutManager.shared
                    let store = LocalPlayerStore.shared
                    // No player (the picker is showing): leave the store alone so
                    // the first player can adopt the existing history.
                    if let key = id.flatMap({ pid in store.players.first { $0.id == pid }?.storeKey }) {
                        manager.switchStore(to: key)
                    }
                    let game = GameProfileService.shared
                    game.activate()
                    if id != nil {
                        game.seedFromHistory(manager.sessions.map { manager.syncPayload(for: $0) })
                    }
                }
            }
    }

    // MARK: Accounts

    /// Saves the current account's log, then loads `userID`'s (nil = the
    /// guest store). Idempotent.
    func switchAccount(to userID: String?) {
        switchStore(to: WorkoutStore.accountKey(forUserID: userID))
    }

    /// Saves the current log, then loads the one in folder `key`. Idempotent.
    func switchStore(to key: String) {
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
