//
//  EngineSelfTest.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  `EndgameFitness -ef.selftest` runs these checks against the local game
//  engine in a throwaway folder, prints PASS/FAIL lines and exits (0 = all
//  passed). Expected numbers marked "JS" were produced by running the old
//  backend modules (App/Backend/functions/_lib) under node, so a mismatch
//  means the Swift port drifted from the server rules.
//

import Foundation

enum EngineSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-ef.selftest") else { return }
        exit(run())
    }

    static func run() -> Int32 {
        var failures = 0
        var count = 0
        func check(_ name: String, _ ok: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if ok() {
                print("PASS \(name)")
            } else {
                failures += 1
                print("FAIL \(name) \(detail())")
            }
        }

        // MARK: Pure rules vs the JS backend
        let t = 1_794_830_400 // 2026-11-16T12:00:00Z (Monday)
        check("dayKey (JS)", GameRules.dayKey(t) == "2026-11-16", GameRules.dayKey(t))
        check("weekKey (JS)", GameRules.weekKey(t) == "2026-W47", GameRules.weekKey(t))
        check("weekKey year edge (JS)", GameRules.weekKey(1_798_761_600) == "2026-W53", GameRules.weekKey(1_798_761_600))
        check("dayEnd/weekEnd (JS)", GameRules.dayEnd(t) == 1_794_873_600 && GameRules.weekEnd(t) == 1_795_392_000)

        // Rolling "X on / Y off" schedule: 3 on / 1 off from a fixed start.
        do {
            let cal = Calendar(identifier: .gregorian)
            let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9))!
            let slots = (0..<9).map { WorkoutManager.rollingSlot(on: cal.date(byAdding: .day, value: $0, to: start)!,
                                                                start: start, daysOn: 3, daysOff: 1, calendar: cal) }
            check("rolling 3on/1off pattern", slots == [0, 1, 2, nil, 0, 1, 2, nil, 0], "\(slots)")
            let before = WorkoutManager.rollingSlot(on: cal.date(byAdding: .day, value: -1, to: start)!,
                                                    start: start, daysOn: 3, daysOff: 1, calendar: cal)
            check("rolling before start wraps", before == nil, "\(String(describing: before))")
            var c = ProgramConfig(); c.scheduleMode = .rolling; c.daysOn = 3; c.daysOff = 1
            check("rolling effective frequency", c.effectiveDaysPerWeek == 5 && c.sessionCount == 3)
        }
        check("hash32 FNV-1a (JS)", GameRules.hash32("player-1|daily|2026-11-16") == 1_147_006_096,
              "\(GameRules.hash32("player-1|daily|2026-11-16"))")
        let board = GameRules.board(for: "player-1", at: t).map(\.def.key).joined(separator: ",")
        check("quest board selection (JS)", board == "steps_8k,react_friend,minutes_30,workouts_5,workouts_3", board)
        check("xpForWorkout (JS)", GameRules.xpForWorkout(volume: 5000, reps: 50, durationSecs: 1800) == 389
              && GameRules.xpForWorkout(volume: 0, reps: 0, durationSecs: 200) == 0
              && GameRules.xpForWorkout(volume: 12345.5, reps: 120, durationSecs: 4000) == 817,
              "\(GameRules.xpForWorkout(volume: 5000, reps: 50, durationSecs: 1800)) \(GameRules.xpForWorkout(volume: 12345.5, reps: 120, durationSecs: 4000))")
        check("season start/number (JS)", GameRules.seasonOneStart == 1_793_577_600 && GameRules.seasonNumber(at: t) == 1)
        check("season tiers (JS)", GameRules.xpRequired(forTier: 5) == 1700 && GameRules.tier(forXP: 2000) == 5
              && GameRules.reward(season: 1, tier: 12).value == "aura_dawn")
        check("raid boss rotation (JS)", GameRules.bossForWeek(t).id == "rest_day_hydra" && GameRules.weekStart(t) == 1_794_787_200)
        check("level curve", GameRules.xpForLevel(2) == 116 && GameRules.levelForXP(115) == 1 && GameRules.levelForXP(116) == 2)

        // Streaks: shield then freezes cover gaps; past days don't move it.
        var st = GameRules.StreakState()
        st = GameRules.applySessionDay(st, day: "2026-11-01", shieldDays: 0).state
        st = GameRules.applySessionDay(st, day: "2026-11-02", shieldDays: 0).state
        check("streak continue", st.current == 2 && st.longest == 2)
        st.freezes = 1
        let covered = GameRules.applySessionDay(st, day: "2026-11-05", shieldDays: 1)
        check("streak shield+freeze cover 2 missed days", covered.state.current == 3 && covered.state.freezes == 0, "\(covered)")
        check("streak late session is 'past'", GameRules.applySessionDay(covered.state, day: "2026-10-01", shieldDays: 0).transition == "past")
        check("streak breaks", GameRules.applySessionDay(covered.state, day: "2026-11-09", shieldDays: 0).state.current == 1)

        // Talents
        check("talent tier gate", GameRules.validateSpend([:], unspent: 3, talentID: "heavy_hands") != nil)
        check("talent multiplier", GameRules.applyTalentEffects(100, ranks: ["momentum": 2, "iron_foundation": 1],
                                                                 volume: 6000, streak: 0, friends: 0, inGuild: false) == 112)

        // PRs: first log is a baseline, beating a rep count is a PR.
        var records: [String: [String: Double]] = [:]
        let bench = GameRules.CleanExercise(key: "bench", name: "Bench", category: "strength",
                                            sets: [.init(reps: 5, weight: 185)])
        check("PR baseline", GameRules.detectPRs([bench], records: &records) == 0)
        var heavier = bench
        heavier.sets = [.init(reps: 5, weight: 195)]
        check("PR beaten", GameRules.detectPRs([heavier], records: &records) == 1)

        // MARK: Engine scenario in a temp folder
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ef-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = LocalGame(store: LocalGameStore(root: root))
        var clock = t
        game.clock = { clock }
        game.tzOffsetMin = 0
        var roster: [(id: String, name: String)] = [("alice", "Alice")]
        game.roster = { roster }

        func session(_ id: String, at: Int, sets: Int = 5, reps: Int = 5, weight: Double = 200) -> SyncSession {
            SyncSession(id: id, performedAt: at, name: "Push", programID: nil, durationSecs: 2400,
                        totalVolume: 0, totalReps: 0, xpEarned: nil, clientRev: 1,
                        exercises: [SyncExercise(name: "Bench Press", exerciseID: "bench", category: "strength",
                                                 sets: Array(repeating: .init(reps: reps, weight: weight), count: sets))])
        }

        let first = game.apply(session("s1", at: t - 3600), to: "alice")
        let a1 = game.store.state("alice")
        let expectedXP = GameRules.xpForWorkout(volume: 5000, reps: 25, durationSecs: 2400)
        check("workout XP applied", first.xpGained == expectedXP && a1.xp >= expectedXP, "\(first.xpGained) vs \(expectedXP)")
        check("first_workout achievement", first.unlocked.contains("first_workout"), "\(first.unlocked)")
        check("totals", a1.totalWorkouts == 1 && a1.totalVolume == 5000 && a1.totalReps == 25)
        check("streak started", a1.streak.current == 1)
        let replay = game.apply(session("s1", at: t - 3600), to: "alice")
        check("replay is a no-op", replay.xpGained == 0 && game.store.state("alice").totalWorkouts == 1)
        check("raid damage", first.raid?.damage == 5000, "\(String(describing: first.raid))")
        check("feed post", game.store.household().feed.contains { $0.kind == "workout" && $0.userID == "alice" })

        let q = game.activeQuests("alice")
        check("board has 3 daily + 2 weekly", q.filter { $0.kind == "daily" }.count == 3 && q.filter { $0.kind == "weekly" }.count == 2)
        if let done = q.first(where: { $0.completedAt != nil }) {
            let before = game.store.state("alice").xp
            if case .success(let r) = game.claimQuest("alice", questID: done.id) {
                check("quest claim pays XP", game.store.state("alice").xp >= before + r.xp && r.xp == done.xpReward)
            } else { check("quest claim pays XP", false) }
            if case .success(let again) = game.claimQuest("alice", questID: done.id) {
                check("quest claim is idempotent", again.xp == 0)
            }
        } else {
            check("a workout completed some quest", q.contains { $0.questKey == "workouts_3" || $0.questKey == "workouts_5" || $0.questKey == "minutes_30" } , "\(q.map(\.questKey))")
        }

        // Edit lowers volume: totals follow, XP does not move.
        var edited = session("s1", at: t - 3600, sets: 2)
        edited.clientRev = 2
        let xpBeforeEdit = game.store.state("alice").xp
        game.apply(edited, to: "alice")
        check("edit adjusts totals, keeps XP", game.store.state("alice").totalVolume == 2000 && game.store.state("alice").xp == xpBeforeEdit)
        var tomb = edited
        tomb.clientRev = 3
        tomb.deleted = true
        game.apply(tomb, to: "alice")
        check("delete removes totals and posts", game.store.state("alice").totalWorkouts == 0
              && !game.store.household().feed.contains { $0.sessionID == "s1" })

        // Household: second player, guild, duel.
        roster.append(("bob", "Bob"))
        game.playerJoined("bob")
        check("party-up achievement", game.store.state("alice").achievements["first_friend"] != nil)
        check("guild create", game.createGuild("alice", name: "Bates House", motto: "", emblem: nil, isOpen: true) == nil)
        check("guild join", game.joinGuild("bob") == nil && game.inGuild("bob"))
        check("duel create", game.createChallenge("alice", kind: "duel", metric: "volume", opponentID: "bob", days: 3) == nil)
        let duel = game.store.household().challenges[0]
        check("duel accept", game.respondToChallenge("bob", challengeID: duel.id, accept: true) == nil)
        clock += 3600
        game.apply(session("a2", at: clock), to: "alice")
        game.apply(session("b1", at: clock, sets: 1), to: "bob")
        clock += 4 * 86400
        let aliceXP = game.store.state("alice").xp
        game.settleChallenges()
        let settled = game.store.household().challenges.first { $0.id == duel.id }
        check("duel settles to the bigger volume", settled?.status == "finished" && settled?.winnerID == "alice", "\(String(describing: settled))")
        check("duel win XP", game.store.state("alice").xp >= aliceXP + GameRules.challengeXPWin)

        // Raid kill: enough volume to drop a two-member boss.
        let raid = game.currentRaid("alice")
        check("guild raid scales with members", raid.memberCount == 2 && raid.hp == GameRules.hpForGuild(GameRules.bossForWeek(clock), members: 2))
        var hit: RaidHit?
        var n = 0
        while (hit?.defeated ?? false) == false && n < 200 {
            hit = game.hitRaid("alice", damage: 25_000)
            n += 1
        }
        check("raid boss defeated", hit?.justDefeated == true || hit?.defeated == true)
        check("raid rewards everyone who hit", game.store.state("alice").raidsWon == 1 && game.store.state("bob").raidsWon == 1)

        // Talents + season
        var alice = game.store.state("alice")
        alice.talentPoints = 4
        game.store.save(alice, for: "alice")
        check("talent spend", game.spendTalent("alice", talentID: "momentum") == nil && game.store.state("alice").talentRanks["momentum"] == 1)
        game.respec("alice")
        check("talent respec refunds", game.store.state("alice").talentPoints == 4 && game.store.state("alice").talentRanks.isEmpty)
        alice = game.store.state("alice")
        alice.seasonXP[GameRules.seasonID(GameRules.seasonNumber(at: clock))] = 5000
        game.store.save(alice, for: "alice")
        check("season tier claim", game.claimSeasonTier("alice", tier: 5) == nil && game.claimSeasonTier("alice", tier: 5) != nil)

        // Persistence round trip through a fresh store.
        let reread = LocalGameStore(root: root).state("alice")
        check("state persists to disk", reread == game.store.state("alice"))
        let encoded = try? JSONEncoder().encode(reread)
        check("state JSON round trip", encoded.flatMap { try? JSONDecoder().decode(PlayerGameState.self, from: $0) } == reread)

        // The views' models are built from server-shaped dictionaries with nils.
        let title: String? = nil
        let shape: [String: Any?] = [
            "user_id": "alice", "display_name": "Alice", "level": 3, "xp": 400, "title": title,
            "is_public": true, "earned_titles": ["Initiate"], "class_affinity": ["strength": 1.0],
            "avatar_config": AvatarBodyProfile.defaultBlob.wireObject,
        ]
        let profile = GameProfileService.decodeShape(FitnessProfile.self, shape)
        check("profile model from local shape", profile?.displayName == "Alice" && profile?.level == 3
              && profile?.title == nil && profile?.avatarConfig != nil, "\(String(describing: profile))")
        let item = GameProfileService.decodeShape(ActivityItem.self, [
            "id": "f1", "user_id": "alice", "kind": "pr", "summary": "x", "created_at": 1,
            "reactions": [["emoji": "fire", "count": 2, "mine": true]], "author_cosmetic": title,
        ] as [String: Any?])
        check("feed model from local shape", item?.reactions.first?.count == 2 && item?.kind == "pr")

        // Friend codes: round trip, deep link, tamper rejection, rival update events.
        let card = PlayerCard(id: "p1", name: "Alex", symbol: "bolt.fill", colorIndex: 2, level: 7, xp: 1200,
                              heroClass: "strength", title: nil, weekKey: "2026-W47", weeklyVolume: 12345, weeklyWorkouts: 3,
                              streak: 4, longestStreak: 9, totalWorkouts: 40, raidDamage: 900,
                              prs: [.init(exercise: "bench press", e1rm: 225)], issuedAt: 1_700_000_000)
        let code = PlayerCardCode.encode(card)
        check("card code round trip", (try? PlayerCardCode.decode(code)) == card, code)
        check("card deep link decodes", (try? PlayerCardCode.decode("hey add me " + PlayerCardCode.deepLink(card).absoluteString + " thx")) == card)
        var tampered = card
        tampered.level = 99
        let forged = PlayerCardCode.encode(tampered).split(separator: ".")
        let mixed = "\(forged[0]).\(forged[1]).\(code.split(separator: ".")[2])"
        check("tampered card rejected", (try? PlayerCardCode.decode(mixed)) == nil)
        check("card QR renders", PlayerCardCode.qrImage(PlayerCardCode.deepLink(card).absoluteString) != nil)
        var newer = card
        newer.level = 8
        newer.issuedAt += 60
        newer.prs = [.init(exercise: "bench press", e1rm: 235)]
        let events = RivalStore.changes(from: card, to: newer)
        check("rival update events", events.count == 2, "\(events.map(\.text))")

        // Rival card: every field survives encode/decode, and importing it twice keeps one rival.
        check("card all fields round trip", (try? PlayerCardCode.decode(code)).map {
            $0.prs == card.prs && $0.weekKey == card.weekKey && $0.raidDamage == card.raidDamage && $0.symbol == card.symbol
        } == true)
        check("garbage card rejected", (try? PlayerCardCode.decode("not a code")) == nil)

        // Player backup: JSON round trip keeps game state; re-keying moves quests to the new id.
        let aliceState = game.store.state("alice")
        let backup = LocalPlayerStore.Backup(exportedAt: clock, player: LocalPlayer(id: "alice", name: "Alice", symbol: "bolt.fill",
                                             colorIndex: 1, pinHash: nil, createdAt: clock, storeKey: "k"),
                                             game: aliceState, workouts: Data("[]".utf8))
        let backupData = try? JSONEncoder().encode(backup)
        let restored = backupData.flatMap { try? JSONDecoder().decode(LocalPlayerStore.Backup.self, from: $0) }
        check("backup JSON round trip", restored?.game == aliceState && restored?.player.name == "Alice"
              && restored?.workouts == Data("[]".utf8) && restored?.format == "endgame-fitness-player")
        let rekeyed = LocalPlayerStore.rekeyed(aliceState, from: "alice", to: "zed")
        check("backup re-keys quests", rekeyed.quests.count == aliceState.quests.count
              && rekeyed.quests.values.allSatisfy { !$0.id.contains("alice") } && rekeyed.xp == aliceState.xp,
              "\(rekeyed.quests.keys.sorted())")

        // Progression over a week of training: level, achievements, quests and raid all move.
        let pRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ef-selftest-prog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pRoot) }
        let prog = LocalGame(store: LocalGameStore(root: pRoot))
        var pClock = t
        prog.clock = { pClock }
        prog.tzOffsetMin = 0
        prog.roster = { [("carol", "Carol")] }
        var totalXP = 0, totalPRs = 0
        for d in 0..<7 {
            pClock = t + d * 86_400
            let o = prog.apply(session("p\(d)", at: pClock - 600, sets: 6, reps: 8, weight: 185 + Double(d * 5)), to: "carol")
            totalXP += o.xpGained
            totalPRs += o.prCount
        }
        let c = prog.store.state("carol")
        check("week: XP accumulates", c.xp >= totalXP && totalXP > 0 && c.totalWorkouts == 7, "\(c.xp) / \(totalXP)")
        check("week: level up", c.level == GameRules.levelForXP(c.xp) && c.level > 1, "lvl \(c.level)")
        check("week: streak 7", c.streak.current == 7, "\(c.streak)")
        check("week: achievements unlocked", c.achievements["first_workout"] != nil && c.achievements.count >= 2, "\(c.achievements.keys.sorted())")
        check("week: PRs counted", totalPRs >= 1, "\(totalPRs)")
        check("week: solo raid took damage", (prog.currentRaid("carol").damage["carol"] ?? 0) > 0, "\(prog.currentRaid("carol"))")

        // Session length: presets reach 2 hours and generated work scales with time.
        func work(_ ex: [String]) -> Int {
            ex.reduce(0) { total, e in
                if let r = e.range(of: #"(\d+)x"#, options: .regularExpression) {
                    return total + (Int(e[r].dropLast()) ?? 1)
                }
                return total + 1
            }
        }
        check("session presets reach 120", SessionLength.presets.last == 120 && SessionLength.range == 15...120)
        check("session clamp", SessionLength.clamp(7) == 15 && SessionLength.clamp(200) == 120 && SessionLength.clamp(62) == 60)
        for group in ["Full Body", "Push", "Pull", "Legs", "Upper", "Lower", "Chest", "Back", "Shoulders", "Arms", "Other"] {
            for focus in ["Strength", "Muscle Building", "Fat Loss", "Endurance", "General Fitness"] {
                let short = WorkoutManager.generateExercises(for: group, duration: 45, focus: focus)
                let long = WorkoutManager.generateExercises(for: group, duration: 120, focus: focus)
                let tiny = WorkoutManager.generateExercises(for: group, duration: 15, focus: focus)
                if !(work(long) > work(short) && !tiny.isEmpty && long.count >= short.count) {
                    check("session scales \(group)/\(focus)", false, "45:\(short) 120:\(long)")
                }
            }
        }
        let fb120 = WorkoutManager.generateExercises(for: "Full Body", duration: 120, focus: "Strength")
        check("120-min session has more work than 45", work(fb120) > work(WorkoutManager.generateExercises(for: "Full Body", duration: 45, focus: "Strength")), "\(fb120)")
        check("15-min session is short", (2...3).contains(WorkoutManager.generateExercises(for: "Push", duration: 15, focus: "Strength").count))
        for g in MesoPhase.TemplateGoal.allCases {
            for w in [4, 6, 12, 24] {
                let ph = MesoPhase.template(goal: g, weeks: w)
                if ph.reduce(0, { $0 + $1.weeks }) != w || ph.contains(where: { $0.weeks < 1 }) {
                    check("phase template \(g)/\(w)", false, "\(ph.map(\.weeks))")
                }
            }
        }
        check("phase templates sum to cycle length", true)

        print(failures == 0 ? "SELFTEST PASS \(count)/\(count)" : "SELFTEST FAIL \(failures) of \(count)")
        return failures == 0 ? 0 : 1
    }
}
