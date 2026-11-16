//
//  WorkoutStore.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://batesai.org · help@batesai.org
//
//  The training log on disk. Rules, in order of importance:
//
//  1. Never lose history. A file that fails to decode is moved aside into
//     `recovery/` (quarantined), never overwritten; the most recent backup is
//     restored if one decodes. If the bad file cannot be moved aside, writes
//     for that account stop until the next launch.
//  2. Writes are atomic: encode to a temp file in the same folder, then
//     replace. The previous file is kept as `workout_sessions.prev.json`, plus
//     one dated copy per day in `backups/` (last 7 days).
//  3. Decoding is tolerant (see TrainingModels.swift). A single unreadable
//     workout is skipped, and a copy of the original file is kept.
//  4. One store per batesai.org account under Application Support, plus a
//     `local` store for signed-out use. The first account that signs in on a
//     device adopts the old un-namespaced store (Documents/WorkoutTracker)
//     once, read-only.
//
//  Layout: Application Support/EndgameFitness/Accounts/<account>/
//      workout_sessions.json, workout_sessions.prev.json, active_workout.json,
//      backups/, recovery/
//

import Foundation
import CryptoKit

final class WorkoutStore {
    static let shared = WorkoutStore()

    struct Snapshot {
        var sessions: [WorkoutSession] = []
        /// Deleted session id -> the revision of the delete. Keeps a pulled copy
        /// of a deleted workout from coming back.
        var tombstones: [String: Int] = [:]
        var activeWorkout: WorkoutSession?
        /// Plain-language problem to show the lifter, if loading hit one.
        var issue: String?
    }

    static let guestKey = "local"
    static let fileVersion = 2

    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private let lastAccountKey = "workoutStore.lastAccountKey"
    private let legacyAdoptedKey = "workoutStore.legacyAdopted.v2"
    private let sessionsName = "workout_sessions.json"
    private let previousName = "workout_sessions.prev.json"
    private let activeName = "active_workout.json"

    /// Accounts whose history file could not be moved aside; never written.
    private var blockedAccounts: Set<String> = []

    let root: URL
    private(set) var accountKey: String

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        root = base.appendingPathComponent("EndgameFitness", isDirectory: true)
        accountKey = defaults.string(forKey: lastAccountKey) ?? Self.guestKey
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Accounts

    /// A folder-safe key for a player id.
    static func accountKey(forUserID userID: String?) -> String {
        guard let userID, !userID.isEmpty else { return guestKey }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if userID.count <= 64, userID.allSatisfy({ allowed.contains($0) }) { return "user-" + userID }
        let digest = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "user-" + String(digest.prefix(40))
    }

