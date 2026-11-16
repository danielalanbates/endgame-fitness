//
//  HistoryViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://batesai.org · help@batesai.org
//
//  Workout history: the session list, a session's detail, and editing or
//  deleting a past session. Edits re-queue the session with the next sync
//  revision; deletes send a tombstone (see TrainingSync.swift).
//

import SwiftUI

// MARK: - List

struct HistoryListView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"

    private var unit: WeightUnit { TrainingUnits.unit(forPreference: unitPreference) }

    private var months: [(title: String, sessions: [WorkoutSession])] {
        let calendar = Calendar.current
        let sorted = workoutManager.loggedSessions.sorted { $0.date > $1.date }
        var groups: [(String, [WorkoutSession])] = []
        var currentKey: DateComponents?
        for session in sorted {
            let key = calendar.dateComponents([.year, .month], from: session.date)
            if key != currentKey {
                groups.append((session.date.formatted(.dateTime.month(.wide).year()), []))
                currentKey = key
            }
            groups[groups.count - 1].1.append(session)
        }
        return groups.map { (title: $0.0, sessions: $0.1) }
    }

    var body: some View {
        Group {
            if workoutManager.loggedSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No workouts yet")
                        .font(.headline)
                    Text("Finished workouts show up here. Tap one to see every set, edit it or delete it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(months, id: \.title) { month in
                        Section(month.title) {
                            ForEach(month.sessions) { session in
                                NavigationLink {
                                    SessionDetailView(sessionID: session.id)
                                } label: {
                                    HistoryRow(session: session, unit: unit)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}

struct HistoryRow: View {
    let session: WorkoutSession
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !exerciseNames.isEmpty {
                Text(exerciseNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        var parts: [String] = []
        if let duration = session.duration, duration > 0 { parts.append("\(Int(duration / 60)) min") }
        if session.completedSetCount > 0 { parts.append("\(session.completedSetCount) sets") }
        if session.totalVolume > 0 { parts.append(TrainingUnits.volume(session.totalVolume, unit)) }
        return parts.joined(separator: " · ")
    }

    private var exerciseNames: String {
        session.exercises.map(\.name).joined(separator: ", ")
    }
}

// MARK: - Detail

struct SessionDetailView: View {
    let sessionID: UUID
    @EnvironmentObject var workoutManager: WorkoutManager
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WorkoutSession?
    @State private var confirmDelete = false

    private var unit: WeightUnit { TrainingUnits.unit(forPreference: unitPreference) }
    private var session: WorkoutSession? { workoutManager.sessions.first { $0.id == sessionID } }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                Text("This workout was deleted.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session?.displayName ?? "Workout")
        .toolbar {
            if let session {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { editing = session } label: { Label("Edit Workout", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Workout", systemImage: "trash") }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            SessionEditorView(original: draft)
                .environmentObject(workoutManager)
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) {
                workoutManager.deleteSession(sessionID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WorkoutSyncBridge.enqueue != nil
                 ? "It will be removed from your history. XP already earned is kept."
                 : "It will be removed from this device's history.")
        }
    }

    private func content(_ session: WorkoutSession) -> some View {
        let history = workoutManager.loggedSessions
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.date.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SessionStatsRow(session: session, unit: unit)
                }
                if session.exercises.isEmpty {
                    Text("This workout was logged without set details (for example on an older app version).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(session.exercises) { exercise in
                    SessionExerciseSummary(exercise: exercise, session: session, history: history, unit: unit)
                }
                if let notes = session.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.headline)
                        Text(notes).font(.callout)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SessionStatsRow: View {
    let session: WorkoutSession
    let unit: WeightUnit

    var body: some View {
        HStack(spacing: 16) {
            stat(session.duration.map { "\(Int($0 / 60)) min" } ?? "–", "duration")
            stat("\(session.completedSetCount)", "sets")
            stat(TrainingUnits.volume(session.totalVolume, unit), "volume")
            if let xp = session.xpEarned, xp > 0 { stat("+\(xp)", "XP") }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SessionExerciseSummary: View {
    let exercise: Exercise
    let session: WorkoutSession
    let history: [WorkoutSession]
    let unit: WeightUnit

    var body: some View {
        let earlier = history.filter { $0.date < session.date }
        VStack(alignment: .leading, spacing: 6) {
            Text(exercise.name)
                .font(.headline)
                .foregroundStyle(Color.brandBlue)
            ForEach(Array(exercise.completedSets.enumerated()), id: \.element.id) { index, set in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(describe(set))
                        .font(.body.monospacedDigit())
                    if let rir = set.rir {
                        Text("RIR \(rir)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ProgressionEngine.isPersonalRecord(set, in: exercise, history: earlier, current: priorSetsOnly(upTo: set)) {
                        Label("PR", systemImage: "trophy.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Color.brandOrange)
                    }
                    if set.reps > 0, set.weight > 0 {
                        Text("e1RM \(TrainingUnits.weight(ProgressionEngine.e1RM(weight: set.weight, reps: set.reps), unit))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The session as it stood just before `set`, so a PR is judged only
    /// against what came earlier.
    private func priorSetsOnly(upTo set: ExerciseSet) -> WorkoutSession {
        var copy = session
        var seen = false
        for i in copy.exercises.indices {
            copy.exercises[i].sets = copy.exercises[i].sets.filter { s in
                if seen { return false }
                if s.id == set.id { seen = true; return false }
                return true
            }
        }
        return copy
    }

    private func describe(_ set: ExerciseSet) -> String {
        switch exercise.resolvedTracking {
        case .timed:
            return TrainingUnits.duration(set.durationSecs ?? 0)
        case .bodyweight:
            return set.weight > 0 ? "+\(TrainingUnits.weight(set.weight, unit)) × \(set.reps)" : "\(set.reps) reps"
        case .weighted:
            return "\(TrainingUnits.weight(set.weight, unit)) × \(set.reps)"
        }
    }
}

// MARK: - Editor

struct SessionEditorView: View {
    let original: WorkoutSession
    @EnvironmentObject var workoutManager: WorkoutManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TrainingUnits.preferenceKey) private var unitPreference = "imperial"
    @State private var draft: WorkoutSession
    @State private var showPicker = false
    @State private var confirmEmpty = false

    init(original: WorkoutSession) {
        self.original = original
        _draft = State(initialValue: original)
    }

    private var unit: WeightUnit { TrainingUnits.unit(forPreference: unitPreference) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    details
                    ForEach($draft.exercises) { $exercise in
                        ExerciseLogCard(
                            exercise: $exercise,
                            history: workoutManager.loggedSessions,
                            excludingSession: draft.id,
                            unit: unit,
                            live: false,
                            onRemove: { draft.exercises.removeAll { $0.id == exercise.id } }
                        )
                    }
                    Button { showPicker = true } label: {
                        Label("Add Exercise", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    Text("Only ticked sets are saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Workout")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft == original)
                }
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView { entry, customName in add(entry, customName) }
            }
            .alert("No completed sets", isPresented: $confirmEmpty) {
                Button("Delete Workout", role: .destructive) {
                    workoutManager.deleteSession(original.id)
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("A workout needs at least one ticked set. Delete it instead?")
            }
        }
        .desktopSheetFrame(width: 640, height: 720)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Workout name", text: Binding(
                get: { draft.programName ?? "" },
                set: { draft.programName = $0.isEmpty ? nil : $0 }
            ))
            .font(.headline)
            .textFieldStyle(.roundedBorder)
            DatePicker("Date", selection: $draft.date, in: ...Date())
            TextField("Notes", text: Binding(
                get: { draft.notes ?? "" },
                set: { draft.notes = $0.isEmpty ? nil : $0 }
            ), axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func add(_ entry: LibraryExercise?, _ customName: String?) {
        let name = entry?.name ?? customName ?? ""
        guard !name.isEmpty else { return }
        var exercise = Exercise(name: name, exerciseID: entry?.id, category: entry?.category, primaryMuscles: entry?.primary)
        if entry == nil { WorkoutManager.attachLibraryMatch(&exercise) }
        exercise.tracking = exercise.resolvedTracking
        exercise.sets = ProgressionEngine.plannedSets(for: exercise, history: workoutManager.loggedSessions, excluding: draft.id)
        draft.exercises.append(exercise)
    }

    private func save() {
        Platform.dismissKeyboard()
        guard draft.completedSetCount > 0 else {
            confirmEmpty = true
            return
        }
        workoutManager.updateSession(draft)
        dismiss()
    }
}
