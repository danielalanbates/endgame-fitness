//
//  ProfileSetupView.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  A short "who are you in the game" step shown once per account on a
//  device: hero name, whether the profile is public, and an optional bio
//  (PUT fitness/profile, API_V2 §2.2–2.3). Public is preselected because the
//  game is better with other people, but the choice is spelled out and can be
//  changed any time in Account.
//

import SwiftUI

struct ProfileSetupView: View {
    /// Called after saving or skipping.
    let onFinish: () -> Void

    @ObservedObject var game = GameProfileService.shared
    @EnvironmentObject var workoutManager: WorkoutManager

    @State private var heroName = ""
    @State private var bio = ""
    @State private var isPublic = true
    @State private var isSaving = false
    @State private var error: String?

    private var nameProblem: String? { ProfileRules.displayNameProblem(heroName) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                nameField
                visibility
                bioField
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Text("Community rules: keep names, bios, comments and guilds friendly. There's no tolerance for harassment, hate or explicit content; reported content is reviewed and abusive accounts are removed. Report or block anyone from their profile or the … menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                buttons
            }
            .frame(maxWidth: 480)
            .adaptivePadding(32, phone: 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .onAppear(perform: prefill)
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarBadgeView(config: game.profile?.avatarConfig, level: game.profile?.level ?? 1,
                            cosmetic: game.profile?.cosmetic, size: 84,
                            tint: game.profile?.rankColor ?? .brandPurple)
            Text("Set up your hero")
                .font(.title.bold())
            Text("This is how friends, guildmates and rivals will see you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hero name").font(.headline)
            PlatformTextField(placeholder: "Hero name", text: $heroName)
            Text(nameProblem ?? "2–24 characters. Letters, numbers, spaces and _ - . '")
                .font(.caption)
                .foregroundStyle(nameProblem == nil ? Color.secondary : Color.red)
        }
    }

    private var visibility: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isPublic) {
                Text("Public profile").font(.headline)
            }
            Text(isPublic
                 ? "Public: your hero name, level, class, title and streak can appear on global and season leaderboards and in player search. Your workouts' details, body stats and email are never shown."
                 : "Private: only your friends and guildmates see you. You won't appear on global leaderboards or in player search.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("You can change this any time in Account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var bioField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bio (optional)").font(.headline)
            TextField("A line about your training", text: $bio, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onChange(of: bio) { _, value in
                    if value.count > ProfileRules.bioLimit { bio = String(value.prefix(ProfileRules.bioLimit)) }
                }
            Text("\(bio.count)/\(ProfileRules.bioLimit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Not now", action: onFinish)
                .buttonStyle(.bordered)
            Spacer()
            Button {
                Task { await save() }
            } label: {
                Text(isSaving ? "Saving…" : "Save and continue")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandPurple)
            .disabled(nameProblem != nil || isSaving)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func prefill() {
        guard heroName.isEmpty else { return }
        if let profile = game.profile {
            heroName = profile.displayName
            bio = profile.bio ?? ""
        }
        if heroName.isEmpty, let name = workoutManager.userProfile?.name, !name.isEmpty {
            heroName = name
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var fields: [String: Any] = [
            "display_name": heroName.trimmingCharacters(in: .whitespacesAndNewlines),
            "is_public": isPublic,
        ]
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBio.isEmpty || !(game.profile?.bio ?? "").isEmpty {
            fields["bio"] = trimmedBio
        }
        if let failure = await game.saveProfile(fields) {
            error = failure
        } else {
            onFinish()
        }
    }
}
