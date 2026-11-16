//
//  AccountView.swift
//  Endgame Fitness
//
//  The local player's own profile: hero name, bio, earned title and aura,
//  avatar, blocked players, backup (export/import), switching player and
//  deleting the player. Titles and auras can only be picked from what the
//  local game says was earned. (The batesai.org membership version of this
//  screen is in _archive/batesai-account-2026-11-16.)
//

import SwiftUI
import UniformTypeIdentifiers

struct AccountView: View {
    @ObservedObject var players = LocalPlayerStore.shared
    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bio = ""
    /// "" = no title equipped (the rank band shows instead).
    @State private var title = ""
    /// "" = no aura.
    @State private var cosmetic = ""
    @State private var fieldsLoadedFor: String?

    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saved = false
    @State private var privacyError: String?
    @State private var isUpdatingPrivacy = false

    @State private var showAvatarEditor = false
    @State private var avatarProfile = AvatarBodyProfile.defaultBlob
    @State private var avatarComplete = false
    @State private var avatarError: String?
    @State private var showTalents = false

    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    @State private var exportDocument: PlayerBackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var backupMessage: String?
    @State private var showPlayerEditor = false

    var body: some View {
        Form {
            playerSection
            if let profile = game.profile {
                heroSection(profile)
                profileSection(profile)
                avatarSection(profile)
            } else {
                Section {
                    if case .failed(let message) = game.profileState {
                        Text(message).foregroundStyle(.secondary)
                        Button("Try again") { Task { await game.loadProfile() } }
                    } else {
                        SwiftUI.ProgressView()
                    }
                }
            }
            safetySection
            backupSection
            accountSection
        }
        .formStyle(.grouped)
        .navigationTitle("Player")
        .desktopMinFrame(minWidth: 460, minHeight: 560)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear(perform: loadFields)
        .onChange(of: game.profile?.userID) { _, _ in loadFields() }
        .task { await game.loadProfile() }
        .confirmationDialog("Delete this player?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { deletePlayer() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(players.current?.name ?? "This player")'s progress is erased from this device and their workout log is set aside. Export a backup first if you might want it back.")
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "\(players.current?.name ?? "player") - Endgame Fitness backup") { result in
            if case .failure(let error) = result { backupMessage = error.localizedDescription } else { backupMessage = "Backup saved." }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importBackup(result)
        }
        .sheet(isPresented: $showPlayerEditor) {
            if let current = players.current {
                LocalPlayerEditor(player: current) { showPlayerEditor = false }
            }
        }
        .sheet(isPresented: $showTalents) { TalentTreeView() }
        .sheet(isPresented: $showAvatarEditor) {
            AvatarQuestionnaireView(profile: $avatarProfile, isComplete: $avatarComplete)
                .desktopMinFrame(minWidth: 480, minHeight: 560)
        }
        .onChange(of: avatarComplete) { _, done in
            guard done else { return }
            avatarComplete = false
            showAvatarEditor = false
            Task { await saveAvatar(avatarProfile) }
        }
    }

    // MARK: Sections

    private var playerSection: some View {
        Section("Player") {
            if let current = players.current {
                HStack(spacing: 12) {
                    LocalPlayerBadge(player: current, size: 40)
                    Text(current.name).font(.headline)
                    Spacer()
                    Button("Edit") { showPlayerEditor = true }
                }
                LabeledContent("PIN", value: current.hasPIN ? "On" : "Off")
            }
            Button("Switch player") {
                game.reset()
                players.select(nil)
                dismiss()
            }
        }
    }

    private var backupSection: some View {
        Section {
            Button("Export backup…") { exportBackup() }
            Button("Import a player from a backup…") { showImporter = true }
            if let backupMessage {
                Text(backupMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("A backup is one JSON file with this player's progress and workout log. Importing adds it as a new player on this device.")
        }
    }

    private func heroSection(_ profile: FitnessProfile) -> some View {
        Section("Hero") {
            HStack(spacing: 14) {
                AvatarBadgeView(config: profile.avatarConfig, level: profile.level,
                                cosmetic: profile.cosmetic, size: 56, tint: profile.rankColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Level \(profile.level) · \(profile.rankTitle)")
                        .font(.headline)
                    HeroClassBadge(hero: profile.hero)
                    Text(profile.hero.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            if profile.streakFreezes > 0 {
                LabeledContent("Streak freezes", value: "\(profile.streakFreezes) of 3")
            }
            Button {
                showTalents = true
            } label: {
                HStack {
                    Text("Talents")
                    Spacer()
                    if profile.talentPoints > 0 { TalentPointsBadge(points: profile.talentPoints) }
                }
            }
        }
    }

    private func profileSection(_ profile: FitnessProfile) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Hero name", text: $displayName)
                if let problem = ProfileRules.displayNameProblem(displayName) {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Bio (optional)", text: $bio, axis: .vertical)
                    .lineLimit(1...4)
                    .onChange(of: bio) { _, value in
                        if value.count > ProfileRules.bioLimit { bio = String(value.prefix(ProfileRules.bioLimit)) }
                    }
                Text("\(bio.count)/\(ProfileRules.bioLimit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            titlePicker(profile)
            auraPicker(profile)
            HStack {
                Button(isSaving ? "Saving…" : "Save changes") { Task { await save(profile) } }
                    .disabled(isSaving || !hasChanges(profile) || ProfileRules.displayNameProblem(displayName) != nil)
                if saved {
                    Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(Color.brandGreen)
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Titles and auras come from levels, achievements, raids and seasons. Only ones you've earned are listed.")
        }
    }

    private func titlePicker(_ profile: FitnessProfile) -> some View {
        Picker("Title", selection: $title) {
            Text("Rank: \(FitnessProfile.rankBand(for: profile.level))").tag("")
            ForEach(titleChoices(profile), id: \.self) { Text($0).tag($0) }
        }
    }

    private func auraPicker(_ profile: FitnessProfile) -> some View {
        Picker("Aura", selection: $cosmetic) {
            Text("None").tag("")
            ForEach(auraChoices(profile), id: \.self) { Text($0.auraDisplayName).tag($0) }
        }
    }

    @ViewBuilder
    private func avatarSection(_ profile: FitnessProfile) -> some View {
        Section {
            if let config = profile.avatarConfig {
                AvatarColorPicker(config: config, level: profile.level) { color in
                    var next = config
                    next.skinColor = color
                    Task { await saveAvatar(next) }
                }
                Button("Edit body shape…") {
                    avatarProfile = config
                    showAvatarEditor = true
                }
            } else {
                Button("Create your avatar…") {
                    avatarProfile = .defaultBlob
                    showAvatarEditor = true
                }
            }
            if let avatarError {
                Text(avatarError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Avatar")
        } footer: {
            Text("Your avatar builds muscle as your lifetime volume grows and gets a face at level 3. New colors unlock as you level up.")
        }
    }

    private func privacySection(_ profile: FitnessProfile) -> some View {
        Section {
            Toggle("Public profile", isOn: Binding(
                get: { profile.isPublic },
                set: { newValue in Task { await setPublic(newValue) } }
            ))
            .disabled(isUpdatingPrivacy)
            if let privacyError {
                Text(privacyError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(profile.isPublic
                 ? "Public: your hero name, level, class, title and streak can appear on global and season leaderboards and in player search. Your workout details, body stats and email are never shown."
                 : "Private: only friends and guildmates see you. You don't appear on global leaderboards, season standings or in player search.")
        }
    }

    private var safetySection: some View {
        Section {
            NavigationLink("Blocked players") { BlockedUsersView() }
            HelpContactLink(subject: "Endgame Fitness help")
        } header: {
            Text("Safety and help")
        }
    }

    private var accountSection: some View {
        Section {
            Button("Delete player…", role: .destructive) { showDeleteConfirm = true }
            if let deleteError {
                Text(deleteError).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("Players live only on this device. Nothing is sent anywhere.")
                .font(.caption)
        }
    }

    // MARK: Choices

    /// Earned titles, plus whatever is equipped now (an older build may have
    /// set a title that predates the earned list) so the picker stays valid.
    private func titleChoices(_ profile: FitnessProfile) -> [String] {
        var choices = profile.earnedTitles
        if let current = profile.title, !current.isEmpty, !choices.contains(current) { choices.insert(current, at: 0) }
        return choices
    }

    private func auraChoices(_ profile: FitnessProfile) -> [String] {
        var choices = profile.earnedCosmetics
        if let current = profile.cosmetic, !current.isEmpty, !choices.contains(current) { choices.insert(current, at: 0) }
        return choices
    }

    // MARK: Actions

    private func loadFields() {
        guard let profile = game.profile, fieldsLoadedFor != profile.userID else { return }
        fieldsLoadedFor = profile.userID
        displayName = profile.displayName
        bio = profile.bio ?? ""
        title = profile.title ?? ""
        cosmetic = profile.cosmetic ?? ""
    }

    private func hasChanges(_ profile: FitnessProfile) -> Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines) != profile.displayName
            || bio.trimmingCharacters(in: .whitespacesAndNewlines) != (profile.bio ?? "")
            || title != (profile.title ?? "")
            || cosmetic != (profile.cosmetic ?? "")
    }

    private func save(_ profile: FitnessProfile) async {
        isSaving = true
        saved = false
        defer { isSaving = false }
        var fields: [String: Any] = [:]
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != profile.displayName { fields["display_name"] = name }
        if trimmedBio != (profile.bio ?? "") { fields["bio"] = trimmedBio }
        if title != (profile.title ?? "") { fields["title"] = title.isEmpty ? NSNull() : title }
        if cosmetic != (profile.cosmetic ?? "") { fields["cosmetic"] = cosmetic.isEmpty ? NSNull() : cosmetic }
        guard !fields.isEmpty else { return }

        if let failure = await game.saveProfile(fields) {
            saveError = failure
        } else {
            saveError = nil
            saved = true
            if let updated = game.profile {
                displayName = updated.displayName
                bio = updated.bio ?? ""
                title = updated.title ?? ""
                cosmetic = updated.cosmetic ?? ""
            }
        }
    }

    private func setPublic(_ isPublic: Bool) async {
        isUpdatingPrivacy = true
        defer { isUpdatingPrivacy = false }
        privacyError = await game.saveProfile(["is_public": isPublic])
    }

    /// The avatar is saved with progress applied, so it looks right at once.
    private func saveAvatar(_ config: AvatarBodyProfile) async {
        let level = game.profile?.level ?? 1
        let volume = game.profile?.totalVolume ?? 0
        guard let object = config.evolved(level: level, totalVolume: volume).wireObject else { return }
        avatarError = await game.saveProfile(["avatar_config": object])
    }

    private func deletePlayer() {
        guard let id = players.currentID else { return }
        game.reset()
        players.delete(id)
        dismiss()
    }

    private func exportBackup() {
        guard let id = players.currentID else { return }
        do {
            exportDocument = PlayerBackupDocument(data: try players.exportBackup(id))
            showExporter = true
        } catch {
            backupMessage = error.localizedDescription
        }
    }

    private func importBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let player = try players.importBackup(try Data(contentsOf: url))
            backupMessage = "Imported \(player.name). Switch player to play as them."
        } catch {
            backupMessage = error.localizedDescription
        }
    }
}

/// Blob colours, unlocked by level. Locked ones show the level they need.
struct AvatarColorPicker: View {
    let config: AvatarBodyProfile
    let level: Int
    let onPick: (AvatarBodyProfile.BlobColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color").font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AvatarBodyProfile.BlobColor.allCases, id: \.self) { color in
                        swatch(color)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func swatch(_ color: AvatarBodyProfile.BlobColor) -> some View {
        let unlocked = level >= color.unlockLevel
        let selected = config.skinColor == color
        return Button {
            if unlocked && !selected { onPick(color) }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(color == .rainbow
                              ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                              : AnyShapeStyle(color.swatch))
                        .frame(width: 30, height: 30)
                        .opacity(unlocked ? 1 : 0.3)
                    if !unlocked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .overlay(Circle().stroke(selected ? Color.primary : Color.clear, lineWidth: 2).padding(-3))
                Text(unlocked ? color.rawValue : "Lv \(color.unlockLevel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
        .accessibilityLabel(unlocked ? "\(color.rawValue)\(selected ? ", selected" : "")" : "\(color.rawValue), unlocks at level \(color.unlockLevel)")
    }
}
