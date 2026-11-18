//
//  SessionGameLayer.swift
//  Endgame Fitness
//
//  The "combat log" layer over a live workout: an auto-starting rest timer,
//  floating "+N XP" / "PR!" / "Combo" pop-ups when a set is logged, and a
//  session summary with a shareable card when the workout is finished.
//
//  Everything here is client-side flavour. XP shown is an ESTIMATE that mirrors
//  the server's formula (Backend/functions/api/fitness/[[path]].js,
//  xpForWorkout); the server stays authoritative and the UI says "est." so the
//  number is never mistaken for the real award.
//
//  Hooks into WorkoutTrackerMac_Enhanced.swift are marked
//  `// SessionGameLayer hook` and are deliberately tiny.
//

import SwiftUI
import Combine
#if os(iOS)
import UserNotifications
#endif

// MARK: - Settings keys

enum SessionGameSettings {
    static let restSecondsKey = "defaultRestTime"        // shared with the existing Settings field
    static let hapticsKey = "sessionGame.haptics"
    static let xpPopupsKey = "sessionGame.xpPopups"
    static let restSoundKey = "sessionGame.restSound"
    static let restTimerKey = "sessionGame.restTimer"

    static func exerciseRestKey(_ name: String) -> String { "sessionGame.rest.\(name)" }

    static var defaultRestSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: restSecondsKey)
        return v > 0 ? v : 90
    }
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
    }
    static var xpPopupsEnabled: Bool {
        UserDefaults.standard.object(forKey: xpPopupsKey) as? Bool ?? true
    }
    static var restTimerEnabled: Bool {
        UserDefaults.standard.object(forKey: restTimerKey) as? Bool ?? true
    }
    static var restSoundEnabled: Bool {
        UserDefaults.standard.bool(forKey: restSoundKey)   // off by default
    }

    /// Per-exercise override, falling back to the global default.
    static func restSeconds(for exercise: String) -> Int {
        let v = UserDefaults.standard.integer(forKey: exerciseRestKey(exercise))
        return v > 0 ? v : defaultRestSeconds
    }
}

// MARK: - XP estimate (mirrors the server formula)

enum XPEstimator {
    /// Same shape as `xpForWorkout` in the fitness worker. Keep in sync.
    static func sessionXP(volume: Double, reps: Int, durationSecs: Int) -> Int {
        let volumeXP = pow(max(volume, 0), 0.8) * 0.35
        let repXP = Double(max(reps, 0)) * 0.5
        let timeXP = min(max(Double(durationSecs), 0) / 60, 120) * 1.5
        return max(10, Int((volumeXP + repXP + timeXP).rounded()))
    }

    /// Marginal XP of one set = session estimate after minus before (volume and
    /// reps only; the time component accrues regardless of the set).
    static func setXP(volumeBefore: Double, repsBefore: Int, set: ExerciseSet) -> Int {
        let before = pow(max(volumeBefore, 0), 0.8) * 0.35 + Double(repsBefore) * 0.5
        let volumeAfter = volumeBefore + Double(set.reps) * set.weight
        let after = pow(max(volumeAfter, 0), 0.8) * 0.35 + Double(repsBefore + set.reps) * 0.5
        return max(1, Int((after - before).rounded()))
    }

    /// Epley estimated one-rep max; used for PR detection.
    static func e1RM(_ set: ExerciseSet) -> Double {
        guard set.reps > 0, set.weight > 0 else { return 0 }
        return set.weight * (1 + Double(set.reps) / 30)
    }
}

// MARK: - Floating pop-up model

struct XPPopup: Identifiable, Equatable {
    enum Kind: Equatable { case xp, pr, combo }
    let id = UUID()
    let text: String
    let kind: Kind
    let xOffset: CGFloat
}

// MARK: - Session game state

/// Not `@MainActor`-isolated because `WorkoutManager` isn't; every caller is
/// on the main thread in practice (SwiftUI actions, Timer on the main run loop).
final class SessionGame: ObservableObject {
    static let shared = SessionGame()

    // Rest timer
    @Published private(set) var restRemaining: Int = 0
    @Published private(set) var restTotal: Int = 0
    @Published private(set) var restExercise: String = ""
    var restActive: Bool { restRemaining > 0 && restTotal > 0 }

    // Pop-ups
    @Published var popups: [XPPopup] = []

