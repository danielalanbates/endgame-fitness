//
//  GameProfile.swift
//  Endgame Fitness
//
//  The player's server-backed identity: level, XP, streak, talents, friends,
//  guild and the activity feed. This is the layer that turns a workout log into
//  a game with other people in it.
//
//  Design notes:
//   • The server is authoritative for anything that affects rank. The client
//     uploads what happened (volume, reps, duration); the server decides the XP.
//     A patched client can lie about a workout but it cannot mint a level.
//   • Sync is offline-first. Sessions queue locally and flush when a connection
//     and a signed-in user are both available, so a workout in a basement gym
//     is never lost.
//

import Foundation
import SwiftUI

// MARK: - Models

struct FitnessProfile: Codable, Equatable {
    var userID: String
    var displayName: String
    var avatarURL: String?
    var level: Int
    var xp: Int
    var xpForNextLevel: Int
    var xpForCurrentLevel: Int
    var talentPoints: Int
    var prestige: Int
    var currentStreak: Int
    var longestStreak: Int
    var lastWorkoutDate: String?
    var totalWorkouts: Int
    var totalVolume: Double
    var totalReps: Int
    var trainingGoal: String?
    var experienceLevel: String?
    var equipmentLevel: String?
    var bodyWeight: Double?
    var heightInches: Double?
    var birthYear: Int?
    var units: String
    var title: String?
    var isPublic: Bool
    var friendCode: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case level, xp, prestige, units, title
        case xpForNextLevel = "xp_for_next_level"
        case xpForCurrentLevel = "xp_for_current_level"
        case talentPoints = "talent_points"
        case currentStreak = "current_streak"
        case longestStreak = "longest_streak"
        case lastWorkoutDate = "last_workout_date"
        case totalWorkouts = "total_workouts"
        case totalVolume = "total_volume"
        case totalReps = "total_reps"
        case trainingGoal = "training_goal"
        case experienceLevel = "experience_level"
        case equipmentLevel = "equipment_level"
        case bodyWeight = "body_weight"
        case heightInches = "height_inches"
        case birthYear = "birth_year"
        case isPublic = "is_public"
        case friendCode = "friend_code"
    }

    /// 0–1 progress through the current level, for the XP bar.
    var levelProgress: Double {
        let span = xpForNextLevel - xpForCurrentLevel
        guard span > 0 else { return 0 }
        return min(1, max(0, Double(xp - xpForCurrentLevel) / Double(span)))
    }

    var xpIntoLevel: Int { max(0, xp - xpForCurrentLevel) }
    var xpNeededForLevel: Int { max(1, xpForNextLevel - xpForCurrentLevel) }

    /// Rank title derived from level. Purely cosmetic, but it is the thing
    /// people screenshot, so the bands are wide enough to feel earned.
    var rankTitle: String {
        if let title, !title.isEmpty { return title }
        switch level {
        case ..<5:    return "Initiate"
        case 5..<10:  return "Apprentice"
        case 10..<20: return "Iron Disciple"
        case 20..<30: return "Ironbound"
        case 30..<45: return "Vanguard"
        case 45..<60: return "Warbringer"
        case 60..<80: return "Champion"
        case 80..<100: return "Ascendant"
        default:      return "Endgame"
        }
    }

    var rankColor: Color {
        switch level {
        case ..<10:   return .gray
        case 10..<30: return .brandGreen
        case 30..<60: return .brandBlue
        case 60..<100: return .brandPurple
        default:      return .brandOrange
        }
    }
}

/// One exercise's completed sets, uploaded so the server can detect personal
/// records (best weight per rep count) — the client never decides a PR itself.
struct SyncExercise: Codable, Equatable {
    struct Set: Codable, Equatable {
        var reps: Int
        var weight: Double
    }
    var name: String
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

    enum CodingKeys: String, CodingKey {
        case id, name, exercises
        case performedAt = "performed_at"
        case programID = "program_id"
        case durationSecs = "duration_secs"
        case totalVolume = "total_volume"
        case totalReps = "total_reps"
        case xpEarned = "xp_earned"
        case clientRev = "client_rev"
    }
}

