//
//  SocialViews.swift
//  Endgame Fitness
//
//  Sign-in, the player card, and the Community tab (feed, leaderboard, friends,
//  guild). This is where the app stops being a spreadsheet and starts being a
//  game other people can see.
//
//  NOTE: the main file declares its own `ProgressView` struct, which shadows
//  SwiftUI's. Anywhere a spinner or bar is needed here, use `SwiftUI.ProgressView`
//  explicitly or the compiler resolves to the app's chart view instead.
//

import SwiftUI

// MARK: - Sign in

struct SignInView: View {
    @ObservedObject var auth = BatesAIAuth.shared

    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isRegistering = false
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                VStack(spacing: 12) {
                    SignInWithAppleButtonView {
                        run { await auth.signInWithApple() }
                    }
                    .frame(height: 46)

                    Button {
                        run { await auth.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "globe")
                            Text("Continue with Google").fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.platformControlBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 380)

                dividerRow

                emailForm

                if let error = auth.lastError, !error.isEmpty {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }

                Text("Your Endgame Fitness profile is your BatesAI membership. Sign in once and your training follows you to every device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(
                colors: [Color.lightPurpleBg, Color.lightBlueBg],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .overlay {
            if isWorking {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    SwiftUI.ProgressView().controlSize(.large)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 52))
                .foregroundStyle(Color.brandPurple)
            Text("Endgame Fitness")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Train. Level up. Bring friends.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    private var dividerRow: some View {
        HStack {
            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
            Text("or").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
        }
        .frame(maxWidth: 380)
    }

    private var emailForm: some View {
        VStack(spacing: 12) {
            if isRegistering {
                PlatformTextField(placeholder: "Name", text: $name)
            }
            PlatformTextField(placeholder: "Email", text: $email)
            PlatformTextField(placeholder: "Password", text: $password, isSecure: true)

            Button {
                run {
                    if isRegistering {
                        await auth.register(email: email, password: password, name: name)
                    } else {
                        await auth.signIn(email: email, password: password)
                    }
                }
            } label: {
                Text(isRegistering ? "Create account" : "Sign in")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.brandPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

            Button(isRegistering ? "Already have an account? Sign in"
                                 : "New here? Create an account") {
                isRegistering.toggle()
                auth.lastError = nil
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(Color.brandPurple)
        }
        .frame(maxWidth: 380)
    }

    private func run(_ operation: @escaping () async -> Void) {
        isWorking = true
        Task {
            await operation()
            isWorking = false
        }
    }
}

/// Apple's own button, wrapped so the call site stays platform-neutral.
struct SignInWithAppleButtonView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                Text("Sign in with Apple").fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundStyle(Color.white)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Player card

struct PlayerCardView: View {
    let profile: FitnessProfile
    var compact = false

    @State private var showTalents = false
    @State private var showAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack(spacing: 12) {
                Button { showAccount = true } label: { avatar }
                    .buttonStyle(.plain)
                    .help("Account")

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(compact ? .headline : .title2.bold())
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(profile.rankTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(profile.rankColor)
                        if profile.prestige > 0 {
                            Label("\(profile.prestige)", systemImage: "star.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.brandYellow)
                        }
                    }
                }

                Spacer()

                if profile.talentPoints > 0 {
                    Button { showTalents = true } label: {
                        TalentPointsBadge(points: profile.talentPoints)
                    }
                    .buttonStyle(.plain)
                    .help("Spend talent points")
                }

                if profile.currentStreak > 0 {
                    VStack(spacing: 0) {
                        Text("🔥").font(compact ? .body : .title3)
                        Text("\(profile.currentStreak)")
                            .font(.caption.bold())
                            .foregroundStyle(Color.brandOrange)
                    }
                }
            }

            xpBar

            if !compact {
                HStack(spacing: 18) {
                    stat("Workouts", "\(profile.totalWorkouts)")
                    stat("Volume", Self.compactNumber(profile.totalVolume) + " lb")
                    stat("Best streak", "\(profile.longestStreak)d")
                    Button { showTalents = true } label: {
                        stat("Talents", profile.talentPoints > 0 ? "\(profile.talentPoints) to spend" : "View", tint: .brandPurple)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(compact ? 12 : 18)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showTalents) { TalentTreeView() }
        .sheet(isPresented: $showAccount) { NavigationStack { AccountView() } }
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [profile.rankColor, profile.rankColor.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            Text("\(profile.level)")
                .font((compact ? Font.headline : Font.title2).bold())
                .foregroundStyle(.white)
        }
        .frame(width: compact ? 38 : 52, height: compact ? 38 : 52)
    }

    private var xpBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.brandPurple, Color.brandBlue],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geometry.size.width * profile.levelProgress))
                        .animation(.spring(response: 0.6, dampingFraction: 0.8),
                                   value: profile.levelProgress)
                }
            }
            .frame(height: 8)

