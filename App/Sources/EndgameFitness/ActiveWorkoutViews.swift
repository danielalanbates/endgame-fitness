//
//  ActiveWorkoutViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  The logging screen, built like the best set loggers: every exercise is a
//  card of set rows — set number, last time's numbers, weight, reps, optional
//  RIR and a check button. Planned rows start unticked; ticking one completes
//  the set, which is what counts for volume, PRs, XP and sync, and starts the
//  rest timer through SessionGame.
//
//  The same card is reused by the history editor (HistoryViews.swift) with a
//  plain binding instead of the live workout.
//

import SwiftUI

// MARK: - Layout metrics

enum SetRowMetrics {
    static var number: CGFloat { Platform.isDesktop ? 34 : 24 }
    static var weight: CGFloat { Platform.isDesktop ? 84 : 68 }
    static var reps: CGFloat { Platform.isDesktop ? 62 : 50 }
    static var rir: CGFloat { Platform.isDesktop ? 54 : 40 }
    static var check: CGFloat { Platform.isDesktop ? 36 : 44 }
    static var fieldHeight: CGFloat { Platform.isDesktop ? 28 : 40 }
    static var spacing: CGFloat { Platform.isDesktop ? 10 : 6 }
}

// MARK: - Active workout screen

struct ActiveWorkoutView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @Binding var summary: SessionSummary?
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"

    @State private var showPicker = false
    @State private var confirmDiscard = false
    @State private var confirmFinish = false
    @State private var nothingToSave = false

    private var unit: WeightUnit { TrainingUnits.unit(forPreference: unitPreference) }

    var body: some View {
        if let workout = workoutManager.currentWorkout {
            VStack(alignment: .leading, spacing: 12) {
                ActiveWorkoutHeader(workout: workout, onFinish: finishTapped, onDiscard: { confirmDiscard = true })
                exerciseList(workout)
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView { entry, customName in
                    workoutManager.addExercise(entry, customName: customName)
                }
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Workout", role: .destructive) { workoutManager.discardWorkout() }
                Button("Keep Logging", role: .cancel) {}
            } message: {
                Text(discardMessage(workout))
            }
            .alert("Nothing to save yet", isPresented: $nothingToSave) {
                Button("Discard Workout", role: .destructive) { workoutManager.discardWorkout() }
                Button("Keep Logging", role: .cancel) {}
            } message: {
                Text("No set is ticked off. Tap the check on each set you did to save it, or discard this workout.")
            }
            .alert("Finish workout?", isPresented: $confirmFinish) {
                Button("Finish") { finish() }
                Button("Keep Logging", role: .cancel) {}
            } message: {
                Text(unfinishedMessage(workout))
            }
        }
    }

    private func exerciseList(_ workout: WorkoutSession) -> some View {
        let history = workoutManager.loggedSessions
        return ScrollView {
            VStack(spacing: 16) {
                if workout.exercises.isEmpty {
                    EmptyWorkoutHint()
                }
                ForEach(workout.exercises) { exercise in
                    ExerciseLogCard(
                        exercise: binding(for: exercise.id),
                        history: history,
                        excludingSession: workout.id,
                        unit: unit,
                        live: true,
                        onToggleSet: { setID in
                            workoutManager.toggleSetCompleted(exerciseID: exercise.id, setID: setID)
                        },
                        onRemove: { workoutManager.removeExercise(exercise.id) },
                        onMove: { workoutManager.moveExercise(exercise.id, by: $0) }
                    )
                }
                addExerciseButton
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Text("Discard Workout")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.bottom, Platform.isDesktop ? 16 : 88)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            RestTimerBar() // SessionGameLayer hook — pinned so it never scrolls away
                .padding(.bottom, 4)
        }
        .overlay(XPPopupOverlay()) // SessionGameLayer hook
    }

    private var addExerciseButton: some View {
        Button(action: { showPicker = true }) {
            Label("Add Exercise", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.brandBlue)
    }

    private func binding(for id: UUID) -> Binding<Exercise> {
        Binding(
            get: { workoutManager.currentWorkout?.exercises.first { $0.id == id } ?? Exercise(id: id, name: "") },
            set: { workoutManager.updateExercise($0) }
        )
    }

    private func finishTapped() {
        Platform.dismissKeyboard()
        guard let workout = workoutManager.currentWorkout else { return }
        if workout.completedSetCount == 0 {
            nothingToSave = true
        } else if workout.exercises.contains(where: { $0.sets.contains { !$0.completed } }) {
            confirmFinish = true
        } else {
            finish()
        }
    }

    private func finish() {
        guard let workout = workoutManager.currentWorkout else { return }
        let draft = SessionSummary.make(from: workout, streak: 1) // SessionGameLayer hook
        let before = workoutManager.loggedSessions
        guard workoutManager.completeWorkout() else {
            nothingToSave = true
            return
        }
        let review = SessionReview.make(workout: workout, before: before, after: workoutManager.loggedSessions,
                                        context: .current(profile: workoutManager.userProfile))
        summary = draft.withStreak(max(workoutManager.currentStreak, 1)).withReview(review)
    }

    private func discardMessage(_ workout: WorkoutSession) -> String {
        let done = workout.completedSetCount
        return done == 0 ? "Nothing has been logged yet." : "\(done) completed set\(done == 1 ? "" : "s") will be deleted. This cannot be undone."
    }

    private func unfinishedMessage(_ workout: WorkoutSession) -> String {
        let open = workout.exercises.reduce(0) { $0 + $1.sets.filter { !$0.completed }.count }
        return "\(open) planned set\(open == 1 ? " was" : "s were") not ticked off and won't be saved."
    }
}

