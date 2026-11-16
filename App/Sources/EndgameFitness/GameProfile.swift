//
//  GameProfile.swift
//  Endgame Fitness
//
//  The player's server-backed identity: level, XP, streak, talents, friends,
//  guild, seasons and the activity feed. This is the layer that turns a
//  workout log into a game with other people in it. Wire format:
//  Docs/API_V2.md.
//
//  Design notes:
//   • The server is authoritative for anything that affects rank. The client
//     uploads what happened (sets, reps, duration); the server decides the XP.
//     A patched client can lie about a workout but it cannot mint a level.
//   • Sync is offline-first. Sessions queue locally and flush when a connection
//     and a signed-in user are both available, so a workout in a basement gym
//     is never lost.
//   • Everything stored on the device is scoped to the signed-in account, so a
//     shared iPad never uploads one person's workouts into another's profile.
//

import Foundation
import SwiftUI

// MARK: - Lenient decoding

/// D1 hands back 0/1 for booleans and sometimes JSON-in-a-string for objects;
/// older servers omit newer fields entirely. These helpers keep one odd field
/// from failing a whole screen.
extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return Int(value) }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value) ?? Double(value).flatMap { $0.isFinite ? Int($0) : nil }
        }
        if let value = try? decode(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }

    func flexDouble(_ key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func flexBool(_ key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return nil
    }

    /// A list of strings, or a JSON string holding one.
    func flexStrings(_ key: Key) -> [String] {
        if let value = try? decode([String].self, forKey: key) { return value }
        if let raw = try? decode(String.self, forKey: key),
           let data = raw.data(using: .utf8),
           let value = try? JSONDecoder().decode([String].self, from: data) {
            return value
        }
        return []
    }

    /// `avatar_config` arrives as an object (v2) or a JSON string (v1).
    func flexAvatar(_ key: Key) -> AvatarBodyProfile? {
        if (try? decodeNil(forKey: key)) ?? true { return nil }
        if let config = try? decode(AvatarBodyProfile.self, forKey: key) { return config }
        if let raw = try? decode(String.self, forKey: key),
           let data = raw.data(using: .utf8),
           let config = try? JSONDecoder().decode(AvatarBodyProfile.self, from: data) {
            return config
        }
        return nil
    }
}

// MARK: - Profile

struct FitnessProfile: Decodable, Equatable {
    /// Share of the last 28 days' training by style, each 0–1 (API_V2 §2.4).
    struct ClassAffinity: Decodable, Equatable {
        var strength: Double
        var endurance: Double
        var mobility: Double
        var athletic: Double

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            strength = c.flexDouble(.strength) ?? 0
            endurance = c.flexDouble(.endurance) ?? 0
            mobility = c.flexDouble(.mobility) ?? 0
            athletic = c.flexDouble(.athletic) ?? 0
        }

