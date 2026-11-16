//
//  ProgramWizard.swift
//  Endgame Fitness
//
//  The "Build your program" flow. Onboarding no longer auto-generates a
//  routine; instead the first-login dashboard shows a calm setup state whose
//  single call-to-action opens this multi-step sheet. Every answer feeds
//  WorkoutManager.generateProgram(with:) so the resulting mesocycle respects
//  training days, split, session length, cycle length, deload and goal.
//

import SwiftUI

// MARK: - Config types

enum ProgramSplit: String, CaseIterable, Identifiable {
    case auto = "Auto-recommend"
    case fullBody = "Full Body"
    case upperLower = "Upper / Lower"
    case ppl = "Push / Pull / Legs"
    var id: String { rawValue }
}

enum ProgressionStyle: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case linear = "Linear"
    case double = "Double Progression"
    case rpe = "RPE / RIR"
    case waves = "Percentage Waves"
    var id: String { rawValue }

    /// Short labels: five segments have to fit at 390pt.
    var shortLabel: String {
        switch self {
        case .double: return "Double"
        case .rpe: return "RPE"
        case .waves: return "Waves"
        default: return rawValue
        }
    }
}

/// Weekly = fixed weekdays. Rolling = X days on, Y days off, repeating
/// regardless of the calendar week (e.g. 3 on / 1 off).
enum ScheduleMode: String, CaseIterable, Identifiable {
    case weekly = "Weekly"
    case rolling = "Days on / off"
    var id: String { rawValue }
}

/// Session length choices shared by every place a user picks minutes:
/// quick presets up to two hours plus a custom value in 5-minute steps.
enum SessionLength {
    static let presets = [30, 45, 60, 90, 120]
    static let range = 15...120
    static let step = 5
    static func clamp(_ minutes: Int) -> Int {
        let snapped = (minutes + step / 2) / step * step
        return min(range.upperBound, max(range.lowerBound, snapped))
    }
}

struct SessionLengthPicker: View {
    @Binding var minutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Session length", selection: $minutes) {
                // Five segments at 390pt: "30 min" clips, "30m" does not.
                ForEach(SessionLength.presets, id: \.self) { Text($0 == 120 ? "2h" : "\($0)m").tag($0) }
            }
            .compactSegmentedPicker()
            .labelsHidden()
            Stepper("Custom: \(minutes) min", value: $minutes,
                    in: SessionLength.range, step: SessionLength.step)
        }
    }
}

struct ProgramConfig {
    var scheduleMode: ScheduleMode = .weekly
    var daysOn: Int = 3
    var daysOff: Int = 1
    var daysPerWeek: Int = 4
    var weekdays: Set<String> = ["Monday", "Tuesday", "Thursday", "Friday"]
    var sessionLength: Int = 60
    var mesocycleWeeks: Int = 6
    var includeDeload: Bool = true
    var experienceLevel: ExperienceLevel = .beginner
    var primaryGoal: TrainingGoal = .generalFitness
    var equipment: EquipmentLevel = .fullGym
    var injuries: Set<String> = []
    var split: ProgramSplit = .auto
    var progression: ProgressionStyle = .auto

    /// Training frequency used to pick a split. Rolling cycles are converted
    /// to their average sessions per 7 days (3 on / 1 off ≈ 5.25 → 5).
    var effectiveDaysPerWeek: Int {
        guard scheduleMode == .rolling else { return daysPerWeek }
        let perWeek = 7.0 * Double(daysOn) / Double(daysOn + daysOff)
        return min(6, max(2, Int(perWeek.rounded())))
    }

    /// Session count the program generates: one per training day.
    var sessionCount: Int { scheduleMode == .rolling ? daysOn : daysPerWeek }
}

// MARK: - Calm first-login dashboard