    // Running session stats
    @Published private(set) var sessionEstimatedXP: Int = 0
    @Published private(set) var combo: Int = 0
    @Published private(set) var prExercises: [String] = []
    @Published private(set) var setsLogged: Int = 0

    private var restTimer: Timer?
    private var restEndsAt: Date?
    private var lastExerciseForCombo: UUID?
    private var notificationPermissionAsked = false
    private let restNotificationID = "sessionGame.restOver"

    private init() {}

    // MARK: Session lifecycle

    func sessionStarted() {
        stopRest()
        popups.removeAll()
        sessionEstimatedXP = 0
        combo = 0
        prExercises = []
        setsLogged = 0
        lastExerciseForCombo = nil
    }

    /// A workout restored at launch (or after an account switch): rebuild the
    /// running numbers from its completed sets. No pop-ups, no rest timer.
    func resume(with workout: WorkoutSession, history: [WorkoutSession]) {
        sessionStarted()
        recalculate(for: workout, history: history)
    }

    /// Recomputes the estimate, set count and PR list after a set was
    /// un-ticked or deleted, so the summary never credits undone work.
    func recalculate(for workout: WorkoutSession, history: [WorkoutSession]) {
        let completed = workout.completedSets
        let volume = completed.reduce(0.0) { $0 + $1.volume }
        let reps = completed.reduce(0) { $0 + max($1.reps, 0) }
        setsLogged = completed.count
        sessionEstimatedXP = reps > 0 ? XPEstimator.sessionXP(volume: volume, reps: reps, durationSecs: 0) : 0
        var prs: [String] = []
        for exercise in workout.exercises where !prs.contains(exercise.name) {
            if exercise.completedSets.contains(where: {
                ProgressionEngine.isPersonalRecord($0, in: exercise, history: history, current: workout)
            }) {
                prs.append(exercise.name)
            }
        }
        prExercises = prs
        if completed.isEmpty { combo = 0 }
    }

    // MARK: Set logged

    /// Called from `WorkoutManager.toggleSetCompleted` when a set is ticked.
    /// `workout` is the session state including the set; `history` holds the
    /// finished workouts used for PR detection.
    func setLogged(_ set: ExerciseSet, in exercise: Exercise, workout: WorkoutSession, history: [WorkoutSession]) {
        setsLogged += 1

        // XP estimate for this set (marginal against the session before it).
        let allSets = workout.completedSets
        let volumeAfter = allSets.reduce(0.0) { $0 + $1.volume }
        let repsAfter = allSets.reduce(0) { $0 + $1.reps }
        let volumeBefore = volumeAfter - Double(set.reps) * set.weight
        let repsBefore = repsAfter - set.reps
        let xp = XPEstimator.setXP(volumeBefore: volumeBefore, repsBefore: repsBefore, set: set)
        sessionEstimatedXP = XPEstimator.sessionXP(volume: volumeAfter, reps: repsAfter, durationSecs: 0)

        // Combo: consecutive logged sets that hit the planned rep target.
        let target = targetReps(for: exercise, excluding: set.id)
        if set.reps >= target {
            combo = (lastExerciseForCombo == exercise.id || lastExerciseForCombo == nil) ? combo + 1 : 1
        } else {
            combo = 0
        }
        lastExerciseForCombo = exercise.id

        // PR, by the server's rule: more weight than ever before at this rep
        // count (completed sets only, including earlier sets today). The first
        // time a rep count is logged is the baseline, not a PR.
        let isPR = ProgressionEngine.isPersonalRecord(set, in: exercise, history: history, current: workout)
        if isPR, !prExercises.contains(exercise.name) { prExercises.append(exercise.name) }

        if SessionGameSettings.xpPopupsEnabled {
            push(XPPopup(text: "+\(xp) XP", kind: .xp, xOffset: 0))
            if isPR { push(XPPopup(text: "PR!", kind: .pr, xOffset: 70), delay: 0.25) }
            if combo >= 2 { push(XPPopup(text: "Combo x\(combo)", kind: .combo, xOffset: -70), delay: 0.4) }
        }

        if SessionGameSettings.hapticsEnabled {
            isPR ? Platform.success() : Platform.impact(.medium)
        }

        if SessionGameSettings.restTimerEnabled {
            startRest(seconds: SessionGameSettings.restSeconds(for: exercise.name), exercise: exercise.name)
        }
    }

