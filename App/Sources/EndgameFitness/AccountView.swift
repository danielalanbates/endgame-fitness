//
//  AccountView.swift
//  Endgame Fitness
//
//  Membership (from batesai.org), display name / title editing, avatar,
//  sign out, and links to manage or delete the account on the website.
//

import SwiftUI

struct AccountView: View {
    @ObservedObject var auth = BatesAIAuth.shared
    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var title = ""
    @State private var isSaving = false
    @State private var showSignOutConfirm = false
    @State private var showAvatarEditor = false
    @State private var avatarProfile = AvatarBodyProfile.defaultBlob
    @State private var avatarComplete = false
    @State private var showTalents = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    private let membersURL = URL(string: "https://batesai.org/members")!

    var body: some View {
        Form {
            Section("Membership") {
                LabeledContent("Email", value: auth.user?.email ?? "—")
                LabeledContent("Tier") {
                    Text((auth.user?.membership ?? "free").capitalized)
                        .foregroundStyle(auth.user?.isPremium == true ? Color.brandYellow : .secondary)
                }
                Link("Manage membership on batesai.org", destination: membersURL)
            }

            Section("Player") {
                TextField("Display name", text: $displayName)
                TextField("Title (e.g. Iron Disciple)", text: $title)
                if let profile = game.profile {
                    LabeledContent("Level", value: "\(profile.level) · \(profile.rankTitle)")
                    // Raid reward cosmetics are equipped locally by
                    // GameProfileService.applyRaidRewards; show what's on.
                    if let cosmetic = profile.cosmetic, !cosmetic.isEmpty {
                        LabeledContent("Aura") {
                            HStack(spacing: 6) {
                                Circle()
                                    .strokeBorder(cosmetic.auraColor, lineWidth: 2)
                                    .frame(width: 14, height: 14)
                                Text(cosmetic.auraDisplayName)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                Button(isSaving ? "Saving…" : "Save changes") { Task { await save() } }
                    .disabled(isSaving || !hasChanges)
            }

            Section("Avatar") {
                Button("Edit avatar…") { showAvatarEditor = true }
            }

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
        .formStyle(.grouped)
        .navigationTitle("Account")
        .desktopMinFrame(minWidth: 380, minHeight: 420)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear(perform: loadFields)
        .onChange(of: game.profile) { _ in loadFields() }
        .confirmationDialog("Sign out of Endgame Fitness?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await auth.signOut(); game.reset(); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
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
        .onChange(of: avatarComplete) { done in
            guard done else { return }
            avatarComplete = false
            showAvatarEditor = false
            Task { await saveAvatar() }
        }
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

    private var hasChanges: Bool {
        guard let profile = game.profile else { return false }
        return displayName != profile.displayName || title != (profile.title ?? "")
    }

    private func loadFields() {
        guard let profile = game.profile else { return }
        displayName = profile.displayName
        title = profile.title ?? ""
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var fields: [String: Any] = ["display_name": displayName.trimmingCharacters(in: .whitespaces)]
        fields["title"] = title.trimmingCharacters(in: .whitespaces).isEmpty ? NSNull() : title
        await game.updateProfile(fields)
    }

    /// AvatarBodyProfile is Codable; ship it as the profile's avatar_config blob.
    private func saveAvatar() async {
        guard let data = try? JSONEncoder().encode(avatarProfile),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        await game.updateProfile(["avatar_config": object])
    }
}
