//
//  LocalGame.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  The on-device game: per-player state and a shared "household" (the local
//  players on this device), persisted as JSON under Application Support, and
//  the engine that applies GameRules to them. This replaces everything the
//  old online fitness API used to compute (XP, levels, streaks, quests,
//  achievements, talents, challenges, raids, seasons, feed).
//
//  Layout (root = Application Support/EndgameFitness/Game):
//    players.json                 the local player roster (LocalPlayerStore)
//    household.json               guild, raids, feed, challenges
//    Players/<player id>/game.json one player's progress
//

import Foundation

// MARK: - Persisted state

struct SessionRecord: Codable, Equatable {
    var id: String
    var performedAt: Int
    var volume: Double
    var reps: Int
    var durationSecs: Int
    var xp: Int
    var rev: Int
    /// Counts toward totals (not deleted, not flagged).
    var counted: Bool
    var prs: Int
    /// Hero-class votes: category -> sets.
    var votes: [String: Int]
}

struct QuestRecord: Codable, Equatable {
    var id: String
    var questKey: String
    var kind: String
    var target: Double
    var progress: Double
    var xpReward: Int
    var expiresAt: Int
    var completedAt: Int?
    var claimed: Bool
}

struct PlayerGameState: Codable, Equatable {
    var version = 1
    var xp = 0
    var level = 1
    var talentPoints = 0
    var streak = GameRules.StreakState()
    var totalWorkouts = 0
    var totalVolume = 0.0
    var totalReps = 0
    var sessions: [String: SessionRecord] = [:]
    /// PR key -> "reps" -> best weight (lb).
    var records: [String: [String: Double]] = [:]
    var quests: [String: QuestRecord] = [:]
    /// Achievement id -> unlocked at.
    var achievements: [String: Int] = [:]
    var talentRanks: [String: Int] = [:]
    /// Season id -> season XP.
    var seasonXP: [String: Int] = [:]
    var seasonClaims: [String: [Int]] = [:]
    var titles: [String] = []
    var cosmetics: [String] = []
    var raidsWon = 0
    /// History imported from the training log once.
    var seeded = false

    // Profile fields (formerly PUT fitness/profile)
    var title: String?
    var cosmetic: String?
    var bio: String?
    var isPublic = true
    var trainingGoal: String?
    var experienceLevel: String?
    var equipmentLevel: String?
    var bodyWeight: Double?
    var heightInches: Double?
    var birthYear: Int?
    var units = "lb"
    var onboarded: Bool?
    var avatarConfig: AvatarBodyProfile?
}

struct LocalGuild: Codable, Equatable {
    var id: String
    var name: String
    var motto: String?
    var emblem: String?
    var ownerID: String
    var inviteCode: String
    var isOpen: Bool
    /// player id -> role (owner | officer | member)
    var members: [String: String]
    var createdAt: Int
}

struct RaidRecord: Codable, Equatable {
    var id: String
    var ownerKey: String        // guild id, or "solo:<player id>"
    var weekStart: Int
    var bossID: String
    var hp: Int
    var memberCount: Int
    var damage: [String: Int] = [:]
    var hits: [String: Int] = [:]
    var defeatedAt: Int?
}

struct FeedRecord: Codable, Equatable {
    var id: String
    var userID: String
    var kind: String
    var summary: String
    var createdAt: Int
    var sessionID: String?
    /// emoji -> player ids
    var reactions: [String: [String]] = [:]
    var comments: [CommentRecord] = []
}

struct CommentRecord: Codable, Equatable {
    var id: String
    var userID: String
    var text: String
    var createdAt: Int
}

struct ChallengeRecord: Codable, Equatable {
    var id: String
    var kind: String
    var metric: String
    var creatorID: String
    var opponentID: String?
    var guildID: String?
    var participants: [String]
    var days: Int
    var createdAt: Int
    var startsAt: Int
    var endsAt: Int
    var status: String          // pending | active | finished | declined
    var winnerID: String?
}

