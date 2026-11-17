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
        let logged = SmartCoach.trainingDates(loggedSessions)
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
    /// The dashboard leaves today's session to the "Up next" tile and the
    /// Workouts tab; this card then only carries the coach's guidance.
    var showsWorkout = true

    private var context: CoachContext { .current(profile: workoutManager.userProfile) }

    private struct Row: Identifiable {
        let id: Int
        let name: String
        let load: String
        let reason: String
        let firstTime: Bool
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
                return Row(id: i, name: plan.name, load: plan.hasTarget ? plan.schemeText : "", reason: "", firstTime: true)
            }
            let load = p.topLoad > 0 ? "\(TrainingUnits.weight(p.topLoad, ctx.unit)) × \(p.topReps)" : "\(p.topReps) reps"
            return Row(id: i, name: plan.name, load: "\(p.sets.count) sets · \(load)", reason: p.reason, firstTime: false)
        }
    }

    /// The warm-up steps, in order, with their minutes.
    private func warmupSteps(_ w: ScheduledWorkout) -> [(id: Int, name: String, time: String)] {
        w.plannedExercises.filter { $0.name.hasPrefix("Warm-up") }.enumerated().map { i, p in
            let name = p.name.replacingOccurrences(of: "Warm-up: ", with: "")
            let secs = p.seconds ?? 0
            return (i, name, secs >= 60 ? "\(secs / 60) min" : (secs > 0 ? "\(secs)s" : ""))
        }
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
        let nudge = workoutManager.adherenceNudge()

        if showsWorkout || nudge != nil || trained {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Today", systemImage: "scope")
                    .font(.headline)
                Spacer()
                Text(cycleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let nudge {
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

            if !showsWorkout {
                EmptyView()
            } else if let todaysWorkout {
                Text(todaysWorkout.workoutType)
                    .font(.subheadline.bold())
                let warm = warmupSteps(todaysWorkout)
                if !warm.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Warm-up", systemImage: "flame")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        ForEach(warm, id: \.id) { step in
                            HStack(alignment: .firstTextBaseline) {
                                Text(step.name)
                                    .font(.caption)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text(step.time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if rows.contains(where: \.firstTime) {
                    Text("New lifts: pick a weight you could lift 2–3 more times.")
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
                        if !row.reason.isEmpty {
                        Text(row.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }
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

/// Shown once after a Smart Advisor update: the program was rebuilt from
/// its saved answers, or (edited by hand) should be rebuilt in the wizard.
struct ProgramUpdateNotice: View {
    let rebuilt: Bool
    let onRebuild: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(rebuilt ? "Your program was updated" : "Rebuild your program", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.bold())
            Text(rebuilt
                 ? "The Smart Advisor rebuilt it with a warm-up in every session, a separate rest-day page and, for longevity, joint-safe loading (8+ reps, 2-3 reps short of failure). Your cycle start is unchanged. If your equipment or injuries changed, rebuild it."
                 : "You edited this program by hand, so it was not changed, apart from removing the rest-day walk from training days. Rebuild it to get warm-ups and joint-safe loading.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(rebuilt ? "Review Settings" : "Rebuild Program", action: onRebuild)
                    .buttonStyle(.borderedProminent)
                    .tint(.brandPurple)
                    .controlSize(.small)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandPurple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}
