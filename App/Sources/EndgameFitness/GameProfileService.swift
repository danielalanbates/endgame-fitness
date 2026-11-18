//
//  GameProfileService.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  The game, for the views. Same surface the networked service had (the
//  online version is archived in _archive/online-account-2026-11-16),
//  but everything is computed on the device by LocalGame for the current
//  local player. The models (FitnessProfile, Quest, RaidState, ...) are the
//  ones in GameProfile.swift; the Decodable-only ones are built from the same
//  JSON shapes the server used to send, so their lenient decoders keep working.
//

import Foundation
import SwiftUI

@MainActor
final class GameProfileService: ObservableObject {
    static let shared = GameProfileService()

    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    @Published private(set) var profile: FitnessProfile?
    @Published private(set) var profileState: LoadState = .idle
    @Published private(set) var feed: [ActivityItem] = []
    @Published private(set) var feedHasMore = false
    @Published private(set) var isLoadingFeed = false
    @Published private(set) var leaderboard: [LeaderboardEntry] = []
    @Published private(set) var leaderboardYou: LeaderboardEntry?
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var incomingRequests: [Friend] = []
    @Published private(set) var outgoingRequests: [Friend] = []
    @Published private(set) var guild: Guild?
    @Published private(set) var guildMembers: [GuildMember] = []
    @Published private(set) var guildRole: String?
    @Published private(set) var raid: RaidState?
    @Published private(set) var isLoadingRaid = false
    /// Set when a workout lands damage on the boss; RaidCard shows it as a toast.
    @Published var lastRaidHit: RaidHit?
    @Published private(set) var talents: TalentState?
    @Published private(set) var talentsError: String?
    @Published private(set) var activeChallenges: [Challenge] = []
    @Published private(set) var pendingChallenges: [Challenge] = []
    @Published private(set) var finishedChallenges: [Challenge] = []
    @Published private(set) var blockedUsers: [BlockedUser] = []
    @Published private(set) var season: SeasonState?
    @Published private(set) var seasonError: String?

    @Published private(set) var dailyQuests: [Quest] = []
    @Published private(set) var weeklyQuests: [Quest] = []
    @Published private(set) var questsLoaded = false
    @Published private(set) var achievements: [Achievement] = []
    @Published private(set) var achievementsLoaded = false

    /// Achievement ids a workout just unlocked, so the UI can celebrate once.
    @Published var pendingAchievements: [String] = []
    /// The quest most recently claimed, for the claim animation.
    @Published var lastClaimedQuest: Quest?

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published var lastError: String?

    /// Set when a workout produces a level-up, so the UI can celebrate once.
    @Published var pendingLevelUps: Int = 0
    /// XP from the most recent workout or quest claim.
    @Published var lastXPGain: Int = 0
    /// XP from a recorded workout; drives the toast.
    @Published var xpEvent: XPGainEvent?

    /// Lets the dashboard open Community on a specific section.
    @Published var requestedCommunitySection: CommunitySection?

    let engine: LocalGame
    private static let feedPageSize = 50
    private var feedLimit = feedPageSize
    private var leaderboardQuery = (scope: "global", metric: "xp")

    private init() {
        engine = LocalGame(store: LocalGameStore(root: LocalGameStore.defaultRoot))
        engine.roster = {
            MainActor.assumeIsolated { LocalPlayerStore.shared.players.map { (id: $0.id, name: $0.name) } }
        }
    }

    private var playerID: String? { LocalPlayerStore.shared.currentID }
    private var players: [LocalPlayer] { LocalPlayerStore.shared.players }
    private func player(_ id: String) -> LocalPlayer? { players.first { $0.id == id } }

    var pendingCount: Int { 0 }

    // MARK: Activation

    /// The current player changed (picker, switch, delete).
    func activate() {
        reset()
        guard playerID != nil else { return }
        refreshAll()
    }