struct HouseholdState: Codable, Equatable {
    var version = 1
    var guild: LocalGuild?
    var raids: [String: RaidRecord] = [:]
    var feed: [FeedRecord] = []
    var challenges: [ChallengeRecord] = []
    /// player id -> blocked player ids
    var blocked: [String: [String]] = [:]
}

// MARK: - Store

/// JSON persistence for player states and the household. Not thread-safe:
/// used from the main actor (and from the self-test on one thread).
final class LocalGameStore {
    let root: URL
    private let fm = FileManager.default
    private var cache: [String: PlayerGameState] = [:]
    private var householdCache: HouseholdState?

    init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("EndgameFitness", isDirectory: true)
            .appendingPathComponent("Game", isDirectory: true)
    }()

    func playerDirectory(_ id: String) -> URL {
        root.appendingPathComponent("Players", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private func playerFile(_ id: String) -> URL { playerDirectory(id).appendingPathComponent("game.json") }
    private var householdFile: URL { root.appendingPathComponent("household.json") }

    func state(_ id: String) -> PlayerGameState {
        if let cached = cache[id] { return cached }
        var state = PlayerGameState()
        if let data = try? Data(contentsOf: playerFile(id)) {
            if let decoded = try? JSONDecoder().decode(PlayerGameState.self, from: data) {
                state = decoded
            } else {
                // Never overwrite a file we could not read: keep a copy aside.
                let aside = playerDirectory(id).appendingPathComponent("game.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.copyItem(at: playerFile(id), to: aside)
            }
        }
        cache[id] = state
        return state
    }

    func save(_ state: PlayerGameState, for id: String) {
        cache[id] = state
        write(state, to: playerFile(id))
    }

    func household() -> HouseholdState {
        if let cached = householdCache { return cached }
        let state = (try? Data(contentsOf: householdFile)).flatMap { try? JSONDecoder().decode(HouseholdState.self, from: $0) }
            ?? HouseholdState()
        householdCache = state
        return state
    }

    func saveHousehold(_ state: HouseholdState) {
        householdCache = state
        write(state, to: householdFile)
    }

    func removePlayer(_ id: String) {
        cache[id] = nil
        try? fm.removeItem(at: playerDirectory(id))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Engine

/// Applies GameRules to the store. Every mutation saves immediately.
final class LocalGame {
    struct Outcome {
        var xpGained = 0
        var levelsGained = 0
        var prCount = 0
        var unlocked: [String] = []
        var raid: RaidHit?
        var accepted = false
    }

    let store: LocalGameStore
    /// Current time (epoch seconds); injectable for the self-test.
    var clock: () -> Int = { Int(Date().timeIntervalSince1970) }
    var tzOffsetMin: Int = TimeZone.current.secondsFromGMT() / 60
    /// The local roster: id -> display name.
    var roster: () -> [(id: String, name: String)] = { [] }

    init(store: LocalGameStore) { self.store = store }

    var now: Int { clock() }

    func name(of id: String) -> String { roster().first { $0.id == id }?.name ?? "Player" }
    func householdIDs() -> [String] { roster().map(\.id) }
    func friendCount(_ id: String) -> Int { householdIDs().filter { $0 != id && !isBlocked(id, $0) }.count }

    func isBlocked(_ a: String, _ b: String) -> Bool {
        let h = store.household()
        return (h.blocked[a] ?? []).contains(b) || (h.blocked[b] ?? []).contains(a)
    }

    func inGuild(_ id: String) -> Bool { store.household().guild?.members[id] != nil }

    // MARK: XP

    /// awardXp: level, talent points (+ bonus), season XP, rank titles, level-up post.
    @discardableResult
    func award(_ amount: Int, to id: String, season: Bool = true) -> Int {
        guard amount > 0 else { return 0 }
        var s = store.state(id)
        let before = s.level
        s.xp += amount
        s.level = GameRules.levelForXP(s.xp)
        let gained = max(0, s.level - before)
        if gained > 0 { s.talentPoints += gained + GameRules.bonusTalentPoints(s.talentRanks, from: before, to: s.level) }
        if season { creditSeason(&s, amount) }
        for title in GameRules.rankTitlesCrossed(from: before, to: s.level) where !s.titles.contains(title) { s.titles.append(title) }
        store.save(s, for: id)
        if gained > 0 { post(id, kind: "level_up", summary: "reached level \(s.level)") }
        return gained
    }

    private func creditSeason(_ s: inout PlayerGameState, _ amount: Int) {
        let n = GameRules.seasonNumber(at: now)
        guard n >= 1 else { return }
        s.seasonXP[GameRules.seasonID(n), default: 0] += amount
    }

    // MARK: Feed

    func post(_ id: String, kind: String, summary: String, sessionID: String? = nil) {
        var h = store.household()
        h.feed.insert(FeedRecord(id: UUID().uuidString, userID: id, kind: kind, summary: summary,
                                 createdAt: now, sessionID: sessionID), at: 0)
        if h.feed.count > 1000 { h.feed.removeLast(h.feed.count - 1000) }
        store.saveHousehold(h)
    }

    // MARK: Quests

    /// ensureBoard: today's and this week's quests exist; expired ones are dropped.
    func ensureBoard(_ id: String) {
        var s = store.state(id)
        let t = now
        var changed = false
        for entry in GameRules.board(for: id, at: t) where s.quests[entry.id] == nil {
            s.quests[entry.id] = QuestRecord(id: entry.id, questKey: entry.def.key, kind: entry.kind,
                                             target: entry.def.target, progress: 0, xpReward: entry.def.xp,
                                             expiresAt: entry.expiresAt, completedAt: nil, claimed: false)
            changed = true
        }
        let expired = s.quests.filter { $0.value.expiresAt <= t }.map(\.key)
        for key in expired { s.quests[key] = nil; changed = true }
        if changed { store.save(s, for: id) }
    }

    func activeQuests(_ id: String) -> [QuestRecord] {
        ensureBoard(id)
        let t = now
        return store.state(id).quests.values.filter { $0.expiresAt > t }
            .sorted { ($0.kind == "daily" ? 0 : 1, $0.questKey) < ($1.kind == "daily" ? 0 : 1, $1.questKey) }
    }

    func advanceQuests(_ id: String, event: [String: Double]) {
        ensureBoard(id)
        var s = store.state(id)
        let t = now
        var changed = false
        for (key, q) in s.quests where q.completedAt == nil && q.expiresAt > t {
            let next = GameRules.advance(questKey: q.questKey, target: q.target, progress: q.progress, event: event)
            guard next != q.progress else { continue }
            s.quests[key]?.progress = next
            if next >= q.target { s.quests[key]?.completedAt = t }
            changed = true
        }
        if changed { store.save(s, for: id) }
    }

    /// Returns (xp, levels gained) or an error message.
    func claimQuest(_ id: String, questID: String) -> Result<(xp: Int, levels: Int), LocalGameError> {
        var s = store.state(id)
        guard let q = s.quests[questID] else { return .failure(.message("Quest not found")) }
        guard q.completedAt != nil else { return .failure(.message("Quest not complete")) }
        if q.claimed { return .success((0, 0)) }
        s.quests[questID]?.claimed = true
        store.save(s, for: id)
        let levels = award(q.xpReward, to: id)
        let title = GameRules.questDefinition(q.questKey)?.title ?? q.questKey
        post(id, kind: "quest", summary: "completed the \(q.kind) quest \"\(title)\"")
        _ = checkAchievements(id)
        return .success((q.xpReward, levels))
    }

    // MARK: Achievements

    func achievementStats(_ id: String) -> GameRules.AchievementStats {
        let s = store.state(id)
        return GameRules.AchievementStats(totalWorkouts: s.totalWorkouts, longestStreak: s.streak.longest,
                                          totalVolume: s.totalVolume, level: s.level, friendCount: friendCount(id),
                                          inGuild: inGuild(id), raidsWon: s.raidsWon)
    }

    /// Unlocks everything newly earned (repeats: achievement XP can cross a level rule).
    func checkAchievements(_ id: String) -> [String] {
        var ids: [String] = []
        for _ in 0..<5 {
            let fresh = GameRules.newlyUnlocked(achievementStats(id), have: Set(store.state(id).achievements.keys))
            guard !fresh.isEmpty else { break }
            for a in fresh {
                var s = store.state(id)
                s.achievements[a.id] = now
                if !s.titles.contains(a.title) { s.titles.append(a.title) }
                store.save(s, for: id)
                award(a.xp, to: id)
                post(id, kind: "achievement", summary: "unlocked \"\(a.title)\"")
                ids.append(a.id)
            }
        }
        return ids
    }

    // MARK: Sessions

    /// One finished, edited or deleted workout (handleSync for a single session).
    @discardableResult
    func apply(_ session: SyncSession, to id: String, historical: Bool = false) -> Outcome {
        var outcome = Outcome()
        let t = now
        let c = GameRules.evaluate(session, now: t)
        var s = store.state(id)
        let rev = max(1, session.clientRev)

        if let existing = s.sessions[c.id] {
            outcome.accepted = true
            guard rev > existing.rev else { return outcome }       // replay
            // applyRevision: totals move by the difference; XP is never re-awarded.
            let newCounts = !c.deleted && !c.flagged
            let dW = (newCounts ? 1 : 0) - (existing.counted ? 1 : 0)
            let dV = (newCounts ? c.volume : 0) - (existing.counted ? existing.volume : 0)
            let dR = (newCounts ? c.reps : 0) - (existing.counted ? existing.reps : 0)
            s.totalWorkouts = max(0, s.totalWorkouts + dW)
            s.totalVolume = max(0, s.totalVolume + dV)
            s.totalReps = max(0, s.totalReps + dR)
            var record = existing
            record.rev = rev
            record.counted = newCounts
            record.performedAt = c.performedAt
            record.volume = c.volume
            record.reps = c.reps
            record.durationSecs = c.durationSecs
            record.votes = votes(c.exercises)
            s.sessions[c.id] = record
            store.save(s, for: id)
            if c.deleted {
                var h = store.household()
                h.feed.removeAll { $0.userID == id && $0.sessionID == c.id }
                store.saveHousehold(h)
            }
            return outcome
        }

        outcome.accepted = true
        if c.deleted || c.flagged {
            s.sessions[c.id] = SessionRecord(id: c.id, performedAt: c.performedAt, volume: c.volume, reps: c.reps,
                                             durationSecs: c.durationSecs, xp: 0, rev: rev, counted: false, prs: 0, votes: [:])
            store.save(s, for: id)
            return outcome
        }

        // Streak first so Second Wind sees the streak this session produces.
        let shield = GameRules.streakShieldDays(s.talentRanks)
        let streak = GameRules.applySessionDay(s.streak, day: GameRules.localDayKey(c.performedAt, tzOffsetMin: tzOffsetMin), shieldDays: shield)
        let base = GameRules.xpForWorkout(volume: c.volume, reps: c.reps, durationSecs: c.durationSecs)
        let xp = GameRules.applyTalentEffects(base, ranks: s.talentRanks, volume: c.volume, streak: streak.state.current,
                                              friends: friendCount(id), inGuild: inGuild(id))
        let prs = GameRules.detectPRs(c.exercises, records: &s.records)

        let before = s.level
        s.xp += xp
        s.level = GameRules.levelForXP(s.xp)
        let gained = max(0, s.level - before)
        s.talentPoints += gained + GameRules.bonusTalentPoints(s.talentRanks, from: before, to: s.level)
        s.streak = streak.state
        s.totalWorkouts += 1
        s.totalVolume += c.volume
        s.totalReps += c.reps
        if !historical { creditSeason(&s, xp) }
        for title in GameRules.rankTitlesCrossed(from: before, to: s.level) where !s.titles.contains(title) { s.titles.append(title) }
        s.sessions[c.id] = SessionRecord(id: c.id, performedAt: c.performedAt, volume: c.volume, reps: c.reps,
                                         durationSecs: c.durationSecs, xp: xp, rev: rev, counted: true, prs: prs,
                                         votes: votes(c.exercises))
        store.save(s, for: id)

        outcome.xpGained = xp
        outcome.levelsGained = gained
        outcome.prCount = prs

        guard !historical else { return outcome }

        let volumeText = Int(c.volume.rounded()).formatted()
        post(id, kind: "workout", summary: "finished \(c.name ?? "a workout") — \(volumeText) lb moved", sessionID: c.id)
        if prs > 0 { post(id, kind: "pr", summary: "set \(prs) new personal record\(prs == 1 ? "" : "s")", sessionID: c.id) }
        if gained > 0 { post(id, kind: "level_up", summary: "reached level \(s.level)") }

        advanceQuests(id, event: GameRules.eventForWorkout(volume: c.volume, reps: c.reps, durationSecs: c.durationSecs, prs: prs))

        let damage = GameRules.raidDamage(volume: c.volume, prCount: prs)
        if damage > 0 { outcome.raid = hitRaid(id, damage: damage) }

        let levelBeforeAchievements = store.state(id).level
        outcome.unlocked = checkAchievements(id)
        outcome.levelsGained += max(0, store.state(id).level - levelBeforeAchievements)
        return outcome
    }

    private func votes(_ exercises: [GameRules.CleanExercise]) -> [String: Int] {
        var v: [String: Int] = [:]
        for ex in exercises { v[GameRules.affinityCategory(category: ex.category, name: ex.name), default: 0] += max(1, ex.sets.count) }
        return v
    }

    /// Replays the training log once for a player that has no game state yet.
    /// Old sessions earn XP, totals, streak and PR baselines, but not quests,
    /// raid damage, season XP or feed posts.
    func seedIfNeeded(_ id: String, history: [SyncSession]) -> Bool {
        guard !store.state(id).seeded else { return false }
        let weekStart = GameRules.weekStart(now)
        for session in history.sorted(by: { ($0.performedAt, $0.id) < ($1.performedAt, $1.id) }) where session.deleted != true {
            apply(session, to: id, historical: session.performedAt < weekStart)
        }
        var s = store.state(id)
        s.seeded = true
        store.save(s, for: id)
        _ = checkAchievements(id)
        return true
    }

    // MARK: Hero class

    func affinity(_ id: String) -> [String: Double] {
        let since = now - GameRules.heroWindowSecs
        var votes: [String: Int] = ["strength": 0, "endurance": 0, "mobility": 0, "athletic": 0]
        for r in store.state(id).sessions.values where r.counted && r.performedAt >= since {
            for (k, v) in r.votes { votes[k, default: 0] += v }
        }
        let total = votes.values.reduce(0, +)
        guard total > 0 else { return votes.mapValues { _ in 0 } }
        return votes.mapValues { (Double($0) / Double(total) * 1000).rounded() / 1000 }
    }

    func heroClass(_ id: String) -> String {
        GameRules.heroClass(affinity: affinity(id), totalSessions: store.state(id).totalWorkouts)
    }

    func effectiveStreak(_ id: String) -> (alive: Bool, current: Int, freezes: Int) {
        let s = store.state(id)
        return GameRules.effectiveStreak(s.streak, today: GameRules.localDayKey(now, tzOffsetMin: tzOffsetMin),
                                         shieldDays: GameRules.streakShieldDays(s.talentRanks))
    }

    func earnedTitles(_ id: String) -> [String] {
        let s = store.state(id)
        var titles = Set(GameRules.rankTitles(forLevel: s.level))
        for a in GameRules.achievements where s.achievements[a.id] != nil { titles.insert(a.title) }
        titles.formUnion(s.titles)
        return titles.sorted()
    }

    func seasonXP(_ id: String) -> Int {
        let n = GameRules.seasonNumber(at: now)
        return n >= 1 ? store.state(id).seasonXP[GameRules.seasonID(n)] ?? 0 : 0
    }

    // MARK: Talents

    func spendTalent(_ id: String, talentID: String) -> String? {
        var s = store.state(id)
        if let problem = GameRules.validateSpend(s.talentRanks, unspent: s.talentPoints, talentID: talentID) { return problem }
        s.talentPoints -= 1
        s.talentRanks[talentID, default: 0] += 1
        store.save(s, for: id)
        return nil
    }

    func respec(_ id: String) {
        var s = store.state(id)
        s.talentPoints += GameRules.pointsSpent(s.talentRanks)
        s.talentRanks = [:]
        store.save(s, for: id)
    }

    // MARK: Seasons

    func claimSeasonTier(_ id: String, tier: Int) -> String? {
        guard (1...GameRules.tierCount).contains(tier) else { return "That tier doesn't exist." }
        let n = GameRules.seasonNumber(at: now)
        guard n >= 1 else { return "The season hasn't started yet." }
        let sid = GameRules.seasonID(n)
        var s = store.state(id)
        guard GameRules.tier(forXP: s.seasonXP[sid] ?? 0) >= tier else { return "Tier not reached yet." }
        guard !(s.seasonClaims[sid] ?? []).contains(tier) else { return "Already claimed." }
        let reward = GameRules.reward(season: n, tier: tier)
        switch reward.type {
        case "title": if !s.titles.contains(reward.value) { s.titles.append(reward.value) }
        case "cosmetic": if !s.cosmetics.contains(reward.value) { s.cosmetics.append(reward.value) }
        case "streak_freeze":
            guard s.streak.freezes < GameRules.maxStreakFreezes else {
                return "Your streak freezes are full (\(GameRules.maxStreakFreezes)). Use one first."
            }
            s.streak.freezes += 1
        default: s.talentPoints += 1
        }
        s.seasonClaims[sid, default: []].append(tier)
        store.save(s, for: id)
        return nil
    }

    // MARK: Guild (household)

    static func inviteCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }

    func createGuild(_ id: String, name: String, motto: String, emblem: String?, isOpen: Bool) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 3, name.count <= 32 else { return "Guild names are 3–32 characters." }
        var h = store.household()
        if let guild = h.guild { return "This device already has a guild, \(guild.name). Join it instead." }
        h.guild = LocalGuild(id: UUID().uuidString, name: name, motto: motto.isEmpty ? nil : motto, emblem: emblem,
                             ownerID: id, inviteCode: Self.inviteCode(), isOpen: isOpen, members: [id: "owner"], createdAt: now)
        store.saveHousehold(h)
        _ = checkAchievements(id)
        return nil
    }

    func joinGuild(_ id: String, inviteCode: String? = nil) -> String? {
        var h = store.household()
        guard var guild = h.guild else { return "There's no guild on this device yet. Found one." }
        if let code = inviteCode, !guild.isOpen, code.uppercased() != guild.inviteCode { return "That invite code doesn't match." }
        guard guild.members.count < 50 else { return "The guild is full." }
        guild.members[id] = guild.members[id] ?? "member"
        h.guild = guild
        store.saveHousehold(h)
        _ = checkAchievements(id)
        return nil
    }

    func leaveGuild(_ id: String) -> String? {
        var h = store.household()
        guard var guild = h.guild, guild.members[id] != nil else { return nil }
        guild.members[id] = nil
        if guild.members.isEmpty {
            h.guild = nil
        } else {
            if guild.ownerID == id, let heir = guild.members.keys.sorted().first {
                guild.ownerID = heir
                guild.members[heir] = "owner"
            }
            h.guild = guild
        }
        store.saveHousehold(h)
        return nil
    }

    // MARK: Raids

    private func raidOwnerKey(_ id: String) -> (key: String, members: [String]) {
        if let guild = store.household().guild, guild.members[id] != nil {
            return (guild.id, guild.members.keys.sorted())
        }
        return ("solo:\(id)", [id])
    }

    /// This week's raid for the player's guild (or a solo raid), created on demand.
    func currentRaid(_ id: String) -> RaidRecord {
        let t = now
        let owner = raidOwnerKey(id)
        let ws = GameRules.weekStart(t)
        let raidID = "\(owner.key)|\(ws)"
        var h = store.household()
        if let existing = h.raids[raidID] { return existing }
        let boss = GameRules.bossForWeek(t)
        let raid = RaidRecord(id: raidID, ownerKey: owner.key, weekStart: ws, bossID: boss.id,
                              hp: GameRules.hpForGuild(boss, members: owner.members.count), memberCount: owner.members.count)
        h.raids[raidID] = raid
        // Keep the last ~12 weeks.
        let cutoff = ws - 12 * GameRules.weekSecs
        h.raids = h.raids.filter { $0.value.weekStart >= cutoff }
        store.saveHousehold(h)
        return raid
    }

    func hitRaid(_ id: String, damage: Int) -> RaidHit? {
        var raid = currentRaid(id)
        guard let boss = GameRules.bossCatalog.first(where: { $0.id == raid.bossID }) else { return nil }
        raid.damage[id, default: 0] += damage
        raid.hits[id, default: 0] += 1
        let done = raid.damage.values.reduce(0, +)
        var justDefeated = false
        if raid.defeatedAt == nil && done >= raid.hp {
            raid.defeatedAt = now
            justDefeated = true
        }
        var h = store.household()
        h.raids[raid.id] = raid
        store.saveHousehold(h)

        if justDefeated {
            for (member, dmg) in raid.damage where dmg > 0 { rewardRaid(member, boss: boss) }
        } else if raid.defeatedAt != nil {
            // A first hit after the kill still counts as taking part.
            var s = store.state(id)
            if let t = boss.rewardTitle, !s.titles.contains(t) { s.titles.append(t) }
            if let c = boss.rewardCosmetic, !s.cosmetics.contains(c) { s.cosmetics.append(c) }
            store.save(s, for: id)
        }
        return RaidHit(bossID: boss.id, bossName: boss.name, damage: damage, hp: raid.hp,
                       damageDone: min(done, raid.hp), defeated: done >= raid.hp, justDefeated: justDefeated,
                       rewardXP: justDefeated ? boss.rewardXP : 0,
                       rewardTitle: justDefeated ? boss.rewardTitle : nil,
                       rewardCosmetic: justDefeated ? boss.rewardCosmetic : nil)
    }

    private func rewardRaid(_ id: String, boss: RaidBoss) {
        var s = store.state(id)
        s.raidsWon += 1
        if let t = boss.rewardTitle, !s.titles.contains(t) { s.titles.append(t) }
        if let c = boss.rewardCosmetic, !s.cosmetics.contains(c) { s.cosmetics.append(c) }
        store.save(s, for: id)
        award(boss.rewardXP, to: id)
        post(id, kind: "raid_defeated", summary: "helped defeat \(boss.name)")
        _ = checkAchievements(id)
    }

    // MARK: Challenges

    func createChallenge(_ id: String, kind: String, metric: String, opponentID: String?, days: Int) -> String? {
        guard ["duel", "guild"].contains(kind) else { return "kind must be duel or guild" }
        guard ["volume", "workouts", "streak"].contains(metric) else { return "metric must be volume, workouts or streak" }
        guard (1...30).contains(days) else { return "days must be 1-30" }
        let t = now
        var h = store.household()
        var record = ChallengeRecord(id: UUID().uuidString, kind: kind, metric: metric, creatorID: id, opponentID: nil,
                                     guildID: nil, participants: [id], days: days, createdAt: t, startsAt: t,
                                     endsAt: t + days * GameRules.day, status: "active", winnerID: nil)
        if kind == "duel" {
            guard let opponentID, opponentID != id, householdIDs().contains(opponentID) else {
                return "Pick another player on this device."
            }
            record.opponentID = opponentID
            record.participants = [id, opponentID]
            record.status = "pending"
        } else {
            guard let guild = h.guild, guild.members[id] != nil else { return "Join the household guild first." }
            record.guildID = guild.id
            record.participants = guild.members.keys.sorted()
        }
        h.challenges.insert(record, at: 0)
        store.saveHousehold(h)
        return nil
    }

    func respondToChallenge(_ id: String, challengeID: String, accept: Bool) -> String? {
        var h = store.household()
        guard let i = h.challenges.firstIndex(where: { $0.id == challengeID }) else { return "Challenge not found." }
        guard h.challenges[i].status == "pending", h.challenges[i].opponentID == id else { return "Nothing to answer." }
        if accept {
            let t = now
            h.challenges[i].status = "active"
            h.challenges[i].startsAt = t
            h.challenges[i].endsAt = t + h.challenges[i].days * GameRules.day
        } else {
            h.challenges[i].status = "declined"
        }
        store.saveHousehold(h)
        return nil
    }

    func challengeSessions(_ id: String) -> [GameRules.ChallengeSession] {
        store.state(id).sessions.values.filter(\.counted).map { .init(performedAt: $0.performedAt, volume: $0.volume) }
    }

    func standings(_ c: ChallengeRecord) -> [GameRules.StandingRow] {
        var byUser: [String: [GameRules.ChallengeSession]] = [:]
        for p in c.participants { byUser[p] = challengeSessions(p) }
        return GameRules.standings(metric: c.metric, startsAt: c.startsAt, endsAt: c.endsAt,
                                   participants: c.participants, sessionsByUser: byUser)
    }

    /// Settles every active challenge whose window has closed; expires stale invites.
    func settleChallenges() {
        let t = now
        var h = store.household()
        var settled: [(ChallengeRecord, GameRules.Settlement)] = []
        for i in h.challenges.indices {
            let c = h.challenges[i]
            if c.status == "pending", t - c.createdAt > 7 * GameRules.day { h.challenges[i].status = "declined" }
            guard c.status == "active", c.endsAt <= t else { continue }
            let result = GameRules.settle(kind: c.kind, standings: standings(c))
            h.challenges[i].status = "finished"
            h.challenges[i].winnerID = result.winnerID
            settled.append((h.challenges[i], result))
        }
        guard !settled.isEmpty || h != store.household() else { return }
        store.saveHousehold(h)
        for (c, result) in settled {
            for award in result.awards { self.award(award.amount, to: award.userID) }
            if let winner = result.winnerID {
                post(winner, kind: "challenge", summary: "won a \(c.days)-day \(c.metric) \(c.kind == "duel" ? "duel" : "guild challenge")")
            }
            for p in c.participants { _ = checkAchievements(p) }
        }
    }

    // MARK: Reactions and comments

    func toggleReaction(_ id: String, itemID: String, emoji: String) {
        var h = store.household()
        guard let i = h.feed.firstIndex(where: { $0.id == itemID }) else { return }
        var who = h.feed[i].reactions[emoji] ?? []
        let adding = !who.contains(id)
        if adding { who.append(id) } else { who.removeAll { $0 == id } }
        h.feed[i].reactions[emoji] = who.isEmpty ? nil : who
        let owner = h.feed[i].userID
        store.saveHousehold(h)
        if adding && owner != id { advanceQuests(id, event: ["reactions": 1]) }
    }

    func addComment(_ id: String, itemID: String, text: String) -> CommentRecord? {
        var h = store.household()
        guard let i = h.feed.firstIndex(where: { $0.id == itemID }) else { return nil }
        let comment = CommentRecord(id: UUID().uuidString, userID: id, text: String(text.prefix(500)), createdAt: now)
        h.feed[i].comments.append(comment)
        store.saveHousehold(h)
        return comment
    }

    func deleteComment(_ id: String, commentID: String) {
        var h = store.household()
        for i in h.feed.indices { h.feed[i].comments.removeAll { $0.id == commentID && $0.userID == id } }
        store.saveHousehold(h)
    }

    // MARK: Roster changes

    /// A new player joined the device: everyone already here gains a party member.
    func playerJoined(_ id: String) {
        for other in householdIDs() where other != id {
            advanceQuests(other, event: ["friends": 1])
            _ = checkAchievements(other)
        }
        advanceQuests(id, event: ["friends": Double(min(1, friendCount(id)))])
        _ = checkAchievements(id)
    }

    func playerRemoved(_ id: String) {
        _ = leaveGuild(id)
        var h = store.household()
        h.feed.removeAll { $0.userID == id }
        for i in h.feed.indices {
            h.feed[i].comments.removeAll { $0.userID == id }
            for (emoji, who) in h.feed[i].reactions { h.feed[i].reactions[emoji] = who.filter { $0 != id } }
        }
        h.challenges.removeAll { $0.participants.contains(id) && $0.status != "finished" }
        h.blocked[id] = nil
        store.saveHousehold(h)
        store.removePlayer(id)
    }
}

enum LocalGameError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
