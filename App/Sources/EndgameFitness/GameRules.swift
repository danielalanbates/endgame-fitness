//
//  GameRules.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  The game's rules, ported 1:1 from the old Cloudflare backend
//  (App/Backend/functions/_lib/*.js and api/fitness/[[path]].js) so the app
//  runs entirely on the device. Pure functions only: no disk, no clock — the
//  caller passes `now` (epoch seconds). LocalGame applies them to state.
//
//  Source map:
//    levels / xpForLevel            api/fitness/[[path]].js  xpForLevel, levelForXp
//    xpForWorkout, evaluate, PRs    _lib/syncrules.js
//    quests, achievements, periods  _lib/game.js
//    talents                        _lib/talents.js
//    challenges                     _lib/challenges.js
//    raids                          _lib/raids.js
//    seasons                        _lib/seasons.js
//    streaks                        _lib/streaks.js
//    hero class                     _lib/heroclass.js
//    titles / cosmetics             _lib/unlocks.js
//

import Foundation

enum GameRules {
    static let day = 86400

    // MARK: Calendar maths (UTC, proleptic Gregorian; no Foundation calendar so
    // results match the JS Date maths exactly)

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func civil(fromDays days: Int) -> (y: Int, m: Int, d: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func days(fromCivil y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = m > 2 ? m - 3 : m + 9
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// 'YYYY-MM-DD' (UTC) for epoch seconds.
    static func dayKey(_ epoch: Int) -> String {
        let c = civil(fromDays: floorDiv(epoch, day))
        return String(format: "%04d-%02d-%02d", c.y, c.m, c.d)
    }

    /// Days since 1970-01-01 for a 'YYYY-MM-DD' key.
    static func parseDayKey(_ key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return days(fromCivil: parts[0], parts[1], parts[2])
    }

    /// Mon=1 … Sun=7 for a day number.
    static func isoWeekday(days d: Int) -> Int { ((d + 3) % 7 + 7) % 7 + 1 }

    /// ISO week key 'YYYY-Www' (UTC).
    static func weekKey(_ epoch: Int) -> String {
        let d = floorDiv(epoch, day)
        let thursday = d + 4 - isoWeekday(days: d)
        let year = civil(fromDays: thursday).y
        let week = (thursday - days(fromCivil: year, 1, 1)) / 7 + 1
        return String(format: "%04d-W%02d", year, week)
    }

    static func dayEnd(_ epoch: Int) -> Int { (floorDiv(epoch, day) + 1) * day }

    static func weekEnd(_ epoch: Int) -> Int {
        let d = floorDiv(epoch, day)
        return d * day + (8 - isoWeekday(days: d)) * day
    }

    // MARK: Levels

    static func xpForLevel(_ level: Int) -> Int {
        guard level > 1 else { return 0 }
        let n = Double(level - 1)
        return Int((100 * n + 15 * n * n + 0.9 * n * n * n).rounded())
    }

    static func levelForXP(_ xp: Int) -> Int {
        var level = 1
        while level < 200 && xp >= xpForLevel(level + 1) { level += 1 }
        return level
    }

    // MARK: Session XP and sanitising

    static func xpForWorkout(volume: Double, reps: Int, durationSecs: Int) -> Int {
        let volume = max(volume, 0)
        let reps = max(reps, 0)
        let secs = Double(max(durationSecs, 0))
        let xp = Int((pow(volume, 0.8) * 0.35 + Double(reps) * 0.5 + min(secs / 60, 120) * 1.5).rounded())
        if reps <= 0 && secs < 300 { return 0 }
        return max(10, xp)
    }

    struct CleanSet: Codable, Equatable { var reps: Int; var weight: Double }
    struct CleanExercise: Codable, Equatable {
        var key: String
        var name: String
        var category: String?
        var sets: [CleanSet]
    }
    struct CleanSession {
        var id: String
        var performedAt: Int
        var durationSecs: Int
        var volume: Double
        var reps: Int
        var exercises: [CleanExercise]
        var flagged: Bool
        var flagReason: String?
        var deleted: Bool
        var name: String?
    }

    static func exerciseKey(id: String?, name: String) -> String {
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return String(id.prefix(120)) }
        let clean = name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return String(clean.prefix(120))
    }

    /// syncrules.js evaluateSession: server-side totals and plausibility caps.
    /// A flagged session is kept for history but earns nothing.
    static func evaluate(_ s: SyncSession, now: Int) -> CleanSession {
        var reasons: [String] = []
        func flag(_ r: String) { if !reasons.contains(r) { reasons.append(r) } }
        let performedAt = s.performedAt > 0 ? s.performedAt : now
        if performedAt > now + 600 { flag("performed_at_future") }
        if performedAt < 1_577_836_800 { flag("performed_at_too_old") }
        let duration = max(0, s.durationSecs)
        if duration > 6 * 3600 { flag("duration_cap") }
        let raw = s.exercises ?? []
        if raw.count > 60 { flag("exercise_cap") }
        var exercises: [CleanExercise] = []
        var volume = 0.0
        var reps = 0
        for ex in raw.prefix(120) {
            let key = exerciseKey(id: ex.exerciseID, name: ex.name)
            guard !key.isEmpty else { continue }
            if ex.sets.count > 40 { flag("set_cap") }
            var sets: [CleanSet] = []
            for set in ex.sets.prefix(80) where set.reps >= 1 {
                if set.reps > 100 { flag("reps_cap") }
                if set.weight < 0 || set.weight > 1500 { flag("weight_cap") }
                sets.append(CleanSet(reps: set.reps, weight: set.weight))
                reps += set.reps
                volume += Double(set.reps) * max(set.weight, 0)
            }
            exercises.append(CleanExercise(key: key, name: ex.name, category: ex.category, sets: sets))
        }
        if raw.isEmpty {
            volume = max(0, s.totalVolume)
            reps = max(0, s.totalReps)
        }
        volume = (volume * 100).rounded() / 100
        if volume > 250_000 { flag("volume_cap") }
        if reps > 5000 { flag("reps_total_cap") }
        return CleanSession(
            id: s.id, performedAt: performedAt, durationSecs: duration, volume: volume, reps: reps,
            exercises: exercises, flagged: !reasons.isEmpty,
            flagReason: reasons.isEmpty ? nil : reasons.joined(separator: ","),
            deleted: s.deleted == true, name: s.name
        )
    }

    // MARK: Personal records

    static func estimated1RM(_ weight: Double, _ reps: Int) -> Double { (weight * (1 + Double(reps) / 30)).rounded() }

    /// syncrules.js bestSetsByExercise + detectPRs. `records` is key → "reps" → weight
    /// and is updated in place. Returns the PR count.
    static func detectPRs(_ exercises: [CleanExercise], records: inout [String: [String: Double]]) -> Int {
        var order: [String] = []
        var bestByKey: [String: [Int: Double]] = [:]
        for ex in exercises {
            for set in ex.sets where set.weight > 0 && set.reps >= 1 && set.reps <= 100 {
                if bestByKey[ex.key] == nil { bestByKey[ex.key] = [:]; order.append(ex.key) }
                if (bestByKey[ex.key]?[set.reps] ?? -1) < set.weight { bestByKey[ex.key]?[set.reps] = set.weight }
            }
        }
        var prCount = 0
        for key in order {
            let best = bestByKey[key] ?? [:]
            var known = records[key] ?? [:]
            if known.isEmpty {
                for (reps, weight) in best { known[String(reps)] = weight }
                records[key] = known
                continue
            }
            var bestE1rm = 0.0
            for (reps, weight) in known { bestE1rm = max(bestE1rm, estimated1RM(weight, Int(reps) ?? 0)) }
            for (reps, weight) in best.sorted(by: { $0.key < $1.key }) {
                let e1rm = estimated1RM(weight, reps)
                if let old = known[String(reps)] {
                    if weight > old { prCount += 1; known[String(reps)] = weight }
                } else {
                    known[String(reps)] = weight
                    if e1rm > bestE1rm { prCount += 1 }
                }
            }
            records[key] = known
        }
        return prCount
    }

    // MARK: Quests

    struct QuestDef {
        let key: String, title: String, desc: String, metric: String
        let target: Double, xp: Int, icon: String
        var absolute = false
    }

    static let dailyQuests: [QuestDef] = [
        QuestDef(key: "log_workout", title: "Show Up", desc: "Log a workout today", metric: "workouts", target: 1, xp: 40, icon: "figure.strengthtraining.traditional"),
        QuestDef(key: "volume_5k", title: "Move Iron", desc: "Move 5,000 lb of total volume", metric: "volume", target: 5000, xp: 60, icon: "scalemass.fill"),
        QuestDef(key: "reps_100", title: "Century", desc: "Complete 100 reps", metric: "reps", target: 100, xp: 50, icon: "repeat"),
        QuestDef(key: "minutes_30", title: "Half Hour Hero", desc: "Train for 30 minutes", metric: "minutes", target: 30, xp: 45, icon: "timer"),
        QuestDef(key: "react_friend", title: "Hype Squad", desc: "React to a household member's activity", metric: "reactions", target: 1, xp: 20, icon: "hands.clap.fill"),
        QuestDef(key: "volume_10k", title: "Heavy Day", desc: "Move 10,000 lb of total volume", metric: "volume", target: 10000, xp: 90, icon: "flame.fill"),
        QuestDef(key: "steps_8k", title: "Step Count", desc: "Walk 8,000 steps (Apple Health)", metric: "steps", target: 8000, xp: 50, icon: "figure.walk", absolute: true),
    ]

    static let weeklyQuests: [QuestDef] = [
        QuestDef(key: "workouts_3", title: "Consistency", desc: "Train 3 times this week", metric: "workouts", target: 3, xp: 150, icon: "calendar"),
        QuestDef(key: "workouts_5", title: "Grinder", desc: "Train 5 times this week", metric: "workouts", target: 5, xp: 250, icon: "calendar.badge.checkmark"),
        QuestDef(key: "volume_25k", title: "Ton Lifter", desc: "Move 25,000 lb this week", metric: "volume", target: 25000, xp: 200, icon: "scalemass.fill"),
        QuestDef(key: "set_pr", title: "New Heights", desc: "Set a personal record", metric: "prs", target: 1, xp: 175, icon: "trophy.fill"),
        QuestDef(key: "reps_500", title: "Volume Dealer", desc: "Complete 500 reps this week", metric: "reps", target: 500, xp: 180, icon: "repeat.circle.fill"),
        QuestDef(key: "add_friend", title: "Party Up", desc: "Add a player to your household", metric: "friends", target: 1, xp: 100, icon: "person.badge.plus"),
    ]

    static let dailyCount = 3
    static let weeklyCount = 2

    static func questDefinition(_ key: String) -> QuestDef? {
        dailyQuests.first { $0.key == key } ?? weeklyQuests.first { $0.key == key }
    }

    /// FNV-1a 32-bit over UTF-16 code units (JS charCodeAt).
    static func hash32(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811c_9dc5
        for unit in s.utf16 {
            h ^= UInt32(unit)
            h = h &* 0x0100_0193
        }
        return h
    }

    static func pickDeterministic(_ catalog: [QuestDef], count: Int, seed: String) -> [QuestDef] {
        var idx = Array(catalog.indices)
        var state = hash32(seed)
        if state == 0 { state = 1 }
        func next() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }
        var i = idx.count - 1
        while i > 0 {
            let j = Int(next() % UInt32(i + 1))
            idx.swapAt(i, j)
            i -= 1
        }
        return idx.prefix(min(count, catalog.count)).map { catalog[$0] }
    }

