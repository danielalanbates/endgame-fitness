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
        if CommandLine.arguments.contains("-ef.plandump") { SmartPlanner.dumpSamples(); exit(0) }
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
            // Rotation keeps going across cycles (no Push twice in a 4-day block).
            let idx = (0..<10).map { WorkoutManager.trainingDayIndex(on: cal.date(byAdding: .day, value: $0, to: start)!,
                start: start, rolling: true, daysOn: 4, daysOff: 1, weekdays: [], calendar: cal) }
            check("rolling 4on/1off training index", idx == [0, 1, 2, 3, nil, 4, 5, 6, 7, nil], "\(idx)")
            let ppl = ProgramSplit.ppl.rotation.map(\.label)
            let firstEight = (0..<8).map { ppl[$0 % 3] }
            check("PPL rotation continuous", firstEight == ["Push Day", "Pull Day", "Leg Day", "Push Day", "Pull Day", "Leg Day", "Push Day", "Pull Day"])
            check("schedule length lcm", WorkoutManager.lcm(4, 3) == 12 && WorkoutManager.lcm(3, 3) == 3 && WorkoutManager.lcm(5, 5) == 5)
            // 2026-11-16 is a Monday; Mon/Wed/Fri plan.
            let wk = (0..<8).map { WorkoutManager.trainingDayIndex(on: cal.date(byAdding: .day, value: $0, to: start)!,
                start: start, rolling: false, daysOn: 0, daysOff: 0, weekdays: ["Monday", "Wednesday", "Friday"], calendar: cal) }
            check("weekly training index", wk == [0, nil, 1, nil, 2, nil, nil, 3], "\(wk)")
            var sa = ProgramConfig(); sa.split = .auto; sa.daysPerWeek = 4; sa.experienceLevel = .intermediate; sa.primaryGoal = .buildMuscle
            check("Smart Advisor 4-day size = PHUL", WorkoutManager.shared.resolvedSplit(for: sa) == .phul)
            sa.scheduleMode = .rolling; sa.daysOn = 3; sa.daysOff = 1
            check("Smart Advisor never mismatched", WorkoutManager.shared.resolvedSplit(for: sa) != .auto)
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

        // MARK: Smart coach (SmartCoach.swift): deterministic, no defaults read.
        do {
            let cal = Calendar(identifier: .gregorian)
            let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 9))!
            func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: base)! }
            func ex(_ name: String, _ lo: Int, _ hi: Int, lower: Bool = false, sets: [(Double, Int, Int?)] = []) -> Exercise {
                var e = Exercise(name: name, primaryMuscles: [lower ? "quadriceps" : "chest"], tracking: .weighted,
                                 targetRepMin: lo, targetRepMax: hi)
                e.sets = sets.map { ExerciseSet(reps: $0.1, weight: $0.0, completed: true, rir: $0.2) }
                return e
            }
            func sess(_ d: Int, _ e: Exercise) -> WorkoutSession {
                WorkoutSession(date: day(d), exercises: [e], completed: true)
            }
            func near(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) <= tol }
            var ctx = CoachContext(); ctx.unit = .lb; ctx.deloadEnabled = false
            let now = day(40)

            // e1RM formulas and RPE chart
            check("coach brzycki/epley", near(SmartCoach.brzycki(weight: 100, reps: 5), 112.5)
                  && near(SmartCoach.epley(weight: 100, reps: 5), 116.667, 0.01))
            check("coach e1RM blend", near(SmartCoach.e1RM(weight: 100, reps: 5), 114.583, 0.01)
                  && SmartCoach.e1RM(weight: 100, reps: 1) == 100 && near(SmartCoach.e1RM(weight: 100, reps: 12), 140))
            check("coach e1RM from RIR", near(SmartCoach.e1RM(weight: 100, reps: 5, rir: 0), 100 / 0.863, 0.01))
            check("coach RPE chart", SmartCoach.percentOf1RM(reps: 1, rpe: 10) == 1.0
                  && near(SmartCoach.percentOf1RM(reps: 5, rpe: 8), 0.811)
                  && near(SmartCoach.percentOf1RM(reps: 3, rpe: 8.5), 0.8775, 0.0001))
            check("coach RPE load", near(SmartCoach.load(e1RM: 200, reps: 5, rpe: 8), 162.2, 0.01))

            // Plate rounding
            check("coach plate round lb", SmartCoach.roundToLoadable(187, unit: .lb) == 185
                  && SmartCoach.roundToLoadable(188, unit: .lb) == 190
                  && SmartCoach.roundToLoadable(52, unit: .lb, equipment: "dumbbell") == 50)
            check("coach plate round kg", near(TrainingUnits.toDisplay(SmartCoach.roundToLoadable(101, unit: .kg), .kg), 45))

            // Linear
            ctx.model = .linear
            let bench = ex("Coach Bench", 5, 5, sets: [(135, 5, nil), (135, 5, nil), (135, 5, nil)])
            let pLin = SmartCoach.prescribe(exercise: bench, history: [sess(0, bench)], context: ctx, now: now)
            check("coach linear upper +5", pLin?.kind == .increase && pLin?.topLoad == 140 && pLin?.topReps == 5
                  && (pLin?.reason.hasPrefix("+5 lb: hit 3×5") ?? false), "\(String(describing: pLin))")
            let squat = ex("Coach Squat", 5, 5, lower: true, sets: [(135, 5, nil), (135, 5, nil), (135, 5, nil)])
            check("coach linear lower +10", SmartCoach.prescribe(exercise: squat, history: [sess(0, squat)], context: ctx, now: now)?.topLoad == 145)
            var kctx = ctx; kctx.unit = .kg
            let kgTop = TrainingUnits.toPounds(60, from: .kg)
            let benchKg = ex("Coach Bench", 5, 5, sets: [(kgTop, 5, nil), (kgTop, 5, nil)])
            let pKg = SmartCoach.prescribe(exercise: benchKg, history: [sess(0, benchKg)], context: kctx, now: now)
            check("coach linear kg +2.5", near(TrainingUnits.toDisplay(pKg?.topLoad ?? 0, .kg), 62.5), "\(String(describing: pKg))")
            let benchMiss = ex("Coach Bench", 5, 5, sets: [(135, 5, nil), (135, 4, nil)])
            let pHold = SmartCoach.prescribe(exercise: benchMiss, history: [sess(0, benchMiss)], context: ctx, now: now)
            check("coach linear hold on miss", pHold?.kind == .hold && pHold?.topLoad == 135)

            // Double progression
            ctx.model = .double
            let curlTop = ex("Coach Curl", 8, 12, sets: [(100, 12, nil), (100, 12, nil), (100, 12, nil)])
            let pRoll = SmartCoach.prescribe(exercise: curlTop, history: [sess(0, curlTop)], context: ctx, now: now)
            check("coach double rollover", pRoll?.kind == .increase && pRoll?.topLoad == 105 && pRoll?.topReps == 8, "\(String(describing: pRoll))")
            let curlMid = ex("Coach Curl", 8, 12, sets: [(100, 10, nil), (100, 9, nil), (100, 9, nil)])
            let pAdd = SmartCoach.prescribe(exercise: curlMid, history: [sess(0, curlMid)], context: ctx, now: now)
            check("coach double add reps", pAdd?.kind == .addReps && pAdd?.topReps == 11 && pAdd?.topLoad == 100)
            let curlRIR0 = ex("Coach Curl", 8, 12, sets: [(100, 12, 0), (100, 12, 0)])
            check("coach double needs RIR 1+", SmartCoach.prescribe(exercise: curlRIR0, history: [sess(0, curlRIR0)], context: ctx, now: now)?.kind == .addReps)

            // Stall -> reset
            let flat = ex("Coach Row", 8, 12, sets: [(100, 10, nil), (100, 10, nil), (100, 10, nil)])
            let flatHist = (0..<5).map { sess($0 * 3, flat) }
            let stState = SmartCoach.state(key: flat.identityKey, history: flatHist, repRange: 8...12, now: now)
            check("coach stall detected", stState?.isStalled == true && stState?.needsDeload == false)
            let pReset = SmartCoach.prescribe(exercise: flat, history: flatHist, context: ctx, now: now)
            check("coach stall reset -10%", pReset?.kind == .reset && pReset?.topLoad == 90, "\(String(describing: pReset))")
            check("coach no stall with 3 exposures", SmartCoach.state(key: flat.identityKey, history: Array(flatHist.prefix(3)), now: now)?.isStalled == false)

            // Fatigue deload triggers
            let ok = ex("Coach Press", 8, 12, sets: [(100, 9, nil), (100, 9, nil)])
            let miss = ex("Coach Press", 8, 12, sets: [(100, 8, nil), (100, 6, nil)])
            let pMiss = SmartCoach.prescribe(exercise: miss, history: [sess(0, ok), sess(3, miss), sess(6, miss)], context: ctx, now: now)
            check("coach deload on missed reps x2", pMiss?.kind == .deload && pMiss?.topLoad == 90, "\(String(describing: pMiss))")
            let pOne = SmartCoach.prescribe(exercise: miss, history: [sess(0, ok), sess(3, miss)], context: ctx, now: now)
            check("coach one miss is not a deload", pOne?.kind != .deload)
            let r3 = ex("Coach Press", 8, 12, sets: [(100, 9, 3)]), r2 = ex("Coach Press", 8, 12, sets: [(100, 9, 2)]),
                r1 = ex("Coach Press", 8, 12, sets: [(100, 9, 1)])
            let creepState = SmartCoach.state(key: r3.identityKey, history: [sess(0, r3), sess(3, r2), sess(6, r1)], repRange: 8...12, now: now)
            check("coach effort creep", creepState?.effortCreep == true && (creepState?.readiness ?? 100) < 100)
            var dctx = ctx; dctx.deloadEnabled = true; dctx.cycleWeeks = 4; dctx.weekInCycle = 4
            let pWeek = SmartCoach.prescribe(exercise: curlMid, history: [sess(0, curlMid)], context: dctx, now: now)
            check("coach planned deload week", pWeek?.kind == .deload && pWeek?.sets.count == 2 && pWeek?.topLoad == 90, "\(String(describing: pWeek))")
            dctx.weekInCycle = 3
            check("coach no deload before last week", SmartCoach.prescribe(exercise: curlMid, history: [sess(0, curlMid)], context: dctx, now: now)?.kind != .deload)

            // RPE / RIR autoregulation
            ctx.model = .rpe; ctx.goal = .getStronger
            let dl = ex("Coach Pull", 3, 6, sets: [(200, 5, 2)])
            let pRPE = SmartCoach.prescribe(exercise: dl, history: [sess(0, dl), sess(3, dl)], context: ctx, now: now)
            // e1RM = 200 / 0.811 = 246.6; 3 reps @ 8.5 = 0.8775 -> 216.4 -> 215
            check("coach RPE prescription", pRPE?.kind == .autoregulated && pRPE?.topLoad == 215 && pRPE?.topReps == 3
                  && pRPE?.targetRPE == 8.5, "\(String(describing: pRPE))")

            // Percentage waves and blocks
            ctx.model = .waves; ctx.cycleWeeks = 6; ctx.weekInCycle = 0
            let one = ex("Coach Pull", 1, 1, sets: [(200, 1, nil)])
            let pW1 = SmartCoach.prescribe(exercise: one, history: [sess(0, one)], context: ctx, now: now)
            // TM = 180: 117 -> 115, 135, 153 -> 155
            check("coach wave week 1", pW1?.sets.map(\.weightLb) == [115, 135, 155] && pW1?.sets.map(\.reps) == [5, 5, 5],
                  "\(String(describing: pW1?.sets))")
            ctx.weekInCycle = 2
            let pW3 = SmartCoach.prescribe(exercise: one, history: [sess(0, one)], context: ctx, now: now)
            check("coach wave week 3 top single", pW3?.sets.last?.reps == 1 && pW3?.topLoad == 170)
            check("coach blocks 10wk", SmartCoach.block(week: 0, cycleWeeks: 10) == .accumulation
                  && SmartCoach.block(week: 5, cycleWeeks: 10) == .intensification
                  && SmartCoach.block(week: 9, cycleWeeks: 10) == .realization)
            ctx.cycleWeeks = 10; ctx.weekInCycle = 9
            let pReal = SmartCoach.prescribe(exercise: one, history: [sess(0, one)], context: ctx, now: now)
            check("coach realization block", pReal?.sets.count == 3 && pReal?.topReps == 2 && pReal?.topLoad == 160)

            // Volume landmarks
            check("coach volume under", SmartCoach.volumeStatus(group: "Back", sets: 4)?.level == .under
                  && SmartCoach.volumeStatus(group: "Back", sets: 4)?.advice == "Back under target: add 6 sets this week.")
            check("coach volume productive/over", SmartCoach.volumeStatus(group: "Chest", sets: 16)?.level == .productive
                  && SmartCoach.volumeStatus(group: "Chest", sets: 30)?.advice.contains("cut 8 sets") == true)
            check("coach muscle groups", SmartCoach.group(forMuscle: "quadriceps") == "Quads" && SmartCoach.group(forMuscle: "lats") == "Back")
            let vol = SmartCoach.weeklyVolume(from: [sess(38, bench), sess(39, squat)], now: now)
            check("coach weekly volume counts", vol.first { $0.landmark.group == "Chest" }?.sets == 3
                  && vol.first { $0.landmark.group == "Quads" }?.sets == 3 && vol.count == SmartCoach.landmarks.count)

            // Auto model choice
            var actx = CoachContext(); actx.model = .auto
            let noHist: ExerciseState? = nil
            check("coach auto beginner linear", SmartCoach.resolvedModel(actx, state: noHist) == .linear)
            check("coach auto beginner stalled double", SmartCoach.resolvedModel(actx, state: stState) == .double)
            actx.experience = .intermediate; actx.goal = .getStronger
            check("coach auto intermediate strength waves", SmartCoach.resolvedModel(actx, state: noHist) == .waves)
            actx.goal = .buildMuscle
            check("coach auto intermediate muscle double", SmartCoach.resolvedModel(actx, state: noHist) == .double)
            actx.experience = .advanced
            check("coach auto advanced no RIR double", SmartCoach.resolvedModel(actx, state: stState) == .double)
            check("coach auto advanced RIR rpe", SmartCoach.resolvedModel(actx, state: creepState) == .rpe)
            actx.model = .linear
            check("coach explicit model kept", SmartCoach.resolvedModel(actx, state: creepState) == .linear)

            // Trend, cycle week, adherence
            let trendHist = (0..<4).map { i in sess(i * 7, ex("Coach Trend", 5, 5, sets: [(100 + Double(i) * 10, 5, nil)])) }
            let tr = SmartCoach.state(key: ex("Coach Trend", 5, 5).identityKey, history: trendHist, now: now)?.trendPerWeek ?? 0
            check("coach trend slope", near(tr, SmartCoach.e1RM(weight: 110, reps: 5) - SmartCoach.e1RM(weight: 100, reps: 5), 0.01), "\(tr)")
            check("coach week in cycle", CoachContext.weekInCycle(start: day(0), now: day(15), totalWeeks: 7) == 2
                  && CoachContext.weekInCycle(start: day(0), now: day(50), totalWeeks: 7) == 0)
            check("coach missed rolling days", SmartCoach.missedRollingDays(start: day(0), daysOn: 3, daysOff: 1, logged: [day(0)],
                                                                            now: day(3), calendar: cal) == 2)
            check("coach rolling on track", SmartCoach.missedRollingDays(start: day(0), daysOn: 3, daysOff: 1, logged: [day(2)],
                                                                         now: day(3), calendar: cal) == 0)
            let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
            check("coach missed weekly day", SmartCoach.missedWeeklyDays(weekdays: ["Monday"], logged: [], now: wed, calendar: cal) == ["Monday"])

            // Post-workout review
            let heavier = ex("Coach Bench", 5, 5, sets: [(140, 5, nil), (140, 5, nil), (140, 5, nil)])
            let w2 = sess(2, heavier)
            ctx = CoachContext(); ctx.model = .linear; ctx.deloadEnabled = false
            let review = SessionReview.make(workout: w2, before: [sess(0, bench)], after: [sess(0, bench), w2], context: ctx)
            check("coach review PR + next", review.records.count == 1 && review.nextTime.first?.text.hasPrefix("145 lb × 5") == true,
                  "\(review)")
        }


        // MARK: Smart Advisor planner
        do {
            typealias SP = SmartPlanner
            let cfg = { (g: TrainingGoal, e: ExperienceLevel, r: (Int, Int)?, pw: Int, len: Int, eq: EquipmentLevel, inj: Set<String>, days: [String]?) in
                SP.sampleConfig(g, e, rolling: r, perWeek: pw, len: len, eq: eq, inj: inj, days: days) }
            func c(_ g: TrainingGoal, _ e: ExperienceLevel = .intermediate, rolling r: (Int, Int)? = nil, perWeek pw: Int = 4,
                   len: Int = 60, eq: EquipmentLevel = .fullGym, inj: Set<String> = [], days: [String]? = nil) -> ProgramConfig {
                cfg(g, e, r, pw, len, eq, inj, days)
            }
            func backToBackHard(_ p: SP.Plan) -> Int {
                var n = 0
                for i in p.sessions.indices {
                    let j = (i + 1) % p.sessions.count
                    if j != i && p.slots[j].restBefore == 0 && p.sessions[i].isHard && p.sessions[j].isHard { n += 1 }
                }
                return n
            }
            func weeklyLiftSets(_ p: SP.Plan) -> Double {
                Double(p.sessions.flatMap(\.items).filter { $0.kind == .lift }.reduce(0) { $0 + $1.sets }) / p.weeks
            }

            // The complaint: longevity, 4 on / 1 off.
            let lon = SP.plan(for: c(.longevity, rolling: (4, 1)))
            let lonLabels = lon.sessions.map(\.label)
            check("planner longevity 4on/1off no Upper/Lower", !lonLabels.contains { $0.contains("Upper") || $0.contains("Lower") }, "\(lonLabels)")
            check("planner longevity has Zone 2", lon.sessions.contains { $0.items.contains { $0.name.hasPrefix("Zone 2") } }, "\(lonLabels)")
            check("planner longevity mobility every day", lon.sessions.allSatisfy { $0.mobilityMinutes > 0 })
            check("planner longevity has VO2max", lon.sessions.contains { $0.spec.kind == .intervals })
            check("planner longevity full-body strength", lon.sessions.filter { $0.label.hasPrefix("Full Body") }.count >= 4)
            check("planner longevity no back-to-back hard", backToBackHard(lon) == 0, "\(lonLabels)")
            check("planner longevity hard day after rest", lon.sessions.indices.filter { lon.slots[$0].restBefore > 0 }.allSatisfy { lon.sessions[$0].isHard }, "\(lonLabels)")
            let lonStats = SP.stats(lon)
            check("planner longevity aerobic >= 150/wk", lonStats.aerobic >= 150, "\(lonStats.aerobic)")
            check("planner longevity strength ~2-3/wk", lonStats.strengthSessions >= 1.8 && lonStats.strengthSessions <= 3, "\(lonStats.strengthSessions)")
            check("planner rolling block whole cycles <= 42", lon.sessions.count % 4 == 0 && lon.sessions.count <= 42, "\(lon.sessions.count)")
            let lonBeg = SP.plan(for: c(.longevity, .beginner, rolling: (4, 1)))
            check("planner longevity beginner gentle intervals", !lonBeg.sessions.contains { $0.spec.kind == .intervals }
                  && lonBeg.sessions.contains { $0.spec.kind == .gentleIntervals } && backToBackHard(lonBeg) == 0)
            let lonSched = lon.scheduledWorkouts
            check("planner schedule entries", lonSched.count == lon.sessions.count && lonSched[0].dayOfWeek == "Day 1 · Cycle 1"
                  && lonSched[0].exercises.count == lon.sessions[0].items.count)
            let again = SP.plan(for: c(.longevity, rolling: (4, 1)))
            check("planner deterministic", again.sessions.map { $0.items.map(\.text) } == lon.sessions.map { $0.items.map(\.text) })

            // Size: every major muscle twice a week, sets inside MEV...MAV.
            let size = SP.plan(for: c(.buildMuscle))
            let sizeVol = SP.volumeReport(size)
            for g in SP.majorGroups {
                let hits = Double(size.sessions.filter { $0.sets(of: g) >= 2 }.count) / size.weeks
                check("planner size 4/wk \(g) >= 2x/wk", hits >= 2, "\(hits)")
                let lm = SmartCoach.landmarks.first { $0.group == g }!
                let sets = sizeVol.first { $0.group == g }!.sets
                check("planner size 4/wk \(g) sets in MEV-MAV", sets >= Double(lm.mev) && sets <= Double(lm.mav.upperBound), "\(sets)")
            }
            check("planner volume report pure", sizeVol.count == 10 && SP.volumeReport(size) == sizeVol)

            // Strength: heavy lower days at least 48 h apart, even on back-to-back weekdays.
            for days in [["Monday", "Wednesday", "Friday"], ["Monday", "Tuesday", "Thursday"]] {
                let st = SP.plan(for: c(.getStronger, perWeek: 3, days: days))
                let heavyDays = st.sessions.indices.filter { st.sessions[$0].items.contains { $0.heavyLoad && ($0.pattern == .squat || $0.pattern == .hinge) } }
                    .map { st.slots[$0].day }
                var minGap = 99
                for (k, d) in heavyDays.enumerated() {
                    let next = k + 1 < heavyDays.count ? heavyDays[k + 1] : heavyDays[0] + st.blockDays
                    minGap = min(minGap, next - d)
                }
                check("planner strength heavy lower spaced 48h \(days.joined(separator: "/"))", heavyDays.count >= 2 && minGap >= 2, "\(heavyDays)")
                let sst = SP.stats(st)
                check("planner strength main lifts 2x/wk \(days.count)", sst.lowerHeavy >= 2 && sst.upperHeavy >= 2, "\(sst.lowerHeavy) \(sst.upperHeavy)")
            }

            // Experience, equipment, injuries, session length.
            let beg = SP.plan(for: c(.buildMuscle, .beginner)), mid = SP.plan(for: c(.buildMuscle, .intermediate))
            check("planner beginners fewer sets", weeklyLiftSets(beg) < weeklyLiftSets(mid), "\(weeklyLiftSets(beg)) vs \(weeklyLiftSets(mid))")
            check("planner beginners <= 4 sets per lift", beg.sessions.flatMap(\.items).allSatisfy { $0.kind != .lift || $0.sets <= 4 })
            check("planner beginners simple lifts", !beg.sessions.flatMap(\.items).contains { ["Deadlifts", "Front Squats", "Weighted Pull-ups", "Barbell Rows"].contains($0.name) })
            let barbellWords = ["Barbell", "Deadlift", "Bench Press", "Back Squat", "Front Squat", "Lat Pulldown", "Leg Press", "Cable", "Machine", "Kettlebell", "Dumbbell"]
            for g in TrainingGoal.allCases {
                let bw = SP.plan(for: c(g, perWeek: 4, eq: .bodyweight))
                let lifts = bw.sessions.flatMap(\.items).filter { $0.kind == .lift }
                check("planner bodyweight \(g.rawValue) no gear", !lifts.isEmpty && lifts.allSatisfy { $0.gear.contains(.bodyweight) }
                      && !lifts.contains { l in barbellWords.contains { l.name.contains($0) } }, "\(lifts.map(\.name))")
                let knee = SP.plan(for: c(g, rolling: (3, 1), inj: ["Knee"]))
                let names = knee.sessions.flatMap(\.items).map { $0.name.lowercased() }
                let flagged = Set(SP.catalog.filter { $0.flags.contains("Knee") }.map { $0.name.lowercased() })
                    .union(SP.mobilityPool.filter { $0.flags.contains("Knee") }.map { $0.name.lowercased() })
                    .union(SP.balancePool.filter { $0.flags.contains("Knee") }.map { $0.name.lowercased() })
                let bad = names.filter { n in flagged.contains(n) || ["jump", "lunge", "leg extension", "step-up", "pistol", "split squat"].contains { n.contains($0) } }
                check("planner knee \(g.rawValue) avoids flagged", bad.isEmpty, "\(bad)")
            }
            let lb = SP.plan(for: c(.getStronger, inj: ["Low back"]))
            check("planner low back avoids loaded hinges", !lb.sessions.flatMap(\.items).contains { $0.name.contains("Deadlift") || $0.name == "Barbell Rows" })
            let sh = SP.plan(for: c(.buildMuscle, inj: ["Shoulder"]))
            check("planner shoulder avoids overhead", !sh.sessions.flatMap(\.items).contains { $0.name.contains("Overhead Press") || $0.name.contains("Shoulder Press") || $0.name.contains("Dips") })
            let long = SP.plan(for: c(.buildMuscle, len: 120)), short = SP.plan(for: c(.buildMuscle, len: 45))
            check("planner 120 min > 45 min volume", weeklyLiftSets(long) > weeklyLiftSets(short) + 10, "\(weeklyLiftSets(long)) vs \(weeklyLiftSets(short))")
            let lLong = SP.stats(SP.plan(for: c(.longevity, rolling: (4, 1), len: 120))), lShort = SP.stats(SP.plan(for: c(.longevity, rolling: (4, 1), len: 45)))
            check("planner 120 min > 45 min aerobic", lLong.aerobic > lShort.aerobic, "\(lLong.aerobic) vs \(lShort.aerobic)")
            var dl = c(.buildMuscle); dl.includeDeload = false; dl.mesocycleWeeks = 8
            check("planner no-deload block caps volume lower", SP.targetRange(group: "Chest", config: dl).upperBound < SP.targetRange(group: "Chest", config: c(.buildMuscle)).upperBound)

            // Weekly slots start at the first training day on/after the start date.
            let cal = Calendar(identifier: .gregorian)
            let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
            let ws = SP.slots(for: c(.generalFitness), start: wed, calendar: cal).slots
            check("planner weekly slots from start", ws.first?.label == "Thursday · Wk 1" && ws.first?.restBefore == 1 && ws.count == 8,
                  "\(ws.map(\.label))")

            // Sweep: sessions fit the time, health goals never stack hard days
            // when the cycle has room, nothing is empty.
            var sweepBad: [String] = []
            for g in TrainingGoal.allCases {
                for e in [ExperienceLevel.beginner, .advanced] {
                    for (r, pw) in [((4, 1), 0), ((3, 1), 0), ((2, 1), 0), ((6, 1), 0)] as [((Int, Int), Int)] {
                        for len in [30, 90] {
                            let p = SP.plan(for: c(g, e, rolling: r, perWeek: pw, len: len))
                            let tag = "\(g.rawValue) \(e.rawValue) \(r) \(len)"
                            if p.sessions.isEmpty || p.sessions.contains(where: { $0.items.isEmpty }) { sweepBad.append("empty " + tag) }
                            if let over = p.sessions.first(where: { $0.minutes > Double(len) + 3 }) { sweepBad.append("long \(Int(over.minutes)) " + tag) }
                            if g != .buildMuscle && g != .getStronger && backToBackHard(p) > 0 { sweepBad.append("hard " + tag) }
                        }
                    }
                }
                for pw in [2, 3, 5, 7] {
                    let p = SP.plan(for: c(g, perWeek: pw))
                    if p.sessions.count != pw * 2 { sweepBad.append("count \(g.rawValue) \(pw)") }
                    if g != .buildMuscle && g != .getStronger && pw < 7 && backToBackHard(p) > 0 { sweepBad.append("hard \(g.rawValue) \(pw)/wk") }
                }
            }
            check("planner sweep (fit, no stacked hard days)", sweepBad.isEmpty, "\(sweepBad.prefix(8))")

            // Smart Advisor vs every hand-built split, same inputs and exercise engine.
            let reps: [(String, ProgramConfig)] = [
                ("longevity 4on/1off", c(.longevity, rolling: (4, 1))),
                ("longevity 3/wk beginner", c(.longevity, .beginner, perWeek: 3)),
                ("size 4/wk", c(.buildMuscle)),
                ("size 6/wk advanced", c(.buildMuscle, .advanced, perWeek: 6)),
                ("strength 3/wk", c(.getStronger, perWeek: 3)),
                ("fat loss 5/wk", c(.loseWeight, perWeek: 5)),
                ("endurance 3on/1off", c(.improveEndurance, rolling: (3, 1))),
                ("flexibility 3/wk bodyweight", c(.increaseFlexibility, perWeek: 3, eq: .bodyweight)),
                ("general 4/wk home knee", c(.generalFitness, eq: .homeGym, inj: ["Knee"])),
            ]
            var wins = 0
            for (name, cf) in reps {
                let smart = SP.qualityScore(SP.plan(for: cf)).total
                let naive = ProgramSplit.allCases.filter { $0 != .auto }.map { (SP.qualityScore(SP.naivePlan(for: cf, split: $0)).total, $0.rawValue) }
                let best = naive.max { $0.0 < $1.0 }!
                let ok = smart > best.0
                if ok { wins += 1 }
                check("planner beats hand-built: \(name)", ok, String(format: "smart %.1f vs %@ %.1f", smart, best.1, best.0))
            }
            check("planner beats hand-built in >= 6 configs", wins >= 6, "\(wins)")
        }

        print(failures == 0 ? "SELFTEST PASS \(count)/\(count)" : "SELFTEST FAIL \(failures) of \(count)")
        return failures == 0 ? 0 : 1
    }
}