    /// Re-reads everything the views show from the local engine.
    func refreshAll() {
        guard let id = playerID else { return }
        engine.tzOffsetMin = TimeZone.current.secondsFromGMT() / 60
        engine.settleChallenges()
        engine.ensureBoard(id)
        profile = buildProfile(id)
        profileState = .loaded
        rebuildQuests(id)
        rebuildAchievements(id)
        talents = TalentState(tree: GameRules.talentTree, ranks: engine.store.state(id).talentRanks,
                              unspent: engine.store.state(id).talentPoints,
                              spent: GameRules.pointsSpent(engine.store.state(id).talentRanks))
        talentsError = nil
        season = buildSeason(id)
        seasonError = season == nil ? "Season unavailable." : nil
        rebuildFeed(id)
        rebuildFriends(id)
        rebuildGuild(id)
        raid = buildRaid(id)
        rebuildChallenges(id)
        rebuildLeaderboard(id)
        blockedUsers = (engine.store.household().blocked[id] ?? []).compactMap { other in
            decode(BlockedUser.self, ["user_id": other, "display_name": player(other)?.name ?? "Player"])
        }
        lastSyncDate = Date()
    }

    /// Replays the training log into a player that has no game state yet.
    func seedFromHistory(_ sessions: [SyncSession]) {
        guard let id = playerID else { return }
        if engine.seedIfNeeded(id, history: sessions) { refreshAll() }
    }

    // MARK: Recording

    func recordWorkout(
        id: String = UUID().uuidString,
        name: String?,
        programID: String? = nil,
        performedAt: Date = Date(),
        durationSecs: Int,
        totalVolume: Double,
        totalReps: Int,
        exercises: [SyncExercise]? = nil,
        notes: String? = nil,
        clientRev: Int? = nil
    ) {
        enqueue(SyncSession(
            id: id, performedAt: Int(performedAt.timeIntervalSince1970), name: name, programID: programID,
            durationSecs: durationSecs, totalVolume: totalVolume, totalReps: totalReps, xpEarned: nil,
            clientRev: clientRev ?? 0, exercises: exercises, notes: notes
        ))
    }

    func recordDeletion(id: String, performedAt: Date = Date()) {
        enqueue(SyncSession(
            id: id, performedAt: Int(performedAt.timeIntervalSince1970), name: nil, programID: nil,
            durationSecs: 0, totalVolume: 0, totalReps: 0, xpEarned: nil, clientRev: 0, deleted: true
        ))
    }

    /// A new, edited or deleted session from the training log. Applied at once.
    func enqueue(_ session: SyncSession) {
        guard let id = playerID else { return }
        var session = session
        if let known = engine.store.state(id).sessions[session.id]?.rev {
            session.clientRev = max(session.clientRev, known + 1)
        } else {
            session.clientRev = max(session.clientRev, 1)
        }
        let isNew = engine.store.state(id).sessions[session.id] == nil
        let outcome = engine.apply(session, to: id)
        if isNew, session.deleted != true, outcome.xpGained > 0 {
            lastXPGain = outcome.xpGained
            xpEvent = XPGainEvent(xp: outcome.xpGained, workouts: 1)
        }
        if outcome.levelsGained > 0 { pendingLevelUps = outcome.levelsGained }
        if !outcome.unlocked.isEmpty { pendingAchievements = outcome.unlocked }
        if let hit = outcome.raid, hit.damage > 0 { lastRaidHit = hit }
        refreshAll()
        evolveAvatarIfNeeded()
    }

    /// Kept for callers from the networked build: refreshes from local state
    /// (No Apple Health or wearable sync: archived 2026-11-16.)
    @discardableResult
    func sync() async -> Bool {
        guard let id = playerID, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        refreshAll()
        return true
    }

    private func evolveAvatarIfNeeded() {
        guard let current = profile, let config = current.avatarConfig else { return }
        let next = config.evolved(level: current.level, totalVolume: current.totalVolume)
        guard next != config, let object = next.wireObject else { return }
        applyProfileFields(["avatar_config": object])
    }

    func unlockDetails(for ids: [String]) -> [AchievementUnlock] {
        ids.map { id in
            if let achievement = achievements.first(where: { $0.id == id }) {
                return AchievementUnlock(id: id, title: achievement.title, icon: achievement.icon,
                                         rarityColor: achievement.rarityColor)
            }
            return AchievementUnlock(id: id, title: id.replacingOccurrences(of: "_", with: " ").capitalized,
                                     icon: "rosette", rarityColor: .brandOrange)
        }
    }

    // MARK: Profile

    func loadAll() async { refreshAll() }
    func loadProfile() async { refreshAll() }