            HStack {
                Text("Level \(profile.level)")
                    .font(.caption2.weight(.semibold))
                Spacer()
                Text("\(profile.xpIntoLevel) / \(profile.xpNeededForLevel) XP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.bold()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 12,500 -> "12.5k". Keeps stat rows from reflowing as numbers grow.
    static func compactNumber(_ value: Double) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...:     return String(format: "%.1fk", value / 1_000)
        default:           return String(format: "%.0f", value)
        }
    }
}

// MARK: - Community

struct CommunityView: View {
    @ObservedObject var game = GameProfileService.shared
    @ObservedObject var auth = BatesAIAuth.shared

    enum Section: String, CaseIterable, Identifiable {
        case feed = "Feed"
        case leaderboard = "Leaderboard"
        case friends = "Friends"
        case guild = "Guild"
        case challenges = "Challenges"
        case quests = "Quests"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .feed:        return "bolt.horizontal.fill"
            case .leaderboard: return "trophy.fill"
            case .friends:     return "person.2.fill"
            case .guild:       return "shield.lefthalf.filled"
            case .challenges:  return "flag.2.crossed.fill"
            case .quests:      return "checkmark.seal.fill"
            }
        }
    }

    @State private var section: Section = .feed
    @State private var leaderboardScope = "global"
    @State private var leaderboardMetric = "xp"

    var body: some View {
        VStack(spacing: 0) {
            if let profile = game.profile {
                PlayerCardView(profile: profile, compact: true)
                    .padding([.horizontal, .top], 16)
            }

            Picker("", selection: $section) {
                ForEach(Section.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)

            Divider()

            Group {
                switch section {
                case .feed:        feedList
                case .leaderboard: leaderboardList
                case .friends:     friendsList
                case .guild:       guildPane
                case .challenges:  ChallengesView()
                case .quests:      QuestsAndAchievementsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await game.loadAll() }
        .onChange(of: section) { _, newValue in
            Task {
                switch newValue {
                case .feed:        await game.loadFeed()
                case .leaderboard: await game.loadLeaderboard(scope: leaderboardScope, metric: leaderboardMetric)
                case .friends:     await game.loadFriends()
                case .guild:       await game.loadGuild()
                case .challenges:  await game.loadChallenges()
                case .quests:      await game.loadQuests()
                }
            }
        }
    }

    // MARK: Feed

    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if game.feed.isEmpty {
                    emptyState(
                        icon: "bolt.horizontal",
                        title: "Nothing here yet",
                        message: "Finish a workout, or add a friend, and this fills up fast."
                    )
                }
                ForEach(game.feed) { item in
                    ActivityRow(item: item) { emoji in
                        Task { await game.react(to: item.id, emoji: emoji) }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: Leaderboard

    private var leaderboardList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Scope", selection: $leaderboardScope) {
                    Text("Global").tag("global")
                    Text("Friends").tag("friends")
                    Text("Guild").tag("guild")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("Metric", selection: $leaderboardMetric) {
                    Text("XP").tag("xp")
                    Text("Streak").tag("streak")
                    Text("Volume").tag("volume")
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onChange(of: leaderboardScope) { _, _ in reloadLeaderboard() }
            .onChange(of: leaderboardMetric) { _, _ in reloadLeaderboard() }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if game.leaderboard.isEmpty {
                        emptyState(
                            icon: "trophy",
                            title: "No standings yet",
                            message: "Ranks appear once people start logging workouts."
                        )
                    }
                    ForEach(game.leaderboard) { entry in
                        LeaderboardRow(entry: entry, metric: leaderboardMetric)
                    }
                }
                .padding(16)
            }
        }
        .task { reloadLeaderboard() }
    }

    private func reloadLeaderboard() {
        Task { await game.loadLeaderboard(scope: leaderboardScope, metric: leaderboardMetric) }
    }

    // MARK: Friends

    @State private var friendEmail = ""
    @State private var friendError: String?
    @State private var copiedCode = false

    private var friendsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let code = game.profile?.friendCode {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your friend code").font(.caption).foregroundStyle(.secondary)
                            Text(code)
                                .font(.system(.title2, design: .monospaced).weight(.bold))
                                .tracking(2)
                        }
                        Spacer()
                        Button(copiedCode ? "Copied" : "Copy") {
                            Platform.copyToClipboard(code)
                            copiedCode = true
                            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedCode = false }
                        }
                    }
                    .padding(14)
                    .background(Color.brandPurple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 8) {
                    PlatformTextField(placeholder: "Friend code or email", text: $friendEmail)
                    Button("Add") {
                        let query = friendEmail
                        friendEmail = ""
                        friendError = nil
                        Task { friendError = await game.requestFriend(query: query) }
                    }
                    .disabled(friendEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let friendError {
                    Text(friendError).font(.caption).foregroundStyle(.red)
                }

                if !game.incomingRequests.isEmpty {
                    Text("Requests").font(.headline)
                    ForEach(game.incomingRequests) { friend in
                        HStack {
                            FriendRow(friend: friend)
                            Spacer()
                            Button("Accept") {
                                Task { await game.respondToFriendRequest(userID: friend.userID, accept: true) }
                            }
                            Button("Decline") {
                                Task { await game.respondToFriendRequest(userID: friend.userID, accept: false) }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Friends").font(.headline)
                if game.friends.isEmpty {
                    emptyState(
                        icon: "person.2",
                        title: "No friends yet",
                        message: "Training with someone watching is the whole point. Share your code or add theirs above."
                    )
                }
                ForEach(game.friends) { friend in
                    FriendRow(friend: friend)
                }
            }
            .padding(16)
        }
    }

    // MARK: Guild

    @State private var newGuildName = ""
    @State private var newGuildMotto = ""

    private var guildPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let guild = game.guild {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(guild.name).font(.title2.bold())
                        if let motto = guild.motto, !motto.isEmpty {
                            Text(motto).font(.callout).foregroundStyle(.secondary)
                        }
                        Text("\(game.guildMembers.count) / \(guild.memberCap) members")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.platformControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Weekly co-op boss: every member's synced volume is damage.
                    RaidCard()

                    ForEach(game.guildMembers) { member in
                        HStack {
                            Text(member.displayName).fontWeight(.medium)
                            if member.role != "member" {
                                Text(member.role.capitalized)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.brandPurple.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            Text("Lv \(member.level)").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    Button("Leave guild") { Task { await game.leaveGuild() } }
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                } else {
                    emptyState(
                        icon: "shield.lefthalf.filled",
                        title: "You're not in a guild",
                        message: "A guild is a small crew with a shared leaderboard. Start one."
                    )
                    PlatformTextField(placeholder: "Guild name", text: $newGuildName)
                    PlatformTextField(placeholder: "Motto (optional)", text: $newGuildMotto)
                    Button("Create guild") {
                        let name = newGuildName, motto = newGuildMotto
                        newGuildName = ""; newGuildMotto = ""
                        Task { await game.createGuild(name: name, motto: motto) }
                    }
                    .disabled(newGuildName.isEmpty)
                }
            }
            .padding(16)
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

// MARK: - Rows

struct ActivityRow: View {
    let item: ActivityItem
    let onReact: (String) -> Void

    private static let reactions = ["💪", "🔥", "👏"]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.title3)
                .foregroundStyle(item.tint)
                .frame(width: 30, height: 30)
                .background(item.tint.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                (
                    Text(item.isSelf ? "You " : "\(item.displayName) ").bold()
                        + Text(item.summary)
                )
                .font(.callout)

                HStack(spacing: 8) {
                    Text(Self.relativeTime(item.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(item.reactions, id: \.emoji) { reaction in
                        Text("\(reaction.emoji) \(reaction.count)")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    ForEach(Self.reactions, id: \.self) { emoji in
                        Button(emoji) { onReact(emoji) }
                            .buttonStyle(.plain)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    static func relativeTime(_ epoch: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(epoch)), relativeTo: Date()
        )
    }
}

struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    let metric: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(.subheadline.bold())
                .foregroundStyle(medalColor)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .fontWeight(entry.isSelf ? .bold : .regular)
                    .lineLimit(1)
                Text("Level \(entry.level)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(metricValue)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(entry.isSelf ? Color.brandPurple.opacity(0.10) : Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var medalColor: Color {
        switch entry.rank {
        case 1: return Color.brandYellow
        case 2: return .gray
        case 3: return Color.brandOrange
        default: return .secondary
        }
    }

    private var metricValue: String {
        switch metric {
        case "streak": return "\(entry.currentStreak)d 🔥"
        case "volume": return PlayerCardView.compactNumber(entry.totalVolume) + " lb"
        default:       return "\(entry.xp) XP"
        }
    }
}

struct FriendRow: View {
    let friend: Friend

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.brandBlue.opacity(0.2))
                Text("\(friend.level)").font(.caption.bold())
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(friend.displayName).fontWeight(.medium)
                Text("\(friend.xp) XP · \(friend.currentStreak)d streak")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Level-up celebration

struct LevelUpOverlay: View {
    let level: Int
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 0.6
    @State private var glow = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.brandPurple.opacity(0.9), Color.brandBlue.opacity(0.2)],
                                center: .center, startRadius: 4, endRadius: 90
                            )
                        )
                        .frame(width: 150, height: 150)
                        .scaleEffect(glow ? 1.08 : 0.96)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: glow)

                    VStack(spacing: 0) {
                        Text("LEVEL").font(.caption.weight(.black)).foregroundStyle(.white.opacity(0.85))
                        Text("\(level)")
                            .font(.system(size: 58, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }

                Text("Level Up!")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("You earned a talent point.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))

                Button("Nice") { onDismiss() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.brandPurple)
                    .padding(.horizontal, 26).padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .padding(.top, 6)
            }
            .scaleEffect(scale)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { scale = 1 }
            glow = true
            Platform.success()
        }
    }
}