        enum CodingKeys: String, CodingKey { case strength, endurance, mobility, athletic }
    }

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
    /// The equipped aura, owned by the server (API_V2 §7).
    var cosmetic: String?
    var isPublic: Bool
    var friendCode: String?

    // v2 (API_V2 §2.1). Defaults keep a v1 server working.
    var bio: String?
    var heroClass: String?
    var classAffinity: ClassAffinity?
    var earnedTitles: [String]
    var earnedCosmetics: [String]
    var streakFreezes: Int
    var streakAlive: Bool
    var seasonXP: Int
    var onboarded: Bool?
    var avatarConfig: AvatarBodyProfile?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case level, xp, prestige, units, title, cosmetic, bio, onboarded
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
        case heroClass = "hero_class"
        case classAffinity = "class_affinity"
        case earnedTitles = "earned_titles"
        case earnedCosmetics = "earned_cosmetics"
        case streakFreezes = "streak_freezes"
        case streakAlive = "streak_alive"
        case seasonXP = "season_xp"
        case avatarConfig = "avatar_config"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        displayName = c.flexString(.displayName) ?? "Athlete"
        avatarURL = c.flexString(.avatarURL)
        level = c.flexInt(.level) ?? 1
        xp = c.flexInt(.xp) ?? 0
        xpForNextLevel = c.flexInt(.xpForNextLevel) ?? 0
        xpForCurrentLevel = c.flexInt(.xpForCurrentLevel) ?? 0
        talentPoints = c.flexInt(.talentPoints) ?? 0
        prestige = c.flexInt(.prestige) ?? 0
        currentStreak = c.flexInt(.currentStreak) ?? 0
        longestStreak = c.flexInt(.longestStreak) ?? 0
        lastWorkoutDate = c.flexString(.lastWorkoutDate)
        totalWorkouts = c.flexInt(.totalWorkouts) ?? 0
        totalVolume = c.flexDouble(.totalVolume) ?? 0
        totalReps = c.flexInt(.totalReps) ?? 0
        trainingGoal = c.flexString(.trainingGoal)
        experienceLevel = c.flexString(.experienceLevel)
        equipmentLevel = c.flexString(.equipmentLevel)
        bodyWeight = c.flexDouble(.bodyWeight)
        heightInches = c.flexDouble(.heightInches)
        birthYear = c.flexInt(.birthYear)
        units = c.flexString(.units) ?? "lb"
        title = c.flexString(.title)
        cosmetic = c.flexString(.cosmetic)
        isPublic = c.flexBool(.isPublic) ?? false
        friendCode = c.flexString(.friendCode)
        bio = c.flexString(.bio)
        heroClass = c.flexString(.heroClass)
        classAffinity = try? c.decode(ClassAffinity.self, forKey: .classAffinity)
        earnedTitles = c.flexStrings(.earnedTitles)
        earnedCosmetics = c.flexStrings(.earnedCosmetics)
        streakFreezes = c.flexInt(.streakFreezes) ?? 0
        streakAlive = c.flexBool(.streakAlive) ?? true
        seasonXP = c.flexInt(.seasonXP) ?? 0
        onboarded = c.flexBool(.onboarded)
        avatarConfig = c.flexAvatar(.avatarConfig)
    }

    /// Server-side onboarding answers exist (API_V2 §2.1 `onboarded`; a v1
    /// server is judged by whether it has a training goal).
    var isOnboarded: Bool { onboarded ?? (trainingGoal != nil) }

    var hero: HeroClass { HeroClass(serverValue: heroClass) }

    /// 0–1 progress through the current level, for the XP bar.
    var levelProgress: Double {
        let span = xpForNextLevel - xpForCurrentLevel
        guard span > 0 else { return 0 }
        return min(1, max(0, Double(xp - xpForCurrentLevel) / Double(span)))
    }

    var xpIntoLevel: Int { max(0, xp - xpForCurrentLevel) }
    var xpNeededForLevel: Int { max(1, xpForNextLevel - xpForCurrentLevel) }

    /// The equipped title, or the rank band for the level. The bands are wide
    /// enough to feel earned, because this is the thing people screenshot.
    var rankTitle: String {
        if let title, !title.isEmpty { return title }
        return Self.rankBand(for: level)
    }

    static func rankBand(for level: Int) -> String {
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

    var rankColor: Color { Self.rankColor(for: level) }

    static func rankColor(for level: Int) -> Color {
        switch level {
        case ..<10:   return .gray
        case 10..<30: return .brandGreen
        case 30..<60: return .brandBlue
        case 60..<100: return .brandPurple
        default:      return .brandOrange
        }
    }
}

/// The class the server derives from the last 28 days of training (API_V2 §2.4).
enum HeroClass: String, CaseIterable {
    case recruit, juggernaut, ranger, monk, striker, paladin

    init(serverValue: String?) {
        self = HeroClass(rawValue: (serverValue ?? "").lowercased()) ?? .recruit
    }

