//
//  GameCenterService.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  Optional Game Center for local players. Game Center signs in ONE Apple
//  account per device, so "per player" means: each local player chooses
//  whether their progress is posted to that account. Only an opted-in player's
//  scores and achievements are submitted. Everything degrades to a no-op when
//  Game Center is unavailable or not signed in.
//
//  The leaderboard and achievement ids below must exist in App Store Connect
//  (Docs/SOCIAL_DESIGN.md lists them); until they do, submits fail quietly.
//

import Foundation
import SwiftUI
import GameKit

struct GCBoardEntry: Identifiable, Equatable {
    var id: String
    var rank: Int
    var name: String
    var score: String
    var isMe: Bool
}

struct GCDuel: Identifiable, Equatable {
    var id: String
    var opponent: String
    var myVolume: Double?
    var theirVolume: Double?
    var myTurn: Bool
    var finished: Bool
    var outcome: String?
}

@MainActor
final class GameCenterService: ObservableObject {
    static let shared = GameCenterService()

    struct Board: Identifiable { let id: String; let title: String; let unit: String }

    static let boards: [Board] = [
        Board(id: "egf.weekly_volume", title: "Weekly volume", unit: "lb"),
        Board(id: "egf.level", title: "Level", unit: ""),
        Board(id: "egf.streak", title: "Streak", unit: "days"),
        Board(id: "egf.raid_damage", title: "Raid damage", unit: ""),
    ]
    static let achievementPrefix = "egf.ach."

    @Published private(set) var isAuthenticated = false
    @Published private(set) var gcName: String?
    @Published private(set) var friends: [String] = []
    @Published private(set) var entries: [String: [GCBoardEntry]] = [:]
    @Published private(set) var duels: [GCDuel] = []
    @Published private(set) var status: String?
    @Published private(set) var isWorking = false

    private var handlerInstalled = false
    private static let enabledKey = "gc.enabledPlayers"

    // MARK: Opt-in per local player