struct LeaderboardEntry: Codable, Identifiable, Equatable {
    var rank: Int
    var userID: String
    var displayName: String
    var level: Int
    var xp: Int
    var currentStreak: Int
    var totalVolume: Double
    var totalWorkouts: Int
    var title: String?
    var avatarURL: String?
    var isSelf: Bool

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case rank, level, xp, title
        case userID = "user_id"
        case displayName = "display_name"
        case currentStreak = "current_streak"
        case totalVolume = "total_volume"
        case totalWorkouts = "total_workouts"
        case avatarURL = "avatar_url"
        case isSelf = "is_self"
    }
}

struct ActivityItem: Codable, Identifiable, Equatable {
    struct Reaction: Codable, Equatable {
        var emoji: String
        var count: Int
    }

    var id: String
    var userID: String
    var displayName: String
    var level: Int
    var avatarURL: String?
    var kind: String
    var summary: String
    var createdAt: Int
    var reactions: [Reaction]
    var isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, summary, level, reactions
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
        case isSelf = "is_self"
    }

    var icon: String {
        switch kind {
        case "level_up":    return "arrow.up.circle.fill"
        case "pr":          return "trophy.fill"
        case "achievement": return "rosette"
        case "quest":       return "checkmark.seal.fill"
        case "challenge":   return "flag.2.crossed.fill"
        case "raid_defeated": return "bolt.shield.fill"
        default:            return "figure.strengthtraining.traditional"
        }
    }

    var tint: Color {
        switch kind {
        case "level_up":    return .brandPurple
        case "pr":          return .brandYellow
        case "achievement": return .brandOrange
        case "quest":       return .brandGreen
        case "challenge":   return .brandOrange
        case "raid_defeated": return .brandOrange
        default:            return .brandBlue
        }
    }
}

struct Friend: Codable, Identifiable, Equatable {
    var userID: String
    var displayName: String
    var level: Int
    var xp: Int
    var currentStreak: Int
    var avatarURL: String?

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case level, xp
        case userID = "user_id"
        case displayName = "display_name"
        case currentStreak = "current_streak"
        case avatarURL = "avatar_url"
    }
}

struct Guild: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var motto: String?
    var ownerID: String
    var emblem: String?
    var memberCap: Int

    enum CodingKeys: String, CodingKey {
        case id, name, motto, emblem
        case ownerID = "owner_id"
        case memberCap = "member_cap"
    }
}

struct GuildMember: Codable, Identifiable, Equatable {
    var userID: String
    var displayName: String
    var level: Int
    var xp: Int
    var currentStreak: Int
    var role: String
    var avatarURL: String?

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case role, level, xp
        case userID = "user_id"
        case displayName = "display_name"
        case currentStreak = "current_streak"
        case avatarURL = "avatar_url"
    }
}

// MARK: - Talents

struct TalentBranch: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var color: String
    var icon: String

    var tint: Color {
        switch color {
        case "red":    return .brandOrange
        case "green":  return .brandGreen
        case "purple": return .brandPurple
        default:       return .brandBlue
        }
    }
}

struct TalentNode: Codable, Identifiable, Equatable {
    struct Requirement: Codable, Equatable {
        var id: String
        var rank: Int
    }
    var id: String
    var branch: String
    var tier: Int
    var maxRank: Int
    var requires: [Requirement]
    var name: String
    var icon: String
    var description: String

    enum CodingKeys: String, CodingKey {
        case id, branch, tier, requires, name, icon, description
        case maxRank = "max_rank"
    }
}

struct TalentTree: Codable, Equatable {
    var version: Int
    var branches: [TalentBranch]
    var nodes: [TalentNode]
}

/// The server's view of the player's talents. Validation is server-side; the
/// client mirrors the same rules purely to grey out buttons.
struct TalentState: Codable, Equatable {
    static let pointsPerTier = 3

    var tree: TalentTree
    var ranks: [String: Int]
    var unspent: Int
    var spent: Int

    func rank(of id: String) -> Int { ranks[id] ?? 0 }

    func spentInBranch(_ branch: String) -> Int {
        tree.nodes.filter { $0.branch == branch }.reduce(0) { $0 + rank(of: $1.id) }
    }

    /// nil when a point can be spent, otherwise the reason it cannot.
    func blocker(for node: TalentNode) -> String? {
        if unspent < 1 { return "No unspent points" }
        if rank(of: node.id) >= node.maxRank { return "Max rank" }
        let needed = (node.tier - 1) * Self.pointsPerTier
        if spentInBranch(node.branch) < needed { return "Spend \(needed) points in this branch first" }
        for req in node.requires where rank(of: req.id) < req.rank {
            let name = tree.nodes.first { $0.id == req.id }?.name ?? req.id
            return "Requires \(name) rank \(req.rank)"
        }
        return nil
    }
}