    var name: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .recruit:    return "star.circle"
        case .juggernaut: return "figure.strengthtraining.traditional"
        case .ranger:     return "figure.run"
        case .monk:       return "figure.mind.and.body"
        case .striker:    return "bolt.fill"
        case .paladin:    return "shield.lefthalf.filled"
        }
    }

    var tint: Color {
        switch self {
        case .recruit:    return .gray
        case .juggernaut: return .brandOrange
        case .ranger:     return .brandGreen
        case .monk:       return .brandBlue
        case .striker:    return .brandYellow
        case .paladin:    return .brandPurple
        }
    }

    /// Plain description of how the class was earned.
    var blurb: String {
        switch self {
        case .recruit:    return "Sync 3 workouts and your training style picks your class."
        case .juggernaut: return "Most of your last 28 days was strength training."
        case .ranger:     return "Most of your last 28 days was cardio."
        case .monk:       return "Mobility and stretching make up a big share of your training."
        case .striker:    return "Plyometrics and explosive work make up a big share of your training."
        case .paladin:    return "A balanced mix of strength, cardio and mobility."
        }
    }
}

/// Client-side copies of the server's profile rules (API_V2 §2.2), so mistakes
/// show up while typing. The server stays the authority.
enum ProfileRules {
    static let displayNameRange = 2...24
    static let bioLimit = 160
    static let commentLimit = 280

    /// nil when the name is acceptable, otherwise what is wrong with it.
    static func displayNameProblem(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count < displayNameRange.lowerBound { return "At least 2 characters." }
        if name.count > displayNameRange.upperBound { return "24 characters at most." }
        let allowed = name.range(of: "^[\\p{L}\\p{N} _\\-.']+$", options: .regularExpression) != nil
        return allowed ? nil : "Letters, numbers, spaces and _ - . ' only."
    }

    static func bioProblem(_ raw: String) -> String? {
        raw.count > bioLimit ? "\(bioLimit) characters at most." : nil
    }
}

// MARK: - Leaderboard

struct LeaderboardEntry: Decodable, Identifiable, Equatable {
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
    var cosmetic: String?
    var seasonXP: Int?
    var heroClass: String?

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case rank, level, xp, title, cosmetic
        case userID = "user_id"
        case displayName = "display_name"
        case currentStreak = "current_streak"
        case totalVolume = "total_volume"
        case totalWorkouts = "total_workouts"
        case avatarURL = "avatar_url"
        case isSelf = "is_self"
        case seasonXP = "season_xp"
        case heroClass = "hero_class"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        rank = c.flexInt(.rank) ?? 0
        displayName = c.flexString(.displayName) ?? "Athlete"
        level = c.flexInt(.level) ?? 1
        xp = c.flexInt(.xp) ?? 0
        currentStreak = c.flexInt(.currentStreak) ?? 0
        totalVolume = c.flexDouble(.totalVolume) ?? 0
        totalWorkouts = c.flexInt(.totalWorkouts) ?? 0
        title = c.flexString(.title)
        avatarURL = c.flexString(.avatarURL)
        isSelf = c.flexBool(.isSelf) ?? false
        cosmetic = c.flexString(.cosmetic)
        seasonXP = c.flexInt(.seasonXP)
        heroClass = c.flexString(.heroClass)
    }
}

// MARK: - Feed

struct ActivityItem: Decodable, Identifiable, Equatable {
    struct Reaction: Decodable, Equatable {
        var emoji: String
        var count: Int
        /// The signed-in player reacted with this emoji.
        var mine: Bool

        init(emoji: String, count: Int, mine: Bool) {
            self.emoji = emoji
            self.count = count
            self.mine = mine
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            emoji = try c.decode(String.self, forKey: .emoji)
            count = c.flexInt(.count) ?? 0
            mine = c.flexBool(.mine) ?? false
        }

