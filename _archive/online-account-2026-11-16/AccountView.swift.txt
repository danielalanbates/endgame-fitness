//
//  AccountView.swift
//  Endgame Fitness
//
//  The player's own profile and membership: hero name, bio, earned title and
//  aura, avatar, public/private, blocked players, help, sign out and account
//  deletion. Titles and auras can only be picked from what the server says
//  was earned (API_V2 §2.2, §7).
//

import SwiftUI

struct AccountView: View {
    @ObservedObject var auth = BatesAIAuth.shared
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

    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        Form {
            membershipSection
            if let profile = game.profile {
                heroSection(profile)
                profileSection(profile)
                avatarSection(profile)
                privacySection(profile)
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
            accountSection
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        .desktopMinFrame(minWidth: 460, minHeight: 560)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear(perform: loadFields)
        .onChange(of: game.profile?.userID) { _, _ in loadFields() }
        .task { await game.loadProfile() }
        .confirmationDialog("Sign out of Endgame Fitness?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await auth.signOut(); game.reset(); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Workouts that haven't synced yet stay on this device and upload the next time you sign in to this account.")
        }
        .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything tied to \(auth.user?.email ?? "this account") is erased. There is no recovery.")
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

    private var membershipSection: some View {
        Section("Membership") {
            LabeledContent("Email", value: auth.user?.email ?? "—")
            LabeledContent("Tier") {
                Text((auth.user?.membership ?? "free").capitalized)
                    .foregroundStyle(auth.user?.isPremium == true ? Color.brandYellow : .secondary)
            }
            Link("Manage membership on batesai.org", destination: BatesAIAuth.membershipURL)
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
        } footer: {
            Text("To report a player, post, comment or guild, use the … menu next to it or the Report button on their profile. Reports go to the Endgame Fitness team.")
        }
    }

    private var accountSection: some View {
        Section {
            Button("Sign out", role: .destructive) { showSignOutConfirm = true }
            Button(isDeleting ? "Deleting…" : "Delete account…", role: .destructive) { showDeleteConfirm = true }
                .disabled(isDeleting)
            if let deleteError {
                Text(deleteError).font(.caption).foregroundStyle(.red)
            }
        } footer: {
            Text("Deleting your account permanently removes your BatesAI membership, profile, workouts, XP, friends and guild membership across all BatesAI apps. This cannot be undone.")
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

    private func deleteAccount() async {
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await auth.deleteAccount()
            game.reset()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
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