struct Challenge: Codable, Identifiable, Equatable {
    struct Standing: Codable, Identifiable, Equatable {
        var userID: String
        var displayName: String
        var level: Int
        var avatarURL: String?
        var score: Double
        var sessions: Int
        var rank: Int
        var isSelf: Bool

        var id: String { userID }

        enum CodingKeys: String, CodingKey {
            case level, score, sessions, rank
            case userID = "user_id"
            case displayName = "display_name"
            case avatarURL = "avatar_url"
            case isSelf = "is_self"
        }
    }

    var id: String
    var kind: String            // duel | guild
    var metric: String          // volume | workouts | streak
    var creatorID: String
    var opponentID: String?
    var guildID: String?
    var startsAt: Int
    var endsAt: Int
    var status: String          // pending | active | finished
    var winnerID: String?
    var isCreator: Bool
    var awaitingMe: Bool
    var standings: [Standing]

    enum CodingKeys: String, CodingKey {
        case id, kind, metric, status, standings
        case creatorID = "creator_id"
        case opponentID = "opponent_id"
        case guildID = "guild_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case winnerID = "winner_id"
        case isCreator = "is_creator"
        case awaitingMe = "awaiting_me"
    }

    var isDuel: Bool { kind == "duel" }
    var me: Standing? { standings.first { $0.isSelf } }
    var them: Standing? { standings.first { !$0.isSelf } }
    var didWin: Bool { winnerID != nil && winnerID == me?.userID }

    var metricLabel: String {
        switch metric {
        case "workouts": return "Workouts"
        case "streak":   return "Streak"
        default:         return "Volume"
        }
    }

    var metricIcon: String {
        switch metric {
        case "workouts": return "figure.strengthtraining.traditional"
        case "streak":   return "flame.fill"
        default:         return "scalemass.fill"
        }
    }

    func format(_ score: Double) -> String {
        switch metric {
        case "workouts": return "\(Int(score))"
        case "streak":   return "\(Int(score))d"
        default:         return PlayerCardView.compactNumber(score) + " lb"
        }
    }

    var timeRemaining: String {
        let secs = endsAt - Int(Date().timeIntervalSince1970)
        if secs <= 0 { return "Ended" }
        if secs < 3600 { return "\(max(1, secs / 60))m left" }
        if secs < 86400 { return "\(secs / 3600)h left" }
        return "\(secs / 86400)d left"
    }
}

struct Quest: Codable, Identifiable, Equatable {
    var id: String
    var questKey: String
    var kind: String            // daily | weekly
    var title: String
    var description: String
    var icon: String
    var metric: String?
    var target: Double
    var progress: Double
    var xpReward: Int
    var expiresAt: Int?
    var completedAt: Int?
    var claimed: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, title, description, icon, metric, target, progress, claimed
        case questKey = "quest_key"
        case xpReward = "xp_reward"
        case expiresAt = "expires_at"
        case completedAt = "completed_at"
    }

    var fraction: Double { target > 0 ? min(1, max(0, progress / target)) : 0 }
    var isComplete: Bool { completedAt != nil }
    var isClaimable: Bool { isComplete && !claimed }
    var isDaily: Bool { kind == "daily" }

    /// "3,200 / 5,000" style progress label, dropping decimals for counts.
    var progressLabel: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        let p = f.string(from: NSNumber(value: progress.rounded(.down))) ?? "0"
        let t = f.string(from: NSNumber(value: target)) ?? "0"
        return "\(p) / \(t)"
    }
}

struct Achievement: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var desc: String
    var rarity: String          // common | rare | epic | legendary
    var xp: Int
    var icon: String
    var unlocked: Bool
    var unlockedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, desc, rarity, xp, icon, unlocked
        case unlockedAt = "unlocked_at"
    }

    var rarityColor: Color {
        switch rarity {
        case "rare":      return .brandBlue
        case "epic":      return .brandPurple
        case "legendary": return .brandOrange
        default:          return .gray
        }
    }
}

// MARK: Guild raids

struct RaidBoss: Codable, Equatable {
    var id: String
    var name: String
    var flavor: String?
    var symbol: String
    var gradient: [String]
    var rewardXP: Int
    var rewardTitle: String?
    var rewardCosmetic: String?

