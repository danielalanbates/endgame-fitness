//
//  ProgramsMeso.swift
//  Endgame Fitness
//
//  The Programs page (pre-made catalog + custom workout builder) and the
//  Mesocycle page (hand-editable phase builder + AI builder). AI calls go
//  through the batesai.org backend (`POST /api/fitness/ai`), which holds the
//  Cerebras key server-side — no AI key ever ships in the app.
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
}

// MARK: - Schedule / program state persistence

extension WorkoutManager {
    var currentProgramLabel: String { currentProgramName ?? "your current program" }

    func saveScheduleState() {
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
    }

    func applyCatalogProgram(_ program: CatalogProgram, append: Bool) {
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

    func applyCustomProgram(name: String, days: [ScheduledWorkout], append: Bool) {
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

// MARK: - AI service

@MainActor
enum FitnessAI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct AIResponse: Decodable { let text: String }

    static func complete(task: String, payload: [String: Any]) async throws -> String {
        var body = payload
        body["task"] = task
        let auth = BatesAIAuth.shared
        guard auth.isSignedIn else {
            throw Failure(message: "Sign in to use AI features.")
        }
        let data = try await auth.requestRaw("fitness/ai", method: "POST", token: auth.token, body: body)
        guard let decoded = try? JSONDecoder().decode(AIResponse.self, from: data) else {
            throw Failure(message: "Unexpected AI response.")
        }
        return decoded.text
    }

    static func improveWorkout(days: [ScheduledWorkout], profile: UserProfile?) async throws -> String {
        let workout = days.map { day -> [String: Any] in
            ["day": day.dayOfWeek, "name": day.workoutType,
             "exercises": day.exercises, "minutes": day.estimatedDuration]
        }
        var payload: [String: Any] = ["workout": workout]
        if let p = profile {
            payload["profile"] = ["experience": p.experienceLevel.rawValue,
                                  "goals": p.primaryGoals.map(\.rawValue)]
        }
        return try await complete(task: "improve_workout", payload: payload)
    }

    static func buildMesocycle(goal: String, experience: String, weeks: Int, notes: String) async throws -> [MesoPhase] {
        let text = try await complete(task: "build_mesocycle", payload: [
            "goal": goal, "experience": experience, "weeks": weeks, "notes": notes,
        ])
        // The model is instructed to return a bare JSON array; tolerate prose
        // around it by slicing to the outermost brackets.
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"),
              start < end else {
            throw Failure(message: "AI did not return a plan. Try again.")
        }
        let jsonText = String(text[start...end])
        struct RawPhase: Decodable {
            let name: String; let weeks: Int; let repRange: String?
            let focus: String?; let emoji: String?
        }
        guard let raw = try? JSONDecoder().decode([RawPhase].self, from: Data(jsonText.utf8)),
              !raw.isEmpty else {
            throw Failure(message: "Could not read the AI plan. Try again.")
        }
        return raw.map {
            MesoPhase(name: $0.name, weeks: max(1, $0.weeks),
                      repRange: $0.repRange ?? "8-12",
                      focus: $0.focus ?? "", emoji: $0.emoji ?? "📈")
        }
    }
}

// MARK: - Program catalog

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

enum ProgramCatalog {
    static let all: [CatalogProgram] = [
        CatalogProgram(name: "Push-Pull-Legs", description: "Classic 3-day split focusing on push, pull, and leg movements", daysPerWeek: 3, difficulty: "Intermediate", goal: "Muscle Building", icon: "💪", days: [
            day("Monday", "Push Day", ["Bench Press", "Overhead Press", "Incline Dumbbell Press", "Tricep Dips"]),
            day("Wednesday", "Pull Day", ["Deadlift", "Pull-ups", "Barbell Rows", "Face Pulls"]),
            day("Friday", "Leg Day", ["Squats", "Romanian Deadlifts", "Leg Press", "Calf Raises"]),
        ]),
        CatalogProgram(name: "PPL x6", description: "6-day push/pull/legs for maximum weekly volume", daysPerWeek: 6, difficulty: "Advanced", goal: "Muscle Building", icon: "🔱", days: [
            day("Monday", "Push A", ["Bench Press", "Overhead Press", "Cable Flyes", "Tricep Pushdowns"]),
            day("Tuesday", "Pull A", ["Deadlift", "Pull-ups", "Seated Rows", "Barbell Curls"]),
            day("Wednesday", "Legs A", ["Squats", "Leg Press", "Leg Curls", "Calf Raises"]),
            day("Thursday", "Push B", ["Incline Bench Press", "Dumbbell Shoulder Press", "Lateral Raises", "Overhead Tricep Extension"]),
            day("Friday", "Pull B", ["Barbell Rows", "Lat Pulldowns", "Face Pulls", "Hammer Curls"]),
            day("Saturday", "Legs B", ["Front Squats", "Romanian Deadlifts", "Walking Lunges", "Seated Calf Raises"]),
        ]),
        CatalogProgram(name: "Upper-Lower Split", description: "4-day program alternating between upper and lower body", daysPerWeek: 4, difficulty: "Intermediate", goal: "Strength & Size", icon: "⚡", days: [
            day("Monday", "Upper Body", ["Bench Press", "Barbell Rows", "Overhead Press", "Pull-ups"]),
            day("Tuesday", "Lower Body", ["Squats", "Romanian Deadlifts", "Leg Press", "Leg Curls"]),
            day("Thursday", "Upper Body", ["Incline Dumbbell Press", "Seated Rows", "Lateral Raises", "Barbell Curls"]),
            day("Friday", "Lower Body", ["Deadlift", "Front Squats", "Walking Lunges", "Calf Raises"]),
        ]),
        CatalogProgram(name: "Full Body 3x", description: "Train your entire body 3 times per week", daysPerWeek: 3, difficulty: "Beginner", goal: "General Fitness", icon: "🏋️", days: [
            day("Monday", "Full Body A", ["Squats", "Bench Press", "Barbell Rows", "Plank"]),
            day("Wednesday", "Full Body B", ["Deadlift", "Overhead Press", "Pull-ups", "Lunges"]),
            day("Friday", "Full Body C", ["Leg Press", "Incline Dumbbell Press", "Seated Rows", "Farmer's Carry"]),
        ]),
        CatalogProgram(name: "Starting Strength", description: "The classic barbell novice program: squat every session", daysPerWeek: 3, difficulty: "Beginner", goal: "Strength", icon: "🐣", days: [
            day("Monday", "Workout A", ["Squats", "Bench Press", "Deadlift"], 45),
            day("Wednesday", "Workout B", ["Squats", "Overhead Press", "Power Cleans"], 45),
            day("Friday", "Workout A", ["Squats", "Bench Press", "Deadlift"], 45),
        ]),
        CatalogProgram(name: "5x5 Strength", description: "Five sets of five on the big compound lifts", daysPerWeek: 3, difficulty: "Intermediate", goal: "Strength", icon: "🖐️", days: [
            day("Monday", "Heavy Day", ["Squats", "Bench Press", "Barbell Rows"], 60),
            day("Wednesday", "Volume Day", ["Squats", "Overhead Press", "Deadlift"], 60),
            day("Friday", "Intensity Day", ["Squats", "Bench Press", "Barbell Rows"], 60),
        ]),
        CatalogProgram(name: "Powerlifting Peaking", description: "Squat, bench, deadlift focus with heavy triples and doubles", daysPerWeek: 4, difficulty: "Advanced", goal: "Strength", icon: "🐘", days: [
            day("Monday", "Squat Day", ["Squats", "Pause Squats", "Leg Press", "Ab Wheel"], 75),
            day("Tuesday", "Bench Day", ["Bench Press", "Close-Grip Bench Press", "Dumbbell Rows", "Tricep Pushdowns"], 75),
            day("Thursday", "Deadlift Day", ["Deadlift", "Deficit Deadlifts", "Barbell Rows", "Back Extensions"], 75),
            day("Saturday", "Accessory Day", ["Incline Bench Press", "Pull-ups", "Lateral Raises", "Barbell Curls"], 60),
        ]),
        CatalogProgram(name: "Bodybuilding Bro Split", description: "One muscle group per day, maximum pump", daysPerWeek: 5, difficulty: "Intermediate", goal: "Muscle Building", icon: "🏆", days: [
            day("Monday", "Chest Day", ["Bench Press", "Incline Dumbbell Press", "Cable Flyes", "Push-ups"]),
            day("Tuesday", "Back Day", ["Deadlift", "Lat Pulldowns", "Seated Rows", "Face Pulls"]),
            day("Wednesday", "Shoulder Day", ["Overhead Press", "Lateral Raises", "Rear Delt Flyes", "Shrugs"]),
            day("Thursday", "Leg Day", ["Squats", "Leg Press", "Leg Curls", "Calf Raises"]),
            day("Friday", "Arm Day", ["Barbell Curls", "Tricep Dips", "Hammer Curls", "Overhead Tricep Extension"]),
        ]),
        CatalogProgram(name: "Circuit Training", description: "High-intensity circuits for fat loss and conditioning", daysPerWeek: 3, difficulty: "Beginner", goal: "Fat Loss", icon: "🔥", days: [
            day("Monday", "Full Body Circuit", ["Squats", "Push-ups", "Lunges", "Rows"], 45),
            day("Wednesday", "HIIT Cardio", ["Burpees", "Mountain Climbers", "Jump Squats", "Plank"], 30),
            day("Friday", "Full Body Circuit", ["Deadlifts", "Bench Press", "Pull-ups", "Leg Press"], 45),
        ]),
        CatalogProgram(name: "Fat Loss Shred", description: "Lifting plus metabolic finishers, 4 days", daysPerWeek: 4, difficulty: "Intermediate", goal: "Fat Loss", icon: "🥵", days: [
            day("Monday", "Upper + Finisher", ["Bench Press", "Barbell Rows", "Overhead Press", "Battle Ropes"], 50),
            day("Tuesday", "Lower + Finisher", ["Squats", "Romanian Deadlifts", "Walking Lunges", "Sled Push"], 50),
            day("Thursday", "Upper + Finisher", ["Incline Dumbbell Press", "Pull-ups", "Lateral Raises", "Burpees"], 50),
            day("Friday", "Lower + Finisher", ["Deadlift", "Leg Press", "Jump Squats", "Mountain Climbers"], 50),
        ]),
        CatalogProgram(name: "Athlete Performance", description: "Power, speed, and strength for sport", daysPerWeek: 4, difficulty: "Advanced", goal: "Athleticism", icon: "🥇", days: [
            day("Monday", "Power Lower", ["Power Cleans", "Box Jumps", "Squats", "Nordic Curls"], 60),
            day("Tuesday", "Power Upper", ["Push Press", "Medicine Ball Throws", "Weighted Pull-ups", "Plank"], 60),
            day("Thursday", "Strength Lower", ["Deadlift", "Front Squats", "Walking Lunges", "Calf Raises"], 60),
            day("Friday", "Strength Upper", ["Bench Press", "Barbell Rows", "Overhead Press", "Face Pulls"], 60),
        ]),
        CatalogProgram(name: "Olympic Lifting", description: "Snatch and clean & jerk technique plus strength", daysPerWeek: 4, difficulty: "Advanced", goal: "Power", icon: "🏋️‍♀️", days: [
            day("Monday", "Snatch Day", ["Snatch", "Overhead Squats", "Snatch Pulls", "Core Work"], 75),
            day("Tuesday", "Clean & Jerk Day", ["Clean and Jerk", "Front Squats", "Push Press", "Pull-ups"], 75),
            day("Thursday", "Strength Day", ["Squats", "Deadlift", "Strict Press", "Barbell Rows"], 75),
            day("Saturday", "Technique Day", ["Hang Snatch", "Hang Cleans", "Jerk Dips", "Ab Wheel"], 60),
        ]),
        CatalogProgram(name: "Calisthenics Foundations", description: "Bodyweight-only strength you can do anywhere", daysPerWeek: 3, difficulty: "Beginner", goal: "General Fitness", icon: "🤸", days: [
            day("Monday", "Push", ["Push-ups", "Pike Push-ups", "Dips", "Plank"], 40),
            day("Wednesday", "Pull", ["Pull-ups", "Inverted Rows", "Chin-ups", "Hollow Hold"], 40),
            day("Friday", "Legs & Core", ["Pistol Squat Progressions", "Walking Lunges", "Glute Bridges", "Hanging Leg Raises"], 40),
        ]),
        CatalogProgram(name: "Longevity & Mobility", description: "Joint-friendly strength, balance, and mobility for the long game", daysPerWeek: 3, difficulty: "Beginner", goal: "Longevity", icon: "🛡️", days: [
            day("Monday", "Strength + Balance", ["Goblet Squats", "Dumbbell Press", "Single-Leg Romanian Deadlifts", "Farmer's Carry"], 45),
            day("Wednesday", "Zone 2 + Core", ["Incline Walk", "Dead Bug", "Bird Dog", "Side Plank"], 45),
            day("Friday", "Full Body + Mobility", ["Trap Bar Deadlift", "Seated Rows", "Step-ups", "Mobility Flow"], 45),
        ]),
        CatalogProgram(name: "Time-Crunched 2x", description: "Two efficient full-body sessions a week", daysPerWeek: 2, difficulty: "Beginner", goal: "General Fitness", icon: "⏱️", days: [
            day("Tuesday", "Full Body A", ["Squats", "Bench Press", "Barbell Rows", "Plank"], 40),
            day("Saturday", "Full Body B", ["Deadlift", "Overhead Press", "Pull-ups", "Walking Lunges"], 40),
        ]),
        CatalogProgram(name: "Home Dumbbell Only", description: "Complete program with just a pair of dumbbells", daysPerWeek: 3, difficulty: "Beginner", goal: "Muscle Building", icon: "🏠", days: [
            day("Monday", "Upper", ["Dumbbell Bench Press", "Dumbbell Rows", "Dumbbell Shoulder Press", "Hammer Curls"], 45),
            day("Wednesday", "Lower", ["Goblet Squats", "Dumbbell Romanian Deadlifts", "Walking Lunges", "Calf Raises"], 45),
            day("Friday", "Full Body", ["Dumbbell Thrusters", "Renegade Rows", "Split Squats", "Overhead Tricep Extension"], 45),
        ]),
    ]
}

// MARK: - Programs View

struct ProgramsView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var showProgramConfirmation = false
    @State private var pendingProgram: CatalogProgram?
    @State private var showAIQuestionnaire = false
    @State private var showCustomBuilder = false

    private var hasActiveProgram: Bool { !workoutManager.weeklySchedule.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose Your Program")
                    .font(.largeTitle)
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
        .sheet(isPresented: $showAIQuestionnaire) {
            AIWorkoutQuestionnaireView()
                .environmentObject(workoutManager)
        }
        .sheet(isPresented: $showCustomBuilder) {
            CustomWorkoutBuilderView()
                .environmentObject(workoutManager)
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
                Text("Pick any program below to switch — we'll ask before replacing anything.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.brandGreen.opacity(0.1))
        .cornerRadius(12)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: { showAIQuestionnaire = true }) {
                bigActionLabel(icon: "sparkles", iconColor: .yellow,
                               title: "AI Generate Workout",
                               subtitle: "Let AI create a personalized workout based on your goals",
                               colors: [.brandPurple, .brandBlue])
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button(action: { showCustomBuilder = true }) {
                bigActionLabel(icon: "square.and.pencil", iconColor: .white,
                               title: "Create Your Own Workout",
                               subtitle: "Build your week from scratch — then let AI suggest improvements",
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
    var dayOfWeek = "Monday"
    var name = ""
    var minutes = 60
    var exercises: [String] = []
    var newExercise = ""
}

struct CustomWorkoutBuilderView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @Environment(\.dismiss) var dismiss

    @State private var programName = "My Custom Program"
    @State private var days: [DraftDay] = [DraftDay()]
    @State private var aiSuggestions: String?
    @State private var aiBusy = false
    @State private var aiError: String?
    @State private var showQuitConfirmation = false

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let quickPicks = ["Squats", "Bench Press", "Deadlift", "Overhead Press", "Pull-ups",
                                     "Barbell Rows", "Lunges", "Leg Press", "Bicep Curls", "Tricep Dips",
                                     "Plank", "Lateral Raises", "Romanian Deadlifts", "Calf Raises", "Push-ups"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Create Your Own Workout")
                        .font(.largeTitle)
                        .bold()
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

                aiSection

                Button {
                    if workoutManager.weeklySchedule.isEmpty {
                        save(append: false)
                    } else {
                        showQuitConfirmation = true
                    }
                } label: {
                    Text("Save Program")
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
                    ForEach(Self.weekdays, id: \.self) { Text($0) }
                }
                .frame(maxWidth: 160)
                TextField("Workout name (e.g. Push Day)", text: day.name)
                    .textFieldStyle(.roundedBorder)
                Stepper("\(day.wrappedValue.minutes) min", value: day.minutes, in: 15...180, step: 5)
                    .frame(maxWidth: 160)
            }

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

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Coach Review", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await runAI() }
                } label: {
                    if aiBusy {
                        SwiftUI.ProgressView().controlSize(.small)
                    } else {
                        Text("Suggest Improvements")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandBlue)
                .disabled(aiBusy || !isValid)
            }
            Text("Your workout is reviewed by our AI coach (runs on our server — free to you).")
                .font(.caption)
                .foregroundColor(.secondary)

            if let error = aiError {
                Text(error).font(.caption).foregroundColor(.red)
            }
            if let suggestions = aiSuggestions {
                Text(suggestions)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.brandBlue.opacity(0.08))
                    .cornerRadius(10)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }

    private func runAI() async {
        aiBusy = true
        aiError = nil
        defer { aiBusy = false }
        do {
            aiSuggestions = try await FitnessAI.improveWorkout(days: draftedDays(), profile: workoutManager.userProfile)
        } catch {
            aiError = error.localizedDescription
        }
    }

    private func draftedDays() -> [ScheduledWorkout] {
        days.map {
            ScheduledWorkout(dayOfWeek: $0.dayOfWeek, workoutType: $0.name,
                             exercises: $0.exercises, estimatedDuration: $0.minutes)
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
    @State private var showAIBuilder = false
    @State private var editingPhase: MesoPhase?

    private var totalWeeks: Int { workoutManager.mesoPhases.reduce(0) { $0 + $1.weeks } }

    private var progress: (workout: Int, total: Int, phase: String) {
        let workoutsPerWeek = max(1, workoutManager.weeklySchedule.count)
        let total = max(1, totalWeeks * workoutsPerWeek)
        let current = workoutManager.sessions.count % total
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
                    .font(.largeTitle)
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

                // AI builder
                Button {
                    showAIBuilder = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 32))
                            .foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI Mesocycle Builder")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                            Text("Answer a few questions and AI designs your training phases")
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
                    .background(LinearGradient(colors: [.brandBlue, .brandPurple], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(16)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

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
        .sheet(isPresented: $showAIBuilder) {
            AIMesocycleBuilderView()
                .environmentObject(workoutManager)
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

struct AIMesocycleBuilderView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @Environment(\.dismiss) var dismiss

    @State private var goal = "Build muscle"
    @State private var weeks = 12
    @State private var notes = ""
    @State private var busy = false
    @State private var error: String?
    @State private var preview: [MesoPhase]?

    private static let goals = ["Build muscle", "Get stronger", "Lose fat", "Athletic performance", "General fitness", "Longevity"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("AI Mesocycle Builder")
                        .font(.title.bold())
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                }

                Picker("Goal", selection: $goal) {
                    ForEach(Self.goals, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)

                Stepper("Cycle length: \(weeks) weeks", value: $weeks, in: 4...24, step: 2)

                TextField("Anything else the AI should know? (injuries, schedule, preferences)", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                Button {
                    Task { await generate() }
                } label: {
                    if busy {
                        SwiftUI.ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(6)
                    } else {
                        Label("Generate Phases", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                            .padding(6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandPurple)
                .disabled(busy)

                if let error {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                if let preview {
                    Text("Proposed Plan")
                        .font(.headline)
                    ForEach(preview) { phase in
                        HStack(spacing: 12) {
                            Text(phase.emoji).font(.system(size: 28))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(phase.name) — \(phase.weeks)w, \(phase.repRange) reps").font(.subheadline.bold())
                                Text(phase.focus).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.brandPurple.opacity(0.08))
                        .cornerRadius(10)
                    }
                    Button {
                        workoutManager.mesoPhases = preview
                        workoutManager.saveScheduleState()
                        dismiss()
                    } label: {
                        Text("Use This Plan")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding(6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandGreen)
                }
            }
            .padding(24)
        }
        .frame(minWidth: Platform.isDesktop ? 520 : nil,
               minHeight: Platform.isDesktop ? 480 : nil)
    }

    private func generate() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            preview = try await FitnessAI.buildMesocycle(
                goal: goal,
                experience: workoutManager.userProfile?.experienceLevel.rawValue ?? "intermediate",
                weeks: weeks,
                notes: notes
            )
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}