    /// Planned reps = the first still-unlogged planned set's reps, else the
    /// median of the sets already logged, else 8.
    private func targetReps(for exercise: Exercise, excluding setID: UUID) -> Int {
        if let planned = exercise.sets.first(where: { !$0.completed && $0.reps > 0 }) { return planned.reps }
        let logged = exercise.sets.filter { $0.completed && $0.id != setID }.map { $0.reps }.sorted()
        if !logged.isEmpty { return logged[logged.count / 2] }
        return 8
    }

    private func push(_ popup: XPPopup, delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.popups.append(popup)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                self?.popups.removeAll { $0.id == popup.id }
            }
        }
    }

    // MARK: Rest timer

    func startRest(seconds: Int, exercise: String) {
        stopRest()
        guard seconds > 0 else { return }
        restTotal = seconds
        restRemaining = seconds
        restExercise = exercise
        restEndsAt = Date().addingTimeInterval(TimeInterval(seconds))
        scheduleRestNotification(after: seconds)
        // .common so the countdown keeps ticking while a list is scrolling.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }

    func adjustRest(by delta: Int) {
        guard restActive, let end = restEndsAt else { return }
        restEndsAt = end.addingTimeInterval(TimeInterval(delta))
        restTotal = max(restTotal + delta, 1)
        cancelRestNotification()
        scheduleRestNotification(after: max(Int(restEndsAt!.timeIntervalSinceNow.rounded()), 0))
        tick()
    }

    func skipRest() { stopRest() }

    private func tick() {
        guard let end = restEndsAt else { return }
        let remaining = Int(end.timeIntervalSinceNow.rounded(.up))
        if remaining <= 0 {
            restRemaining = 0
            restTimer?.invalidate()
            restTimer = nil
            restEndsAt = nil
            if SessionGameSettings.hapticsEnabled { Platform.success() }
            if SessionGameSettings.restSoundEnabled { Platform.beep() }
            // Foreground delivery would duplicate the in-app cue.
            cancelRestNotification()
        } else {
            restRemaining = remaining
            if remaining <= 3, SessionGameSettings.hapticsEnabled { Platform.tick() }
        }
    }

    private func stopRest() {
        restTimer?.invalidate()
        restTimer = nil
        restEndsAt = nil
        restRemaining = 0
        restTotal = 0
        cancelRestNotification()
    }

    // MARK: Local notification (iOS only). The system does not present a
    // pending notification while the app is frontmost (no delegate is set), so
    // scheduling it up front is equivalent to "fire only when backgrounded".

    private func scheduleRestNotification(after seconds: Int) {
        #if os(iOS)
        guard seconds > 0 else { return }
        let center = UNUserNotificationCenter.current()
        let schedule = { [restNotificationID, restExercise] in
            let content = UNMutableNotificationContent()
            content.title = "Rest over — next set"
            content.body = restExercise.isEmpty ? "Back to it." : "Back to \(restExercise)."
            content.sound = SessionGameSettings.restSoundEnabled ? .default : nil
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
            center.add(UNNotificationRequest(identifier: restNotificationID, content: content, trigger: trigger))
        }
        if notificationPermissionAsked {
            schedule()
        } else {
            // Lazy permission request: first time the rest timer is used.
            notificationPermissionAsked = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { schedule() }
            }
        }
        #endif
    }

    private func cancelRestNotification() {
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [restNotificationID])
        #endif
    }
}

// MARK: - Summary model

struct SessionSummary: Identifiable {
    let id = UUID()
    let name: String
    let date: Date
    let durationSecs: Int
    let totalVolume: Double
    let totalReps: Int
    let sets: Int
    let exercises: Int
    let estimatedXP: Int
    let prExercises: [String]
    let streakDays: Int
    /// New best e1RMs and what the coach prescribes next time.
    var review: SessionReview = .empty

    /// Built at finish time, before `WorkoutManager` clears `currentWorkout`.
    static func make(from workout: WorkoutSession, streak: Int) -> SessionSummary {
        let completed = workout.completedSets
        let volume = completed.reduce(0.0) { $0 + $1.volume }
        let reps = completed.reduce(0) { $0 + max($1.reps, 0) }
        let duration = Int(workout.duration ?? WorkoutManager.duration(of: workout))
        return SessionSummary(
            name: workout.programName ?? "Workout",
            date: workout.date,
            durationSecs: duration,
            totalVolume: volume,
            totalReps: reps,
            sets: completed.count,
            exercises: workout.exercises.filter { $0.sets.contains { $0.completed } }.count,
            estimatedXP: reps > 0 ? XPEstimator.sessionXP(volume: volume, reps: reps, durationSecs: duration) : 0,
            prExercises: SessionGame.shared.prExercises,
            streakDays: streak
        )
    }