    struct BoardEntry {
        let def: QuestDef
        let kind: String
        let period: String
        let id: String
        let expiresAt: Int
    }

    static func board(for userID: String, at epoch: Int) -> [BoardEntry] {
        let dk = dayKey(epoch)
        let wk = weekKey(epoch)
        let daily = pickDeterministic(dailyQuests, count: dailyCount, seed: "\(userID)|daily|\(dk)").map {
            BoardEntry(def: $0, kind: "daily", period: dk, id: "\(userID):daily:\(dk):\($0.key)", expiresAt: dayEnd(epoch))
        }
        let weekly = pickDeterministic(weeklyQuests, count: weeklyCount, seed: "\(userID)|weekly|\(wk)").map {
            BoardEntry(def: $0, kind: "weekly", period: wk, id: "\(userID):weekly:\(wk):\($0.key)", expiresAt: weekEnd(epoch))
        }
        return daily + weekly
    }

    /// game.js advance: new progress for one event, capped at target.
    static func advance(questKey: String, target: Double, progress: Double, event: [String: Double]) -> Double {
        guard let def = questDefinition(questKey) else { return progress }
        let delta = event[def.metric] ?? 0
        guard delta > 0 else { return progress }
        let next = def.absolute ? max(progress, delta) : progress + delta
        return min(target, next)
    }

