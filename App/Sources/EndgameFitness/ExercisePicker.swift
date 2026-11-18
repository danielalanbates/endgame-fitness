//
//  ExercisePicker.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Add an exercise: search the bundled library by name and filter by muscle,
//  equipment and category, read the step-by-step instructions, or add a
//  custom exercise by typing its name.
//

import SwiftUI

struct ExercisePickerView: View {
    /// Library entry, or nil with a custom name.
    let onPick: (LibraryExercise?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var muscle: String?
    @State private var equipment: String?
    @State private var category: String?
    @State private var detail: LibraryExercise?

    private let library = ExerciseLibrary.shared
    private let limit = 150

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: [LibraryExercise] {
        library.search(trimmedQuery, muscle: muscle, equipment: equipment, category: category)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                resultList
            }
            .searchable(text: $query, prompt: "Search \(library.count) exercises")
            .navigationTitle("Add Exercise")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $detail) { entry in
                ExerciseInfoView(entry: entry, onAdd: { pick(entry, custom: nil) })
            }
        }
        .desktopSheetFrame(width: 580, height: 660)
    }

    private var resultList: some View {
        let found = results
        return List {
            if !trimmedQuery.isEmpty {
                Button {
                    pick(nil, custom: trimmedQuery)
                } label: {
                    Label("Add “\(trimmedQuery)” as a custom exercise", systemImage: "plus.circle")
                }
            }
            ForEach(found.prefix(limit)) { entry in
                ExercisePickerRow(entry: entry, onPick: { pick(entry, custom: nil) }, onInfo: { detail = entry })
            }
            if found.count > limit {
                Text("Showing \(limit) of \(found.count). Search or filter to narrow it down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if found.isEmpty {
                Text(library.count == 0 ? "The exercise library could not be loaded. You can still add a custom exercise by name."
                                        : "No exercises match. Clear a filter, or add it as a custom exercise.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Exercise data: free-exercise-db (public domain).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterMenu(title: "Muscle", selection: $muscle, options: library.muscles,
                           label: ExerciseLibrary.displayName(forMuscle:))
                FilterMenu(title: "Equipment", selection: $equipment, options: library.equipments,
                           label: ExerciseLibrary.displayName(forEquipment:))
                FilterMenu(title: "Category", selection: $category, options: library.categories,
                           label: ExerciseLibrary.displayName(forCategory:))
                if muscle != nil || equipment != nil || category != nil {
                    Button("Clear") {
                        muscle = nil
                        equipment = nil
                        category = nil
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func pick(_ entry: LibraryExercise?, custom: String?) {
        onPick(entry, custom)
        detail = nil
        dismiss()
    }
}

private struct ExercisePickerRow: View {
    let entry: LibraryExercise
    let onPick: () -> Void
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPick) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brandBlue)
            .accessibilityLabel("Instructions for \(entry.name)")
        }
    }

    private var subtitle: String {
        var parts = entry.primary.map(ExerciseLibrary.displayName(forMuscle:))
        if let equipment = entry.equipment { parts.append(ExerciseLibrary.displayName(forEquipment: equipment)) }
        parts.append(ExerciseLibrary.displayName(forCategory: entry.category))
        return parts.joined(separator: " · ")
    }
}

private struct FilterMenu: View {
    let title: String
    @Binding var selection: String?
    let options: [String]
    let label: (String) -> String

    var body: some View {
        Menu {
            Button("Any \(title.lowercased())") { selection = nil }
            Divider()
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option { Label(label(option), systemImage: "checkmark") } else { Text(label(option)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.map(label) ?? title)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background((selection == nil ? Color.gray.opacity(0.15) : Color.brandBlue.opacity(0.2)), in: Capsule())
            .foregroundStyle(selection == nil ? Color.primary : Color.brandBlue)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Exercise detail

struct ExerciseInfoView: View {
    let entry: LibraryExercise
    var onAdd: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.name)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    tags
                    muscles
                    instructions
                    Text("Instructions: free-exercise-db (public domain). Stop if anything hurts, and check with a professional if you are unsure about a movement.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Exercise")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let onAdd {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            dismiss()
                            onAdd()
                        }
                    }
                }
            }
        }
        .desktopSheetFrame(width: 520, height: 600)
    }

    private var tags: some View {
        let values = [entry.category, entry.equipment, entry.level, entry.mechanic].compactMap { $0 }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Text(value == "body only" ? "Bodyweight" : value.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.brandPurple.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private var muscles: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !entry.primary.isEmpty {
                Text("Primary: " + entry.primary.map(ExerciseLibrary.displayName(forMuscle:)).joined(separator: ", "))
                    .font(.subheadline)
            }
            if !entry.secondary.isEmpty {
                Text("Secondary: " + entry.secondary.map(ExerciseLibrary.displayName(forMuscle:)).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to do it").font(.headline)
            if entry.instructions.isEmpty {
                Text("No written instructions for this one.").foregroundStyle(.secondary)
            }
            ForEach(Array(entry.instructions.enumerated()), id: \.offset) { index, step in
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
}