    var durationText: String {
        let m = durationSecs / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// The same summary with the streak known after the workout was saved.
    func withStreak(_ days: Int) -> SessionSummary {
        SessionSummary(name: name, date: date, durationSecs: durationSecs, totalVolume: totalVolume,
                       totalReps: totalReps, sets: sets, exercises: exercises, estimatedXP: estimatedXP,
                       prExercises: prExercises, streakDays: days, review: review)
    }

    func withReview(_ review: SessionReview) -> SessionSummary {
        var copy = self
        copy.review = review
        return copy
    }
}

// MARK: - Views: rest bar + pop-ups overlay

/// Compact rest countdown bar. Place above the exercise list.
struct RestTimerBar: View {
    @ObservedObject private var game = SessionGame.shared

    var body: some View {
        if game.restActive {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.brandBlue.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(game.restRemaining) / CGFloat(max(game.restTotal, 1)))
                        .stroke(Color.brandBlue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: game.restRemaining)
                    Text("\(game.restRemaining)")
                        .font(.caption.monospacedDigit().bold())
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rest")
                        .font(.subheadline.bold())
                    Text(game.restExercise)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("-15") { game.adjustRest(by: -15) }
                Button("+15") { game.adjustRest(by: 15) }
                Button("Skip") { game.skipRest() }
                    .tint(.brandOrange)
            }
            .buttonStyle(.bordered)
            .controlSize(Platform.isDesktop ? .small : .regular)
            .padding(10)
            .background(Color.brandBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Floating "+N XP" / "PR!" / "Combo" labels that rise and fade. Use as an
/// `.overlay` on the session view; it ignores touches.
struct XPPopupOverlay: View {
    @ObservedObject private var game = SessionGame.shared

    var body: some View {
        ZStack {
            ForEach(game.popups) { popup in
                FloatingLabel(popup: popup)
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct FloatingLabel: View {
        let popup: XPPopup
        @State private var risen = false

        var body: some View {
            Text(popup.text)
                .font(popup.kind == .xp ? .title2.bold() : .headline.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(color)
                .cornerRadius(12)
                .shadow(radius: 4)
                .offset(x: popup.xOffset, y: risen ? -140 : -20)
                .opacity(risen ? 0 : 1)
                .scaleEffect(risen ? 1.15 : 0.8)
                .onAppear {
                    withAnimation(.easeOut(duration: 1.6)) { risen = true }
                }
        }

        private var color: Color {
            switch popup.kind {
            case .xp: return .brandPurple
            case .pr: return .brandYellow
            case .combo: return .brandOrange
            }
        }
    }
}

/// Small running "est. XP" readout for the session header.
struct SessionXPBadge: View {
    @ObservedObject private var game = SessionGame.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
            Text("\(game.sessionEstimatedXP) XP est.")
                .monospacedDigit()
            if game.combo >= 2 {
                Text("x\(game.combo)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.brandOrange.opacity(0.3))
                    .cornerRadius(6)
            }
        }
        .font(.subheadline.bold())
        .foregroundColor(.brandPurple)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.brandPurple.opacity(0.12))
        .cornerRadius(20)
    }
}

// MARK: - Session summary + share card

struct SessionSummaryView: View {
    let summary: SessionSummary
    let onDone: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Session Complete")
                .font(.screenTitle.bold())

            ShareCardView(summary: summary)

            if !summary.review.records.isEmpty || !summary.review.nextTime.isEmpty {
                SessionReviewView(review: summary.review)
            }

            HStack(spacing: 12) {
                #if os(macOS)
                Button(copied ? "Copied" : "Copy Share Card") {
                    if let image = renderCard() {
                        Platform.copyImageToPasteboard(image)
                        copied = true
                    }
                }
                .buttonStyle(.bordered)
                #else
                if let image = renderCard() {
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("\(summary.name) — Endgame Fitness", image: Image(uiImage: image))
                    ) {
                        Label("Share Card", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                #endif

                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }

            Text("XP is estimated on-device; your profile updates when the session syncs.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 520)
        #endif
    }

    @MainActor
    private func renderCard() -> PlatformImage? {
        let renderer = ImageRenderer(content: ShareCardView(summary: summary).frame(width: 440))
        renderer.scale = 2
        #if os(macOS)
        return renderer.nsImage
        #else
        return renderer.uiImage
        #endif
    }
}

/// PRs by estimated max and what changes next session.
struct SessionReviewView: View {
    let review: SessionReview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !review.records.isEmpty {
                    Label("New best estimated max", systemImage: "trophy.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.brandGreen)
                    ForEach(review.records) { line in
                        row(line)
                    }
                }
                if !review.nextTime.isEmpty {
                    Label("Next time", systemImage: "arrow.forward.circle")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.brandBlue)
                    ForEach(review.nextTime) { line in
                        row(line)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }

    private func row(_ line: SessionReview.Line) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.name).font(.caption.bold())
            Text(line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShareCardView: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2)
                Text(summary.name)
                    .font(.title2.bold())
                Spacer()
                Text(summary.date, style: .date)
                    .font(.caption)
                    .opacity(0.8)
            }

            HStack(spacing: 12) {
                stat(TrainingUnits.volume(summary.totalVolume).components(separatedBy: " ").first ?? "0",
                     "\(TrainingUnits.current.label) volume")
                stat("\(summary.sets)", "sets")
                stat(summary.durationText, "duration")
                stat("+\(summary.estimatedXP)", "XP est.")
            }

            HStack(spacing: 16) {
                Label("\(summary.streakDays)-day streak", systemImage: "flame.fill")
                if !summary.prExercises.isEmpty {
                    Label("\(summary.prExercises.count) PR\(summary.prExercises.count == 1 ? "" : "s")", systemImage: "trophy.fill")
                }
                Spacer()
                Text("Endgame Fitness")
                    .font(.caption.bold())
                    .opacity(0.7)
            }
            .font(.subheadline.bold())

            if !summary.prExercises.isEmpty {
                Text(summary.prExercises.joined(separator: " · "))
                    .font(.caption)
                    .opacity(0.85)
                    .lineLimit(2)
            }
        }
        .foregroundColor(.white)
        .padding(20)
        .background(
            LinearGradient(colors: [.brandPurple, .brandBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(16)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption2).opacity(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.15))
        .cornerRadius(10)
    }
}

// MARK: - Settings section

/// Dropped into the existing `SettingsView` form.
struct SessionGameSettingsSection: View {
    @AppStorage(SessionGameSettings.restTimerKey) private var restTimer = true
    @AppStorage(SessionGameSettings.hapticsKey) private var haptics = true
    @AppStorage(SessionGameSettings.xpPopupsKey) private var xpPopups = true
    @AppStorage(SessionGameSettings.restSoundKey) private var restSound = false

    var body: some View {
        Section("Session Game Layer") {
            Toggle("Auto rest timer after each set", isOn: $restTimer)
            Toggle("XP pop-ups", isOn: $xpPopups)
            Toggle("Haptics (iPhone)", isOn: $haptics)
            Toggle("Sound when rest ends", isOn: $restSound)
            Text("Rest length uses Default Rest Time above. Set a per-exercise override from the exercise card during a workout.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Per-exercise rest override control, shown inside the exercise card.
struct ExerciseRestOverride: View {
    let exerciseName: String
    @State private var seconds: Int = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .foregroundColor(.secondary)
            TextField("Rest", value: $seconds, format: .number)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .multilineTextAlignment(.leading)
                .frame(width: Platform.isDesktop ? 56 : 64)
                .accessibilityLabel("Rest seconds for \(exerciseName)")
                .onChange(of: seconds) { _, new in
                    // Only a value that differs from the default is an
                    // override. Showing the default (onAppear) must not pin
                    // it, or a later change to Default Rest Time would never
                    // reach this exercise.
                    let key = SessionGameSettings.exerciseRestKey(exerciseName)
                    if new > 0, new != SessionGameSettings.defaultRestSeconds {
                        UserDefaults.standard.set(new, forKey: key)
                    } else {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
            Text("s")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear { seconds = SessionGameSettings.restSeconds(for: exerciseName) }
    }
}
