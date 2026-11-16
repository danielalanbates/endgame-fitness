//
//  WorkoutTracker - Enhanced Implementation
//  The app entry point, WorkoutManager (the training log's state) and most of
//  the app's screens. The data model lives in TrainingModels.swift, storage in
//  WorkoutStore.swift, sync in TrainingSync.swift.
//

import SwiftUI
import Foundation
import Combine
import Charts
import UniformTypeIdentifiers

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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // `-ef.selftest`: check the local game engine, print PASS/FAIL, exit.
        EngineSelfTest.runIfRequested()
        // Before RootView's first sync, so pulled history and account changes
        // have somewhere to go.
        WorkoutManager.shared.installSyncHooks()
    }

    var body: some Scene {
        WindowGroup {
            RootView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .environmentObject(workoutManager)
                .onAppear { Platform.activate() }
                .onChange(of: scenePhase) { _, phase in
                    // iOS may end the process any time after this.
                    if phase != .active { workoutManager.flushActiveWorkout() }
                }
        }
        #if os(macOS)
        .windowStyle(DefaultWindowStyle())
        .defaultPosition(.center)
        #endif
        .commands {
            CommandGroup(replacing: .newItem) {
                // Never silently replaces a workout in progress: the Workout
                // tab asks first.
                Button("New Workout Session") {
                    workoutManager.requestNewWorkout()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            #if os(macOS)
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
            #endif
        }
    }
}

// MARK: - Program Models (device-wide placeholders)

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

    /// Finished workouts for the signed-in account, oldest first.
    @Published var sessions: [WorkoutSession] = []
    @Published var programs: [WorkoutProgram] = []
    /// The workout in progress. Saved to disk shortly after every change and
    /// whenever the app leaves the foreground, and restored at launch.
    @Published var currentWorkout: WorkoutSession? {
        didSet { scheduleActiveSave() }
    }
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
    /// A new workout was requested while one is in progress. The Workout tab
    /// asks whether to resume or discard; nothing is replaced silently.
    @Published var pendingStart: PendingStart?
    /// A storage problem worth telling the lifter about (history restored from
    /// a backup, an unreadable file set aside). Cleared when dismissed.
    @Published var storeIssue: String?
    /// Deleted workout id (lower-cased) -> the revision of the delete, so a
    /// pulled copy of a deleted workout never comes back.
    var tombstones: [String: Int] = [:]

    enum PendingStart: Identifiable {
        case empty
        case scheduled(ScheduledWorkout)

        var id: String {
            switch self {
            case .empty: return "empty"
            case .scheduled(let s): return "scheduled-\(s.id)"
            }
        }

        var title: String {
            switch self {
            case .empty: return "a new workout"
            case .scheduled(let s): return s.workoutType
            }
        }
    }

    var authObserver: AnyCancellable?
    private var activeSaveWork: DispatchWorkItem?
    private var isApplyingSnapshot = false

    /// Sessions that hold completed work. Stats, streaks and charts read this;
    /// empty sessions saved by older builds are ignored.
    var loggedSessions: [WorkoutSession] { sessions.filter(\.hasCompletedWork) }

    var currentStreak: Int {
        calculateStreak()
    }

    var todaysWorkouts: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return loggedSessions.filter { Calendar.current.isDate($0.date, inSameDayAs: today) }.count
    }

    var weeklyWorkouts: Int {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return loggedSessions.filter { $0.date >= weekAgo }.count
    }

    private init() {
        TrainingUnits.migrateLegacySetting()
        loadData()
        loadDefaultPrograms()
        loadModulations()
    }

    func loadData() {
        applySnapshot(WorkoutStore.shared.load(WorkoutStore.shared.accountKey))
        programs = WorkoutStore.shared.loadPrograms()
        loadScheduleState()
    }

    /// Replaces the in-memory log with a freshly loaded account store.
    func applySnapshot(_ snapshot: WorkoutStore.Snapshot) {
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        activeSaveWork?.cancel()
        sessions = snapshot.sessions.map { session in
            var session = session
            for i in session.exercises.indices { Self.attachLibraryMatch(&session.exercises[i]) }
            return session
        }
        .sorted { $0.date < $1.date }
        tombstones = snapshot.tombstones
        currentWorkout = snapshot.activeWorkout
        isWorkoutActive = snapshot.activeWorkout != nil
        storeIssue = snapshot.issue
        if let workout = snapshot.activeWorkout {
            SessionGame.shared.resume(with: workout, history: sessions)
        } else {
            SessionGame.shared.sessionStarted()
        }
    }

    func loadModulations() {
        repRangeModulation = UserDefaults.standard.double(forKey: "repRangeModulation") != 0 ? UserDefaults.standard.double(forKey: "repRangeModulation") : 50.0
        volumeIntensityModulation = UserDefaults.standard.double(forKey: "volumeIntensityModulation") != 0 ? UserDefaults.standard.double(forKey: "volumeIntensityModulation") : 50.0
        frequencyModulation = UserDefaults.standard.double(forKey: "frequencyModulation") != 0 ? UserDefaults.standard.double(forKey: "frequencyModulation") : 50.0
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
        saveSessionsNow()
        WorkoutStore.shared.savePrograms(programs)
        saveScheduleState()
    }

    /// Writes history (atomically, with backups) for the active account.
    func saveSessionsNow() {
        WorkoutStore.shared.saveSessions(sessions, tombstones: tombstones)
    }

    // MARK: Active workout persistence

    private func scheduleActiveSave() {
        guard !isApplyingSnapshot else { return }
        activeSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            WorkoutStore.shared.saveActiveWorkout(self.currentWorkout)
        }
        activeSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Saves the in-progress workout now (app going to the background).
    func flushActiveWorkout() {
        activeSaveWork?.cancel()
        activeSaveWork = nil
        WorkoutStore.shared.saveActiveWorkout(currentWorkout)
    }

    // MARK: Starting, logging and finishing

    /// Cmd-N and the "Start Workout" buttons. Asks first if a workout is
    /// already in progress.
    func requestNewWorkout() { requestStart(.empty) }

    func requestStart(_ start: PendingStart) {
        if isWorkoutActive, currentWorkout != nil {
            selectedTab = 1
            pendingStart = start
            return
        }
        perform(start)
    }

    /// Starts without asking. Only call after the lifter confirmed.
    func perform(_ start: PendingStart) {
        pendingStart = nil
        switch start {
        case .empty:
            beginWorkout(named: nil, exercises: [])
        case .scheduled(let scheduled):
            let history = loggedSessions
            let exercises = scheduled.plannedExercises.map { makeExercise(from: $0, history: history) }
            beginWorkout(named: scheduled.workoutType, exercises: exercises)
        }
    }

    func startNewWorkout() { requestStart(.empty) }

    func startScheduledWorkout(_ scheduledWorkout: ScheduledWorkout) {
        requestStart(.scheduled(scheduledWorkout))
    }

    private func beginWorkout(named name: String?, exercises: [Exercise]) {
        currentWorkout = WorkoutSession(date: Date(), programName: name, exercises: exercises, completed: false)
        isWorkoutActive = true
        selectedTab = 1
        SessionGame.shared.sessionStarted() // SessionGameLayer hook
        flushActiveWorkout()
    }

    /// A program exercise with its prescription and planned rows.
    func makeExercise(from plan: PlannedExercise, history: [WorkoutSession]) -> Exercise {
        var exercise = Exercise(name: plan.name, targetSets: plan.sets, targetRepMin: plan.repMin,
                                targetRepMax: plan.repMax, targetSeconds: plan.seconds, targetLoadLb: plan.loadLb)
        Self.attachLibraryMatch(&exercise)
        exercise.tracking = exercise.resolvedTracking
        exercise.sets = ProgressionEngine.plannedSets(for: exercise, history: history)
        return exercise
    }

    /// Adds an exercise from the library (or a custom name) to the workout in
    /// progress, with planned rows from history when there is any.
    func addExercise(_ entry: LibraryExercise?, customName: String? = nil) {
        guard currentWorkout != nil else { return }
        let name = entry?.name ?? customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return }
        var exercise = Exercise(name: name, exerciseID: entry?.id, category: entry?.category,
                                primaryMuscles: entry?.primary)
        if entry == nil { Self.attachLibraryMatch(&exercise) }
        exercise.tracking = exercise.resolvedTracking
        exercise.sets = ProgressionEngine.plannedSets(for: exercise, history: loggedSessions)
        currentWorkout?.exercises.append(exercise)
    }

    func removeExercise(_ exerciseID: UUID) {
        currentWorkout?.exercises.removeAll { $0.id == exerciseID }
        if let workout = currentWorkout { SessionGame.shared.recalculate(for: workout, history: loggedSessions) }
    }

    func moveExercise(_ exerciseID: UUID, by offset: Int) {
        guard var workout = currentWorkout, let i = workout.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        let j = i + offset
        guard workout.exercises.indices.contains(j) else { return }
        workout.exercises.swapAt(i, j)
        currentWorkout = workout
    }

    /// Replaces one exercise of the workout in progress (field edits).
    func updateExercise(_ exercise: Exercise) {
        guard let i = currentWorkout?.exercises.firstIndex(where: { $0.id == exercise.id }),
              let before = currentWorkout?.exercises[i] else { return }
        currentWorkout?.exercises[i] = exercise
        // A completed set was deleted: the running XP estimate must drop too.
        if exercise.completedSets.count < before.completedSets.count, let workout = currentWorkout {
            SessionGame.shared.recalculate(for: workout, history: loggedSessions)
        }
    }

    /// The check button. Returns false when the set is missing reps/load (or a
    /// duration) and so cannot be ticked.
    @discardableResult
    func toggleSetCompleted(exerciseID: UUID, setID: UUID) -> Bool {
        guard var workout = currentWorkout,
              let ei = workout.exercises.firstIndex(where: { $0.id == exerciseID }),
              let si = workout.exercises[ei].sets.firstIndex(where: { $0.id == setID }) else { return false }
        var set = workout.exercises[ei].sets[si]
        if set.completed {
            set.completed = false
            set.completedAt = nil
        } else {
            guard set.isLoggable(as: workout.exercises[ei].resolvedTracking) else { return false }
            set.completed = true
            set.completedAt = Date()
        }
        workout.exercises[ei].sets[si] = set
        currentWorkout = workout

        // SessionGameLayer hook: XP pop-up, combo/PR detection, rest timer.
        if set.completed {
            SessionGame.shared.setLogged(set, in: workout.exercises[ei], workout: workout, history: loggedSessions)
            let partyName = workout.exercises[ei].name
            MainActor.assumeIsolated { GymParty.shared.setLogged(weight: set.weight, reps: set.reps, exercise: partyName) }
        } else {
            SessionGame.shared.recalculate(for: workout, history: loggedSessions)
        }
        return true
    }

    /// "+ Add Set": a planned row copying the last row's numbers.
    func addSet(to exerciseID: UUID) {
        guard let ei = currentWorkout?.exercises.firstIndex(where: { $0.id == exerciseID }),
              let exercise = currentWorkout?.exercises[ei] else { return }
        let last = exercise.sets.last
        let set = ExerciseSet(reps: last?.reps ?? exercise.targetRepMin ?? 0,
                              weight: last?.weight ?? 0,
                              durationSecs: last?.durationSecs ?? exercise.targetSeconds)
        currentWorkout?.exercises[ei].sets.append(set)
    }

    func deleteSet(exerciseID: UUID, setID: UUID) {
        guard let ei = currentWorkout?.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
        currentWorkout?.exercises[ei].sets.removeAll { $0.id == setID }
        if let workout = currentWorkout { SessionGame.shared.recalculate(for: workout, history: loggedSessions) }
    }

    /// Throws the workout in progress away (after the lifter confirmed).
    func discardWorkout() {
        currentWorkout = nil
        isWorkoutActive = false
        SessionGame.shared.sessionStarted()
        flushActiveWorkout()
    }

    /// Completed sets in the workout in progress.
    var currentCompletedSetCount: Int { currentWorkout?.completedSetCount ?? 0 }

    /// Saves the workout in progress to history. Only completed sets are kept;
    /// returns false (and saves nothing) when no set was completed — the
    /// caller offers to discard instead.
    @discardableResult
    func completeWorkout() -> Bool {
        guard var workout = currentWorkout else { return false }
        workout.exercises = workout.exercises.compactMap { exercise in
            var exercise = exercise
            exercise.sets = exercise.sets.filter(\.completed)
            return exercise.sets.isEmpty ? nil : exercise
        }
        guard !workout.exercises.isEmpty else { return false }

        workout.completed = true
        if workout.duration == nil { workout.duration = Self.duration(of: workout) }
        workout.clientRev = max(workout.clientRev, 0) + 1
        workout.updatedAt = Date()

        sessions.append(workout)
        sessions.sort { $0.date < $1.date }
        currentWorkout = nil
        isWorkoutActive = false
        flushActiveWorkout()
        saveData()

        // Hand the session to the game layer. The server decides the actual
        // XP award; this just reports what happened.
        uploadSession(workout)
        let start = workout.date
        let seconds = Int(workout.duration ?? 0)
        let name = workout.displayName
        Task { @MainActor in
            // Mirror the session into Apple Health (iOS only; no-op on macOS
            // and whenever the Settings toggle is off).
            HealthKitManager.shared.saveStrengthWorkout(start: start, durationSecs: seconds, name: name)
        }
        return true
    }

    /// Start to the last completed set (plus a minute), so a workout restored
    /// hours after the app was closed doesn't claim the whole gap. Capped at
    /// six hours, the server's limit.
    static func duration(of workout: WorkoutSession) -> TimeInterval {
        let lastSet = workout.exercises.flatMap(\.sets).compactMap(\.completedAt).max()
        let end = lastSet.map { $0.addingTimeInterval(60) } ?? Date()
        return min(max(end.timeIntervalSince(workout.date), 60), 6 * 3600)
    }

    // MARK: Editing history

    /// Saves an edited past workout and re-queues it with the next revision.
    func updateSession(_ edited: WorkoutSession) {
        guard let i = sessions.firstIndex(where: { $0.id == edited.id }) else { return }
        var session = edited
        session.exercises = session.exercises.compactMap { exercise in
            var exercise = exercise
            exercise.sets = exercise.sets.filter(\.completed)
            return exercise.sets.isEmpty ? nil : exercise
        }
        // At least 2: sessions saved by older builds have no local revision but
        // were uploaded as revision 1, and the server ignores a same-revision replay.
        session.clientRev = max(sessions[i].clientRev, session.clientRev, 1) + 1
        session.updatedAt = Date()
        sessions[i] = session
        sessions.sort { $0.date < $1.date }
        saveSessionsNow()
        uploadSession(session)
    }

    /// Deletes a past workout here and, through sync, everywhere else.
    func deleteSession(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[i]
        session.clientRev = max(session.clientRev, 1) + 1
        session.updatedAt = Date()
        sessions.remove(at: i)
        tombstones[session.syncID.lowercased()] = session.clientRev
        saveSessionsNow()
        uploadDeletion(of: session)
    }

    func quickLogWorkout() {
        requestStart(.empty)
    }

    func showTodayProgress() {
        selectedTab = 3
    }

    /// Consecutive days with a logged workout, ending today (or yesterday, so
    /// the streak doesn't read 0 before today's session).
    func calculateStreak() -> Int {
        let calendar = Calendar.current
        let days = Set(loggedSessions.map { calendar.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
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
        if config.scheduleMode == .rolling {
            days = (1...max(1, config.daysOn)).map { "Day \($0)" }
        }

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

            var exercises = Self.generateExercises(for: group, duration: config.sessionLength, focus: focus)
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
        d.set(config.experienceLevel.rawValue, forKey: "progressionExperience")
        d.set(config.primaryGoal.rawValue, forKey: "progressionGoal")
        d.set(Date().timeIntervalSince1970, forKey: "programStartDate")
        d.set(config.scheduleMode.rawValue, forKey: "scheduleMode")
        d.set(config.daysOn, forKey: "cycleDaysOn")
        d.set(config.daysOff, forKey: "cycleDaysOff")
        d.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: "cycleStartDay")

        saveData()
    }

    /// Rolling "X on / Y off" programs: which training day (0-based) `date`
    /// falls on, or nil for a rest day. Pure, so the selftest can check it.
    static func rollingSlot(on date: Date, start: Date, daysOn: Int, daysOff: Int,
                            calendar: Calendar = .current) -> Int? {
        let cycle = max(1, daysOn + daysOff)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let idx = ((days % cycle) + cycle) % cycle
        return idx < daysOn ? idx : nil
    }

    /// Today's planned session for either schedule mode.
    func scheduledWorkout(for date: Date = Date()) -> ScheduledWorkout? {
        let d = UserDefaults.standard
        if d.string(forKey: "scheduleMode") == ScheduleMode.rolling.rawValue {
            let start = Date(timeIntervalSince1970: d.double(forKey: "cycleStartDay"))
            guard let slot = Self.rollingSlot(on: date, start: start,
                                              daysOn: d.integer(forKey: "cycleDaysOn"),
                                              daysOff: d.integer(forKey: "cycleDaysOff")) else { return nil }
            return weeklySchedule.first { $0.dayOfWeek == "Day \(slot + 1)" }
        }
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let today = dayNames[Calendar.current.component(.weekday, from: date) - 1]
        return weeklySchedule.first { $0.dayOfWeek == today }
    }

    func resolvedSplit(for config: ProgramConfig) -> ProgramSplit {
        guard config.split == .auto else { return config.split }
        let perWeek = config.effectiveDaysPerWeek
        if config.primaryGoal == .longevity && perWeek <= 4 { return .fullBody }
        switch perWeek {
        case ..<4:
            let strengthy = config.primaryGoal == .getStronger || config.primaryGoal == .buildMuscle
            return (perWeek == 3 && strengthy && config.experienceLevel != .beginner) ? .ppl : .fullBody
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

    // Build a weekly plan from the quick-builder answers (fixed templates).
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
                ScheduledWorkout(dayOfWeek: "", workoutType: "Full Body A",
                                exercises: Self.generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Full Body B",
                                exercises: Self.generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (3, "Strength"), (3, "Muscle Building"):
            // 3 days = Push/Pull/Legs
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "Push Day",
                                exercises: Self.generateExercises(for: "Push", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Pull Day",
                                exercises: Self.generateExercises(for: "Pull", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Leg Day",
                                exercises: Self.generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (3, _):
            // 3 days fat loss/fitness = Full body
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "Full Body Strength",
                                exercises: Self.generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Full Body Power",
                                exercises: Self.generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Full Body Conditioning",
                                exercises: Self.generateExercises(for: "Full Body", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (4, _):
            // 4 days = Upper/Lower split
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "Upper Body A",
                                exercises: Self.generateExercises(for: "Upper", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Lower Body A",
                                exercises: Self.generateExercises(for: "Lower", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Upper Body B",
                                exercises: Self.generateExercises(for: "Upper", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Lower Body B",
                                exercises: Self.generateExercises(for: "Lower", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (5, _):
            // 5 days = Bro split (body part per day)
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "Chest Day",
                                exercises: Self.generateExercises(for: "Chest", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Back Day",
                                exercises: Self.generateExercises(for: "Back", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Leg Day",
                                exercises: Self.generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Shoulders Day",
                                exercises: Self.generateExercises(for: "Shoulders", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Arms Day",
                                exercises: Self.generateExercises(for: "Arms", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration)
            ]

        case (6, _):
            // 6 days = PPL x2
            baseWorkouts = [
                ScheduledWorkout(dayOfWeek: "", workoutType: "Push Day 1",
                                exercises: Self.generateExercises(for: "Push", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Pull Day 1",
                                exercises: Self.generateExercises(for: "Pull", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Leg Day 1",
                                exercises: Self.generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Push Day 2",
                                exercises: Self.generateExercises(for: "Push", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Pull Day 2",
                                exercises: Self.generateExercises(for: "Pull", duration: sessionDuration, focus: primaryFocus),
                                estimatedDuration: sessionDuration),
                ScheduledWorkout(dayOfWeek: "", workoutType: "Leg Day 2",
                                exercises: Self.generateExercises(for: "Legs", duration: sessionDuration, focus: primaryFocus),
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

    /// Template exercise selection by muscle group, session length and focus.
    /// Scales from 15 to 120 minutes: more exercises, then extra sets, then
    /// finishers once the pool for that group runs out.
    static func generateExercises(for muscleGroup: String, duration: Int, focus: String) -> [String] {
        let minutes = min(120, max(15, duration))
        // ~15 min per exercise including warm-up sets and rest.
        let exerciseCount = max(2, (minutes + 15) / 15)

        // Base set/rep scheme by focus.
        var (sets, reps): (Int, String)
        switch focus.lowercased() {
        case "strength":
            (sets, reps) = (5, "5")    // Heavy weight, low reps
        case "muscle building", "hypertrophy":
            (sets, reps) = (4, "10")   // Moderate weight, moderate reps
        case "fat loss":
            (sets, reps) = (3, "15")   // Circuit-style, higher reps
        case "endurance":
            (sets, reps) = (3, "20")   // Light weight, high reps
        default:
            (sets, reps) = (3, "12")
        }
        // Long sessions add a set per 30 min past an hour; very short ones drop one.
        if minutes > 60 { sets += (minutes - 60) / 30 }
        if minutes < 30 { sets = max(2, sets - 1) }
        let setRepScheme = " \(sets)x\(reps)"
        
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
        
        var result = Array(exercises.prefix(exerciseCount)).map { $0 + setRepScheme }
        // Pool ran out on a long session: fill with finishers.
        let finishers = ["Core Circuit 3x45s", "Farmer's Carry 3x40m", "Mobility Flow 10 min", "Zone 2 Cardio 15 min"]
        for f in finishers where result.count < exerciseCount { result.append(f) }
        return result
    }


    /// The full history as this app's JSON export (ISO 8601 dates).
    func exportData() -> Data? {
        WorkoutStore.exportData(sessions)
    }

    /// macOS: writes the export through a save panel. iOS presents
    /// `.fileExporter` from Settings instead (see SettingsView).
    @discardableResult
    func exportWorkouts() -> URL? {
        guard let data = exportData() else { return nil }
        return WorkoutTransfer.exportJSON(data, suggestedName: "endgame-fitness-workouts.json")
    }

    /// macOS: picks a file with an open panel. iOS uses `.fileImporter`.
    func importWorkouts() {
        guard let data = WorkoutTransfer.importJSON() else { return }
        importWorkouts(from: data)
    }

    /// Merges sessions from an export. Existing ids win, so importing the same
    /// file twice doesn't duplicate history. Imported workouts stay on this
    /// device (they are not uploaded, so old sessions earn no XP). Returns how
    /// many were added, or nil if the file was not a workout export.
    @discardableResult
    func importWorkouts(from data: Data) -> Int? {
        guard let imported = WorkoutStore.importSessions(from: data) else { return nil }
        let knownIDs = Set(sessions.map(\.id))
        let fresh = imported.filter { !knownIDs.contains($0.id) && !tombstones.keys.contains($0.syncID.lowercased()) }
            .map { session -> WorkoutSession in
                var session = session
                for i in session.exercises.indices { Self.attachLibraryMatch(&session.exercises[i]) }
                return session
            }
        sessions.append(contentsOf: fresh)
        sessions.sort { $0.date < $1.date }
        saveSessionsNow()
        return fresh.count
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

    // Mesocycle phase from logged sessions
    var currentMesocyclePhase: String {
        // Determine phase based on workout count in current cycle
        let cycleLength = 12 // 12-week mesocycle
        let workoutCount = loggedSessions.count
        let weekInCycle = (workoutCount / 3) % cycleLength // Assuming 3 workouts per week

        if weekInCycle < 4 {
            return "Hypertrophy"
        } else if weekInCycle < 8 {
            return "Strength"
        } else {
            return "Endurance"
        }
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
            SocialTabView()
                .tabItem { Label("Social", systemImage: "person.2.wave.2.fill") }
                .tag(8)
            TrainingProgressView()
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
                title: "Social",
                icon: "person.2.wave.2.fill",
                isSelected: workoutManager.selectedTab == 8
            ) {
                workoutManager.selectedTab = 8
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
                TrainingProgressView()
            case 4:
                MesocycleView()
            case 5:
                ToolsView()
            case 6:
                SettingsView()
            case 7:
                CommunityView()
            case 8:
                SocialTabView()
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
    @AppStorage("weeklyGoal") private var weeklyGoal = 5
    @State private var showProgramWizard = false

    private var todaysScheduledWorkout: ScheduledWorkout? {
        workoutManager.scheduledWorkout()
    }

    // First login: nothing trained, no program built yet. Show a calm
    // setup state instead of the full grid.
    private var needsSetup: Bool {
        workoutManager.loggedSessions.isEmpty && workoutManager.weeklySchedule.isEmpty && !workoutManager.isWorkoutActive
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

                if let issue = workoutManager.storeIssue {
                    StoreIssueBanner(message: issue) { workoutManager.storeIssue = nil }
                }

                if workoutManager.isWorkoutActive, let workout = workoutManager.currentWorkout {
                    ResumeWorkoutBanner(workout: workout) { workoutManager.selectedTab = 1 }
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

                // Today's prescribed loads, missed-day nudge and weekly volume
                SmartTodayCard(workoutManager: workoutManager, todaysWorkout: todaysScheduledWorkout)

                // Training insight from your own logged history
                TrainingInsightCard(workoutManager: workoutManager)

                // Workout Schedule Overview
                if let profile = workoutManager.userProfile, !workoutManager.weeklySchedule.isEmpty {
                    ProgramRecommendationCard(profile: profile, schedule: workoutManager.weeklySchedule)
                }

                // Today's Workout / Next Workout
                WorkoutScheduleCard(workoutManager: workoutManager, hidesToday: todaysScheduledWorkout != nil)

                // Today's Quests (server-generated; jumps to Community → Quests)
                TodaysQuestsCard { workoutManager.selectedTab = 7 }

                // Apple Health: today's steps + active energy (iOS only)
                #if os(iOS)
                HealthCard()
                #endif

                // Quick Stats
                LazyVGrid(columns: adaptiveColumns(desktop: 3, phone: 2), spacing: 20) {
                    StatCard(title: "Today's Workouts", value: "\(workoutManager.todaysWorkouts)", icon: "figure.strengthtraining.traditional", color: .blue)
                    StatCard(title: "Last 7 Days", value: "\(workoutManager.weeklyWorkouts)/\(max(weeklyGoal, 1))", icon: "chart.bar.fill", color: .green)
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
                if !workoutManager.loggedSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent Workouts")
                                .font(.headline)
                            Spacer()
                            Button("See All") { workoutManager.selectedTab = 3 }
                                .font(.subheadline)
                        }

                        ForEach(workoutManager.loggedSessions.sorted { $0.date > $1.date }.prefix(5)) { session in
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
    @State private var selectedScheduledWorkoutIndex = 0
    @State private var sessionSummary: SessionSummary? // SessionGameLayer hook

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { workoutManager.pendingStart != nil },
            set: { if !$0 { workoutManager.pendingStart = nil } }
        )
    }

    var body: some View {
        #if os(iOS)
        // The stack only hosts the keyboard toolbar: number pads have no
        // return key, so "Done" sits above them.
        NavigationStack {
            screen
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { Platform.dismissKeyboard() }
                    }
                }
        }
        #else
        screen
        #endif
    }

    private var screen: some View {
        Group {
            if workoutManager.isWorkoutActive, workoutManager.currentWorkout != nil {
                ActiveWorkoutView(summary: $sessionSummary)
            } else {
                idleContent
            }
        }
        .padding()
        .sheet(item: $sessionSummary) { summary in // SessionGameLayer hook
            SessionSummaryView(summary: summary, onDone: { sessionSummary = nil })
        }
        // Cmd-N or a Start button while a workout is going: ask, never replace.
        .alert("Workout in progress", isPresented: pendingBinding, presenting: workoutManager.pendingStart) { start in
            Button("Resume Current Workout", role: .cancel) { workoutManager.pendingStart = nil }
            Button("Discard and Start New", role: .destructive) {
                workoutManager.discardWorkout()
                workoutManager.perform(start)
            }
        } message: { start in
            Text("Starting \(start.title) would replace the workout you have going. Its logged sets would be deleted.")
        }
        .onAppear {
            if let todayIndex = getTodaysWorkoutIndex() {
                selectedScheduledWorkoutIndex = todayIndex
            }
        }
    }

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Workouts")
                    .font(.screenTitle)
                    .bold()

                if workoutManager.weeklySchedule.isEmpty {
                    VStack(spacing: 12) {
                        Text("No program yet")
                            .font(.title3.bold())
                        Text("Pick or build a program in the Programs tab, or just start logging.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Browse Programs") { workoutManager.selectedTab = 2 }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ScheduledWorkoutBrowser(
                        schedule: workoutManager.weeklySchedule,
                        index: $selectedScheduledWorkoutIndex,
                        onStart: { workoutManager.startScheduledWorkout($0) }
                    )
                }

                Button {
                    workoutManager.requestNewWorkout()
                } label: {
                    Label("Start Empty Workout", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.bottom, Platform.isDesktop ? 0 : 80)
        }
    }

    func getTodaysWorkoutIndex() -> Int? {
        let today = Calendar.current.component(.weekday, from: Date())
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let todayName = dayNames[today - 1]

        return workoutManager.weeklySchedule.firstIndex { $0.dayOfWeek == todayName }
    }
}

/// Steps through the program's days and starts one. The index is clamped, so
/// switching to a shorter program can never read past the end.
struct ScheduledWorkoutBrowser: View {
    let schedule: [ScheduledWorkout]
    @Binding var index: Int
    let onStart: (ScheduledWorkout) -> Void

    private var safeIndex: Int { min(max(index, 0), max(schedule.count - 1, 0)) }

    var body: some View {
        if schedule.isEmpty {
            EmptyView()
        } else {
            let workout = schedule[safeIndex]
            VStack(alignment: .leading, spacing: 16) {
                selector(workout)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Exercises")
                        .font(.title3.bold())
                    ForEach(Array(workout.plannedExercises.enumerated()), id: \.offset) { _, planned in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "circle")
                                .font(.caption)
                                .foregroundColor(.brandBlue)
                            Text(planned.name)
                                .font(.body)
                            Spacer()
                            if planned.hasTarget {
                                Text(planned.schemeText)
                                    .font(.callout.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Button {
                    onStart(workout)
                } label: {
                    Label("Start This Workout", systemImage: "play.circle.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandBlue)
            }
            .onAppear { index = safeIndex }
        }
    }

    private func selector(_ workout: ScheduledWorkout) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    index = max(safeIndex - 1, 0)
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundColor(safeIndex == 0 ? .gray : .brandBlue)
                .disabled(safeIndex == 0)
                .accessibilityLabel("Previous workout")

                Spacer()

                VStack(spacing: 4) {
                    Text(workout.workoutType)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 8) {
                        Text(workout.dayOfWeek)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if isToday(workout) {
                            Text("TODAY")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                        }
                    }
                }

                Spacer()

                Button {
                    index = min(safeIndex + 1, schedule.count - 1)
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundColor(safeIndex >= schedule.count - 1 ? .gray : .brandBlue)
                .disabled(safeIndex >= schedule.count - 1)
                .accessibilityLabel("Next workout")
            }
            Text("\(safeIndex + 1) of \(schedule.count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func isToday(_ workout: ScheduledWorkout) -> Bool {
        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return workout.dayOfWeek == dayNames[Calendar.current.component(.weekday, from: Date()) - 1]
    }
}

struct QuickProgramQuestionnaireView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @Environment(\.dismiss) var dismiss

    @State private var currentStep = 1
    @State private var daysPerWeek = 3
    @State private var sessionDuration = 60
    @State private var primaryFocus = "Muscle Building"

    let daysOptions = [2, 3, 4, 5, 6]
    let durationOptions = SessionLength.presets
    let focusOptions = ["Muscle Building", "Strength", "Fat Loss", "General Fitness", "Athletic Performance"]

    var body: some View {
        VStack(spacing: 30) {
            // Header
            HStack {
                Text("Quick Program Builder")
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
                                    text: duration == 120 ? "2 hours" : "\(duration) min",
                                    isSelected: sessionDuration == duration
                                ) {
                                    sessionDuration = duration
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                        Stepper("Custom: \(sessionDuration) min", value: $sessionDuration,
                                in: SessionLength.range, step: SessionLength.step)
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
                        generateQuickProgram()
                        dismiss()
                    }
                }) {
                    HStack {
                        Text(currentStep < 3 ? "Next" : "Generate Workout")
                        Image(systemName: currentStep < 3 ? "chevron.right" : "checkmark")
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

    func generateQuickProgram() {
        // Fixed templates scaled to the answers.
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
/// Named to avoid shadowing SwiftUI.ProgressView.
struct TrainingProgressView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"

    private var unit: WeightUnit { TrainingUnits.unit(forPreference: unitPreference) }

    var body: some View {
        NavigationStack {
            ScrollView {
                content(workoutManager.loggedSessions)
                    .padding()
                    .padding(.bottom, Platform.isDesktop ? 0 : 80)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
    }

    private func content(_ logged: [WorkoutSession]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Progress")
                    .font(.screenTitle)
                    .bold()
                Spacer()
                NavigationLink {
                    HistoryListView()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
            }

            ProgressStatsGrid(logged: logged, streak: workoutManager.currentStreak,
                              weekly: workoutManager.weeklyWorkouts, unit: unit)
            MuscleWeekCard(sessions: logged, unit: unit)
            RecordsCard(sessions: logged, unit: unit)
            WeeklyActivityChart(sessions: logged)
            VolumeTrendChart(sessions: logged, unit: unit)
            WorkoutCalendarView(sessions: logged)
        }
    }
}

struct ProgressStatsGrid: View {
    let logged: [WorkoutSession]
    let streak: Int
    let weekly: Int
    let unit: WeightUnit

    var body: some View {
        let total = logged.reduce(0.0) { $0 + $1.totalVolume }
        let average = logged.isEmpty ? 0 : total / Double(logged.count)
        LazyVGrid(columns: adaptiveColumns(desktop: 4, phone: 2), spacing: 15) {
            StatCard(title: "Workouts", value: "\(logged.count)", icon: "list.bullet", color: .blue)
            StatCard(title: "Day Streak", value: "\(streak)", icon: "flame.fill", color: .orange)
            StatCard(title: "Total Volume", value: TrainingUnits.volume(total, unit), icon: "chart.bar.fill", color: .green)
            StatCard(title: "Avg per Workout", value: TrainingUnits.volume(average, unit), icon: "chart.line.uptrend.xyaxis", color: .purple)
        }
    }
}

struct WeeklyActivityChart: View {
    let sessions: [WorkoutSession]

    private var days: [(String, Int)] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let count = sessions.filter { calendar.isDate($0.date, inSameDayAs: date) }.count
            return (date.formatted(.dateTime.weekday(.abbreviated)), count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workouts, Last 7 Days")
                .font(.headline)
            Chart {
                ForEach(days, id: \.0) { day, count in
                    BarMark(x: .value("Day", day), y: .value("Workouts", count))
                        .foregroundStyle(Color.blue.gradient)
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 160)
        }
        .padding()
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct VolumeTrendChart: View {
    let sessions: [WorkoutSession]
    let unit: WeightUnit

    var body: some View {
        let recent = Array(sessions.suffix(12))
        VStack(alignment: .leading, spacing: 10) {
            Text("Volume per Workout (\(unit.label))")
                .font(.headline)
            if recent.count < 2 {
                Text("Log two or more workouts to see the trend.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(recent) { session in
                        LineMark(x: .value("Date", session.date), y: .value("Volume", TrainingUnits.toDisplay(session.totalVolume, unit)))
                            .foregroundStyle(Color.green.gradient)
                        PointMark(x: .value("Date", session.date), y: .value("Volume", TrainingUnits.toDisplay(session.totalVolume, unit)))
                            .foregroundStyle(Color.green)
                    }
                }
                .frame(height: 180)
                Text("Completed sets only: reps × load.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
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

// MARK: - Workout Calendar View
struct WorkoutCalendarView: View {
    let sessions: [WorkoutSession]

    var workoutDates: Set<DateComponents> {
        var dates = Set<DateComponents>()
        for session in sessions {
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
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"
    @State private var weight = ""
    @State private var reps = ""
    @State private var oneRM: Double?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Weight Lifted")
                        .font(.headline)
                    TextField("Enter weight (\(TrainingUnits.unit(forPreference: unitPreference).label))", text: $weight)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reps Completed")
                        .font(.headline)
                    TextField("Enter reps", text: $reps)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
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
                        Text("\(Int(result)) \(TrainingUnits.unit(forPreference: unitPreference).label)")
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
        guard let w = Double(weight.replacingOccurrences(of: ",", with: ".")), let r = Int(reps), r > 0 else { return }
        // Epley, the same estimate the Progress tab shows.
        oneRM = ProgressionEngine.e1RM(weight: w, reps: r)
    }
}

struct BMICalculatorView: View {
    @State private var weight = "150"
    @State private var height = "64"
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
    @State private var weight = "150"
    @State private var height = "64"
    @State private var age = ""
    @State private var gender = "Female"
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
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"
    @State private var targetWeight = ""
    @State private var barWeight = ""
    @State private var result: PlateBreakdown?

    private var unit: WeightUnit { TrainingUnits.unit(forPreference: unitPreference) }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target Weight (\(unit.label))")
                        .font(.headline)
                    TextField("Enter target weight", text: $targetWeight)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bar Weight (\(unit.label))")
                        .font(.headline)
                    TextField(TrainingUnits.number(PlateMath.defaultBar(for: unit)), text: $barWeight)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }

                Button("Calculate") {
                    Platform.dismissKeyboard()
                    calculatePlates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let result {
                    resultView(result)
                }
            }
            .padding()
        }
        .onChange(of: unitPreference) { _, _ in result = nil }
    }

    @ViewBuilder
    private func resultView(_ result: PlateBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.isBelowBar {
                Text("That's less than the \(TrainingUnits.number(result.bar)) \(unit.label) bar.")
                    .foregroundColor(.secondary)
            } else if result.perSide.isEmpty {
                Text("Just the bar.")
                    .foregroundColor(.secondary)
            } else {
                Text("Plates Per Side")
                    .font(.headline)
                    .foregroundColor(.secondary)

                ForEach(result.perSide) { plate in
                    HStack {
                        Text("\(TrainingUnits.number(plate.weight)) \(unit.label)")
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
            if !result.isExact, !result.isBelowBar {
                Label("Standard plates can't make this exactly. Closest: \(TrainingUnits.number(result.loadable)) \(unit.label), \(TrainingUnits.number(result.remainderPerSide)) \(unit.label) short per side.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundColor(.orange)
            }
        }
    }

    func calculatePlates() {
        let parse = { (text: String) in Double(text.replacingOccurrences(of: ",", with: ".")) }
        guard let target = parse(targetWeight), target > 0 else {
            result = nil
            return
        }
        let bar = parse(barWeight) ?? PlateMath.defaultBar(for: unit)
        result = PlateMath.breakdown(total: target, bar: bar, unit: unit)
    }
}

struct RepMaxChartView: View {
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"
    @State private var oneRM = ""
    @State private var percentages: [(percent: Int, weight: Int)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1 Rep Max (\(TrainingUnits.unit(forPreference: unitPreference).label))")
                        .font(.headline)
                    TextField("Enter 1RM", text: $oneRM)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
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
                                Text("\(item.weight) \(TrainingUnits.unit(forPreference: unitPreference).label)")
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
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"
    @AppStorage("defaultRestTime") private var defaultRestTime = 90
    @AppStorage("weeklyGoal") private var weeklyGoal = 5
    @EnvironmentObject var workoutManager: WorkoutManager
    @ObservedObject private var health = HealthKitManager.shared
    @State private var showAccount = false
    @State private var exportDocument: WorkoutExportDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var transferMessage: String?
    @State private var confirmReset = false

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
                            Text(LocalPlayerStore.shared.current?.name ?? "Player")
                            Spacer()
                            Text("Manage").foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Units") {
                    Picker("Weight", selection: $unitPreference) {
                        Text("Pounds (lb)").tag("imperial")
                        Text("Kilograms (kg)").tag("metric")
                    }
                    .compactSegmentedPicker()
                    Text("Weights are entered and shown in this unit everywhere, including plate math. History is kept in pounds and converts automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                #if os(iOS)
                Section("Apple Health") {
                    if health.isConnected {
                        Toggle("Save finished workouts to Apple Health", isOn: $health.syncWorkoutsToHealth)
                    } else {
                        Button("Connect Apple Health") {
                            Task { await health.requestAuthorization() }
                        }
                        .disabled(!health.isAvailable)
                    }
                    if !health.isAvailable {
                        Text("Apple Health is not available on this device.").font(.caption).foregroundColor(.secondary)
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
                .multilineTextAlignment(.leading)
                            .labelsHidden()
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .multilineTextAlignment(.leading)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .frame(width: 80)
                        Text("seconds")
                    }

                    Stepper("Weekly goal: \(weeklyGoal) workout\(weeklyGoal == 1 ? "" : "s")", value: $weeklyGoal, in: 1...14)
                }

                SessionGameSettingsSection() // SessionGameLayer hook

                Section("Your Data") {
                    Button("Export Workouts…") { export() }
                    Button("Import Workouts…") { importTapped() }
                    Text("An export is a JSON file of your whole training log: keep it as a backup or import it on another device. Imported workouts stay on that device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let transferMessage {
                        Text(transferMessage)
                            .font(.caption)
                    }
                    if let issue = workoutManager.storeIssue {
                        Text(issue)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Section("Programming") {
                    Button(action: { confirmReset = true }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .foregroundColor(.red)
                            Text("Reset All Programming")
                                .foregroundColor(.red)
                        }
                    }
                    .buttonStyle(.plain)

                    Text("Clears your scheduled workouts so you can start fresh with a new program. Your workout history is not affected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showAccount) { NavigationStack { AccountView() } }
        .confirmationDialog("Reset all programming?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Programming", role: .destructive) { workoutManager.resetProgramming() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your scheduled workouts will be cleared. Finished workouts stay in your history.")
        }
        #if os(iOS)
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "endgame-fitness-workouts") { result in
            switch result {
            case .success: transferMessage = "Exported \(workoutManager.sessions.count) workout\(workoutManager.sessions.count == 1 ? "" : "s")."
            case .failure(let error): transferMessage = "Export failed: \(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                if let data = WorkoutTransfer.readPickedFile(url) {
                    handleImport(data)
                } else {
                    transferMessage = "That file could not be read."
                }
            case .failure(let error):
                transferMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        #endif
    }

    private func export() {
        #if os(macOS)
        if workoutManager.exportWorkouts() != nil {
            transferMessage = "Exported \(workoutManager.sessions.count) workout\(workoutManager.sessions.count == 1 ? "" : "s")."
        }
        #else
        guard let data = workoutManager.exportData() else {
            transferMessage = "Export failed."
            return
        }
        exportDocument = WorkoutExportDocument(data: data)
        showExporter = true
        #endif
    }

    private func importTapped() {
        #if os(macOS)
        guard let data = WorkoutTransfer.importJSON() else { return }
        handleImport(data)
        #else
        showImporter = true
        #endif
    }

    private func handleImport(_ data: Data) {
        guard let added = workoutManager.importWorkouts(from: data) else {
            transferMessage = "That file is not an Endgame Fitness workout export."
            return
        }
        transferMessage = added == 0 ? "No new workouts in that file." : "Imported \(added) workout\(added == 1 ? "" : "s")."
    }
}

// MARK: - Supporting Views
struct MicrocycleProgressCard: View {
    let workoutManager: WorkoutManager

    var microcycleProgress: (current: Int, total: Int, weekNumber: Int) {
        let workoutsPerWeek = 3
        let weeksInMicrocycle = 4
        let totalWorkouts = workoutsPerWeek * weeksInMicrocycle // 12 workouts per microcycle
        let currentWorkout = workoutManager.loggedSessions.count % totalWorkouts
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

struct TrainingInsightCard: View {
    let workoutManager: WorkoutManager
    @State private var currentInsightIndex = 0

    var insights: [(emoji: String, title: String, message: String, tip: String)] {
        let streak = workoutManager.currentStreak
        let weeklyWorkouts = workoutManager.weeklyWorkouts
        let totalWorkouts = workoutManager.loggedSessions.count
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
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.brandPurple)
                    .frame(width: 44, height: 44)
                    .background(Color.brandPurple.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Training")
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
        let unit = TrainingUnits.current
        let bench = TrainingUnits.weight(Double(profile.benchPress5RM), unit)
        let squat = TrainingUnits.weight(Double(profile.squat5RM), unit)
        let deadlift = TrainingUnits.weight(Double(profile.deadlift5RM), unit)
        return "A \(experienceText) \(goalText) program. Your starting 5-rep maxes: bench \(bench), squat \(squat), deadlift \(deadlift)."
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
    /// True when the dashboard's Today card already shows today's workout.
    var hidesToday: Bool = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This Week")
                .font(.title2)
                .bold()

            if !hidesToday, let todaysWorkout = getTodaysWorkout() {
                // Today's workout
                Button(action: {
                    workoutManager.selectedTab = 1
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

                        ForEach(Array(todaysWorkout.plannedExercises.enumerated()), id: \.offset) { _, planned in
                            HStack {
                                Image(systemName: "circle")
                                    .foregroundColor(.brandGreen)
                                    .font(.caption)
                                Text(planned.name)
                                    .font(.subheadline)
                                if planned.hasTarget {
                                    Spacer()
                                    Text(planned.schemeText)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
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
                        Image(systemName: hidesToday ? "calendar" : "bed.double.fill")
                            .foregroundColor(.brandYellow)
                        Text(hidesToday ? "Up Next" : "Rest Day")
                            .font(.headline)
                    }

                    Text("Your next workout is \(nextWorkout.dayOfWeek): \(nextWorkout.workoutType)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                // No workouts scheduled - point to the Programs tab
                Button(action: {
                    workoutManager.selectedTab = 2 // Go to Programs tab
                }) {
                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "list.bullet.clipboard")
                                .font(.system(size: 50))
                                .foregroundColor(.yellow)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Don't know where to start?")
                                    .font(.title.bold())
                                    .foregroundColor(.primary)

                                Text("Pick a ready-made program or build your own in the Programs tab.")
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

            if let lastWorkout = workoutManager.loggedSessions.last {
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
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
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
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"
    @State private var isHovering = false
    @State private var showDetail = false

    var body: some View {
        Button(action: { showDetail = true }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(TrainingUnits.volume(session.totalVolume, TrainingUnits.unit(forPreference: unitPreference)))
                        .font(.subheadline)
                        .bold()
                    Text("\(session.completedSetCount) sets · \(session.exercises.count) exercises")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(isHovering ? 0.1 : 0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                SessionDetailView(sessionID: session.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showDetail = false }
                        }
                    }
            }
            .environmentObject(workoutManager)
            .desktopSheetFrame(width: 600, height: 680)
        }
    }
}

/// A storage problem, said plainly, with a dismiss button.
struct StoreIssueBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shown on the dashboard while a workout is in progress (including one
/// restored after the app was closed).
struct ResumeWorkoutBanner: View {
    let workout: WorkoutSession
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2)
                    .foregroundColor(.brandGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workout in progress")
                        .font(.headline)
                    Text("\(workout.displayName) · \(workout.completedSetCount) sets done")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Resume")
                    .font(.subheadline.bold())
                    .foregroundColor(.brandGreen)
            }
            .padding()
            .background(Color.brandGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    // Defaults: 150 lb woman of average US female height (5'4").
    @State private var userWeight = "150"
    @State private var userHeight = "64"
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
        // Save user profile to WorkoutManager
        guard let age = Int(userAge),
              let weight = Double(userWeight),
              let height = Double(userHeight),
              let bench = Int(benchPress5RM),
              let squat = Int(squat5RM),
              let deadlift = Int(deadlift5RM) else {
            errorMessage = "Please enter valid numbers for all fields"
            showError = true
            return
        }

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

        hasCompletedOnboarding = true

        // Force UserDefaults to sync
        UserDefaults.standard.synchronize()
    }
}

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: Platform.isDesktop ? 40 : 24) {
            // Stick figure in a squat
            ZStack {
                // Stick figure in squat
                Image(systemName: "figure.strengthtraining.functional")
                    .font(.system(size: 100))
                    .foregroundColor(.brandBlue)

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
                    title: "Smart Progression",
                    description: "Next-session targets worked out from your own logged sets",
                    color: .brandPurple
                )

                FeatureRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Programs and Phases",
                    description: "16 ready-made programs, a program builder and mesocycle phases",
                    color: .brandBlue
                )

                FeatureRow(
                    icon: "dumbbell.fill",
                    title: "876 Exercises",
                    description: "Searchable by muscle and equipment, each with step-by-step instructions",
                    color: .brandGreen
                )

                FeatureRow(
                    icon: "calendar.badge.clock",
                    title: "Progress Tracking",
                    description: "Personal records, weekly sets per muscle and a 12-month calendar",
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
                        Endgame Fitness and its developers are not medical professionals and do not provide medical advice, diagnosis, or treatment. The information and workout programs provided by this application are for educational and informational purposes only.

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
                        TO THE FULLEST EXTENT PERMITTED BY LAW, Bates LLC, its owners, developers, and affiliates SHALL NOT BE LIABLE for any injuries, damages, or losses of any kind arising from:

                        • Use of this application
                        • Following workout programs or recommendations
                        • Use of exercise equipment
                        • Any direct, indirect, incidental, consequential, or punitive damages

                        You release and hold harmless Bates LLC and all associated parties from any and all claims, liabilities, damages, or expenses arising from your use of this application.
                        """
                    )

                    // Business Liability Waiver
                    WaiverSection(
                        title: "🏢 Business Indemnification",
                        content: """
                        You agree to indemnify and hold harmless Bates LLC, its officers, directors, employees, contractors, and agents from any claims, lawsuits, damages, losses, or expenses (including attorney fees) arising from:

                        • Your use of this application
                        • Your breach of these terms
                        • Your violation of any law or rights of third parties

                        Bates LLC provides this software "AS IS" without warranties of any kind, either express or implied.
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
                        • You release Bates LLC from all liability
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
            get: { Int(((Double(userHeight) ?? 64) * 2.54).rounded()) },
            set: { userHeight = String(Int((Double($0) / 2.54).rounded())) }
        )
    }

    // Height is entered as feet + inches (no one thinks in total inches);
    // the parent still stores plain inches in userHeight, so nothing
    // downstream changes.
    private var feetBinding: Binding<Int> {
        Binding(
            get: { Int(Double(userHeight) ?? 64) / 12 },
            set: { userHeight = String($0 * 12 + Int(Double(userHeight) ?? 64) % 12) }
        )
    }
    private var inchesBinding: Binding<Int> {
        Binding(
            get: { Int(Double(userHeight) ?? 64) % 12 },
            set: { userHeight = String((Int(Double(userHeight) ?? 64) / 12) * 12 + $0) }
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
                            .onChange(of: userAge) { _, v in
                                userAge = String(v.filter(\.isNumber).prefix(3))
                            }
                    }

                    if unitPreference == "metric" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Weight (kg)").font(.headline)
                            TextField("68", text: weightKgBinding)
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
                            TextField("150", text: $userWeight)
                                .textFieldStyle(.roundedBorder)
                                .font(.title3)
                                .frame(width: 110)
                                .focused($focusedField, equals: .weight)
                                .onChange(of: userWeight) { _, v in
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
            if userHeight.isEmpty { userHeight = "64" }   // sensible default; pickers can't be blank
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
            Text("Endgame Fitness and its developers are not a substitute for medical advice. Please consult with your primary care physician and get cleared for exercise before starting any workout program.\n\nIf you have any pre-existing health conditions, injuries, or concerns, speak with a qualified healthcare provider to ensure this program is safe for you.")
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
    var id = UUID()
    var dayOfWeek: String
    var workoutType: String
    /// Exercise names as shown. Older saves may carry a scheme suffix
    /// ("Bench Press 4x8"); `plannedExercises` splits it off.
    var exercises: [String]
    var estimatedDuration: Int // minutes
    var completed: Bool = false
    var date: Date?
    /// The prescription for each exercise, aligned with `exercises`.
    var plan: [PlannedExercise]? = nil

    enum CodingKeys: String, CodingKey {
        case id, dayOfWeek, workoutType, exercises, estimatedDuration, completed, date, plan
    }

    /// One entry per exercise: the stored prescription when it still matches
    /// the name, otherwise whatever scheme the name carries.
    var plannedExercises: [PlannedExercise] {
        exercises.enumerated().map { i, name in
            if let plan, plan.indices.contains(i), plan[i].name == name { return plan[i] }
            return ProgramTargetParser.parse(name)
        }
    }

    /// Moves any "4x8" suffix out of the names and into `plan`.
    mutating func normalizePlan() {
        let planned = plannedExercises
        plan = planned
        exercises = planned.map(\.name)
    }
}

extension ScheduledWorkout {
    /// Tolerant: the id used to regenerate on every launch (it was never
    /// saved), and `plan` is new.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        dayOfWeek = (try? c.decodeIfPresent(String.self, forKey: .dayOfWeek)) ?? ""
        workoutType = (try? c.decodeIfPresent(String.self, forKey: .workoutType)) ?? "Workout"
        exercises = (try? c.decodeIfPresent([String].self, forKey: .exercises)) ?? []
        estimatedDuration = (try? c.decodeIfPresent(Int.self, forKey: .estimatedDuration)) ?? 60
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? false
        date = try? c.decodeIfPresent(Date.self, forKey: .date)
        plan = try? c.decodeIfPresent([PlannedExercise].self, forKey: .plan)
    }
}