    static func eventForWorkout(volume: Double, reps: Int, durationSecs: Int, prs: Int) -> [String: Double] {
        ["workouts": 1, "volume": max(0, volume), "reps": Double(max(0, reps)),
         "minutes": Double(max(0, durationSecs)) / 60, "prs": Double(max(0, prs))]
    }

    // MARK: Achievements

    struct AchievementStats {
        var totalWorkouts = 0
        var longestStreak = 0
        var totalVolume = 0.0
        var level = 1
        var friendCount = 0
        var inGuild = false
        var raidsWon = 0
    }

    struct AchievementDef {
        let id: String, title: String, desc: String, rarity: String, xp: Int, icon: String
        let rule: (AchievementStats) -> Bool
    }

    static let achievements: [AchievementDef] = [
        AchievementDef(id: "first_workout", title: "First Blood", desc: "Complete your first workout", rarity: "common", xp: 50, icon: "figure.strengthtraining.traditional") { $0.totalWorkouts >= 1 },
        AchievementDef(id: "workouts_10", title: "Regular", desc: "Complete 10 workouts", rarity: "common", xp: 100, icon: "10.circle.fill") { $0.totalWorkouts >= 10 },
        AchievementDef(id: "workouts_50", title: "Dedicated", desc: "Complete 50 workouts", rarity: "rare", xp: 250, icon: "50.circle.fill") { $0.totalWorkouts >= 50 },
        AchievementDef(id: "workouts_100", title: "Century Club", desc: "Complete 100 workouts", rarity: "epic", xp: 500, icon: "medal.fill") { $0.totalWorkouts >= 100 },
        AchievementDef(id: "streak_7", title: "One Week Strong", desc: "Train 7 days in a row", rarity: "rare", xp: 200, icon: "flame.fill") { $0.longestStreak >= 7 },
        AchievementDef(id: "streak_30", title: "Iron Will", desc: "Train 30 days in a row", rarity: "legendary", xp: 750, icon: "flame.circle.fill") { $0.longestStreak >= 30 },
        AchievementDef(id: "volume_100k", title: "Volume King", desc: "Move 100,000 lb lifetime", rarity: "epic", xp: 400, icon: "crown.fill") { $0.totalVolume >= 100_000 },
        AchievementDef(id: "level_10", title: "Iron Disciple", desc: "Reach level 10", rarity: "common", xp: 100, icon: "arrow.up.circle.fill") { $0.level >= 10 },
        AchievementDef(id: "level_25", title: "Ironbound", desc: "Reach level 25", rarity: "rare", xp: 300, icon: "star.circle.fill") { $0.level >= 25 },
        AchievementDef(id: "level_50", title: "Legend", desc: "Reach level 50", rarity: "legendary", xp: 1000, icon: "sparkles") { $0.level >= 50 },
        AchievementDef(id: "first_friend", title: "Party of Two", desc: "Share this device with another player", rarity: "common", xp: 50, icon: "person.2.fill") { $0.friendCount >= 1 },
        AchievementDef(id: "guild_join", title: "Banner Raised", desc: "Join or found a household guild", rarity: "common", xp: 75, icon: "shield.lefthalf.filled") { $0.inGuild },
        AchievementDef(id: "raid_slayer", title: "Raid Slayer", desc: "Help defeat a weekly raid boss", rarity: "rare", xp: 150, icon: "bolt.shield.fill") { $0.raidsWon >= 1 },
    ]

