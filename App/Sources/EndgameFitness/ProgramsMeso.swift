//
//  ProgramsMeso.swift
//  Endgame Fitness
//
//  The Programs page (pre-made catalog + custom workout builder) and the
//  Mesocycle page (hand-editable phase builder + fixed phase templates).
//  The old AI features live in _archive/ai-features-2026-11-16/.
//

import SwiftUI

// MARK: - Mesocycle model

struct MesoPhase: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var weeks: Int
    var repRange: String
    var focus: String
    var emoji: String

    static let classic12Week: [MesoPhase] = [
        MesoPhase(name: "Hypertrophy", weeks: 4, repRange: "8-12",
                  focus: "Muscle growth with moderate weight and controlled tempo.", emoji: "💎"),
        MesoPhase(name: "Strength", weeks: 4, repRange: "3-5",
                  focus: "Heavy lifting for maximum strength on the main lifts.", emoji: "⚔️"),
        MesoPhase(name: "Endurance", weeks: 4, repRange: "15+",
                  focus: "High reps to build muscular endurance and recovery capacity.", emoji: "🏃"),
    ]

    enum TemplateGoal: String, CaseIterable, Identifiable {
        case muscle, strength, fatLoss, athletic, general, longevity
        var id: String { rawValue }
        var label: String {
            switch self {
            case .muscle: return "Muscle"
            case .strength: return "Strength"
            case .fatLoss: return "Fat loss"
            case .athletic: return "Athletic"
            case .general: return "General"
            case .longevity: return "Longevity"
            }
        }
    }

    /// Fixed phase recipes per goal. Each recipe's weights are shares of the
    /// cycle; weeks are split proportionally (min 1 each) and always sum to
    /// `weeks`. Deterministic, so the selftest can check it.
    static func template(goal: TemplateGoal, weeks: Int) -> [MesoPhase] {
        typealias R = (name: String, share: Int, reps: String, focus: String, emoji: String)
        let recipe: [R]
        switch goal {
        case .muscle:
            recipe = [("Accumulation", 2, "10-15", "Higher volume, moderate weight, controlled tempo.", "💎"),
                      ("Hypertrophy", 2, "8-12", "Add load each week while keeping reps clean.", "📈"),
                      ("Intensification", 1, "6-8", "Heavier sets to lift the ceiling for the next cycle.", "⚔️")]
        case .strength:
            recipe = [("Base", 1, "6-8", "Build work capacity on the main lifts.", "🧱"),
                      ("Strength", 2, "3-5", "Heavy compound lifts, long rests.", "⚔️"),
                      ("Peak", 1, "1-3", "Low volume, top singles and doubles.", "🏔️")]
        case .fatLoss:
            recipe = [("Circuit", 1, "12-15", "Short rests, full-body circuits.", "🔥"),
                      ("Strength Retention", 1, "6-8", "Keep the heavy lifts while in a calorie deficit.", "🛡️"),
                      ("Conditioning", 1, "15+", "Higher reps and extra conditioning work.", "🏃")]
        case .athletic:
            recipe = [("General Prep", 1, "8-12", "Movement quality and base strength.", "🧱"),
                      ("Strength", 1, "3-5", "Heavy compound lifts.", "⚔️"),
                      ("Power", 1, "3-5", "Fast, explosive reps and jumps.", "⚡")]
        case .general:
            recipe = MesoPhase.classic12Week.map { ($0.name, 1, $0.repRange, $0.focus, $0.emoji) }
        case .longevity:
            recipe = [("Foundation", 1, "10-15", "Joint-friendly volume and mobility.", "🌱"),
                      ("Strength", 1, "6-10", "Moderate-heavy lifts for bone and muscle health.", "💪"),
                      ("Capacity", 1, "12-20", "Endurance, balance and zone 2 work.", "🫀")]
        }
        let total = max(recipe.count, weeks)
        let shareSum = recipe.reduce(0) { $0 + $1.share }
        var split = recipe.map { max(1, total * $0.share / shareSum) }
        var i = 0
        while split.reduce(0, +) < total { split[i % split.count] += 1; i += 1 }
        while split.reduce(0, +) > total, let j = split.indices.last(where: { split[$0] > 1 }) { split[j] -= 1 }
        return zip(recipe, split).map {
            MesoPhase(name: $0.name, weeks: $1, repRange: $0.reps, focus: $0.focus, emoji: $0.emoji)
        }
    }
}

// MARK: - Schedule / program state persistence

extension WorkoutManager {
    var currentProgramLabel: String { currentProgramName ?? "your current program" }

    func saveScheduleState() {
        normalizeSchedule()
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(weeklySchedule) { d.set(data, forKey: "weeklySchedule.v1") }
        if let data = try? JSONEncoder().encode(mesoPhases) { d.set(data, forKey: "mesoPhases.v1") }
        d.set(currentProgramName, forKey: "currentProgramName.v1")
        if let profile = userProfile, let data = try? JSONEncoder().encode(profile) {
            d.set(data, forKey: "userProfile.v1")
        }
    }