    var isEnabledForCurrent: Bool {
        guard let id = LocalPlayerStore.shared.currentID else { return false }
        return Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? []).contains(id)
    }

    func setEnabledForCurrent(_ on: Bool) {
        guard let id = LocalPlayerStore.shared.currentID else { return }
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
        if on { set.insert(id) } else { set.remove(id) }
        UserDefaults.standard.set(Array(set), forKey: Self.enabledKey)
        objectWillChange.send()
        if on { authenticate() }
    }

    /// Quietly restores a session on launch when the current player opted in.
    func resumeIfEnabled() {
        if isEnabledForCurrent { authenticate() }
    }

    // MARK: Sign-in

    func authenticate() {
        if GKLocalPlayer.local.isAuthenticated { didAuthenticate(); return }
        guard !handlerInstalled else { return }
        handlerInstalled = true
        status = "Signing in to Game Center…"
        GKLocalPlayer.local.authenticateHandler = { [weak self] controller, error in
            Task { @MainActor in
                guard let self else { return }
                if let controller {
                    Self.present(controller)
                    return
                }
                if let error {
                    self.isAuthenticated = false
                    self.status = "Game Center unavailable: \(error.localizedDescription)"
                    return
                }
                if GKLocalPlayer.local.isAuthenticated {
                    self.didAuthenticate()
                } else {
                    self.isAuthenticated = false
                    self.status = "Not signed in to Game Center. Sign in from System Settings, then try again."
                }
            }
        }
    }

    #if os(iOS)
    private static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(controller, animated: true)
    }
    #else
    private static func present(_ controller: NSViewController) {
        NSApp.keyWindow?.contentViewController?.presentAsSheet(controller)
    }
    #endif

    private func didAuthenticate() {
        isAuthenticated = true
        gcName = GKLocalPlayer.local.displayName
        status = nil
        Task {
            await publish()
            await loadFriends()
            await loadBoards()
            await loadDuels()
        }
    }

    // MARK: Scores + achievements

    /// Posts the current player's numbers. No-op unless opted in and signed in.
    func publish() async {
        guard isAuthenticated, isEnabledForCurrent, let card = PlayerCardBuilder.current() else { return }
        let scores: [(String, Int)] = [
            ("egf.weekly_volume", Int(card.weeklyVolume)),
            ("egf.level", card.level),
            ("egf.streak", card.streak),
            ("egf.raid_damage", card.raidDamage),
        ]
        for (board, value) in scores where value > 0 {
            try? await GKLeaderboard.submitScore(value, context: 0, player: GKLocalPlayer.local, leaderboardIDs: [board])
        }
        // Mirror unlocked local achievements.
        if let id = LocalPlayerStore.shared.currentID {
            let unlocked = GameProfileService.shared.engine.store.state(id).achievements.keys
            let reports = unlocked.map { key -> GKAchievement in
                let a = GKAchievement(identifier: Self.achievementPrefix + key)
                a.percentComplete = 100
                a.showsCompletionBanner = false
                return a
            }
            if !reports.isEmpty { try? await GKAchievement.report(reports) }
        }
    }

    func loadBoards() async {
        guard isAuthenticated else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let boards = try await GKLeaderboard.loadLeaderboards(IDs: Self.boards.map(\.id))
            var out: [String: [GCBoardEntry]] = [:]
            for board in boards {
                let scope: GKLeaderboard.PlayerScope = friends.isEmpty ? .global : .friendsOnly
                let (_, rows, _) = try await board.loadEntries(for: scope, timeScope: .week, range: NSRange(location: 1, length: 25))
                out[board.baseLeaderboardID] = rows.map {
                    GCBoardEntry(id: $0.player.gamePlayerID, rank: $0.rank, name: $0.player.displayName,
                                 score: $0.formattedScore, isMe: $0.player.gamePlayerID == GKLocalPlayer.local.gamePlayerID)
                }
            }
            entries = out
        } catch {
            status = "Leaderboards aren't set up yet (\(error.localizedDescription))."
        }
    }

    func loadFriends() async {
        guard isAuthenticated else { return }
        do {
            let list = try await GKLocalPlayer.local.loadFriends()
            friends = list.map(\.displayName).sorted()
        } catch {
            // Friend-list permission declined or unsupported: boards fall back to global.
            friends = []
        }
    }

    // MARK: Duels (turn-based: each side posts this week's volume)

    private struct DuelData: Codable { var week: String; var volumes: [String: Double] }

    func startDuel() async {
        guard isAuthenticated else { return }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.inviteMessage = "Weekly volume duel in Endgame Fitness"
        do {
            let match = try await GKTurnBasedMatch.find(for: request)
            try await takeTurn(match)
            await loadDuels()
        } catch {
            status = "Couldn't start a duel: \(error.localizedDescription)"
        }
    }

    /// Posts my weekly volume into a duel and passes the turn (or ends it).
    func play(_ duelID: String) async {
        guard let match = try? await GKTurnBasedMatch.load(withID: duelID) else { return }
        do {
            try await takeTurn(match)
        } catch {
            status = "Duel move failed: \(error.localizedDescription)"
        }
        await loadDuels()
    }

    private func takeTurn(_ match: GKTurnBasedMatch) async throws {
        let me = GKLocalPlayer.local.gamePlayerID
        let week = GameRules.weekKey(Int(Date().timeIntervalSince1970))
        var data = match.matchData.flatMap { try? JSONDecoder().decode(DuelData.self, from: $0) } ?? DuelData(week: week, volumes: [:])
        data.volumes[me] = PlayerCardBuilder.current()?.weeklyVolume ?? 0
        let encoded = try JSONEncoder().encode(data)
        let others = match.participants.filter { $0.player?.gamePlayerID != me }
        if data.volumes.count >= 2, let them = others.first, let theirID = them.player?.gamePlayerID {
            let mine = data.volumes[me] ?? 0, theirs = data.volumes[theirID] ?? 0
            for p in match.participants {
                let isMe = p.player?.gamePlayerID == me
                p.matchOutcome = mine == theirs ? .tied : ((mine > theirs) == isMe ? .won : .lost)
            }
            try await match.endMatchInTurn(withMatch: encoded)
        } else {
            try await match.endTurn(withNextParticipants: others, turnTimeout: GKTurnTimeoutDefault, match: encoded)
        }
    }

    func loadDuels() async {
        guard isAuthenticated else { return }
        guard let matches = try? await GKTurnBasedMatch.loadMatches() else { return }
        let me = GKLocalPlayer.local.gamePlayerID
        duels = matches.map { m in
            let data = m.matchData.flatMap { try? JSONDecoder().decode(DuelData.self, from: $0) }
            let other = m.participants.first { $0.player?.gamePlayerID != me }
            let theirID = other?.player?.gamePlayerID
            let mine = m.participants.first { $0.player?.gamePlayerID == me }
            return GCDuel(
                id: m.matchID, opponent: other?.player?.displayName ?? "Waiting for opponent",
                myVolume: data?.volumes[me], theirVolume: theirID.flatMap { data?.volumes[$0] },
                myTurn: m.currentParticipant?.player?.gamePlayerID == me,
                finished: m.status == .ended,
                outcome: m.status == .ended ? Self.outcomeText(mine?.matchOutcome) : nil
            )
        }
    }

    private static func outcomeText(_ o: GKTurnBasedMatch.Outcome?) -> String? {
        switch o {
        case .won?:  return "Won"
        case .lost?: return "Lost"
        case .tied?: return "Tied"
        default:     return nil
        }
    }
}
