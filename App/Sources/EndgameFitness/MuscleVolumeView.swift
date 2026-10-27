//
//  MuscleVolumeView.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://batesai.org · help@batesai.org
//
//  Progress-tab building blocks: completed sets per muscle over the last
//  seven days (from the library's primary muscles), and personal records by
//  the server's rule — best weight at each rep count — with an Epley
//  estimated one-rep max for comparison.
//

import SwiftUI
import Charts

struct MuscleWeekCard: View {
    let sessions: [WorkoutSession]
    let unit: WeightUnit
    @State private var showVolume = false

    var body: some View {
        let weeks = TrainingStats.muscleWeek(from: sessions)
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 Days by Muscle")
                .font(.headline)
            Picker("Measure", selection: $showVolume) {
                Text("Sets").tag(false)
                Text("Volume").tag(true)
            }
            .labelsHidden()
            .compactSegmentedPicker()
            .frame(maxWidth: 220)
            if weeks.isEmpty {
                Text("Complete a set this week to see which muscles you trained.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Chart(weeks) { week in
                    BarMark(
                        x: .value(showVolume ? "Volume" : "Sets", showVolume ? TrainingUnits.toDisplay(week.volume, unit) : Double(week.sets)),
                        y: .value("Muscle", ExerciseLibrary.displayName(forMuscle: week.muscle))
                    )
                    .foregroundStyle(Color.brandPurple.gradient)
                    .annotation(position: .trailing) {
                        Text(showVolume ? TrainingUnits.volume(week.volume, unit) : "\(week.sets)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(max(weeks.count, 3)) * 28)
                Text("Each completed set counts once for every primary muscle it trains. Bodyweight sets add volume only for added load; timed sets add sets, not volume.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RecordsCard: View {
    let sessions: [WorkoutSession]
    let unit: WeightUnit
    var limit: Int = 5

    var body: some View {
        let records = TrainingStats.records(from: sessions)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Personal Records")
                    .font(.headline)
                Spacer()
                if records.count > limit {
                    NavigationLink("All \(records.count)") {
                        RecordsListView(records: records, unit: unit)
                    }
                    .font(.subheadline)
                }
            }
            if records.isEmpty {
                Text("Log weighted sets to build your records: the best weight you have lifted at each rep count.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records.prefix(limit)) { record in
                    RecordRow(record: record, unit: unit)
                    if record.id != records.prefix(limit).last?.id { Divider() }
                }
            }
        }
        .padding()
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RecordsListView: View {
    let records: [ExerciseRecord]
    let unit: WeightUnit

    var body: some View {
        List(records) { record in
            VStack(alignment: .leading, spacing: 8) {
                RecordRow(record: record, unit: unit)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(record.repMaxes) { max in
                            VStack(spacing: 2) {
                                Text("\(max.reps) rep\(max.reps == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(TrainingUnits.weight(max.weight, unit))
                                    .font(.caption.monospacedDigit().bold())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.brandYellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Personal Records")
    }
}

struct RecordRow: View {
    let record: ExerciseRecord
    let unit: WeightUnit

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("Best set \(TrainingUnits.weight(record.bestSetWeight, unit)) × \(record.bestSetReps) · \(record.bestDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(TrainingUnits.weight(record.bestE1RM, unit))
                    .font(.headline.monospacedDigit())
                Text("est. 1RM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