        enum CodingKeys: String, CodingKey { case emoji, count, mine }
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
    var commentCount: Int
    var authorCosmetic: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, summary, level, reactions
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
        case isSelf = "is_self"
        case commentCount = "comment_count"
        case authorCosmetic = "author_cosmetic"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.flexString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "feed item without id"))
        }
        self.id = id
        userID = c.flexString(.userID) ?? ""
        displayName = c.flexString(.displayName) ?? "Athlete"
        level = c.flexInt(.level) ?? 1
        avatarURL = c.flexString(.avatarURL)
        kind = c.flexString(.kind) ?? "workout"
        summary = c.flexString(.summary) ?? ""
        createdAt = c.flexInt(.createdAt) ?? 0
        reactions = (try? c.decode([Reaction].self, forKey: .reactions)) ?? []
        isSelf = c.flexBool(.isSelf) ?? false
        commentCount = c.flexInt(.commentCount) ?? 0
        authorCosmetic = c.flexString(.authorCosmetic)
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

    /// Flips the player's own reaction locally, for an instant response while
    /// the server confirms (POST react toggles, API_V2 §4).
    mutating func toggleReaction(_ emoji: String) {
        if let i = reactions.firstIndex(where: { $0.emoji == emoji }) {
            if reactions[i].mine {
                reactions[i].mine = false
                reactions[i].count -= 1
                if reactions[i].count <= 0 { reactions.remove(at: i) }
            } else {
                reactions[i].mine = true
                reactions[i].count += 1
            }
        } else {
            reactions.append(Reaction(emoji: emoji, count: 1, mine: true))
        }
    }
}

struct FeedComment: Decodable, Identifiable, Equatable {
    var id: String
    var userID: String
    var displayName: String
    var level: Int
    var text: String
    var createdAt: Int
    var isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case id, level, text
        case userID = "user_id"
        case displayName = "display_name"
        case createdAt = "created_at"
        case isSelf = "is_self"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        userID = c.flexString(.userID) ?? ""
        displayName = c.flexString(.displayName) ?? "Athlete"
        level = c.flexInt(.level) ?? 1
        text = c.flexString(.text) ?? ""
        createdAt = c.flexInt(.createdAt) ?? Int(Date().timeIntervalSince1970)
        isSelf = c.flexBool(.isSelf) ?? false
    }
}

// MARK: - Friends, players, safety

struct Friend: Decodable, Identifiable, Equatable {
    var userID: String
    var displayName: String
    var level: Int
    var xp: Int
    var currentStreak: Int
    var avatarURL: String?
    var cosmetic: String?

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case level, xp, cosmetic
        case userID = "user_id"
        case displayName = "display_name"
        case currentStreak = "current_streak"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        displayName = c.flexString(.displayName) ?? "Athlete"
        level = c.flexInt(.level) ?? 1
        xp = c.flexInt(.xp) ?? 0
        currentStreak = c.flexInt(.currentStreak) ?? 0
        avatarURL = c.flexString(.avatarURL)
        cosmetic = c.flexString(.cosmetic)
    }
}

/// Someone else's public player card (API_V2 §2.6).
struct PublicPlayer: Decodable, Identifiable, Equatable {
    struct GuildRef: Decodable, Equatable {
        var id: String
        var name: String
        var emblem: String?
    }

    var userID: String
    var displayName: String
    var level: Int
    var xp: Int
    var title: String?
    var heroClass: String?
    var currentStreak: Int
    var totalWorkouts: Int
    var avatarConfig: AvatarBodyProfile?
    var avatarURL: String?
    var guild: GuildRef?
    var achievementsCount: Int
    var isFriend: Bool
    var isSelf: Bool
    var isBlocked: Bool
    var cosmetic: String?
    var bio: String?

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case level, xp, title, guild, cosmetic, bio
        case userID = "user_id"
        case displayName = "display_name"
        case heroClass = "hero_class"
        case currentStreak = "current_streak"
        case totalWorkouts = "total_workouts"
        case avatarConfig = "avatar_config"
        case avatarURL = "avatar_url"
        case achievementsCount = "achievements_count"
        case isFriend = "is_friend"
        case isSelf = "is_self"
        case isBlocked = "is_blocked"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        displayName = c.flexString(.displayName) ?? "Athlete"
        level = c.flexInt(.level) ?? 1
        xp = c.flexInt(.xp) ?? 0
        title = c.flexString(.title)
        heroClass = c.flexString(.heroClass)
        currentStreak = c.flexInt(.currentStreak) ?? 0
        totalWorkouts = c.flexInt(.totalWorkouts) ?? 0
        avatarConfig = c.flexAvatar(.avatarConfig)
        avatarURL = c.flexString(.avatarURL)
        guild = try? c.decode(GuildRef.self, forKey: .guild)
        achievementsCount = c.flexInt(.achievementsCount) ?? 0
        isFriend = c.flexBool(.isFriend) ?? false
        isSelf = c.flexBool(.isSelf) ?? false
        isBlocked = c.flexBool(.isBlocked) ?? false
        cosmetic = c.flexString(.cosmetic)
        bio = c.flexString(.bio)
    }

    var rankTitle: String {
        if let title, !title.isEmpty { return title }
        return FitnessProfile.rankBand(for: level)
    }

    var hero: HeroClass { HeroClass(serverValue: heroClass) }
}

