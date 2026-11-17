//
//  ExerciseLibrary.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  The bundled exercise library: 876 exercises from free-exercise-db by yuhonas
//  (The Unlicense, public domain), shipped as Resources/exercise_library.json.
//  Each entry has a stable id, category, equipment, primary/secondary muscles
//  and step-by-step instructions. No images or videos are bundled.
//
//  The library is loaded once, on first use. It also maps the free-text names
//  older builds and the program catalog use ("Squats", "Bench Press 4x10") to
//  library ids so history, PRs and progression group correctly.
//

import Foundation

struct LibraryExercise: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let equipment: String?
    let level: String?
    let mechanic: String?
    let force: String?
    let primary: [String]
    let secondary: [String]
    let instructions: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, category, equipment, level, mechanic, force, primary, secondary, instructions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? "strength"
        equipment = try? c.decodeIfPresent(String.self, forKey: .equipment)
        level = try? c.decodeIfPresent(String.self, forKey: .level)
        mechanic = try? c.decodeIfPresent(String.self, forKey: .mechanic)
        force = try? c.decodeIfPresent(String.self, forKey: .force)
        primary = (try? c.decodeIfPresent([String].self, forKey: .primary)) ?? []
        secondary = (try? c.decodeIfPresent([String].self, forKey: .secondary)) ?? []
        instructions = (try? c.decodeIfPresent([String].self, forKey: .instructions)) ?? []
    }

    var tracking: SetTracking {
        ExerciseLibrary.inferTracking(category: category, equipment: equipment, force: force, name: name)
    }

    /// Legs and hips get the bigger load jump in progression.
    var isLowerBody: Bool { ExerciseLibrary.isLowerBody(muscles: primary) }

    var isBarbell: Bool { equipment == "barbell" }
}

final class ExerciseLibrary {
    static let shared = ExerciseLibrary()

    private struct File: Decodable {
        let source: String?
        let exercises: [LibraryExercise]
    }

    private(set) lazy var all: [LibraryExercise] = Self.loadBundled()
    private lazy var byID: [String: LibraryExercise] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    private lazy var byName: [String: LibraryExercise] = {
        var map: [String: LibraryExercise] = [:]
        for entry in all {
            let key = Self.normalize(entry.name)
            if map[key] == nil { map[key] = entry }
            let compact = key.replacingOccurrences(of: " ", with: "")
            if map[compact] == nil { map[compact] = entry }
        }
        return map
    }()
    private var matchCache: [String: String] = [:]
    private var missCache: Set<String> = []

    private init() {}

    /// Number of bundled exercises (0 if the resource is missing).
    var count: Int { all.count }

    func entry(id: String) -> LibraryExercise? { byID[id] }

    // MARK: Name matching

    /// The library entry a free-text name refers to: exact (normalised) name,
    /// a known alias, or the same name with a leading "barbell". Returns nil
    /// rather than guessing between several different movements.
    func match(name: String) -> LibraryExercise? {
        let base = Self.normalize(ProgramTargetParser.parse(name).name)
        guard !base.isEmpty else { return nil }
        if let id = matchCache[base] { return byID[id] }
        if missCache.contains(base) { return nil }

        var found: LibraryExercise?
        if let id = Self.aliases[base] { found = byID[id] }
        if found == nil { found = byName[base] ?? byName[base.replacingOccurrences(of: " ", with: "")] }
        if found == nil, !base.hasPrefix("barbell ") { found = byName["barbell " + base] }

        if let found { matchCache[base] = found.id } else { missCache.insert(base) }
        return found
    }

    /// Set tracking for a known id, else inferred from the name alone.
    func tracking(forID id: String?, name: String) -> SetTracking {
        // A planner move done with bodyweight or a band only is never given a load to pick.
        if let planned = SmartPlanner.bodyweightTracking(name: name) { return planned }
        if let id, let entry = byID[id] { return entry.tracking }
        if let entry = match(name: name) { return entry.tracking }
        return Self.inferTracking(category: nil, equipment: nil, force: nil, name: name)
    }

    // MARK: Search

    func search(_ query: String, muscle: String?, equipment: String?, category: String?) -> [LibraryExercise] {
        let tokens = Self.normalize(query).split(separator: " ").map(String.init)
        let filtered = all.filter { entry in
            if let muscle, !entry.primary.contains(muscle) { return false }
            if let equipment, (entry.equipment ?? "other") != equipment { return false }
            if let category, entry.category != category { return false }
            guard !tokens.isEmpty else { return true }
            let name = Self.normalize(entry.name)
            return tokens.allSatisfy { name.contains($0) }
        }
        guard !tokens.isEmpty else { return filtered }
        let q = Self.normalize(query)
        // Names that start with the query first, then alphabetical.
        return filtered.sorted { a, b in
            let pa = Self.normalize(a.name).hasPrefix(q), pb = Self.normalize(b.name).hasPrefix(q)
            if pa != pb { return pa }
            return a.name < b.name
        }
    }