    private func buildProfile(_ id: String) -> FitnessProfile? {
        let s = engine.store.state(id)
        let streak = engine.effectiveStreak(id)
        let dict: [String: Any?] = [
            "user_id": id,
            "display_name": player(id)?.name ?? "Player",
            "level": s.level,
            "xp": s.xp,
            "xp_for_next_level": GameRules.xpForLevel(s.level + 1),
            "xp_for_current_level": GameRules.xpForLevel(s.level),
            "talent_points": s.talentPoints,
            "prestige": 0,
            "current_streak": streak.current,
            "longest_streak": s.streak.longest,
            "last_workout_date": s.streak.lastDate,
            "total_workouts": s.totalWorkouts,
            "total_volume": s.totalVolume,
            "total_reps": s.totalReps,
            "training_goal": s.trainingGoal,
            "experience_level": s.experienceLevel,
            "equipment_level": s.equipmentLevel,
            "body_weight": s.bodyWeight,
            "height_inches": s.heightInches,
            "birth_year": s.birthYear,
            "units": s.units,
            "title": s.title,
            "cosmetic": s.cosmetic,
            "is_public": s.isPublic,
            "friend_code": String(id.prefix(8)).uppercased(),
            "bio": s.bio,
            "hero_class": engine.heroClass(id),
            "class_affinity": engine.affinity(id),
            "earned_titles": engine.earnedTitles(id),
            "earned_cosmetics": s.cosmetics.sorted(),
            "streak_freezes": streak.freezes,
            "streak_alive": streak.alive,
            "season_xp": engine.seasonXP(id),
            "onboarded": s.onboarded,
            "avatar_config": s.avatarConfig?.wireObject,
        ]
        return decode(FitnessProfile.self, dict)
    }

    /// Profile edit (formerly PUT fitness/profile). Returns a problem, or nil.
    @discardableResult
    func saveProfile(_ fields: [String: Any]) async -> String? { applyProfileFields(fields) }

    @discardableResult
    func applyProfileFields(_ fields: [String: Any]) -> String? {
        guard let id = playerID else { return "Pick a player first." }
        var s = engine.store.state(id)
        func string(_ key: String) -> String?? {
            guard let raw = fields[key] else { return .none }
            if raw is NSNull { return .some(nil) }
            let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .some((text?.isEmpty ?? true) ? nil : text)
        }
        func number(_ key: String) -> Double? { (fields[key] as? NSNumber)?.doubleValue }

        if case .some(let name?) = string("display_name") {
            if let problem = ProfileRules.displayNameProblem(name) { return problem }
            LocalPlayerStore.shared.rename(id, to: name)
        }
        if case .some(let bio) = string("bio") {
            if let bio, let problem = ProfileRules.bioProblem(bio) { return problem }
            s.bio = bio
        }
        if case .some(let title) = string("title") {
            if let title, !engine.earnedTitles(id).contains(title) { return "You haven't earned that title yet." }
            s.title = title
        }
        if case .some(let cosmetic) = string("cosmetic") {
            if let cosmetic, !s.cosmetics.contains(cosmetic) { return "You haven't earned that aura yet." }
            s.cosmetic = cosmetic
        }
        if let v = fields["is_public"] as? Bool { s.isPublic = v }
        if case .some(let goal) = string("training_goal") { s.trainingGoal = goal; if goal != nil { s.onboarded = true } }
        if case .some(let v) = string("experience_level") { s.experienceLevel = v }
        if case .some(let v) = string("equipment_level") { s.equipmentLevel = v }
        if case .some(let v) = string("units") { s.units = v ?? "lb" }
        if let v = number("body_weight") { s.bodyWeight = v > 0 ? v : nil }
        if let v = number("height_inches") { s.heightInches = v > 0 ? v : nil }
        if let v = number("birth_year") { s.birthYear = Int(v) }
        if let v = fields["onboarded"] as? Bool { s.onboarded = v }
        if let object = fields["avatar_config"] {
            if object is NSNull {
                s.avatarConfig = nil
            } else if let config = decode(AvatarBodyProfile.self, object) {
                s.avatarConfig = config
            }
        }
        engine.store.save(s, for: id)
        profile = buildProfile(id)
        profileState = .loaded
        return nil
    }

    func updateProfile(_ fields: [String: Any]) async { applyProfileFields(fields) }

    // MARK: Quests & achievements

