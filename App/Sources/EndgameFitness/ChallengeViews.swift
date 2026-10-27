//
//  ChallengeViews.swift
//  Endgame Fitness
//
//  Challenges (friend duels + guild challenges) and the Home "Today" cluster.
//  Standings arrive from the server already computed from workout_sessions;
//  nothing here does scoring — it only draws it.
//
//  NOTE: `ProgressView` is shadowed by the app's chart view; use
//  `SwiftUI.ProgressView` for spinners.
//

import SwiftUI

// MARK: - Challenges tab

struct ChallengesView: View {
    @ObservedObject var game = GameProfileService.shared
    @State private var showCreate = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Challenges").font(.title2.bold())
                    Spacer()
                    Button {
                        showCreate = true
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .disabled(game.friends.isEmpty && game.guild == nil)
                }

                if !game.pendingChallenges.isEmpty {
                    sectionHeader("Invites")
                    ForEach(game.pendingChallenges) { challenge in
                        PendingChallengeRow(challenge: challenge) { accept in
                            Task { await game.respondToChallenge(id: challenge.id, accept: accept) }
                        }
                    }
                }

                sectionHeader("Active")
                if game.activeChallenges.isEmpty {
                    emptyState
                }
                ForEach(game.activeChallenges) { challenge in
                    ChallengeCard(challenge: challenge)
                }

                if !game.finishedChallenges.isEmpty {
                    sectionHeader("Recent results")
                    ForEach(game.finishedChallenges) { challenge in
                        ChallengeCard(challenge: challenge)
                    }
                }
            }
            .padding(16)
        }
        .task { await game.loadChallenges() }
        .refreshableIfAvailable { await game.loadChallenges() }
        .sheet(isPresented: $showCreate) {
            CreateChallengeSheet()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "flag.2.crossed")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No active challenges")
                .font(.headline)
            Text(game.friends.isEmpty && game.guild == nil
                 ? "Add a friend or join a guild to start one."
                 : "Challenge a friend to a duel, or rally your guild.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private extension View {
    /// `.refreshable` is a no-op on macOS lists outside a List; keep it iOS-only.
    @ViewBuilder
    func refreshableIfAvailable(_ action: @escaping @Sendable () async -> Void) -> some View {
        #if os(iOS)
        self.refreshable { await action() }
        #else
        self
        #endif
    }
}

// MARK: - Cards

/// Full challenge card. Duels draw a head-to-head bar; guild challenges a
/// ranked list.
struct ChallengeCard: View {
    let challenge: Challenge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if challenge.isDuel {
                HeadToHeadBar(challenge: challenge)
            } else {
                guildStandings
            }
        }
        .padding(14)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if challenge.status == "finished" {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(challenge.didWin ? Color.brandYellow.opacity(0.7) : Color.clear, lineWidth: 1.5)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: challenge.metricIcon)
                .foregroundStyle(Color.brandOrange)
            Text(challenge.isDuel ? "\(challenge.metricLabel) duel" : "Guild \(challenge.metricLabel.lowercased()) challenge")
                .font(.headline)
            Spacer()
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let (text, tint): (String, Color) = {
            switch challenge.status {
            case "finished":
                if challenge.winnerID == nil { return ("Draw", .gray) }
                return challenge.didWin ? ("Won", .brandYellow) : ("Lost", .gray)
            case "pending": return ("Pending", .brandBlue)
            default: return (challenge.timeRemaining, .brandGreen)
            }
        }()
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.18))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private var guildStandings: some View {
        VStack(spacing: 6) {
            ForEach(challenge.standings.prefix(8)) { row in
                HStack(spacing: 10) {
                    Text("#\(row.rank)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 28, alignment: .leading)
                        .foregroundStyle(row.rank == 1 ? Color.brandYellow : .secondary)
                    Text(row.displayName)
                        .fontWeight(row.isSelf ? .bold : .regular)
                        .lineLimit(1)
                    if row.isSelf {
                        Text("you").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(challenge.format(row.score))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
        }
    }
}

/// Two-sided bar: you on the left, them on the right, widths proportional to score.
struct HeadToHeadBar: View {
    let challenge: Challenge

    private var me: Challenge.Standing? { challenge.me }
    private var them: Challenge.Standing? { challenge.them }

    private var myFraction: Double {
        let a = me?.score ?? 0, b = them?.score ?? 0
        if a + b <= 0 { return 0.5 }
        return a / (a + b)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("You").font(.caption.weight(.semibold))
                    Text(challenge.format(me?.score ?? 0))
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(Color.brandPurple)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(them?.displayName ?? "Opponent").font(.caption.weight(.semibold)).lineLimit(1)
                    Text(challenge.format(them?.score ?? 0))
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(Color.brandOrange)
                }
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(Color.brandPurple)
                        .frame(width: max(4, (geo.size.width - 2) * myFraction))
                    Capsule().fill(Color.brandOrange)
                }
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: myFraction)
            }
            .frame(height: 10)
        }
    }
}