    func directory(for key: String) -> URL {
        root.appendingPathComponent("Accounts", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    /// Makes `key` the account that saves go to, and remembers it for the
    /// next launch (so the right history shows before sign-in is confirmed).
    func activate(_ key: String) {
        accountKey = key
        defaults.set(key, forKey: lastAccountKey)
    }

    // MARK: Local players

    /// The training log a first local player should adopt: the last account
    /// used on this device (signed-in member or guest) when it has history.
    func legacyKeyToAdopt() -> String? {
        var candidates: [String] = []
        if let last = defaults.string(forKey: lastAccountKey) { candidates.append(last) }
        candidates.append(Self.guestKey)
        let accounts = root.appendingPathComponent("Accounts", isDirectory: true)
        let others = ((try? fm.contentsOfDirectory(atPath: accounts.path)) ?? []).filter { $0.hasPrefix("user-") }.sorted()
        candidates.append(contentsOf: others)
        return candidates.first { fm.fileExists(atPath: directory(for: $0).appendingPathComponent(sessionsName).path) }
    }

    /// The raw history file for a backup.
    func rawSessionsFile(for key: String) -> Data? {
        try? Data(contentsOf: directory(for: key).appendingPathComponent(sessionsName))
    }

    func writeRawSessionsFile(_ data: Data, for key: String) throws {
        _ = try decodeSessions(data)   // refuse anything this build can't read
        let dir = directory(for: key)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard atomicWrite(data, to: dir.appendingPathComponent(sessionsName)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// A deleted player's log is moved aside (never destroyed outright).
    func removeAccount(_ key: String) {
        let dir = directory(for: key)
        guard fm.fileExists(atPath: dir.path) else { return }
        let aside = root.appendingPathComponent("DeletedPlayers", isDirectory: true)
        try? fm.createDirectory(at: aside, withIntermediateDirectories: true)
        try? fm.moveItem(at: dir, to: aside.appendingPathComponent("\(key)-\(Int(Date().timeIntervalSince1970))"))
    }

    // MARK: Loading

    func load(_ key: String) -> Snapshot {
        let dir = directory(for: key)
        let isNewAccount = !fm.fileExists(atPath: dir.path)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var snapshot = Snapshot()
        var issues: [String] = []

        let sessions = loadSessions(in: dir, key: key)
        snapshot.sessions = sessions.sessions
        snapshot.tombstones = sessions.tombstones
        if let issue = sessions.issue { issues.append(issue) }

        if key != Self.guestKey, isNewAccount, !defaults.bool(forKey: legacyAdoptedKey) {
            let legacy = adoptLegacyStore()
            if !legacy.sessions.isEmpty {
                let known = Set(snapshot.sessions.map(\.id))
                snapshot.sessions.append(contentsOf: legacy.sessions.filter { !known.contains($0.id) })
                snapshot.sessions.sort { $0.date < $1.date }
                writeSessions(snapshot.sessions, tombstones: snapshot.tombstones, key: key)
            }
            if let issue = legacy.issue { issues.append(issue) }
        }

        let active = loadActive(in: dir)
        snapshot.activeWorkout = active.workout
        if let issue = active.issue { issues.append(issue) }

        snapshot.issue = issues.isEmpty ? nil : issues.joined(separator: " ")
        return snapshot
    }

    private struct DecodedSessions {
        var sessions: [WorkoutSession] = []
        var tombstones: [String: Int] = [:]
        var dropped = 0
    }

    private struct SessionsFileOut: Encodable {
        let version: Int
        let savedAt: Date
        let sessions: [WorkoutSession]
        let tombstones: [String: Int]
    }

    private struct SessionsFileIn: Decodable {
        let version: Int?
        let sessions: LossyList<WorkoutSession>
        let tombstones: [String: Int]?
    }

    /// Reads the current envelope or the plain array older builds wrote.
    private func decodeSessions(_ data: Data) throws -> DecodedSessions {
        let decoder = TrainingJSON.decoder()
        if let file = try? decoder.decode(SessionsFileIn.self, from: data) {
            return DecodedSessions(sessions: file.sessions.items, tombstones: file.tombstones ?? [:],
                                   dropped: file.sessions.dropped)
        }
        let list = try decoder.decode(LossyList<WorkoutSession>.self, from: data)
        return DecodedSessions(sessions: list.items, tombstones: [:], dropped: list.dropped)
    }

    private func loadSessions(in dir: URL, key: String) -> (sessions: [WorkoutSession], tombstones: [String: Int], issue: String?) {
        let url = dir.appendingPathComponent(sessionsName)
        guard fm.fileExists(atPath: url.path) else { return ([], [:], nil) }

        if let data = try? Data(contentsOf: url), let decoded = try? decodeSessions(data) {
            var issue: String?
            if decoded.dropped > 0 {
                // Keep the original so the skipped workouts can be recovered.
                _ = copyToRecovery(url, in: dir, label: "partial")
                issue = "\(decoded.dropped) workout\(decoded.dropped == 1 ? "" : "s") in your history could not be read and \(decoded.dropped == 1 ? "was" : "were") left out. A copy of the file was kept; write to help@batesai.org if you need it recovered."
            }
            return (decoded.sessions, decoded.tombstones, issue)
        }

        // Unreadable: set the file aside (never overwrite it), then restore
        // the newest backup that decodes.
        if !moveToRecovery(url, in: dir, label: "corrupt") {
            if !copyToRecovery(url, in: dir, label: "corrupt") { blockedAccounts.insert(key) }
        }
        for candidate in backupCandidates(in: dir) {
            if let data = try? Data(contentsOf: candidate), let decoded = try? decodeSessions(data) {
                if !blockedAccounts.contains(key) {
                    writeSessions(decoded.sessions, tombstones: decoded.tombstones, key: key)
                }
                return (decoded.sessions, decoded.tombstones,
                        "Your workout history file could not be read, so your most recent backup was restored. The unreadable file was kept, not deleted.")
            }
        }
        return ([], [:], "Your workout history file could not be read. It was set aside, not deleted. Write to help@batesai.org and we will help recover it.")
    }

    private func loadActive(in dir: URL) -> (workout: WorkoutSession?, issue: String?) {
        let url = dir.appendingPathComponent(activeName)
        guard fm.fileExists(atPath: url.path) else { return (nil, nil) }
        if let data = try? Data(contentsOf: url),
           let workout = try? TrainingJSON.decoder().decode(WorkoutSession.self, from: data) {
            return (workout, nil)
        }
        if !moveToRecovery(url, in: dir, label: "corrupt-active") { try? fm.removeItem(at: url) }
        return (nil, "The workout you had in progress could not be restored.")
    }

    // MARK: Saving

    func saveSessions(_ sessions: [WorkoutSession], tombstones: [String: Int]) {
        writeSessions(sessions, tombstones: tombstones, key: accountKey)
    }

    private func writeSessions(_ sessions: [WorkoutSession], tombstones: [String: Int], key: String) {
        guard !blockedAccounts.contains(key) else { return }
        let dir = directory(for: key)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(sessionsName)
        let file = SessionsFileOut(version: Self.fileVersion, savedAt: Date(), sessions: sessions, tombstones: tombstones)
        guard let data = try? TrainingJSON.encoder().encode(file) else { return }

        if fm.fileExists(atPath: url.path) {
            dailyBackup(of: url, in: dir)
            let previous = dir.appendingPathComponent(previousName)
            try? fm.removeItem(at: previous)
            try? fm.copyItem(at: url, to: previous)
        }
        atomicWrite(data, to: url)
    }

    func saveActiveWorkout(_ workout: WorkoutSession?) {
        let url = directory(for: accountKey).appendingPathComponent(activeName)
        guard let workout else {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.createDirectory(at: directory(for: accountKey), withIntermediateDirectories: true)
        guard let data = try? TrainingJSON.encoder().encode(workout) else { return }
        atomicWrite(data, to: url)
    }

    /// Temp file in the same folder, then an atomic replace.
    @discardableResult
    private func atomicWrite(_ data: Data, to url: URL) -> Bool {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }

    // MARK: Backups and recovery

    private func dailyBackup(of url: URL, in dir: URL) {
        let backups = dir.appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let day = Self.dayStamp.string(from: Date())
        let target = backups.appendingPathComponent("workout_sessions-\(day).json")
        if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: url, to: target) }
        // Keep the newest seven.
        let files = (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        let dated = files.filter { $0.lastPathComponent.hasPrefix("workout_sessions-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in dated.dropFirst(7) { try? fm.removeItem(at: old) }
    }

    private func backupCandidates(in dir: URL) -> [URL] {
        var urls = [dir.appendingPathComponent(previousName)]
        let backups = dir.appendingPathComponent("backups", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        urls += files.filter { $0.lastPathComponent.hasPrefix("workout_sessions-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    private func recoveryURL(for url: URL, in dir: URL, label: String) -> URL {
        let folder = dir.appendingPathComponent("recovery", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.timeStamp.string(from: Date())
        let base = url.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent("\(base).\(label)-\(stamp)-\(UUID().uuidString.prefix(4)).json")
    }

    private func moveToRecovery(_ url: URL, in dir: URL, label: String) -> Bool {
        (try? fm.moveItem(at: url, to: recoveryURL(for: url, in: dir, label: label))) != nil
    }

    private func copyToRecovery(_ url: URL, in dir: URL, label: String) -> Bool {
        (try? fm.copyItem(at: url, to: recoveryURL(for: url, in: dir, label: label))) != nil
    }

    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: Legacy store (builds before 2026-10-27)

    /// Where older builds kept history. Read-only: these files are never
    /// modified or deleted.
    private func legacyCandidates() -> [URL] {
        var urls: [URL] = []
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            // Sandboxed builds: the app container. The unsandboxed local Mac
            // build: ~/Documents.
            urls.append(documents.appendingPathComponent("WorkoutTracker/workout_sessions.json"))
        }
        #if os(macOS)
        if !Platform.isSandboxed {
            let home = fm.homeDirectoryForCurrentUser
            urls.append(home.appendingPathComponent("Documents/workout_tracker/workout_sessions.json"))
        }
        #endif
        return urls
    }

    private func adoptLegacyStore() -> (sessions: [WorkoutSession], issue: String?) {
        var sessions: [WorkoutSession] = []
        var unreadable = false
        for url in legacyCandidates() where fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let decoded = try? decodeSessions(data) else {
                unreadable = true
                continue
            }
            let known = Set(sessions.map(\.id))
            sessions.append(contentsOf: decoded.sessions.filter { !known.contains($0.id) })
        }
        // Try again next launch if an old file exists but could not be read.
        if !unreadable { defaults.set(true, forKey: legacyAdoptedKey) }
        return (sessions, unreadable ? "Some workouts saved by an older version could not be read. The old file was left untouched." : nil)
    }

    // MARK: Programs (device-wide placeholders)

    private var programsURL: URL { root.appendingPathComponent("workout_programs.json") }

    func loadPrograms() -> [WorkoutProgram] {
        guard let data = try? Data(contentsOf: programsURL),
              let list = try? JSONDecoder().decode(LossyList<WorkoutProgram>.self, from: data)
        else { return [] }
        return list.items
    }

    func savePrograms(_ programs: [WorkoutProgram]) {
        guard let data = try? JSONEncoder().encode(programs) else { return }
        atomicWrite(data, to: programsURL)
    }

    // MARK: Export / import

    struct ExportFile: Codable {
        var app = "Endgame Fitness"
        var version = WorkoutStore.fileVersion
        var exportedAt = Date()
        var sessions: [WorkoutSession]
    }

    static func exportData(_ sessions: [WorkoutSession]) -> Data? {
        let encoder = TrainingJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(ExportFile(sessions: sessions))
    }

    /// Reads this app's export (any version) or a plain array of sessions.
    static func importSessions(from data: Data) -> [WorkoutSession]? {
        struct ExportIn: Decodable { let sessions: LossyList<WorkoutSession> }
        let decoder = TrainingJSON.decoder()
        if let file = try? decoder.decode(ExportIn.self, from: data) { return file.sessions.items }
        return (try? decoder.decode(LossyList<WorkoutSession>.self, from: data))?.items
    }
}