    var claimableQuestCount: Int { (dailyQuests + weeklyQuests).filter(\.isClaimable).count }

    func loadQuests() async {
        guard let id = playerID else { return }
        rebuildQuests(id)
    }

    private func rebuildQuests(_ id: String) {
        let quests = engine.activeQuests(id).map { q -> Quest in
            let def = GameRules.questDefinition(q.questKey)
            return Quest(id: q.id, questKey: q.questKey, kind: q.kind, title: def?.title ?? q.questKey,
                         description: def?.desc ?? "", icon: def?.icon ?? "checkmark.seal.fill", metric: def?.metric,
                         target: q.target, progress: q.progress, xpReward: q.xpReward, expiresAt: q.expiresAt,
                         completedAt: q.completedAt, claimed: q.claimed)
        }
        dailyQuests = quests.filter(\.isDaily)
        weeklyQuests = quests.filter { !$0.isDaily }
        questsLoaded = true
    }

    func claimQuest(_ quest: Quest) async {
        guard let id = playerID, quest.isClaimable else { return }
        switch engine.claimQuest(id, questID: quest.id) {
        case .success(let result):
            if result.xp > 0 { lastXPGain = result.xp }
            if result.levels > 0 { pendingLevelUps = result.levels }
            refreshAll()
            lastClaimedQuest = (dailyQuests + weeklyQuests).first { $0.id == quest.id }
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func loadAchievements() async {
        guard let id = playerID else { return }
        rebuildAchievements(id)
    }

    private func rebuildAchievements(_ id: String) {
        let have = engine.store.state(id).achievements
        achievements = GameRules.achievements.map {
            Achievement(id: $0.id, title: $0.title, desc: $0.desc, rarity: $0.rarity, xp: $0.xp, icon: $0.icon,
                        unlocked: have[$0.id] != nil, unlockedAt: have[$0.id])
        }
        achievementsLoaded = true
    }

    // MARK: Feed, reactions, comments

    func loadFeed() async {
        guard let id = playerID else { return }
        feedLimit = Self.feedPageSize
        rebuildFeed(id)
    }

    func loadMoreFeed() async {
        guard let id = playerID, feedHasMore else { return }
        feedLimit += Self.feedPageSize
        rebuildFeed(id)
    }

    private func rebuildFeed(_ id: String) {
        let visible = engine.store.household().feed.filter { !engine.isBlocked(id, $0.userID) && player($0.userID) != nil }
        feed = visible.prefix(feedLimit).compactMap { item in
            let author = engine.store.state(item.userID)
            let reactions = item.reactions.keys.sorted().map { emoji -> [String: Any] in
                let who = item.reactions[emoji] ?? []
                return ["emoji": emoji, "count": who.count, "mine": who.contains(id)]
            }
            let dict: [String: Any?] = [
                "id": item.id, "user_id": item.userID, "display_name": player(item.userID)?.name ?? "Player",
                "level": author.level, "kind": item.kind, "summary": item.summary, "created_at": item.createdAt,
                "reactions": reactions, "is_self": item.userID == id, "comment_count": item.comments.count,
                "author_cosmetic": author.cosmetic,
            ]
            return decode(ActivityItem.self, dict)
        }
        feedHasMore = visible.count > feedLimit
    }

    func toggleReaction(on itemID: String, emoji: String) async {
        guard let id = playerID else { return }
        engine.toggleReaction(id, itemID: itemID, emoji: emoji)
        rebuildFeed(id)
        rebuildQuests(id)
    }

    func loadComments(for itemID: String) async throws -> [FeedComment] {
        guard let id = playerID,
              let item = engine.store.household().feed.first(where: { $0.id == itemID }) else { return [] }
        return item.comments.filter { !engine.isBlocked(id, $0.userID) }.compactMap { comment(for: $0, viewer: id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func addComment(to itemID: String, text: String) async throws -> FeedComment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = playerID, !trimmed.isEmpty,
              let record = engine.addComment(id, itemID: itemID, text: trimmed),
              let made = comment(for: record, viewer: id) else {
            throw LocalGameError.message("Couldn't add that comment.")
        }
        rebuildFeed(id)
        return made
    }

    func deleteComment(_ commentID: String, on itemID: String) async throws {
        guard let id = playerID else { return }
        engine.deleteComment(id, commentID: commentID)
        rebuildFeed(id)
    }

    private func comment(for record: CommentRecord, viewer: String) -> FeedComment? {
        decode(FeedComment.self, [
            "id": record.id, "user_id": record.userID, "display_name": player(record.userID)?.name ?? "Player",
            "level": engine.store.state(record.userID).level, "text": record.text, "created_at": record.createdAt,
            "is_self": record.userID == viewer,
        ])
    }

    // MARK: Leaderboard (players on this device)

    func loadLeaderboard(scope: String = "global", metric: String = "xp") async {
        leaderboardQuery = (scope, metric)
        guard let id = playerID else { return }
        rebuildLeaderboard(id)
    }

    private func rebuildLeaderboard(_ id: String) {
        var ids = players.map(\.id).filter { $0 == id || !engine.isBlocked(id, $0) }
        if leaderboardQuery.scope == "guild" {
            let members = engine.store.household().guild?.members ?? [:]
            ids = ids.filter { members[$0] != nil }
        }
        let metric = leaderboardQuery.metric
        func value(_ p: String) -> Double {
            let s = engine.store.state(p)
            switch metric {
            case "level": return Double(s.xp)
            case "streak": return Double(engine.effectiveStreak(p).current)
            case "volume": return s.totalVolume
            case "workouts": return Double(s.totalWorkouts)
            case "season": return Double(engine.seasonXP(p))
            default: return Double(s.xp)
            }
        }
        let sorted = ids.sorted { value($0) != value($1) ? value($0) > value($1) : $0 < $1 }
        let entries = sorted.enumerated().compactMap { index, p -> LeaderboardEntry? in
            let s = engine.store.state(p)
            let dict: [String: Any?] = [
                "rank": index + 1, "user_id": p, "display_name": player(p)?.name ?? "Player", "level": s.level,
                "xp": s.xp, "current_streak": engine.effectiveStreak(p).current, "total_volume": s.totalVolume,
                "total_workouts": s.totalWorkouts, "title": s.title, "is_self": p == id, "cosmetic": s.cosmetic,
                "season_xp": engine.seasonXP(p), "hero_class": engine.heroClass(p),
            ]
            return decode(LeaderboardEntry.self, dict)
        }
        leaderboard = entries
        leaderboardYou = entries.first { $0.isSelf }
    }

    // MARK: Household ("friends")

    func loadFriends() async {
        guard let id = playerID else { return }
        rebuildFriends(id)
    }

    private func rebuildFriends(_ id: String) {
        friends = players.filter { $0.id != id && !engine.isBlocked(id, $0.id) }.compactMap { p in
            let s = engine.store.state(p.id)
            return decode(Friend.self, [
                "user_id": p.id, "display_name": p.name, "level": s.level, "xp": s.xp,
                "current_streak": engine.effectiveStreak(p.id).current, "cosmetic": s.cosmetic as Any? ?? NSNull(),
            ])
        }
        incomingRequests = []
        outgoingRequests = []
    }

    private static let householdNote = "Everyone who plays on this device is already in your party. Add a player from the player picker."

    @discardableResult
    func requestFriend(query: String) async -> String? { Self.householdNote }

    @discardableResult
    func requestFriend(userID: String) async -> String? { Self.householdNote }

    @discardableResult
    func respondToFriendRequest(userID: String, accept: Bool) async -> String? { nil }

    @discardableResult
    func removeFriend(userID: String) async -> String? {
        "Household members can't be unfriended. Block them, or delete the player from the player picker."
    }

    func loadPlayer(_ userID: String) async throws -> PublicPlayer {
        guard let viewer = playerID, let p = player(userID) else { throw LocalGameError.message("That player isn't on this device.") }
        let s = engine.store.state(userID)
        let guild = engine.store.household().guild
        let dict: [String: Any?] = [
            "user_id": userID, "display_name": p.name, "level": s.level, "xp": s.xp, "title": s.title,
            "hero_class": engine.heroClass(userID), "current_streak": engine.effectiveStreak(userID).current,
            "total_workouts": s.totalWorkouts, "avatar_config": s.avatarConfig?.wireObject,
            "guild": (guild?.members[userID] != nil) ? ["id": guild!.id, "name": guild!.name, "emblem": guild!.emblem as Any? ?? NSNull()] : nil,
            "achievements_count": s.achievements.count, "is_friend": userID != viewer, "is_self": userID == viewer,
            "is_blocked": (engine.store.household().blocked[viewer] ?? []).contains(userID),
            "cosmetic": s.cosmetic, "bio": s.bio,
        ]
        guard let made = decode(PublicPlayer.self, dict) else { throw LocalGameError.message("Couldn't load that player.") }
        return made
    }

    func searchPlayers(_ query: String) async throws -> [PublicPlayer] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        var out: [PublicPlayer] = []
        for p in players where p.name.lowercased().contains(q) || p.id.lowercased().hasPrefix(q) {
            if let found = try? await loadPlayer(p.id) { out.append(found) }
        }
        return out
    }

    // MARK: Safety

    func loadBlocked() async { refreshAll() }

    @discardableResult
    func block(userID: String) async -> String? {
        guard let id = playerID, userID != id else { return nil }
        var h = engine.store.household()
        var list = h.blocked[id] ?? []
        if !list.contains(userID) { list.append(userID) }
        h.blocked[id] = list
        engine.store.saveHousehold(h)
        refreshAll()
        return nil
    }

    @discardableResult
    func unblock(userID: String) async -> String? {
        guard let id = playerID else { return nil }
        var h = engine.store.household()
        h.blocked[id]?.removeAll { $0 == userID }
        engine.store.saveHousehold(h)
        refreshAll()
        return nil
    }

    /// There is no moderator for players on one device.
    @discardableResult
    func report(_ target: ReportTarget, id: String, reason: String) async -> String? {
        "Players on this device aren't moderated online. Block them, or ask whoever manages this device to remove the player. For anything urgent, open an issue on the Endgame Fitness GitHub page."
    }

    // MARK: Guild (household)

    func loadGuild() async {
        guard let id = playerID else { return }
        rebuildGuild(id)
    }

    private func rebuildGuild(_ id: String) {
        guard let g = engine.store.household().guild, g.members[id] != nil else {
            guild = nil
            guildMembers = []
            guildRole = nil
            return
        }
        guild = decode(Guild.self, [
            "id": g.id, "name": g.name, "motto": g.motto, "emblem": g.emblem, "owner_id": g.ownerID,
            "member_cap": 50, "invite_code": g.inviteCode, "is_open": g.isOpen,
        ] as [String: Any?])
        guildMembers = g.members.keys.sorted().compactMap { member in
            let s = engine.store.state(member)
            return decode(GuildMember.self, [
                "user_id": member, "display_name": player(member)?.name ?? "Player", "level": s.level, "xp": s.xp,
                "current_streak": engine.effectiveStreak(member).current, "role": g.members[member] ?? "member",
            ])
        }
        guildRole = g.members[id]
    }

    var isGuildOwner: Bool { guildRole == "owner" || (guild != nil && guild?.ownerID == playerID) }
    var canManageInvites: Bool { isGuildOwner || guildRole == "officer" }

    @discardableResult
    func createGuild(name: String, motto: String, emblem: String? = nil, isOpen: Bool = true) async -> String? {
        guard let id = playerID else { return "Pick a player first." }
        let problem = engine.createGuild(id, name: name, motto: motto.trimmingCharacters(in: .whitespacesAndNewlines),
                                         emblem: emblem, isOpen: isOpen)
        refreshAll()
        return problem
    }

    func discoverGuilds(query: String) async throws -> [GuildSummary] {
        guard let g = engine.store.household().guild else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.isEmpty || g.name.lowercased().contains(q) else { return [] }
        return [decode(GuildSummary.self, [
            "id": g.id, "name": g.name, "motto": g.motto, "emblem": g.emblem,
            "member_count": g.members.count, "is_open": g.isOpen,
        ] as [String: Any?])].compactMap { $0 }
    }

    @discardableResult
    func joinGuild(inviteCode: String) async -> String? {
        guard let id = playerID else { return "Pick a player first." }
        let problem = engine.joinGuild(id, inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshAll()
        return problem
    }

    @discardableResult
    func joinGuild(id guildID: String) async -> String? {
        guard let id = playerID else { return "Pick a player first." }
        let problem = engine.joinGuild(id)
        refreshAll()
        return problem
    }

    @discardableResult
    func leaveGuild() async -> String? {
        guard let id = playerID else { return nil }
        let problem = engine.leaveGuild(id)
        refreshAll()
        return problem
    }

    @discardableResult
    func rotateGuildInviteCode() async -> String? {
        var h = engine.store.household()
        guard h.guild != nil else { return "No guild." }
        h.guild?.inviteCode = LocalGame.inviteCode()
        engine.store.saveHousehold(h)
        refreshAll()
        return nil
    }

    @discardableResult
    func updateGuild(_ fields: [String: Any]) async -> String? {
        var h = engine.store.household()
        guard var g = h.guild, g.ownerID == playerID else { return "Only the guild owner can edit the guild." }
        if let name = (fields["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard name.count >= 3, name.count <= 32 else { return "Guild names are 3–32 characters." }
            g.name = name
        }
        if let motto = fields["motto"] as? String { g.motto = motto.isEmpty ? nil : motto }
        if let emblem = fields["emblem"] as? String { g.emblem = emblem }
        if let open = fields["is_open"] as? Bool { g.isOpen = open }
        h.guild = g
        engine.store.saveHousehold(h)
        refreshAll()
        return nil
    }

    // MARK: Raid

    /// This week's boss: the household guild's raid, or a solo raid without one.
    func loadRaid() async {
        guard let id = playerID else { return }
        raid = buildRaid(id)
    }

    private func buildRaid(_ id: String) -> RaidState? {
        let r = engine.currentRaid(id)
        guard let boss = GameRules.bossCatalog.first(where: { $0.id == r.bossID }) else { return nil }
        let t = engine.now
        let done = r.damage.values.reduce(0, +)
        let contributors = r.damage.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .enumerated().map { index, entry in
                RaidContributor(rank: index + 1, userID: entry.key, displayName: player(entry.key)?.name ?? "Player",
                                level: engine.store.state(entry.key).level, avatarURL: nil, damage: entry.value,
                                hits: r.hits[entry.key] ?? 0, isSelf: entry.key == id)
            }
        let endsAt = r.weekStart + GameRules.weekSecs
        return RaidState(id: r.id, guildID: r.ownerKey, weekStart: r.weekStart, endsAt: endsAt,
                         secondsLeft: max(0, endsAt - t), boss: boss, hp: r.hp, damageDone: min(done, r.hp),
                         hpRemaining: max(0, r.hp - done), defeated: r.defeatedAt != nil, defeatedAt: r.defeatedAt,
                         memberCount: r.memberCount, contributors: contributors, myDamage: r.damage[id] ?? 0,
                         myHits: r.hits[id] ?? 0)
    }

    // MARK: Seasons

    func loadSeason() async {
        guard let id = playerID else { return }
        season = buildSeason(id)
    }

    private func buildSeason(_ id: String) -> SeasonState? {
        let t = engine.now
        let n = max(1, GameRules.seasonNumber(at: t))
        let theme = GameRules.theme(for: n)
        let starts = GameRules.seasonOneStart + (n - 1) * GameRules.seasonSecs
        let ends = starts + GameRules.seasonSecs
        let sid = GameRules.seasonID(n)
        let tiers: [[String: Any]] = (1...GameRules.tierCount).map { tier in
            let r = GameRules.reward(season: n, tier: tier)
            return ["tier": tier, "xp_required": GameRules.xpRequired(forTier: tier),
                    "reward": ["type": r.type, "value": r.value, "label": r.label]]
        }
        let mine = engine.seasonXP(id)
        let board = players.map(\.id).sorted { engine.seasonXP($0) != engine.seasonXP($1) ? engine.seasonXP($0) > engine.seasonXP($1) : $0 < $1 }
            .enumerated().map { index, p -> [String: Any] in
                ["rank": index + 1, "user_id": p, "display_name": player(p)?.name ?? "Player",
                 "level": engine.store.state(p).level, "season_xp": engine.seasonXP(p), "is_self": p == id]
            }
        let dict: [String: Any] = [
            "season": ["id": sid, "number": n, "name": "Season \(n): \(theme.name)", "theme": theme.theme,
                       "starts_at": starts, "ends_at": ends, "seconds_left": max(0, ends - t), "tiers": tiers],
            "progress": ["season_xp": mine, "tier": GameRules.tier(forXP: mine),
                         "claimed": engine.store.state(id).seasonClaims[sid] ?? []],
            "leaderboard": board,
        ]
        return decode(SeasonState.self, dict)
    }

    @discardableResult
    func claimSeasonTier(_ tier: Int) async -> String? {
        guard let id = playerID else { return "Pick a player first." }
        let problem = engine.claimSeasonTier(id, tier: tier)
        refreshAll()
        return problem
    }

    // MARK: Talents

    func loadTalents() async { refreshAll() }

    @discardableResult
    func spendTalent(_ talentID: String) async -> String? {
        guard let id = playerID else { return "Pick a player first." }
        let problem = engine.spendTalent(id, talentID: talentID)
        refreshAll()
        return problem
    }

    func respecTalents() async {
        guard let id = playerID else { return }
        engine.respec(id)
        refreshAll()
    }

    // MARK: Challenges

    func loadChallenges() async {
        guard let id = playerID else { return }
        engine.settleChallenges()
        rebuildChallenges(id)
    }

    private func rebuildChallenges(_ id: String) {
        let mine = engine.store.household().challenges.filter { $0.participants.contains(id) }
        func shape(_ c: ChallengeRecord) -> Challenge {
            let standings = engine.standings(c).map { row in
                Challenge.Standing(userID: row.userID, displayName: player(row.userID)?.name ?? "Player",
                                   level: engine.store.state(row.userID).level, avatarURL: nil, score: row.score,
                                   sessions: row.sessions, rank: row.rank, isSelf: row.userID == id)
            }
            return Challenge(id: c.id, kind: c.kind, metric: c.metric, creatorID: c.creatorID, opponentID: c.opponentID,
                             guildID: c.guildID, startsAt: c.startsAt, endsAt: c.endsAt, status: c.status,
                             winnerID: c.winnerID, isCreator: c.creatorID == id,
                             awaitingMe: c.status == "pending" && c.opponentID == id, standings: standings)
        }
        pendingChallenges = mine.filter { $0.status == "pending" }.map(shape)
        activeChallenges = mine.filter { $0.status == "active" }.map(shape)
        finishedChallenges = mine.filter { $0.status == "finished" }.prefix(20).map(shape)
    }

    @discardableResult
    func createChallenge(kind: String, metric: String, opponentUserID: String?, days: Int) async -> String? {
        guard let id = playerID else { return "Pick a player first." }
        let problem = engine.createChallenge(id, kind: kind, metric: metric, opponentID: opponentUserID, days: days)
        rebuildChallenges(id)
        return problem
    }

    @discardableResult
    func respondToChallenge(id challengeID: String, accept: Bool) async -> String? {
        guard let id = playerID else { return nil }
        let problem = engine.respondToChallenge(id, challengeID: challengeID, accept: accept)
        rebuildChallenges(id)
        return problem
    }

    // MARK: Reset

    func reset() {
        profile = nil
        profileState = .idle
        feed = []
        feedHasMore = false
        feedLimit = Self.feedPageSize
        leaderboard = []
        leaderboardYou = nil
        friends = []
        incomingRequests = []
        outgoingRequests = []
        guild = nil
        guildMembers = []
        guildRole = nil
        activeChallenges = []
        pendingChallenges = []
        finishedChallenges = []
        talents = nil
        talentsError = nil
        dailyQuests = []
        weeklyQuests = []
        questsLoaded = false
        achievements = []
        achievementsLoaded = false
        pendingAchievements = []
        lastClaimedQuest = nil
        raid = nil
        lastRaidHit = nil
        blockedUsers = []
        season = nil
        seasonError = nil
        pendingLevelUps = 0
        lastXPGain = 0
        xpEvent = nil
        lastSyncDate = nil
        lastError = nil
        requestedCommunitySection = nil
    }

    // MARK: Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? { Self.decodeShape(type, object) }

    /// Builds a model from the JSON shape the server used to send.
    nonisolated static func decodeShape<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
        let cleaned = clean(object)
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Drops nil values from [String: Any?] (and nested) so JSONSerialization accepts them.
    nonisolated private static func clean(_ value: Any) -> Any {
        if let dict = value as? [String: Any?] {
            var out: [String: Any] = [:]
            for (k, v) in dict { if let v { out[k] = clean(v) } }
            return out
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { clean($0) }
        }
        if let list = value as? [Any] { return list.map { clean($0) } }
        return value
    }
}
