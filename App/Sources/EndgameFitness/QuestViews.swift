//
//  QuestViews.swift
//  Endgame Fitness
//
//  The game loop: a daily/weekly quest board and an achievement wall. Quests
//  are generated and progressed on the server; the client only renders and
//  claims. Cross-platform SwiftUI — no AppKit/UIKit here.
//

import SwiftUI

// MARK: - Quest board

struct QuestBoardView: View {
    @ObservedObject var game = GameProfileService.shared
    @ObservedObject var players = LocalPlayerStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if players.current == nil {
                    signedOut
                } else {
                    questSection(title: "Daily Quests", subtitle: "Reset at midnight UTC", quests: game.dailyQuests)
                    questSection(title: "Weekly Quests", subtitle: "Reset Monday", quests: game.weeklyQuests)
                    if game.dailyQuests.isEmpty && game.weeklyQuests.isEmpty {
                        Text(game.questsLoaded
                             ? "No quests right now. New ones arrive at the daily reset."
                             : "Loading your board…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
            }
            .padding(16)
        }
        .task { await game.loadQuests() }
        .refreshableIfAvailable { await game.loadQuests() }
    }

    private var signedOut: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Pick a player to pick up quests").font(.headline)
            Text("Daily and weekly quests pay XP on top of your workouts.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private func questSection(title: String, subtitle: String, quests: [Quest]) -> some View {
        if !quests.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(quests) { quest in
                    QuestRow(quest: quest) {
                        Task { await game.claimQuest(quest) }
                    }
                }
            }
        }
    }
}

struct QuestRow: View {
    let quest: Quest
    let onClaim: () -> Void

    @State private var burst = false
    @State private var claimedScale: CGFloat = 1

    private var tint: Color { quest.isDaily ? .brandGreen : .brandBlue }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(quest.isComplete ? 0.28 : 0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: quest.claimed ? "checkmark" : quest.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(quest.claimed ? Color.brandGreen : tint)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(quest.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("+\(quest.xpReward) XP")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.brandYellow)
                }
                Text(quest.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    QuestProgressBar(fraction: quest.fraction, tint: tint, complete: quest.isComplete)
                    Text(quest.progressLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }

            trailing
        }
        .padding(12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(quest.isClaimable ? Color.brandYellow.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .opacity(quest.claimed ? 0.6 : 1)
        .scaleEffect(claimedScale)
        .overlay(alignment: .center) {
            if burst {
                Text("+\(quest.xpReward) XP")
                    .font(.title2.weight(.black))
                    .foregroundStyle(Color.brandYellow)
                    .transition(.asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .onChange(of: quest.claimed) { _, claimed in
            guard claimed else { return }
            Platform.success()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) {
                claimedScale = 1.04
                burst = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.4)) {
                    claimedScale = 1
                    burst = false
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if quest.isClaimable {
            Button(action: onClaim) {
                Text("Claim")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.brandYellow)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        } else if quest.claimed {
            Text("Done")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct QuestProgressBar: View {
    let fraction: Double
    let tint: Color
    var complete: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.2))
                Capsule()
                    .fill(complete ? Color.brandGreen : tint)
                    .frame(width: max(0, geo.size.width * fraction))
                    .animation(.easeOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Dashboard card

/// Compact "Today's Quests" card for the Home dashboard. Tapping a claimable
/// quest claims it in place; the header button jumps to the full board.
struct TodaysQuestsCard: View {
    @ObservedObject var game = GameProfileService.shared
    @ObservedObject var players = LocalPlayerStore.shared
    var onOpenBoard: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Today's Quests", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Color.brandGreen)
                Spacer()
                if game.claimableQuestCount > 0 {
                    Text("\(game.claimableQuestCount) to claim")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.brandYellow)
                        .clipShape(Capsule())
                }
                Button("All quests") {
                    // Community opens on the Quests section, not the feed.
                    game.requestedCommunitySection = .quests
                    onOpenBoard()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if players.current == nil {
                Text("Pick a player to receive daily quests.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if game.dailyQuests.isEmpty {
                Text(game.questsLoaded ? "No daily quests right now." : "Loading…")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(game.dailyQuests) { quest in
                    HStack(spacing: 10) {
                        Image(systemName: quest.claimed ? "checkmark.circle.fill" : quest.icon)
                            .foregroundStyle(quest.claimed ? Color.brandGreen : Color.brandBlue)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(quest.title).font(.caption.weight(.semibold))
                                Spacer()
                                Text("+\(quest.xpReward)").font(.caption2).foregroundStyle(Color.brandYellow)
                            }
                            QuestProgressBar(fraction: quest.fraction, tint: .brandBlue, complete: quest.isComplete)
                        }
                        if quest.isClaimable {
                            Button("Claim") { Task { await game.claimQuest(quest) } }
                                .buttonStyle(.plain)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.brandYellow)
                                .clipShape(Capsule())
                        }
                    }
                    .opacity(quest.claimed ? 0.55 : 1)
                }
            }
        }
        .padding()
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await game.loadQuests() }
    }
}

// MARK: - Achievements

struct AchievementsView: View {
    @ObservedObject var game = GameProfileService.shared
    @ObservedObject var players = LocalPlayerStore.shared

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if players.current == nil {
                    Text("Pick a player to track achievements.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                } else {
                    HStack {
                        Text("Achievements").font(.headline)
                        Spacer()
                        let unlocked = game.achievements.filter(\.unlocked).count
                        Text("\(unlocked) / \(game.achievements.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(game.achievements) { achievement in
                            AchievementTile(achievement: achievement)
                        }
                    }
                }
            }
            .padding(16)
        }
        .task { await game.loadAchievements() }
    }
}

struct AchievementTile: View {
    let achievement: Achievement

    private var tint: Color { achievement.rarityColor }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(achievement.unlocked
                          ? AnyShapeStyle(RadialGradient(colors: [tint.opacity(0.9), tint.opacity(0.25)],
                                                         center: .center, startRadius: 2, endRadius: 30))
                          : AnyShapeStyle(Color.gray.opacity(0.15)))
                    .frame(width: 56, height: 56)
                Image(systemName: achievement.unlocked ? achievement.icon : "lock.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(achievement.unlocked ? Color.white : Color.gray)
            }
            Text(achievement.title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
            Text(achievement.desc)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 28, alignment: .top)
            HStack(spacing: 6) {
                Text(achievement.rarity.capitalized)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(achievement.unlocked ? tint : .secondary)
                Text("·").foregroundStyle(.secondary)
                Text("+\(achievement.xp) XP")
                    .font(.caption2)
                    .foregroundStyle(Color.brandYellow)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(achievement.unlocked ? tint.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .saturation(achievement.unlocked ? 1 : 0)
        .opacity(achievement.unlocked ? 1 : 0.7)
    }
}

// MARK: - Combined pane used by CommunityView

struct QuestsAndAchievementsPane: View {
    enum Page: String, CaseIterable, Identifiable {
        case quests = "Quests"
        case achievements = "Achievements"
        var id: String { rawValue }
    }
    @State private var page: Page = .quests

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .compactSegmentedPicker()
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            switch page {
            case .quests:       QuestBoardView()
            case .achievements: AchievementsView()
            }
        }
    }
}

// MARK: - Helpers

private extension View {
    /// `.refreshable` is a no-op on macOS but harmless; keep the call site clean.
    func refreshableIfAvailable(_ action: @escaping @Sendable () async -> Void) -> some View {
        self.refreshable { await action() }
    }
}
