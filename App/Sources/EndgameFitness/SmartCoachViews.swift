//
//  SmartCoachViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  The dashboard "Today" card: today's prescribed loads with the reason for
//  each, a missed-day nudge, and weekly volume against the landmarks.
//

import SwiftUI

extension WorkoutManager {
    /// Rolling programs: push the cycle start forward so today becomes the
    /// training day that was missed.
    func shiftRollingCycle(byDays days: Int) {
        let d = UserDefaults.standard
        let start = d.double(forKey: "cycleStartDay")
        guard start > 0, days > 0 else { return }
        d.set(start + Double(days) * 86_400, forKey: "cycleStartDay")
        objectWillChange.send()
    }

    /// Missed-day nudge text, or nil when on track.
    func adherenceNudge(now: Date = Date()) -> (text: String, shiftDays: Int)? {
        let d = UserDefaults.standard
        let logged = loggedSessions.map(\.date)
        guard !weeklySchedule.isEmpty else { return nil }
        if d.string(forKey: "scheduleMode") == ScheduleMode.rolling.rawValue {
            let start = Date(timeIntervalSince1970: d.double(forKey: "cycleStartDay"))
            let missed = SmartCoach.missedRollingDays(start: start, daysOn: d.integer(forKey: "cycleDaysOn"),
                                                      daysOff: d.integer(forKey: "cycleDaysOff"),
                                                      logged: logged, now: now)
            guard missed > 0 else { return nil }
            return ("You missed \(missed) training day\(missed == 1 ? "" : "s"). Shift the cycle so you pick up where you left off instead of skipping ahead.", missed)
        }
        let weekdays = Set(weeklySchedule.map { String($0.dayOfWeek.components(separatedBy: " · ").first ?? $0.dayOfWeek) })
        let missed = SmartCoach.missedWeeklyDays(weekdays: weekdays, logged: logged, now: now)
        guard let first = missed.last else { return nil }
        let name = weeklySchedule.first { $0.dayOfWeek.hasPrefix(first) }?.workoutType ?? "workout"
        return ("\(first)'s \(name) was missed. Doing it today keeps the week balanced.", 0)
    }
}

struct SmartTodayCard: View {
    @ObservedObject var workoutManager: WorkoutManager
    let todaysWorkout: ScheduledWorkout?

    private var context: CoachContext { .current(profile: workoutManager.userProfile) }

    private struct Row: Identifiable {
        let id: Int
        let name: String
        let load: String
        let reason: String
    }

    private var rows: [Row] {
        guard let todaysWorkout else { return [] }
        let ctx = context
        let history = workoutManager.loggedSessions
        // Warm-ups, cardio and drills are timed: only lifts get a prescription.
        let lifts = todaysWorkout.plannedExercises.compactMap { plan -> (PlannedExercise, Exercise)? in
            var ex = Exercise(name: plan.name, targetSets: plan.sets, targetRepMin: plan.repMin,
                              targetRepMax: plan.repMax, targetSeconds: plan.seconds, targetLoadLb: plan.loadLb)
            WorkoutManager.attachLibraryMatch(&ex)
            let timedTarget = plan.seconds != nil && plan.repMin == nil && plan.repMax == nil
            if timedTarget || ex.resolvedTracking == .timed { return nil }
            return (plan, ex)
        }
        return lifts.prefix(6).enumerated().compactMap { i, pair in
            let (plan, ex) = pair
            guard let p = SmartCoach.prescribe(exercise: ex, history: history, context: ctx) else {
                return Row(id: i, name: plan.name, load: plan.hasTarget ? plan.schemeText : "", reason: "First time: pick a weight you could lift 2–3 more times.")
            }
            let load = p.topLoad > 0 ? "\(TrainingUnits.weight(p.topLoad, ctx.unit)) × \(p.topReps)" : "\(p.topReps) reps"
            return Row(id: i, name: plan.name, load: "\(p.sets.count) sets · \(load)", reason: p.reason)
        }
    }

    /// "Warm-up: 11 min (cardio, 4 drills, ramp-up sets)".
    private func warmupSummary(_ w: ScheduledWorkout) -> String? {
        let warm = w.plannedExercises.filter { $0.name.hasPrefix("Warm-up") }
        guard !warm.isEmpty else { return nil }
        let minutes = warm.reduce(0) { $0 + ($1.seconds ?? 0) } / 60
        return "Starts with a \(minutes)-min warm-up (\(warm.count) steps)"
    }

    private var cycleText: String {
        let c = context
        let model = c.model == .auto ? "Smart Advisor" : c.model.shortLabel
        if c.isDeloadWeek { return "Deload week · \(model)" }
        return "Week \(c.weekInCycle + 1) of \(c.cycleWeeks) · \(model)"
    }

    var body: some View {
        let volume = SmartCoach.weeklyVolume(from: workoutManager.loggedSessions)
            .filter { $0.level == .under || $0.level == .over }
        let trained = !workoutManager.loggedSessions.isEmpty

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Today", systemImage: "scope")
                    .font(.headline)
                Spacer()
                Text(cycleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let nudge = workoutManager.adherenceNudge() {
                VStack(alignment: .leading, spacing: 6) {
                    Text(nudge.text)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if nudge.shiftDays > 0 {
                        Button("Shift cycle \(nudge.shiftDays) day\(nudge.shiftDays == 1 ? "" : "s")") {
                            workoutManager.shiftRollingCycle(byDays: nudge.shiftDays)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let todaysWorkout {
                Text(todaysWorkout.workoutType)
                    .font(.subheadline.bold())
                if let warm = warmupSummary(todaysWorkout) {
                    Label(warm, systemImage: "flame")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = todaysWorkout.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).font(.subheadline)
                            Spacer(minLength: 8)
                            Text(row.load)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Color.brandBlue)
                        }
                        Text(row.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let rest = workoutManager.restDayPlan() {
                RestDayPlanView(plan: rest) {
                    workoutManager.startScheduledWorkout(rest.asScheduledWorkout)
                }
            } else {
                Text("Rest day. Nothing scheduled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if trained {
                Divider()
                Text("This week's volume")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if volume.isEmpty {
                    Text("Every muscle group is at or above its minimum.")
                        .font(.caption)
                } else {
                    ForEach(volume.prefix(3)) { v in
                        Text(v.advice)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A rest day's recovery plan: what to do, why, and an optional start button
/// that logs it as a light recovery session.
struct RestDayPlanView: View {
    let plan: RestDayPlan
    var onStart: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.title, systemImage: "bed.double.fill")
                .font(.subheadline.bold())
            ForEach(Array(plan.plannedExercises.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: item.name.hasPrefix("Optional") ? "circle.dotted" : "circle")
                        .font(.caption)
                        .foregroundStyle(Color.brandGreen)
                    Text(item.name)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if item.hasTarget {
                        Text(item.schemeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(plan.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onStart {
                Button(action: onStart) {
                    Label("Start Recovery Session", systemImage: "figure.walk")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
