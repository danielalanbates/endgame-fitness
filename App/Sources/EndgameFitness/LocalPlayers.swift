//
//  LocalPlayers.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  Local players: everyone who trains on this device gets a profile (name,
//  avatar symbol and colour, optional PIN). No account, no network. The
//  players on one device form the "household": they see each other's feed,
//  can duel, and can found a household guild to fight the weekly raid boss.
//
//  Each player's training log lives in WorkoutStore under `storeKey`; their
//  game progress lives in LocalGameStore under their id.
//

import Foundation
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

enum AppInfo {
    static let helpURL = URL(string: "https://github.com/danielalanbates/endgame-fitness/issues")!
}

struct LocalPlayer: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var symbol: String
    var colorIndex: Int
    /// SHA-256 of "<id>:<pin>". A household convenience lock, not security.
    var pinHash: String?
    var createdAt: Int
    /// The WorkoutStore account folder holding this player's training log.
    var storeKey: String

    var hasPIN: Bool { pinHash != nil }

    static let symbols = [
        "figure.strengthtraining.traditional", "figure.run", "figure.yoga", "figure.cross.training",
        "dumbbell.fill", "flame.fill", "bolt.fill", "star.fill", "heart.fill", "leaf.fill",
        "crown.fill", "shield.fill", "hare.fill", "tortoise.fill", "pawprint.fill", "sun.max.fill",
    ]
    static let colors: [Color] = [.brandPurple, .brandOrange, .brandGreen, .brandBlue, .brandYellow, .pink, .teal, .red]

    var color: Color { Self.colors[((colorIndex % Self.colors.count) + Self.colors.count) % Self.colors.count] }

    static func hashPIN(_ pin: String, id: String) -> String {
        SHA256.hash(data: Data("\(id):\(pin)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func checkPIN(_ pin: String) -> Bool { pinHash == nil || pinHash == Self.hashPIN(pin, id: id) }
}

@MainActor
final class LocalPlayerStore: ObservableObject {
    static let shared = LocalPlayerStore()

    @Published private(set) var players: [LocalPlayer] = []
    @Published private(set) var currentID: String?

    private let defaults = UserDefaults.standard
    private let currentKey = "ef.localPlayer.current"
    let file: URL

    var current: LocalPlayer? { players.first { $0.id == currentID } }

    private init() {
        file = LocalGameStore.defaultRoot.appendingPathComponent("players.json")
        load()
        if let saved = defaults.string(forKey: currentKey), players.contains(where: { $0.id == saved }) {
            currentID = saved
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([LocalPlayer].self, from: data) else { return }
        players = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(players) { try? data.write(to: file, options: .atomic) }
    }

    /// Creates a player. The first player on a device that already has a
    /// training log (from a pre-local-players build) adopts that log.
    @discardableResult
    func create(name: String, symbol: String, colorIndex: Int, pin: String?) -> LocalPlayer {
        let id = UUID().uuidString.lowercased()
        var storeKey = WorkoutStore.accountKey(forUserID: id)
        if players.isEmpty, let legacy = WorkoutStore.shared.legacyKeyToAdopt() { storeKey = legacy }
        var player = LocalPlayer(id: id, name: Self.clean(name), symbol: symbol, colorIndex: colorIndex,
                                 pinHash: nil, createdAt: Int(Date().timeIntervalSince1970), storeKey: storeKey)
        if let pin, !pin.isEmpty { player.pinHash = LocalPlayer.hashPIN(pin, id: id) }
        players.append(player)
        save()
        GameProfileService.shared.engine.playerJoined(id)
        return player
    }

    func update(_ player: LocalPlayer) {
        guard let i = players.firstIndex(where: { $0.id == player.id }) else { return }
        var p = player
        p.name = Self.clean(p.name)
        players[i] = p
        save()
        if p.id == currentID { GameProfileService.shared.refreshAll() }
    }

    func rename(_ id: String, to name: String) {
        guard var p = players.first(where: { $0.id == id }) else { return }
        p.name = name
        update(p)
    }

    func setPIN(_ id: String, pin: String?) {
        guard var p = players.first(where: { $0.id == id }) else { return }
        p.pinHash = (pin?.isEmpty ?? true) ? nil : LocalPlayer.hashPIN(pin!, id: id)
        update(p)
    }

    /// Deletes a player, their game progress and their training log.
    func delete(_ id: String) {
        guard let p = players.first(where: { $0.id == id }) else { return }
        if currentID == id { select(nil) }
        players.removeAll { $0.id == id }
        save()
        GameProfileService.shared.engine.playerRemoved(id)
        WorkoutStore.shared.removeAccount(p.storeKey)
    }

    func select(_ id: String?) {
        currentID = id
        if let id { defaults.set(id, forKey: currentKey) } else { defaults.removeObject(forKey: currentKey) }
    }

    static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player" : String(trimmed.prefix(24))
    }

    // MARK: Backup

    struct Backup: Codable {
        var format = "endgame-fitness-player"
        var version = 1
        var exportedAt: Int
        var player: LocalPlayer
        var game: PlayerGameState
        /// Raw training-log file (workout_sessions.json) for this player.
        var workouts: Data?
    }

    func exportBackup(_ id: String) throws -> Data {
        guard let p = players.first(where: { $0.id == id }) else { throw LocalGameError.message("Player not found.") }
        if id == currentID { WorkoutManager.shared.saveSessionsNow() }
        let backup = Backup(exportedAt: Int(Date().timeIntervalSince1970), player: p,
                            game: GameProfileService.shared.engine.store.state(id),
                            workouts: WorkoutStore.shared.rawSessionsFile(for: p.storeKey))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    /// Imports a backup as a new player (a fresh id, so it never overwrites
    /// anyone). Returns the new player.
    @discardableResult
    func importBackup(_ data: Data) throws -> LocalPlayer {
        let backup: Backup
        do { backup = try JSONDecoder().decode(Backup.self, from: data) } catch {
            throw LocalGameError.message("That file isn't an Endgame Fitness player backup.")
        }
        guard backup.format == "endgame-fitness-player" else {
            throw LocalGameError.message("That file isn't an Endgame Fitness player backup.")
        }
        let id = UUID().uuidString.lowercased()
        var player = backup.player
        let taken = Set(players.map(\.name))
        player.id = id
        player.storeKey = WorkoutStore.accountKey(forUserID: id)
        player.pinHash = nil
        if taken.contains(player.name) { player.name = String("\(player.name) (restored)".prefix(24)) }
        player.createdAt = Int(Date().timeIntervalSince1970)
        let game = Self.rekeyed(backup.game, from: backup.player.id, to: id)
        GameProfileService.shared.engine.store.save(game, for: id)
        if let workouts = backup.workouts { try WorkoutStore.shared.writeRawSessionsFile(workouts, for: player.storeKey) }
        players.append(player)
        save()
        // Same household bookkeeping as a newly created player.
        GameProfileService.shared.engine.playerJoined(id)
        return player
    }

    /// Quest ids embed the player id; re-key them so the board keeps its progress.
    nonisolated static func rekeyed(_ game: PlayerGameState, from oldID: String, to id: String) -> PlayerGameState {
        var game = game
        game.quests = Dictionary(uniqueKeysWithValues: game.quests.map { key, q in
            var q = q
            q.id = q.id.replacingOccurrences(of: oldID, with: id)
            return (key.replacingOccurrences(of: oldID, with: id), q)
        })
        return game
    }
}

/// A player backup file for fileExporter.
struct PlayerBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
