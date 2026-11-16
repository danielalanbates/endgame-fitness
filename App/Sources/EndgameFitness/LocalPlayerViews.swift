//
//  LocalPlayerViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  "Who's training?" — the launch screen that picks, creates, edits and
//  deletes local players, plus the small pieces the Player screen reuses.
//

import SwiftUI
import UniformTypeIdentifiers

/// A player's avatar: their symbol on their colour.
struct LocalPlayerBadge: View {
    let player: LocalPlayer
    var size: CGFloat = 64

    var body: some View {
        Circle()
            .fill(player.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: player.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

struct PlayerPickerView: View {
    @ObservedObject var players = LocalPlayerStore.shared
    @ObservedObject var game = GameProfileService.shared

    @State private var editing: LocalPlayer?
    @State private var creating = false
    @State private var unlocking: LocalPlayer?
    @State private var deleting: LocalPlayer?
    @State private var showImporter = false
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Who's training?")
                        .font(.largeTitle.bold())
                    Text("Everyone on this device gets their own hero, quests and streak. Train together as a household guild.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .padding(.top, 32)

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(players.players) { player in
                        tile(player)
                    }
                    addTile
                }
                .frame(maxWidth: 640)

                Button("Import a player from a backup…") { showImporter = true }
                    .buttonStyle(.borderless)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .adaptivePadding(32, phone: 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .sheet(isPresented: $creating) {
            LocalPlayerEditor(player: nil) { creating = false }
        }
        .sheet(item: $editing) { player in
            LocalPlayerEditor(player: player) { editing = nil }
        }
        .sheet(item: $unlocking) { player in
            PINEntryView(player: player) { ok in
                unlocking = nil
                if ok { players.select(player.id) }
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "player")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                if let p = deleting { players.delete(p.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Their progress is erased from this device and their workout log is set aside.")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let p = try players.importBackup(try Data(contentsOf: url))
                message = "Imported \(p.name)."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func tile(_ player: LocalPlayer) -> some View {
        let state = game.engine.store.state(player.id)
        return Button {
            if player.hasPIN { unlocking = player } else { players.select(player.id) }
        } label: {
            VStack(spacing: 8) {
                LocalPlayerBadge(player: player, size: 84)
                    .overlay(alignment: .bottomTrailing) {
                        if player.hasPIN {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .padding(5)
                                .background(.thinMaterial, in: Circle())
                        }
                    }
                Text(player.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("Level \(state.level) · \(FitnessProfile.rankBand(for: state.level))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit…") { editing = player }
            Button("Delete…", role: .destructive) { deleting = player }
        }
    }

    private var addTile: some View {
        Button { creating = true } label: {
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(.secondary)
                    .frame(width: 84, height: 84)
                    .overlay { Image(systemName: "plus").font(.title).foregroundStyle(.secondary) }
                Text("Add player").font(.headline)
                Text(" ").font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

/// Create (player == nil) or edit a local player.
struct LocalPlayerEditor: View {
    let player: LocalPlayer?
    let onDone: () -> Void

    @ObservedObject var players = LocalPlayerStore.shared
    @State private var name = ""
    @State private var symbol = LocalPlayer.symbols[0]
    @State private var colorIndex = 0
    @State private var usePIN = false
    @State private var pin = ""
    @State private var loaded = false

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Pick a name." }
        if players.players.contains(where: { $0.name.lowercased() == trimmed.lowercased() && $0.id != player?.id }) {
            return "Someone on this device already uses that name."
        }
        return ProfileRules.displayNameProblem(trimmed)
    }

    private var pinProblem: String? {
        guard usePIN, !(player?.hasPIN == true && pin.isEmpty) else { return nil }
        return (pin.count == 4 && pin.allSatisfy(\.isNumber)) ? nil : "A PIN is 4 digits."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        LocalPlayerBadge(player: preview, size: 88)
                        Spacer()
                    }
                    TextField("Name", text: $name)
                .multilineTextAlignment(.leading)
                    if let nameProblem, !name.isEmpty {
                        Text(nameProblem).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Avatar") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 10)], spacing: 10) {
                        ForEach(LocalPlayer.symbols, id: \.self) { s in
                            Button { symbol = s } label: {
                                Image(systemName: s)
                                    .frame(width: 36, height: 36)
                                    .background(symbol == s ? preview.color.opacity(0.3) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(LocalPlayer.colors.indices, id: \.self) { i in
                            Button { colorIndex = i } label: {
                                Circle().fill(LocalPlayer.colors[i]).frame(width: 26, height: 26)
                                    .overlay { if colorIndex == i { Circle().stroke(.primary, lineWidth: 2) } }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Toggle("Lock with a PIN", isOn: $usePIN)
                    if usePIN {
                        SecureField(player?.hasPIN == true ? "New PIN (leave empty to keep)" : "4-digit PIN", text: $pin)
                .multilineTextAlignment(.leading)
                        if let pinProblem { Text(pinProblem).font(.caption).foregroundStyle(.red) }
                    }
                } footer: {
                    Text("Optional. A PIN keeps a sibling from logging sets as you; it isn't a password.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(player == nil ? "New player" : "Edit player")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(player == nil ? "Create" : "Save", action: save)
                        .disabled(nameProblem != nil || pinProblem != nil)
                }
            }
        }
        .desktopMinFrame(minWidth: 420, minHeight: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let player {
                name = player.name
                symbol = player.symbol
                colorIndex = player.colorIndex
                usePIN = player.hasPIN
            } else {
                colorIndex = players.players.count % LocalPlayer.colors.count
                symbol = LocalPlayer.symbols[players.players.count % LocalPlayer.symbols.count]
            }
        }
    }

    private var preview: LocalPlayer {
        LocalPlayer(id: player?.id ?? "preview", name: name, symbol: symbol, colorIndex: colorIndex,
                    pinHash: nil, createdAt: 0, storeKey: "")
    }

    private func save() {
        if var existing = player {
            existing.name = name
            existing.symbol = symbol
            existing.colorIndex = colorIndex
            players.update(existing)
            if !usePIN { players.setPIN(existing.id, pin: nil) } else if !pin.isEmpty { players.setPIN(existing.id, pin: pin) }
        } else {
            let created = players.create(name: name, symbol: symbol, colorIndex: colorIndex, pin: usePIN ? pin : nil)
            players.select(created.id)
        }
        onDone()
    }
}

struct PINEntryView: View {
    let player: LocalPlayer
    let onFinish: (Bool) -> Void

    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 16) {
            LocalPlayerBadge(player: player, size: 72)
            Text("Enter \(player.name)'s PIN").font(.headline)
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
                .onSubmit(check)
            if wrong { Text("That PIN doesn't match.").font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { onFinish(false) }
                Button("Unlock", action: check).buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .desktopMinFrame(minWidth: 300, minHeight: 260)
    }

    private func check() {
        if player.checkPIN(pin) { onFinish(true) } else { wrong = true; pin = "" }
    }
}
