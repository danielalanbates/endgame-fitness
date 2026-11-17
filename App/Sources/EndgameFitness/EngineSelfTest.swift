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
        if CommandLine.arguments.contains("-ef.guidedump") { dumpDirections(); exit(0) }
        guard CommandLine.arguments.contains("-ef.selftest") else { return }
        exit(run())
    }

    static func run() -> Int32 {
        // The bare selftest executable has no bundle: read the library from the repo.
        ExerciseLibrary.fallbackResourceDirectory = repoResources
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

            // Longevity: joint-safe progression. Never below 8 reps, effort capped
            // at RPE 7-8 (stop 2-3 reps short), no waves / heavy singles.
            do {
                var lctx = CoachContext(); lctx.unit = .lb; lctx.deloadEnabled = false; lctx.goal = .longevity
                var bad: [String] = []
                let cases: [(ProgressionStyle, ExperienceLevel, Exercise)] = [
                    (.auto, .beginner, ex("Lon Goblet", 10, 15, lower: true, sets: [(50, 15, 3), (50, 15, 3)])),
                    (.auto, .intermediate, ex("Lon DB Bench", 8, 12, sets: [(50, 12, 2), (50, 12, 2), (50, 12, 2)])),
                    (.auto, .intermediate, ex("Lon Row", 8, 12, sets: [(60, 9, 2), (60, 9, 2)])),
                    (.auto, .advanced, ex("Lon Press", 8, 12, sets: [(40, 10, 3)])),
                    (.waves, .intermediate, ex("Lon Wave", 8, 12, sets: [(100, 8, 2)])),
                    (.linear, .beginner, ex("Lon Linear", 10, 15, sets: [(30, 10, 3), (30, 10, 3)])),
                    // No program target: the default compound range (6-10) is lifted to 8+.
                    (.double, .intermediate, Exercise(name: "Lon No Target", sets: [ExerciseSet(reps: 6, weight: 100, completed: true)],
                                                      primaryMuscles: ["chest"], tracking: .weighted)),
                ]
                for (model, exp, e) in cases {
                    lctx.model = model; lctx.experience = exp
                    guard let p = SmartCoach.prescribe(exercise: e, history: [sess(0, e)], context: lctx, now: now) else {
                        bad.append("\(e.name): nil"); continue
                    }
                    if p.model == .waves { bad.append("\(e.name): waves") }
                    if p.sets.contains(where: { $0.reps < 8 }) { bad.append("\(e.name): reps \(p.sets.map(\.reps))") }
                    if (p.targetRPE ?? 99) > 8 { bad.append("\(e.name): RPE \(String(describing: p.targetRPE))") }
                    if !p.reason.contains("short of failure") { bad.append("\(e.name): no cue") }
                    if p.sets.map(\.weightLb).max() ?? 0 > (e.completedSets.map(\.weight).max() ?? 0) * 1.15 + 10 { bad.append("\(e.name): jump") }
                }
                check("coach longevity: 8+ reps, RPE <= 8, no waves, cue", bad.isEmpty, "\(bad)")
                // Top of the range at only 1 rep in reserve is not a load increase for longevity.
                lctx.model = .double; lctx.experience = .intermediate
                let hard = ex("Lon Hard", 8, 12, sets: [(60, 12, 1), (60, 12, 1)])
                check("coach longevity needs 2 RIR to add load",
                      SmartCoach.prescribe(exercise: hard, history: [sess(0, hard)], context: lctx, now: now)?.kind == .addReps)
                // Longevity beginners (Auto) and Linear never add load after a grinding set:
                // they run double progression, which needs the top of the range with 2+ RIR.
                var bctx = lctx; bctx.experience = .beginner
                let grind = ex("Lon Grind", 10, 15, lower: true, sets: [(50, 10, 0), (50, 10, 0)])
                let grindKinds = [ProgressionStyle.auto, .linear].map { m -> SmartCoach.Prescription? in
                    bctx.model = m; return SmartCoach.prescribe(exercise: grind, history: [sess(0, grind)], context: bctx, now: now) }
                check("coach longevity beginner/linear: no load increase after an RPE 10 set",
                      grindKinds.allSatisfy { $0?.kind == .addReps && $0?.model == .double && ($0?.topLoad ?? 0) <= 50 },
                      "\(grindKinds.map { "\(String(describing: $0?.model)) \(String(describing: $0?.kind)) \($0?.topLoad ?? -1)" })")
                bctx.model = .linear; var sctx = bctx; sctx.goal = .getStronger
                check("coach linear unchanged for other goals", SmartCoach.resolvedModel(sctx, state: nil) == .linear
                      && SmartCoach.resolvedModel(bctx, state: nil) == .double)
                // Warm-up entries are timed: never prescribed, never counted as volume.
                var warm = Exercise(name: "Warm-up: Ramp-up Sets for Goblet Squats (2-3 lighter sets building to your working weight)")
                WorkoutManager.attachLibraryMatch(&warm)
                check("coach warm-up items are timed, untracked", warm.resolvedTracking == .timed && warm.musclesForStats.isEmpty
                      && SmartCoach.prescribe(exercise: warm, history: [], context: lctx, now: now) == nil)
            }

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
            // Hard days back to back that load the same region (VO2max after an
            // upper-only day is allowed: the legs are fresh).
            func backToBackHard(_ p: SP.Plan) -> Int {
                var n = 0
                for i in p.sessions.indices {
                    let j = (i + 1) % p.sessions.count
                    if j != i && p.slots[j].restBefore == 0 && p.sessions[i].isHard && p.sessions[j].isHard
                        && SP.overlap(p.sessions[i].fatigue, p.sessions[j].fatigue) { n += 1 }
                }
                return n
            }
            func weeklyLiftSets(_ p: SP.Plan) -> Double {
                Double(p.sessions.flatMap(\.items).filter { $0.kind == .lift }.reduce(0) { $0 + $1.sets }) / p.weeks
            }

            // The complaint: longevity, 4 on / 1 off.
            let lon = SP.plan(for: c(.longevity, rolling: (4, 1)))
            let lonLabels = lon.sessions.map(\.label)
            // The complaint: no upper/lower split before the rest day. At most an
            // upper-only day that sets up VO2max; never a lower day, never two
            // strength days in a row.
            var lonSplit: [String] = []
            for i in lon.sessions.indices {
                let j = (i + 1) % lon.sessions.count
                if lon.sessions[i].label.contains("Lower") { lonSplit.append(lon.sessions[i].label) }
                if lon.slots[j].restBefore == 0 && lon.sessions[i].hasStrength && lon.sessions[j].hasStrength { lonSplit.append("\(lon.slots[i].label)+next") }
                if lon.sessions[i].label.hasPrefix("Upper") && lon.sessions[j].spec.kind != .intervals { lonSplit.append("upper not before VO2max") }
            }
            check("planner longevity 4on/1off no upper/lower split", lonSplit.isEmpty, "\(lonSplit) \(lonLabels)")
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

            // Coach audit (2026-11-16): the 22 audit configs plus sweeps.
            let audit: [(String, ProgramConfig)] = [
                ("01", c(.longevity, rolling: (4, 1))),
                ("02", c(.longevity, .beginner, perWeek: 2, len: 30, eq: .bodyweight)),
                ("03", c(.longevity, .advanced, perWeek: 6, len: 120, inj: ["Low back"])),
                ("04", c(.buildMuscle, .advanced, rolling: (5, 2))),
                ("05", c(.buildMuscle, .beginner, perWeek: 3, len: 30)),
                ("06", c(.buildMuscle, perWeek: 6, len: 120, inj: ["Shoulder"])),
                ("07", c(.getStronger, .beginner, perWeek: 2)),
                ("08", c(.getStronger, .advanced, rolling: (2, 1), len: 120, inj: ["Knee"])),
                ("09", c(.getStronger, perWeek: 4, eq: .bodyweight)),
                ("10", c(.loseWeight, .beginner, perWeek: 5, len: 30, eq: .bodyweight, inj: ["Knee"])),
                ("11", c(.loseWeight, .advanced, rolling: (3, 1))),
                ("12", c(.improveEndurance, .beginner, perWeek: 3)),
                ("13", c(.improveEndurance, .advanced, rolling: (5, 2), len: 120, eq: .bodyweight)),
                ("14", c(.increaseFlexibility, .beginner, rolling: (4, 1), len: 30, eq: .bodyweight, inj: ["Shoulder"])),
                ("15", c(.increaseFlexibility, .advanced, perWeek: 5)),
                ("16", c(.generalFitness, .beginner, inj: ["Low back"])),
                ("17", c(.generalFitness, .advanced, rolling: (2, 1), len: 30)),
                ("18", c(.generalFitness, perWeek: 6, len: 120, eq: .bodyweight)),
                ("19", c(.longevity, .beginner, rolling: (3, 1), inj: ["Knee", "Shoulder"])),
                ("20", c(.buildMuscle, perWeek: 2, eq: .homeGym)),
                ("21", c(.longevity, rolling: (5, 2), eq: .minimal)),
                ("22", c(.getStronger, perWeek: 3, len: 30, inj: ["Low back"])),
            ]
            var pool: [(String, ProgramConfig)] = audit
            for g in TrainingGoal.allCases {
                for e in [ExperienceLevel.beginner, .intermediate, .advanced] {
                    for eq in [EquipmentLevel.fullGym, .bodyweight] {
                        pool.append(("\(g.rawValue)/\(e.rawValue)/\(eq)/3wk/30", c(g, e, perWeek: 3, len: 30, eq: eq)))
                        pool.append(("\(g.rawValue)/\(e.rawValue)/\(eq)/4on1off/120", c(g, e, rolling: (4, 1), len: 120, eq: eq)))
                    }
                }
            }
            let plans = pool.map { ($0.0, $0.1, SP.plan(for: $0.1)) }
            let catalogByName = Dictionary(uniqueKeysWithValues: SP.catalog.map { ($0.name, $0) })
            func lifts(_ s: SP.Session) -> [SP.Item] { s.items.filter { $0.kind == .lift } }

            // 1. Endurance at 2-3 days: Zone 2 + intervals, 90+ aerobic min, strength cut to 1 at 3 days.
            for pw in [2, 3] {
                for e in [ExperienceLevel.beginner, .intermediate] {
                    let p = SP.plan(for: c(.improveEndurance, e, perWeek: pw))
                    let st = SP.stats(p)
                    let z2 = Double(p.sessions.filter { $0.spec.kind == .zone2 }.count) / p.weeks
                    let iv = Double(p.sessions.filter { $0.spec.kind == .intervals || $0.spec.kind == .gentleIntervals }.count) / p.weeks
                    check("audit 1 endurance \(pw)/wk \(e.rawValue) aerobic >= 90, Z2 + intervals, strength <= 1",
                          st.aerobic >= 90 && z2 >= 1 && iv >= 1 && st.strengthSessions <= 1.01,
                          "aerobic \(st.aerobic) z2 \(z2) iv \(iv) strength \(st.strengthSessions) \(p.sessions.map(\.label))")
                }
            }
            // 2. Every longevity schedule reaches 150 aerobic min a week (rest-day walks count).
            var lonShort: [String] = []
            for len in [30, 60] {
                for e in [ExperienceLevel.beginner, .intermediate] {
                    for pw in [2, 3, 4, 5, 6] {
                        let p = SP.plan(for: c(.longevity, e, perWeek: pw, len: len))
                        if SP.stats(p).aerobic < 150 { lonShort.append("\(pw)/wk \(len) \(e.rawValue): \(Int(SP.stats(p).aerobic))") }
                    }
                    for r in [(4, 1), (3, 1), (2, 1), (5, 2), (6, 1), (3, 2)] {
                        let p = SP.plan(for: c(.longevity, e, rolling: r, len: len))
                        if SP.stats(p).aerobic < 150 { lonShort.append("\(r) \(len) \(e.rawValue): \(Int(SP.stats(p).aerobic))") }
                    }
                }
            }
            check("audit 2 longevity >= 150 aerobic min/wk on every schedule", lonShort.isEmpty, "\(lonShort)")
            let lon2 = SP.plan(for: audit[1].1)
            check("audit 2 longevity 2/wk = Strength + Zone 2", lon2.sessions.allSatisfy { $0.spec.kind == .mixed && $0.aerobic > 0 },
                  "\(lon2.sessions.map(\.label))")
            // 3. Longevity 4 on / 1 off: strength on Day 1 and Day 3 of every cycle; VO2max only after a legs-free day.
            let lonC = Dictionary(grouping: lon.sessions.indices, by: { lon.slots[$0].cycle })
            let d13 = lonC.values.allSatisfy { idx in idx.count == 4 && lon.sessions[idx[0]].hasStrength && lon.sessions[idx[2]].hasStrength }
            let vo2Ok = lon.sessions.indices.filter { lon.sessions[$0].spec.kind == .intervals }
                .allSatisfy { i in i > 0 && lon.slots[i].restBefore == 0 ? lon.sessions[i - 1].fatigue[1] < 2 : true }
            check("audit 3 longevity 4on/1off strength D1+D3 every cycle, VO2max after upper-only",
                  d13 && vo2Ok && lonStats.strengthSessions >= 2 && lonStats.vo2 >= 0.6, "\(lonLabels)")
            // 4. Strength + Zone 2 is hard where it loads; no lift repeated on back-to-back days.
            var repeats: [String] = []
            for (n, _, p) in plans {
                for i in p.sessions.indices where i > 0 && p.slots[i].restBefore == 0 {
                    let shared = Set(lifts(p.sessions[i]).map(\.name)).intersection(lifts(p.sessions[i - 1]).map(\.name))
                    if !shared.isEmpty { repeats.append("\(n) \(p.slots[i].label) \(shared)") }
                }
                for s in p.sessions where s.spec.kind == .mixed && !s.isHard { repeats.append("\(n) mixed not hard") }
            }
            check("audit 4 Strength + Zone 2 hard, no same lifts on back-to-back days", repeats.isEmpty, "\(repeats.prefix(5))")
            // 5. Every full-body strength / Strength + Zone 2 session has a push, a pull and a lower lift.
            var thin: [String] = []
            for (n, _, p) in plans {
                for s in p.sessions where s.hasStrength && (s.spec.template ?? .fullBody) == .fullBody {
                    let regions = Set(lifts(s).compactMap { SP.region($0.pattern) })
                    if regions.count < 3 || lifts(s).count < 3 { thin.append("\(n) \(s.label): \(lifts(s).map(\.name))") }
                }
            }
            check("audit 5 full-body sessions keep push + pull + lower", thin.isEmpty, "\(thin.prefix(4))")
            let a22 = SP.plan(for: audit[21].1)
            check("audit 5 strength 30 min: every session has a pull", a22.sessions.allSatisfy { s in
                s.label.contains("Lower") || lifts(s).contains { SP.region($0.pattern) == 1 } }, "\(a22.sessions.map { lifts($0).map(\.name) })")
            // 6. The top of each muscle's range is a hard cap (size 120 min, 6/wk and every audit config).
            var overCap: [String] = []
            for (n, cf) in audit + [("size 120 6/wk", c(.buildMuscle, perWeek: 6, len: 120)), ("size 120 6/wk adv", c(.buildMuscle, .advanced, perWeek: 6, len: 120))] {
                for l in SP.volumeReport(SP.plan(for: cf)) where l.sets > Double(l.target.upperBound) + 0.01 {
                    overCap.append("\(n) \(l.group) \(l.sets)>\(l.target.upperBound)")
                }
            }
            check("audit 6 weekly sets never over the top of the range", overCap.isEmpty, "\(overCap)")
            // 7. Each session type has its own ceiling; drills are not repeated from the day before.
            var long7: [String] = [], drillRep: [String] = []
            for (n, cf, p) in plans {
                let strengthGoal = cf.primaryGoal == .buildMuscle || cf.primaryGoal == .getStronger
                for (k, s) in p.sessions.enumerated() {
                    let cap: Double
                    switch s.spec.kind {
                    case .intervals: cap = 55
                    case .gentleIntervals: cap = 50
                    case .mobility: cap = 45
                    case .recovery: cap = 40
                    case .zone2: cap = strengthGoal ? 45 : 120
                    default: cap = 120
                    }
                    if s.minutes > cap + 0.5 || s.minutes > Double(cf.sessionLength) + 0.5 { long7.append("\(n) \(s.label) \(Int(s.minutes))") }
                    if k > 0 && p.slots[k].restBefore == 0 {
                        let shared = SP.drillNames(s).intersection(SP.drillNames(p.sessions[k - 1]))
                        if !shared.isEmpty { drillRep.append("\(n) \(p.slots[k].label) \(shared)") }
                    }
                }
            }
            check("audit 7 session-type ceilings (VO2max 55, mobility 45, Zone 2 45 for strength/size)", long7.isEmpty, "\(long7.prefix(5))")
            check("audit 7 no drills repeated from the day before", drillRep.isEmpty, "\(drillRep.prefix(5))")
            // 8. Never glutes over the range while hamstrings are under it.
            let gh = plans.filter { _, _, p in
                let v = SP.volumeReport(p)
                let gl = v.first { $0.group == "Glutes" }!, hm = v.first { $0.group == "Hamstrings" }!
                return gl.sets > Double(gl.target.upperBound) + 0.01 && hm.sets < Double(hm.target.lowerBound) - 0.01
            }.map(\.0)
            check("audit 8 no glutes-over / hamstrings-under", gh.isEmpty, "\(gh)")
            // 9. Size: no core, carries or cardio days while a major muscle is under its minimum.
            var sizeWaste: [String] = []
            for (n, cf, p) in plans where cf.primaryGoal == .buildMuscle {
                let under = SP.volumeReport(p).contains { SP.majorGroups.contains($0.group) && $0.sets < Double($0.target.lowerBound) - 0.01 }
                if under && p.sessions.contains(where: { s in s.spec.kind != .strength || lifts(s).contains { $0.pattern == .core || $0.pattern == .carry } }) {
                    sizeWaste.append(n)
                }
            }
            check("audit 9 size fills short muscles before core/carries/cardio", sizeWaste.isEmpty, "\(sizeWaste)")
            check("audit 9 size 5on/2off trains biceps directly", SP.plan(for: audit[3].1).sessions.contains { lifts($0).contains { $0.pattern == .biceps } })
            // 10. Size at 2-3 days is full body; every major muscle 2x a week at 2, 3, 5 and 6 days.
            for pw in [2, 3] {
                let p = SP.plan(for: c(.buildMuscle, .beginner, perWeek: pw))
                check("audit 10 size \(pw)/wk is full body", p.sessions.allSatisfy { $0.label.hasPrefix("Full Body") }, "\(p.sessions.map(\.label))")
            }
            for pw in [2, 3, 5, 6] {
                let p = SP.plan(for: c(.buildMuscle, perWeek: pw))
                let low = SP.majorGroups.filter { g in Double(p.sessions.filter { $0.sets(of: g) >= 1 }.count) / p.weeks < 2 }
                check("audit 10 size \(pw)/wk every major muscle >= 2x/wk", low.isEmpty, "\(low)")
            }
            // 11. Beginners never get a move the catalog marks as not for beginners.
            let notBeg = plans.filter { $0.1.experienceLevel == .beginner }.flatMap { n, _, p in
                p.sessions.flatMap(lifts).filter { catalogByName[$0.name]?.beginner == false }.map { "\(n) \($0.name)" } }
            check("audit 11 beginners only beginner moves", notBeg.isEmpty, "\(Set(notBeg))")
            // 12. Injury swaps: no barbell squats with a low back, no barbell bench with a shoulder; overhead swaps rotate.
            let lbBad = plans.filter { $0.1.injuries.contains("Low back") }.flatMap { n, _, p in
                p.sessions.flatMap(lifts).filter { ["Back Squats", "Front Squats", "Barbell Box Squats"].contains($0.name) }.map { "\(n) \($0.name)" } }
            var shPool = plans.filter { $0.1.injuries.contains("Shoulder") }.map { $0.2 }
            shPool.append(SP.plan(for: c(.buildMuscle, perWeek: 4, inj: ["Shoulder"])))
            let shBad = shPool.flatMap { $0.sessions.flatMap(lifts) }.filter { $0.name == "Barbell Bench Press" }
            check("audit 12 low back: no barbell squats", lbBad.isEmpty, "\(lbBad)")
            check("audit 12 shoulder: no barbell bench", shBad.isEmpty)
            let a06 = SP.plan(for: audit[5].1)
            var perLift: [String: Double] = [:]
            for it in a06.sessions.flatMap(lifts) { perLift[it.name, default: 0] += Double(it.sets) / a06.weeks }
            let vPushNames = Set(a06.sessions.flatMap(lifts).filter { $0.pattern == .vPush }.map(\.name))
            check("audit 12 shoulder size: overhead swaps rotate, no lift > 12 sets/wk",
                  vPushNames.count >= 2 && (perLift.values.max() ?? 0) <= 12, "\(vPushNames) \(perLift.filter { $0.value > 12 })")
            // 13. With loadable gear, no band or bodyweight version unless the loaded ones are missing or blocked.
            var lowGear: [String] = []
            for (n, cf, p) in plans where cf.equipment == .fullGym || cf.equipment == .homeGym {
                let ctx = SP.Ctx(config: cf)
                for it in p.sessions.flatMap(lifts) {
                    guard let m = catalogByName[it.name], let pat = it.pattern, pat != .core && pat != .carry,
                          SP.gearRank(m, ctx: ctx) >= 2 else { continue }
                    let better = SP.catalog.contains { o in o.pattern == pat && SP.gearRank(o, ctx: ctx) <= 1 && !o.gear.isDisjoint(with: ctx.gear)
                        && o.flags.isDisjoint(with: cf.injuries) && (!ctx.beginner || o.beginner) && !o.heavyOnly }
                    if better { lowGear.append("\(n) \(it.name)") }
                }
            }
            check("audit 13 loadable gear ranks first", lowGear.isEmpty, "\(Set(lowGear))")
            // 14. One exercise per pattern in a session (sets go on the lift already there).
            var dupPat: [String] = []
            for (n, _, p) in plans {
                for s in p.sessions where [nil, .fullBody, .upper, .lower].contains(s.spec.template) && s.spec.groups.isEmpty {
                    let pats = lifts(s).compactMap(\.pattern)
                    if Set(pats).count != pats.count { dupPat.append("\(n) \(s.label) \(lifts(s).map(\.name))") }
                }
            }
            check("audit 14 no pattern twice in a session", dupPat.isEmpty, "\(dupPat.prefix(3))")
            // 15. "Heavy" only with a heavy-capable lift; bodyweight strength uses harder progressions.
            let fakeHeavy = plans.flatMap { n, _, p in p.sessions.filter { $0.label.contains("Heavy") && !$0.items.contains(where: \.heavyLoad) }.map { "\(n) \($0.label)" } }
            check("audit 15 Heavy sessions have a heavy lift", fakeHeavy.isEmpty, "\(fakeHeavy.prefix(4))")
            let a09 = SP.plan(for: audit[8].1)
            check("audit 15 bodyweight strength: low-rep progressions", a09.sessions.flatMap(lifts).contains { ["Pistol Squats", "Archer Push-ups"].contains($0.name) }
                  && !a09.sessions.flatMap(lifts).contains { $0.name == "Bodyweight Squats" })
            // 16. 30-minute VO2max: short warm-up, 10+ minutes hard.
            let vo30 = SP.build(SP.Spec(kind: .intervals), ctx: SP.Ctx(config: c(.generalFitness, .advanced, len: 30)))
            let warm = vo30.items.first { $0.name.contains("Warm-up") }?.minutes ?? 99
            let iv = vo30.items.first { $0.kind == .intervals }
            let hardMin = Double(iv?.sets ?? 0) * (Double(iv?.reps.split(separator: "x").last?.dropLast() ?? "0") ?? 0) / 60
            check("audit 16 30-min VO2max: warm-up <= 6, >= 10 min hard", warm <= 6 && hardMin >= 10 && vo30.minutes <= 30.5, "\(vo30.items.map(\.text))")
            // 17. Fixed microcycle: week 2 = week 1; a named workout is the same every time it appears.
            var drift: [String] = []
            for (n, cf, p) in plans {
                if cf.scheduleMode == .weekly {
                    let h = p.sessions.count / 2
                    for i in 0..<h where p.sessions[i].items.map(\.text) != p.sessions[i + h].items.map(\.text) { drift.append("\(n) \(p.slots[i].label)") }
                }
                var byLabel: [String: [String]] = [:]
                for s in p.sessions where s.hasStrength {
                    let t = s.items.filter { [.lift, .cardio, .intervals, .walk].contains($0.kind) }.map(\.text)
                    if let prev = byLabel[s.label], prev != t { drift.append("\(n) \(s.label)") }
                    byLabel[s.label] = t
                }
            }
            check("audit 17 same week to week, same sets per named workout", drift.isEmpty, "\(Set(drift).prefix(5))")
            let a06Kinds = a06.sessions.map(\.spec.kind)
            check("audit 17 size 6/wk: both weeks have the same lifting days", Array(a06Kinds.prefix(6)) == Array(a06Kinds.suffix(6)))

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

            // Warm-up, rest-day page and joint-safe longevity (Daniel, 2026-11-16).
            // 1. Every session opens with a timed warm-up that counts toward its minutes.
            var noWarm: [String] = []
            for (n, cf, p) in plans {
                for s in p.sessions {
                    guard s.items.first?.kind == .warmup else { noWarm.append("\(n) \(s.label) first \(s.items.first?.name ?? "-")"); continue }
                    let w = s.warmupMinutes
                    let drills = s.items.filter(\.warmDrill).count
                    if s.hasStrength {
                        // Ramp-up sets only toward a working weight; a bodyweight first lift gets a practice set.
                        let ramp = s.items.first { $0.name.hasPrefix("Warm-up: Ramp-up Sets for ") || $0.name.hasPrefix("Warm-up: Practice Set of ") }
                        let firstLift = s.items.first { $0.kind == .lift }?.name ?? ""
                        if w < 6 || drills < 3 || ramp == nil { noWarm.append("\(n) \(s.label) warm \(w) drills \(drills)") }
                        if let r = ramp {
                            if let target = s.items.first(where: { $0.kind == .lift && r.name.contains("for \($0.name) (") || r.name.contains("of \($0.name) (") }) {
                                if r.name.contains("Ramp-up") != SP.isLoadable(target, ctx: SP.Ctx(config: cf)) { noWarm.append("\(n) \(r.name) loadable mismatch") }
                            } else { noWarm.append("\(n) ramp \(r.name) vs \(firstLift)") }
                        }
                        // Lifts end before the session's length runs out with the warm-up counted.
                        if s.warmupMinutes + s.strengthMinutes > Double(cf.sessionLength) + 0.5 { noWarm.append("\(n) \(s.label) over") }
                    }
                    if (s.spec.kind == .intervals || s.spec.kind == .gentleIntervals) && drills < 2 { noWarm.append("\(n) \(s.label) interval drills \(drills)") }
                    if abs(s.minutes - s.items.reduce(0) { $0 + $1.duration }) > 0.01 || w > s.minutes { noWarm.append("\(n) \(s.label) minutes") }
                }
                // The schedule's duration includes the warm-up.
                for (s, sw) in zip(p.sessions, p.scheduledWorkouts) where sw.estimatedDuration < min(cf.sessionLength, Int(s.minutes.rounded())) {
                    noWarm.append("\(n) \(s.label) scheduled \(sw.estimatedDuration)")
                }
            }
            check("warm-up first in every session, timed and counted in its minutes", noWarm.isEmpty, "\(noWarm.prefix(5))")
            let lonWarm = lon.sessions[0].items.prefix { $0.kind == .warmup }
            check("warm-up on longevity day 1: cardio raise, 4 drills, 3-min ramp-up, 12 min",
                  lonWarm.count == 6 && lonWarm.first?.minutes == 5 && lonWarm.last?.minutes == 3 && lonWarm.reduce(0) { $0 + $1.minutes } == 12, "\(lonWarm.map(\.text))")
            let wParsed = lon.scheduledWorkouts[0].plannedExercises.filter { $0.name.hasPrefix("Warm-up") }
            check("warm-up entries parse as timed targets", wParsed.count == 6 && wParsed.allSatisfy { $0.seconds != nil && $0.repMin == nil })

            // 2. No rest-day item inside any training session; a separate rest-day plan instead.
            let restItems = plans.flatMap { n, _, p in p.sessions.flatMap(\.items).filter { $0.name.lowercased().contains("rest day") }.map { "\(n) \($0.name)" } }
            check("no rest-day item in any training session", restItems.isEmpty, "\(restItems.prefix(3))")
            check("longevity 4on/1off sessions carry no outside-the-session walk", !lon.sessions.flatMap(\.items).contains { $0.kind == .outside })
            let rdp = lon.restDayPlan
            let rdItems = rdp.plannedExercises
            check("rest-day plan: walk 20-30 min, 10 min mobility, all timed",
                  rdItems.count >= 2 && rdItems[0].name.contains("Walk") && (1200...1800).contains(rdItems[0].seconds ?? 0)
                  && rdItems.contains { $0.name.contains("Mobility") && $0.seconds == 600 }
                  && rdItems.allSatisfy { $0.seconds != nil && $0.repMin == nil }, "\(rdp.exercises)")
            check("rest-day plan covers the aerobic gap", lon.restDayWalk == 0 || Double(rdItems[0].seconds ?? 0) / 60 >= lon.restDayWalk)
            let rdData = try? JSONEncoder().encode(rdp)
            check("rest-day plan Codable", rdData.flatMap { try? JSONDecoder().decode(RestDayPlan.self, from: $0) } == rdp)
            let rdSession = rdp.asScheduledWorkout
            check("rest-day plan opens as a recovery session", rdSession.plannedExercises.count == rdp.exercises.count
                  && rdSession.workoutType == rdp.title)
            check("explicit splits get a default rest-day plan", !SP.restDayPlan(config: c(.buildMuscle)).exercises.isEmpty)
            // Retrievable on rest days, nil on training days, in both schedule modes.
            let rdStart = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 8))!   // a Monday
            func rdOn(_ k: Int, rolling: Bool) -> RestDayPlan? {
                RestDayPlan.forDate(cal.date(byAdding: .day, value: k, to: rdStart)!, start: rdStart, rolling: rolling, daysOn: 4, daysOff: 1,
                                    weekdays: ["Monday", "Tuesday", "Thursday", "Friday"], plan: rdp, calendar: cal)
            }
            let rollRest = (0..<10).filter { rdOn($0, rolling: true) != nil }
            let weekRest = (0..<14).filter { rdOn($0, rolling: false) != nil }
            check("rest-day plan on rolling rest days only", rollRest == [4, 9], "\(rollRest)")
            check("rest-day plan on weekly rest days only", weekRest == [2, 5, 6, 9, 12, 13], "\(weekRest)")
            check("no rest-day plan before the program starts", rdOn(-1, rolling: true) == nil)
            check("rest days leave training-day indexing alone",
                  WorkoutManager.trainingDayIndex(on: cal.date(byAdding: .day, value: 5, to: rdStart)!, start: rdStart, rolling: true,
                                                  daysOn: 4, daysOff: 1, weekdays: [], calendar: cal) == 4)

            // 3. Joint-safe longevity: 8+ reps (10+ for beginners), no high-risk moves, a stated effort cap.
            let risky = Set(SP.catalog.filter { $0.longevity < 0 }.map(\.name))
            check("longevity risky list covers the named lifts", ["Back Squats", "Front Squats", "Deadlifts", "Barbell Bench Press", "Barbell Rows",
                  "Pull-ups", "Ab Wheel Rollouts", "Hanging Knee Raises"].allSatisfy(risky.contains))
            var lonPlans = plans.filter { $0.1.primaryGoal == .longevity }
            for e in [ExperienceLevel.beginner, .intermediate, .advanced] {
                for eq in [EquipmentLevel.fullGym, .homeGym, .minimal, .bodyweight] {
                    lonPlans.append(("lon \(e.rawValue) \(eq)", c(.longevity, e, rolling: (4, 1), eq: eq), SP.plan(for: c(.longevity, e, rolling: (4, 1), eq: eq))))
                    lonPlans.append(("lon \(e.rawValue) \(eq) 3/wk", c(.longevity, e, perWeek: 3, eq: eq), SP.plan(for: c(.longevity, e, perWeek: 3, eq: eq))))
                }
            }
            var lonBad: [String] = []
            for (n, cf, p) in lonPlans {
                for it in p.sessions.flatMap(lifts) {
                    if risky.contains(it.name) { lonBad.append("\(n) risky \(it.name)") }
                    if let lo = Int(it.reps.split(separator: "-").first ?? "") {
                        if lo < 8 { lonBad.append("\(n) \(it.name) \(it.reps)") }
                        if cf.experienceLevel == .beginner && (it.pattern?.isCompound ?? false) && lo < 10 { lonBad.append("\(n) beginner \(it.name) \(it.reps)") }
                    }
                    if it.heavyLoad { lonBad.append("\(n) heavy \(it.name)") }
                }
                for (ps, sw) in zip(p.sessions, p.scheduledWorkouts) where ps.hasStrength {
                    if !(sw.notes ?? "").contains("2-3 reps short of failure") { lonBad.append("\(n) \(sw.workoutType) no effort cue") }
                }
            }
            check("longevity: no set below 8 reps, no high-risk moves, effort cue on lifting days", lonBad.isEmpty, "\(lonBad.prefix(6))")
            let lonFull = lon.sessions.flatMap(lifts)
            check("longevity full gym uses joint-safe swaps", lonFull.contains { ["Goblet Squats", "Leg Press", "Safety Bar Squats"].contains($0.name) }
                  && lonFull.allSatisfy { $0.pattern != .squat || ["Goblet Squats", "Leg Press", "Safety Bar Squats", "Belt Squats"].contains($0.name) },
                  "\(Set(lonFull.map(\.name)))")
            // Review fixes (planner).
            // 3. Longevity rotates only among its best-ranked variations.
            let lowerRanked = ["Bulgarian Split Squats", "Walking Lunges", "Back Extensions", "Barbell Hip Thrusts", "Skull Crushers"]
            var rotBad: [String] = []
            for (n, cf, p) in lonPlans where cf.equipment == .fullGym {
                for it in p.sessions.flatMap(lifts) where lowerRanked.contains(it.name) { rotBad.append("\(n) \(it.name)") }
            }
            for e in [ExperienceLevel.beginner, .intermediate, .advanced] {
                for v in 0..<6 {
                    for pat in SP.Pattern.allCases {
                        let ctx = SP.Ctx(config: c(.longevity, e))
                        let all = SP.ranked(pat, ctx: ctx, intensity: .foundation, used: [])
                        guard let best = all.first, let m = SP.pick(pat, variant: v, ctx: ctx, intensity: .foundation, used: []), m.pattern == pat else { continue }
                        if m.longevity < best.longevity { rotBad.append("\(e.rawValue) \(pat) v\(v) \(m.name) < \(best.name)") }
                    }
                }
            }
            check("longevity rotation never picks a lower-ranked variation", rotBad.isEmpty, "\(rotBad.prefix(6))")
            // 4. Ramp-up sets only toward a working weight: bodyweight first lifts get a practice set.
            let bwLon = SP.plan(for: c(.longevity, .intermediate, rolling: (4, 1), eq: .bodyweight))
            let bwWarm = bwLon.sessions.flatMap(\.items).filter { $0.kind == .warmup }.map(\.name)
            check("bodyweight plan: practice sets, no ramp-up to a working weight",
                  !bwWarm.contains { $0.contains("Ramp-up") } && bwWarm.contains { $0.hasPrefix("Warm-up: Practice Set of ") }, "\(bwWarm.prefix(8))")
            let lbLon = SP.plan(for: c(.longevity, .intermediate, perWeek: 3, inj: ["Low back"]))
            let lbRamp = lbLon.sessions.flatMap(\.items).filter { $0.name.contains("Ramp-up Sets for Single-Leg") || $0.name.contains("Ramp-up Sets for Push-ups") }
            check("low-back longevity: no ramp-up for a bodyweight hinge", lbRamp.isEmpty, "\(lbRamp.map(\.name))")
            // 5/6. Rest-day walk: recovery length (<= 30 min), the same minutes the plan counts;
            // training days carry an extra walk only when the rest days are full.
            var walkBad: [String] = []
            for e in [ExperienceLevel.beginner, .intermediate] {
                for len in [30, 45, 60] {
                    for (r, pw) in [((4, 1), 0), ((3, 1), 0), ((5, 2), 0), ((0, 0), 4), ((0, 0), 6), ((0, 0), 3)] as [((Int, Int), Int)] {
                        for inj in [Set<String>(), ["Knee"]] {
                            let cf = r.0 > 0 ? c(.longevity, e, rolling: r, len: len, inj: inj) : c(.longevity, e, perWeek: pw, len: len, inj: inj)
                            let p = SP.plan(for: cf)
                            let tag = "\(e.rawValue) \(r) \(pw) \(len) \(inj)"
                            let walk = (p.restDayPlan.plannedExercises.first?.seconds ?? 0) / 60
                            if walk > 30 { walkBad.append("long rest walk \(walk) " + tag) }
                            if p.restDayWalk > 0 && Double(walk) != p.restDayWalk { walkBad.append("walk \(walk) vs \(p.restDayWalk) " + tag) }
                            let extra = p.sessions.flatMap(\.items).contains { $0.kind == .outside }
                            if extra && p.walkDaysPerWeek > 0.01 && p.restDayWalk < SP.maxRestDayWalk { walkBad.append("extra walk with room " + tag) }
                            if p.restDayPlan.estimatedDuration > 45 { walkBad.append("rest day \(p.restDayPlan.estimatedDuration) min " + tag) }
                        }
                    }
                }
            }
            check("rest-day walk <= 30 min, matches the plan, extra walks only when rest days are full", walkBad.isEmpty, "\(walkBad.prefix(5))")
            // 7. Short longevity plans keep hinge/hamstring and core work; no upper-only day under 45 min.
            var shortBad: [String] = []
            for e in [ExperienceLevel.intermediate, .advanced] {
                for pw in [2, 3, 4, 5] {
                    let p = SP.plan(for: c(.longevity, e, perWeek: pw, len: 30))
                    let tag = "\(e.rawValue) \(pw)/wk"
                    if p.sessions.contains(where: { $0.spec.template == .upper && $0.spec.kind == .strength }) { shortBad.append("upper day " + tag) }
                    // Known limit: two 30-min lifting days hold one hinge a week (2 of 3 hamstring
                    // sets), and 2/wk Strength + Zone 2 has no room for core work.
                    for l in SP.longevityFloorReport(p) {
                        if l.group == "Hamstrings" && l.sets < 2 { shortBad.append("Hamstrings \(l.sets) " + tag) }
                        if l.group == "Core" && pw >= 3 && l.sets < Double(l.target.lowerBound) - 0.01 { shortBad.append("Core \(l.sets) " + tag) }
                    }
                }
            }
            check("longevity 30 min: a hinge every week, core at its minimum (3+/wk), no upper-only day", shortBad.isEmpty, "\(shortBad.prefix(6))")
            // 8. Interval warm-ups: leg drills in order, build-up efforts last.
            var ivBad: [String] = []
            for len in [30, 40, 60] {
                for g in [TrainingGoal.longevity, .improveEndurance, .loseWeight] {
                    for s in SP.plan(for: c(g, .intermediate, rolling: (4, 1), len: len)).sessions where s.spec.kind == .intervals {
                        let w = s.items.prefix { $0.kind == .warmup }.map(\.name)
                        if w.last != "Warm-up: \(SP.buildUps)" { ivBad.append("\(g.rawValue) \(len) \(w)") }
                        if w.count >= 3 && w[1] != "Warm-up: Leg Swings (10 each leg)" { ivBad.append("\(g.rawValue) \(len) order \(w)") }
                        if w.count >= 4 && w[2] != "Warm-up: Walking Knee Hugs (8 each leg)" { ivBad.append("\(g.rawValue) \(len) skip \(w)") }
                    }
                }
            }
            let ctxK = SP.Ctx(config: c(.longevity))
            let fourDrills = SP.warmDrillItems(areas: [4], count: 4, ctx: ctxK).map(\.name)
            check("interval warm-up ends with build-ups; drills taken in order", ivBad.isEmpty
                  && fourDrills == SP.warmDrills[4]!.map { "Warm-up: \($0.name)" }, "\(ivBad.prefix(3)) \(fourDrills)")
            // 9. Shoulder injuries: no overhead hanging pulls or end-range flyes.
            var shInjBad: [String] = []
            for g in [TrainingGoal.longevity, .buildMuscle, .generalFitness] {
                for e in [ExperienceLevel.beginner, .advanced] {
                    for eq in [EquipmentLevel.fullGym, .homeGym, .minimal] {
                        let p = SP.plan(for: c(g, e, perWeek: 4, eq: eq, inj: ["Shoulder"]))
                        for it in p.sessions.flatMap(lifts) where ["Band-Assisted Pull-ups", "Dumbbell Flyes", "Pec Deck", "Pull-ups", "Chin-ups",
                                                                   "Weighted Pull-ups", "Assisted Pull-ups"].contains(it.name) {
                            shInjBad.append("\(g.rawValue) \(e.rawValue) \(eq) \(it.name)")
                        }
                    }
                }
            }
            check("shoulder injury: no pull-up variations, flyes or pec deck", shInjBad.isEmpty, "\(shInjBad.prefix(5))")
            check("shoulder injury: lat pulldowns are the vertical-pull swap",
                  SP.plan(for: c(.longevity, .advanced, perWeek: 4, inj: ["Shoulder"])).sessions.flatMap(lifts).contains { $0.name == "Lat Pulldowns" })
            // 11. Ramp-up time: 3 min at 45+ min, 2 under.
            check("ramp-up booked 3 min (45+) / 2 min (<45)", SP.strengthWarmup(60, ctx: ctxK).ramp == 3 && SP.strengthWarmup(30, ctx: ctxK).ramp == 2)

            // Review fixes (app).
            // 10. Hand-picked splits on longevity: no heavy "strength" days, joint-safe swaps, 8+ reps, fits the length.
            let banned = ["Barbell Bench Press", "Bench Press", "Overhead Press", "Weighted Dips", "Back Squats", "Squats", "Deadlifts",
                          "Romanian Deadlifts", "Pull-ups", "Weighted Pull-ups", "Barbell Rows", "Chin-ups", "Skull Crushers", "Lunges", "Push Press"]
            var exBad: [String] = []
            for split in ProgramSplit.allCases where split != .auto {
                for len in [30, 45, 60, 90] {
                    var cf = c(.longevity, .intermediate, perWeek: 4, len: len); cf.split = split
                    for w in WorkoutManager.shared.explicitSplitSchedule(config: cf, days: ["Monday", "Tuesday", "Thursday", "Friday"]) {
                        let plan = w.exercises.map(ProgramTargetParser.parse)
                        for pe in plan where banned.contains(pe.name) { exBad.append("\(split.rawValue) \(len) \(pe.name)") }
                        for pe in plan where (pe.repMin ?? 99) < 8 { exBad.append("\(split.rawValue) \(len) \(pe.name) \(pe.repMin ?? 0)") }
                        let timed = plan.reduce(0) { $0 + ($1.repMin == nil ? ($1.seconds ?? 0) / 60 : 0) }
                        if timed > len - 15 { exBad.append("\(split.rawValue) \(len) timed \(timed)") }
                        let first = plan.first { !$0.name.hasPrefix("Warm-up") }?.name ?? ""
                        let ramp = plan.first { $0.name.hasPrefix("Warm-up: Ramp-up") || $0.name.hasPrefix("Warm-up: Practice") }?.name ?? ""
                        let loadable = ExerciseLibrary.shared.tracking(forID: nil, name: first) == .weighted
                        if ramp.contains("Ramp-up") != loadable { exBad.append("\(split.rawValue) \(len) \(ramp) for \(first)") }
                    }
                }
            }
            check("hand-picked longevity splits: joint-safe, 8+ reps, fit the session, ramp-up only when loaded", exBad.isEmpty, "\(exBad.prefix(5))")
            var phul = c(.getStronger, .intermediate, perWeek: 4); phul.split = .phul
            check("hand-picked splits for other goals keep their heavy days",
                  WorkoutManager.shared.explicitSplitSchedule(config: phul, days: ["Monday", "Tuesday", "Thursday", "Friday"])
                    .flatMap(\.exercises).contains { $0.hasPrefix("Bench Press 5x5") })
            // App 1 / coach 1. Programs from an older planner: answers saved, rebuilt from them, or read back.
            var saved = c(.longevity, .intermediate, rolling: (4, 1)); saved.injuries = ["Knee"]
            let savedData = try? JSONEncoder().encode(saved)
            check("program config round-trips (saved for planner updates)", savedData.flatMap { try? JSONDecoder().decode(ProgramConfig.self, from: $0) } == saved)
            check("planner version bumped past the old planner", SP.version >= 3)
            let legacy = [ScheduledWorkout(dayOfWeek: "Day 1", workoutType: "Full Body Strength A",
                                           exercises: ["Back Squats 3x6-10", "Brisk Walk on rest days 20 min"], estimatedDuration: 59),
                          ScheduledWorkout(dayOfWeek: "Day 2", workoutType: "Zone 2 + Mobility", exercises: ["Zone 2 Cardio 45 min"], estimatedDuration: 39)]
            let vals: [String: Any] = ["progressionGoal": "Longevity", "progressionExperience": "Intermediate", "scheduleMode": ScheduleMode.rolling.rawValue,
                                       "cycleDaysOn": 4, "cycleDaysOff": 1, "trainingWeekdays": ["Day 1", "Day 2", "Day 3", "Day 4"], "mesocycleWeeks": 6]
            let rc = WorkoutManager.reconstructConfig(schedule: legacy, values: vals, profile: nil)
            check("legacy program read back: goal, level, 4 on / 1 off, 60 min, Smart Advisor",
                  rc?.primaryGoal == .longevity && rc?.experienceLevel == .intermediate && rc?.scheduleMode == .rolling
                  && rc?.daysOn == 4 && rc?.daysOff == 1 && rc?.sessionLength == 60 && rc?.split == .auto, "\(String(describing: rc))")
            let ulLegacy = ["Upper Body", "Lower Body", "Upper Body", "Lower Body"].enumerated().map {
                ScheduledWorkout(dayOfWeek: "Day \($0.offset + 1)", workoutType: $0.element, exercises: [], estimatedDuration: 45) }
            check("legacy hand-picked split detected from its labels",
                  WorkoutManager.reconstructConfig(schedule: ulLegacy, values: vals, profile: nil)?.split == .upperLower)
            check("stale in-session rest-day walks recognised",
                  WorkoutManager.isStaleRestDayEntry("Brisk Walk on rest days 20 min") && WorkoutManager.isStaleRestDayEntry("Brisk Walk every day (outside the session) 15 min")
                  && !WorkoutManager.isStaleRestDayEntry("Zone 2 Cardio 45 min"))
            // App 3. A logged recovery session neither hides a missed day nor counts as a workout.
            let rcStart = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 8))!
            func dayAt(_ k: Int) -> Date { cal.date(byAdding: .day, value: k, to: rcStart)! }
            // 4 on / 1 off: days 0-2 trained, day 3 skipped, recovery logged on rest day 4, checked on day 5.
            var logs = (0..<3).map { WorkoutSession(date: dayAt($0), programName: "Full Body Strength A", completed: true) }
            logs.append(WorkoutSession(date: dayAt(4), programName: RestDayPlan.recoveryTitle, completed: true))
            let missedAfterRecovery = SmartCoach.missedRollingDays(start: rcStart, daysOn: 4, daysOff: 1,
                                                                   logged: SmartCoach.trainingDates(logs), now: dayAt(5), calendar: cal)
            check("recovery session does not hide a missed training day", logs.last?.isRecoverySession == true && missedAfterRecovery == 1,
                  "\(missedAfterRecovery)")
            // App 4. No rest-day page for programs with no rest days.
            check("rest days: none for 7-day weeks or 0 days off, found otherwise",
                  !WorkoutManager.programHasRestDay(from: rcStart, cycleStart: rcStart, rolling: false, daysOn: 0, daysOff: 0,
                                                    weekdays: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], calendar: cal)
                  && !WorkoutManager.programHasRestDay(from: rcStart, cycleStart: rcStart, rolling: true, daysOn: 5, daysOff: 0, weekdays: [], calendar: cal)
                  && WorkoutManager.programHasRestDay(from: rcStart, cycleStart: rcStart, rolling: true, daysOn: 4, daysOff: 1, weekdays: [], calendar: cal)
                  && WorkoutManager.programHasRestDay(from: rcStart, cycleStart: rcStart, rolling: false, daysOn: 0, daysOff: 0,
                                                      weekdays: ["Monday", "Tuesday", "Thursday", "Friday"], calendar: cal))

            // Other goals keep their lifts: size and strength still use the barbell staples.
            let strengthLifts = SP.plan(for: c(.getStronger, perWeek: 3)).sessions.flatMap(lifts).map(\.name)
            check("other goals keep barbell lifts and no longevity-only variations",
                  strengthLifts.contains("Back Squats") && !plans.filter { $0.1.primaryGoal != .longevity }
                    .flatMap { $0.2.sessions.flatMap(lifts) }.contains { catalogByName[$0.name]?.longevityOnly == true })
        }


        // MARK: Directions for every program item
        do {
            typealias G = ExerciseGuide
            let names = programItemNames()
            var missing: [String] = [], thin: [String] = []
            var before = 0, fromGuide = 0
            for name in names.keys.sorted() {
                if let lib = ExerciseLibrary.shared.match(name: name), !lib.instructions.isEmpty { before += 1 }
                guard let d = G.directions(for: name) else { missing.append("\(name) [\(names[name] ?? "")]"); continue }
                if d.steps.isEmpty || d.cue.isEmpty || d.safety.isEmpty || d.inlineSteps.isEmpty { thin.append(name) }
                if !d.stepsFromLibrary { fromGuide += 1 }
            }
            check("library readable for the directions test", ExerciseLibrary.shared.count > 800, "\(ExerciseLibrary.shared.count)")
            check("directions: every program item has directions (\(names.count) names: \(before) from the library alone before the guide, \(names.count - missing.count) now, \(fromGuide) with guide steps)",
                  missing.isEmpty && names.count > 250, missing.joined(separator: " | "))
            check("directions: every item has a cue, steps and a safety cue", thin.isEmpty, thin.joined(separator: " | "))
            var bad: [String] = [], dup: [String] = []
            var owner: [String: String] = [:]
            for e in G.entries {
                if !(2...4).contains(e.steps.count) || e.safety.isEmpty || e.easier.isEmpty || e.harder.isEmpty || e.cue.isEmpty || e.cue.count > 110 {
                    bad.append(e.names[0])
                }
                for n in e.names {
                    let k = G.key(for: n)
                    if let o = owner[k], o != e.names[0] { dup.append("\(n) (\(o))") }
                    owner[k] = e.names[0]
                }
            }
            check("guide: 2-4 steps, safety cue, easier and harder options, short cue (\(G.entries.count) guides)", bad.isEmpty, bad.joined(separator: ", "))
            check("guide: no name maps to two guides", dup.isEmpty, dup.joined(separator: ", "))
            let plannerNames = SmartPlanner.catalog.map(\.name)
                + (SmartPlanner.mobilityPool + SmartPlanner.balancePool + SmartPlanner.stabilityPool).map(\.name)
                + SmartPlanner.warmDrills.values.flatMap { $0.map { "Warm-up: \($0.name)" } }
            let unguided = plannerNames.filter { G.entry(for: $0) == nil }
            check("guide: every Smart Advisor move, drill and warm-up has its own guide (safety + options)", unguided.isEmpty, unguided.joined(separator: ", "))
            check("guide keys drop prefixes, doses and schemes",
                  G.key(for: "Warm-up: Leg Swings (10 each leg) 1 min") == G.key(for: "Leg Swings")
                  && G.key(for: "Warm-up: Ramp-up Sets for Back Squats (2-3 lighter sets building to your working weight) 4 min") == "ramp up set"
                  && G.key(for: "Optional: Foam Rolling (calves, quads, upper back) 5 min") == G.key(for: "Foam Rolling")
                  && G.key(for: "VO2max Intervals: 4 min hard / 3 min easy (bike or rower) 5x240s") == G.key(for: "VO2max Intervals")
                  && G.key(for: "Zone 2 Cardio (brisk walk or easy jog) 35 min") == G.key(for: "Zone 2 Cardio"),
                  G.key(for: "Warm-up: Leg Swings (10 each leg) 1 min"))
            let guideFirst = ["Pallof Press", "Bird Dog", "Goblet Squats", "Box Squats", "Split Squats", "Side Plank",
                              "Kettlebell Swings", "Dumbbell Romanian Deadlifts", "Hip Thrusts"]
            let wrong = guideFirst.filter { G.directions(for: $0)?.stepsFromLibrary != false }
            check("directions: poor or empty library matches use the guide's steps", wrong.isEmpty, wrong.joined(separator: ", "))
            let bench = G.directions(for: "Barbell Bench Press 3x8")
            check("directions: a good library match keeps its steps plus the guide's cue, safety and options",
                  bench?.stepsFromLibrary == true && bench?.libraryID != nil && bench?.easier != nil
                  && (bench?.quickSteps.count ?? 0) >= 2 && bench?.inlineSteps == Array(bench?.quickSteps.prefix(2) ?? []))
            let ramp = G.directions(for: "Warm-up: Ramp-up Sets for Goblet Squats (2-3 lighter sets building to your working weight) 3 min")
            check("directions: ramp-up sets name their lift and give the percentages",
                  ramp?.kind == .warmup && ramp?.steps.contains { $0.contains("Goblet Squats") } == true
                  && ramp?.cue.contains("50%") == true, "\(String(describing: ramp?.steps))")
            check("directions: effort note on lifts only",
                  G.directions(for: "Goblet Squats")?.effortNote?.contains("2-3") == true
                  && G.directions(for: "Zone 2 Cardio (brisk walk or easy jog) 35 min")?.effortNote == nil)
            let z2 = G.directions(for: "Zone 2 Cardio (bike, rower or incline walk) 30 min")
            check("directions: Zone 2 explains the talk test, 60-70% max HR and nasal breathing",
                  z2?.steps.joined().contains("60-70%") == true && z2?.steps.joined().contains("nose") == true
                  && z2?.cue.contains("talk") == true)
            let rest = SmartPlanner.restDayPlan(config: SmartPlanner.sampleConfig(.longevity, inj: ["Knee"]))
            let restCues = rest.plannedExercises.compactMap { G.cue(for: $0.name) }
            check("directions: every rest-day item has a one-line cue", restCues.count == rest.exercises.count && !restCues.isEmpty,
                  "\(restCues.count)/\(rest.exercises.count)")
        }
        print(failures == 0 ? "SELFTEST PASS \(count)/\(count)" : "SELFTEST FAIL \(failures) of \(count)")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Directions coverage