struct GetSetUpView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @ObservedObject private var game = GameProfileService.shared
    var onBuildProgram: () -> Void

    private var firstName: String {
        let name = workoutManager.userProfile?.name ?? game.profile?.displayName ?? ""
        return name.split(separator: " ").first.map(String.init) ?? "there"
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.brandPurple)
                Text("Welcome, \(firstName)")
                    .font(.screenTitle.bold())
                    .adaptiveHeading()
                Text("One step left: build the program you'll train on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Single primary call-to-action.
            Button(action: onBuildProgram) {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Build your program")
                            .font(.title3.bold())
                        Text("A short setup: days, split, cycle length and goals")
                            .font(.caption)
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundColor(.white)
                .padding(20)
                .background(
                    LinearGradient(colors: [.brandPurple, .brandBlue],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .shadow(color: .brandPurple.opacity(0.3), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 480)

            // Just the two light chips — no grid, no cards.
            HStack(spacing: 12) {
                SetupChip(icon: "flame.fill", tint: .orange,
                          text: "\(workoutManager.currentStreak)-day streak")
                if let level = game.profile?.level {
                    SetupChip(icon: "star.fill", tint: .brandPurple, text: "Level \(level)")
                }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SetupChip: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - Wizard

struct ProgramWizardView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @Environment(\.dismiss) private var dismiss

    @State private var config = ProgramConfig()
    @State private var step = 0
    private let totalSteps = 5

    private let weekOrder = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private let injuryOptions = ["Low back", "Shoulder", "Knee"]

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                Group {
                    switch step {
                    case 0: scheduleStep
                    case 1: cycleStep
                    case 2: goalStep
                    case 3: equipmentStep
                    default: splitStep
                    }
                }
                .adaptivePadding(24)
                .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity)

            footer
        }
        .desktopMinFrame(minWidth: 620, minHeight: 560)
        .onAppear(perform: prefill)
    }

    // Prefill from the onboarding answers so nothing is asked twice cold.
    private func prefill() {
        guard let profile = workoutManager.userProfile else { return }
        config.experienceLevel = profile.experienceLevel
        config.equipment = profile.availableEquipment
        if let goal = profile.primaryGoals.first { config.primaryGoal = goal }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Build Your Program")
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.brandPurple : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button(step < totalSteps - 1 ? "Continue" : "Generate Program") {
                if step < totalSteps - 1 {
                    withAnimation { step += 1 }
                } else {
                    workoutManager.generateProgram(with: config)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandPurple)
            .disabled(step == 0 && config.scheduleMode == .weekly && config.weekdays.isEmpty)
        }
        .padding(20)
    }

    private func card<Content: View>(_ title: String, icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(Color.brandPurple)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // Step 0 — schedule
    private var scheduleStep: some View {
        VStack(spacing: 16) {
            card("Training Days", icon: "calendar") {
                Picker("Schedule", selection: $config.scheduleMode) {
                    ForEach(ScheduleMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .compactSegmentedPicker()
                .labelsHidden()

                if config.scheduleMode == .weekly {
                Stepper("Days per week: \(config.daysPerWeek)",
                        value: $config.daysPerWeek, in: 2...6)
                    .onChange(of: config.daysPerWeek) { _, _ in trimWeekdays() }

                Text("Which days?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 8) {
                    ForEach(weekOrder, id: \.self) { day in
                        let on = config.weekdays.contains(day)
                        Button(action: { toggleDay(day) }) {
                            Text(day.prefix(3))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(on ? Color.brandPurple : Color.gray.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .foregroundColor(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                            } else {
                    Stepper("Days on: \(config.daysOn)", value: $config.daysOn, in: 1...7)
                    Stepper("Days off: \(config.daysOff)", value: $config.daysOff, in: 1...7)
                    Text("Repeats every \(config.daysOn + config.daysOff) days, starting today — not tied to the calendar week.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(0..<(config.daysOn + config.daysOff), id: \.self) { i in
                            let on = i < config.daysOn
                            Text(on ? "Train" : "Rest")
                                .font(.caption2.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(on ? Color.brandPurple : Color.gray.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .foregroundColor(on ? .white : .primary)
                        }
                    }
                }
            }

            card("Session Length", icon: "clock") {
                SessionLengthPicker(minutes: $config.sessionLength)
            }
        }
    }

    private func toggleDay(_ day: String) {
        if config.weekdays.contains(day) {
            config.weekdays.remove(day)
        } else if config.weekdays.count < config.daysPerWeek {
            config.weekdays.insert(day)
        }
    }

    private func trimWeekdays() {
        while config.weekdays.count > config.daysPerWeek {
            if let last = weekOrder.reversed().first(where: { config.weekdays.contains($0) }) {
                config.weekdays.remove(last)
            }
        }
    }

    // Step 1 — mesocycle
    private var cycleStep: some View {
        VStack(spacing: 16) {
            card("Mesocycle Length", icon: "calendar.badge.clock") {
                Picker("Weeks", selection: $config.mesocycleWeeks) {
                    ForEach([4, 6, 8, 12], id: \.self) { Text("\($0) wk").tag($0) }
                }
                .compactSegmentedPicker()
                .labelsHidden()
                Toggle("End the cycle with a deload week", isOn: $config.includeDeload)
                    .tint(.brandPurple)
            }

            card("Progression Style", icon: "chart.line.uptrend.xyaxis") {
                Picker("Progression", selection: $config.progression) {
                    ForEach(ProgressionStyle.allCases) { Text($0.shortLabel).tag($0) }
                }
                .compactSegmentedPicker()
                .labelsHidden()
                Text(config.progression.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Step 2 — goal + experience check-in
    private var goalStep: some View {
        VStack(spacing: 16) {
            card("Primary Goal", icon: "target") {
                let stored = workoutManager.userProfile?.primaryGoals ?? []
                let options: [TrainingGoal] = stored.isEmpty
                    ? [.buildMuscle, .getStronger, .loseWeight, .improveEndurance, .generalFitness, .longevity]
                    : stored
                Picker("Goal", selection: $config.primaryGoal) {
                    ForEach(options, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .wizardRadioStyle()
                .labelsHidden()
            }

            card("Experience Check-in", icon: "figure.strengthtraining.traditional") {
                Picker("Experience", selection: $config.experienceLevel) {
                    // Short labels: "Intermediate" truncates in a 4-segment control on 390pt screens.
                    Text("New").tag(ExperienceLevel.beginner)
                    Text("Mid").tag(ExperienceLevel.intermediate)
                    Text("Adv").tag(ExperienceLevel.advanced)
                    Text("Expert").tag(ExperienceLevel.expert)
                }
                .compactSegmentedPicker()
                .labelsHidden()
            }
        }
    }

    // Step 3 — equipment + limitations
    private var equipmentStep: some View {
        VStack(spacing: 16) {
            card("Equipment", icon: "dumbbell") {
                Picker("Equipment", selection: $config.equipment) {
                    Text("Full Gym").tag(EquipmentLevel.fullGym)
                    Text("Home Gym").tag(EquipmentLevel.homeGym)
                    Text("Minimal").tag(EquipmentLevel.minimal)
                    Text("Bodyweight").tag(EquipmentLevel.bodyweight)
                }
                .compactSegmentedPicker()
                .labelsHidden()
            }

            card("Injuries or Limitations", icon: "cross.case") {
                ForEach(injuryOptions, id: \.self) { injury in
                    Toggle(injury, isOn: Binding(
                        get: { config.injuries.contains(injury) },
                        set: { on in
                            if on { config.injuries.insert(injury) }
                            else { config.injuries.remove(injury) }
                        }
                    ))
                    .tint(.brandPurple)
                }
                Toggle("None", isOn: Binding(
                    get: { config.injuries.isEmpty },
                    set: { if $0 { config.injuries.removeAll() } }
                ))
                .tint(.brandPurple)
                Text("Flagged areas get safer substitutions in the generated plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Step 4 — split + review
    private var splitStep: some View {
        VStack(spacing: 16) {
            card("Preferred Split", icon: "square.grid.2x2") {
                Picker("Split", selection: $config.split) {
                    ForEach(ProgramSplit.allCases) { Text($0.rawValue).tag($0) }
                }
                .wizardRadioStyle()
                .labelsHidden()
                if config.split == .auto {
                    Text("Recommended for you: \(workoutManager.resolvedSplit(for: config).rawValue)")
                        .font(.caption)
                        .foregroundStyle(Color.brandPurple)
                }
            }

            card("Review", icon: "checkmark.seal") {
                if config.scheduleMode == .rolling {
                    reviewRow("Days", "\(config.daysOn) on / \(config.daysOff) off, repeating")
                } else {
                    reviewRow("Days", "\(config.daysPerWeek)/week — \(weekOrder.filter { config.weekdays.contains($0) }.map { String($0.prefix(3)) }.joined(separator: ", "))")
                }
                reviewRow("Sessions", "\(config.sessionLength) min")
                reviewRow("Cycle", "\(config.mesocycleWeeks) weeks\(config.includeDeload ? " + deload" : "")")
                reviewRow("Goal", config.primaryGoal.rawValue)
                reviewRow("Split", workoutManager.resolvedSplit(for: config).rawValue)
                reviewRow("Progression", config.progression.rawValue)
                if !config.injuries.isEmpty {
                    reviewRow("Protecting", config.injuries.sorted().joined(separator: ", "))
                }
            }
        }
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

private extension View {
    @ViewBuilder func wizardRadioStyle() -> some View {
        #if os(macOS)
        self.pickerStyle(.radioGroup)
        #else
        self.pickerStyle(.inline)
        #endif
    }
}