struct PendingChallengeRow: View {
    let challenge: Challenge
    let respond: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: challenge.metricIcon)
                .foregroundStyle(Color.brandOrange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                if challenge.awaitingMe {
                    Text("\(challenge.them?.displayName ?? "A friend") challenged you")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text("Waiting on \(challenge.them?.displayName ?? "your friend")")
                        .font(.subheadline.weight(.semibold))
                }
                Text("\(challenge.metricLabel) · \(max(1, (challenge.endsAt - challenge.startsAt) / 86400)) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if challenge.awaitingMe {
                Button("Decline") { respond(false) }
                    .buttonStyle(.bordered)
                Button("Accept") { respond(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandGreen)
            } else {
                SwiftUI.ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Compact card for the Home dashboard: the closest active duel, or a guild
/// challenge if there is no duel.
struct LiveDuelCard: View {
    @ObservedObject var game = GameProfileService.shared
    var onOpen: () -> Void = {}

    private var featured: Challenge? {
        game.activeChallenges.first { $0.isDuel } ?? game.activeChallenges.first
    }

    var body: some View {
        if let challenge = featured {
            Button {
                // Community opens on Challenges, not the feed.
                game.requestedCommunitySection = .challenges
                onOpen()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(challenge.isDuel ? "Live duel" : "Guild challenge", systemImage: "flag.2.crossed.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandOrange)
                        Spacer()
                        Text(challenge.timeRemaining)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if challenge.isDuel {
                        HeadToHeadBar(challenge: challenge)
                    } else if let me = challenge.me {
                        HStack {
                            Text("You're #\(me.rank) of \(challenge.standings.count)")
                                .font(.headline)
                            Spacer()
                            Text(challenge.format(me.score))
                                .font(.headline.monospacedDigit())
                        }
                    }
                }
                .padding(12)
                .background(Color.platformControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Create sheet

struct CreateChallengeSheet: View {
    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "duel"
    @State private var metric = "volume"
    @State private var days = 7
    @State private var opponentID: String = ""
    @State private var isWorking = false
    @State private var error: String?

    private var canSubmit: Bool {
        if isWorking { return false }
        return kind == "duel" ? !opponentID.isEmpty : game.guild != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New challenge").font(.title2.bold())

            Picker("Type", selection: $kind) {
                // Short labels: the full phrases clip on a 390pt-wide iPhone.
                Text("Duel").tag("duel")
                if game.guild != nil { Text("Guild").tag("guild") }
            }
            .compactSegmentedPicker()
            .labelsHidden()

            if kind == "duel" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Opponent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if game.friends.isEmpty {
                        Text("Add a friend first.").foregroundStyle(.secondary)
                    } else {
                        Picker("Opponent", selection: $opponentID) {
                            Text("Choose…").tag("")
                            ForEach(game.friends) { friend in
                                Text("\(friend.displayName) · Lv \(friend.level)").tag(friend.userID)
                            }
                        }
                        .labelsHidden()
                    }
                }
            } else if let guild = game.guild {
                Text("Everyone in \(guild.name) (\(game.guildMembers.count) members) is enrolled. Officers and owners only.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Metric").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Metric", selection: $metric) {
                    Text("Volume").tag("volume")
                    Text("Workouts").tag("workouts")
                    Text("Streak").tag("streak")
                }
                .compactSegmentedPicker()
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Length").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Length", selection: $days) {
                    Text("3d").tag(3)
                    Text("7d").tag(7)
                    Text("14d").tag(14)
                    Text("30d").tag(30)
                }
                .compactSegmentedPicker()
                .labelsHidden()
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    isWorking = true
                    Task {
                        let result = await game.createChallenge(
                            kind: kind, metric: metric,
                            opponentUserID: kind == "duel" ? opponentID : nil,
                            days: days
                        )
                        isWorking = false
                        if let result { error = result } else { dismiss() }
                    }
                } label: {
                    if isWorking {
                        SwiftUI.ProgressView().controlSize(.small)
                    } else {
                        Text(kind == "duel" ? "Send challenge" : "Start challenge")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandOrange)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: Platform.isDesktop ? 420 : nil)
        .onAppear {
            if opponentID.isEmpty, let first = game.friends.first { opponentID = first.userID }
        }
    }
}

// MARK: - Home "Today" cluster

/// Streak flame + XP ring + today's workout CTA + friends strip. Reads the
/// server profile when signed in and falls back to local WorkoutManager stats
/// so the card is never blank.
struct TodayCardCluster: View {
    @ObservedObject var game = GameProfileService.shared
    let localStreak: Int
    let todaysWorkout: ScheduledWorkout?
    let workoutDoneToday: Bool
    let onStartWorkout: () -> Void
    let onOpenCommunity: () -> Void

    private var streak: Int { game.profile?.currentStreak ?? localStreak }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today").font(.headline)

            HStack(spacing: 12) {
                streakTile
                xpTile
                workoutTile
            }
            .frame(minHeight: 96)

            LiveDuelCard(onOpen: onOpenCommunity)

            FriendsStrip(items: game.feed.filter { !$0.isSelf }, onOpen: onOpenCommunity)
        }
    }

    private var streakTile: some View {
        VStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 26))
                .foregroundStyle(streak > 0 ? Color.brandOrange : Color.gray.opacity(0.5))
                .symbolEffectIfAvailable(active: streak > 0)
            Text("\(streak)")
                .font(.title2.monospacedDigit().bold())
            Text(streak == 0 && game.profile?.streakAlive == false ? "start a streak" : "day streak")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let freezes = game.profile?.streakFreezes, freezes > 0 {
                Label("\(freezes)", systemImage: "snowflake")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.brandBlue)
                    .help("Streak freezes protect your streak on a missed day.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var xpTile: some View {
        VStack(spacing: 4) {
            if let profile = game.profile {
                XPRing(progress: profile.levelProgress, level: profile.level)
                    .frame(width: 44, height: 44)
                Text("\(profile.xpNeededForLevel - profile.xpIntoLevel) XP")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text("to level \(profile.level + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                XPRing(progress: 0, level: 1).frame(width: 44, height: 44)
                Text("Sign in").font(.caption.weight(.semibold))
                Text("to earn XP").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var workoutTile: some View {
        Button(action: onStartWorkout) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: workoutDoneToday ? "checkmark.circle.fill" : "play.circle.fill")
                        .foregroundStyle(workoutDoneToday ? Color.brandGreen : Color.brandBlue)
                    Text(workoutDoneToday ? "Done today" : (todaysWorkout == nil ? "Rest day" : "Up next"))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                }
                Text(todaysWorkout?.workoutType ?? "Free session")
                    .font(.subheadline.bold())
                    .lineLimit(2)
                if let w = todaysWorkout {
                    Text("\(w.exercises.count) exercises · \(w.estimatedDuration) min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap to log anything")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background((workoutDoneToday ? Color.brandGreen : Color.brandBlue).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    @ViewBuilder
    func symbolEffectIfAvailable(active: Bool) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.symbolEffect(.pulse, isActive: active)
        } else {
            self
        }
    }
}

struct XPRing: View {
    let progress: Double
    let level: Int

    var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(
                    AngularGradient(colors: [Color.brandPurple, Color.brandBlue, Color.brandPurple], center: .center),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.7, dampingFraction: 0.85), value: progress)
            Text("\(level)")
                .font(.caption.bold().monospacedDigit())
        }
    }
}

/// Horizontal strip of friends' most recent activity. "Training now" = a
/// workout item within the last 90 minutes.
struct FriendsStrip: View {
    let items: [ActivityItem]
    var onOpen: () -> Void = {}

    @State private var selectedPlayer: PlayerRef?

    private var recent: [ActivityItem] {
        // One entry per friend, newest first.
        var seen = Set<String>()
        return items.filter { seen.insert($0.userID).inserted }.prefix(8).map { $0 }
    }

    private func isLive(_ item: ActivityItem) -> Bool {
        item.kind == "workout" && Date().timeIntervalSince1970 - Double(item.createdAt) < 90 * 60
    }

    var body: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(recent.contains(where: isLive) ? "Friends training now" : "Friends recently")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("See all", action: onOpen)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.brandBlue)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(recent) { item in
                            Button {
                                selectedPlayer = PlayerRef(id: item.userID, displayName: item.displayName)
                            } label: {
                                chip(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .playerProfileSheet($selectedPlayer)
        }
    }

    private func chip(_ item: ActivityItem) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AvatarBadgeView(config: nil, level: item.level, cosmetic: item.authorCosmetic,
                                size: 30, tint: FitnessProfile.rankColor(for: item.level))
                if isLive(item) {
                    Circle().fill(Color.brandGreen)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.platformControlBackground, lineWidth: 1.5))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                Text(item.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.platformControlBackground)
        .clipShape(Capsule())
    }
}