struct BlockedUser: Decodable, Identifiable, Equatable {
    var userID: String
    var displayName: String
    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        displayName = c.flexString(.displayName) ?? "Player"
    }
}

/// What can be reported to the moderators (API_V2 §4).
enum ReportTarget: String {
    case user
    case feedItem = "feed_item"
    case comment
    case guild

    var noun: String {
        switch self {
        case .user:     return "player"
        case .feedItem: return "post"
        case .comment:  return "comment"
        case .guild:    return "guild"
        }
    }
}

/// A player to open a profile sheet for, from anywhere a name is shown.
struct PlayerRef: Identifiable, Equatable {
    let id: String
    var displayName: String
}

// MARK: - Guilds

struct Guild: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var motto: String?
    var ownerID: String
    var emblem: String?
    var memberCap: Int
    /// Shown to members only (API_V2 §5).
    var inviteCode: String?
    var isOpen: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, motto, emblem
        case ownerID = "owner_id"
        case memberCap = "member_cap"
        case inviteCode = "invite_code"
        case isOpen = "is_open"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.flexString(.name) ?? "Guild"
        motto = c.flexString(.motto)
        ownerID = c.flexString(.ownerID) ?? ""
        emblem = c.flexString(.emblem)
        memberCap = c.flexInt(.memberCap) ?? 50
        inviteCode = c.flexString(.inviteCode)
        isOpen = c.flexBool(.isOpen) ?? false
    }
}

struct GuildMember: Decodable, Identifiable, Equatable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        displayName = c.flexString(.displayName) ?? "Athlete"
        level = c.flexInt(.level) ?? 1
        xp = c.flexInt(.xp) ?? 0
        currentStreak = c.flexInt(.currentStreak) ?? 0
        role = c.flexString(.role) ?? "member"
        avatarURL = c.flexString(.avatarURL)
    }
}

/// A guild in the discovery list (API_V2 §5).
struct GuildSummary: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var motto: String?
    var emblem: String?
    var memberCount: Int
    var isOpen: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, motto, emblem
        case memberCount = "member_count"
        case isOpen = "is_open"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.flexString(.name) ?? "Guild"
        motto = c.flexString(.motto)
        emblem = c.flexString(.emblem)
        memberCount = c.flexInt(.memberCount) ?? 0
        isOpen = c.flexBool(.isOpen) ?? true
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

    /// Points that could still be spent somewhere in the tree.
    var remainingCapacity: Int {
        tree.nodes.reduce(0) { $0 + max(0, $1.maxRank - rank(of: $1.id)) }
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

// MARK: - Challenges, quests, achievements

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
    var rewardTitle: String?
    var rewardCosmetic: String?

    enum CodingKeys: String, CodingKey {
        case damage, hp, defeated
        case bossID = "boss_id"
        case bossName = "boss_name"
        case damageDone = "damage_done"
        case justDefeated = "just_defeated"
        case rewardXP = "reward_xp"
        case rewardTitle = "reward_title"
        case rewardCosmetic = "reward_cosmetic"
    }
}

// MARK: - Seasons (API_V2 §6)

struct SeasonReward: Decodable, Equatable {
    var type: String            // title | cosmetic | streak_freeze | talent_point
    var value: String?
    var label: String

    enum CodingKeys: String, CodingKey { case type, value, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.flexString(.type) ?? "title"
        value = c.flexString(.value)
        label = c.flexString(.label) ?? value ?? type
    }

    var icon: String {
        switch type {
        case "cosmetic":      return "sparkles"
        case "streak_freeze": return "snowflake"
        case "talent_point":  return "star.fill"
        default:              return "rosette"
        }
    }

