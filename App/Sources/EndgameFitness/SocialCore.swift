//
//  SocialCore.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  Social without our own accounts (Docs/SOCIAL_DESIGN.md):
//  - PlayerCard: a compact snapshot of a local player (name, level, class,
//    weekly volume, top PRs, streak) that travels as a text code, a deep link
//    (endgamefitness://card/<code>) or a QR code.
//  - RivalStore: friends' cards imported on this device, per local player.
//    Re-importing a newer card updates the rival and logs what changed.
//
//  The code is "signed-ish": an HMAC with a key baked into the app. It stops
//  typos and casual hand-edits; it does NOT stop someone who extracts the key.
//  Rival boards are bragging rights between friends, not a ranked ladder.
//

import Foundation
import SwiftUI
import CryptoKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Player card

struct PlayerCard: Codable, Equatable, Identifiable {
    struct PR: Codable, Equatable, Hashable {
        var exercise: String
        var e1rm: Double
        enum CodingKeys: String, CodingKey { case exercise = "x", e1rm = "w" }
    }

    var version = 1
    /// Local player id from the sender's device (random UUID, not personal).
    var id: String
    var name: String
    var symbol: String
    var colorIndex: Int
    var level: Int
    var xp: Int
    var heroClass: String?
    var title: String?
    var weekKey: String
    var weeklyVolume: Double
    var weeklyWorkouts: Int
    var streak: Int
    var longestStreak: Int
    var totalWorkouts: Int
    var raidDamage: Int
    var prs: [PR]
    var issuedAt: Int

    enum CodingKeys: String, CodingKey {
        case version = "v", id, name = "n", symbol = "sy", colorIndex = "ci", level = "l", xp = "xp"
        case heroClass = "c", title = "ti", weekKey = "wk", weeklyVolume = "wv", weeklyWorkouts = "ww"
        case streak = "s", longestStreak = "ls", totalWorkouts = "tw", raidDamage = "rd", prs = "pr", issuedAt = "t"
    }

    var color: Color { LocalPlayer.colors[((colorIndex % LocalPlayer.colors.count) + LocalPlayer.colors.count) % LocalPlayer.colors.count] }
    /// Weekly volume only counts against the current week.
    var currentWeeklyVolume: Double {
        weekKey == GameRules.weekKey(Int(Date().timeIntervalSince1970)) ? weeklyVolume : 0
    }
}

enum PlayerCardCode {
    static let prefix = "EGF1"
    static let scheme = "endgamefitness"
    // Obfuscation-grade key: see the header comment.
    private static let key = SymmetricKey(data: Data("endgame-fitness/player-card/v1/7f3c1e".utf8))

    enum DecodeError: LocalizedError {
        case notACard, badSignature, unreadable
        var errorDescription: String? {
            switch self {
            case .notACard:     return "That isn't an Endgame Fitness player card."
            case .badSignature: return "This card was changed after it was made, so it can't be imported."
            case .unreadable:   return "The card is damaged or from a newer version of the app."
            }
        }
    }