    func loadScheduleState() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "weeklySchedule.v1"),
           let sched = try? JSONDecoder().decode([ScheduledWorkout].self, from: data),
           weeklySchedule.isEmpty {
            weeklySchedule = sched
        }
        if let data = d.data(forKey: "mesoPhases.v1"),
           let phases = try? JSONDecoder().decode([MesoPhase].self, from: data),
           !phases.isEmpty {
            mesoPhases = phases
        }
        currentProgramName = d.string(forKey: "currentProgramName.v1")
        if userProfile == nil, let data = d.data(forKey: "userProfile.v1"),
           let profile = try? JSONDecoder().decode(UserProfile.self, from: data) {
            userProfile = profile
        }
        normalizeSchedule()
    }

    /// Program generators still write names like "Bench Press 4x8". Split the
    /// scheme into structured targets so a started workout gets 4 planned
    /// sets of 8 instead of a name with numbers in it.
    func normalizeSchedule() {
        guard weeklySchedule.contains(where: { $0.plan?.map(\.name) != $0.exercises }) else { return }
        weeklySchedule = weeklySchedule.map { day in
            var day = day
            day.normalizePlan()
            return day
        }
    }

    func applyCatalogProgram(_ program: CatalogProgram, append: Bool) {
        // Catalog and custom programs are weekday-based.
        if !append { UserDefaults.standard.set(ScheduleMode.weekly.rawValue, forKey: "scheduleMode"); UserDefaults.standard.set(false, forKey: "rotationIndexed") }
        if append {
            weeklySchedule.append(contentsOf: program.days)
        } else {
            weeklySchedule = program.days
            currentProgramName = program.name
        }
        saveScheduleState()
        saveData()
        selectedTab = 1
    }

    /// Save edits to the program in place (keeps weekly/rolling mode).
    func updateCurrentProgram(name: String, days: [ScheduledWorkout]) {
        weeklySchedule = days
        currentProgramName = name.isEmpty ? "My Program" : name
        saveScheduleState()
        saveData()
    }

    /// Stop following a program. History and game progress are untouched.
    func dropCurrentProgram() {
        weeklySchedule = []
        currentProgramName = nil
        UserDefaults.standard.set(ScheduleMode.weekly.rawValue, forKey: "scheduleMode")
        UserDefaults.standard.set(false, forKey: "rotationIndexed")
        saveScheduleState()
        saveData()
    }

    func applyCustomProgram(name: String, days: [ScheduledWorkout], append: Bool) {
        // Catalog and custom programs are weekday-based.
        if !append { UserDefaults.standard.set(ScheduleMode.weekly.rawValue, forKey: "scheduleMode"); UserDefaults.standard.set(false, forKey: "rotationIndexed") }
        if append {
            weeklySchedule.append(contentsOf: days)
        } else {
            weeklySchedule = days
            currentProgramName = name.isEmpty ? "Custom Program" : name
        }
        saveScheduleState()
        saveData()
        selectedTab = 1
    }
}


struct CatalogProgram: Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let daysPerWeek: Int
    let difficulty: String
    let goal: String
    let icon: String
    let days: [ScheduledWorkout]
}

private func day(_ dow: String, _ type: String, _ ex: [String], _ min: Int = 60) -> ScheduledWorkout {
    ScheduledWorkout(dayOfWeek: dow, workoutType: type, exercises: ex, estimatedDuration: min)
}

extension CatalogProgram {
    /// Gives every exercise the program's default prescription, so starting a
    /// day plans real sets and reps. Timed moves (planks, walks, mobility) get
    /// a timed target instead; carries and sleds get a set count only.
    func prescribing(_ scheme: String) -> CatalogProgram {
        let planned = days.map { day -> ScheduledWorkout in
            var day = day
            day.plan = day.exercises.map { Self.plan(for: $0, scheme: scheme) }
            return day
        }
        return CatalogProgram(name: name, description: description, daysPerWeek: daysPerWeek,
                              difficulty: difficulty, goal: goal, icon: icon, days: planned)
    }

    static func plan(for name: String, scheme: String) -> PlannedExercise {
        let parsed = ProgramTargetParser.parse(name)
        if parsed.hasTarget { return parsed }
        let lower = name.lowercased()
        if ExerciseLibrary.shared.tracking(forID: nil, name: name) == .timed {
            let long = ["walk", "cardio", "flow", "zone", "run", "bike", "mobility"].contains { lower.contains($0) }
            return PlannedExercise(name: name, sets: long ? 1 : 3, seconds: long ? 600 : 30)
        }
        if ["carry", "farmer", "sled"].contains(where: { lower.contains($0) }) {
            return PlannedExercise(name: name, sets: 3)
        }
        var plan = ProgramTargetParser.parse("\(name) \(scheme)")
        plan.name = name
        return plan
    }
}