    /// Distinct values for the picker's filter menus, most common first.
    lazy var muscles: [String] = Self.distinct(all.flatMap(\.primary))
    lazy var equipments: [String] = Self.distinct(all.map { $0.equipment ?? "other" })
    lazy var categories: [String] = Self.distinct(all.map(\.category))

    private static func distinct(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    // MARK: Helpers

    static func displayName(forMuscle muscle: String) -> String { muscle.capitalized }

    static func displayName(forEquipment equipment: String) -> String {
        switch equipment {
        case "body only": return "Bodyweight"
        case "e-z curl bar": return "EZ Bar"
        case "kettlebells": return "Kettlebell"
        default: return equipment.capitalized
        }
    }

    static func displayName(forCategory category: String) -> String { category.capitalized }

    static func isLowerBody(muscles: [String]) -> Bool {
        let lower: Set<String> = ["quadriceps", "hamstrings", "glutes", "calves", "adductors", "abductors", "lower back"]
        return muscles.contains { lower.contains($0) }
    }

    /// Lower-case, punctuation to spaces, simple plural stripping, and any
    /// trailing set/rep scheme removed by the caller.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        s = String(s.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let words = s.split(separator: " ").map { word -> String in
            var w = String(word)
            // "ups" counts too, so "pull-ups" matches "pull up".
            if w.count > 2, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us") { w.removeLast() }
            return w
        }
        return words.joined(separator: " ")
    }

    static func inferTracking(category: String?, equipment: String?, force: String?, name: String) -> SetTracking {
        if category == "cardio" || category == "stretching" { return .timed }
        // Whole-word matching, so "crunch" never matches "run".
        let words = " " + normalize(name) + " "
        func has(_ phrase: String) -> Bool { words.contains(" \(phrase) ") }

        let timedPhrases = ["plank", "hold", "wall sit", "side bridge", "dead hang", "cardio", "mobility",
                            "stretch", "flow", "yoga", "incline walk", "jog", "jogging", "run", "running",
                            "treadmill", "bike", "cycling", "elliptical", "min", "minute",
                            "battle rope", "battling rope", "sled push", "sled drag", "carry",
                            // Program warm-ups, cool-downs and rest-day recovery: never tracked lifts.
                            "warm up", "cool down", "brisk walk", "easy walk", "foam rolling", "breathing"]
        if timedPhrases.contains(where: has) { return .timed }
        if force == "static", equipment == nil || equipment == "body only" { return .timed }
        if equipment == "body only" { return .bodyweight }
        if category == "plyometrics", equipment == nil || equipment == "other" { return .bodyweight }
        // Library entries that list no equipment are bodyweight drills.
        if equipment == nil, category != nil { return .bodyweight }

        let bodyweightPhrases = ["push up", "pushup", "pull up", "pullup", "chin up", "chinup", "dip",
                                 "burpee", "sit up", "situp", "crunch", "crunche", "mountain climber",
                                 "jumping jack", "bodyweight", "air squat", "box jump", "jump squat",
                                 "inverted row", "hanging leg raise", "bird dog", "dead bug",
                                 "glute bridge", "high knee", "pistol", "nordic", "russian twist"]
        if bodyweightPhrases.contains(where: has) { return .bodyweight }
        return .weighted
    }

    /// Where to look when the app bundle has no copy (the command-line
    /// selftest build, which is a bare executable). Set before first use.
    static var fallbackResourceDirectory: URL?

    private static func loadBundled() -> [LibraryExercise] {
        let bundled = Bundle.main.url(forResource: "exercise_library", withExtension: "json")
        let fallback = fallbackResourceDirectory?.appendingPathComponent("exercise_library.json")
        guard let url = bundled ?? fallback,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.exercises
    }

    /// Common gym names → library ids, keyed by `normalize(_:)` output. Only
    /// unambiguous matches are listed; anything else keeps the lifter's name.
    private static let aliases: [String: String] = [
        "bench press": "Barbell_Bench_Press_-_Medium_Grip",
        "barbell bench press": "Barbell_Bench_Press_-_Medium_Grip",
        "flat bench press": "Barbell_Bench_Press_-_Medium_Grip",
        "bench": "Barbell_Bench_Press_-_Medium_Grip",
        "squat": "Barbell_Squat",
        "back squat": "Barbell_Squat",
        "barbell back squat": "Barbell_Squat",
        "deadlift": "Barbell_Deadlift",
        "conventional deadlift": "Barbell_Deadlift",
        "overhead press": "Standing_Military_Press",
        "barbell overhead press": "Standing_Military_Press",
        "military press": "Standing_Military_Press",
        "strict press": "Standing_Military_Press",
        "standing press": "Standing_Military_Press",
        "ohp": "Standing_Military_Press",
        "barbell row": "Bent_Over_Barbell_Row",
        "bent over row": "Bent_Over_Barbell_Row",
        "bent over barbell row": "Bent_Over_Barbell_Row",
        "pull up": "Pullups",
        "pullup": "Pullups",
        "weighted pull up": "Pullups",
        "chin up": "Chin-Up",
        "chinup": "Chin-Up",
        "romanian deadlift": "Romanian_Deadlift",
        "rdl": "Romanian_Deadlift",
        "dumbbell romanian deadlift": "Stiff-Legged_Dumbbell_Deadlift",
        "calf raise": "Standing_Calf_Raises",
        "standing calf raise": "Standing_Calf_Raises",
        "seated calf raise": "Seated_Calf_Raise",
        "dip": "Dips_-_Triceps_Version",
        "tricep dip": "Dips_-_Triceps_Version",
        "tricep dips": "Dips_-_Triceps_Version",
        "weighted dip": "Dips_-_Triceps_Version",
        "parallel bar dip": "Parallel_Bar_Dip",
        "lat pulldown": "Wide-Grip_Lat_Pulldown",
        "seated row": "Seated_Cable_Rows",
        "seated cable row": "Seated_Cable_Rows",
        "cable row": "Seated_Cable_Rows",
        "tricep pushdown": "Triceps_Pushdown",
        "lateral raise": "Side_Lateral_Raise",
        "side lateral raise": "Side_Lateral_Raise",
        "dumbbell lateral raise": "Side_Lateral_Raise",
        "front raise": "Front_Dumbbell_Raise",
        "rear delt fly": "Reverse_Flyes",
        "rear delt flye": "Reverse_Flyes",
        "reverse fly": "Reverse_Flyes",
        "cable flye": "Cable_Crossover",
        "cable fly": "Cable_Crossover",
        "chest flye": "Dumbbell_Flyes",
        "chest fly": "Dumbbell_Flyes",
        "push up": "Pushups",
        "pushup": "Pushups",
        "incline push up": "Incline_Push-Up",
        "handstand push up": "Handstand_Push-Ups",
        "lunge": "Dumbbell_Lunges",
        "walking lunge": "Bodyweight_Walking_Lunge",
        "front squat": "Front_Squat_Clean_Grip",
        "incline bench press": "Barbell_Incline_Bench_Press_-_Medium_Grip",
        "incline bench": "Barbell_Incline_Bench_Press_-_Medium_Grip",
        "incline press": "Barbell_Incline_Bench_Press_-_Medium_Grip",
        "decline bench press": "Decline_Barbell_Bench_Press",
        "close grip bench press": "Close-Grip_Barbell_Bench_Press",
        "close grip bench": "Close-Grip_Barbell_Bench_Press",
        "leg curl": "Lying_Leg_Curls",
        "hip thrust": "Barbell_Hip_Thrust",
        "glute bridge": "Butt_Lift_Bridge",
        "bulgarian split squat": "Split_Squat_with_Dumbbells",
        "split squat": "Split_Squat_with_Dumbbells",
        "kettlebell swing": "One-Arm_Kettlebell_Swings",
        "box jump": "Front_Box_Jump",
        "jump squat": "Freehand_Jump_Squat",
        "jump rope": "Rope_Jumping",
        "hang clean": "Hang_Clean",
        "t bar row": "T-Bar_Row_with_Handle",
        "dumbbell row": "One-Arm_Dumbbell_Row",
        "bicep curl": "Dumbbell_Bicep_Curl",
        "biceps curl": "Dumbbell_Bicep_Curl",
        "dumbbell curl": "Dumbbell_Bicep_Curl",
        "cable curl": "Standing_Biceps_Cable_Curl",
        "skull crusher": "EZ-Bar_Skullcrusher",
        "tricep extension": "Dumbbell_One-Arm_Triceps_Extension",
        "overhead tricep extension": "Cable_Rope_Overhead_Triceps_Extension",
        "overhead extension": "Cable_Rope_Overhead_Triceps_Extension",
        "shrug": "Barbell_Shrug",
        "ab wheel": "Ab_Roller",
        "ab rollout": "Ab_Roller",
        "russian twist": "Russian_Twist",
        "mountain climber": "Mountain_Climbers",
        "leg raise": "Hanging_Leg_Raise",
        "step up": "Dumbbell_Step_Ups",
        "back extension": "Hyperextensions_Back_Extensions",
        "pec deck": "Butterfly",
        "battle rope": "Battling_Ropes",
        "sled push": "Sled_Push",
        "incline walk": "Walking_Treadmill",
        "trap bar deadlift": "Trap_Bar_Deadlift",
        "renegade row": "Alternating_Renegade_Row",
        "medicine ball slam": "One-Arm_Medicine_Ball_Slam",
        "farmer walk": "Farmers_Walk",
        "farmers walk": "Farmers_Walk",
        "farmer carry": "Farmers_Walk",
        "farmers carry": "Farmers_Walk",
        "inverted row": "Inverted_Row",
        "bodyweight row": "Inverted_Row",
        "dumbbell press": "Dumbbell_Bench_Press",
        "air squat": "Bodyweight_Squat",
        "side plank": "Side_Bridge",
        "crunch": "Crunches",
        "nordic curl": "Natural_Glute_Ham_Raise",
        "straight arm pulldown": "Straight-Arm_Pulldown",
    ]
}