extension EngineSelfTest {
    /// The repo's App/Resources folder. The command-line selftest is a bare
    /// executable with no bundle, so it reads the bundled JSON from the repo.
    static var repoResources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
    }

    /// Every exercise name any program can put in front of a user, with where
    /// it came from: the Smart Advisor (its catalog, drill pools and warm-ups,
    /// and real plans over a matrix of wizard answers), the explicit splits,
    /// the old template pools and preset generators, the in-app program
    /// catalog, the bundled preset JSON and the custom builder's quick picks.
    static func programItemNames(full: Bool = false) -> [String: String] {
        var out: [String: String] = [:]
        func add(_ raw: String, _ origin: String) {
            let name = ProgramTargetParser.parse(raw).name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, out[name] == nil else { return }
            out[name] = origin
        }
        typealias SP = SmartPlanner
        // Static pools.
        for m in SP.catalog {
            add(m.name, "planner move")
            // Any move can open a session, as ramp-up sets (loaded) or a practice set (bodyweight).
            add("Warm-up: Ramp-up Sets for \(m.name) (2-3 lighter sets building to your working weight)", "planner ramp-up")
            add("Warm-up: Practice Set of \(m.name) (1 easy set at half your reps)", "planner ramp-up")
        }
        for d in SP.mobilityPool + SP.balancePool + SP.stabilityPool { add(d.name, "planner drill") }
        for (_, list) in SP.warmDrills { for d in list { add("Warm-up: \(d.name)", "planner warm-up drill") } }
        add("Warm-up: \(SP.buildUps)", "planner warm-up drill")
        // Real Smart Advisor plans and explicit splits over the wizard's answers.
        let goals = TrainingGoal.allCases
        let levels: [ExperienceLevel] = [.beginner, .intermediate, .advanced]
        let gear: [EquipmentLevel] = [.fullGym, .homeGym, .minimal, .bodyweight]
        let injuries: [Set<String>] = [[], ["Knee"], ["Low back"], ["Shoulder"], ["Knee", "Low back", "Shoulder"]]
        let shapes: [(rolling: (Int, Int)?, perWeek: Int, len: Int)] = [
            (nil, 2, 30), (nil, 3, 45), (nil, 4, 60), (nil, 5, 20), (nil, 6, 90), ((4, 1), 4, 60), ((3, 1), 3, 30), ((2, 1), 2, 45),
        ]
        let splits = ProgramSplit.allCases.filter { $0 != .auto }
        func run(_ g: TrainingGoal, _ e: ExperienceLevel, _ q: EquipmentLevel, _ inj: Set<String>,
                 _ s: (rolling: (Int, Int)?, perWeek: Int, len: Int), splitsToo: Bool) {
            let c = SP.sampleConfig(g, e, rolling: s.rolling, perWeek: s.perWeek, len: s.len, eq: q, inj: inj)
            let p = SP.plan(for: c)
            for w in p.scheduledWorkouts { for x in w.exercises { add(x, "planner plan") } }
            for x in p.restDayPlan.exercises { add(x, "rest day") }
            guard splitsToo else { return }
            for split in splits {
                var sc = c
                sc.split = split
                let days = s.rolling == nil ? SP.weekdays(for: sc) : (1...max(1, sc.daysOn)).map { "Day \($0)" }
                for w in WorkoutManager.shared.explicitSplitSchedule(config: sc, days: days) {
                    for x in w.exercises { add(x, "explicit split") }
                }
            }
        }
        if full {
            for g in goals { for e in levels { for q in gear { for inj in injuries {
                for (k, s) in shapes.enumerated() { run(g, e, q, inj, s, splitsToo: k % 3 == 0) }
            } } } }
        } else {
            // Every goal x equipment x injury set (rotating shape and level), then
            // every goal x shape x level on a full gym. Matches the full matrix's names.
            var n = 0
            for g in goals { for q in gear { for inj in injuries {
                run(g, levels[n % levels.count], q, inj, shapes[n % shapes.count], splitsToo: n % 2 == 0)
                n += 1
            } } }
            for g in goals { for s in shapes { run(g, levels[n % levels.count], .fullGym, [], s, splitsToo: false); n += 1 } }
        }
        // Old template pools.
        for group in ["Push", "Pull", "Legs", "Upper", "Lower", "Chest", "Back", "Shoulders", "Arms", "Full Body", "Other"] {
            for focus in ["strength", "muscle building", "fat loss", "endurance", "general"] {
                for minutes in [15, 45, 90, 120] {
                    for x in WorkoutManager.generateExercises(for: group, duration: minutes, focus: focus) { add(x, "template pool") }
                }
            }
        }
        // In-app program catalog.
        for prog in ProgramCatalog.all { for d in prog.days { for x in d.exercises { add(x, "program catalog") } } }
        // Bundled preset JSON.
        if let data = try? Data(contentsOf: repoResources.appendingPathComponent("preset_workout_programs.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let programs = json["programs"] as? [[String: Any]] {
            for prog in programs {
                for week in (prog["schedule"] as? [String: Any] ?? [:]).values {
                    for day in (week as? [String: Any] ?? [:]).values {
                        for ex in (day as? [String: Any])?["exercises"] as? [[String: Any]] ?? [] {
                            if let n = ex["name"] as? String { add(n, "preset JSON") }
                        }
                    }
                }
            }
        } else {
            out["<preset_workout_programs.json unreadable>"] = "preset JSON"
        }
        // The old preset generators and the builder's quick picks, read from
        // source (they are private and write straight into the schedule).
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        func scan(_ file: String, from: String, to: String, _ origin: String) {
            guard let text = try? String(contentsOf: src.appendingPathComponent(file), encoding: .utf8),
                  let a = text.range(of: from), let b = text.range(of: to, range: a.upperBound..<text.endIndex) else {
                out["<\(file) unreadable>"] = origin
                return
            }
            let region = String(text[a.lowerBound..<b.lowerBound])
            let interp = try! NSRegularExpression(pattern: #""([^"\\]+?) \\\(modulateReps"#)
            let arrays = try! NSRegularExpression(pattern: #"(?:exercises|quickPicks)\s*(?::|=)\s*\[([^\]]*)\]"#)
            let quoted = try! NSRegularExpression(pattern: #""([^"\\]+)""#)
            let ns = region as NSString
            for m in interp.matches(in: region, range: NSRange(location: 0, length: ns.length)) { add(ns.substring(with: m.range(at: 1)), origin) }
            for m in arrays.matches(in: region, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: m.range(at: 1))
                let nb = body as NSString
                for q in quoted.matches(in: body, range: NSRange(location: 0, length: nb.length)) {
                    let s = nb.substring(with: q.range(at: 1))
                    if s.first?.isUppercase == true { add(s, origin) }
                }
            }
        }
        scan("WorkoutTrackerMac_Enhanced.swift", from: "func generateProgramWithPreset", to: "func generateCustomWorkout", "old preset generator")
        scan("ProgramsMeso.swift", from: "private static let quickPicks", to: "var body", "custom builder")
        return out
    }

    /// `-ef.guidedump`: every program item name with its library match and guide (developer aid).
    static func dumpDirections() {
        ExerciseLibrary.fallbackResourceDirectory = repoResources
        let names = programItemNames(full: CommandLine.arguments.contains("-full"))
        for (name, origin) in names.sorted(by: { $0.key < $1.key }) {
            let lib = ExerciseLibrary.shared.match(name: name)?.name ?? "-"
            let d = ExerciseGuide.directions(for: name)
            let how = d.map { $0.stepsFromLibrary ? "library+guide" : "guide" } ?? "NONE"
            print("\(origin)\t\(name)\t\(lib)\t\(ExerciseGuide.entry(for: name) == nil && d != nil ? "library" : how)")
        }
        print("total \(names.count), library \(names.keys.filter { ExerciseLibrary.shared.match(name: $0) != nil }.count)")
    }
}