enum ProgramCatalog {
    static let all: [CatalogProgram] = [
        CatalogProgram(name: "Push-Pull-Legs", description: "Classic 3-day split focusing on push, pull, and leg movements", daysPerWeek: 3, difficulty: "Intermediate", goal: "Muscle Building", icon: "💪", days: [
            day("Monday", "Push Day", ["Bench Press", "Overhead Press", "Incline Dumbbell Press", "Tricep Dips"]),
            day("Wednesday", "Pull Day", ["Deadlift", "Pull-ups", "Barbell Rows", "Face Pulls"]),
            day("Friday", "Leg Day", ["Squats", "Romanian Deadlifts", "Leg Press", "Calf Raises"]),
        ]).prescribing("3x8-12"),
        CatalogProgram(name: "PPL x6", description: "6-day push/pull/legs for maximum weekly volume", daysPerWeek: 6, difficulty: "Advanced", goal: "Muscle Building", icon: "🔱", days: [
            day("Monday", "Push A", ["Bench Press", "Overhead Press", "Cable Flyes", "Tricep Pushdowns"]),
            day("Tuesday", "Pull A", ["Deadlift", "Pull-ups", "Seated Rows", "Barbell Curls"]),
            day("Wednesday", "Legs A", ["Squats", "Leg Press", "Leg Curls", "Calf Raises"]),
            day("Thursday", "Push B", ["Incline Bench Press", "Dumbbell Shoulder Press", "Lateral Raises", "Overhead Tricep Extension"]),
            day("Friday", "Pull B", ["Barbell Rows", "Lat Pulldowns", "Face Pulls", "Hammer Curls"]),
            day("Saturday", "Legs B", ["Front Squats", "Romanian Deadlifts", "Walking Lunges", "Seated Calf Raises"]),
        ]).prescribing("3x8-12"),
        CatalogProgram(name: "Upper-Lower Split", description: "4-day program alternating between upper and lower body", daysPerWeek: 4, difficulty: "Intermediate", goal: "Strength & Size", icon: "⚡", days: [
            day("Monday", "Upper Body", ["Bench Press", "Barbell Rows", "Overhead Press", "Pull-ups"]),
            day("Tuesday", "Lower Body", ["Squats", "Romanian Deadlifts", "Leg Press", "Leg Curls"]),
            day("Thursday", "Upper Body", ["Incline Dumbbell Press", "Seated Rows", "Lateral Raises", "Barbell Curls"]),
            day("Friday", "Lower Body", ["Deadlift", "Front Squats", "Walking Lunges", "Calf Raises"]),
        ]).prescribing("3x6-10"),
        CatalogProgram(name: "Full Body 3x", description: "Train your entire body 3 times per week", daysPerWeek: 3, difficulty: "Beginner", goal: "General Fitness", icon: "🏋️", days: [
            day("Monday", "Full Body A", ["Squats", "Bench Press", "Barbell Rows", "Plank"]),
            day("Wednesday", "Full Body B", ["Deadlift", "Overhead Press", "Pull-ups", "Lunges"]),
            day("Friday", "Full Body C", ["Leg Press", "Incline Dumbbell Press", "Seated Rows", "Farmer's Carry"]),
        ]).prescribing("3x8-12"),
        CatalogProgram(name: "Starting Strength", description: "The classic barbell novice program: squat every session", daysPerWeek: 3, difficulty: "Beginner", goal: "Strength", icon: "🐣", days: [
            day("Monday", "Workout A", ["Squats", "Bench Press", "Deadlift"], 45),
            day("Wednesday", "Workout B", ["Squats", "Overhead Press", "Power Cleans"], 45),
            day("Friday", "Workout A", ["Squats", "Bench Press", "Deadlift"], 45),
        ]).prescribing("3x5"),
        CatalogProgram(name: "5x5 Strength", description: "Five sets of five on the big compound lifts", daysPerWeek: 3, difficulty: "Intermediate", goal: "Strength", icon: "🖐️", days: [
            day("Monday", "Heavy Day", ["Squats", "Bench Press", "Barbell Rows"], 60),
            day("Wednesday", "Volume Day", ["Squats", "Overhead Press", "Deadlift"], 60),
            day("Friday", "Intensity Day", ["Squats", "Bench Press", "Barbell Rows"], 60),
        ]).prescribing("5x5"),
        CatalogProgram(name: "Powerlifting Peaking", description: "Squat, bench, deadlift focus with heavy triples and doubles", daysPerWeek: 4, difficulty: "Advanced", goal: "Strength", icon: "🐘", days: [
            day("Monday", "Squat Day", ["Squats", "Pause Squats", "Leg Press", "Ab Wheel"], 75),
            day("Tuesday", "Bench Day", ["Bench Press", "Close-Grip Bench Press", "Dumbbell Rows", "Tricep Pushdowns"], 75),
            day("Thursday", "Deadlift Day", ["Deadlift", "Deficit Deadlifts", "Barbell Rows", "Back Extensions"], 75),
            day("Saturday", "Accessory Day", ["Incline Bench Press", "Pull-ups", "Lateral Raises", "Barbell Curls"], 60),
        ]).prescribing("4x3"),
        CatalogProgram(name: "Bodybuilding Bro Split", description: "One muscle group per day, maximum pump", daysPerWeek: 5, difficulty: "Intermediate", goal: "Muscle Building", icon: "🏆", days: [
            day("Monday", "Chest Day", ["Bench Press", "Incline Dumbbell Press", "Cable Flyes", "Push-ups"]),
            day("Tuesday", "Back Day", ["Deadlift", "Lat Pulldowns", "Seated Rows", "Face Pulls"]),
            day("Wednesday", "Shoulder Day", ["Overhead Press", "Lateral Raises", "Rear Delt Flyes", "Shrugs"]),
            day("Thursday", "Leg Day", ["Squats", "Leg Press", "Leg Curls", "Calf Raises"]),
            day("Friday", "Arm Day", ["Barbell Curls", "Tricep Dips", "Hammer Curls", "Overhead Tricep Extension"]),
        ]).prescribing("4x8-12"),
        CatalogProgram(name: "Circuit Training", description: "High-intensity circuits for fat loss and conditioning", daysPerWeek: 3, difficulty: "Beginner", goal: "Fat Loss", icon: "🔥", days: [
            day("Monday", "Full Body Circuit", ["Squats", "Push-ups", "Lunges", "Rows"], 45),
            day("Wednesday", "HIIT Cardio", ["Burpees", "Mountain Climbers", "Jump Squats", "Plank"], 30),
            day("Friday", "Full Body Circuit", ["Deadlifts", "Bench Press", "Pull-ups", "Leg Press"], 45),
        ]).prescribing("3x12-15"),
        CatalogProgram(name: "Fat Loss Shred", description: "Lifting plus metabolic finishers, 4 days", daysPerWeek: 4, difficulty: "Intermediate", goal: "Fat Loss", icon: "🥵", days: [
            day("Monday", "Upper + Finisher", ["Bench Press", "Barbell Rows", "Overhead Press", "Battle Ropes"], 50),
            day("Tuesday", "Lower + Finisher", ["Squats", "Romanian Deadlifts", "Walking Lunges", "Sled Push"], 50),
            day("Thursday", "Upper + Finisher", ["Incline Dumbbell Press", "Pull-ups", "Lateral Raises", "Burpees"], 50),
            day("Friday", "Lower + Finisher", ["Deadlift", "Leg Press", "Jump Squats", "Mountain Climbers"], 50),
        ]).prescribing("3x10-15"),
        CatalogProgram(name: "Athlete Performance", description: "Power, speed, and strength for sport", daysPerWeek: 4, difficulty: "Advanced", goal: "Athleticism", icon: "🥇", days: [
            day("Monday", "Power Lower", ["Power Cleans", "Box Jumps", "Squats", "Nordic Curls"], 60),
            day("Tuesday", "Power Upper", ["Push Press", "Medicine Ball Throws", "Weighted Pull-ups", "Plank"], 60),
            day("Thursday", "Strength Lower", ["Deadlift", "Front Squats", "Walking Lunges", "Calf Raises"], 60),
            day("Friday", "Strength Upper", ["Bench Press", "Barbell Rows", "Overhead Press", "Face Pulls"], 60),
        ]).prescribing("4x4-6"),
        CatalogProgram(name: "Olympic Lifting", description: "Snatch and clean & jerk technique plus strength", daysPerWeek: 4, difficulty: "Advanced", goal: "Power", icon: "🏋️‍♀️", days: [
            day("Monday", "Snatch Day", ["Snatch", "Overhead Squats", "Snatch Pulls", "Core Work"], 75),
            day("Tuesday", "Clean & Jerk Day", ["Clean and Jerk", "Front Squats", "Push Press", "Pull-ups"], 75),
            day("Thursday", "Strength Day", ["Squats", "Deadlift", "Strict Press", "Barbell Rows"], 75),
            day("Saturday", "Technique Day", ["Hang Snatch", "Hang Cleans", "Jerk Dips", "Ab Wheel"], 60),
        ]).prescribing("5x3"),
        CatalogProgram(name: "Calisthenics Foundations", description: "Bodyweight-only strength you can do anywhere", daysPerWeek: 3, difficulty: "Beginner", goal: "General Fitness", icon: "🤸", days: [
            day("Monday", "Push", ["Push-ups", "Pike Push-ups", "Dips", "Plank"], 40),
            day("Wednesday", "Pull", ["Pull-ups", "Inverted Rows", "Chin-ups", "Hollow Hold"], 40),
            day("Friday", "Legs & Core", ["Pistol Squat Progressions", "Walking Lunges", "Glute Bridges", "Hanging Leg Raises"], 40),
        ]).prescribing("3x6-12"),
        CatalogProgram(name: "Longevity & Mobility", description: "Joint-friendly strength, balance, and mobility for the long game", daysPerWeek: 3, difficulty: "Beginner", goal: "Longevity", icon: "🛡️", days: [
            day("Monday", "Strength + Balance", ["Goblet Squats", "Dumbbell Press", "Single-Leg Romanian Deadlifts", "Farmer's Carry"], 45),
            day("Wednesday", "Zone 2 + Core", ["Incline Walk", "Dead Bug", "Bird Dog", "Side Plank"], 45),
            day("Friday", "Full Body + Mobility", ["Trap Bar Deadlift", "Seated Rows", "Step-ups", "Mobility Flow"], 45),
        ]).prescribing("3x8-12"),
        CatalogProgram(name: "Time-Crunched 2x", description: "Two efficient full-body sessions a week", daysPerWeek: 2, difficulty: "Beginner", goal: "General Fitness", icon: "⏱️", days: [
            day("Tuesday", "Full Body A", ["Squats", "Bench Press", "Barbell Rows", "Plank"], 40),
            day("Saturday", "Full Body B", ["Deadlift", "Overhead Press", "Pull-ups", "Walking Lunges"], 40),
        ]).prescribing("3x6-10"),
        CatalogProgram(name: "Home Dumbbell Only", description: "Complete program with just a pair of dumbbells", daysPerWeek: 3, difficulty: "Beginner", goal: "Muscle Building", icon: "🏠", days: [
            day("Monday", "Upper", ["Dumbbell Bench Press", "Dumbbell Rows", "Dumbbell Shoulder Press", "Hammer Curls"], 45),
            day("Wednesday", "Lower", ["Goblet Squats", "Dumbbell Romanian Deadlifts", "Walking Lunges", "Calf Raises"], 45),
            day("Friday", "Full Body", ["Dumbbell Thrusters", "Renegade Rows", "Split Squats", "Overhead Tricep Extension"], 45),
        ]).prescribing("3x10-15"),
    ]
}

