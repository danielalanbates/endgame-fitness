//
//  ExerciseGuideViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Where the directions from `ExerciseGuide` are shown: an inline "How to"
//  on the live exercise card, the full directions sheet, one-line cues for
//  lists, and the program-day row with its "How to" button.
//

import SwiftUI

/// Collapsible "How to" on the live exercise card: the first steps and the
/// safety cue, with a link to the full directions.
struct ExerciseHowToInline: View {
    let directions: ExerciseDirections
    @Binding var isExpanded: Bool
    let onMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("How to")
                        .font(.caption.weight(.semibold))
                    if !isExpanded {
                        Text(directions.cue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brandBlue)
            .accessibilityLabel(isExpanded ? "Hide directions" : "Show directions")

            if isExpanded {
                ForEach(Array(directions.inlineSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(Color.brandBlue)
                        Text(step)
                            .font(.caption)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                SafetyCueLine(text: directions.safety)
                Button("Full directions", action: onMore)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brandBlue)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandBlue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The safety cue, in the warning colour.
struct SafetyCueLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.shield")
                .font(.caption)
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.brandOrange)
    }
}

/// A one-line cue under an exercise name in a list (nil-safe: nothing when unknown).
struct ExerciseCueLine: View {
    let name: String

    var body: some View {
        if let cue = ExerciseGuide.cue(for: name) {
            Text(cue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Full directions: steps, safety, easier/harder options, effort, muscles.
struct ExerciseDirectionsSheet: View {
    let directions: ExerciseDirections
    @Environment(\.dismiss) private var dismiss

    private var library: LibraryExercise? { directions.libraryID.flatMap { ExerciseLibrary.shared.entry(id: $0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(directions.name)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(directions.cue)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let library, !library.primary.isEmpty {
                        Text("Works: " + library.primary.map(ExerciseLibrary.displayName(forMuscle:)).joined(separator: ", "))
                            .font(.subheadline)
                    }
                    if !directions.quickSteps.isEmpty {
                        steps("Key points", directions.quickSteps)
                    }
                    steps(directions.quickSteps.isEmpty ? "How to do it" : "Step by step", directions.steps)
                    SafetyCueLine(text: directions.safety)
                    if directions.easier != nil || directions.harder != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if let easier = directions.easier { option("Easier", easier, "arrow.down.circle", .brandGreen) }
                            if let harder = directions.harder { option("Harder", harder, "arrow.up.circle", .brandPurple) }
                        }
                    }
                    if let effort = directions.effortNote {
                        Text(effort)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.brandPurple.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text(directions.stepsFromLibrary
                         ? "Step-by-step text: free-exercise-db (public domain). Stop if anything hurts, and check with a professional if you are unsure about a movement."
                         : "Stop if anything hurts, and check with a professional if you are unsure about a movement.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("How To")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .desktopSheetFrame(width: 520, height: 600)
    }

    private func steps(_ title: String, _ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(Array(list.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .frame(width: 22, height: 22)
                        .background(Color.brandBlue.opacity(0.15), in: Circle())
                    Text(step)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func option(_ title: String, _ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            (Text(title + ": ").bold() + Text(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A program day's exercise row: name, scheme, one-line cue and a "How to" button.
struct ProgramDayExerciseRow: View {
    let planned: PlannedExercise
    @State private var showHowTo = false

    var body: some View {
        let directions = ExerciseGuide.directions(for: planned.name)
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "circle")
                .font(.caption)
                .foregroundColor(.brandBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(planned.name)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let directions {
                    Text(directions.cue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if planned.hasTarget {
                Text(planned.schemeText)
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            if directions != nil {
                Button { showHowTo = true } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brandBlue)
                .accessibilityLabel("How to do \(planned.name)")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showHowTo) {
            if let directions { ExerciseDirectionsSheet(directions: directions) }
        }
    }
}