    enum CodingKeys: String, CodingKey {
        case id, name, flavor, symbol, gradient
        case rewardXP = "reward_xp"
        case rewardTitle = "reward_title"
        case rewardCosmetic = "reward_cosmetic"
    }
}

struct RaidContributor: Codable, Identifiable, Equatable {
    var rank: Int
    var userID: String
    var displayName: String
    var level: Int
    var avatarURL: String?
    var damage: Int
    var hits: Int
    var isSelf: Bool

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case rank, level, damage, hits
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case isSelf = "is_self"
    }
}

/// This week's boss for the player's guild, as served by GET fitness/raid.
struct RaidState: Codable, Equatable {
    var id: String
    var guildID: String
    var weekStart: Int
    var endsAt: Int
    var secondsLeft: Int
    var boss: RaidBoss
    var hp: Int
    var damageDone: Int
    var hpRemaining: Int
    var defeated: Bool
    var defeatedAt: Int?
    var memberCount: Int
    var contributors: [RaidContributor]
    var myDamage: Int
    var myHits: Int

    enum CodingKeys: String, CodingKey {
        case id, boss, hp, defeated, contributors
        case guildID = "guild_id"
        case weekStart = "week_start"
        case endsAt = "ends_at"
        case secondsLeft = "seconds_left"
        case damageDone = "damage_done"
        case hpRemaining = "hp_remaining"
        case defeatedAt = "defeated_at"
        case memberCount = "member_count"
        case myDamage = "my_damage"
        case myHits = "my_hits"
    }

    /// 0–1 share of the boss's hp still standing.
    var hpFraction: Double {
        guard hp > 0 else { return 0 }
        return min(1, max(0, Double(hp - damageDone) / Double(hp)))
    }
}

/// What one sync did to the boss; comes back inside the sync response.
struct RaidHit: Codable, Equatable {
    var bossID: String
    var bossName: String
    var damage: Int
    var hp: Int
    var damageDone: Int
    var defeated: Bool
    var justDefeated: Bool
    var rewardXP: Int

    enum CodingKeys: String, CodingKey {
        case damage, hp, defeated
        case bossID = "boss_id"
        case bossName = "boss_name"
        case damageDone = "damage_done"
        case justDefeated = "just_defeated"
        case rewardXP = "reward_xp"
    }
}


// MARK: - Service

@MainActor
final class GameProfileService: ObservableObject {
    static let shared = GameProfileService()

    @Published private(set) var profile: FitnessProfile?
    @Published private(set) var feed: [ActivityItem] = []
    @Published private(set) var leaderboard: [LeaderboardEntry] = []
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var incomingRequests: [Friend] = []
    @Published private(set) var guild: Guild?
    @Published private(set) var guildMembers: [GuildMember] = []
    @Published private(set) var raid: RaidState?
    @Published private(set) var isLoadingRaid = false
    /// Set when a sync lands damage on the guild boss; RaidCard shows it as a toast.
    @Published var lastRaidHit: RaidHit?
    @Published private(set) var talents: TalentState?
    @Published private(set) var activeChallenges: [Challenge] = []
    @Published private(set) var pendingChallenges: [Challenge] = []
    @Published private(set) var finishedChallenges: [Challenge] = []

    @Published private(set) var dailyQuests: [Quest] = []
    @Published private(set) var weeklyQuests: [Quest] = []
    @Published private(set) var achievements: [Achievement] = []

    /// Set when a sync unlocks achievements, so the UI can celebrate once.
    @Published var pendingAchievements: [String] = []
    /// The quest most recently claimed, for the claim animation.
    @Published var lastClaimedQuest: Quest?

    @Published private(set) var isSyncing = false
    @Published var lastError: String?

    /// Set when a sync produces a level-up, so the UI can celebrate once.
    @Published var pendingLevelUps: Int = 0
    @Published var lastXPGain: Int = 0

    private let auth = BatesAIAuth.shared
    private let defaults = UserDefaults.standard
    private let pendingKey = "pendingWorkoutSync"
    private let sinceKey = "lastSyncTimestamp"

    private var lastSyncedAt: Int {
        get { defaults.integer(forKey: sinceKey) }
        set { defaults.set(newValue, forKey: sinceKey) }
    }