// MARK: - Programs View

struct ProgramsView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var showProgramConfirmation = false
    @State private var pendingProgram: CatalogProgram?
    @State private var showQuickBuilder = false
    @State private var showCustomBuilder = false
    @State private var showEditProgram = false
    @State private var showWizard = false
    @State private var confirmDrop = false

    private var hasActiveProgram: Bool { !workoutManager.weeklySchedule.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose Your Program")
                    .font(.screenTitle)
                    .bold()

                if hasActiveProgram {
                    currentProgramBanner
                }

                actionButtons
                ModulatorSection()
                catalogSection
            }
            .padding()
        }
        .alert("Quit \(workoutManager.currentProgramLabel)?", isPresented: $showProgramConfirmation, presenting: pendingProgram) { program in
            Button("Replace With \(program.name)", role: .destructive) {
                workoutManager.applyCatalogProgram(program, append: false)
            }
            Button("Append to Current Program") {
                workoutManager.applyCatalogProgram(program, append: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: { program in
            Text("Are you sure you want to quit your current program? Replace overwrites your schedule with \(program.name). Append adds its workouts after your current program.")
        }
        .sheet(isPresented: $showQuickBuilder) {
            QuickProgramQuestionnaireView()
                .environmentObject(workoutManager)
        }
        .sheet(isPresented: $showCustomBuilder) {
            CustomWorkoutBuilderView()
                .environmentObject(workoutManager)
        }
        .sheet(isPresented: $showEditProgram) {
            CustomWorkoutBuilderView(editingCurrent: true)
                .environmentObject(workoutManager)
        }
        .sheet(isPresented: $showWizard) {
            ProgramWizardView()
                .environmentObject(workoutManager)
        }
        .confirmationDialog("Drop \(workoutManager.currentProgramLabel)?", isPresented: $confirmDrop) {
            Button("Drop Program", role: .destructive) { workoutManager.dropCurrentProgram() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your schedule is cleared. Logged workouts, PRs and game progress are kept.")
        }
    }

    private var currentProgramBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundColor(.brandGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text("Current Program: \(workoutManager.currentProgramName ?? "Custom Schedule")")
                    .font(.headline)
                Text("\(workoutManager.weeklySchedule.count) workouts. Edit it, rebuild it, drop it, or pick another program below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button { showEditProgram = true } label: { Label("Edit Program", systemImage: "pencil") }
                    Button { showWizard = true } label: { Label("Rebuild", systemImage: "wand.and.stars") }
                    Button(role: .destructive) { confirmDrop = true } label: { Label("Drop", systemImage: "trash") }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding()
        .background(Color.brandGreen.opacity(0.1))
        .cornerRadius(12)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: { showWizard = true }) {
                bigActionLabel(icon: "wand.and.stars", iconColor: .white,
                               title: "Build Your Program",
                               subtitle: "Guided setup: days, session length, goal, split and progression",
                               colors: [.brandBlue, .brandGreen])
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button(action: { showQuickBuilder = true }) {
                bigActionLabel(icon: "list.bullet.clipboard", iconColor: .white,
                               title: "Quick Program Builder",
                               subtitle: "Answer three questions and get a ready-made weekly plan",
                               colors: [.brandPurple, .brandBlue])
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button(action: { showCustomBuilder = true }) {
                bigActionLabel(icon: "square.and.pencil", iconColor: .white,
                               title: "Create Your Own Workout",
                               subtitle: "Build your week from scratch, day by day",
                               colors: [.brandOrange, .brandPurple])
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    private func bigActionLabel(icon: String, iconColor: Color, title: String, subtitle: String, colors: [Color]) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
            }
            Spacer()
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(.white)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        .cornerRadius(16)
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 8)
            Text("Pre-Built Programs")
                .font(.title2)
                .bold()
            Text("\(ProgramCatalog.all.count) programs — pick one that matches your goals")
                .font(.subheadline)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20)], spacing: 20) {
                ForEach(ProgramCatalog.all) { program in
                    CatalogProgramCard(
                        program: program,
                        isCurrent: workoutManager.currentProgramName == program.name
                    ) {
                        if workoutManager.weeklySchedule.isEmpty {
                            workoutManager.applyCatalogProgram(program, append: false)
                        } else {
                            pendingProgram = program
                            showProgramConfirmation = true
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

struct CatalogProgramCard: View {
    let program: CatalogProgram
    let isCurrent: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(program.icon).font(.system(size: 34))
                    Spacer()
                    if isCurrent {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.bold())
                            .foregroundColor(.brandGreen)
                    }
                }
                Text(program.name)
                    .font(.headline)
                Text(program.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    tag("\(program.daysPerWeek)x/week", .brandBlue)
                    tag(program.difficulty, .brandOrange)
                    tag(program.goal, .brandPurple)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isCurrent ? Color.brandGreen : Color.clear, lineWidth: 2)
            )
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

// MARK: - Modulator section (sliders + presets)

struct ModulatorSection: View {
    @EnvironmentObject var workoutManager: WorkoutManager

    private static let presets: [(title: String, subtitle: String, icon: String, preset: String)] = [
        ("Optimal", "Balanced approach", "⚖️", "optimal"),
        ("Time Crunched", "Short, intense sessions", "⏱️", "time_crunched"),
        ("Weekend Warrior", "Infrequent, long sessions", "🏔️", "weekend_warrior"),
        ("Longevity", "Safety-focused, recovery", "🛡️", "longevity"),
        ("Strength", "Heavy lifting, low reps", "💪", "strength"),
        ("Weight Lifter", "Olympic-style training", "🏋️", "weight_lifter"),
        ("Powerlifting", "Main lifts focus", "🐘", "powerlifting"),
        ("Power Building", "Hybrid strength/speed", "⚡", "power_building"),
        ("Bodybuilding", "High volume hypertrophy", "🏆", "bodybuilding"),
        ("Functional Fitness", "Multi-joint movements", "🤸", "functional_fitness"),
        ("Bodybuilder MAX", "Precautions thrown out", "🔥", "bodybuilder"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("🎛️ Workout Modulator")
                .font(.title2)
                .bold()
            Text("Fine-tune your training approach")
                .font(.caption)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 16) {
                modSlider(value: $workoutManager.repRangeModulation, icon: "repeat", color: .brandBlue,
                          title: "Rep Range (Safe to Maximal)", low: "Safer", high: "Maximal")
                modSlider(value: $workoutManager.volumeIntensityModulation, icon: "chart.bar.fill", color: .brandGreen,
                          title: "Volume vs Intensity", low: "Volume", high: "Intensity")
                modSlider(value: $workoutManager.frequencyModulation, icon: "calendar.badge.clock", color: .brandOrange,
                          title: "Training Frequency", low: "Often", high: "Sparingly")
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("🎯 Bodybuilder Mini")
                    .font(.subheadline)
                    .bold()
                Toggle("Add intense hypertrophy exercises to any program", isOn: $workoutManager.bodybuilderMiniActive)
                    .toggleStyle(.switch)
                    .tint(.brandOrange)
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 16) {
                Text("🎯 Training Presets")
                    .font(.title2)
                    .bold()
                Text("Choose your training style to auto-adjust modulation settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                    ForEach(Self.presets, id: \.preset) { p in
                        PresetButton(title: p.title, subtitle: p.subtitle, icon: p.icon,
                                     preset: p.preset, workoutManager: workoutManager)
                    }
                }
            }
            .padding()
            .background(Color.brandPurple.opacity(0.1))
            .cornerRadius(12)
        }
    }

    private func modSlider(value: Binding<Double>, icon: String, color: Color, title: String, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundColor(color)
                Text(title).font(.subheadline).bold()
            }
            VStack {
                Slider(value: value, in: 0...100, step: 5).tint(color)
                HStack {
                    Text(low).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(value.wrappedValue))%").font(.headline)
                    Spacer()
                    Text(high).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Custom workout builder

private struct DraftDay: Identifiable {
    let id = UUID()
    /// Set when editing the current program, so unchanged days keep their
    /// id and smart-coach prescriptions.
    var original: ScheduledWorkout? = nil
    var dayOfWeek = "Monday"
    var name = ""
    var minutes = 60
    var exercises: [String] = []
    var newExercise = ""
}

struct CustomWorkoutBuilderView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @Environment(\.dismiss) var dismiss

    /// true = edit the program you're on (prefilled, saves in place).
    var editingCurrent = false

    @State private var programName = "My Custom Program"
    @State private var days: [DraftDay] = [DraftDay()]
    @State private var showQuitConfirmation = false
    @State private var loaded = false

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let quickPicks = ["Squats", "Bench Press", "Deadlift", "Overhead Press", "Pull-ups",
                                     "Barbell Rows", "Lunges", "Leg Press", "Bicep Curls", "Tricep Dips",
                                     "Plank", "Lateral Raises", "Romanian Deadlifts", "Calf Raises", "Push-ups"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(editingCurrent ? "Edit Your Program" : "Create Your Own Workout")
                        .font(.screenTitle)
                        .bold()
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                }

                TextField("Program name", text: $programName)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)

                ForEach($days) { $day in
                    dayEditor($day)
                }

                HStack {
                    Button {
                        days.append(DraftDay())
                    } label: {
                        Label("Add Day", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.bordered)

                    if days.count > 1 {
                        Button(role: .destructive) {
                            days.removeLast()
                        } label: {
                            Label("Remove Last Day", systemImage: "minus.circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }


                Button {
                    if editingCurrent {
                        workoutManager.updateCurrentProgram(name: programName, days: draftedDays())
                        dismiss()
                    } else if workoutManager.weeklySchedule.isEmpty {
                        save(append: false)
                    } else {
                        showQuitConfirmation = true
                    }
                } label: {
                    Text(editingCurrent ? "Save Changes" : "Save Program")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandPurple)
                .disabled(!isValid)

                if !isValid {
                    Text("Give every day a name and at least one exercise.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: Platform.isDesktop ? 620 : nil,
               minHeight: Platform.isDesktop ? 640 : nil)
        .onAppear(perform: loadCurrentIfEditing)
        .alert("Quit \(workoutManager.currentProgramLabel)?", isPresented: $showQuitConfirmation) {
            Button("Replace With \(programName)", role: .destructive) { save(append: false) }
            Button("Append to Current Program") { save(append: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to quit your current program? Replace overwrites your schedule; Append adds these workouts after it.")
        }
    }

    private var isValid: Bool {
        !days.isEmpty && days.allSatisfy { !$0.name.isEmpty && !$0.exercises.isEmpty }
    }

    private func dayEditor(_ day: Binding<DraftDay>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Day", selection: day.dayOfWeek) {
                    ForEach(dayChoices(including: day.wrappedValue.dayOfWeek), id: \.self) { Text($0) }
                }
                .frame(maxWidth: 160)
                TextField("Workout name (e.g. Push Day)", text: day.name)
                    .textFieldStyle(.roundedBorder)
            }
            SessionLengthPicker(minutes: day.minutes)

            if !day.wrappedValue.exercises.isEmpty {
                ForEach(day.wrappedValue.exercises.indices, id: \.self) { i in
                    HStack {
                        Text("• \(day.wrappedValue.exercises[i])")
                        Spacer()
                        Button {
                            day.wrappedValue.exercises.remove(at: i)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                TextField("Add exercise", text: day.newExercise)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addExercise(day) }
                Button("Add") { addExercise(day) }
                    .buttonStyle(.bordered)
                    .disabled(day.wrappedValue.newExercise.isEmpty)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.quickPicks.filter { !day.wrappedValue.exercises.contains($0) }, id: \.self) { pick in
                        Button(pick) {
                            day.wrappedValue.exercises.append(pick)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .cornerRadius(12)
    }

    private func addExercise(_ day: Binding<DraftDay>) {
        let name = day.wrappedValue.newExercise.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        day.wrappedValue.exercises.append(name)
        day.wrappedValue.newExercise = ""
    }

    private func draftedDays() -> [ScheduledWorkout] {
        days.map { d in
            var w = d.original ?? ScheduledWorkout(dayOfWeek: d.dayOfWeek, workoutType: d.name,
                                                   exercises: d.exercises, estimatedDuration: d.minutes)
            // Prescriptions only stay valid if the exercise list is unchanged.
            if w.exercises != d.exercises { w.plan = nil }
            w.dayOfWeek = d.dayOfWeek
            w.workoutType = d.name
            w.exercises = d.exercises
            w.estimatedDuration = d.minutes
            return w
        }
    }

    /// Weekdays, plus "Day N" labels for rolling (days on / off) programs.
    private func dayChoices(including current: String) -> [String] {
        var list = Self.weekdays
        let rolling = workoutManager.weeklySchedule.map(\.dayOfWeek).filter { !Self.weekdays.contains($0) }
        for d in rolling + [current] where !list.contains(d) && !d.isEmpty { list.append(d) }
        return list
    }

    private func loadCurrentIfEditing() {
        guard editingCurrent, !loaded else { return }
        loaded = true
        programName = workoutManager.currentProgramName ?? "My Program"
        let current = workoutManager.weeklySchedule
        if !current.isEmpty {
            days = current.map {
                DraftDay(original: $0, dayOfWeek: $0.dayOfWeek, name: $0.workoutType,
                         minutes: min(120, max(15, $0.estimatedDuration)),
                         exercises: $0.plannedExercises.map(\.name))
            }
        }
    }

    private func save(append: Bool) {
        workoutManager.applyCustomProgram(name: programName, days: draftedDays(), append: append)
        dismiss()
    }
}

// MARK: - Mesocycle View

struct MesocycleView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var templateGoal: MesoPhase.TemplateGoal = .muscle
    @State private var templateWeeks = 12
    @State private var editingPhase: MesoPhase?

    private var totalWeeks: Int { workoutManager.mesoPhases.reduce(0) { $0 + $1.weeks } }

    private var progress: (workout: Int, total: Int, phase: String) {
        let workoutsPerWeek = max(1, workoutManager.weeklySchedule.count)
        let total = max(1, totalWeeks * workoutsPerWeek)
        let current = workoutManager.loggedSessions.count % total
        let currentWeek = current / workoutsPerWeek
        var week = 0
        for phase in workoutManager.mesoPhases {
            week += phase.weeks
            if currentWeek < week { return (current, total, phase.name) }
        }
        return (current, total, workoutManager.mesoPhases.last?.name ?? "Training")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Mesocycle Training")
                    .font(.screenTitle)
                    .bold()

                // Current phase + progress
                VStack(alignment: .leading, spacing: 16) {
                    Text("Current Phase: \(progress.phase)")
                        .font(.title2)
                        .bold()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.gray.opacity(0.3))
                            Rectangle()
                                .fill(Color.brandBlue)
                                .frame(width: geo.size.width * CGFloat(progress.workout) / CGFloat(progress.total))
                        }
                        .cornerRadius(4)
                    }
                    .frame(height: 8)
                    Text("Workout \(progress.workout) of \(progress.total) — \(totalWeeks)-week cycle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.05))
                .cornerRadius(12)

                // Phase templates (fixed recipes, scaled to the cycle length you pick)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Start From a Template")
                        .font(.headline)
                    Text("Pick a goal and cycle length. You can edit every phase afterwards.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Goal", selection: $templateGoal) {
                        ForEach(MesoPhase.TemplateGoal.allCases) { Text($0.label).tag($0) }
                    }
                    .compactSegmentedPicker()
                    HStack {
                        Stepper("Cycle length: \(templateWeeks) weeks", value: $templateWeeks, in: 4...24, step: 2)
                        Spacer()
                        Button("Use Template") {
                            workoutManager.mesoPhases = MesoPhase.template(goal: templateGoal, weeks: templateWeeks)
                            workoutManager.saveScheduleState()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brandPurple)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.05))
                .cornerRadius(12)
                // Editable phases
                HStack {
                    Text("Your Phases")
                        .font(.headline)
                    Spacer()
                    Button {
                        workoutManager.mesoPhases.append(
                            MesoPhase(name: "New Phase", weeks: 4, repRange: "8-12",
                                      focus: "Describe the focus of this phase.", emoji: "📈"))
                        workoutManager.saveScheduleState()
                    } label: {
                        Label("Add Phase", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    Button("Reset to Classic 12-Week") {
                        workoutManager.mesoPhases = MesoPhase.classic12Week
                        workoutManager.saveScheduleState()
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(workoutManager.mesoPhases) { phase in
                    phaseRow(phase)
                }
            }
            .padding()
        }
        .sheet(item: $editingPhase) { phase in
            MesoPhaseEditor(phase: phase) { updated in
                if let i = workoutManager.mesoPhases.firstIndex(where: { $0.id == updated.id }) {
                    workoutManager.mesoPhases[i] = updated
                    workoutManager.saveScheduleState()
                }
            }
        }
    }

    private func phaseRow(_ phase: MesoPhase) -> some View {
        HStack(spacing: 16) {
            Text(phase.emoji).font(.system(size: 36))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(phase.name) — \(phase.weeks) week\(phase.weeks == 1 ? "" : "s"), \(phase.repRange) reps")
                    .font(.headline)
                Text(phase.focus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            let index = workoutManager.mesoPhases.firstIndex(where: { $0.id == phase.id }) ?? 0
            VStack(spacing: 4) {
                Button {
                    guard index > 0 else { return }
                    workoutManager.mesoPhases.swapAt(index, index - 1)
                    workoutManager.saveScheduleState()
                } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                Button {
                    guard index < workoutManager.mesoPhases.count - 1 else { return }
                    workoutManager.mesoPhases.swapAt(index, index + 1)
                    workoutManager.saveScheduleState()
                } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .disabled(index == workoutManager.mesoPhases.count - 1)
            }
            Button("Edit") { editingPhase = phase }
                .buttonStyle(.bordered)
            Button(role: .destructive) {
                workoutManager.mesoPhases.removeAll { $0.id == phase.id }
                workoutManager.saveScheduleState()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(workoutManager.mesoPhases.count == 1)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandBlue.opacity(0.08))
        .cornerRadius(12)
    }
}

struct MesoPhaseEditor: View {
    @State var phase: MesoPhase
    let onSave: (MesoPhase) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit Phase")
                .font(.title.bold())
            TextField("Phase name", text: $phase.name)
                .textFieldStyle(.roundedBorder)
            Stepper("Length: \(phase.weeks) week\(phase.weeks == 1 ? "" : "s")", value: $phase.weeks, in: 1...16)
            TextField("Rep range (e.g. 8-12)", text: $phase.repRange)
                .textFieldStyle(.roundedBorder)
            TextField("Emoji", text: $phase.emoji)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100)
            TextField("Focus", text: $phase.focus, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    onSave(phase)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(phase.name.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: Platform.isDesktop ? 420 : nil)
    }
}
