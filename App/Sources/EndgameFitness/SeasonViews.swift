//
//  SeasonViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Seasons (API_V2 §6): eight weeks, 30 reward tiers, a fresh leaderboard.
//  Season XP is the XP earned while the season runs, so a new player can
//  chase the top of this board even though the all-time one is out of reach.
//  The server owns the track; this file draws it and claims rewards.
//

import SwiftUI

struct SeasonView: View {
    @ObservedObject var game = GameProfileService.shared
    let open: (CommunitySheet) -> Void

    @State private var claiming: Int?
    @State private var claimError: String?
    @State private var showAllTiers = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let state = game.season {
                    SeasonHeader(state: state)
                    if let claimError {
                        Text(claimError).font(.caption).foregroundStyle(.red)
                    }
                    tierTrack(state)
                    standings(state)
                } else if let error = game.seasonError {
                    VStack(spacing: 10) {
                        CommunityEmptyState(icon: "calendar.badge.exclamationmark",
                                            title: "Season unavailable", message: error)
                        Button("Try again") { Task { await game.loadSeason() } }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    SwiftUI.ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .refreshable { await game.loadSeason() }
        .task { await game.loadSeason() }
    }

    /// Reached tiers first (so claims are at the top), then the next few.
    private func visibleTiers(_ state: SeasonState) -> [SeasonTier] {
        if showAllTiers { return state.season.tiers }
        let nextLocked = state.season.tiers.first { !state.isReached($0) }?.tier ?? Int.max
        return state.season.tiers.filter { tier in
            (state.isReached(tier) && !state.isClaimed(tier.tier)) || (tier.tier >= nextLocked && tier.tier < nextLocked + 5)
        }
    }

    private func tierTrack(_ state: SeasonState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reward track").font(.headline)
                Spacer()
                Button(showAllTiers ? "Show fewer" : "All \(state.season.tiers.count) tiers") {
                    showAllTiers.toggle()
                }
                .font(.caption)
            }
            ForEach(visibleTiers(state)) { tier in
                SeasonTierRow(
                    tier: tier,
                    reached: state.isReached(tier),
                    claimed: state.isClaimed(tier.tier),
                    isClaiming: claiming == tier.tier,
                    seasonXP: state.progress.seasonXP
                ) {
                    Task { await claim(tier.tier) }
                }
            }
        }
    }

    private func standings(_ state: SeasonState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Season leaderboard").font(.headline)
            if state.leaderboard.isEmpty {
                Text("No one has earned season XP yet. The first workout of the season takes the top spot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.leaderboard) { row in
                Button {
                    if !row.isSelf { open(.player(PlayerRef(id: row.userID, displayName: row.displayName))) }
                } label: {
                    SeasonStandingRow(row: row)
                }
                .buttonStyle(.plain)
            }
            if let profile = game.profile, !profile.isPublic {
                Text("Your profile is private, so you only appear here to yourself and your friends.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func claim(_ tier: Int) async {
        claiming = tier
        claimError = await game.claimSeasonTier(tier)
        if claimError == nil { Platform.success() }
        claiming = nil
    }
}

struct SeasonHeader: View {
    let state: SeasonState

    private var nextTier: SeasonTier? {
        state.season.tiers.first { !state.isReached($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SEASON \(state.season.number)")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.secondary)
                    Text(state.season.name).font(.title2.bold())
                    if let theme = state.season.theme, !theme.isEmpty {
                        Text(theme).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                SeasonCountdown(startsAt: state.season.startsAt, endsAt: state.season.endsAt)
            }
            progressBar
            HStack {
                Text("\(state.progress.seasonXP) season XP · tier \(state.progress.tier) of \(state.season.tiers.count)")
                    .font(.caption.monospacedDigit())
                Spacer()
                if let next = nextTier {
                    Text("\(max(0, next.xpRequired - state.progress.seasonXP)) XP to tier \(next.tier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Track complete").font(.caption.weight(.semibold)).foregroundStyle(Color.brandGreen)
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color.brandPurple.opacity(0.18), Color.brandBlue.opacity(0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var progressBar: some View {
        let previous = state.season.tiers.last { state.isReached($0) }?.xpRequired ?? 0
        let next = nextTier?.xpRequired ?? max(previous, 1)
        let span = max(1, next - previous)
        let fraction = nextTier == nil ? 1 : min(1, max(0, Double(state.progress.seasonXP - previous) / Double(span)))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [Color.brandPurple, Color.brandBlue],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 10)
    }
}

struct SeasonCountdown: View {
    let startsAt: Int
    let endsAt: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = Int(context.date.timeIntervalSince1970)
            let upcoming = now < startsAt
            let remaining = max(0, (upcoming ? startsAt : endsAt) - now)
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: "hourglass").font(.caption).foregroundStyle(.secondary)
                Text(remaining > 0 ? Self.format(remaining) : "Ended")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(upcoming ? "until it starts" : "left").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    static func format(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h \((seconds % 3_600) / 60)m"
    }
}

struct SeasonTierRow: View {
    let tier: SeasonTier
    let reached: Bool
    let claimed: Bool
    let isClaiming: Bool
    let seasonXP: Int
    let onClaim: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(tier.tier)")
                .font(.subheadline.bold().monospacedDigit())
                .frame(width: 30, height: 30)
                .background(Circle().fill(reached ? Color.brandPurple.opacity(0.25) : Color.gray.opacity(0.12)))

            Image(systemName: tier.reward.icon)
                .foregroundStyle(tier.reward.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(tier.reward.label).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(tier.xpRequired) season XP")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(10)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(reached && !claimed ? Color.brandYellow.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .opacity(claimed ? 0.6 : 1)
    }

    @ViewBuilder
    private var trailing: some View {
        if claimed {
            Label("Claimed", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brandGreen)
        } else if reached {
            Button(action: onClaim) {
                if isClaiming {
                    SwiftUI.ProgressView().controlSize(.small)
                } else {
                    Text("Claim")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.brandYellow))
                }
            }
            .buttonStyle(.plain)
            .disabled(isClaiming)
        } else {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Locked until \(tier.xpRequired) season XP")
        }
    }
}

struct SeasonStandingRow: View {
    let row: SeasonStanding

    var body: some View {
        HStack(spacing: 10) {
            Text("\(row.rank)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(row.rank <= 3 ? Color.brandYellow : .secondary)
                .frame(width: 26, alignment: .trailing)
            AvatarBadgeView(config: nil, level: row.level, size: 28,
                            tint: FitnessProfile.rankColor(for: row.level))
            Text(row.isSelf ? "\(row.displayName) (you)" : row.displayName)
                .fontWeight(row.isSelf ? .bold : .regular)
                .lineLimit(1)
            Spacer()
            Text("\(row.seasonXP) XP")
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(row.isSelf ? Color.brandPurple.opacity(0.10) : Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}