    static func newlyUnlocked(_ stats: AchievementStats, have: Set<String>) -> [AchievementDef] {
        achievements.filter { !have.contains($0.id) && $0.rule(stats) }
    }

    // MARK: Talents

    enum TalentEffect {
        case xpPct(perRank: Int)
        case xpPctHeavy(perRank: Int, minVolume: Double)
        case xpPctStreak(perRank: Int, minStreak: Int)
        case xpPctFriends(perRank: Int, maxFriends: Int)
        case xpPctGuild(perRank: Int)
        case streakShield(daysPerRank: Int)
        case bonusPointEvery(levels: Int)
    }

    static let pointsPerTier = 3

    static let talentTree = TalentTree(
        version: 1,
        branches: [
            TalentBranch(id: "strength", name: "Strength", color: "red", icon: "dumbbell.fill"),
            TalentBranch(id: "endurance", name: "Endurance", color: "green", icon: "flame.fill"),
            TalentBranch(id: "community", name: "Community", color: "purple", icon: "person.3.fill"),
        ],
        nodes: [
            TalentNode(id: "iron_foundation", branch: "strength", tier: 1, maxRank: 5, requires: [], name: "Iron Foundation", icon: "dumbbell.fill", description: "+2% XP per rank on sessions moving at least 5,000 lb."),
            TalentNode(id: "heavy_hands", branch: "strength", tier: 2, maxRank: 3, requires: [.init(id: "iron_foundation", rank: 3)], name: "Heavy Hands", icon: "hand.raised.fill", description: "+3% XP per rank on sessions moving at least 15,000 lb."),
            TalentNode(id: "titan", branch: "strength", tier: 3, maxRank: 1, requires: [.init(id: "heavy_hands", rank: 3)], name: "Titan", icon: "mountain.2.fill", description: "Every 10th level grants one extra talent point."),
            TalentNode(id: "momentum", branch: "endurance", tier: 1, maxRank: 5, requires: [], name: "Momentum", icon: "flame.fill", description: "+5% XP per rank on every workout."),
            TalentNode(id: "streak_shield", branch: "endurance", tier: 2, maxRank: 2, requires: [.init(id: "momentum", rank: 3)], name: "Streak Shield", icon: "shield.checkered", description: "Your streak survives one missed day per rank."),
            TalentNode(id: "second_wind", branch: "endurance", tier: 3, maxRank: 3, requires: [.init(id: "streak_shield", rank: 1)], name: "Second Wind", icon: "wind", description: "+4% XP per rank while your streak is 7 days or longer."),
            TalentNode(id: "rally", branch: "community", tier: 1, maxRank: 5, requires: [], name: "Rally", icon: "person.2.fill", description: "+1% XP per rank for each household member, up to 5."),
            TalentNode(id: "guild_banner", branch: "community", tier: 2, maxRank: 3, requires: [.init(id: "rally", rank: 3)], name: "Guild Banner", icon: "flag.fill", description: "+3% XP per rank while you belong to a guild."),
            TalentNode(id: "mentor", branch: "community", tier: 3, maxRank: 1, requires: [.init(id: "guild_banner", rank: 2)], name: "Mentor", icon: "graduationcap.fill", description: "Every 5th level grants one extra talent point."),
        ]
    )

