//
//  WorkoutTracker macOS - Enhanced Implementation
//  All features: Persistence, Python Integration, Progress Tracking, Rest Timer, Export/Import
//

import SwiftUI
import Foundation
import Charts

// MARK: - Brand Colors
extension Color {
    static let brandPurple = Color(red: 0.58, green: 0.40, blue: 0.93)
    static let brandBlue = Color(red: 0.33, green: 0.67, blue: 0.93)
    static let brandGreen = Color(red: 0.40, green: 0.87, blue: 0.67)
    static let brandOrange = Color(red: 1.0, green: 0.60, blue: 0.40)
    static let brandYellow = Color(red: 1.0, green: 0.87, blue: 0.40)

    static let lightPurpleBg = Color(red: 0.95, green: 0.93, blue: 0.98)
    static let lightBlueBg = Color(red: 0.93, green: 0.96, blue: 0.99)
    static let lightGreenBg = Color(red: 0.93, green: 0.98, blue: 0.96)
    static let lightOrangeBg = Color(red: 1.0, green: 0.96, blue: 0.93)
}

// MARK: - Main App
@main
struct WorkoutTrackerMacApp: App {
    @StateObject private var workoutManager = WorkoutManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            RootView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .environmentObject(workoutManager)
                .onAppear { Platform.activate() }
        }
        #if os(macOS)
        .windowStyle(DefaultWindowStyle())
        .defaultPosition(.center)
        #endif
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workout Session") {
                    workoutManager.startNewWorkout()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .importExport) {
                Button("Export Workouts...") {
                    workoutManager.exportWorkouts()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Import Workouts...") {
                    workoutManager.importWorkouts()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Data Models
struct WorkoutSession: Codable, Identifiable {
    let id: UUID
    var date: Date
    var programName: String?
    var exercises: [Exercise]
    var notes: String?
    var duration: TimeInterval?
    var completed: Bool

    init(id: UUID = UUID(), date: Date = Date(), programName: String? = nil, exercises: [Exercise] = [], notes: String? = nil, duration: TimeInterval? = nil, completed: Bool = false) {
        self.id = id
        self.date = date
        self.programName = programName
        self.exercises = exercises
        self.notes = notes
        self.duration = duration
        self.completed = completed
    }

    var totalVolume: Double {
        exercises.reduce(0) { $0 + $1.totalVolume }
    }
}

struct Exercise: Codable, Identifiable {
    let id: UUID
    var name: String
    var sets: [ExerciseSet]
    var muscleGroup: String?
    var notes: String?

    init(id: UUID = UUID(), name: String, sets: [ExerciseSet] = [], muscleGroup: String? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.sets = sets
        self.muscleGroup = muscleGroup
        self.notes = notes
    }

    var totalVolume: Double {
        sets.reduce(0) { $0 + (Double($1.reps) * $1.weight) }
    }
}

struct ExerciseSet: Codable, Identifiable {
    let id: UUID
    var reps: Int
    var weight: Double
    var completed: Bool
    var restTime: TimeInterval?

    init(id: UUID = UUID(), reps: Int = 0, weight: Double = 0, completed: Bool = false, restTime: TimeInterval? = nil) {
        self.id = id
        self.reps = reps
        self.weight = weight
        self.completed = completed
        self.restTime = restTime
    }
}

struct WorkoutProgram: Codable, Identifiable {
    let id: UUID
    var name: String
    var description: String
    var weeks: Int
    var daysPerWeek: Int
    var schedule: [String: [ProgramDay]]

    init(id: UUID = UUID(), name: String, description: String, weeks: Int, daysPerWeek: Int, schedule: [String: [ProgramDay]] = [:]) {
        self.id = id
        self.name = name
        self.description = description
        self.weeks = weeks
        self.daysPerWeek = daysPerWeek
        self.schedule = schedule
    }
}

struct ProgramDay: Codable, Identifiable {
    let id: UUID
    var focus: String
    var exercises: [ProgramExercise]

    init(id: UUID = UUID(), focus: String, exercises: [ProgramExercise] = []) {
        self.id = id
        self.focus = focus
        self.exercises = exercises
    }
}

struct ProgramExercise: Codable, Identifiable {
    let id: UUID
    var name: String
    var sets: Int
    var reps: String
    var rest: String
    var notes: String?

    init(id: UUID = UUID(), name: String, sets: Int, reps: String, rest: String, notes: String? = nil) {
        self.id = id
        self.name = name
        self.sets = sets
        self.reps = reps
        self.rest = rest
        self.notes = notes
    }
}

// MARK: - Workout Manager
class WorkoutManager: ObservableObject {
    static let shared = WorkoutManager()

    @Published var sessions: [WorkoutSession] = []
    @Published var programs: [WorkoutProgram] = []
    @Published var currentWorkout: WorkoutSession?
    @Published var isWorkoutActive: Bool = false
    @Published var selectedTab: Int = 0
    @Published var userProfile: UserProfile?
    @Published var weeklySchedule: [ScheduledWorkout] = []
    @Published var repRangeModulation: Double = 50.0 // 0-100, 50=neutral
    @Published var volumeIntensityModulation: Double = 50.0 // Lower=volume bias, higher=intensity bias
    @Published var frequencyModulation: Double = 50.0 // Lower=often, higher=sparingly
    @Published var bodybuilderMiniActive: Bool = false
    @Published var currentProgramName: String?
    @Published var mesoPhases: [MesoPhase] = MesoPhase.classic12Week

    private let persistenceService = PersistenceService.shared
    private let pythonService = PythonGeneratorService.shared

    var currentStreak: Int {
        calculateStreak()
    }

    var todaysWorkouts: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return sessions.filter { Calendar.current.isDate($0.date, inSameDayAs: today) }.count
    }

    var weeklyWorkouts: Int {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date())!
        return sessions.filter { $0.date >= weekAgo }.count
    }

    private init() {
        loadData()
        loadDefaultPrograms()
        loadModulations()
    }

    func loadData() {
        sessions = persistenceService.loadSessions()
        programs = persistenceService.loadPrograms()
        loadScheduleState()
    }

    func loadModulations() {
        repRangeModulation = (UserDefaults.standard.object(forKey: "repRangeModulation") as? NSNumber)?.doubleValue ?? 50.0
        volumeIntensityModulation = (UserDefaults.standard.object(forKey: "volumeIntensityModulation") as? NSNumber)?.doubleValue ?? 50.0
        frequencyModulation = (UserDefaults.standard.object(forKey: "frequencyModulation") as? NSNumber)?.doubleValue ?? 50.0
        bodybuilderMiniActive = UserDefaults.standard.bool(forKey: "bodybuilderMiniActive")
    }

    func saveModulations() {
        UserDefaults.standard.set(repRangeModulation, forKey: "repRangeModulation")
        UserDefaults.standard.set(volumeIntensityModulation, forKey: "volumeIntensityModulation")
        UserDefaults.standard.set(frequencyModulation, forKey: "frequencyModulation")
        UserDefaults.standard.set(bodybuilderMiniActive, forKey: "bodybuilderMiniActive")
        UserDefaults.standard.synchronize()
    }

    func saveData() {
        persistenceService.save(sessions: sessions)
        persistenceService.save(programs: programs)
        saveScheduleState()
    }

    func startNewWorkout() {
        currentWorkout = WorkoutSession()
        isWorkoutActive = true
        selectedTab = 1
        SessionGame.shared.sessionStarted() // SessionGameLayer hook
    }

    func startScheduledWorkout(_ scheduledWorkout: ScheduledWorkout, defaultSets: Int = 3, defaultReps: Int = 10, defaultWeight: Double = 0) {
        currentWorkout = WorkoutSession()
        isWorkoutActive = true
        selectedTab = 1
        SessionGame.shared.sessionStarted() // SessionGameLayer hook

        // Add exercises from scheduled workout with custom defaults
        for exerciseName in scheduledWorkout.exercises {
            addExerciseToCurrentWorkout(name: exerciseName, muscleGroup: nil, defaultSets: defaultSets, defaultReps: defaultReps, defaultWeight: defaultWeight)
        }
    }

    func addExerciseToCurrentWorkout(name: String, muscleGroup: String? = nil, defaultSets: Int = 3, defaultReps: Int = 10, defaultWeight: Double = 0) {
        guard currentWorkout != nil else { return }

        // Check if we have performance data for this exercise
        let perfData = getPerformanceDefaults(for: name)
        let useSets = perfData.sets > 0 ? perfData.sets : defaultSets
        let useReps = perfData.reps > 0 ? perfData.reps : defaultReps
        let useWeight = perfData.weight > 0 ? perfData.weight : defaultWeight

        // Create exercise with performance-based or custom default sets
        var sets: [ExerciseSet] = []
        for _ in 0..<useSets {
            sets.append(ExerciseSet(reps: useReps, weight: useWeight, completed: false))
        }

        let exercise = Exercise(name: name, sets: sets, muscleGroup: muscleGroup)
        currentWorkout?.exercises.append(exercise)
        objectWillChange.send()
    }

    func addSetToExercise(exerciseId: UUID, reps: Int, weight: Double) {
        // The old `sessions.firstIndex(... currentWorkout?.id)` guard always failed
        // (an active workout is only appended to `sessions` on completion), so no
        // set could ever be logged. Removed.
        guard let exerciseIndex = currentWorkout?.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }

        let newSet = ExerciseSet(reps: reps, weight: weight, completed: true)
        currentWorkout?.exercises[exerciseIndex].sets.append(newSet)
        objectWillChange.send()

        // SessionGameLayer hook: XP pop-up, combo/PR detection, rest timer.
        if let workout = currentWorkout {
            SessionGame.shared.setLogged(newSet, in: workout.exercises[exerciseIndex], workout: workout, history: sessions)
        }
    }

    func updateSet(exerciseId: UUID, setId: UUID, reps: Int, weight: Double) {
        guard let exerciseIndex = currentWorkout?.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        guard let setIndex = currentWorkout?.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setId }) else { return }

        currentWorkout?.exercises[exerciseIndex].sets[setIndex].reps = reps
        currentWorkout?.exercises[exerciseIndex].sets[setIndex].weight = weight
        objectWillChange.send()
    }

    func completeWorkout() {
        guard var workout = currentWorkout else { return }
        workout.completed = true
        // SessionGameLayer hook: duration was never recorded, so the server saw 0.
        if workout.duration == nil { workout.duration = Date().timeIntervalSince(workout.date) }
        sessions.append(workout)

        // Track performance for future AI programming
        updatePerformanceData(from: workout)

        saveData()

        // Hand the session to the game layer. Only completed sets count toward
        // XP — logging a set you didn't do shouldn't level you up. The server
        // decides the actual XP award; this just reports what happened.
        let completedSets = workout.exercises.flatMap { $0.sets }.filter { $0.completed }
        let volume = completedSets.reduce(0.0) { $0 + Double($1.reps) * $1.weight }
        let reps = completedSets.reduce(0) { $0 + $1.reps }

        if reps > 0 {
            // Completed sets per exercise, so the server can detect personal
            // records (best weight at each rep count).
            let syncExercises: [SyncExercise] = workout.exercises.compactMap { exercise in
                let done = exercise.sets.filter { $0.completed && $0.reps > 0 && $0.weight > 0 }
                guard !done.isEmpty else { return nil }
                return SyncExercise(name: exercise.name, sets: done.map { .init(reps: $0.reps, weight: $0.weight) })
            }
            let sessionID = workout.id.uuidString
            let sessionName = workout.programName ?? "Workout"
            let performedAt = workout.date
            let duration = Int(workout.duration ?? 0)
            Task { @MainActor in
                GameProfileService.shared.recordWorkout(
                    id: sessionID,
                    name: sessionName,
                    performedAt: performedAt,
                    durationSecs: duration,
                    totalVolume: volume,
                    totalReps: reps,
                    exercises: syncExercises
                )
                // Mirror the session into Apple Health (iOS only; no-op on macOS
                // and whenever the Settings toggle is off).
                HealthKitManager.shared.saveStrengthWorkout(
                    start: performedAt,
                    durationSecs: duration,
                    name: sessionName
                )
            }
        }

        currentWorkout = nil
        isWorkoutActive = false
    }

    // Track user performance to improve future AI recommendations
    func updatePerformanceData(from workout: WorkoutSession) {
        for exercise in workout.exercises {
            let exerciseName = exercise.name
            let totalSets = exercise.sets.count
            let avgReps = exercise.sets.isEmpty ? 0 : exercise.sets.map { $0.reps }.reduce(0, +) / exercise.sets.count
            let avgWeight = exercise.sets.isEmpty ? 0.0 : exercise.sets.map { $0.weight }.reduce(0, +) / Double(exercise.sets.count)

            // Store in UserDefaults for future AI calculations
            UserDefaults.standard.set(totalSets, forKey: "perf_\(exerciseName)_sets")
            UserDefaults.standard.set(avgReps, forKey: "perf_\(exerciseName)_reps")
            UserDefaults.standard.set(avgWeight, forKey: "perf_\(exerciseName)_weight")
        }
    }

    // Get performance-based defaults for an exercise
    func getPerformanceDefaults(for exerciseName: String) -> (sets: Int, reps: Int, weight: Double) {
        let defaultSets = UserDefaults.standard.integer(forKey: "perf_\(exerciseName)_sets")
        let defaultReps = UserDefaults.standard.integer(forKey: "perf_\(exerciseName)_reps")
        let defaultWeight = UserDefaults.standard.double(forKey: "perf_\(exerciseName)_weight")

        // If no data exists, return standard defaults
        if defaultSets == 0 {
            return (3, 10, 135)
        }

        return (defaultSets, defaultReps, defaultWeight)
    }

    func quickLogWorkout() {
        selectedTab = 1
        startNewWorkout()
    }

    func showTodayProgress() {
        selectedTab = 3
    }

    func calculateStreak() -> Int {
        guard !sessions.isEmpty else { return 0 }

        let sortedSessions = sessions.sorted { $0.date > $1.date }
        var streak = 0
        var currentDate = Calendar.current.startOfDay(for: Date())

        for session in sortedSessions {
            let sessionDate = Calendar.current.startOfDay(for: session.date)
            if Calendar.current.isDate(sessionDate, inSameDayAs: currentDate) {
                streak += 1
                currentDate = Calendar.current.date(byAdding: .day, value: -1, to: currentDate)!
            } else if sessionDate < currentDate {
                break
            }
        }

        return streak
    }

    func generateProgramFromPython(weeks: Int = 12, daysPerWeek: Int = 5) {
        if let programData = pythonService.generateProgram(weeks: weeks, daysPerWeek: daysPerWeek) {
            // Parse and add program
            print("Generated program: \(programData)")
        }
    }

    func generateInitialProgram() {
        guard userProfile != nil else { return }

        // Start with optimal preset by default
        generateProgramWithPreset(preset: "optimal")
    }

    // MARK: - Program Wizard generation

    /// Builds the mesocycle from the full wizard config: chosen weekdays,
    /// split, session length, goal emphasis, injuries. Mesocycle length,
    /// deload and progression style are persisted for the coaching views.
    func generateProgram(with config: ProgramConfig) {
        let weekOrder = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        var days = weekOrder.filter { config.weekdays.contains($0) }
        // Fill in sensible days if fewer were picked than daysPerWeek.
        if days.count < config.daysPerWeek {
            for d in weekOrder where !days.contains(d) && days.count < config.daysPerWeek {
                days.append(d)
            }
            days = weekOrder.filter { days.contains($0) }
        }
        days = Array(days.prefix(config.daysPerWeek))

        let split = resolvedSplit(for: config)
        let focus = focusString(for: config.primaryGoal)

        var schedule: [ScheduledWorkout] = []
        for (i, day) in days.enumerated() {
            let (label, group): (String, String)
            switch split {
            case .fullBody:
                label = "Full Body \(["A", "B", "C", "D", "E", "F"][i % 6])"
                group = "Full Body"
            case .upperLower:
                label = i % 2 == 0 ? "Upper Body" : "Lower Body"
                group = i % 2 == 0 ? "Upper" : "Lower"
            case .ppl, .auto:
                label = ["Push Day", "Pull Day", "Leg Day"][i % 3]
                group = ["Push", "Pull", "Legs"][i % 3]
            }

            var exercises = generateExercises(for: group, duration: config.sessionLength, focus: focus)
            exercises = injurySafe(exercises, injuries: config.injuries)
            if config.primaryGoal == .longevity {
                exercises.append("Mobility Flow 10 min")
                exercises.append("Zone 2 Cardio 15 min")
            }

            schedule.append(ScheduledWorkout(
                dayOfWeek: day,
                workoutType: label,
                exercises: exercises,
                estimatedDuration: config.sessionLength
            ))
        }

        weeklySchedule = schedule

        // Persist the cycle-level knobs for the coaching/mesocycle views.
        let d = UserDefaults.standard
        d.set(config.mesocycleWeeks, forKey: "mesocycleWeeks")
        d.set(config.includeDeload, forKey: "deloadEnabled")
        d.set(config.progression.rawValue, forKey: "progressionStyle")
        d.set(Date().timeIntervalSince1970, forKey: "programStartDate")

        saveData()
    }

    func resolvedSplit(for config: ProgramConfig) -> ProgramSplit {
        guard config.split == .auto else { return config.split }
        if config.primaryGoal == .longevity && config.daysPerWeek <= 4 { return .fullBody }
        switch config.daysPerWeek {
        case ..<4:
            let strengthy = config.primaryGoal == .getStronger || config.primaryGoal == .buildMuscle
            return (config.daysPerWeek == 3 && strengthy && config.experienceLevel != .beginner) ? .ppl : .fullBody
        case 4: return .upperLower
        default: return .ppl
        }
    }

    private func focusString(for goal: TrainingGoal) -> String {
        switch goal {
        case .getStronger: return "Strength"
        case .buildMuscle: return "Muscle Building"
        case .loseWeight: return "Fat Loss"
        case .improveEndurance: return "Endurance"
        case .longevity, .increaseFlexibility, .generalFitness: return "General"
        }
    }

    // Swap out exercises that conflict with flagged limitations, keeping the
    // set/rep scheme suffix (e.g. " 4x8") when one is present.
    private func injurySafe(_ exercises: [String], injuries: Set<String>) -> [String] {
        guard !injuries.isEmpty else { return exercises }
        return exercises.map { ex in
            let l = ex.lowercased()
            let scheme = ex.range(of: #" \d+x[\w-]+$"#, options: .regularExpression)
                .map { String(ex[$0]) } ?? ""
            if injuries.contains("Low back"),
               l.contains("deadlift") || l.contains("bent-over") || l.contains("barbell row") || l.contains("good morning") {
                return "Chest-Supported Rows" + scheme
            }
            if injuries.contains("Shoulder"),
               l.contains("overhead press") || l.contains("push press") || l.contains("snatch") || l.contains("dips") || l.contains("handstand") {
                return "Landmine Press" + scheme
            }
            if injuries.contains("Knee"),
               l.contains("jump") || l.contains("lunge") || l.contains("leg extension") || l.contains("step-up") || l.contains("pistol") {
                return "Hip Thrusts" + scheme
            }
            return ex
        }
    }

    // Generate program with specific preset and modulation settings
    func generateProgramWithPreset(preset: String) {
        switch preset {
        case "optimal":
            generateOptimalProgram()
        case "time_crunched":
            generateTimeCrunchedProgram()
        case "weekend_warrior":
            generateWeekendWarriorProgram()
        case "longevity":
            generateLongevityProgram()
        case "strength":
            generateStrengthProgram()
        case "weight_lifter":
            generateWeightLifterProgram()
        case "powerlifting":
            generatePowerliftingProgram()
        case "power_building":
            generatePowerBuildingProgram()
        case "bodybuilding":
            generateBodybuildingProgram()
        case "functional_fitness":
            generateFunctionalFitnessProgram()
        case "bodybuilder":
            generateBodybuilderProgram()
        default:
            setPushPullLegsProgram()
        }

        // Apply bodybuilder mini if active
        if bodybuilderMiniActive {
            applyBodybuilderMini()
        }
    }

    private func generateOptimalProgram() {
        // Optimal: Balanced approach - 3-4 days/week, moderate intensity
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 1.0) // Balanced
        let intensity = volumeIntensityModulation
        
        weeklySchedule = generateBalancedSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateTimeCrunchedProgram() {
        // Time Crunched: Short sessions, high intensity, variable frequency
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.7) // More frequent
        let intensity = volumeIntensityModulation * 1.3 // Higher intensity
        
        weeklySchedule = generateHighIntensitySchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateWeekendWarriorProgram() {
        // Weekend Warrior: Infrequent, long sessions, high intensity
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.6) // Less frequent
        let intensity = volumeIntensityModulation * 1.4 // Very high intensity
        
        weeklySchedule = generateLowFrequencyHighIntensitySchedule(days: Int(max(2, daysPerWeek)), intensity: intensity)
    }

    private func generateLongevityProgram() {
        // Longevity: Safety-focused, recovery-oriented, lower intensity
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.8) // Moderate frequency
        let intensity = volumeIntensityModulation * 0.7 // Lower intensity
        
        weeklySchedule = generateRecoveryFocusedSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateStrengthProgram() {
        // Strength: Heavy lifting, low reps, compound focus
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.9)
        let intensity = volumeIntensityModulation * 0.6 // Lower volume, high intensity
        
        weeklySchedule = generateStrengthFocusedSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateWeightLifterProgram() {
        // Weight Lifter: Olympic-style training
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.8)
        let intensity = volumeIntensityModulation * 0.8
        
        weeklySchedule = generateOlympicStyleSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generatePowerliftingProgram() {
        // Powerlifting: Main lifts focus, low frequency
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.7)
        let intensity = volumeIntensityModulation * 0.5 // Very high intensity
        
        weeklySchedule = generatePowerliftingSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generatePowerBuildingProgram() {
        // Power Building: Hybrid strength and speed
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.85)
        let intensity = volumeIntensityModulation * 0.7
        
        weeklySchedule = generatePowerBuildingSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateBodybuildingProgram() {
        // Bodybuilding: High volume hypertrophy
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 1.1)
        let intensity = volumeIntensityModulation * 1.2 // High volume
        
        weeklySchedule = generateHypertrophySchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateFunctionalFitnessProgram() {
        // Functional Fitness: Multi-joint movements
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.95)
        let intensity = volumeIntensityModulation * 1.1
        
        weeklySchedule = generateFunctionalFitnessSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateBodybuilderProgram() {
        // Bodybuilder Maximum: All precautions thrown out for max hypertrophy
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 1.2)
        let intensity = volumeIntensityModulation * 1.4 // Maximum volume
        
        weeklySchedule = generateMaximumHypertrophySchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    // Calculate training days per week based on frequency modulation
    private func calculateModulatedDays(_ frequencyMod: Double) -> Double {
        let baseDays = 4.0
        let modulation = (frequencyMod - 50.0) / 50.0 // Convert to -1 to +1 scale
        let modulatedDays = baseDays + (modulation * 2.0) // ±2 days variation
        return max(2.0, min(6.0, modulatedDays))
    }

    // Rep range modulation helper
    private func modulateReps(_ baseReps: String, _ repModulation: Double) -> String {
        let modulation = (repModulation - 50.0) / 50.0 // Convert to -1 to +1 scale
        let parts = baseReps.split(separator: "-").map { String($0) }
        
        if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
            let range = high - low
            let newLow = max(1, Int(Double(low) + modulation * Double(range) * 0.5))
            let newHigh = max(newLow + 3, Int(Double(high) + modulation * Double(range) * 0.5))
            return "\(newLow)-\(newHigh)"
        }
        
        return baseReps
    }

    // Apply bodybuilder mini (additional hypertrophy exercises)
    private func applyBodybuilderMini() {
        for i in 0..<weeklySchedule.count {
            // Add isolation exercises based on the main lifts in each workout
            var additionalExercises = [String]()
            
            for mainExercise in weeklySchedule[i].exercises {
                switch mainExercise.lowercased() {
                case let ex where ex.contains("bench"):
                    additionalExercises.append("Cable Flyes 3x12-15")
                case let ex where ex.contains("squat"):
                    additionalExercises.append("Leg Extensions 3x15-20")
                case let ex where ex.contains("press"):
                    additionalExercises.append("Tricep Extensions 3x12-15")
                case let ex where ex.contains("pull"):
                    additionalExercises.append("Bicep Curls 3x12-15")
                default:
                    break
                }
            }
            
            weeklySchedule[i].exercises.append(contentsOf: additionalExercises)
            weeklySchedule[i].estimatedDuration += 15 // Extra 15 minutes
        }
    }

    // Schedule generation helpers
    private func generateBalancedSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<days {
            let dayIndex = i % daysOfWeek.count
            let exercises = [
                "Squats \(modulateReps("8-12", repRangeModulation))",
                "Bench Press \(modulateReps("8-12", repRangeModulation))",
                "Bent-over Rows \(modulateReps("8-12", repRangeModulation))",
                "Overhead Press \(modulateReps("10-15", repRangeModulation))"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[dayIndex],
                workoutType: "Balanced Training",
                exercises: exercises,
                estimatedDuration: 60
            ))
        }
        
        return schedule
    }

    private func generateHighIntensitySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<days {
            let dayIndex = i % daysOfWeek.count
            let exercises = [
                "Squats \(modulateReps("5-8", repRangeModulation))",
                "Bench Press \(modulateReps("5-8", repRangeModulation))",
                "Pull-ups \(modulateReps("6-10", repRangeModulation))"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[dayIndex],
                workoutType: "High Intensity",
                exercises: exercises,
                estimatedDuration: 45
            ))
        }
        
        return schedule
    }

    private func generateLowFrequencyHighIntensitySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let workoutDays = ["Saturday", "Sunday"] // Weekend focused
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<min(days, workoutDays.count) {
            let exercises = [
                "Squats \(modulateReps("4-6", repRangeModulation))",
                "Bench Press \(modulateReps("4-6", repRangeModulation))",
                "Deadlifts \(modulateReps("4-6", repRangeModulation))",
                "Overhead Press \(modulateReps("6-8", repRangeModulation))",
                "Pull-ups \(modulateReps("6-8", repRangeModulation))"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: workoutDays[i],
                workoutType: "Weekend Warrior",
                exercises: exercises,
                estimatedDuration: 90
            ))
        }
        
        return schedule
    }

    private func generateRecoveryFocusedSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Wednesday", "Friday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Goblet Squats \(modulateReps("12-15", repRangeModulation))",
                "Dumbbell Press \(modulateReps("12-15", repRangeModulation))",
                "Lat Pulldowns \(modulateReps("12-15", repRangeModulation))",
                "Planks 3x30s"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Recovery Focused",
                exercises: exercises,
                estimatedDuration: 50
            ))
        }
        
        return schedule
    }

    private func generateStrengthFocusedSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Thursday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Squats \(modulateReps("4-6", repRangeModulation))",
                "Bench Press \(modulateReps("4-6", repRangeModulation))",
                "Deadlifts \(modulateReps("4-6", repRangeModulation))",
                "Overhead Press \(modulateReps("4-6", repRangeModulation))"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Strength Training",
                exercises: exercises,
                estimatedDuration: 75
            ))
        }
        
        return schedule
    }

    private func generateOlympicStyleSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Wednesday", "Friday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Hang Power Cleans \(modulateReps("5-8", repRangeModulation))",
                "Front Squats \(modulateReps("5-8", repRangeModulation))",
                "Push Press \(modulateReps("5-8", repRangeModulation))",
                "Snatches \(modulateReps("4-6", repRangeModulation))"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Olympic Lifting",
                exercises: exercises,
                estimatedDuration: 90
            ))
        }
        
        return schedule
    }

    private func generatePowerliftingSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Wednesday", "Friday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Squats \(modulateReps("3-5", repRangeModulation))",
                "Bench Press \(modulateReps("3-5", repRangeModulation))",
                "Deadlifts \(modulateReps("3-5", repRangeModulation))"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Powerlifting",
                exercises: exercises,
                estimatedDuration: 80
            ))
        }
        
        return schedule
    }

    private func generatePowerBuildingSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Thursday", "Friday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<min(days, daysOfWeek.count) {
            let exercises: [String]
            if i % 2 == 0 {
                // Heavy day
                exercises = [
                    "Squats \(modulateReps("4-6", repRangeModulation))",
                    "Bench Press \(modulateReps("4-6", repRangeModulation))",
                    "Deadlifts \(modulateReps("4-6", repRangeModulation))"
                ]
            } else {
                // Speed day
                exercises = [
                    "Box Squats \(modulateReps("6-8", repRangeModulation))",
                    "Close Grip Bench \(modulateReps("6-8", repRangeModulation))",
                    "Snatch Grip Pulls \(modulateReps("6-8", repRangeModulation))"
                ]
            }
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Power Building",
                exercises: exercises,
                estimatedDuration: 70
            ))
        }
        
        return schedule
    }

    private func generateHypertrophySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let bodyParts = ["Chest", "Back", "Legs", "Shoulders", "Arms"]
        var schedule = [ScheduledWorkout]()
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        
        for i in 0..<days {
            let focusArea = bodyParts[i % bodyParts.count]
            var exercises = [String]()
            
            switch focusArea {
            case "Chest":
                exercises = [
                    "Bench Press \(modulateReps("8-12", repRangeModulation))",
                    "Incline Dumbbell Press \(modulateReps("8-12", repRangeModulation))",
                    "Cable Flyes \(modulateReps("10-15", repRangeModulation))"
                ]
            case "Back":
                exercises = [
                    "Pull-ups \(modulateReps("8-12", repRangeModulation))",
                    "Lat Pulldowns \(modulateReps("10-15", repRangeModulation))",
                    "Bent-over Rows \(modulateReps("8-12", repRangeModulation))"
                ]
            case "Legs":
                exercises = [
                    "Squats \(modulateReps("8-12", repRangeModulation))",
                    "Leg Press \(modulateReps("10-15", repRangeModulation))",
                    "Leg Extensions \(modulateReps("12-15", repRangeModulation))"
                ]
            case "Shoulders":
                exercises = [
                    "Overhead Press \(modulateReps("8-12", repRangeModulation))",
                    "Lateral Raises \(modulateReps("10-15", repRangeModulation))",
                    "Rear Delt Flyes \(modulateReps("10-15", repRangeModulation))"
                ]
            case "Arms":
                exercises = [
                    "Barbell Curls \(modulateReps("8-12", repRangeModulation))",
                    "Tricep Extensions \(modulateReps("10-15", repRangeModulation))",
                    "Hammer Curls \(modulateReps("10-15", repRangeModulation))"
                ]
            default:
                exercises = ["Bench Press \(modulateReps("8-12", repRangeModulation))"]
            }
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i % daysOfWeek.count],
                workoutType: "\(focusArea) Hypertrophy",
                exercises: exercises,
                estimatedDuration: 60
            ))
        }
        
        return schedule
    }

    private func generateFunctionalFitnessSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Saturday"]
        var schedule = [ScheduledWorkout]()
        
        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Burpees \(modulateReps("8-12", repRangeModulation))",
                "Kettlebell Swings \(modulateReps("10-15", repRangeModulation))",
                "Box Jumps \(modulateReps("8-12", repRangeModulation))",
                "Farmer's Walk 4x30m",
                "Medicine Ball Slams \(modulateReps("8-12", repRangeModulation))"
            ]
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Functional Fitness",
                exercises: exercises,
                estimatedDuration: 50
            ))
        }
        
        return schedule
    }

    private func generateMaximumHypertrophySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let bodyParts = ["Chest", "Back", "Legs", "Shoulders", "Arms"]
        var schedule = [ScheduledWorkout]()
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        
        for i in 0..<days {
            let focusArea1 = bodyParts[i % bodyParts.count]
            let focusArea2 = bodyParts[(i + 1) % bodyParts.count]
            var exercises = [String]()
            
            // Primary focus area
            switch focusArea1 {
            case "Chest":
                exercises.append(contentsOf: [
                    "Bench Press \(modulateReps("6-10", repRangeModulation))",
                    "Incline Bench Press \(modulateReps("8-12", repRangeModulation))",
                    "Decline Bench Press \(modulateReps("8-12", repRangeModulation))",
                    "Cable Flyes \(modulateReps("10-15", repRangeModulation))",
                    "Push-ups \(modulateReps("15-20", repRangeModulation))"
                ])
            case "Back":
                exercises.append(contentsOf: [
                    "Pull-ups \(modulateReps("6-10", repRangeModulation))",
                    "Lat Pulldowns \(modulateReps("8-12", repRangeModulation))",
                    "Bent-over Rows \(modulateReps("8-12", repRangeModulation))",
                    "Seated Cable Rows \(modulateReps("10-15", repRangeModulation))",
                    "Face Pulls \(modulateReps("12-15", repRangeModulation))"
                ])
            case "Legs":
                exercises.append(contentsOf: [
                    "Squats \(modulateReps("8-12", repRangeModulation))",
                    "Leg Press \(modulateReps("10-15", repRangeModulation))",
                    "Lunges \(modulateReps("10-15", repRangeModulation))",
                    "Leg Extensions \(modulateReps("12-15", repRangeModulation))",
                    "Leg Curls \(modulateReps("12-15", repRangeModulation))"
                ])
            default:
                exercises.append("Rest and Recovery Day")
            }
            
            // Secondary focus area
            switch focusArea2 {
            case "Shoulders":
                exercises.append("Overhead Press \(modulateReps("8-12", repRangeModulation))")
                exercises.append("Lateral Raises \(modulateReps("10-15", repRangeModulation))")
            case "Arms":
                exercises.append("Bicep Curls \(modulateReps("8-12", repRangeModulation))")
                exercises.append("Tricep Extensions \(modulateReps("10-15", repRangeModulation))")
            default:
                break
            }
            
            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i % daysOfWeek.count],
                workoutType: "Maximum Hypertrophy",
                exercises: exercises,
                estimatedDuration: 90
            ))
        }
        
        return schedule
    }

    func resetProgramming() {
        weeklySchedule = []
        saveData()
    }

    func setPushPullLegsProgram() {
        weeklySchedule = [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Push Day",
                            exercises: ["Bench Press", "Overhead Press", "Incline Dumbbell Press", "Tricep Dips"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "Pull Day",
                            exercises: ["Deadlift", "Pull-ups", "Barbell Rows", "Face Pulls"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Leg Day",
                            exercises: ["Squats", "Romanian Deadlifts", "Leg Press", "Calf Raises"],
                            estimatedDuration: 60)
        ]
        saveData()
        selectedTab = 1 // Navigate to Workouts tab
    }

    func setCircuitTrainingProgram() {
        weeklySchedule = [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Full Body Circuit",
                            exercises: ["Squats", "Push-ups", "Lunges", "Rows"],
                            estimatedDuration: 45),
            ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "HIIT Cardio",
                            exercises: ["Burpees", "Mountain Climbers", "Jump Squats", "Plank"],
                            estimatedDuration: 30),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Full Body Circuit",
                            exercises: ["Deadlifts", "Bench Press", "Pull-ups", "Leg Press"],
                            estimatedDuration: 45)
        ]
        saveData()
        selectedTab = 1 // Navigate to Workouts tab
    }

    func setUpperLowerProgram() {
        weeklySchedule = [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Upper Body",
                            exercises: ["Bench Press", "Barbell Rows", "Overhead Press", "Pull-ups"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Tuesday", workoutType: "Lower Body",
                            exercises: ["Squats", "Romanian Deadlifts", "Leg Press", "Leg Curls"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Thursday", workoutType: "Upper Body",
                            exercises: ["Incline Bench", "T-Bar Rows", "Dumbbell Press", "Lat Pulldowns"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Lower Body",
                            exercises: ["Deadlifts", "Front Squats", "Lunges", "Calf Raises"],
                            estimatedDuration: 60)
        ]
        saveData()
        selectedTab = 1 // Navigate to Workouts tab
    }

    func setFullBodyProgram() {
        weeklySchedule = [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Full Body A",
                            exercises: ["Squats", "Bench Press", "Barbell Rows", "Overhead Press"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "Full Body B",
                            exercises: ["Deadlifts", "Incline Press", "Pull-ups", "Dumbbell Rows"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Full Body C",
                            exercises: ["Front Squats", "Dips", "Chin-ups", "Leg Press"],
                            estimatedDuration: 60)
        ]
        saveData()
        selectedTab = 1 // Navigate to Workouts tab
    }

    // Append versions of programs
    func appendPushPullLegsProgram() {
        weeklySchedule.append(contentsOf: [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Push Day",
                            exercises: ["Bench Press", "Overhead Press", "Incline Dumbbell Press", "Tricep Dips"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "Pull Day",
                            exercises: ["Deadlift", "Pull-ups", "Barbell Rows", "Face Pulls"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Leg Day",
                            exercises: ["Squats", "Romanian Deadlifts", "Leg Press", "Calf Raises"],
                            estimatedDuration: 60)
        ])
        saveData()
    }

    func appendCircuitTrainingProgram() {
        weeklySchedule.append(contentsOf: [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Full Body Circuit",
                            exercises: ["Squats", "Push-ups", "Lunges", "Rows"],
                            estimatedDuration: 45),
            ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "HIIT Cardio",
                            exercises: ["Burpees", "Mountain Climbers", "Jump Squats", "Plank"],
                            estimatedDuration: 30),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Full Body Circuit",
                            exercises: ["Deadlifts", "Bench Press", "Pull-ups", "Leg Press"],
                            estimatedDuration: 45)
        ])
        saveData()
    }

    func appendUpperLowerProgram() {
        weeklySchedule.append(contentsOf: [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Upper Body",
                            exercises: ["Bench Press", "Barbell Rows", "Overhead Press", "Pull-ups"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Tuesday", workoutType: "Lower Body",
                            exercises: ["Squats", "Romanian Deadlifts", "Leg Press", "Leg Curls"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Thursday", workoutType: "Upper Body",
                            exercises: ["Incline Bench", "T-Bar Rows", "Dumbbell Press", "Lat Pulldowns"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Lower Body",
                            exercises: ["Deadlifts", "Front Squats", "Lunges", "Calf Raises"],
                            estimatedDuration: 60)
        ])
        saveData()
    }

    func appendFullBodyProgram() {
        weeklySchedule.append(contentsOf: [
            ScheduledWorkout(dayOfWeek: "Monday", workoutType: "Full Body A",
                            exercises: ["Squats", "Bench Press", "Barbell Rows", "Overhead Press"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "Full Body B",
                            exercises: ["Deadlifts", "Incline Press", "Pull-ups", "Dumbbell Rows"],
                            estimatedDuration: 60),
            ScheduledWorkout(dayOfWeek: "Friday", workoutType: "Full Body C",
                            exercises: ["Front Squats", "Dips", "Chin-ups", "Leg Press"],
                            estimatedDuration: 60)
        ])
        saveData()
    }

    // AI Generate Workout - Creates personalized program based on user profile
    func generateAIWorkout() {
        guard let profile = userProfile else {
            // If no profile, use a default beginner program
            setFullBodyProgram()
            selectedTab = 1
            return
        }

        // Generate program based on user goals and experience
        let primaryGoal = profile.primaryGoals.first ?? .buildMuscle

        switch (profile.experienceLevel, primaryGoal) {
        case (.beginner, _):
            // Beginners get full body 3x per week
            weeklySchedule = [
                ScheduledWorkout(dayOfWeek: "Monday", workoutType: "AI Full Body Strength",
                                exercises: ["Goblet Squats", "Push-ups", "Dumbbell Rows", "Plank"],
                                estimatedDuration: 45),
                ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "AI Full Body Power",
                                exercises: ["Leg Press", "Dumbbell Bench Press", "Lat Pulldowns", "Leg Raises"],
                                estimatedDuration: 45),
                ScheduledWorkout(dayOfWeek: "Friday", workoutType: "AI Full Body Hypertrophy",
                                exercises: ["Lunges", "Incline Dumbbell Press", "Cable Rows", "Russian Twists"],
                                estimatedDuration: 45)
            ]

        case (.intermediate, .buildMuscle):
            // Intermediate muscle building - Push/Pull/Legs
            weeklySchedule = [
                ScheduledWorkout(dayOfWeek: "Monday", workoutType: "AI Push (Chest/Shoulders/Triceps)",
                                exercises: ["Bench Press 4x8", "Overhead Press 3x10", "Dumbbell Flyes 3x12", "Tricep Dips 3x10"],
                                estimatedDuration: 60),
                ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "AI Pull (Back/Biceps)",
                                exercises: ["Deadlifts 4x6", "Pull-ups 3x8", "Barbell Rows 4x8", "Hammer Curls 3x12"],
                                estimatedDuration: 60),
                ScheduledWorkout(dayOfWeek: "Friday", workoutType: "AI Legs (Quads/Hamstrings/Calves)",
                                exercises: ["Squats 4x8", "Romanian Deadlifts 3x10", "Leg Press 3x12", "Calf Raises 4x15"],
                                estimatedDuration: 60)
            ]

        case (.intermediate, .loseWeight):
            // Fat loss with circuits
            weeklySchedule = [
                ScheduledWorkout(dayOfWeek: "Monday", workoutType: "AI HIIT Circuit",
                                exercises: ["Jump Squats 4x15", "Burpees 4x12", "Mountain Climbers 4x20", "Plank 4x45s"],
                                estimatedDuration: 35),
                ScheduledWorkout(dayOfWeek: "Wednesday", workoutType: "AI Strength Circuit",
                                exercises: ["Kettlebell Swings 4x15", "Push-ups 4x12", "Goblet Squats 4x12", "Russian Twists 4x20"],
                                estimatedDuration: 35),
                ScheduledWorkout(dayOfWeek: "Friday", workoutType: "AI Cardio Circuit",
                                exercises: ["Box Jumps 4x10", "Battle Ropes 4x30s", "High Knees 4x30s", "Bicycle Crunches 4x20"],
                                estimatedDuration: 35)
            ]

        case (.advanced, .buildMuscle), (.expert, .buildMuscle):
            // Advanced muscle building - Upper/Lower 4x per week
            weeklySchedule = [
                ScheduledWorkout(dayOfWeek: "Monday", workoutType: "AI Upper Power",
                                exercises: ["Bench Press 5x5", "Barbell Rows 5x5", "Overhead Press 4x6", "Weighted Pull-ups 4x6"],
                                estimatedDuration: 75),
                ScheduledWorkout(dayOfWeek: "Tuesday", workoutType: "AI Lower Power",
                                exercises: ["Squats 5x5", "Deadlifts 5x5", "Front Squats 3x8", "Leg Curls 4x10"],
                                estimatedDuration: 75),
                ScheduledWorkout(dayOfWeek: "Thursday", workoutType: "AI Upper Hypertrophy",
                                exercises: ["Incline Bench 4x10", "Cable Rows 4x12", "Dumbbell Press 3x12", "Face Pulls 4x15"],
                                estimatedDuration: 75),
                ScheduledWorkout(dayOfWeek: "Friday", workoutType: "AI Lower Hypertrophy",
                                exercises: ["Leg Press 4x15", "Romanian Deadlifts 4x12", "Lunges 3x12", "Calf Raises 5x15"],
                                estimatedDuration: 75)
            ]

        default:
            // Default to push/pull/legs
            setPushPullLegsProgram()
            selectedTab = 1
            return
        }

        saveData()
        selectedTab = 1 // Navigate to workouts tab
    }

    // Generate custom AI workout based on questionnaire responses
    func generateCustomWorkout(daysPerWeek: Int, sessionDuration: Int, primaryFocus: String) {
        let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

        // Get current day of week
        let calendar = Calendar.current
        let todayIndex = calendar.component(.weekday, from: Date()) - 1 // Sunday = 0, Monday = 1, etc.
        let adjustedTodayIndex = todayIndex == 0 ? 6 : todayIndex - 1 // Convert to Monday = 0, Sunday = 6

        var baseWorkouts: [ScheduledWorkout] = []

        // Determine training split based on days per week and focus
        switch (daysPerWeek, primaryFocus) {
        case (2, _):
            // 2 days = Full body
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Full Body A",
                                exercises: generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Full Body B",
                                exercises: generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (3, "Strength"), (3, "Muscle Building"):
            // 3 days = Push/Pull/Legs
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Push Day",
                                exercises: generateExercises(for: "Push", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Pull Day",
                                exercises: generateExercises(for: "Pull", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Leg Day",
                                exercises: generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (3, _):
            // 3 days fat loss/fitness = Full body
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Full Body Strength",
                                exercises: generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Full Body Power",
                                exercises: generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Full Body Conditioning",
                                exercises: generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (4, _):
            // 4 days = Upper/Lower split
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Upper Body A",
                                exercises: generateExercises(for: "Upper", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Lower Body A",
                                exercises: generateExercises(for: "Lower", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Upper Body B",
                                exercises: generateExercises(for: "Upper", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Lower Body B",
                                exercises: generateExercises(for: "Lower", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (5, _):
            // 5 days = Bro split (body part per day)
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Chest Day",
                                exercises: generateExercises(for: "Chest", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Back Day",
                                exercises: generateExercises(for: "Back", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Leg Day",
                                exercises: generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Shoulders Day",
                                exercises: generateExercises(for: "Shoulders", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Arms Day",
                                exercises: generateExercises(for: "Arms", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (6, _):
            // 6 days = PPL x2
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Push Day 1",
                                exercises: generateExercises(for: "Push", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Pull Day 1",
                                exercises: generateExercises(for: "Pull", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Leg Day 1",
                                exercises: generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Push Day 2",
                                exercises: generateExercises(for: "Push", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Pull Day 2",
                                exercises: generateExercises(for: "Pull", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "AI Leg Day 2",
                                exercises: generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        default:
            // Fallback to 3-day program
            setPushPullLegsProgram()
            selectedTab = 1
            return
        }

        // Schedule workouts starting from today, spacing them appropriately
        var scheduledWorkouts: [ScheduledWorkout] = []
        let totalDays = 7
        let restDaysBetween = max(1, (totalDays - daysPerWeek) / max(daysPerWeek - 1, 1))

        var currentDayOffset = 0
        for (index, workout) in baseWorkouts.enumerated() {
            let dayIndex = (adjustedTodayIndex + currentDayOffset) % 7
            var updatedWorkout = workout
            updatedWorkout.dayOfWeek = dayNames[dayIndex]
            scheduledWorkouts.append(updatedWorkout)

            // Add rest days between workouts (but not after the last one)
            if index < baseWorkouts.count - 1 {
                currentDayOffset += 1 + restDaysBetween
            }
        }

        weeklySchedule = scheduledWorkouts
        saveData()
        selectedTab = 1
    }

    private func generateExercises(for muscleGroup: String, duration: Int, focus: String) -> [String] {
        // AI-like exercise selection based on muscle group, duration, and focus
        let exerciseCount = duration <= 30 ? 3 : duration <= 60 ? 4 : 5
        
        // Define set/rep schemes based on focus
        let setRepScheme: String
        switch focus.lowercased() {
        case "strength":
            setRepScheme = " 5x5"  // Heavy weight, low reps
        case "muscle building", "hypertrophy":
            setRepScheme = " 4x10"  // Moderate weight, moderate reps
        case "fat loss":
            setRepScheme = " 3x15"  // Circuit-style, higher reps
        case "endurance":
            setRepScheme = " 3x20"  // Light weight, high reps
        default:
            setRepScheme = " 3x12"  // Default
        }
        
        // Define exercise pools for each muscle group and focus
        var exercises: [String]
        
        switch muscleGroup.lowercased() {
        case "push":
            if focus.lowercased() == "strength" {
                exercises = ["Barbell Bench Press", "Overhead Press", "Weighted Dips", "Close Grip Bench Press"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Push-ups", "Pike Push-ups", "Dips", "Diamond Push-ups", "Handstand Push-ups"]
            } else {
                exercises = ["Dumbbell Bench Press", "Incline Dumbbell Press", "Lateral Raises", "Tricep Extensions", "Chest Flyes"]
            }
            
        case "pull":
            if focus.lowercased() == "strength" {
                exercises = ["Deadlifts", "Weighted Pull-ups", "Barbell Rows", "Face Pulls"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Bodyweight Rows", "Chin-ups", "Inverted Rows", "Bicep Curls", "Face Pulls"]
            } else {
                exercises = ["Lat Pulldowns", "Seated Cable Rows", "Face Pulls", "Hammer Curls", "Bicep Curls"]
            }
            
        case "legs":
            if focus.lowercased() == "strength" {
                exercises = ["Back Squats", "Romanian Deadlifts", "Bulgarian Split Squats", "Calf Raises"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Bodyweight Squats", "Lunges", "Step-ups", "Wall Sits", "Jump Squats"]
            } else {
                exercises = ["Leg Press", "Leg Extensions", "Leg Curls", "Calf Raises", "Hip Thrusts"]
            }
            
        case "upper":
            if focus.lowercased() == "strength" {
                exercises = ["Bench Press", "Weighted Pull-ups", "Overhead Press", "Barbell Rows"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Push-ups", "Pull-ups", "Dips", "Bodyweight Rows", "Pike Push-ups"]
            } else {
                exercises = ["Dumbbell Press", "Lat Pulldowns", "Dumbbell Rows", "Lateral Raises", "Bicep Curls"]
            }
            
        case "lower":
            if focus.lowercased() == "strength" {
                exercises = ["Squats", "Deadlifts", "Bulgarian Split Squats", "Calf Raises"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Bodyweight Squats", "Lunges", "Glute Bridges", "Calf Raises", "Step-ups"]
            } else {
                exercises = ["Leg Press", "Leg Extensions", "Romanian Deadlifts", "Hip Thrusts", "Seated Calf Raises"]
            }
            
        case "chest":
            if focus.lowercased() == "strength" {
                exercises = ["Barbell Bench Press", "Incline Bench Press", "Weighted Dips"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Push-ups", "Dips", "Plyo Push-ups", "Incline Push-ups"]
            } else {
                exercises = ["Dumbbell Press", "Incline Dumbbell Press", "Cable Flyes", "Pec Deck"]
            }
            
        case "back":
            if focus.lowercased() == "strength" {
                exercises = ["Deadlifts", "Weighted Pull-ups", "Barbell Rows", "T-bar Rows"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Pull-ups", "Chin-ups", "Inverted Rows", "Bodyweight Rows"]
            } else {
                exercises = ["Lat Pulldowns", "Seated Cable Rows", "Face Pulls", "Straight Arm Pulldowns"]
            }
            
        case "shoulders":
            if focus.lowercased() == "strength" {
                exercises = ["Overhead Press", "Push Press", "Barbell Shrugs"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Pike Push-ups", "Handstand Push-ups", "Lateral Raises", "Front Raises"]
            } else {
                exercises = ["Dumbbell Shoulder Press", "Lateral Raises", "Front Raises", "Rear Delt Flyes"]
            }
            
        case "arms":
            if focus.lowercased() == "strength" {
                exercises = ["Close Grip Bench Press", "Barbell Curls", "Weighted Dips", "Chin-ups"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Dips", "Chin-ups", "Diamond Push-ups", "Close Grip Push-ups"]
            } else {
                exercises = ["Bicep Curls", "Tricep Extensions", "Hammer Curls", "Skull Crushers"]
            }
            
        case "full body":
            if focus.lowercased() == "strength" {
                exercises = ["Squats", "Bench Press", "Deadlifts", "Overhead Press", "Pull-ups"]
            } else if focus.lowercased() == "endurance" {
                exercises = ["Burpees", "Jump Squats", "Mountain Climbers", "Kettlebell Swings", "Jumping Jacks"]
            } else if focus.lowercased() == "fat loss" {
                exercises = ["Burpees", "Kettlebell Swings", "Jump Rope", "Mountain Climbers", "Box Jumps"]
            } else {
                exercises = ["Squats", "Dumbbell Press", "Romanian Deadlifts", "Pull-ups", "Lunges"]
            }
            
        default:
            exercises = ["Squats", "Push-ups", "Pull-ups", "Plank"]
        }
        
        // Apply set/rep scheme to each exercise and limit to exerciseCount
        return Array(exercises.prefix(exerciseCount)).map { $0 + setRepScheme }
    }


    /// Writes the full session history as JSON. The file panel lives in
    /// `WorkoutTransfer` so this compiles on iOS, where there is no panel.
    @discardableResult
    func exportWorkouts() -> URL? {
        do {
            let data = try JSONEncoder().encode(sessions)
            return WorkoutTransfer.exportJSON(data, suggestedName: "workouts_export.json")
        } catch {
            print("Export error: \(error)")
            return nil
        }
    }

    /// Merges sessions from a JSON export. Existing ids win, so re-importing the
    /// same file twice doesn't duplicate history.
    func importWorkouts() {
        guard let data = WorkoutTransfer.importJSON() else { return }
        importWorkouts(from: data)
    }

    func importWorkouts(from data: Data) {
        do {
            let imported = try JSONDecoder().decode([WorkoutSession].self, from: data)
            let knownIDs = Set(sessions.map(\.id))
            let fresh = imported.filter { !knownIDs.contains($0.id) }
            sessions.append(contentsOf: fresh)
            saveData()
        } catch {
            print("Import error: \(error)")
        }
    }

    func loadDefaultPrograms() {
        if programs.isEmpty {
            programs = [
                WorkoutProgram(name: "5/3/1 Wendler", description: "Strength-focused progressive overload program", weeks: 4, daysPerWeek: 4),
                WorkoutProgram(name: "Starting Strength", description: "Beginner compound movement program", weeks: 12, daysPerWeek: 3),
                WorkoutProgram(name: "Push/Pull/Legs", description: "Bodybuilding split routine", weeks: 8, daysPerWeek: 6),
                WorkoutProgram(name: "Upper/Lower Split", description: "Balanced hypertrophy program", weeks: 8, daysPerWeek: 4)
            ]
            saveData()
        }
    }

    // AI Coaching - Mesocycle Phase
    var currentMesocyclePhase: String {
        // Determine phase based on workout count in current cycle
        let cycleLength = 12 // 12-week mesocycle
        let workoutCount = sessions.count
        let weekInCycle = (workoutCount / 3) % cycleLength // Assuming 3 workouts per week

        if weekInCycle < 4 {
            return "Hypertrophy"
        } else if weekInCycle < 8 {
            return "Strength"
        } else {
            return "Endurance"
        }
    }

    // Add exercise with AI-generated presets
    func addExerciseWithPresets(name: String, muscleGroup: String, sets: Int, reps: Int, weight: Double) {
        guard currentWorkout != nil else { return }

        var exerciseSets: [ExerciseSet] = []
        for _ in 0..<sets {
            exerciseSets.append(ExerciseSet(reps: reps, weight: weight, completed: false))
        }

        let exercise = Exercise(name: name, sets: exerciseSets, muscleGroup: muscleGroup)
        currentWorkout?.exercises.append(exercise)
        objectWillChange.send()
        saveData()
    }
}

// MARK: - Persistence Service
class PersistenceService {
    static let shared = PersistenceService()
    private let sessionsURL: URL
    private let programsURL: URL
    private let scheduleURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appFolder = documents.appendingPathComponent("WorkoutTracker", isDirectory: true)

        // Create app folder if needed
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        sessionsURL = appFolder.appendingPathComponent("workout_sessions.json")
        programsURL = appFolder.appendingPathComponent("workout_programs.json")
        scheduleURL = appFolder.appendingPathComponent("weekly_schedule.json")
    }

    func save(sessions: [WorkoutSession]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: sessionsURL)
        } catch {
            print("Error saving sessions: \(error)")
        }
    }

    func loadSessions() -> [WorkoutSession] {
        do {
            let data = try Data(contentsOf: sessionsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([WorkoutSession].self, from: data)
        } catch {
            print("Error loading sessions: \(error)")
            return []
        }
    }

    func save(programs: [WorkoutProgram]) {
        do {
            let data = try JSONEncoder().encode(programs)
            try data.write(to: programsURL)
        } catch {
            print("Error saving programs: \(error)")
        }
    }

    func save(schedule: [ScheduledWorkout]) {
        do {
            let data = try JSONEncoder().encode(schedule)
            try data.write(to: scheduleURL)
        } catch {
            print("Error saving schedule: \(error)")
        }
    }

    func loadSchedule() -> [ScheduledWorkout] {
        guard let data = try? Data(contentsOf: scheduleURL) else { return [] }
        return (try? JSONDecoder().decode([ScheduledWorkout].self, from: data)) ?? []
    }

    func loadPrograms() -> [WorkoutProgram] {
        do {
            let data = try Data(contentsOf: programsURL)
            return try JSONDecoder().decode([WorkoutProgram].self, from: data)
        } catch {
            print("Error loading programs: \(error)")
            return []
        }
    }
}

// MARK: - Python Generator Service
class PythonGeneratorService {
    static let shared = PythonGeneratorService()
    private init() {}

    /// Shells out to a local Python script. `Process` does not exist on iOS, and
    /// spawning a subprocess is not permitted there, so this is macOS-only and
    /// callers must handle nil.
    ///
    /// NOTE: the paths below point at a checkout that may not exist. Treat a nil
    /// return as the normal case, not an error worth surfacing to the user.
    func generateProgram(weeks: Int = 12, daysPerWeek: Int = 5) -> String? {
        #if !os(macOS)
        return nil
        #else
        let task = Process()
        let pipe = Pipe()

        // Use the venv python
        let pythonPath = "/Users/daniel/Documents/GitHub/copilot/.venv/bin/python3"
        let scriptPath = "/Users/daniel/Documents/GitHub/copilot/04-Business_Productivity/workout_routine_generator.py"

        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [scriptPath, String(weeks), String(daysPerWeek)]
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            print("Error running Python generator: \(error)")
            return nil
        }
        #endif
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject var workoutManager: WorkoutManager

    var body: some View {
        #if os(macOS)
        PlatformSplit {
            sidebar
            mainContent
        }
        #else
        // Phones and iPads get a tab bar. A fixed 220pt sidebar beside the
        // content is a desktop idiom that is unusable on a phone. The five
        // most-used destinations come first; SwiftUI moves the rest into a
        // "More" tab on iPhone automatically.
        TabView(selection: $workoutManager.selectedTab) {
            DashboardView()
                .tabItem { Label("Home", systemImage: "dumbbell.fill") }
                .tag(0)
            WorkoutView()
                .tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }
                .tag(1)
            CommunityView()
                .tabItem { Label("Community", systemImage: "person.2.fill") }
                .tag(7)
            ProgressView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(3)
            ProgramsView()
                .tabItem { Label("Programs", systemImage: "doc.text") }
                .tag(2)
            MesocycleView()
                .tabItem { Label("Mesocycle", systemImage: "calendar.badge.clock") }
                .tag(4)
            ToolsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver.fill") }
                .tag(5)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(6)
        }
        #endif
    }

    /// The macOS navigation rail.
    private var sidebar: some View {
        // Sidebar
        VStack(alignment: .leading, spacing: 10) {
            Text("Endgame Fitness")
                .font(.title2)
                .bold()
                .padding(.bottom)

            SidebarButton(
                title: "Dashboard",
                icon: "dumbbell.fill",
                isSelected: workoutManager.selectedTab == 0
            ) {
                workoutManager.selectedTab = 0
            }

            SidebarButton(
                title: "Workouts",
                icon: "figure.strengthtraining.traditional",
                isSelected: workoutManager.selectedTab == 1
            ) {
                workoutManager.selectedTab = 1
            }

            SidebarButton(
                title: "Programs",
                icon: "doc.text",
                isSelected: workoutManager.selectedTab == 2
            ) {
                workoutManager.selectedTab = 2
            }

            SidebarButton(
                title: "Progress",
                icon: "chart.line.uptrend.xyaxis",
                isSelected: workoutManager.selectedTab == 3
            ) {
                workoutManager.selectedTab = 3
            }

            SidebarButton(
                title: "Mesocycle",
                icon: "calendar.badge.clock",
                isSelected: workoutManager.selectedTab == 4
            ) {
                workoutManager.selectedTab = 4
            }

            SidebarButton(
                title: "Tools",
                icon: "wrench.and.screwdriver.fill",
                isSelected: workoutManager.selectedTab == 5
            ) {
                workoutManager.selectedTab = 5
            }

            SidebarButton(
                title: "Community",
                icon: "person.2.fill",
                isSelected: workoutManager.selectedTab == 7
            ) {
                workoutManager.selectedTab = 7
            }

            SidebarButton(
                title: "Settings",
                icon: "gear",
                isSelected: workoutManager.selectedTab == 6
            ) {
                workoutManager.selectedTab = 6
            }

            Spacer()

            // Quick Stats in Sidebar
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Image(systemName: "flame.fill")
                        .foregroundColor(.orange)
                    Text("\(workoutManager.currentStreak) day streak")
                        .font(.caption)
                }
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(.green)
                    Text("\(workoutManager.weeklyWorkouts) workouts this week")
                        .font(.caption)
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(width: 220)
        .background(Color.platformControlBackground)
    }

    /// The selected destination, used by the macOS split layout.
    private var mainContent: some View {
        Group {
            switch workoutManager.selectedTab {
            case 0:
                DashboardView()
            case 1:
                WorkoutView()
            case 2:
                ProgramsView()
            case 3:
                ProgressView()
            case 4:
                MesocycleView()
            case 5:
                ToolsView()
            case 6:
                SettingsView()
            case 7:
                CommunityView()
            default:
                DashboardView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar Button
struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .font(.title2)
                Text(title)
                    .font(.body)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(isSelected ? Color.accentColor.opacity(0.2) : (isHovering ? Color.gray.opacity(0.1) : Color.clear))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
        .foregroundColor(isSelected ? .accentColor : .primary)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Dashboard View
struct DashboardView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var showProgramWizard = false

    private var todaysScheduledWorkout: ScheduledWorkout? {
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let today = dayNames[Calendar.current.component(.weekday, from: Date()) - 1]
        return workoutManager.weeklySchedule.first { $0.dayOfWeek == today }
    }

    // First login: nothing trained, no program built yet. Show a calm
    // setup state instead of the full grid.
    private var needsSetup: Bool {
        workoutManager.sessions.isEmpty && workoutManager.weeklySchedule.isEmpty
    }

    var body: some View {
        Group {
            if needsSetup {
                GetSetUpView(onBuildProgram: { showProgramWizard = true })
            } else {
                fullDashboard
            }
        }
        .sheet(isPresented: $showProgramWizard) {
            ProgramWizardView()
                .environmentObject(workoutManager)
        }
    }

    private var fullDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Greet by the name given during onboarding.
                if let name = workoutManager.userProfile?.name, !name.isEmpty {
                    Text("Welcome back, \(name)")
                        .font(.screenTitle)
                        .bold()
                } else {
                    Text("Dashboard")
                        .font(.screenTitle)
                        .bold()
                }

                // Today: streak, XP ring, today's workout CTA, friends strip, live duel
                TodayCardCluster(
                    localStreak: workoutManager.currentStreak,
                    todaysWorkout: todaysScheduledWorkout,
                    workoutDoneToday: workoutManager.todaysWorkouts > 0,
                    onStartWorkout: {
                        if let scheduled = todaysScheduledWorkout {
                            workoutManager.startScheduledWorkout(scheduled)
                        } else {
                            workoutManager.startNewWorkout()
                        }
                    },
                    onOpenCommunity: { workoutManager.selectedTab = 7 }
                )

                // AI Coach Insight - Inspiring Message
                AICoachInsightCard(workoutManager: workoutManager)

                // Workout Schedule Overview
                if let profile = workoutManager.userProfile, !workoutManager.weeklySchedule.isEmpty {
                    ProgramRecommendationCard(profile: profile, schedule: workoutManager.weeklySchedule)
                }

                // Today's Workout / Next Workout
                WorkoutScheduleCard(workoutManager: workoutManager)

                // Today's Quests (server-generated; jumps to Community → Quests)
                TodaysQuestsCard { workoutManager.selectedTab = 7 }

                // Apple Health: today's steps + active energy (iOS only)
                #if os(iOS)
                HealthCard()
                #endif

                // Quick Stats
                LazyVGrid(columns: adaptiveColumns(desktop: 3, phone: 2), spacing: 20) {
                    StatCard(title: "Today's Workouts", value: "\(workoutManager.todaysWorkouts)", icon: "figure.strengthtraining.traditional", color: .blue)
                    StatCard(title: "Weekly Progress", value: "\(workoutManager.weeklyWorkouts)/21", icon: "chart.bar.fill", color: .green)
                    StatCard(title: "Current Streak", value: "\(workoutManager.currentStreak) days", icon: "flame.fill", color: .orange)
                }

                // Microcycle Progress
                MicrocycleProgressCard(workoutManager: workoutManager)

                // Quick Actions
                VStack(alignment: .leading, spacing: 15) {
                    Text("Quick Actions")
                        .font(.headline)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 15) {
                        ActionButton(title: "Start Workout", icon: "play.fill", color: .green) {
                            workoutManager.startNewWorkout()
                        }
                        ActionButton(title: "Log Exercise", icon: "plus.circle.fill", color: .blue) {
                            workoutManager.selectedTab = 1
                        }
                        ActionButton(title: "View Programs", icon: "doc.text", color: .purple) {
                            workoutManager.selectedTab = 2
                        }
                        ActionButton(title: "Progress Report", icon: "chart.line.uptrend.xyaxis", color: .orange) {
                            workoutManager.selectedTab = 3
                        }
                    }
                }

                // Recent Workouts
                if !workoutManager.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Workouts")
                            .font(.headline)

                        ForEach(workoutManager.sessions.suffix(5).reversed()) { session in
                            RecentWorkoutCard(session: session)
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Workout View
struct WorkoutView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var showAddExercise = false
    @State private var newExerciseName = ""
    @State private var selectedMuscleGroup = "Chest"
    @State private var restTimer: RestTimer?
    @State private var selectedScheduledWorkoutIndex = 0
    @State private var currentExerciseIndex = 0
    @State private var showCelebration = false
    @State private var sessionSummary: SessionSummary? // SessionGameLayer hook

    let muscleGroups = ["Chest", "Back", "Shoulders", "Arms", "Legs", "Core"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Workouts")
                    .font(.screenTitle)
                    .bold()

                // Active workout indicator
                if workoutManager.isWorkoutActive {
                    HStack(spacing: 6) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .foregroundColor(.brandGreen)
                            .font(.title2)
                            .symbolEffect(.pulse, options: .repeating)
                        if Platform.isDesktop {
                            Text("Active")
                                .font(.subheadline)
                                .foregroundColor(.brandGreen)
                                .bold()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.brandGreen.opacity(0.2))
                    .cornerRadius(20)
                }

                if workoutManager.isWorkoutActive { SessionXPBadge() } // SessionGameLayer hook

                Spacer()

                if workoutManager.isWorkoutActive, let workout = workoutManager.currentWorkout {
                    HStack(spacing: 12) {
                        // Previous Exercise Button
                        Button(action: {
                            if currentExerciseIndex > 0 {
                                withAnimation {
                                    currentExerciseIndex -= 1
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                if Platform.isDesktop { Text("Previous") }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(currentExerciseIndex == 0)

                        // Exercise Counter
                        Text("\(currentExerciseIndex + 1) / \(workout.exercises.count)")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        // Next Exercise Button
                        Button(action: {
                            if currentExerciseIndex < workout.exercises.count - 1 {
                                withAnimation {
                                    currentExerciseIndex += 1
                                }
                            } else {
                                // All exercises complete - show celebration
                                showCelebration = true
                            }
                        }) {
                            HStack {
                                if Platform.isDesktop {
                                    Text(currentExerciseIndex < workout.exercises.count - 1 ? "Next" : "Finish")
                                }
                                Image(systemName: currentExerciseIndex < workout.exercises.count - 1 ? "chevron.right" : "checkmark.circle.fill")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(currentExerciseIndex < workout.exercises.count - 1 ? .blue : .green)
                        .controlSize(.large)
                    }
                }
            }

            if workoutManager.isWorkoutActive, let workout = workoutManager.currentWorkout {
                ScrollView {
                    VStack(spacing: 20) {
                        // Workout Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Active Workout")
                                .font(.title2)
                                .bold()
                            Text(workout.date, style: .time)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(10)

                        RestTimerBar() // SessionGameLayer hook

                        // Exercises
                        ForEach(Array(workout.exercises.enumerated()), id: \.element.id) { index, exercise in
                            ExerciseCard(
                                exercise: exercise,
                                restTimer: $restTimer,
                                isCurrentExercise: index == currentExerciseIndex
                            )
                            .scaleEffect(index == currentExerciseIndex ? 1.02 : 1.0)
                            .shadow(color: index == currentExerciseIndex ? .blue.opacity(0.3) : .clear, radius: 8)
                        }

                        // Add Exercise Button
                        Button(action: { showAddExercise = true }) {
                            Label("Add Exercise", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(.blue)
                    }
                }
                .overlay(XPPopupOverlay()) // SessionGameLayer hook
            } else {
                // Show programmed workouts
                if !workoutManager.weeklySchedule.isEmpty {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Workout Selector
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Button(action: {
                                        print("Left button pressed")
                                        if selectedScheduledWorkoutIndex > 0 {
                                            selectedScheduledWorkoutIndex -= 1
                                        }
                                    }) {
                                        Image(systemName: "chevron.left.circle.fill")
                                            .font(.title)
                                            .foregroundColor(selectedScheduledWorkoutIndex == 0 ? .gray : .blue)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .disabled(selectedScheduledWorkoutIndex == 0)
                                    .help("Previous workout")

                                    Spacer()

                                    VStack(spacing: 4) {
                                        Text(workoutManager.weeklySchedule[selectedScheduledWorkoutIndex].workoutType)
                                            .font(.title.bold())

                                        HStack(spacing: 8) {
                                            Text(workoutManager.weeklySchedule[selectedScheduledWorkoutIndex].dayOfWeek)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)

                                            if isTodaysWorkout(workoutManager.weeklySchedule[selectedScheduledWorkoutIndex]) {
                                                Text("• TODAY")
                                                    .font(.caption.bold())
                                                    .foregroundColor(.green)
                                            }
                                        }
                                    }

                                    Spacer()

                                    Button(action: {
                                        print("Right button pressed")
                                        if selectedScheduledWorkoutIndex < workoutManager.weeklySchedule.count - 1 {
                                            selectedScheduledWorkoutIndex += 1
                                        }
                                    }) {
                                        Image(systemName: "chevron.right.circle.fill")
                                            .font(.title)
                                            .foregroundColor(selectedScheduledWorkoutIndex >= workoutManager.weeklySchedule.count - 1 ? .gray : .blue)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .disabled(selectedScheduledWorkoutIndex >= workoutManager.weeklySchedule.count - 1)
                                    .help("Next workout")
                                }

                                Text("\(selectedScheduledWorkoutIndex + 1) of \(workoutManager.weeklySchedule.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding()
                            .background(Color(.systemGray).opacity(0.1))
                            .cornerRadius(12)

                            // Exercise List
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Exercises")
                                    .font(.title2.bold())

                                ForEach(workoutManager.weeklySchedule[selectedScheduledWorkoutIndex].exercises, id: \.self) { exercise in
                                    HStack {
                                        Image(systemName: "checkmark.circle")
                                            .foregroundColor(.blue)
                                        Text(exercise)
                                            .font(.body)
                                        Spacer()
                                    }
                                    .padding()
                                    .background(Color.white.opacity(0.5))
                                    .cornerRadius(8)
                                }
                            }

                            // Start Workout Button
                            Button(action: {
                                workoutManager.startScheduledWorkout(workoutManager.weeklySchedule[selectedScheduledWorkoutIndex])
                            }) {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                    Text("Start This Workout")
                                }
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contentShape(Rectangle())
                        }
                        .padding()
                    }
                } else {
                    // No programmed workouts
                    VStack(spacing: 20) {
                        Text("No programmed workouts")
                            .font(.title2)
                            .foregroundColor(.secondary)

                        Text("Complete onboarding to generate your program")
                            .font(.body)
                            .foregroundColor(.secondary)

                        Button("Start Custom Workout") {
                            workoutManager.startNewWorkout()
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.title3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showAddExercise) {
            AddExerciseSheet(
                exerciseName: $newExerciseName,
                muscleGroup: $selectedMuscleGroup,
                muscleGroups: muscleGroups,
                onAdd: {
                    workoutManager.addExerciseToCurrentWorkout(name: newExerciseName, muscleGroup: selectedMuscleGroup)
                    newExerciseName = ""
                    showAddExercise = false
                }
            )
        }
        .sheet(isPresented: $showCelebration) {
            WorkoutCompletionView(onComplete: {
                showCelebration = false
                // SessionGameLayer hook: snapshot the summary before the workout is cleared.
                let summary = workoutManager.currentWorkout.map {
                    SessionSummary.make(from: $0, streak: max(workoutManager.currentStreak, 1))
                }
                workoutManager.completeWorkout()
                currentExerciseIndex = 0
                sessionSummary = summary
            })
        }
        .sheet(item: $sessionSummary) { summary in // SessionGameLayer hook
            SessionSummaryView(summary: summary, onDone: { sessionSummary = nil })
        }
        .onAppear {
            // Set today's workout as default
            if let todayIndex = getTodaysWorkoutIndex() {
                selectedScheduledWorkoutIndex = todayIndex
            }
        }
        .onChange(of: workoutManager.isWorkoutActive) { _, isActive in
            if isActive {
                // Reset exercise index when starting a new workout
                currentExerciseIndex = 0
            }
        }
    }

    func getTodaysWorkoutIndex() -> Int? {
        let today = Calendar.current.component(.weekday, from: Date())
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let todayName = dayNames[today - 1]

        return workoutManager.weeklySchedule.firstIndex { $0.dayOfWeek == todayName }
    }

    func isTodaysWorkout(_ workout: ScheduledWorkout) -> Bool {
        let today = Calendar.current.component(.weekday, from: Date())
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let todayName = dayNames[today - 1]

        return workout.dayOfWeek == todayName
    }
}

// MARK: - Exercise Card
struct ExerciseCard: View {
    let exercise: Exercise
    @Binding var restTimer: RestTimer?
    var isCurrentExercise: Bool = false
    @State private var reps: Int = 10
    @State private var weight: Double = 135
    @State private var showAddSet = false
    @State private var editingSetId: UUID? = nil
    @State private var editReps: Int = 10
    @State private var editWeight: Double = 135

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(exercise.name)
                            .font(.headline)
                        if isCurrentExercise {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                        }
                    }
                    if let muscleGroup = exercise.muscleGroup {
                        Text(muscleGroup)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text("\(Int(exercise.totalVolume)) lbs")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ExerciseRestOverride(exerciseName: exercise.name) // SessionGameLayer hook
            }

            // Sets
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                if editingSetId == set.id {
                    // Edit mode
                    if Platform.isDesktop {
                        HStack {
                            Text("Set \(index + 1)")
                                .frame(width: 60, alignment: .leading)
                            TextField("Reps", value: $editReps, format: .number)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 60)
                            Text("×")
                            TextField("Weight", value: $editWeight, format: .number)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 80)
                            Text("lbs")

                            Spacer()

                            Button("Save") {
                                WorkoutManager.shared.updateSet(exerciseId: exercise.id, setId: set.id, reps: editReps, weight: editWeight)
                                editingSetId = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Cancel") {
                                editingSetId = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    } else {
                        // iPhone: stacked edit layout
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Set \(index + 1)")
                                .font(.caption.weight(.semibold))
                            HStack(spacing: 8) {
                                TextField("Reps", value: $editReps, format: .number)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(maxWidth: 60)
                                Text("×")
                                    .frame(maxWidth: 20)
                                TextField("Weight", value: $editWeight, format: .number)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .frame(maxWidth: 70)
                                Text("lbs")
                                    .font(.caption)
                            }
                            HStack(spacing: 8) {
                                Button("Save") {
                                    WorkoutManager.shared.updateSet(exerciseId: exercise.id, setId: set.id, reps: editReps, weight: editWeight)
                                    editingSetId = nil
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)

                                Button("Cancel") {
                                    editingSetId = nil
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    // View mode
                    if Platform.isDesktop {
                        HStack {
                            Text("Set \(index + 1)")
                                .frame(width: 60, alignment: .leading)
                            Text("\(set.reps) reps")
                                .frame(width: 80, alignment: .leading)
                            Text("\(Int(set.weight)) lbs")
                                .frame(width: 80, alignment: .leading)
                            Spacer()

                            Button(action: {
                                editingSetId = set.id
                                editReps = set.reps
                                editWeight = set.weight
                            }) {
                                Image(systemName: "pencil.circle")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)

                            if set.completed {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        // iPhone: compact layout
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Set \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                if set.completed {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.callout)
                                }
                            }
                            HStack(spacing: 12) {
                                Text("\(set.reps) × \(Int(set.weight)) lbs")
                                    .font(.callout)
                                Spacer()
                                Button(action: {
                                    editingSetId = set.id
                                    editReps = set.reps
                                    editWeight = set.weight
                                }) {
                                    Image(systemName: "pencil.circle")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            // Add Set
            if showAddSet {
                HStack {
                    TextField("Reps", value: $reps, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 60)
                    Text("×")
                    TextField("Weight", value: $weight, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                    Text("lbs")

                    Spacer()

                    Button("Add") {
                        WorkoutManager.shared.addSetToExercise(exerciseId: exercise.id, reps: reps, weight: weight)
                        showAddSet = false
                        // SessionGameLayer hook: rest timer now starts in SessionGame.setLogged
                        // (the old RestTimer here was never displayed and only beeped).
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 8)
            } else {
                Button(action: { showAddSet = true }) {
                    Label("Add Set", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.blue)
            }
        }
        .padding()
        .background(isCurrentExercise ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrentExercise ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Workout Completion View
struct WorkoutCompletionView: View {
    let onComplete: () -> Void
    @State private var confettiTrigger = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
                .frame(height: 20)

            // Trophy Icon with animation
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .scaleEffect(confettiTrigger ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: confettiTrigger)

                Image(systemName: "trophy.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(.degrees(confettiTrigger ? 10 : -10))
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: confettiTrigger)
            }

            VStack(spacing: 12) {
                Text("Workout Complete!")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.brandPurple, .brandBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("Amazing work! You crushed it!")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }

            // Confetti animation (using SF Symbols)
            HStack(spacing: 20) {
                ForEach(0..<5) { index in
                    Image(systemName: "star.fill")
                        .font(.title)
                        .foregroundColor([.yellow, .orange, .pink, .purple, .blue][index])
                        .offset(y: confettiTrigger ? -20 : 0)
                        .animation(.spring(response: 0.6, dampingFraction: 0.5).delay(Double(index) * 0.1).repeatForever(autoreverses: true), value: confettiTrigger)
                }
            }

            Spacer()

            // Complete Button
            Button(action: onComplete) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Finish")
                        .font(.title2.bold())
                }
                .frame(maxWidth: 400)
                .padding(.vertical, 16)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())

            Spacer()
        }
        .desktopSheetFrame(width: 500, height: 400)
        .padding()
        .onAppear {
            confettiTrigger = true
        }
    }
}

// MARK: - Customize Workout Sheet
struct CustomizeWorkoutSheet: View {
    let scheduledWorkout: ScheduledWorkout
    let onStart: (Int, Int, Double) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var defaultSets = 3
    @State private var defaultReps = 10
    @State private var defaultWeight = 135.0

    var body: some View {
        VStack(spacing: 30) {
            // Header
            HStack {
                Text("Customize Workout")
                    .font(.screenTitle)
                    .bold()

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            VStack(alignment: .leading, spacing: 20) {
                Text(scheduledWorkout.workoutType)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.brandPurple, .brandBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Text("\(scheduledWorkout.exercises.count) exercises")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Divider()

                Text("Set default values for all exercises:")
                    .font(.headline)

                // Sets
                HStack {
                    Text("Sets per exercise:")
                        .frame(width: 150, alignment: .leading)
                    Stepper("\(defaultSets)", value: $defaultSets, in: 1...10)
                        .frame(width: 120)
                }

                // Reps
                HStack {
                    Text("Reps per set:")
                        .frame(width: 150, alignment: .leading)
                    Stepper("\(defaultReps)", value: $defaultReps, in: 1...50)
                        .frame(width: 120)
                }

                // Weight
                HStack {
                    Text("Starting weight:")
                        .frame(width: 150, alignment: .leading)
                    TextField("Weight", value: $defaultWeight, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                    Text("lbs")
                }

                Text("You can adjust individual sets during your workout.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)

            Spacer()

            // Start Button
            Button(action: {
                onStart(defaultSets, defaultReps, defaultWeight)
            }) {
                HStack {
                    Image(systemName: "play.circle.fill")
                    Text("Start Workout")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(
                        colors: [.brandPurple, .brandBlue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
        .desktopSheetFrame(width: 500, height: 500)
    }
}

// MARK: - Rest Timer
class RestTimer: ObservableObject, Identifiable {
    let id = UUID()
    @Published var timeRemaining: TimeInterval
    let duration: TimeInterval
    private var timer: Timer?

    init(duration: TimeInterval) {
        self.duration = duration
        self.timeRemaining = duration
        startTimer()
    }

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.timeRemaining > 0 {
                self.timeRemaining -= 1
            } else {
                self.timer?.invalidate()
                self.playSound()
            }
        }
    }

    func playSound() {
        Platform.beep()
    }

    deinit {
        timer?.invalidate()
    }
}

struct AIWorkoutQuestionnaireView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @Environment(\.dismiss) var dismiss

    @State private var currentStep = 1
    @State private var daysPerWeek = 3
    @State private var sessionDuration = 60
    @State private var primaryFocus = "Muscle Building"

    let daysOptions = [2, 3, 4, 5, 6]
    let durationOptions = [30, 45, 60, 75, 90]
    let focusOptions = ["Muscle Building", "Strength", "Fat Loss", "General Fitness", "Athletic Performance"]

    var body: some View {
        VStack(spacing: 30) {
            // Header
            HStack {
                Text("AI Workout Generator")
                    .font(.screenTitle)
                    .bold()

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            // Progress Indicator
            HStack(spacing: 12) {
                ForEach(1...3, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.brandPurple : Color.gray.opacity(0.3))
                        .frame(width: 12, height: 12)
                }
            }

            // Question Content (scrollable)
            ScrollView {
                VStack(spacing: 40) {
                    if currentStep == 1 {
                    VStack(spacing: 20) {
                        Image(systemName: "calendar")
                            .font(.system(size: 60))
                            .foregroundColor(.brandPurple)

                        Text("How many days per week do you want to train?")
                            .font(.title)
                            .bold()
                            .multilineTextAlignment(.center)

                        LazyVGrid(columns: adaptiveColumns(desktop: 3, phone: 2), spacing: 16) {
                            ForEach(daysOptions, id: \.self) { days in
                                BubbleOption(
                                    text: "\(days) days",
                                    isSelected: daysPerWeek == days
                                ) {
                                    daysPerWeek = days
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                } else if currentStep == 2 {
                    VStack(spacing: 20) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.brandBlue)

                        Text("How long should each session be?")
                            .font(.title)
                            .bold()
                            .multilineTextAlignment(.center)

                        LazyVGrid(columns: adaptiveColumns(desktop: 3, phone: 2), spacing: 16) {
                            ForEach(durationOptions, id: \.self) { duration in
                                BubbleOption(
                                    text: "\(duration) min",
                                    isSelected: sessionDuration == duration
                                ) {
                                    sessionDuration = duration
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                } else if currentStep == 3 {
                    VStack(spacing: 20) {
                        Image(systemName: "target")
                            .font(.system(size: 60))
                            .foregroundColor(.brandGreen)

                        Text("What's your primary focus?")
                            .font(.title)
                            .bold()
                            .multilineTextAlignment(.center)

                        VStack(spacing: 12) {
                            ForEach(focusOptions, id: \.self) { focus in
                                BubbleOption(
                                    text: focus,
                                    isSelected: primaryFocus == focus,
                                    fullWidth: true
                                ) {
                                    primaryFocus = focus
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                    }
                }
                }
                .padding(.vertical)
            }
            .frame(maxHeight: .infinity)

            // Navigation Buttons
            HStack(spacing: 16) {
                if currentStep > 1 {
                    Button(action: {
                        withAnimation {
                            currentStep -= 1
                        }
                    }) {
                        HStack {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    if currentStep < 3 {
                        withAnimation {
                            currentStep += 1
                        }
                    } else {
                        // Generate workout
                        generateCustomAIWorkout()
                        dismiss()
                    }
                }) {
                    HStack {
                        Text(currentStep < 3 ? "Next" : "Generate Workout")
                        Image(systemName: currentStep < 3 ? "chevron.right" : "sparkles")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [.brandPurple, .brandBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .desktopSheetFrame(width: 700, height: 680)
    }

    func generateCustomAIWorkout() {
        // Generate workout based on user inputs using AI-like logic
        workoutManager.generateCustomWorkout(
            daysPerWeek: daysPerWeek,
            sessionDuration: sessionDuration,
            primaryFocus: primaryFocus
        )
    }
}

struct BubbleOption: View {
    let text: String
    let isSelected: Bool
    var fullWidth: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.title3)
                .bold()
                .padding(.vertical, 20)
                .padding(.horizontal, fullWidth ? 32 : 28)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(minHeight: 60)
                .background(
                    isSelected ?
                    LinearGradient(
                        colors: [.brandPurple, .brandBlue],
                        startPoint: .leading,
                        endPoint: .trailing
                    ).opacity(isHovering ? 1.0 : 0.9) :
                    LinearGradient(
                        colors: [Color.gray.opacity(0.1), Color.gray.opacity(0.1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ).opacity(isHovering ? 0.3 : 0.2)
                )
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(fullWidth ? 12 : 25)
                .overlay(
                    RoundedRectangle(cornerRadius: fullWidth ? 12 : 25)
                        .stroke(isSelected ? Color.clear : Color.gray.opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .shadow(color: isSelected ? .brandPurple.opacity(0.3) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Progress View
struct ProgressView: View {
    @EnvironmentObject var workoutManager: WorkoutManager

    var weeklyData: [(String, Int)] {
        let calendar = Calendar.current
        let today = Date()
        var data: [(String, Int)] = []

        for i in (0..<7).reversed() {
            if let date = calendar.date(byAdding: .day, value: -i, to: today) {
                let dayName = date.formatted(.dateTime.weekday(.abbreviated))
                let count = workoutManager.sessions.filter {
                    calendar.isDate($0.date, inSameDayAs: date)
                }.count
                data.append((dayName, count))
            }
        }
        return data
    }

    var totalVolume: Double {
        workoutManager.sessions.reduce(0) { $0 + $1.totalVolume }
    }

    var averageVolume: Double {
        guard !workoutManager.sessions.isEmpty else { return 0 }
        return totalVolume / Double(workoutManager.sessions.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Progress Tracking")
                    .font(.screenTitle)
                    .bold()

                // Stats Overview
                LazyVGrid(columns: adaptiveColumns(desktop: 4, phone: 2), spacing: 15) {
                    StatCard(title: "Total Workouts", value: "\(workoutManager.sessions.count)", icon: "list.bullet", color: .blue)
                    StatCard(title: "Current Streak", value: "\(workoutManager.currentStreak)", icon: "flame.fill", color: .orange)
                    StatCard(title: "Total Volume", value: "\(Int(totalVolume))", icon: "chart.bar.fill", color: .green)
                    StatCard(title: "Avg Volume", value: "\(Int(averageVolume))", icon: "chart.line.uptrend.xyaxis", color: .purple)
                }

                // Weekly Activity Chart
                VStack(alignment: .leading, spacing: 10) {
                    Text("This Week's Activity")
                        .font(.headline)

                    if #available(macOS 13.0, *) {
                        Chart {
                            ForEach(weeklyData, id: \.0) { day, count in
                                BarMark(
                                    x: .value("Day", day),
                                    y: .value("Workouts", count)
                                )
                                .foregroundStyle(Color.blue.gradient)
                            }
                        }
                        .frame(height: 200)
                        .padding()
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(10)
                    }
                }

                // Volume Progress
                VStack(alignment: .leading, spacing: 10) {
                    Text("Volume Over Time")
                        .font(.headline)

                    if #available(macOS 13.0, *) {
                        Chart {
                            ForEach(Array(workoutManager.sessions.suffix(10).enumerated()), id: \.element.id) { index, session in
                                LineMark(
                                    x: .value("Session", index + 1),
                                    y: .value("Volume", session.totalVolume)
                                )
                                .foregroundStyle(Color.green.gradient)
                            }
                        }
                        .frame(height: 200)
                        .padding()
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(10)
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}

struct PhaseCard: View {
    let emoji: String
    let title: String
    let description: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            Text(emoji)
                .font(.system(size: 40))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - History View
struct HistoryView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var selectedMonth = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Workout History")
                    .font(.screenTitle)
                    .bold()

                if workoutManager.sessions.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No workout history yet")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 12-Month Calendar View
                    WorkoutCalendarView(workoutManager: workoutManager)

                    Divider()
                        .padding(.vertical)

                    // List View
                    Text("Recent Workouts")
                        .font(.headline)

                    ForEach(workoutManager.sessions.sorted(by: { $0.date > $1.date }).prefix(20)) { session in
                        WorkoutHistoryRow(session: session)
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Workout Calendar View
struct WorkoutCalendarView: View {
    let workoutManager: WorkoutManager

    var workoutDates: Set<DateComponents> {
        var dates = Set<DateComponents>()
        for session in workoutManager.sessions {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: session.date)
            dates.insert(components)
        }
        return dates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("12-Month Calendar")
                .font(.headline)

            LazyVGrid(columns: adaptiveColumns(desktop: 4, phone: 2), spacing: 16) {
                ForEach(0..<12, id: \.self) { monthOffset in
                    if let monthDate = Calendar.current.date(byAdding: .month, value: -monthOffset, to: Date()) {
                        MonthCalendarView(
                            month: monthDate,
                            workoutDates: workoutDates
                        )
                    }
                }
            }
        }
    }
}

struct MonthCalendarView: View {
    let month: Date
    let workoutDates: Set<DateComponents>

    var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: month)
    }

    var daysInMonth: [Date?] {
        var days: [Date?] = []
        let calendar = Calendar.current
        let range = calendar.range(of: .day, in: .month, for: month)!
        let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let firstWeekday = calendar.component(.weekday, from: firstDay)

        // Add empty days for alignment
        for _ in 1..<firstWeekday {
            days.append(nil)
        }

        // Add actual days
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }

        return days
    }

    func hasWorkout(date: Date) -> Bool {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return workoutDates.contains(components)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(monthName)
                .font(.caption)
                .bold()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 2) {
                ForEach(daysInMonth.indices, id: \.self) { index in
                    if let date = daysInMonth[index] {
                        ZStack {
                            Circle()
                                .fill(hasWorkout(date: date) ? Color.green : Color.clear)
                                .frame(width: 20, height: 20)

                            Text("\(Calendar.current.component(.day, from: date))")
                                .font(.system(size: 8))
                                .foregroundColor(hasWorkout(date: date) ? .white : .secondary)
                        }
                    } else {
                        Text("")
                            .frame(width: 20, height: 20)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Tools View
struct ToolsView: View {
    @State private var selectedTool: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Fitness Tools")
                    .font(.screenTitle)
                    .bold()

                Text("Calculators and utilities to help track your fitness journey")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 20) {
                    ToolCard(
                        title: "1RM Calculator",
                        icon: "gauge.high",
                        color: .brandPurple,
                        description: "Calculate your one-rep max"
                    ) {
                        selectedTool = "1RM"
                    }

                    ToolCard(
                        title: "BMI Calculator",
                        icon: "figure.stand",
                        color: .brandBlue,
                        description: "Calculate Body Mass Index"
                    ) {
                        selectedTool = "BMI"
                    }

                    ToolCard(
                        title: "TDEE Calculator",
                        icon: "flame.fill",
                        color: .brandOrange,
                        description: "Total Daily Energy Expenditure"
                    ) {
                        selectedTool = "TDEE"
                    }

                    ToolCard(
                        title: "Macro Calculator",
                        icon: "chart.pie.fill",
                        color: .brandGreen,
                        description: "Calculate daily macronutrients"
                    ) {
                        selectedTool = "Macro"
                    }

                    ToolCard(
                        title: "Plate Calculator",
                        icon: "circle.circle.fill",
                        color: .brandYellow,
                        description: "Calculate barbell plate loading"
                    ) {
                        selectedTool = "Plate"
                    }

                    ToolCard(
                        title: "Rep Max Chart",
                        icon: "chart.bar.fill",
                        color: .purple,
                        description: "View percentage-based rep maxes"
                    ) {
                        selectedTool = "RepMax"
                    }
                }
            }
            .padding()
        }
        .sheet(item: .constant(selectedTool.map { ToolSelection(id: $0) })) { selection in
            ToolDetailView(toolType: selection.id, isPresented: Binding(
                get: { selectedTool != nil },
                set: { if !$0 { selectedTool = nil } }
            ))
        }
    }
}

struct ToolSelection: Identifiable {
    let id: String
}

struct ToolCard: View {
    let title: String
    let icon: String
    let color: Color
    let description: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 32))
                        .foregroundColor(color)
                    Spacer()
                }

                Text(title)
                    .font(.title3)
                    .bold()
                    .foregroundColor(.primary)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(isHovering ? color.opacity(0.1) : Color.platformControlBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? color : Color.clear, lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(isHovering ? 0.1 : 0.05), radius: isHovering ? 8 : 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

struct ToolDetailView: View {
    let toolType: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(toolTitle)
                    .font(.title)
                    .bold()
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            switch toolType {
            case "1RM":
                OneRMCalculatorView()
            case "BMI":
                BMICalculatorView()
            case "TDEE":
                TDEECalculatorView()
            case "Macro":
                MacroCalculatorView()
            case "Plate":
                PlateCalculatorView()
            case "RepMax":
                RepMaxChartView()
            default:
                Text("Tool not found")
            }

            Spacer()
        }
        .desktopSheetFrame(width: 600, height: 700)
    }

    var toolTitle: String {
        switch toolType {
        case "1RM": return "1RM Calculator"
        case "BMI": return "BMI Calculator"
        case "TDEE": return "TDEE Calculator"
        case "Macro": return "Macro Calculator"
        case "Plate": return "Plate Calculator"
        case "RepMax": return "Rep Max Chart"
        default: return "Tool"
        }
    }
}

// Individual Calculator Views
struct OneRMCalculatorView: View {
    @State private var weight = ""
    @State private var reps = ""
    @State private var oneRM: Double?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weight Lifted")
                        .font(.headline)
                    TextField("Enter weight (lbs)", text: $weight)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reps Completed")
                        .font(.headline)
                    TextField("Enter reps", text: $reps)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Calculate") {
                    calculateOneRM()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let result = oneRM {
                    VStack(spacing: 8) {
                        Text("Your Estimated 1RM")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("\(Int(result)) lbs")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.brandPurple)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.brandPurple.opacity(0.1))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
    }

    func calculateOneRM() {
        guard let w = Double(weight), let r = Double(reps), r > 0 else { return }
        // Epley formula: 1RM = w * (1 + r/30)
        oneRM = w * (1 + r / 30)
    }
}

struct BMICalculatorView: View {
    @State private var weight = ""
    @State private var height = ""
    @State private var bmi: Double?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weight (lbs)")
                        .font(.headline)
                    TextField("Enter weight", text: $weight)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Height (inches)")
                        .font(.headline)
                    TextField("Enter height", text: $height)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Calculate") {
                    calculateBMI()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let result = bmi {
                    VStack(spacing: 8) {
                        Text("Your BMI")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", result))
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.brandBlue)
                        Text(bmiCategory(result))
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.brandBlue.opacity(0.1))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
    }

    func calculateBMI() {
        guard let w = Double(weight), let h = Double(height), h > 0 else { return }
        // BMI = (weight in pounds / (height in inches)^2) * 703
        bmi = (w / (h * h)) * 703
    }

    func bmiCategory(_ bmi: Double) -> String {
        switch bmi {
        case ..<18.5: return "Underweight"
        case 18.5..<25: return "Normal weight"
        case 25..<30: return "Overweight"
        default: return "Obese"
        }
    }
}

struct TDEECalculatorView: View {
    @State private var weight = ""
    @State private var height = ""
    @State private var age = ""
    @State private var gender = "Male"
    @State private var activityLevel = "Moderate"
    @State private var tdee: Double?

    let activityLevels = ["Sedentary", "Light", "Moderate", "Active", "Very Active"]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weight (lbs)")
                        .font(.headline)
                    TextField("Enter weight", text: $weight)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Height (inches)")
                        .font(.headline)
                    TextField("Enter height", text: $height)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Age")
                        .font(.headline)
                    TextField("Enter age", text: $age)
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Gender", selection: $gender) {
                    Text("Male").tag("Male")
                    Text("Female").tag("Female")
                }
                .compactSegmentedPicker()

                Picker("Activity Level", selection: $activityLevel) {
                    ForEach(activityLevels, id: \.self) { level in
                        Text(level).tag(level)
                    }
                }

                Button("Calculate") {
                    calculateTDEE()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let result = tdee {
                    VStack(spacing: 8) {
                        Text("Your TDEE")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("\(Int(result)) cal/day")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.brandOrange)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.brandOrange.opacity(0.1))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
    }

    func calculateTDEE() {
        guard let w = Double(weight), let h = Double(height), let a = Double(age) else { return }

        // Convert to kg and cm
        let weightKg = w * 0.453592
        let heightCm = h * 2.54

        // Mifflin-St Jeor Equation
        var bmr: Double
        if gender == "Male" {
            bmr = (10 * weightKg) + (6.25 * heightCm) - (5 * a) + 5
        } else {
            bmr = (10 * weightKg) + (6.25 * heightCm) - (5 * a) - 161
        }

        // Activity multiplier
        let multiplier: Double
        switch activityLevel {
        case "Sedentary": multiplier = 1.2
        case "Light": multiplier = 1.375
        case "Moderate": multiplier = 1.55
        case "Active": multiplier = 1.725
        case "Very Active": multiplier = 1.9
        default: multiplier = 1.55
        }

        tdee = bmr * multiplier
    }
}

struct MacroCalculatorView: View {
    @State private var calories = ""
    @State private var goal = "Maintenance"
    @State private var macros: (protein: Int, carbs: Int, fats: Int)?

    let goals = ["Weight Loss", "Maintenance", "Muscle Gain"]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daily Calories")
                        .font(.headline)
                    TextField("Enter calories", text: $calories)
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Goal", selection: $goal) {
                    ForEach(goals, id: \.self) { g in
                        Text(g).tag(g)
                    }
                }

                Button("Calculate") {
                    calculateMacros()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let result = macros {
                    VStack(spacing: 12) {
                        Text("Your Daily Macros")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        HStack(spacing: 20) {
                            MacroCard(name: "Protein", grams: result.protein, color: .red)
                            MacroCard(name: "Carbs", grams: result.carbs, color: .blue)
                            MacroCard(name: "Fats", grams: result.fats, color: .yellow)
                        }
                    }
                    .padding()
                }
            }
            .padding()
        }
    }

    func calculateMacros() {
        guard let cal = Double(calories), cal > 0 else { return }

        var proteinPercent: Double
        var carbsPercent: Double
        var fatsPercent: Double

        switch goal {
        case "Weight Loss":
            proteinPercent = 0.40
            carbsPercent = 0.30
            fatsPercent = 0.30
        case "Muscle Gain":
            proteinPercent = 0.30
            carbsPercent = 0.50
            fatsPercent = 0.20
        default: // Maintenance
            proteinPercent = 0.30
            carbsPercent = 0.40
            fatsPercent = 0.30
        }

        let proteinCal = cal * proteinPercent
        let carbsCal = cal * carbsPercent
        let fatsCal = cal * fatsPercent

        macros = (
            protein: Int(proteinCal / 4), // 4 cal per gram
            carbs: Int(carbsCal / 4),
            fats: Int(fatsCal / 9) // 9 cal per gram
        )
    }
}

struct MacroCard: View {
    let name: String
    let grams: Int
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(name)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("\(grams)g")
                .font(.title2)
                .bold()
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct PlateCalculatorView: View {
    @State private var targetWeight = ""
    @State private var barWeight = "45"
    @State private var plates: [(weight: Double, count: Int)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target Weight (lbs)")
                        .font(.headline)
                    TextField("Enter target weight", text: $targetWeight)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bar Weight (lbs)")
                        .font(.headline)
                    TextField("Enter bar weight", text: $barWeight)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Calculate") {
                    calculatePlates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !plates.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Plates Per Side")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        ForEach(plates, id: \.weight) { plate in
                            HStack {
                                Text("\(Int(plate.weight)) lbs")
                                    .font(.title3)
                                    .bold()
                                Spacer()
                                Text("× \(plate.count)")
                                    .font(.title2)
                                    .foregroundColor(.brandYellow)
                            }
                            .padding()
                            .background(Color.brandYellow.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
            }
            .padding()
        }
    }

    func calculatePlates() {
        guard let target = Double(targetWeight), let bar = Double(barWeight) else { return }

        var remaining = (target - bar) / 2.0 // Weight per side
        let availablePlates = [45.0, 35.0, 25.0, 10.0, 5.0, 2.5]

        var result: [(weight: Double, count: Int)] = []

        for plateWeight in availablePlates {
            let count = Int(remaining / plateWeight)
            if count > 0 {
                result.append((weight: plateWeight, count: count))
                remaining -= Double(count) * plateWeight
            }
        }

        plates = result
    }
}

struct RepMaxChartView: View {
    @State private var oneRM = ""
    @State private var percentages: [(percent: Int, weight: Int)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1 Rep Max (lbs)")
                        .font(.headline)
                    TextField("Enter 1RM", text: $oneRM)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Calculate") {
                    calculatePercentages()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !percentages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Percentage Chart")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        ForEach(percentages, id: \.percent) { item in
                            HStack {
                                Text("\(item.percent)%")
                                    .font(.title3)
                                    .bold()
                                    .frame(width: 60, alignment: .leading)
                                Spacer()
                                Text("\(item.weight) lbs")
                                    .font(.title3)
                                    .foregroundColor(.purple)
                            }
                            .padding()
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
            }
            .padding()
        }
    }

    func calculatePercentages() {
        guard let max = Double(oneRM), max > 0 else { return }

        let percents = [100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50]
        percentages = percents.map { percent in
            (percent: percent, weight: Int(max * Double(percent) / 100.0))
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @AppStorage("useMetric") private var useMetric = false
    @AppStorage("defaultRestTime") private var defaultRestTime = 90
    @AppStorage("weeklyGoal") private var weeklyGoal = 5
    @EnvironmentObject var workoutManager: WorkoutManager
    @ObservedObject private var health = HealthKitManager.shared
    @State private var showAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.screenTitle)
                .bold()

            Form {
                Section("Account") {
                    Button {
                        showAccount = true
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle")
                            Text(BatesAIAuth.shared.user?.email ?? "Account")
                            Spacer()
                            Text("Manage").foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Units") {
                    Toggle("Use Metric Units (kg)", isOn: $useMetric)
                }

                #if os(iOS)
                Section("Apple Health") {
                    if health.isConnected {
                        Toggle("Sync workouts to Apple Health", isOn: $health.syncWorkoutsToHealth)
                    } else {
                        Button("Connect Apple Health") {
                            Task { await health.requestAuthorization() }
                        }
                        .disabled(!health.isAvailable)
                    }
                    if let error = health.lastError {
                        Text(error).font(.caption).foregroundColor(.secondary)
                    }
                }
                #endif

                Section("Workout Settings") {
                    HStack {
                        Text("Default Rest Time")
                        Spacer()
                        TextField("Seconds", value: $defaultRestTime, format: .number)
                            .labelsHidden()
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                        Text("seconds")
                    }

                    HStack {
                        Text("Weekly Workout Goal")
                        Spacer()
                        TextField("Goal", value: $weeklyGoal, format: .number)
                            .labelsHidden()
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                        Text("workouts")
                    }
                }

                SessionGameSettingsSection() // SessionGameLayer hook

                Section("Data Management") {
                    Button("Export Workouts") {
                        workoutManager.exportWorkouts()
                    }

                    Button("Import Workouts") {
                        workoutManager.importWorkouts()
                    }

                    Button("Generate Python Program") {
                        workoutManager.generateProgramFromPython()
                    }
                }

                Section("Programming") {
                    Button(action: {
                        workoutManager.resetProgramming()
                    }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .foregroundColor(.red)
                            Text("Reset All Programming")
                                .foregroundColor(.red)
                        }
                    }
                    .buttonStyle(.plain)

                    Text("This will clear all scheduled workouts and allow you to start fresh with a new program.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showAccount) { NavigationStack { AccountView() } }
    }
}

// MARK: - Supporting Views
struct MicrocycleProgressCard: View {
    let workoutManager: WorkoutManager

    var microcycleProgress: (current: Int, total: Int, weekNumber: Int) {
        let workoutsPerWeek = 3
        let weeksInMicrocycle = 4
        let totalWorkouts = workoutsPerWeek * weeksInMicrocycle // 12 workouts per microcycle
        let currentWorkout = workoutManager.sessions.count % totalWorkouts
        let currentWeek = (currentWorkout / workoutsPerWeek) + 1

        return (currentWorkout, totalWorkouts, currentWeek)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("Current Microcycle")
                    .font(.headline)
            }

            Text("Week \(microcycleProgress.weekNumber) of 4")
                .font(.title3)
                .bold()

            HStack(spacing: 4) {
                ForEach(0..<microcycleProgress.total, id: \.self) { index in
                    Rectangle()
                        .fill(index < microcycleProgress.current ? Color.blue : Color.gray.opacity(0.3))
                        .frame(height: 8)
                        .cornerRadius(4)
                }
            }

            HStack {
                Text("\(microcycleProgress.current)/\(microcycleProgress.total) workouts")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    workoutManager.selectedTab = 4
                }) {
                    Text("View Full Mesocycle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(12)
    }
}

struct AICoachInsightCard: View {
    let workoutManager: WorkoutManager
    @State private var currentInsightIndex = 0

    var insights: [(emoji: String, title: String, message: String, tip: String)] {
        let streak = workoutManager.currentStreak
        let weeklyWorkouts = workoutManager.weeklyWorkouts
        let totalWorkouts = workoutManager.sessions.count
        let phase = workoutManager.currentMesocyclePhase

        var messages: [(String, String, String, String)] = []

        // Streak-based insights
        if streak == 0 {
            messages.append(("🎯", "Time to Build Momentum!", "Every champion started with their first workout. Today is your day to begin something incredible.", "Start with just 20 minutes - that's all it takes to begin your transformation."))
        } else if streak < 3 {
            messages.append(("🔥", "Great Start!", "You're building consistency! \(streak) day\(streak == 1 ? "" : "s") down. Each workout is a step toward your best self.", "Keep the momentum going - your next workout will make \(streak + 1) days!"))
        } else if streak < 7 {
            messages.append(("💪", "Momentum Building!", "\(streak) days strong! You're proving to yourself what you're capable of. This is where habits form.", "You're in the critical habit-forming zone. Don't break the chain!"))
        } else if streak < 14 {
            messages.append(("🚀", "On Fire!", "\(streak) days! Your consistency is incredible. Your body is adapting, getting stronger every single day.", "Two weeks of consistency creates lasting change. You're almost there!"))
        } else if streak < 30 {
            messages.append(("⚡", "Unstoppable!", "\(streak) day streak! You're in beast mode. This level of dedication separates good from great.", "At this rate, you'll achieve things you never thought possible."))
        } else {
            messages.append(("👑", "Legend Status!", "\(streak) days! You're not just working out - you're living a lifestyle. You're an inspiration.", "Your discipline is elite. Keep showing what's possible!"))
        }

        // Weekly progress insights
        if weeklyWorkouts == 0 {
            messages.append(("📅", "Fresh Week Ahead", "This week is a blank canvas. How will you paint your fitness story?", "Aim for 3-4 workouts this week to build sustainable momentum."))
        } else if weeklyWorkouts < 3 {
            messages.append(("📈", "Building the Week", "\(weeklyWorkouts) workout\(weeklyWorkouts == 1 ? "" : "s") completed. You're making progress, one rep at a time.", "Try to hit 3-4 workouts this week for optimal results."))
        } else if weeklyWorkouts >= 3 {
            messages.append(("✨", "Crushing It This Week!", "\(weeklyWorkouts) workouts! You're exceeding expectations and building real strength.", "This is the volume that creates transformation. Keep it up!"))
        }

        // Mesocycle-based coaching
        switch phase {
        case "Hypertrophy":
            messages.append(("💎", "Hypertrophy Phase Active", "Right now, your muscles are primed for growth. Every rep is building your physique.", "Focus on the mind-muscle connection. Feel every contraction, control every movement."))
        case "Strength":
            messages.append(("⚔️", "Strength Phase Active", "This is where you build real power. Heavy weights, low reps, maximum intensity.", "Rest 3-5 minutes between sets. Let your nervous system fully recover for maximum strength gains."))
        case "Endurance":
            messages.append(("🏃", "Endurance Phase Active", "Building your cardiovascular base and muscular endurance. This phase improves everything.", "Higher reps, shorter rest. Your work capacity is skyrocketing."))
        default:
            messages.append(("🎯", "Training Smart", "You're following periodized training - the scientifically proven path to peak performance.", "Trust the process. Each phase builds on the last."))
        }

        // Progress-based insights
        if totalWorkouts == 0 {
            messages.append(("🌟", "Your Journey Begins", "Welcome to your transformation! Every expert was once a beginner. You've got this.", "Focus on learning proper form. The weight will come with time."))
        } else if totalWorkouts < 10 {
            messages.append(("🌱", "Building Your Foundation", "\(totalWorkouts) workouts completed! Your body is learning, adapting, growing stronger.", "These early sessions are building habits that will last a lifetime."))
        } else if totalWorkouts < 50 {
            messages.append(("🔨", "Forging Strength", "\(totalWorkouts) workouts! You're past the beginner phase. Real gains are happening now.", "Progressive overload is key. Always aim to beat your last performance."))
        } else if totalWorkouts < 100 {
            messages.append(("💯", "Approaching Mastery", "\(totalWorkouts) workouts! You're becoming an athlete. Your dedication shows in every lift.", "You know your body now. Listen to it, push it, trust the process."))
        } else {
            messages.append(("🏆", "Elite Athlete", "\(totalWorkouts) workouts! You've built something extraordinary. Your consistency is world-class.", "You're proof that dedication and patience create incredible results."))
        }

        return messages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.brandPurple)
                    .frame(width: 44, height: 44)
                    .background(Color.brandPurple.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Coach")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(insights[currentInsightIndex].title)
                        .font(.title2)
                        .bold()
                }

                Spacer()
            }

            Text(insights[currentInsightIndex].message)
                .font(.title3)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

struct ProgramRecommendationCard: View {
    let profile: UserProfile
    let schedule: [ScheduledWorkout]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "star.circle.fill")
                    .foregroundColor(.brandPurple)
                    .font(.title2)
                Text("Your Program")
                    .font(.title2)
                    .bold()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(programDescription)
                    .font(.body)

                Divider()

                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Frequency")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(schedule.count) days/week")
                            .font(.headline)
                    }

                    VStack(alignment: .leading) {
                        Text("Duration")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(totalWeeklyMinutes) min/week")
                            .font(.headline)
                    }

                    VStack(alignment: .leading) {
                        Text("Focus")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(focusArea)
                            .font(.headline)
                    }
                }
            }
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.brandPurple.opacity(0.1), Color.brandBlue.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }

    var programDescription: String {
        let experienceText = profile.experienceLevel == .beginner ? "beginner-friendly" : profile.experienceLevel == .intermediate ? "intermediate" : "advanced"
        let goalText = profile.primaryGoals.first?.rawValue.lowercased() ?? "fitness"
        return "We've created a \(experienceText) \(goalText) program based on your goals and current strength levels (Bench: \(profile.benchPress5RM)lbs, Squat: \(profile.squat5RM)lbs, Deadlift: \(profile.deadlift5RM)lbs)."
    }

    var totalWeeklyMinutes: Int {
        schedule.reduce(0) { $0 + $1.estimatedDuration }
    }

    var focusArea: String {
        if profile.primaryGoals.contains(.buildMuscle) {
            return "Hypertrophy"
        } else if profile.primaryGoals.contains(.getStronger) {
            return "Strength"
        } else if profile.primaryGoals.contains(.loseWeight) {
            return "Fat Loss"
        }
        return "General Fitness"
    }
}

struct WorkoutScheduleCard: View {
    let workoutManager: WorkoutManager
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This Week")
                .font(.title2)
                .bold()

            if let todaysWorkout = getTodaysWorkout() {
                // Today's workout
                Button(action: {
                    workoutManager.selectedTab = 1
                    // Find and select today's workout in the workout view
                    if let todayIndex = workoutManager.weeklySchedule.firstIndex(where: {
                        Calendar.current.isDateInToday(Date()) && $0.dayOfWeek == getTodayName()
                    }) {
                        // Store this to be used by WorkoutView
                    }
                }) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                                .foregroundColor(.brandGreen)
                            Text("Today - \(todaysWorkout.workoutType)")
                                .font(.headline)
                            Spacer()
                            Text("\(todaysWorkout.estimatedDuration) min")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ForEach(todaysWorkout.exercises, id: \.self) { exercise in
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.brandGreen)
                                    .opacity(0.5)
                                Text(exercise)
                                    .font(.subheadline)
                            }
                        }

                        HStack {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("View in Workouts Tab")
                                .font(.caption)
                        }
                        .padding(.top, 4)
                        .foregroundColor(.blue)
                    }
                    .padding()
                    .background(Color.brandGreen.opacity(isHovering ? 0.2 : 0.1))
                    .cornerRadius(12)
                    .scaleEffect(isHovering ? 1.02 : 1.0)
                    .shadow(color: isHovering ? .brandGreen.opacity(0.3) : .clear, radius: 8)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isHovering = hovering
                    }
                }
            } else if let nextWorkout = getNextWorkout() {
                // Next workout (rest day today)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "bed.double.fill")
                            .foregroundColor(.brandYellow)
                        Text("Rest Day")
                            .font(.headline)
                    }

                    Text("Your next workout is \(nextWorkout.dayOfWeek): \(nextWorkout.workoutType)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                // No workouts scheduled - prompt to use AI
                Button(action: {
                    workoutManager.selectedTab = 2 // Go to Programs tab
                }) {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "sparkles")
                                .font(.system(size: 50))
                                .foregroundColor(.yellow)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Don't know where to start?")
                                    .font(.title.bold())
                                    .foregroundColor(.primary)

                                Text("Have AI make you a program in the Program tab!")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.brandPurple)
                        }
                        .padding(24)
                    }
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [.brandPurple.opacity(0.1), .brandBlue.opacity(0.1)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [.brandPurple, .brandBlue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: 3
                            )
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }

            if let lastWorkout = workoutManager.sessions.last {
                Divider()

                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    VStack(alignment: .leading) {
                        Text("Last Workout")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(lastWorkout.date, style: .relative)
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.5))
        .cornerRadius(12)
    }

    func getTodaysWorkout() -> ScheduledWorkout? {
        let todayName = getTodayName()
        return workoutManager.weeklySchedule.first { $0.dayOfWeek == todayName }
    }

    func getTodayName() -> String {
        let today = Calendar.current.component(.weekday, from: Date())
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return dayNames[today - 1]
    }

    func getNextWorkout() -> ScheduledWorkout? {
        let today = Calendar.current.component(.weekday, from: Date())
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        for i in 1...7 {
            let nextDay = (today + i - 1) % 7
            let nextDayName = dayNames[nextDay]
            if let workout = workoutManager.weeklySchedule.first(where: { $0.dayOfWeek == nextDayName }) {
                return workout
            }
        }

        return nil
    }
}

/// Dashboard card: today's steps and active energy from Apple Health, or a
/// connect button until the user has authorised us. iOS only at the call site;
/// the type itself compiles everywhere via the macOS stub.
struct HealthCard: View {
    @ObservedObject private var health = HealthKitManager.shared
    private let stepGoal = 8000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Health", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(Color.red)
                Spacer()
                if health.isConnected {
                    Button {
                        Task { await health.refreshToday() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if !health.isAvailable {
                Text("Apple Health is not available on this device.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if health.isConnected {
                HStack(spacing: 24) {
                    healthStat(value: health.stepsToday.formatted(), unit: "steps", icon: "figure.walk", color: .brandGreen)
                    healthStat(value: "\(Int(health.activeKcalToday.rounded()))", unit: "active kcal", icon: "flame.fill", color: .orange)
                    Spacer()
                }
                QuestProgressBar(fraction: min(1, Double(health.stepsToday) / Double(stepGoal)),
                                 tint: .brandGreen, complete: health.stepsToday >= stepGoal)
                Text(health.stepsToday >= stepGoal
                     ? "Step goal reached"
                     : "\(stepGoal - health.stepsToday) steps to today's \(stepGoal.formatted()) goal")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Connect Apple Health to count steps and active energy toward quests, and to save workouts to Health.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Connect Apple Health") {
                    Task { await health.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)
            }
            if let error = health.lastError {
                Text(error).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await health.refreshToday() }
    }

    private func healthStat(value: String, unit: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title3.weight(.semibold))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(color)
            Text(value)
                .font(.title2)
                .bold()
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ProgramCard: View {
    let program: WorkoutProgram

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                Spacer()
                Text("\(program.weeks)w")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
            }

            Text(program.name)
                .font(.headline)

            Text(program.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            Text("\(program.daysPerWeek) days/week")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }
}

struct RecentWorkoutCard: View {
    let session: WorkoutSession
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            workoutManager.selectedTab = 1
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(session.exercises.count) exercises")
                        .font(.subheadline)
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("\(Int(session.totalVolume)) lbs")
                        .font(.subheadline)
                        .bold()
                    if session.completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(isHovering ? 0.1 : 0.05))
            .cornerRadius(8)
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

struct WorkoutHistoryRow: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.date.formatted(date: .long, time: .shortened))
                    .font(.headline)
                Spacer()
                if session.completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            Text("\(session.exercises.count) exercises • \(Int(session.totalVolume)) lbs total volume")
                .font(.caption)
                .foregroundColor(.secondary)

            if let programName = session.programName {
                Text(programName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddExerciseSheet: View {
    @Binding var exerciseName: String
    @Binding var muscleGroup: String
    let muscleGroups: [String]
    let onAdd: () -> Void
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workoutManager: WorkoutManager

    @State private var step = 1
    @State private var selectedBodyPart = "Chest"
    @State private var selectedExercise: ExerciseTemplate?
    @State private var suggestedSets = 3
    @State private var suggestedReps = 10
    @State private var suggestedWeight = 135.0

    let bodyParts = ["Chest", "Back", "Shoulders", "Biceps", "Triceps", "Legs", "Quads", "Hamstrings", "Glutes", "Calves", "Core", "Abs"]

    let exerciseLibrary: [String: [ExerciseTemplate]] = [
        "Chest": [
            ExerciseTemplate(name: "Barbell Bench Press", difficulty: .intermediate),
            ExerciseTemplate(name: "Dumbbell Bench Press", difficulty: .beginner),
            ExerciseTemplate(name: "Incline Bench Press", difficulty: .intermediate),
            ExerciseTemplate(name: "Dumbbell Flyes", difficulty: .beginner),
            ExerciseTemplate(name: "Push-ups", difficulty: .beginner),
            ExerciseTemplate(name: "Cable Flyes", difficulty: .intermediate)
        ],
        "Back": [
            ExerciseTemplate(name: "Deadlift", difficulty: .advanced),
            ExerciseTemplate(name: "Barbell Row", difficulty: .intermediate),
            ExerciseTemplate(name: "Pull-ups", difficulty: .intermediate),
            ExerciseTemplate(name: "Lat Pulldown", difficulty: .beginner),
            ExerciseTemplate(name: "Dumbbell Row", difficulty: .beginner),
            ExerciseTemplate(name: "Seated Cable Row", difficulty: .beginner)
        ],
        "Shoulders": [
            ExerciseTemplate(name: "Overhead Press", difficulty: .intermediate),
            ExerciseTemplate(name: "Dumbbell Shoulder Press", difficulty: .beginner),
            ExerciseTemplate(name: "Lateral Raises", difficulty: .beginner),
            ExerciseTemplate(name: "Front Raises", difficulty: .beginner),
            ExerciseTemplate(name: "Face Pulls", difficulty: .beginner)
        ],
        "Biceps": [
            ExerciseTemplate(name: "Barbell Curl", difficulty: .beginner),
            ExerciseTemplate(name: "Dumbbell Curl", difficulty: .beginner),
            ExerciseTemplate(name: "Hammer Curl", difficulty: .beginner),
            ExerciseTemplate(name: "Cable Curl", difficulty: .beginner)
        ],
        "Triceps": [
            ExerciseTemplate(name: "Tricep Dips", difficulty: .intermediate),
            ExerciseTemplate(name: "Close Grip Bench", difficulty: .intermediate),
            ExerciseTemplate(name: "Tricep Pushdown", difficulty: .beginner),
            ExerciseTemplate(name: "Overhead Extension", difficulty: .beginner)
        ],
        "Legs": [
            ExerciseTemplate(name: "Squat", difficulty: .intermediate),
            ExerciseTemplate(name: "Romanian Deadlift", difficulty: .intermediate),
            ExerciseTemplate(name: "Leg Press", difficulty: .beginner),
            ExerciseTemplate(name: "Lunges", difficulty: .beginner)
        ],
        "Quads": [
            ExerciseTemplate(name: "Front Squat", difficulty: .advanced),
            ExerciseTemplate(name: "Leg Extension", difficulty: .beginner),
            ExerciseTemplate(name: "Hack Squat", difficulty: .intermediate)
        ],
        "Hamstrings": [
            ExerciseTemplate(name: "Leg Curl", difficulty: .beginner),
            ExerciseTemplate(name: "Romanian Deadlift", difficulty: .intermediate),
            ExerciseTemplate(name: "Good Mornings", difficulty: .intermediate)
        ],
        "Glutes": [
            ExerciseTemplate(name: "Hip Thrust", difficulty: .intermediate),
            ExerciseTemplate(name: "Bulgarian Split Squat", difficulty: .intermediate),
            ExerciseTemplate(name: "Glute Bridge", difficulty: .beginner)
        ],
        "Calves": [
            ExerciseTemplate(name: "Standing Calf Raise", difficulty: .beginner),
            ExerciseTemplate(name: "Seated Calf Raise", difficulty: .beginner)
        ],
        "Core": [
            ExerciseTemplate(name: "Plank", difficulty: .beginner),
            ExerciseTemplate(name: "Ab Wheel", difficulty: .advanced),
            ExerciseTemplate(name: "Cable Crunch", difficulty: .intermediate)
        ],
        "Abs": [
            ExerciseTemplate(name: "Hanging Leg Raise", difficulty: .intermediate),
            ExerciseTemplate(name: "Crunches", difficulty: .beginner),
            ExerciseTemplate(name: "Russian Twists", difficulty: .beginner)
        ]
    ]

    var body: some View {
        VStack(spacing: 20) {
            // Progress indicator
            HStack(spacing: 4) {
                ForEach(1...3, id: \.self) { s in
                    Rectangle()
                        .fill(step >= s ? Color.blue : Color.gray.opacity(0.3))
                        .frame(height: 4)
                        .cornerRadius(2)
                }
            }
            .padding(.horizontal)

            if step == 1 {
                // Step 1: Choose Body Part
                VStack(spacing: 16) {
                    Text("Select Body Part")
                        .font(.title2)
                        .bold()

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                            ForEach(bodyParts, id: \.self) { part in
                                Button(action: {
                                    selectedBodyPart = part
                                    step = 2
                                }) {
                                    VStack(spacing: 8) {
                                        Image(systemName: bodyPartIcon(part))
                                            .font(.screenTitle)
                                        Text(part)
                                            .font(.caption)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(selectedBodyPart == part ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                                    .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 400)
                }
            } else if step == 2 {
                // Step 2: Choose Exercise
                VStack(spacing: 16) {
                    Text("Select Exercise: \(selectedBodyPart)")
                        .font(.title2)
                        .bold()

                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(exerciseLibrary[selectedBodyPart] ?? [], id: \.name) { exercise in
                                Button(action: {
                                    selectedExercise = exercise
                                    calculateAIPresets(for: exercise)
                                    step = 3
                                }) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(exercise.name)
                                                .font(.headline)
                                            Text(exercise.difficulty.rawValue)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 400)

                    Button("← Back") {
                        step = 1
                    }
                    .buttonStyle(.bordered)
                }
            } else if step == 3 {
                // Step 3: Review AI Presets
                if let exercise = selectedExercise {
                    VStack(spacing: 16) {
                        Text("AI Coaching Recommendation")
                            .font(.title2)
                            .bold()

                        VStack(alignment: .leading, spacing: 12) {
                            Text(exercise.name)
                                .font(.title3)
                                .bold()

                            Divider()

                            Text("Based on your mesocycle and training history:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Label("Sets", systemImage: "list.number")
                                Spacer()
                                Stepper("\(suggestedSets)", value: $suggestedSets, in: 1...10)
                            }

                            HStack {
                                Label("Reps", systemImage: "repeat")
                                Spacer()
                                Stepper("\(suggestedReps)", value: $suggestedReps, in: 1...30)
                            }

                            HStack {
                                Label("Weight", systemImage: "scalemass")
                                Spacer()
                                HStack {
                                    TextField("Weight", value: $suggestedWeight, format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    Text("lbs")
                                        .foregroundColor(.secondary)
                                }
                            }

                            Text(getCoachingTip())
                                .font(.caption)
                                .foregroundColor(.blue)
                                .padding()
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(12)

                        Spacer()

                        HStack {
                            Button("← Back") {
                                step = 2
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button("Add Exercise") {
                                exerciseName = exercise.name
                                muscleGroup = selectedBodyPart
                                // Add the exercise with AI presets
                                workoutManager.addExerciseWithPresets(
                                    name: exercise.name,
                                    muscleGroup: selectedBodyPart,
                                    sets: suggestedSets,
                                    reps: suggestedReps,
                                    weight: suggestedWeight
                                )
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .padding(.top)
        }
        .padding()
        .desktopSheetFrame(width: 600, height: 600)
    }

    func bodyPartIcon(_ part: String) -> String {
        switch part {
        case "Chest": return "heart.fill"
        case "Back": return "figure.strengthtraining.traditional"
        case "Shoulders": return "arrow.up.circle.fill"
        case "Biceps", "Triceps": return "figure.arms.open"
        case "Legs", "Quads", "Hamstrings", "Glutes", "Calves": return "figure.walk"
        case "Core", "Abs": return "circle.grid.cross.fill"
        default: return "figure.strengthtraining.traditional"
        }
    }

    func calculateAIPresets(for exercise: ExerciseTemplate) {
        // AI coaching based on mesocycle phase
        let phase = workoutManager.currentMesocyclePhase

        switch phase {
        case "Strength":
            suggestedReps = exercise.difficulty == .advanced ? 3 : 5
            suggestedSets = 5
        case "Hypertrophy":
            suggestedReps = 10
            suggestedSets = 4
        case "Endurance":
            suggestedReps = 15
            suggestedSets = 3
        default:
            suggestedReps = 10
            suggestedSets = 3
        }

        // Estimate weight based on exercise history
        suggestedWeight = estimateWeight(for: exercise.name)
    }

    func estimateWeight(for exerciseName: String) -> Double {
        // Look at previous workouts for this exercise
        let previousSets = workoutManager.sessions
            .flatMap { $0.exercises }
            .filter { $0.name == exerciseName }
            .flatMap { $0.sets }
            .filter { $0.completed }

        if let lastWeight = previousSets.last?.weight {
            // Progressive overload: suggest 5 lbs more than last time
            return lastWeight + 5
        }

        // Default weights for common exercises
        switch exerciseName {
        case "Barbell Bench Press": return 135
        case "Squat": return 185
        case "Deadlift": return 225
        case "Overhead Press": return 95
        case "Barbell Row": return 115
        default: return 95
        }
    }

    func getCoachingTip() -> String {
        let phase = workoutManager.currentMesocyclePhase

        switch phase {
        case "Strength":
            return "💡 Strength phase: Focus on heavy weight with low reps. Rest 3-5 minutes between sets."
        case "Hypertrophy":
            return "💡 Hypertrophy phase: Moderate weight with 8-12 reps for muscle growth. Rest 60-90 seconds."
        case "Endurance":
            return "💡 Endurance phase: Lighter weight with higher reps. Rest 30-60 seconds between sets."
        default:
            return "💡 Focus on proper form and progressive overload."
        }
    }
}

struct ExerciseTemplate {
    let name: String
    let difficulty: Difficulty

    enum Difficulty: String {
        case beginner = "Beginner"
        case intermediate = "Intermediate"
        case advanced = "Advanced"
    }
}

struct GenerateProgramSheet: View {
    @State private var weeks = 12
    @State private var daysPerWeek = 5
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workoutManager: WorkoutManager

    var body: some View {
        VStack(spacing: 20) {
            Text("Generate Workout Program")
                .font(.title2)
                .bold()

            Text("Uses your Python workout generator")
                .font(.caption)
                .foregroundColor(.secondary)

            Form {
                HStack {
                    Text("Duration (weeks)")
                    Spacer()
                    TextField("Weeks", value: $weeks, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                }

                HStack {
                    Text("Days per week")
                    Spacer()
                    TextField("Days", value: $daysPerWeek, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Generate") {
                    workoutManager.generateProgramFromPython(weeks: weeks, daysPerWeek: daysPerWeek)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .desktopSheetFrame(width: 450, height: 350)
    }
}

struct PresetButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let preset: String
    let workoutManager: WorkoutManager

    @State private var isHovering = false

    var body: some View {
        Button(action: {
            workoutManager.generateProgramWithPreset(preset: preset)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(icon)
                        .font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .bold()
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Color.gray.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue, lineWidth: 1)
            )
            .cornerRadius(12)
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Onboarding View
struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @EnvironmentObject var workoutManager: WorkoutManager
    @State private var currentStep = 0
    @State private var userName = ""
    @State private var userAge = ""
    @State private var userWeight = ""
    @State private var userHeight = ""
    @State private var experienceLevel: ExperienceLevel = .beginner
    @State private var selectedGoals: Set<TrainingGoal> = []
    @State private var availableEquipment: EquipmentLevel = .fullGym
    @State private var benchPress5RM = ""
    @State private var squat5RM = ""
    @State private var deadlift5RM = ""
    @State private var showError = false
    @State private var errorMessage = ""

    let totalSteps = 7
    @State private var hasAcceptedWaivers = false
    @State private var showMedicalDisclaimer = false

    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color.lightBlueBg, Color.lightPurpleBg, Color.lightGreenBg],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()
                .onTapGesture {
                    // Bring window to front when background is tapped
                    Platform.activate()
                }

            VStack(spacing: 0) {
                // Progress Bar
                HStack(spacing: 4) {
                    ForEach(0..<totalSteps, id: \.self) { step in
                        Rectangle()
                            .fill(step <= currentStep ? Color.brandPurple : Color.gray.opacity(0.3))
                            .frame(height: 6)
                            .cornerRadius(3)
                    }
                }
                .padding()

                // Content Area (scrolls on iPhone; fixed on the Mac window)
                VStack(spacing: 30) {
                    switch currentStep {
                    case 0:
                        WaiverStep(hasAcceptedWaivers: $hasAcceptedWaivers)
                    case 1:
                        WelcomeStep()
                    case 2:
                        BasicInfoStep(
                            userName: $userName,
                            userAge: $userAge,
                            userWeight: $userWeight,
                            userHeight: $userHeight
                        )
                    case 3:
                        GoalsStep(selectedGoals: $selectedGoals, showMedicalDisclaimer: $showMedicalDisclaimer)
                    case 4:
                        ExperienceLevelStep(experienceLevel: $experienceLevel)
                    case 5:
                        EquipmentStep(availableEquipment: $availableEquipment)
                    case 6:
                        StrengthAssessmentStep(
                            benchPress5RM: $benchPress5RM,
                            squat5RM: $squat5RM,
                            deadlift5RM: $deadlift5RM
                        )
                    default:
                        WaiverStep(hasAcceptedWaivers: $hasAcceptedWaivers)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .scrollableOnPhone()
                .frame(maxHeight: .infinity)

                // Navigation Buttons
                HStack(spacing: 16) {
                    if currentStep > 0 {
                        Button(action: {
                            withAnimation {
                                currentStep -= 1
                            }
                        }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.white.opacity(0.9))
                            .foregroundColor(.black)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.gray, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: {
                        if currentStep < totalSteps - 1 {
                            withAnimation {
                                currentStep += 1
                            }
                        } else {
                            completeOnboarding()
                        }
                    }) {
                        HStack(spacing: 12) {
                            Text(currentStep < totalSteps - 1 ? "Continue" : "Get Started")
                                .font(Platform.isDesktop ? .title2 : .headline)
                                .bold()
                            Image(systemName: currentStep < totalSteps - 1 ? "chevron.right" : "checkmark.circle.fill")
                                .font(.title2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Platform.isDesktop ? 20 : 14)
                        .padding(.horizontal)
                        .background(canContinue ? Color.brandPurple : Color.gray.opacity(0.5))
                        .foregroundColor(.black)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinue)
                }
                .padding()
            }
        }
        .desktopMinFrame(minWidth: 800, minHeight: 700)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    var canContinue: Bool {
        switch currentStep {
        case 0: return hasAcceptedWaivers
        case 1: return true
        case 2:
            let t = { (v: String) in v.trimmingCharacters(in: .whitespaces) }
            return !t(userName).isEmpty
                && Int(t(userAge)) != nil
                && Double(t(userWeight)) != nil
                && Double(t(userHeight)) != nil
        case 3: return !selectedGoals.isEmpty
        case 4: return true
        case 5: return true
        case 6: return !benchPress5RM.isEmpty && !squat5RM.isEmpty && !deadlift5RM.isEmpty
        default: return false
        }
    }

    func completeOnboarding() {
        print("🎯 completeOnboarding() called")

        // Save user profile to WorkoutManager
        guard let age = Int(userAge),
              let weight = Double(userWeight),
              let height = Double(userHeight),
              let bench = Int(benchPress5RM),
              let squat = Int(squat5RM),
              let deadlift = Int(deadlift5RM) else {
            print("❌ Failed to parse onboarding values")
            errorMessage = "Please enter valid numbers for all fields"
            showError = true
            return
        }

        print("✅ Creating user profile...")
        let profile = UserProfile(
            name: userName,
            age: age,
            weight: weight,
            height: height,
            experienceLevel: experienceLevel,
            primaryGoals: Array(selectedGoals),
            availableEquipment: availableEquipment,
            healthConditions: [],
            benchPress5RM: bench,
            squat5RM: squat,
            deadlift5RM: deadlift,
            initialWeight: weight,
            unitPreference: UserDefaults.standard.string(forKey: "unitPreference") ?? "imperial"
        )

        workoutManager.userProfile = profile
        // No instant routine any more: the Program Wizard on the dashboard
        // collects the full training preferences before generating.
        workoutManager.saveData()

        print("✅ Completing onboarding, setting hasCompletedOnboarding = true")
        hasCompletedOnboarding = true

        // Force UserDefaults to sync
        UserDefaults.standard.synchronize()
        print("✅ hasCompletedOnboarding is now: \(hasCompletedOnboarding)")
    }
}

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: Platform.isDesktop ? 40 : 24) {
            // Stick figure in deep squat with dumbbells overhead
            ZStack {
                // Stick figure in squat
                Image(systemName: "figure.strengthtraining.functional")
                    .font(.system(size: 100))
                    .foregroundColor(.brandBlue)

                // Left dumbbell (overhead - in hands)
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 35))
                    .foregroundColor(.brandPurple)
                    .offset(x: -45, y: -65)
                    .rotationEffect(.degrees(-15))

                // Right dumbbell (overhead - in hands)
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 35))
                    .foregroundColor(.brandPurple)
                    .offset(x: 45, y: -65)
                    .rotationEffect(.degrees(15))
            }
            .frame(height: 140)

            Text("Endgame Fitness")
                .font(.system(size: Platform.isDesktop ? 52 : 36, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.brandPurple, .brandBlue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "brain.head.profile",
                    title: "AI Coaching",
                    description: "Personalized workout recommendations based on your progress",
                    color: .brandPurple
                )

                FeatureRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Mesocycle Training",
                    description: "12-week periodized programs for optimal gains",
                    color: .brandBlue
                )

                FeatureRow(
                    icon: "dumbbell.fill",
                    title: "10,000+ Exercises",
                    description: "Complete wger exercise database with videos & instructions",
                    color: .brandGreen
                )

                FeatureRow(
                    icon: "calendar.badge.clock",
                    title: "Smart Tracking",
                    description: "Progress visualization with calendar heatmaps",
                    color: .brandOrange
                )
            }
            .padding()
            .background(Color.white.opacity(0.7))
            .cornerRadius(16)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.screenTitle)
                .foregroundColor(color)
                .frame(width: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .bold()
                    .foregroundColor(.black)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.black)
            }
        }
    }
}

struct WaiverStep: View {
    @Binding var hasAcceptedWaivers: Bool
    @State private var hasScrolledToBottom = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("⚖️ Important Legal Information")
                    .font(.screenTitle)
                    .bold()
                    .foregroundColor(.black)
                    .adaptiveHeading()

                Text("Please read carefully before proceeding")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Medical Disclaimer
                    WaiverSection(
                        title: "🏥 Medical Disclaimer",
                        content: """
                        WorkoutTracker and BatesAI are not medical professionals and do not provide medical advice, diagnosis, or treatment. The information and workout programs provided by this application are for educational and informational purposes only.

                        Before beginning any exercise program, you should consult with your primary care physician or other qualified healthcare provider to ensure that exercise is safe and appropriate for your individual circumstances.

                        If you experience any pain, discomfort, dizziness, or other adverse symptoms during exercise, stop immediately and consult a healthcare professional.
                        """
                    )

                    // Assumption of Risk
                    WaiverSection(
                        title: "⚠️ Assumption of Risk",
                        content: """
                        You acknowledge and agree that participation in physical exercise activities involves inherent risks, including but not limited to:

                        • Risk of serious injury or death
                        • Muscle strains, sprains, and tears
                        • Joint injuries
                        • Cardiovascular incidents
                        • Equipment-related injuries

                        You voluntarily assume all such risks and agree to participate at your own risk.
                        """
                    )

                    // Liability Waiver
                    WaiverSection(
                        title: "🛡️ Limitation of Liability",
                        content: """
                        TO THE FULLEST EXTENT PERMITTED BY LAW, BatesAI, its owners, developers, and affiliates SHALL NOT BE LIABLE for any injuries, damages, or losses of any kind arising from:

                        • Use of this application
                        • Following workout programs or recommendations
                        • Use of exercise equipment
                        • Any direct, indirect, incidental, consequential, or punitive damages

                        You release and hold harmless BatesAI and all associated parties from any and all claims, liabilities, damages, or expenses arising from your use of this application.
                        """
                    )

                    // Business Liability Waiver
                    WaiverSection(
                        title: "🏢 Business Indemnification",
                        content: """
                        You agree to indemnify and hold harmless BatesAI, its officers, directors, employees, contractors, and agents from any claims, lawsuits, damages, losses, or expenses (including attorney fees) arising from:

                        • Your use of this application
                        • Your breach of these terms
                        • Your violation of any law or rights of third parties

                        BatesAI provides this software "AS IS" without warranties of any kind, either express or implied.
                        """
                    )

                    // Acknowledgment
                    WaiverSection(
                        title: "✅ Your Acknowledgment",
                        content: """
                        By checking the box below, you acknowledge that:

                        • You have read and understood all waivers and disclaimers
                        • You have been advised to consult with a physician before starting any exercise program
                        • You voluntarily assume all risks associated with physical exercise
                        • You release BatesAI from all liability
                        • You are of legal age to enter into this agreement
                        • This agreement is legally binding
                        """
                    )

                    Spacer()
                        .frame(height: 20)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geometry.frame(in: .named("scroll")).minY
                            )
                        })
                }
                .padding()
            }
            .coordinateSpace(name: "scroll")
            .frame(maxHeight: Platform.isDesktop ? 400 : 320)
            .background(Color.white.opacity(0.9))
            .cornerRadius(12)
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                hasScrolledToBottom = value < 50
            }

            Toggle(isOn: $hasAcceptedWaivers) {
                Text("I have read and agree to all terms, waivers, and disclaimers above")
                    .font(Platform.isDesktop ? .headline : .subheadline)
                    .foregroundColor(.black)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .padding()
            .background(hasAcceptedWaivers ? Color.brandGreen.opacity(0.2) : Color.white.opacity(0.5))
            .cornerRadius(12)
        }
        .padding()
    }
}

struct WaiverSection: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3)
                .bold()
                .foregroundColor(.black)

            Text(content)
                .font(.body)
                .foregroundColor(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct BasicInfoStep: View {
    @Binding var userName: String
    @Binding var userAge: String
    @Binding var userWeight: String
    @Binding var userHeight: String

    @FocusState private var focusedField: Field?
    @AppStorage("unitPreference") private var unitPreference = "imperial"

    enum Field { case name, age, weight }

    // Canonical storage is ALWAYS pounds + inches (userWeight/userHeight),
    // so nothing downstream changes. Metric mode just converts at the edge.
    private var weightKgBinding: Binding<String> {
        Binding(
            get: {
                guard let lb = Double(userWeight) else { return "" }
                let kg = lb / 2.20462
                return kg == kg.rounded() ? String(Int(kg)) : String(format: "%.1f", kg)
            },
            set: { newValue in
                let cleaned = String(newValue.filter { $0.isNumber || $0 == "." }.prefix(6))
                if let kg = Double(cleaned) {
                    userWeight = String(format: "%.1f", kg * 2.20462)
                } else if cleaned.isEmpty {
                    userWeight = ""
                }
            }
        )
    }
    private var heightCmBinding: Binding<Int> {
        Binding(
            get: { Int(((Double(userHeight) ?? 68) * 2.54).rounded()) },
            set: { userHeight = String(Int((Double($0) / 2.54).rounded())) }
        )
    }

    // Height is entered as feet + inches (no one thinks in total inches);
    // the parent still stores plain inches in userHeight, so nothing
    // downstream changes.
    private var feetBinding: Binding<Int> {
        Binding(
            get: { Int(Double(userHeight) ?? 68) / 12 },
            set: { userHeight = String($0 * 12 + Int(Double(userHeight) ?? 68) % 12) }
        )
    }
    private var inchesBinding: Binding<Int> {
        Binding(
            get: { Int(Double(userHeight) ?? 68) % 12 },
            set: { userHeight = String((Int(Double(userHeight) ?? 68) / 12) * 12 + $0) }
        )
    }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.brandPurple)
                Text("Tell us about yourself")
                    .font(.screenTitle.bold())
                    .adaptiveHeading()
                Text("Four quick answers to calibrate your programs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                Picker("Units", selection: $unitPreference) {
                    Text("Imperial").tag("imperial")
                    Text("Metric").tag("metric")
                }
                .compactSegmentedPicker()
                .labelsHidden()
                .frame(maxWidth: 240)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.headline)
                    TextField("Your name", text: $userName)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .focused($focusedField, equals: .name)
                        .onSubmit { focusedField = .age }
                }

                AdaptiveHStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Age").font(.headline)
                        TextField("34", text: $userAge)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .frame(width: 90)
                            .focused($focusedField, equals: .age)
                            .onSubmit { focusedField = .weight }
                            .onChange(of: userAge) { v in
                                userAge = String(v.filter(\.isNumber).prefix(3))
                            }
                    }

                    if unitPreference == "metric" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Weight (kg)").font(.headline)
                            TextField("84", text: weightKgBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.title3)
                                .frame(width: 110)
                                .focused($focusedField, equals: .weight)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Height (cm)").font(.headline)
                            Picker("", selection: heightCmBinding) {
                                ForEach(120...220, id: \.self) { Text("\($0) cm").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Weight (lb)").font(.headline)
                            TextField("185", text: $userWeight)
                                .textFieldStyle(.roundedBorder)
                                .font(.title3)
                                .frame(width: 110)
                                .focused($focusedField, equals: .weight)
                                .onChange(of: userWeight) { v in
                                    userWeight = String(v.filter { $0.isNumber || $0 == "." }.prefix(6))
                                }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Height").font(.headline)
                            HStack(spacing: 8) {
                                Picker("", selection: feetBinding) {
                                    ForEach(3...7, id: \.self) { Text("\($0) ft").tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 90)
                                Picker("", selection: inchesBinding) {
                                    ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 90)
                            }
                        }
                    }
                }
            }
            .adaptivePadding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 560)
        }
        .padding()
        .onAppear {
            Platform.activate()
            if userHeight.isEmpty { userHeight = "68" }   // sensible default; pickers can't be blank
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusedField = .name
            }
        }
    }
}

// Retained for macOS only: superseded by PlatformTextField, which works on both platforms.
#if os(macOS)
// MARK: - MacTextField (AppKit wrapper for guaranteed keyboard input)
struct MacTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.delegate = context.coordinator
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.isEditable = true
        textField.isEnabled = true
        textField.isBezeled = true
        textField.drawsBackground = true
        textField.backgroundColor = NSColor.textBackgroundColor

        // Make sure it can become first responder
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacTextField

        init(_ parent: MacTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }
    }
}
#endif

struct FormField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            TextField(placeholder, text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.title3)
                .padding(4)
        }
    }
}

struct GoalsStep: View {
    @Binding var selectedGoals: Set<TrainingGoal>
    @Binding var showMedicalDisclaimer: Bool

    let goals: [(TrainingGoal, String, String, String, Color)] = [
        (.buildMuscle, "figure.strengthtraining.traditional", "Build Muscle", "Add size with hypertrophy work", .brandPurple),
        (.getStronger, "bolt.fill", "Get Stronger", "Push your big-lift numbers up", .brandBlue),
        (.loseWeight, "flame.fill", "Lose Weight", "Burn fat, keep your muscle", .brandOrange),
        (.improveEndurance, "figure.run", "Improve Endurance", "Build stamina and work capacity", .brandGreen),
        (.increaseFlexibility, "figure.flexibility", "Increase Flexibility", "Move better, stretch further", .brandYellow),
        (.generalFitness, "target", "General Fitness", "A balanced all-round program", .gray),
        (.longevity, "heart.text.square", "Longevity", "Train to stay strong, mobile and healthy for decades", .brandGreen)
    ]

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 8) {
                Text("What Are Your Goals?")
                    .font(.screenTitle)
                    .bold()
                    .foregroundColor(.black)
                    .adaptiveHeading()

                Text("Select all that apply")
                    .font(.subheadline)
                    .foregroundColor(.black)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 16) {
                ForEach(goals, id: \.0) { goal, symbol, name, blurb, color in
                    Button(action: {
                        if selectedGoals.contains(goal) {
                            selectedGoals.remove(goal)
                        } else {
                            selectedGoals.insert(goal)
                            // Show medical disclaimer on first goal selection
                            if selectedGoals.count == 1 {
                                showMedicalDisclaimer = true
                            }
                        }
                    }) {
                        VStack(spacing: 10) {
                            Image(systemName: symbol)
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(color)
                                .frame(height: 40)

                            Text(name)
                                .font(.headline)
                                .foregroundColor(.black)

                            Text(blurb)
                                .font(.caption)
                                .foregroundColor(.black.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            selectedGoals.contains(goal) ?
                            color.opacity(0.2) :
                            Color.white.opacity(0.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedGoals.contains(goal) ? color : Color.clear, lineWidth: 3)
                        )
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .alert("⚕️ Medical Reminder", isPresented: $showMedicalDisclaimer) {
            Button("I Understand", role: .cancel) { }
        } message: {
            Text("WorkoutTracker and BatesAI are not a substitute for medical advice. Please consult with your primary care physician and get cleared for exercise before starting any workout program.\n\nIf you have any pre-existing health conditions, injuries, or concerns, speak with a qualified healthcare provider to ensure this program is safe for you.")
        }
    }
}

struct ExperienceLevelStep: View {
    @Binding var experienceLevel: ExperienceLevel

    let levels: [(ExperienceLevel, String, String, Color)] = [
        (.beginner, "🌱", "Beginner", .brandGreen),
        (.intermediate, "💪", "Intermediate", .brandBlue),
        (.advanced, "⚡", "Advanced", .brandPurple),
        (.expert, "🏆", "Expert", .brandOrange)
    ]

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 8) {
                Text("💡 Experience Level")
                    .font(.screenTitle)
                    .bold()
                    .foregroundColor(.black)
                    .adaptiveHeading()

                Text("This helps us suggest appropriate weights and programs")
                    .font(.subheadline)
                    .foregroundColor(.black)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 16) {
                ForEach(levels, id: \.0) { level, emoji, name, color in
                    Button(action: {
                        experienceLevel = level
                    }) {
                        HStack(spacing: 16) {
                            Text(emoji)
                                .font(.system(size: 40))

                            Text(name)
                                .font(.title3)
                                .bold()
                                .foregroundColor(.black)

                            Spacer()

                            if experienceLevel == level {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(color)
                                    .font(.title2)
                            }
                        }
                        .padding()
                        .background(
                            experienceLevel == level ?
                            color.opacity(0.2) :
                            Color.white.opacity(0.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(experienceLevel == level ? color : Color.clear, lineWidth: 3)
                        )
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct EquipmentStep: View {
    @Binding var availableEquipment: EquipmentLevel

    let equipment: [(EquipmentLevel, String, String, Color)] = [
        (.fullGym, "🏋️", "Full Gym Access", .brandPurple),
        (.homeGym, "🏠", "Home Gym", .brandBlue),
        (.minimal, "💪", "Minimal Equipment", .brandGreen),
        (.bodyweight, "🤸", "Bodyweight Only", .brandOrange)
    ]

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 8) {
                Text("🏋️ Available Equipment")
                    .font(.screenTitle)
                    .bold()
                    .foregroundColor(.black)
                    .adaptiveHeading()

                Text("We'll customize exercises for your setup")
                    .font(.subheadline)
                    .foregroundColor(.black)
            }

            VStack(spacing: 16) {
                ForEach(equipment, id: \.0) { level, emoji, name, color in
                    Button(action: {
                        availableEquipment = level
                    }) {
                        HStack(spacing: 16) {
                            Text(emoji)
                                .font(.system(size: 40))

                            Text(name)
                                .font(.title3)
                                .bold()
                                .foregroundColor(.black)

                            Spacer()

                            if availableEquipment == level {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(color)
                                    .font(.title2)
                            }
                        }
                        .padding()
                        .background(
                            availableEquipment == level ?
                            color.opacity(0.2) :
                            Color.white.opacity(0.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(availableEquipment == level ? color : Color.clear, lineWidth: 3)
                        )
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct StrengthAssessmentStep: View {
    @Binding var benchPress5RM: String
    @Binding var squat5RM: String
    @Binding var deadlift5RM: String

    @FocusState private var focusedField: Field?
    @AppStorage("unitPreference") private var unitPreference = "imperial"

    enum Field {
        case bench, squat, deadlift
    }

    private var isMetric: Bool { unitPreference == "metric" }

    // Canonical storage stays pounds; metric mode converts at the edge.
    private func unitBinding(_ lb: Binding<String>) -> Binding<String> {
        guard isMetric else { return lb }
        return Binding(
            get: {
                guard let v = Double(lb.wrappedValue) else { return "" }
                return String(Int((v / 2.20462).rounded()))
            },
            set: { newValue in
                let cleaned = String(newValue.filter(\.isNumber).prefix(4))
                if let kg = Double(cleaned) {
                    lb.wrappedValue = String(Int((kg * 2.20462).rounded()))
                } else if cleaned.isEmpty {
                    lb.wrappedValue = ""
                }
            }
        )
    }

    private func placeholder(_ lbExample: Int) -> String {
        isMetric ? "Weight in kg (e.g., \(Int((Double(lbExample) / 2.20462).rounded())))"
                 : "Weight in lbs (e.g., \(lbExample))"
    }

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 8) {
                Text("💪 Strength Assessment")
                    .font(.screenTitle)
                    .bold()
                    .foregroundColor(.black)
                    .adaptiveHeading()

                Text("Help us calibrate your program")
                    .font(.subheadline)
                    .foregroundColor(.black)
            }

            VStack(alignment: .leading, spacing: 24) {
                Text("What weight can you lift for 5 reps?")
                    .font(.headline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .foregroundColor(.brandBlue)
                        Text("Bench Press (5RM)")
                            .font(.headline)
                            .foregroundColor(.black)
                    }
                    TextField(placeholder(185), text: unitBinding($benchPress5RM))
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundColor(.black)
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray, lineWidth: 2)
                        )
                        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .frame(maxWidth: 400)
                        .focused($focusedField, equals: .bench)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .foregroundColor(.brandGreen)
                        Text("Squat (5RM)")
                            .font(.headline)
                            .foregroundColor(.black)
                    }
                    TextField(placeholder(225), text: unitBinding($squat5RM))
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundColor(.black)
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray, lineWidth: 2)
                        )
                        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .frame(maxWidth: 400)
                        .focused($focusedField, equals: .squat)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .foregroundColor(.brandOrange)
                        Text("Deadlift (5RM)")
                            .font(.headline)
                            .foregroundColor(.black)
                    }
                    TextField(placeholder(275), text: unitBinding($deadlift5RM))
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundColor(.black)
                        .padding(12)
                        .background(Color.white)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray, lineWidth: 2)
                        )
                        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                        .frame(maxWidth: 400)
                        .focused($focusedField, equals: .deadlift)
                }

                Text("💡 Don't know? Just estimate - we'll adjust as you progress")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .adaptivePadding(30)
            .background(Color.white.opacity(0.9))
            .cornerRadius(16)
        }
        .padding()
        .onAppear {
            Platform.activate()
            #if os(macOS)
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(window.contentView)
                }
            }
            #endif

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusedField = .bench
            }
        }
    }
}

// MARK: - User Data Models
enum TrainingGoal: String, Hashable, Codable {
    case buildMuscle = "Build Muscle"
    case getStronger = "Get Stronger"
    case loseWeight = "Lose Weight"
    case improveEndurance = "Improve Endurance"
    case increaseFlexibility = "Increase Flexibility"
    case generalFitness = "General Fitness"
    case longevity = "Longevity"
}

enum ExperienceLevel: String, Codable {
    case beginner = "Beginner"
    case intermediate = "Intermediate"
    case advanced = "Advanced"
    case expert = "Expert"
}

enum EquipmentLevel: String, Codable {
    case fullGym = "Full Gym"
    case homeGym = "Home Gym"
    case minimal = "Minimal"
    case bodyweight = "Bodyweight"
}

struct UserProfile: Codable {
    var name: String
    var age: Int
    var weight: Double
    var height: Double
    var experienceLevel: ExperienceLevel
    var primaryGoals: [TrainingGoal]
    var availableEquipment: EquipmentLevel
    var healthConditions: [String]
    var benchPress5RM: Int
    var squat5RM: Int
    var deadlift5RM: Int
    var initialWeight: Double?
    var level: Int = 1
    var currentXP: Int = 0
    // "imperial" or "metric"; optional so older saved profiles still decode.
    var unitPreference: String? = nil
}

struct ScheduledWorkout: Identifiable, Codable {
    let id = UUID()
    var dayOfWeek: String
    var workoutType: String
    var exercises: [String]
    var estimatedDuration: Int // minutes
    var completed: Bool = false
    var date: Date?
}