    var tint: Color {
        switch type {
        case "cosmetic":      return value?.auraColor ?? .brandPurple
        case "streak_freeze": return .brandBlue
        case "talent_point":  return .brandPurple
        default:              return .brandYellow
        }
    }
}

struct SeasonTier: Decodable, Identifiable, Equatable {
    var tier: Int
    var xpRequired: Int
    var reward: SeasonReward

    var id: Int { tier }

    enum CodingKeys: String, CodingKey {
        case tier, reward
        case xpRequired = "xp_required"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = c.flexInt(.tier) ?? 0
        xpRequired = c.flexInt(.xpRequired) ?? 0
        reward = try c.decode(SeasonReward.self, forKey: .reward)
    }
}

struct Season: Decodable, Equatable {
    var id: String
    var number: Int
    var name: String
    var theme: String?
    var startsAt: Int
    var endsAt: Int
    var secondsLeft: Int
    var tiers: [SeasonTier]

    enum CodingKeys: String, CodingKey {
        case id, number, name, theme, tiers
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case secondsLeft = "seconds_left"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = c.flexInt(.number) ?? 1
        id = c.flexString(.id) ?? "season-\(number)"
        name = c.flexString(.name) ?? "Season \(number)"
        theme = c.flexString(.theme)
        startsAt = c.flexInt(.startsAt) ?? 0
        endsAt = c.flexInt(.endsAt) ?? 0
        secondsLeft = c.flexInt(.secondsLeft) ?? max(0, endsAt - Int(Date().timeIntervalSince1970))
        tiers = ((try? c.decode([SeasonTier].self, forKey: .tiers)) ?? []).sorted { $0.tier < $1.tier }
    }
}

struct SeasonProgress: Decodable, Equatable {
    var seasonXP: Int
    var tier: Int
    var claimed: [Int]

    enum CodingKeys: String, CodingKey {
        case tier, claimed
        case seasonXP = "season_xp"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonXP = c.flexInt(.seasonXP) ?? 0
        tier = c.flexInt(.tier) ?? 0
        claimed = (try? c.decode([Int].self, forKey: .claimed)) ?? []
    }
}

struct SeasonStanding: Decodable, Identifiable, Equatable {
    var rank: Int
    var userID: String
    var displayName: String
    var level: Int
    var seasonXP: Int
    var isSelf: Bool

    var id: String { userID }

    enum CodingKeys: String, CodingKey {
        case rank, level
        case userID = "user_id"
        case displayName = "display_name"
        case seasonXP = "season_xp"
        case isSelf = "is_self"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = try c.decode(String.self, forKey: .userID)
        rank = c.flexInt(.rank) ?? 0
        displayName = c.flexString(.displayName) ?? "Athlete"
        level = c.flexInt(.level) ?? 1
        seasonXP = c.flexInt(.seasonXP) ?? 0
        isSelf = c.flexBool(.isSelf) ?? false
    }
}

struct SeasonState: Decodable, Equatable {
    var season: Season
    var progress: SeasonProgress
    var leaderboard: [SeasonStanding]

    enum CodingKeys: String, CodingKey { case season, progress, leaderboard }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        season = try c.decode(Season.self, forKey: .season)
        progress = try c.decode(SeasonProgress.self, forKey: .progress)
        leaderboard = (try? c.decode([SeasonStanding].self, forKey: .leaderboard)) ?? []
    }

    func isClaimed(_ tier: Int) -> Bool { progress.claimed.contains(tier) }
    func isReached(_ tier: SeasonTier) -> Bool { progress.seasonXP >= tier.xpRequired || progress.tier >= tier.tier }
    var claimableCount: Int { season.tiers.filter { isReached($0) && !isClaimed($0.tier) }.count }
}

// MARK: - Celebration events

/// Server-confirmed XP from one sync, for the "+XP" toast.
struct XPGainEvent: Identifiable, Equatable {
    let id = UUID()
    let xp: Int
    let workouts: Int
}

/// One achievement the server just unlocked, for the celebration toast.
struct AchievementUnlock: Identifiable, Equatable {
    let id: String
    var title: String
    var icon: String
    var rarityColor: Color
}