    static let talentEffects: [String: TalentEffect] = [
        "iron_foundation": .xpPctHeavy(perRank: 2, minVolume: 5000),
        "heavy_hands": .xpPctHeavy(perRank: 3, minVolume: 15000),
        "titan": .bonusPointEvery(levels: 10),
        "momentum": .xpPct(perRank: 5),
        "streak_shield": .streakShield(daysPerRank: 1),
        "second_wind": .xpPctStreak(perRank: 4, minStreak: 7),
        "rally": .xpPctFriends(perRank: 1, maxFriends: 5),
        "guild_banner": .xpPctGuild(perRank: 3),
        "mentor": .bonusPointEvery(levels: 5),
    ]

    static func pointsSpent(_ ranks: [String: Int]) -> Int { ranks.values.reduce(0, +) }

    static func pointsSpent(_ ranks: [String: Int], branch: String) -> Int {
        talentTree.nodes.filter { $0.branch == branch }.reduce(0) { $0 + (ranks[$1.id] ?? 0) }
    }

    /// nil when one more point can go into `talentID`, else the reason.
    static func validateSpend(_ ranks: [String: Int], unspent: Int, talentID: String) -> String? {
        guard let node = talentTree.nodes.first(where: { $0.id == talentID }) else { return "Unknown talent" }
        if unspent < 1 { return "No unspent talent points" }
        if (ranks[talentID] ?? 0) >= node.maxRank { return "Talent is already at max rank" }
        let needed = (node.tier - 1) * pointsPerTier
        if pointsSpent(ranks, branch: node.branch) < needed { return "Spend \(needed) points in \(node.branch) first" }
        for req in node.requires where (ranks[req.id] ?? 0) < req.rank {
            let name = talentTree.nodes.first { $0.id == req.id }?.name ?? req.id
            return "Requires \(name) rank \(req.rank)"
        }
        return nil
    }

    static func xpMultiplier(_ ranks: [String: Int], volume: Double, streak: Int, friends: Int, inGuild: Bool) -> Double {
        var pct = 0
        for node in talentTree.nodes {
            let rank = ranks[node.id] ?? 0
            guard rank > 0, let effect = talentEffects[node.id] else { continue }
            switch effect {
            case .xpPct(let per): pct += per * rank
            case .xpPctHeavy(let per, let minVolume): if volume >= minVolume { pct += per * rank }
            case .xpPctStreak(let per, let minStreak): if streak >= minStreak { pct += per * rank }
            case .xpPctFriends(let per, let maxFriends): pct += per * rank * min(max(friends, 0), maxFriends)
            case .xpPctGuild(let per): if inGuild { pct += per * rank }
            case .streakShield, .bonusPointEvery: break
            }
        }
        return 1 + Double(pct) / 100
    }

    static func applyTalentEffects(_ baseXP: Int, ranks: [String: Int], volume: Double, streak: Int, friends: Int, inGuild: Bool) -> Int {
        Int((Double(baseXP) * xpMultiplier(ranks, volume: volume, streak: streak, friends: friends, inGuild: inGuild)).rounded())
    }

    static func streakShieldDays(_ ranks: [String: Int]) -> Int { (ranks["streak_shield"] ?? 0) * 1 }

    static func bonusTalentPoints(_ ranks: [String: Int], from before: Int, to after: Int) -> Int {
        var bonus = 0
        for node in talentTree.nodes {
            guard case .bonusPointEvery(let every)? = talentEffects[node.id], (ranks[node.id] ?? 0) > 0,
                  after > before else { continue }
            for l in (before + 1)...after where l % every == 0 { bonus += 1 }
        }
        return bonus
    }

    // MARK: Challenges

    static let challengeXPWin = 150
    static let challengeXPDraw = 60
    static let challengeXPLoss = 25
    static let challengeXPGuildTop = 120
    static let challengeXPGuildPart = 20

    struct ChallengeSession { var performedAt: Int; var volume: Double }

    static func longestStreak(ofDays days: [Int]) -> Int {
        var best = 0, run = 0
        var prev: Int?
        for d in Set(days).sorted() {
            run = (prev != nil && d - prev! == 1) ? run + 1 : 1
            prev = d
            best = max(best, run)
        }
        return best
    }

    static func score(metric: String, sessions: [ChallengeSession]) -> Double {
        switch metric {
        case "workouts": return Double(sessions.count)
        case "streak": return Double(longestStreak(ofDays: sessions.map { floorDiv($0.performedAt, day) }))
        default: return sessions.reduce(0) { $0 + $1.volume }
        }
    }

    struct StandingRow { var userID: String; var score: Double; var sessions: Int; var rank: Int }

