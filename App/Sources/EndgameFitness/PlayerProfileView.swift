//
//  PlayerProfileView.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Someone else's public player card (API_V2 §2.6), opened by tapping a name
//  anywhere: feed, leaderboard, friends, guild roster, raid contributors,
//  season standings. From here you can add or remove a friend, block, or
//  report. Private players who aren't your friend come back as 404, which is
//  shown plainly — report and block still work by id.
//

import SwiftUI

struct PlayerProfileView: View {
    let player: PlayerRef

    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var loaded: PublicPlayer?
    @State private var loadError: String?
    @State private var isHidden = false
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var message: String?
    @State private var confirmBlock = false
    @State private var confirmUnfriend = false
    @State private var report: ReportRequest?
    @State private var blocked = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if isLoading {
                        SwiftUI.ProgressView().padding(.vertical, 60)
                    } else if let loaded {
                        PlayerProfileHeader(player: loaded)
                        PlayerProfileStats(player: loaded)
                        if let guild = loaded.guild { guildRow(guild) }
                        if !loaded.isSelf { actions(for: loaded) }
                    } else {
                        unavailable
                    }
                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(loaded?.displayName ?? player.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .desktopMinFrame(minWidth: 440, minHeight: 560)
        .task { await load() }
        .sheet(item: $report) { ReportSheet(request: $0) }
        .confirmationDialog("Block \(displayName)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { Task { await block() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's activity, comments, rankings or profiles, and any friendship ends. You can unblock in Account.")
        }
        .confirmationDialog("Remove \(displayName) from friends?", isPresented: $confirmUnfriend, titleVisibility: .visible) {
            Button("Remove friend", role: .destructive) { Task { await unfriend() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var displayName: String { loaded?.displayName ?? player.displayName }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Image(systemName: isHidden ? "lock.fill" : "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(isHidden ? "This profile is private" : "Couldn't load this profile")
                .font(.headline)
            Text(isHidden
                 ? "\(player.displayName) only shares their profile with friends."
                 : (loadError ?? "Please try again."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !isHidden {
                Button("Try again") { Task { await load() } }
            }
            safetyButtons(isBlocked: blocked)
        }
        .padding(.vertical, 30)
    }

    private func guildRow(_ guild: PublicPlayer.GuildRef) -> some View {
        HStack(spacing: 10) {
            GuildEmblemView(emblem: guild.emblem, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Guild").font(.caption).foregroundStyle(.secondary)
                Text(guild.name).font(.headline)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func actions(for player: PublicPlayer) -> some View {
        VStack(spacing: 10) {
            friendButton(for: player)
                .disabled(isWorking || blocked)
            safetyButtons(isBlocked: blocked || player.isBlocked)
        }
    }

    @ViewBuilder
    private func friendButton(for player: PublicPlayer) -> some View {
        let incoming = game.incomingRequests.contains { $0.userID == player.userID }
        let outgoing = game.outgoingRequests.contains { $0.userID == player.userID }
        let isFriend = player.isFriend || game.friends.contains { $0.userID == player.userID }

        if isFriend {
            HStack {
                Label("Friends", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.brandGreen)
                Spacer()
                Button("Remove friend", role: .destructive) { confirmUnfriend = true }
            }
        } else if incoming {
            Button {
                Task { await respond(accept: true) }
            } label: {
                Label("Accept friend request", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandGreen)
        } else if outgoing {
            Label("Friend request sent", systemImage: "clock")
                .foregroundStyle(.secondary)
        } else {
            Button {
                Task { await addFriend() }
            } label: {
                Label("Add friend", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandPurple)
        }
    }

    private func safetyButtons(isBlocked: Bool) -> some View {
        HStack(spacing: 12) {
            if isBlocked {
                Button("Unblock") { Task { await unblock() } }
                    .buttonStyle(.bordered)
            } else {
                Button(role: .destructive) { confirmBlock = true } label: {
                    Label("Block", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
            }
            Button {
                report = ReportRequest(target: .user, targetID: player.id, subject: displayName)
            } label: {
                Label("Report", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.bordered)
        }
        .disabled(isWorking)
    }

    // MARK: Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            loaded = try await game.loadPlayer(player.id)
            blocked = loaded?.isBlocked ?? false
            loadError = nil
            isHidden = false
        } catch is LocalGameError {
            loaded = nil
            isHidden = true
        } catch {
            loaded = nil
            loadError = error.localizedDescription
        }
    }

    private func addFriend() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await game.requestFriend(userID: player.id) {
            message = failure
        } else {
            message = "Friend request sent. You'll be friends once \(displayName) accepts."
        }
    }

    private func respond(accept: Bool) async {
        isWorking = true
        defer { isWorking = false }
        message = await game.respondToFriendRequest(userID: player.id, accept: accept)
        await load()
    }

    private func unfriend() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await game.removeFriend(userID: player.id) {
            message = failure
        } else {
            message = "\(displayName) is no longer your friend."
            await load()
        }
    }

    private func block() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await game.block(userID: player.id) {
            message = failure
        } else {
            blocked = true
            message = "\(displayName) is blocked."
        }
    }

    private func unblock() async {
        isWorking = true
        defer { isWorking = false }
        if let failure = await game.unblock(userID: player.id) {
            message = failure
        } else {
            blocked = false
            message = "\(displayName) is unblocked."
            await load()
        }
    }
}

// MARK: - Pieces

struct PlayerProfileHeader: View {
    let player: PublicPlayer

    var body: some View {
        VStack(spacing: 10) {
            AvatarBadgeView(config: player.avatarConfig, level: player.level, cosmetic: player.cosmetic,
                            size: 96, tint: FitnessProfile.rankColor(for: player.level))
                .padding(.top, 6)
            Text(player.displayName)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Text(player.rankTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FitnessProfile.rankColor(for: player.level))
                HeroClassBadge(hero: player.hero)
            }
            if let bio = player.bio, !bio.isEmpty {
                Text(bio)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PlayerProfileStats: View {
    let player: PublicPlayer

    var body: some View {
        HStack(spacing: 0) {
            stat("Level", "\(player.level)", icon: "arrow.up.circle.fill", tint: .brandPurple)
            stat("Streak", "\(player.currentStreak)d", icon: "flame.fill", tint: .brandOrange)
            stat("Workouts", "\(player.totalWorkouts)", icon: "figure.strengthtraining.traditional", tint: .brandBlue)
            stat("Achievements", "\(player.achievementsCount)", icon: "rosette", tint: .brandYellow)
        }
        .padding(.vertical, 12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ label: String, _ value: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Presents a player's public profile when `item` is set.
    func playerProfileSheet(_ item: Binding<PlayerRef?>) -> some View {
        sheet(item: item) { PlayerProfileView(player: $0) }
    }
}