    /// Sessions recorded locally but not yet accepted by the server.
    private var pending: [SyncSession] {
        get {
            guard let data = defaults.data(forKey: pendingKey),
                  let decoded = try? JSONDecoder().decode([SyncSession].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: pendingKey)
        }
    }

    var pendingCount: Int { pending.count }

    private init() {}

    // MARK: Recording

    /// Queue a finished workout for upload. Safe to call while offline or signed
    /// out — it flushes on the next successful sync.
    func recordWorkout(
        id: String = UUID().uuidString,
        name: String?,
        programID: String? = nil,
        performedAt: Date = Date(),
        durationSecs: Int,
        totalVolume: Double,
        totalReps: Int,
        exercises: [SyncExercise]? = nil
    ) {
        var queue = pending
        // Replace rather than append if this id is already queued, so an edited
        // session doesn't upload twice.
        let session = SyncSession(
            id: id,
            performedAt: Int(performedAt.timeIntervalSince1970),
            name: name,
            programID: programID,
            durationSecs: durationSecs,
            totalVolume: totalVolume,
            totalReps: totalReps,
            xpEarned: nil,
            clientRev: (queue.first { $0.id == id }?.clientRev ?? 0) + 1,
            exercises: exercises
        )
        queue.removeAll { $0.id == id }
        queue.append(session)
        pending = queue

        Task { await sync() }
    }

    // MARK: Sync

    private struct SyncResponse: Decodable {
        let accepted: [String]
        let xpGained: Int
        let levelsGained: Int
        let serverTime: Int
        let profile: FitnessProfile
        let achievementsUnlocked: [String]?
        let raid: RaidHit?

        enum CodingKeys: String, CodingKey {
            case accepted, profile, raid
            case xpGained = "xp_gained"
            case levelsGained = "levels_gained"
            case serverTime = "server_time"
            case achievementsUnlocked = "achievements_unlocked"
        }
    }

    @discardableResult
    func sync() async -> Bool {
        guard auth.isSignedIn, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }

        let outbound = pending
        // Fresh Health numbers ride along so server quests (Step Count) can use them.
        await HealthKitManager.shared.refreshToday()
        do {
            var body: [String: Any] = [
                "since": lastSyncedAt,
                "sessions": outbound.map { session -> [String: Any] in
                    var dict: [String: Any] = [
                        "id": session.id,
                        "performed_at": session.performedAt,
                        "duration_secs": session.durationSecs,
                        "total_volume": session.totalVolume,
                        "total_reps": session.totalReps,
                        "client_rev": session.clientRev,
                    ]
                    if let name = session.name { dict["name"] = name }
                    if let programID = session.programID { dict["program_id"] = programID }
                    if let exercises = session.exercises, !exercises.isEmpty {
                        dict["payload"] = [
                            "exercises": exercises.map { exercise -> [String: Any] in
                                [
                                    "name": exercise.name,
                                    "sets": exercise.sets.map { ["reps": $0.reps, "weight": $0.weight] },
                                ]
                            },
                        ]
                    }
                    return dict
                },
            ]
            for (key, value) in HealthKitManager.shared.syncFields { body[key] = value }

            let response: SyncResponse = try await auth.request(
                "fitness/sync", method: "POST", body: body
            )

            // Only drop what the server confirmed; anything else stays queued.
            let accepted = Set(response.accepted)
            pending = pending.filter { !accepted.contains($0.id) }
            lastSyncedAt = response.serverTime

            profile = response.profile
            if response.levelsGained > 0 { pendingLevelUps = response.levelsGained }
            if response.xpGained > 0 { lastXPGain = response.xpGained }
            if let unlocked = response.achievementsUnlocked, !unlocked.isEmpty {
                pendingAchievements = unlocked
            }
            if let hit = response.raid, hit.damage > 0 {
                lastRaidHit = hit
                await loadRaid()   // the boss moved; let the HP bar animate down
            }
            // A workout moves quest progress; refresh the board if anything went up.
            if !outbound.isEmpty { await loadQuests() }

            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Loading

    private struct ProfileResponse: Decodable { let profile: FitnessProfile }
    private struct FeedResponse: Decodable { let items: [ActivityItem] }
    private struct LeaderboardResponse: Decodable { let entries: [LeaderboardEntry] }
    private struct FriendsResponse: Decodable {
        let friends: [Friend]
        let incomingRequests: [Friend]
        enum CodingKeys: String, CodingKey {
            case friends
            case incomingRequests = "incoming_requests"
        }
    }
    private struct GuildResponse: Decodable {
        let guild: Guild?
        let members: [GuildMember]
    }

    /// Everything the profile and social tabs need, in one pass at launch.
    func loadAll() async {
        guard auth.isSignedIn else { return }
        await sync()
        async let profileTask: Void = loadProfile()
        async let feedTask: Void = loadFeed()
        async let friendsTask: Void = loadFriends()
        async let guildTask: Void = loadGuild()
        async let challengesTask: Void = loadChallenges()
        async let questTask: Void = loadQuests()
        _ = await (profileTask, feedTask, friendsTask, guildTask, challengesTask, questTask)
    }

    // MARK: Quests & achievements

    private struct QuestsResponse: Decodable {
        let daily: [Quest]
        let weekly: [Quest]
    }
    private struct ClaimResponse: Decodable {
        let xpGained: Int
        let levelsGained: Int
        let quest: Quest
        enum CodingKeys: String, CodingKey {
            case quest
            case xpGained = "xp_gained"
            case levelsGained = "levels_gained"
        }
    }
    private struct AchievementsResponse: Decodable { let achievements: [Achievement] }

    var claimableQuestCount: Int {
        (dailyQuests + weeklyQuests).filter(\.isClaimable).count
    }

    func loadQuests() async {
        guard auth.isSignedIn else { return }
        do {
            let response: QuestsResponse = try await auth.request("fitness/quests", method: "GET")
            dailyQuests = response.daily
            weeklyQuests = response.weekly
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Claims a completed quest. XP is paid by the server on claim, so the
    /// profile is refreshed afterwards to pick up the new total.
    func claimQuest(_ quest: Quest) async {
        guard auth.isSignedIn, quest.isClaimable else { return }
        do {
            let response: ClaimResponse = try await auth.request(
                "fitness/quests/\(quest.id)/claim", method: "POST", body: [:]
            )
            lastClaimedQuest = response.quest
            if response.xpGained > 0 { lastXPGain = response.xpGained }
            if response.levelsGained > 0 { pendingLevelUps = response.levelsGained }
            replaceQuest(response.quest)
            await loadProfile()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func replaceQuest(_ quest: Quest) {
        if let i = dailyQuests.firstIndex(where: { $0.id == quest.id }) { dailyQuests[i] = quest }
        if let i = weeklyQuests.firstIndex(where: { $0.id == quest.id }) { weeklyQuests[i] = quest }
    }

    func loadAchievements() async {
        guard auth.isSignedIn else { return }
        do {
            let response: AchievementsResponse = try await auth.request("fitness/achievements", method: "GET")
            achievements = response.achievements
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadProfile() async {
        guard auth.isSignedIn else { return }
        do {
            let response: ProfileResponse = try await auth.request("fitness/profile", method: "GET")
            profile = response.profile
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateProfile(_ fields: [String: Any]) async {
        guard auth.isSignedIn else { return }
        do {
            let response: ProfileResponse = try await auth.request(
                "fitness/profile", method: "PUT", body: fields
            )
            profile = response.profile
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadFeed() async {
        guard auth.isSignedIn else { return }
        do {
            let response: FeedResponse = try await auth.request("fitness/feed", method: "GET")
            feed = response.items
        } catch {
            lastError = error.localizedDescription
        }
    }

    func react(to activityID: String, emoji: String) async {
        guard auth.isSignedIn else { return }
        _ = try? await auth.requestRaw(
            "fitness/feed/\(activityID)/react", method: "POST",
            token: auth.token, body: ["emoji": emoji]
        )
        await loadFeed()
    }

    func loadLeaderboard(scope: String = "global", metric: String = "xp") async {
        guard auth.isSignedIn else { return }
        do {
            let response: LeaderboardResponse = try await auth.request(
                "fitness/leaderboard?scope=\(scope)&metric=\(metric)", method: "GET"
            )
            leaderboard = response.entries
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadFriends() async {
        guard auth.isSignedIn else { return }
        do {
            let response: FriendsResponse = try await auth.request("fitness/friends", method: "GET")
            friends = response.friends
            incomingRequests = response.incomingRequests
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// `query` is an email or a friend code; the server tells them apart.
    /// Returns an error message to show, or nil on success.
    @discardableResult
    func requestFriend(query: String) async -> String? {
        guard auth.isSignedIn else { return "Not signed in." }
        var failure: String?
        do {
            _ = try await auth.requestRaw(
                "fitness/friends/request", method: "POST",
                token: auth.token, body: ["query": query.trimmingCharacters(in: .whitespaces)]
            )
        } catch {
            failure = error.localizedDescription
        }
        await loadFriends()
        return failure
    }

    func requestFriend(email: String) async { _ = await requestFriend(query: email) }

    func respondToFriendRequest(userID: String, accept: Bool) async {
        guard auth.isSignedIn else { return }
        _ = try? await auth.requestRaw(
            "fitness/friends/respond", method: "POST",
            token: auth.token, body: ["user_id": userID, "accept": accept]
        )
        await loadFriends()
    }

    func loadGuild() async {
        guard auth.isSignedIn else { return }
        do {
            let response: GuildResponse = try await auth.request("fitness/guild", method: "GET")
            guild = response.guild
            guildMembers = response.members
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createGuild(name: String, motto: String) async {
        guard auth.isSignedIn else { return }
        _ = try? await auth.requestRaw(
            "fitness/guild", method: "POST",
            token: auth.token, body: ["name": name, "motto": motto]
        )
        await loadGuild()
    }

    func leaveGuild() async {
        guard auth.isSignedIn else { return }
        _ = try? await auth.requestRaw(
            "fitness/guild/leave", method: "POST", token: auth.token, body: nil
        )
        raid = nil
        await loadGuild()
    }

    // MARK: Guild raid

    private struct RaidResponse: Decodable { let raid: RaidState? }

    /// This week's boss for the caller's guild. `raid` stays nil without a guild.
    func loadRaid() async {
        guard auth.isSignedIn else { return }
        isLoadingRaid = true
        defer { isLoadingRaid = false }
        do {
            let response: RaidResponse = try await auth.request("fitness/raid", method: "GET")
            raid = response.raid
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Talents

    func loadTalents() async {
        guard auth.isSignedIn else { return }
        do {
            talents = try await auth.request("fitness/talents", method: "GET")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Spends one point. Returns the server's rejection reason, or nil on success.
    @discardableResult
    func spendTalent(_ talentID: String) async -> String? {
        guard auth.isSignedIn else { return "Not signed in" }
        do {
            talents = try await auth.request(
                "fitness/talents/spend", method: "POST", body: ["talent_id": talentID]
            )
            await loadProfile()
            return nil
        } catch {
            lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

    func respecTalents() async {
        guard auth.isSignedIn else { return }
        do {
            talents = try await auth.request("fitness/talents/respec", method: "POST", body: [:])
            await loadProfile()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Challenges

    private struct ChallengesResponse: Decodable {
        let pending: [Challenge]
        let active: [Challenge]
        let finished: [Challenge]
    }

    func loadChallenges() async {
        guard auth.isSignedIn else { return }
        do {
            let response: ChallengesResponse = try await auth.request("fitness/challenges", method: "GET")
            pendingChallenges = response.pending
            activeChallenges = response.active
            finishedChallenges = response.finished
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Returns the server's error message on failure, nil on success.
    @discardableResult
    func createChallenge(kind: String, metric: String, opponentUserID: String?, days: Int) async -> String? {
        guard auth.isSignedIn else { return "Sign in first." }
        var body: [String: Any] = ["kind": kind, "metric": metric, "days": days]
        if let opponentUserID { body["opponent_user_id"] = opponentUserID }
        do {
            _ = try await auth.requestRaw("fitness/challenges", method: "POST", token: auth.token, body: body)
            await loadChallenges()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func respondToChallenge(id: String, accept: Bool) async {
        guard auth.isSignedIn else { return }
        _ = try? await auth.requestRaw(
            "fitness/challenges/\(id)/\(accept ? "accept" : "decline")",
            method: "POST", token: auth.token, body: nil
        )
        await loadChallenges()
    }

    /// Clears everything on sign-out. The pending queue is deliberately kept:
    /// if the same person signs back in, their unsynced workouts still upload.
    func reset() {
        profile = nil
        feed = []
        leaderboard = []
        friends = []
        incomingRequests = []
        guild = nil
        guildMembers = []
        activeChallenges = []
        pendingChallenges = []
        finishedChallenges = []
        talents = nil
        dailyQuests = []
        weeklyQuests = []
        achievements = []
        pendingAchievements = []
        lastClaimedQuest = nil
        raid = nil
        lastRaidHit = nil
    }
}