    static func standings(metric: String, startsAt: Int, endsAt: Int, participants: [String],
                          sessionsByUser: [String: [ChallengeSession]]) -> [StandingRow] {
        var rows = participants.map { id -> StandingRow in
            let mine = (sessionsByUser[id] ?? []).filter { $0.performedAt >= startsAt && $0.performedAt < endsAt }
            return StandingRow(userID: id, score: score(metric: metric, sessions: mine), sessions: mine.count, rank: 0)
        }
        rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.userID < $1.userID }
        var rank = 0
        var last: Double?
        for i in rows.indices {
            if rows[i].score != last { rank = i + 1; last = rows[i].score }
            rows[i].rank = rank
        }
        return rows
    }

    struct Settlement { var winnerID: String?; var draw: Bool; var awards: [(userID: String, amount: Int, reason: String)] }

    static func settle(kind: String, standings: [StandingRow]) -> Settlement {
        guard let top = standings.first?.score else { return Settlement(winnerID: nil, draw: true, awards: []) }
        let leaders = standings.filter { $0.score == top }
        if top <= 0 { return Settlement(winnerID: nil, draw: true, awards: []) }
        if kind == "duel" {
            if leaders.count > 1 {
                return Settlement(winnerID: nil, draw: true, awards: standings.map { ($0.userID, challengeXPDraw, "challenge_draw") })
            }
            let winner = leaders[0].userID
            return Settlement(winnerID: winner, draw: false, awards: standings.map {
                $0.userID == winner ? ($0.userID, challengeXPWin, "challenge_win") : ($0.userID, challengeXPLoss, "challenge_loss")
            })
        }
        let awards = standings.filter { $0.score > 0 }.map {
            $0.score == top ? ($0.userID, challengeXPGuildTop, "challenge_guild_top") : ($0.userID, challengeXPGuildPart, "challenge_guild_part")
        }
        return Settlement(winnerID: leaders.count == 1 ? leaders[0].userID : nil, draw: leaders.count > 1, awards: awards)
    }

    // MARK: Raids

    static let weekSecs = 7 * 86400
    static let mondayEpoch = 345_600

    static func weekStart(_ epoch: Int) -> Int { mondayEpoch + floorDiv(epoch - mondayEpoch, weekSecs) * weekSecs }
    static func weekIndex(_ epoch: Int) -> Int { (weekStart(epoch) - mondayEpoch) / weekSecs }

    static let bossCatalog: [RaidBoss] = [
        RaidBoss(id: "ironjaw", name: "Ironjaw the Plate Hoarder", flavor: "He has every 45 in the building and he is not re-racking them.", symbol: "dumbbell.fill", gradient: ["#8E8E93", "#1C1C1E"], rewardXP: 400, rewardTitle: "Plate Liberator", rewardCosmetic: "aura_iron"),
        RaidBoss(id: "cardio_wraith", name: "The Cardio Wraith", flavor: "Whispers \"just one more mile\" from inside the treadmill.", symbol: "figure.run", gradient: ["#5AC8FA", "#1D3557"], rewardXP: 380, rewardTitle: "Wraith Runner", rewardCosmetic: "aura_mist"),
        RaidBoss(id: "chalk_golem", name: "Chalk Golem", flavor: "Leaves a handprint on everything. Everything.", symbol: "hand.raised.fill", gradient: ["#F2F2F7", "#8E8E93"], rewardXP: 450, rewardTitle: "Dusted", rewardCosmetic: "aura_chalk"),
        RaidBoss(id: "squat_rack_curler", name: "The Squat-Rack Curler", flavor: "Twenty-pound curls, forty-minute sets, zero shame.", symbol: "figure.strengthtraining.traditional", gradient: ["#FF9F0A", "#7A2E00"], rewardXP: 420, rewardTitle: "Rack Reclaimer", rewardCosmetic: "aura_ember"),
        RaidBoss(id: "doms_dragon", name: "DOMS, the Two-Day Dragon", flavor: "You do not feel its bite today. You will feel it on Thursday.", symbol: "flame.fill", gradient: ["#FF375F", "#3A0A1A"], rewardXP: 500, rewardTitle: "Dragonsore", rewardCosmetic: "aura_crimson"),
        RaidBoss(id: "plateau_titan", name: "Plateau Titan", flavor: "Has held the same bench number for six years and calls it consistency.", symbol: "mountain.2.fill", gradient: ["#30D158", "#0B3D20"], rewardXP: 550, rewardTitle: "Plateau Breaker", rewardCosmetic: "aura_verdant"),
        RaidBoss(id: "mirror_lich", name: "The Mirror Lich", flavor: "Feeds on flexing. Weakens with every rep you do not film.", symbol: "sparkles", gradient: ["#BF5AF2", "#2A0A3D"], rewardXP: 480, rewardTitle: "Unfilmed", rewardCosmetic: "aura_violet"),
        RaidBoss(id: "rest_day_hydra", name: "Rest-Day Hydra", flavor: "Skip one session and two excuses grow back.", symbol: "bolt.heart.fill", gradient: ["#FFD60A", "#5A4500"], rewardXP: 520, rewardTitle: "Hydra Slayer", rewardCosmetic: "aura_gold"),
    ]

    static let bossBaseHP: [String: Int] = [
        "ironjaw": 60000, "cardio_wraith": 55000, "chalk_golem": 70000, "squat_rack_curler": 65000,
        "doms_dragon": 80000, "plateau_titan": 90000, "mirror_lich": 75000, "rest_day_hydra": 85000,
    ]

    static func bossForWeek(_ epoch: Int) -> RaidBoss {
        let i = weekIndex(epoch) % bossCatalog.count
        return bossCatalog[(i + bossCatalog.count) % bossCatalog.count]
    }

    static func hpForGuild(_ boss: RaidBoss, members: Int) -> Int {
        (bossBaseHP[boss.id] ?? 60000) * min(50, max(1, members))
    }

    static func raidDamage(volume: Double, prCount: Int) -> Int {
        Int((max(0, volume) + Double(min(20, max(0, prCount)) * 250)).rounded())
    }

    // MARK: Seasons

    static let seasonOneStart = days(fromCivil: 2026, 11, 2) * day
    static let seasonWeeks = 8
    static let seasonSecs = seasonWeeks * 7 * day
    static let tierCount = 30

    struct SeasonTheme { let key: String, name: String, theme: String; let auras: [(id: String, label: String, color: String)] }

    static let seasonThemes: [SeasonTheme] = [
        SeasonTheme(key: "iron_dawn", name: "Iron Dawn", theme: "First light on the platform. Build the base everything else stands on.", auras: [("aura_dawn", "Dawn Aura", "#FFB347"), ("aura_daybreak", "Daybreak Aura", "#FF7A45")]),
        SeasonTheme(key: "frostforge", name: "Frostforge", theme: "Cold iron, steady breath. Consistency through the dark months.", auras: [("aura_frost", "Frost Aura", "#8FD3FF"), ("aura_glacier", "Glacier Aura", "#4A90E2")]),
        SeasonTheme(key: "stormbreak", name: "Stormbreak", theme: "Speed and power. Every session hits like thunder.", auras: [("aura_storm", "Storm Aura", "#7B8CDE"), ("aura_thunder", "Thunder Aura", "#FFE066")]),
        SeasonTheme(key: "verdant_rise", name: "Verdant Rise", theme: "Growth season. Add a little every week and watch it compound.", auras: [("aura_sprout", "Sprout Aura", "#7ED957"), ("aura_grove", "Grove Aura", "#2E8B57")]),
        SeasonTheme(key: "emberfall", name: "Emberfall", theme: "The long, hot grind. Show up when it is hard.", auras: [("aura_cinder", "Cinder Aura", "#FF6B3D"), ("aura_inferno", "Inferno Aura", "#D7263D")]),
        SeasonTheme(key: "starfall", name: "Starfall", theme: "Finish the year strong. Chase the numbers you wrote down in January.", auras: [("aura_star", "Star Aura", "#C7B8FF"), ("aura_nova", "Nova Aura", "#F5E663")]),
    ]

    static let titleRanks = ["Wanderer", "Contender", "Stalwart", "Vanquisher", "Paragon", "Eternal"]
    static let talentPointTiers: Set<Int> = [4, 9, 14, 19, 24, 29]
    static let cosmeticTiers = [12, 27]

    static func seasonNumber(at epoch: Int) -> Int {
        epoch < seasonOneStart ? 0 : (epoch - seasonOneStart) / seasonSecs + 1
    }

    static func seasonID(_ number: Int) -> String { "s\(number)" }

    static func theme(for number: Int) -> SeasonTheme { seasonThemes[(max(1, number) - 1) % seasonThemes.count] }

    static func xpRequired(forTier tier: Int) -> Int {
        let t = max(0, tier)
        return 300 * t + 10 * t * (t - 1)
    }

    static func tier(forXP xp: Int) -> Int {
        var tier = 0
        while tier < tierCount && xp >= xpRequired(forTier: tier + 1) { tier += 1 }
        return tier
    }

    struct Reward { var type: String; var value: String; var label: String; var color: String? }

    static func reward(season number: Int, tier: Int) -> Reward {
        let th = theme(for: number)
        if tier % 5 == 0 {
            let title = "\(th.name) \(titleRanks[tier / 5 - 1])"
            return Reward(type: "title", value: title, label: "Title: \(title)")
        }
        if let i = cosmeticTiers.firstIndex(of: tier) {
            let aura = th.auras[i]
            return Reward(type: "cosmetic", value: aura.id, label: aura.label, color: aura.color)
        }
        if talentPointTiers.contains(tier) { return Reward(type: "talent_point", value: "1", label: "+1 talent point") }
        return Reward(type: "streak_freeze", value: "1", label: "+1 streak freeze")
    }

    // MARK: Streaks

    static let maxStreakFreezes = 3
    static let freezeMilestoneDays = 7

    struct StreakState: Codable, Equatable {
        var lastDate: String?
        var current = 0
        var longest = 0
        var freezes = 0
    }

    static func localDayKey(_ epoch: Int, tzOffsetMin: Int) -> String { dayKey(epoch + tzOffsetMin * 60) }

    static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let da = parseDayKey(a), let db = parseDayKey(b) else { return nil }
        return db - da
    }

    private static func cover(missed: Int, shieldDays: Int, freezes: Int) -> (alive: Bool, used: Int) {
        if missed <= shieldDays { return (true, 0) }
        let needed = missed - shieldDays
        return needed <= freezes ? (true, needed) : (false, 0)
    }

    /// streaks.js applySessionDay. Returns the new state and the transition.
    static func applySessionDay(_ state: StreakState, day: String, shieldDays: Int) -> (state: StreakState, transition: String, freezeEarned: Bool) {
        var s = state
        s.current = max(0, s.current)
        s.longest = max(0, s.longest)
        s.freezes = min(maxStreakFreezes, max(0, s.freezes))
        let gap = s.lastDate.flatMap { daysBetween($0, day) }
        var transition: String
        if s.lastDate == nil || gap == nil || s.current == 0 {
            if s.lastDate != nil, let g = gap, g < 0 { return (s, "past", false) }
            if s.lastDate != nil, gap == 0, s.current > 0 { transition = "same-day" } else { s.current = 1; transition = "start" }
        } else if let g = gap, g < 0 {
            return (s, "past", false)
        } else if gap == 0 {
            transition = "same-day"
        } else {
            let c = cover(missed: gap! - 1, shieldDays: shieldDays, freezes: s.freezes)
            if c.alive {
                s.freezes -= c.used
                s.current += 1
                transition = "continue"
            } else {
                s.current = 1
                transition = "reset"
            }
        }
        var earned = false
        if transition == "continue", s.current % freezeMilestoneDays == 0, s.freezes < maxStreakFreezes {
            s.freezes += 1
            earned = true
        }
        s.longest = max(s.longest, s.current)
        if transition != "same-day" { s.lastDate = day }
        return (s, transition, earned)
    }

    /// streaks.js effectiveStreak: the streak as of `today`, without writing.
    static func effectiveStreak(_ state: StreakState, today: String, shieldDays: Int) -> (alive: Bool, current: Int, freezes: Int) {
        let current = max(0, state.current)
        let freezes = min(maxStreakFreezes, max(0, state.freezes))
        guard let last = state.lastDate, current > 0 else { return (false, 0, freezes) }
        guard let gap = daysBetween(last, today), gap > 1 else { return (true, current, freezes) }
        let c = cover(missed: gap - 1, shieldDays: shieldDays, freezes: freezes)
        return c.alive ? (true, current, freezes - c.used) : (false, 0, freezes)
    }

    // MARK: Hero class

    static let heroWindowSecs = 28 * 86400
    static let recruitSessions = 3

    private static let categoryMap: [String: String] = [
        "strength": "strength", "powerlifting": "strength", "olympic weightlifting": "strength", "strongman": "strength",
        "cardio": "endurance", "stretching": "mobility", "plyometrics": "athletic",
    ]
    private static let nameRules: [(String, String)] = [
        ("strength", "farmer|carry|yoke|sled"),
        ("mobility", "stretch|yoga|mobility|foam roll|pilates|cat.cow|pigeon|child'?s pose"),
        ("athletic", "plyo|box jump|jump squat|broad jump|burpee|bound|skater|sprint|agility|tuck jump|depth jump|jump rope|clap push"),
        ("endurance", "\\brun|jog|treadmill|cycl|bike|elliptical|rowing machine|\\brower\\b|erg\\b|swim|walk|hike|stair|cardio|ski erg|assault|airdyne"),
    ]

    static func affinityCategory(category: String?, name: String) -> String {
        let cat = (category ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let mapped = categoryMap[cat] { return mapped }
        let lower = name.lowercased()
        for (bucket, pattern) in nameRules where lower.range(of: pattern, options: .regularExpression) != nil { return bucket }
        return "strength"
    }

    static func heroClass(affinity: [String: Double], totalSessions: Int) -> String {
        if totalSessions < recruitSessions { return "recruit" }
        let thresholds: [(String, String, Double)] = [
            ("juggernaut", "strength", 0.6), ("ranger", "endurance", 0.5), ("monk", "mobility", 0.4), ("striker", "athletic", 0.4),
        ]
        var best: (cls: String, share: Double)?
        for (cls, key, minShare) in thresholds {
            let share = affinity[key] ?? 0
            if share >= minShare && (best == nil || share > best!.share) { best = (cls, share) }
        }
        return best?.cls ?? "paladin"
    }

    // MARK: Titles and cosmetics

    static let rankTitles: [(level: Int, title: String)] = [
        (1, "Initiate"), (5, "Apprentice"), (10, "Iron Disciple"), (20, "Ironbound"), (30, "Vanguard"),
        (45, "Warbringer"), (60, "Champion"), (80, "Ascendant"), (100, "Endgame"),
    ]

    static func rankTitles(forLevel level: Int) -> [String] { rankTitles.filter { level >= $0.level }.map(\.title) }

    static func rankTitlesCrossed(from before: Int, to after: Int) -> [String] {
        rankTitles.filter { $0.level > before && $0.level <= after }.map(\.title)
    }
}