    static func encode(_ card: PlayerCard) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(card)) ?? Data()
        let mac = Data(HMAC<SHA256>.authenticationCode(for: json, using: key)).prefix(8)
        return "\(prefix).\(json.base64URL).\(mac.base64URL)"
    }

    static func deepLink(_ card: PlayerCard) -> URL {
        URL(string: "\(scheme)://card/\(encode(card))")!
    }

    /// Accepts the bare code, the deep link, or text containing either.
    static func decode(_ raw: String) throws -> PlayerCard {
        guard let start = raw.range(of: "\(prefix).") else { throw DecodeError.notACard }
        let tail = raw[start.lowerBound...]
        let token = tail.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        let parts = token.split(separator: ".")
        guard parts.count == 3, let json = Data(base64URL: String(parts[1])), let mac = Data(base64URL: String(parts[2])) else {
            throw DecodeError.unreadable
        }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: json, using: key)).prefix(8)
        guard expected == mac else { throw DecodeError.badSignature }
        guard let card = try? JSONDecoder().decode(PlayerCard.self, from: json) else { throw DecodeError.unreadable }
        return card
    }

    /// A QR image of the deep link.
    static func qrImage(_ text: String, scale: CGFloat = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Finds a QR code in an image (macOS "import screenshot", iOS photo).
    static func readQR(from image: CIImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

// MARK: - Building my card

@MainActor
enum PlayerCardBuilder {
    /// The current local player's card, or nil before a player is picked.
    static func current() -> PlayerCard? {
        let game = GameProfileService.shared
        guard let player = LocalPlayerStore.shared.current, let profile = game.profile else { return nil }
        let state = game.engine.store.state(player.id)
        let now = Int(Date().timeIntervalSince1970)
        let weekStart = GameRules.weekStart(now)
        let thisWeek = state.sessions.values.filter { $0.counted && $0.performedAt >= weekStart }
        var prs: [PlayerCard.PR] = state.records.map { exercise, byReps in
            let best = byReps.reduce(0.0) { max($0, GameRules.estimated1RM($1.value, Int($1.key) ?? 0)) }
            return PlayerCard.PR(exercise: exercise, e1rm: best)
        }
        prs.sort { $0.e1rm > $1.e1rm }
        let raid = game.raid
        return PlayerCard(
            id: player.id, name: player.name, symbol: player.symbol, colorIndex: player.colorIndex,
            level: profile.level, xp: profile.xp, heroClass: profile.heroClass, title: profile.title,
            weekKey: GameRules.weekKey(now),
            weeklyVolume: thisWeek.reduce(0) { $0 + $1.volume }, weeklyWorkouts: thisWeek.count,
            streak: profile.currentStreak, longestStreak: profile.longestStreak, totalWorkouts: profile.totalWorkouts,
            raidDamage: raid?.myDamage ?? 0, prs: Array(prs.prefix(5)), issuedAt: now
        )
    }
}

// MARK: - Rivals

struct Rival: Codable, Identifiable, Equatable {
    var card: PlayerCard
    var addedAt: Int
    var updatedAt: Int
    /// "nearby" (Gym Party), "code", "qr", "link", "file".
    var source: String
    var id: String { card.id }
}

/// Something that happened socially: a rival leveled, a party boss fell.
struct SocialEvent: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var at: Int
    var symbol: String
    var text: String
}

struct RivalBook: Codable {
    var rivals: [Rival] = []
    var events: [SocialEvent] = []
}

@MainActor
final class RivalStore: ObservableObject {
    static let shared = RivalStore()

    @Published private(set) var rivals: [Rival] = []
    @Published private(set) var events: [SocialEvent] = []
    /// The card most recently imported, for a confirmation banner.
    @Published var lastImport: (name: String, isNew: Bool)?
    @Published var importError: String?

    private var loadedFor: String?

    private func file(_ playerID: String) -> URL {
        GameProfileService.shared.engine.store.playerDirectory(playerID).appendingPathComponent("rivals.json")
    }

    /// Reloads for whichever local player is current.
    func reload() {
        guard let id = LocalPlayerStore.shared.currentID else { rivals = []; events = []; loadedFor = nil; return }
        let book = (try? Data(contentsOf: file(id))).flatMap { try? JSONDecoder().decode(RivalBook.self, from: $0) } ?? RivalBook()
        rivals = book.rivals
        events = book.events
        loadedFor = id
    }

    private func ensureLoaded() {
        if loadedFor != LocalPlayerStore.shared.currentID { reload() }
    }

    private func save() {
        guard let id = loadedFor else { return }
        let url = file(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(RivalBook(rivals: rivals, events: Array(events.prefix(200)))) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Imports a card from any text (code, link, QR payload). Returns true on success.
    @discardableResult
    func importText(_ text: String, source: String) -> Bool {
        do {
            return add(try PlayerCardCode.decode(text), source: source)
        } catch {
            importError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func add(_ card: PlayerCard, source: String) -> Bool {
        ensureLoaded()
        guard loadedFor != nil else { importError = "Pick a player first."; return false }
        if card.id == LocalPlayerStore.shared.currentID { importError = "That's your own card."; return false }
        importError = nil
        let now = Int(Date().timeIntervalSince1970)
        if let i = rivals.firstIndex(where: { $0.id == card.id }) {
            let old = rivals[i].card
            guard card.issuedAt >= old.issuedAt else { lastImport = (card.name, false); return true }
            rivals[i].card = card
            rivals[i].updatedAt = now
            for e in Self.changes(from: old, to: card) { log(e) }
            lastImport = (card.name, false)
        } else {
            rivals.append(Rival(card: card, addedAt: now, updatedAt: now, source: source))
            log(SocialEvent(at: now, symbol: "person.badge.plus", text: "\(card.name) joined your rivals (Lv \(card.level))."))
            lastImport = (card.name, true)
        }
        save()
        return true
    }

    func remove(_ id: String) {
        ensureLoaded()
        rivals.removeAll { $0.id == id }
        save()
    }

    func log(_ event: SocialEvent) {
        ensureLoaded()
        events.insert(event, at: 0)
        save()
    }

    nonisolated static func changes(from old: PlayerCard, to new: PlayerCard) -> [SocialEvent] {
        var out: [SocialEvent] = []
        let at = new.issuedAt
        if new.level > old.level { out.append(SocialEvent(at: at, symbol: "arrow.up.circle.fill", text: "\(new.name) reached level \(new.level).")) }
        if new.streak > old.streak, new.streak >= 3 { out.append(SocialEvent(at: at, symbol: "flame.fill", text: "\(new.name) is on a \(new.streak)-day streak.")) }
        let oldBest = Dictionary(old.prs.map { ($0.exercise, $0.e1rm) }, uniquingKeysWith: max)
        for pr in new.prs where pr.e1rm > (oldBest[pr.exercise] ?? .infinity) {
            out.append(SocialEvent(at: at, symbol: "trophy.fill", text: "\(new.name) hit a \(pr.exercise.capitalized) PR (\(Int(pr.e1rm)) e1RM)."))
        }
        if new.weekKey == old.weekKey, new.weeklyWorkouts > old.weeklyWorkouts {
            out.append(SocialEvent(at: at, symbol: "dumbbell.fill", text: "\(new.name) trained again: \(new.weeklyWorkouts) sessions this week."))
        }
        return out
    }

    /// Me + rivals, ranked by a metric.
    func board(metric: RivalMetric, me: PlayerCard?) -> [(card: PlayerCard, isMe: Bool)] {
        ensureLoaded()
        var rows = rivals.map { (card: $0.card, isMe: false) }
        if let me { rows.append((card: me, isMe: true)) }
        return rows.sorted { metric.value($0.card) > metric.value($1.card) }
    }
}

enum RivalMetric: String, CaseIterable, Identifiable {
    case weeklyVolume = "Week volume"
    case level = "Level"
    case streak = "Streak"
    case bestLift = "Best lift"

    var id: String { rawValue }

    func value(_ c: PlayerCard) -> Double {
        switch self {
        case .weeklyVolume: return c.currentWeeklyVolume
        case .level:        return Double(c.level) + Double(c.xp) / 1e9
        case .streak:       return Double(c.streak)
        case .bestLift:     return c.prs.map(\.e1rm).max() ?? 0
        }
    }

    func label(_ c: PlayerCard) -> String {
        switch self {
        case .weeklyVolume: return "\(Int(c.currentWeeklyVolume).formatted()) lb"
        case .level:        return "Lv \(c.level)"
        case .streak:       return "\(c.streak) d"
        case .bestLift:     return c.prs.first.map { "\(Int($0.e1rm)) \($0.exercise.capitalized)" } ?? "-"
        }
    }
}