private struct EmptyWorkoutHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "dumbbell")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Add your first exercise")
                .font(.headline)
            Text(ExerciseLibrary.shared.count > 0
                 ? "Search \(ExerciseLibrary.shared.count) exercises by name, muscle or equipment, or type your own."
                 : "Type the name of an exercise to add it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

struct ActiveWorkoutHeader: View {
    let workout: WorkoutSession
    let onFinish: () -> Void
    let onDiscard: () -> Void

    private var plannedCount: Int { workout.exercises.reduce(0) { $0 + $1.sets.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Text(workout.displayName)
                    .font(.screenTitle)
                    .bold()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Menu {
                    Button("Discard Workout", role: .destructive, action: onDiscard)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Workout options")

                Button(action: onFinish) {
                    Text("Finish")
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
            }
            HStack(spacing: 10) {
                ElapsedTimeLabel(start: workout.date)
                Text("\(workout.completedSetCount)/\(plannedCount) sets")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                SessionXPBadge() // SessionGameLayer hook
            }
        }
    }
}

struct ElapsedTimeLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(Self.format(context.date.timeIntervalSince(start)), systemImage: "clock")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = max(Int(interval), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Exercise card

struct ExerciseLogCard: View {
    @Binding var exercise: Exercise
    let history: [WorkoutSession]
    let excludingSession: UUID?
    let unit: WeightUnit
    /// True in the live workout (rest timer, game hooks); false in the editor.
    let live: Bool
    /// Live mode: completes/uncompletes through WorkoutManager. Returns false
    /// when the set is missing numbers.
    var onToggleSet: ((UUID) -> Bool)? = nil
    var onRemove: () -> Void
    var onMove: ((Int) -> Void)? = nil

    @State private var showInfo = false
    @State private var showRange = false
    @State private var confirmRemove = false
    @State private var rejectedSet: UUID?

    private var tracking: SetTracking { exercise.resolvedTracking }
    private var library: LibraryExercise? { exercise.exerciseID.flatMap { ExerciseLibrary.shared.entry(id: $0) } }

    var body: some View {
        let last = ProgressionEngine.lastPerformance(of: exercise, in: history, excluding: excludingSession)
        let suggestion = live ? ProgressionEngine.suggestion(for: exercise, history: history, excluding: excludingSession, unit: unit) : nil
        let prescription = live ? SmartCoach.prescribe(exercise: exercise, history: history, excluding: excludingSession,
                                                       context: CoachContext.current()) : nil

        VStack(alignment: .leading, spacing: 8) {
            header
            if live {
                ProgressionHintView(exercise: exercise, suggestion: suggestion, prescription: prescription,
                                    hasHistory: last != nil, unit: unit, onEditRange: tracking == .timed ? nil : { showRange = true })
            }
            SetColumnHeader(tracking: tracking, unit: unit)
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                SetRowView(
                    number: index + 1,
                    set: setBinding(set.id),
                    tracking: tracking,
                    previous: previous(at: index, last?.sets),
                    unit: unit,
                    rejected: rejectedSet == set.id,
                    onToggle: { toggle(set.id, previous: previous(at: index, last?.sets)) },
                    onDelete: { exercise.sets.removeAll { $0.id == set.id } },
                    onUsePrevious: { usePrevious(set.id, previous(at: index, last?.sets)) }
                )
            }
            footer
        }
        .padding(12)
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showInfo) {
            if let library { ExerciseInfoView(entry: library) }
        }
        .popover(isPresented: $showRange) {
            RepRangeEditor(exercise: exercise)
                .presentationCompactAdaptation(.popover)
        }
        .confirmationDialog("Remove \(exercise.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Exercise", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sets in this workout will be deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.headline)
                    .foregroundStyle(Color.brandBlue)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !exercise.musclesForStats.isEmpty {
                    Text(exercise.musclesForStats.map(ExerciseLibrary.displayName(forMuscle:)).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                if library != nil {
                    Button { showInfo = true } label: { Label("Instructions", systemImage: "info.circle") }
                }
                if tracking != .timed {
                    Button { showRange = true } label: { Label("Rep Range…", systemImage: "arrow.up.arrow.down") }
                }
                if let onMove {
                    Button { onMove(-1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    Button { onMove(1) } label: { Label("Move Down", systemImage: "arrow.down") }
                }
                Button(role: .destructive) {
                    if exercise.sets.contains(where: \.completed) { confirmRemove = true } else { onRemove() }
                } label: {
                    Label("Remove Exercise", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Exercise options")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tracking == .weighted, library?.isBarbell == true, let weight = plateWeight, weight > 0 {
                PlateHintView(weightLb: weight, unit: unit)
            }
            HStack(spacing: 10) {
                Button {
                    addSet()
                } label: {
                    Label("Add Set", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Platform.isDesktop ? 2 : 6)
                }
                .buttonStyle(.bordered)
                .tint(.brandBlue)
                if live, tracking != .timed {
                    ExerciseRestOverride(exerciseName: exercise.name) // SessionGameLayer hook
                }
            }
        }
    }

    /// The next unticked set's load (else the last set's), for plate math.
    private var plateWeight: Double? {
        (exercise.sets.first { !$0.completed && $0.weight > 0 } ?? exercise.sets.last { $0.weight > 0 })?.weight
    }

    private func previous(at index: Int, _ sets: [ExerciseSet]?) -> ExerciseSet? {
        guard let sets, !sets.isEmpty else { return nil }
        return sets.indices.contains(index) ? sets[index] : nil
    }

    private func setBinding(_ id: UUID) -> Binding<ExerciseSet> {
        Binding(
            get: { exercise.sets.first { $0.id == id } ?? ExerciseSet(id: id) },
            set: { newValue in
                if let i = exercise.sets.firstIndex(where: { $0.id == id }) { exercise.sets[i] = newValue }
            }
        )
    }

    private func addSet() {
        let last = exercise.sets.last
        exercise.sets.append(ExerciseSet(reps: last?.reps ?? exercise.targetRepMin ?? 0,
                                         weight: last?.weight ?? 0,
                                         durationSecs: last?.durationSecs ?? exercise.targetSeconds))
    }

    /// Empty fields take last time's numbers before the set is ticked, so one
    /// tap logs a repeat of last session.
    private func toggle(_ id: UUID, previous: ExerciseSet?) {
        Platform.dismissKeyboard()
        guard let i = exercise.sets.firstIndex(where: { $0.id == id }) else { return }
        if !exercise.sets[i].completed, let previous {
            var set = exercise.sets[i]
            if set.reps == 0 { set.reps = previous.reps }
            if set.weight == 0, tracking == .weighted { set.weight = previous.weight }
            if (set.durationSecs ?? 0) == 0, tracking == .timed { set.durationSecs = previous.durationSecs }
            if set != exercise.sets[i] { exercise.sets[i] = set }
        }
        let ok: Bool
        if live, let onToggleSet {
            ok = onToggleSet(id)
        } else {
            var set = exercise.sets[i]
            if set.completed {
                set.completed = false
                ok = true
            } else {
                ok = set.isLoggable(as: tracking)
                if ok { set.completed = true; set.completedAt = set.completedAt ?? Date() }
            }
            exercise.sets[i] = set
        }
        if !ok {
            Platform.beep()
            rejectedSet = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if rejectedSet == id { rejectedSet = nil } }
        }
    }

    private func usePrevious(_ id: UUID, _ previous: ExerciseSet?) {
        guard let previous, let i = exercise.sets.firstIndex(where: { $0.id == id }), !exercise.sets[i].completed else { return }
        exercise.sets[i].reps = previous.reps
        exercise.sets[i].weight = previous.weight
        exercise.sets[i].durationSecs = previous.durationSecs
        exercise.sets[i].rir = previous.rir
    }
}

// MARK: - Hint, headers

struct ProgressionHintView: View {
    let exercise: Exercise
    let suggestion: ProgressionSuggestion?
    var prescription: SmartCoach.Prescription? = nil
    let hasHistory: Bool
    let unit: WeightUnit
    var onEditRange: (() -> Void)?

    var body: some View {
        if let text {
            Button(action: { onEditRange?() }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(onEditRange == nil)
            .accessibilityHint(onEditRange == nil ? "" : "Edit the rep range")
        }
    }

    private var range: ClosedRange<Int> { ProgressionEngine.repRange(for: exercise) }
    private var rangeText: String { "\(range.lowerBound)–\(range.upperBound)" }

    private var icon: String {
        if let prescription {
            switch prescription.kind {
            case .increase: return "arrow.up.right.circle.fill"
            case .deload, .reset: return "arrow.down.right.circle"
            case .hold: return "equal.circle"
            default: return "target"
            }
        }
        switch suggestion?.kind {
        case .increaseLoad: return "arrow.up.right.circle.fill"
        case .topOfRangeBodyweight: return "arrow.up.right.circle"
        case .addReps: return "plus.circle"
        case nil: return "target"
        }
    }

    private var tint: Color {
        if let prescription {
            switch prescription.kind {
            case .increase: return .brandGreen
            case .deload, .reset: return .orange
            default: return .brandBlue
            }
        }
        return suggestion?.kind == .increaseLoad ? .brandGreen : .brandBlue
    }

    private var text: String? {
        let plan = PlannedExercise(name: exercise.name, sets: exercise.targetSets, repMin: exercise.targetRepMin,
                                   repMax: exercise.targetRepMax, seconds: exercise.targetSeconds)
        let target = plan.hasTarget ? "Target \(plan.schemeText). " : ""
        if let prescription {
            return "\(prescription.model.shortLabel): " + prescription.reason
        }
        guard let suggestion else {
            if exercise.resolvedTracking == .timed { return plan.hasTarget ? "Target \(plan.schemeText)." : nil }
            if hasHistory { return target.isEmpty ? nil : target }
            return target + "First time logging this: today sets your baseline. Rep range \(rangeText)."
        }
        switch suggestion.kind {
        case .increaseLoad:
            let load = suggestion.weightLb.map { TrainingUnits.weight($0, unit) } ?? ""
            return target + "Go up to \(load) × \(suggestion.range.lowerBound)+: last time every set reached \(suggestion.range.upperBound) reps with reps in reserve."
        case .addReps:
            let load = suggestion.weightLb.map { " at \(TrainingUnits.weight($0, unit))" } ?? ""
            return target + "Aim for \(suggestion.targetReps)+ reps\(load). Reach \(suggestion.range.upperBound) on every set (RIR 1+) and the load goes up. Range \(rangeText)."
        case .topOfRangeBodyweight:
            return target + "You hit \(suggestion.range.upperBound) reps on every set last time: add load or a harder variation."
        }
    }
}

struct SetColumnHeader: View {
    let tracking: SetTracking
    let unit: WeightUnit

    var body: some View {
        HStack(spacing: SetRowMetrics.spacing) {
            Text("SET").frame(width: SetRowMetrics.number)
            Text("PREVIOUS").frame(maxWidth: .infinity)
            switch tracking {
            case .timed:
                Text("TIME").frame(width: SetRowMetrics.weight + SetRowMetrics.reps + SetRowMetrics.spacing)
                Color.clear.frame(width: SetRowMetrics.rir, height: 1)
            case .weighted, .bodyweight:
                Text(tracking == .bodyweight ? "+\(unit.label.uppercased())" : unit.label.uppercased())
                    .frame(width: SetRowMetrics.weight)
                Text("REPS").frame(width: SetRowMetrics.reps)
                Text("RIR").frame(width: SetRowMetrics.rir)
            }
            Image(systemName: "checkmark").frame(width: SetRowMetrics.check)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Set row

struct SetRowView: View {
    let number: Int
    @Binding var set: ExerciseSet
    let tracking: SetTracking
    let previous: ExerciseSet?
    let unit: WeightUnit
    var rejected: Bool = false
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onUsePrevious: () -> Void

    var body: some View {
        HStack(spacing: SetRowMetrics.spacing) {
            leading
            fields
            checkButton
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.15), value: set.completed)
    }

    private var rowBackground: Color {
        if rejected { return Color.red.opacity(0.15) }
        return set.completed ? Color.brandGreen.opacity(0.15) : Color.clear
    }

    /// Set number and last time's numbers. Long-press (right-click on the Mac)
    /// for Delete / Use Previous; tapping "previous" copies it into the row.
    private var leading: some View {
        HStack(spacing: SetRowMetrics.spacing) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(set.completed ? Color.brandGreen : Color.secondary)
                .frame(width: SetRowMetrics.number)
            Button(action: onUsePrevious) {
                Text(previousText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: SetRowMetrics.fieldHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(previous == nil || set.completed)
            .accessibilityLabel(previous == nil ? "No previous set" : "Previous: \(previousText). Tap to copy.")
        }
        .contextMenu {
            if previous != nil, !set.completed {
                Button { onUsePrevious() } label: { Label("Use Previous", systemImage: "arrow.uturn.backward") }
            }
            Button(role: .destructive, action: onDelete) { Label("Delete Set", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch tracking {
        case .timed:
            DurationEntryField(seconds: set.durationSecs ?? 0) { set.durationSecs = $0 > 0 ? $0 : nil }
                .frame(width: SetRowMetrics.weight + SetRowMetrics.reps + SetRowMetrics.spacing)
                .disabled(set.completed)
            Color.clear.frame(width: SetRowMetrics.rir, height: 1)
        case .weighted, .bodyweight:
            NumberEntryField(
                placeholder: tracking == .bodyweight ? "BW" : "–",
                value: TrainingUnits.toDisplay(set.weight, unit),
                decimals: true,
                onChange: { set.weight = TrainingUnits.toPounds($0, from: unit) }
            )
            .frame(width: SetRowMetrics.weight)
            .disabled(set.completed)
            .accessibilityLabel(tracking == .bodyweight ? "Added weight, \(unit.label)" : "Weight, \(unit.label)")
            NumberEntryField(placeholder: "–", value: Double(set.reps), decimals: false,
                             onChange: { set.reps = Int($0) })
                .frame(width: SetRowMetrics.reps)
                .disabled(set.completed)
                .accessibilityLabel("Reps")
            RIRPicker(rir: $set.rir)
        }
    }

    private var checkButton: some View {
        Button(action: onToggle) {
            Image(systemName: set.completed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.title2)
                .foregroundStyle(set.completed ? Color.brandGreen : Color.secondary)
                .frame(width: SetRowMetrics.check, height: max(SetRowMetrics.fieldHeight, 36))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(set.completed ? "Set \(number) done. Tap to undo." : "Complete set \(number)")
    }

    private var previousText: String {
        guard let previous else { return "–" }
        switch tracking {
        case .timed:
            return TrainingUnits.duration(previous.durationSecs ?? 0)
        case .bodyweight:
            let load = previous.weight > 0 ? "+" + TrainingUnits.weight(previous.weight, unit, withUnit: false) : "BW"
            return "\(load) × \(previous.reps)"
        case .weighted:
            return "\(TrainingUnits.weight(previous.weight, unit, withUnit: false)) × \(previous.reps)"
        }
    }
}

// MARK: - Entry controls

/// A numeric text field that keeps its own text while editing and reports
/// parsed values. 0 shows as empty with a placeholder.
struct NumberEntryField: View {
    let placeholder: String
    let value: Double
    let decimals: Bool
    let onChange: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .multilineTextAlignment(.leading)
            .font(.body.monospacedDigit())
            .textFieldStyle(.plain)
            #if os(iOS)
            .keyboardType(decimals ? .decimalPad : .numberPad)
            #endif
            .frame(maxWidth: .infinity, minHeight: SetRowMetrics.fieldHeight)
            .background(Color.platformTextBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: focused ? 1.5 : 1)
            )
            .onAppear { text = Self.format(value, decimals) }
            .onChange(of: value) { _, newValue in
                if !focused { text = Self.format(newValue, decimals) }
            }
            .onChange(of: text) { _, newText in commit(newText) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = Self.format(value, decimals) }
            }
    }

    private func commit(_ newText: String) {
        let cleaned = newText.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        if cleaned.isEmpty {
            if value != 0 { onChange(0) }
            return
        }
        guard let parsed = Double(cleaned), parsed >= 0, parsed < 10_000 else { return }
        let next = decimals ? parsed : parsed.rounded(.down)
        if abs(next - value) > 0.0001 { onChange(next) }
    }

    static func format(_ value: Double, _ decimals: Bool) -> String {
        guard value > 0 else { return "" }
        return decimals ? TrainingUnits.number(value) : String(Int(value))
    }
}

/// Seconds, entered as "90" or "1:30".
struct DurationEntryField: View {
    let seconds: Int
    let onChange: (Int) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("m:ss", text: $text)
            .focused($focused)
            .multilineTextAlignment(.leading)
            .font(.body.monospacedDigit())
            .textFieldStyle(.plain)
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
            .frame(maxWidth: .infinity, minHeight: SetRowMetrics.fieldHeight)
            .background(Color.platformTextBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: focused ? 1.5 : 1)
            )
            .onAppear { text = Self.format(seconds) }
            .onChange(of: seconds) { _, newValue in if !focused { text = Self.format(newValue) } }
            .onChange(of: text) { _, newText in
                let parsed = Self.parse(newText)
                if parsed != seconds { onChange(parsed) }
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { text = Self.format(seconds) } }
            .accessibilityLabel("Duration")
    }

    static func format(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func parse(_ text: String) -> Int {
        let parts = text.split(separator: ":").map { Int($0.filter(\.isNumber)) ?? 0 }
        switch parts.count {
        case 0: return 0
        case 1: return min(parts[0], 24 * 3600)
        default: return min(parts[0] * 60 + parts[1], 24 * 3600)
        }
    }
}

/// Reps in reserve, 0–5, or not logged.
struct RIRPicker: View {
    @Binding var rir: Int?

    var body: some View {
        Menu {
            Button("Not logged") { rir = nil }
            ForEach(0...5, id: \.self) { value in
                Button(value == 0 ? "0 (to failure)" : "\(value) in reserve") { rir = value }
            }
        } label: {
            Text(rir.map(String.init) ?? "–")
                .font(.body.monospacedDigit())
                .foregroundStyle(rir == nil ? Color.secondary : Color.primary)
                .frame(width: SetRowMetrics.rir, height: SetRowMetrics.fieldHeight)
                .background(Color.platformTextBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Reps in reserve")
        .accessibilityValue(rir.map(String.init) ?? "not logged")
    }
}

// MARK: - Plates

struct PlateHintView: View {
    let weightLb: Double
    let unit: WeightUnit
    @State private var showDetail = false

    var body: some View {
        let total = TrainingUnits.toDisplay(weightLb, unit)
        let breakdown = PlateMath.breakdown(total: total, bar: PlateMath.defaultBar(for: unit), unit: unit)
        Button { showDetail = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.grid.2x1.fill")
                    .foregroundStyle(Color.brandYellow)
                Text("\(TrainingUnits.number(total)) \(unit.label): \(breakdown.summary)")
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !breakdown.isExact, !breakdown.isBelowBar {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plate breakdown")
        .popover(isPresented: $showDetail) {
            PlateBreakdownView(total: total, unit: unit)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct PlateBreakdownView: View {
    let total: Double
    let unit: WeightUnit
    @State private var bar: Double

    init(total: Double, unit: WeightUnit) {
        self.total = total
        self.unit = unit
        _bar = State(initialValue: PlateMath.defaultBar(for: unit))
    }

    private var bars: [Double] { unit == .kg ? [20, 15, 10] : [45, 35, 15] }

    var body: some View {
        let breakdown = PlateMath.breakdown(total: total, bar: bar, unit: unit)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(TrainingUnits.number(total)) \(unit.label)")
                .font(.title2.bold())
            Picker("Bar", selection: $bar) {
                ForEach(bars, id: \.self) { Text("\(TrainingUnits.number($0)) \(unit.label) bar").tag($0) }
            }
            .compactSegmentedPicker()
            if breakdown.isBelowBar {
                Text("Lighter than the bar.").foregroundStyle(.secondary)
            } else if breakdown.perSide.isEmpty {
                Text("Empty bar.").foregroundStyle(.secondary)
            } else {
                Text("Per side").font(.caption).foregroundStyle(.secondary)
                ForEach(breakdown.perSide) { plate in
                    HStack {
                        Text("\(TrainingUnits.number(plate.weight)) \(unit.label)").bold()
                        Spacer()
                        Text("× \(plate.count)").monospacedDigit()
                    }
                }
            }
            if !breakdown.isExact, !breakdown.isBelowBar {
                Label("Standard plates can't make this exactly. Closest: \(TrainingUnits.number(breakdown.loadable)) \(unit.label) (\(TrainingUnits.number(breakdown.remainderPerSide)) \(unit.label) short per side).",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(minWidth: 260)
    }
}

// MARK: - Rep range

struct RepRangeEditor: View {
    let exercise: Exercise
    @State private var low: Int
    @State private var high: Int
    @Environment(\.dismiss) private var dismiss

    init(exercise: Exercise) {
        self.exercise = exercise
        let range = ProgressionEngine.repRange(for: exercise)
        _low = State(initialValue: range.lowerBound)
        _high = State(initialValue: range.upperBound)
    }

    private var setByProgram: Bool { exercise.targetRepMin != nil && exercise.targetRepMax != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rep range").font(.headline)
            Text("When every working set reaches the top of the range with at least 1 rep in reserve, the next session suggests more load.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if setByProgram {
                Text("This workout's program sets \(low)–\(high) reps.")
                    .font(.callout)
            } else {
                Stepper("Low: \(low)", value: $low, in: 1...50)
                    .onChange(of: low) { _, v in if high < v { high = v } }
                Stepper("High: \(high)", value: $high, in: 1...50)
                    .onChange(of: high) { _, v in if low > v { low = v } }
                HStack {
                    Button("Use Default") {
                        ProgressionSettings.setCustomRange(nil, for: exercise.identityKey)
                        dismiss()
                    }
                    Spacer()
                    Button("Save") {
                        ProgressionSettings.setCustomRange(low...high, for: exercise.identityKey)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(minWidth: 280)
    }
}
