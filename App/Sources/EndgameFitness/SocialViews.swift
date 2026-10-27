//
//  SocialViews.swift
//  Endgame Fitness
//
//  Sign-in, the player card, and the Community tab (feed, leaderboard, friends;
//  guild and season live in GuildViews.swift / SeasonViews.swift). This is
//  where the app stops being a spreadsheet and starts being a game other
//  people can see.
//
//  NOTE: the main file declares its own `ProgressView` struct, which shadows
//  SwiftUI's. Anywhere a spinner or bar is needed here, use `SwiftUI.ProgressView`
//  explicitly or the compiler resolves to the app's chart view instead.
//

import SwiftUI
import AuthenticationServices

// MARK: - Sign in

struct SignInView: View {
    @ObservedObject var auth = BatesAIAuth.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isRegistering = false
    @State private var isWorking = false
    @State private var showForgot = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                providerButtons
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
            .adaptivePadding(32, phone: 20)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.brandPurple.opacity(0.18), Color.platformWindowBackground]
                    : [Color.lightPurpleBg, Color.lightBlueBg],
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

    private var providerButtons: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(isRegistering ? .signUp : .signIn) { request in
                auth.prepareAppleRequest(request)
            } onCompletion: { result in
                run { await auth.completeAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 46)
            // The button does not restyle itself when the appearance flips.
            .id(colorScheme)

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
    }

    private var dividerRow: some View {
        HStack {
            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
            Text("or").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
        }
        .frame(maxWidth: 380)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// nil when the form can be sent, otherwise the hint to show.
    private var formProblem: String? {
        if trimmedEmail.isEmpty || password.isEmpty { return "" }
        if !trimmedEmail.contains("@") || !trimmedEmail.contains(".") { return "Enter a valid email address." }
        if isRegistering && password.count < 8 { return "Passwords need at least 8 characters." }
        return nil
    }

    private var emailForm: some View {
        VStack(spacing: 12) {
            if isRegistering {
                PlatformTextField(placeholder: "Name", text: $name)
            }
            PlatformTextField(placeholder: "Email", text: $email)
            PlatformTextField(placeholder: "Password", text: $password, isSecure: true, onCommit: submit)

            if let problem = formProblem, !problem.isEmpty {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                Text(isRegistering ? "Create account" : "Sign in")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.brandPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(formProblem != nil)
            .opacity(formProblem != nil ? 0.5 : 1)

            HStack {
                Button(isRegistering ? "Already have an account? Sign in"
                                     : "New here? Create an account") {
                    isRegistering.toggle()
                    auth.lastError = nil
                }
                Spacer()
                if !isRegistering {
                    Button("Forgot password?") { showForgot.toggle() }
                }
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(Color.brandPurple)

            if showForgot && !isRegistering {
                ForgotPasswordNote()
            }
        }
        .frame(maxWidth: 380)
    }

    private func submit() {
        guard formProblem == nil else { return }
        run {
            if isRegistering {
                await auth.register(email: email, password: password, name: name)
            } else {
                await auth.signIn(email: email, password: password)
            }
        }
    }

    private func run(_ operation: @escaping () async -> Void) {
        isWorking = true
        Task {
            await operation()
            isWorking = false
        }
    }
}

/// API_V2 §1.3: there is no email reset, so say plainly what works instead.
struct ForgotPasswordNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Forgot your password? Sign in with Apple or Google using the same email, or write to \(BatesAIAuth.helpEmail).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let mail = URL(string: "mailto:\(BatesAIAuth.helpEmail)?subject=Endgame%20Fitness%20sign-in%20help") {
                Link("Email \(BatesAIAuth.helpEmail)", destination: mail)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                Button { showAccount = true } label: {
                    AvatarBadgeView(
                        config: profile.avatarConfig, level: profile.level,
                        cosmetic: profile.cosmetic, size: compact ? 44 : 64, tint: profile.rankColor
                    )
                }
                .buttonStyle(.plain)
                .help("Account")

                identity
                Spacer(minLength: 4)
                badges
            }

            xpBar

            if !compact {
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                statsRow
            }
        }
        .padding(compact ? 12 : 18)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showTalents) { TalentTreeView() }
        .sheet(isPresented: $showAccount) { NavigationStack { AccountView() } }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profile.displayName)
                .font(compact ? .headline : .title2.bold())
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(profile.rankTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(profile.rankColor)
                    .lineLimit(1)
                HeroClassBadge(hero: profile.hero, compact: true)
                if profile.prestige > 0 {
                    Label("\(profile.prestige)", systemImage: "star.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.brandYellow)
                }
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 10) {
            if profile.talentPoints > 0 {
                Button { showTalents = true } label: {
                    TalentPointsBadge(points: profile.talentPoints)
                }
                .buttonStyle(.plain)
                .help("Spend talent points")
            }
            if profile.currentStreak > 0 {
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill")
                        .font(compact ? .body : .title3)
                        .foregroundStyle(Color.brandOrange)
                    Text("\(profile.currentStreak)")
                        .font(.caption.bold())
                        .foregroundStyle(Color.brandOrange)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(profile.currentStreak) day streak")
            }
            if profile.streakFreezes > 0 {
                Label("\(profile.streakFreezes)", systemImage: "snowflake")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandBlue)
                    .help("Streak freezes: each one protects your streak on a missed day.")
            }
        }
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

    private var statsRow: some View {
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

enum CommunitySection: String, CaseIterable, Identifiable {
    case feed = "Feed"
    case leaderboard = "Leaderboard"
    case friends = "Friends"
    case guild = "Guild"
    case season = "Season"
    case challenges = "Challenges"
    case quests = "Quests"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .feed:        return "bolt.horizontal.fill"
        case .leaderboard: return "trophy.fill"
        case .friends:     return "person.2.fill"
        case .guild:       return "shield.lefthalf.filled"
        case .season:      return "calendar.badge.clock"
        case .challenges:  return "flag.2.crossed.fill"
        case .quests:      return "checkmark.seal.fill"
        }
    }
}

/// Every sheet the Community tab can raise, so one `.sheet(item:)` serves all.
enum CommunitySheet: Identifiable {
    case player(PlayerRef)
    case comments(ActivityItem)
    case report(ReportRequest)

    var id: String {
        switch self {
        case .player(let ref):      return "player-\(ref.id)"
        case .comments(let item):   return "comments-\(item.id)"
        case .report(let request):  return "report-\(request.id)"
        }
    }
}

struct CommunityView: View {
    @ObservedObject var game = GameProfileService.shared

    @State private var section: CommunitySection = .feed
    @State private var sheet: CommunitySheet?

    var body: some View {
        VStack(spacing: 0) {
            if let profile = game.profile {
                PlayerCardView(profile: profile, compact: true)
                    .padding([.horizontal, .top], 16)
            }

            CommunitySectionBar(selection: $section)
                .padding(.vertical, 12)

            Divider()

            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            consumeDeepLink()
            await game.loadAll()
        }
        .onChange(of: game.requestedCommunitySection) { _, _ in consumeDeepLink() }
        .onChange(of: section) { _, newValue in
            Task { await refresh(newValue) }
        }
        .sheet(item: $sheet) { item in
            sheetContent(item)
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .feed:        FeedPane(open: open)
        case .leaderboard: LeaderboardPane(open: open)
        case .friends:     FriendsPane(open: open)
        case .guild:       GuildPane(open: open)
        case .season:      SeasonView(open: open)
        case .challenges:  ChallengesView()
        case .quests:      QuestsAndAchievementsPane()
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: CommunitySheet) -> some View {
        switch item {
        case .player(let ref):
            PlayerProfileView(player: ref)
        case .comments(let activity):
            CommentsSheet(item: activity) { ref in
                // Swap the comments sheet for the author's profile.
                sheet = nil
                Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    sheet = .player(ref)
                }
            }
        case .report(let request):
            ReportSheet(request: request)
        }
    }

    private func open(_ item: CommunitySheet) { sheet = item }

    private func consumeDeepLink() {
        guard let requested = game.requestedCommunitySection else { return }
        section = requested
        game.requestedCommunitySection = nil
    }

    private func refresh(_ section: CommunitySection) async {
        switch section {
        case .feed:        await game.loadFeed()
        case .leaderboard: break   // the pane loads with its own scope/metric
        case .friends:     await game.loadFriends()
        case .guild:       await game.loadGuild()
        case .season:      break   // SeasonView loads itself
        case .challenges:  await game.loadChallenges()
        case .quests:      await game.loadQuests()
        }
    }
}

/// Horizontally scrolling chips: seven sections don't fit a 390pt screen as a
/// segmented control, and the same row reads well in a Mac window.
struct CommunitySectionBar: View {
    @Binding var selection: CommunitySection
    @ObservedObject var game = GameProfileService.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CommunitySection.allCases) { item in
                        chip(item).id(item)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    private func chip(_ item: CommunitySection) -> some View {
        let selected = selection == item
        return Button {
            selection = item
        } label: {
            HStack(spacing: 5) {
                Label(item.rawValue, systemImage: item.icon)
                if let count = badge(for: item), count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.brandOrange))
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.platformControlBackground)
            )
            .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(item.rawValue)
    }

    private func badge(for item: CommunitySection) -> Int? {
        switch item {
        case .friends:    return game.incomingRequests.count
        case .quests:     return game.claimableQuestCount
        case .challenges: return game.pendingChallenges.filter(\.awaitingMe).count
        case .season:     return game.season?.claimableCount
        default:          return nil
        }
    }
}

/// Shared empty-state block for the Community panes.
struct CommunityEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
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

// MARK: Feed

struct FeedPane: View {
    @ObservedObject var game = GameProfileService.shared
    let open: (CommunitySheet) -> Void

    @State private var blockCandidate: ActivityItem?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if game.feed.isEmpty {
                    if game.isLoadingFeed {
                        SwiftUI.ProgressView().padding(.vertical, 36)
                    } else {
                        CommunityEmptyState(
                            icon: "bolt.horizontal",
                            title: "Nothing here yet",
                            message: "Finish a workout, add a friend, or join a guild and this fills up fast."
                        )
                    }
                }
                ForEach(game.feed) { item in
                    row(item)
                }
                if game.feedHasMore {
                    Button {
                        Task { await game.loadMoreFeed() }
                    } label: {
                        if game.isLoadingFeed {
                            SwiftUI.ProgressView().controlSize(.small)
                        } else {
                            Text("Load older activity")
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(.vertical, 8)
                }
            }
            .padding(16)
        }
        .refreshable { await game.loadFeed() }
        .confirmationDialog(
            "Block \(blockCandidate?.displayName ?? "this player")?",
            isPresented: Binding(get: { blockCandidate != nil }, set: { if !$0 { blockCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                if let item = blockCandidate {
                    Task { await game.block(userID: item.userID) }
                }
                blockCandidate = nil
            }
            Button("Cancel", role: .cancel) { blockCandidate = nil }
        } message: {
            Text("You won't see each other's activity, comments or rankings, and any friendship ends. You can unblock in Account.")
        }
    }

    private func row(_ item: ActivityItem) -> some View {
        ActivityRow(
            item: item,
            cosmetic: item.isSelf ? game.profile?.cosmetic : item.authorCosmetic,
            onReact: { emoji in Task { await game.toggleReaction(on: item.id, emoji: emoji) } },
            onComments: { open(.comments(item)) },
            onAuthor: item.isSelf ? nil : { open(.player(PlayerRef(id: item.userID, displayName: item.displayName))) },
            actions: { actions(for: item) }
        )
        .contextMenu { actions(for: item) }
        .onAppear {
            if item.id == game.feed.last?.id { Task { await game.loadMoreFeed() } }
        }
    }

    @ViewBuilder
    private func actions(for item: ActivityItem) -> some View {
        if !item.isSelf {
            Button {
                open(.player(PlayerRef(id: item.userID, displayName: item.displayName)))
            } label: {
                Label("View \(item.displayName)", systemImage: "person.crop.circle")
            }
            Button {
                open(.report(ReportRequest(target: .feedItem, targetID: item.id, subject: "\(item.displayName)'s post")))
            } label: {
                Label("Report post…", systemImage: "exclamationmark.bubble")
            }
            Button(role: .destructive) {
                blockCandidate = item
            } label: {
                Label("Block \(item.displayName)…", systemImage: "hand.raised")
            }
        }
        Button {
            open(.comments(item))
        } label: {
            Label("Comments", systemImage: "bubble.left")
        }
    }
}

struct ActivityRow<Actions: View>: View {
    let item: ActivityItem
    /// The author's equipped aura, when known.
    var cosmetic: String?
    let onReact: (String) -> Void
    var onComments: () -> Void = {}
    /// nil for the player's own posts.
    var onAuthor: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    /// The five reactions the server accepts (API_V2 §4).
    static var reactionChoices: [String] { ["💪", "🔥", "👏", "🏆", "⚡"] }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            authorBadge

            VStack(alignment: .leading, spacing: 6) {
                headline
                Text(ActivityRowTime.relative(item.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                reactionBar
            }
        }
        .padding(12)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var authorBadge: some View {
        Button {
            onAuthor?()
        } label: {
            Image(systemName: item.icon)
                .font(.title3)
                .foregroundStyle(item.tint)
                .frame(width: 32, height: 32)
                .background(item.tint.opacity(0.12))
                .clipShape(Circle())
                .overlay {
                    if let cosmetic, !cosmetic.isEmpty {
                        Circle()
                            .strokeBorder(cosmetic.auraColor, lineWidth: 2)
                            .padding(-2.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(onAuthor == nil)
    }

    private var headline: some View {
        HStack(alignment: .top) {
            (
                Text(item.isSelf ? "You " : "\(item.displayName) ").bold()
                    + Text(item.summary)
            )
            .font(.callout)
            .onTapGesture { onAuthor?() }
            Spacer(minLength: 4)
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    private var reactionBar: some View {
        HStack(spacing: 6) {
            ForEach(Self.reactionChoices, id: \.self) { emoji in
                reactionButton(emoji)
            }
            Spacer(minLength: 4)
            Button(action: onComments) {
                Label(item.commentCount > 0 ? "\(item.commentCount)" : "Comment", systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func reactionButton(_ emoji: String) -> some View {
        let reaction = item.reactions.first { $0.emoji == emoji }
        let mine = reaction?.mine ?? false
        let count = reaction?.count ?? 0
        return Button {
            Platform.tick()
            onReact(emoji)
        } label: {
            HStack(spacing: 3) {
                Text(emoji)
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(mine ? Color.brandPurple.opacity(0.22) : Color.gray.opacity(0.10)))
            .overlay(Capsule().stroke(mine ? Color.brandPurple : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(emoji) \(count)\(mine ? ", you reacted" : "")")
    }
}

enum ActivityRowTime {
    static func relative(_ epoch: Int) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(
            for: Date(timeIntervalSince1970: TimeInterval(epoch)), relativeTo: Date()
        )
    }
}

// MARK: Leaderboard

struct LeaderboardPane: View {
    @ObservedObject var game = GameProfileService.shared
    let open: (CommunitySheet) -> Void

    @State private var scope = "global"
    @State private var metric = "xp"
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            ScrollView {
                LazyVStack(spacing: 6) {
                    privacyNote
                    if game.leaderboard.isEmpty && !isLoading {
                        CommunityEmptyState(
                            icon: "trophy",
                            title: "No standings yet",
                            message: "Ranks appear once people start logging workouts."
                        )
                    }
                    ForEach(game.leaderboard) { entry in
                        Button {
                            if !entry.isSelf {
                                open(.player(PlayerRef(id: entry.userID, displayName: entry.displayName)))
                            }
                        } label: {
                            LeaderboardRow(entry: entry, metric: metric)
                        }
                        .buttonStyle(.plain)
                    }
                    if let you = game.leaderboardYou, !game.leaderboard.contains(where: { $0.isSelf }) {
                        LeaderboardRow(entry: you, metric: metric)
                    }
                }
                .padding(16)
            }
            .refreshable { await reload() }
        }
        .task(id: "\(scope)-\(metric)") { await reload() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $scope) {
                Text("Global").tag("global")
                Text("Friends").tag("friends")
                Text("Guild").tag("guild")
            }
            .compactSegmentedPicker()
            .labelsHidden()

            Picker("Metric", selection: $metric) {
                Text("XP").tag("xp")
                Text("Season").tag("season")
                Text("Streak").tag("streak")
                Text("Volume").tag("volume")
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var privacyNote: some View {
        if scope == "global", let profile = game.profile, !profile.isPublic {
            Text("Your profile is private, so you don't appear on the global board. Friends still see you. Change this in Account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.brandBlue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func reload() async {
        isLoading = true
        await game.loadLeaderboard(scope: scope, metric: metric)
        isLoading = false
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

            AvatarBadgeView(config: nil, level: entry.level, cosmetic: entry.cosmetic,
                            size: 30, tint: FitnessProfile.rankColor(for: entry.level))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.isSelf ? "\(entry.displayName) (you)" : entry.displayName)
                    .fontWeight(entry.isSelf ? .bold : .regular)
                    .lineLimit(1)
                Text(entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Level \(entry.level)")
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
        .contentShape(Rectangle())
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
        case "streak": return "\(entry.currentStreak)d"
        case "volume": return PlayerCardView.compactNumber(entry.totalVolume) + " lb"
        case "season": return "\(entry.seasonXP ?? entry.xp) XP"
        default:       return "\(entry.xp) XP"
        }
    }
}

// MARK: Friends

struct FriendsPane: View {
    @ObservedObject var game = GameProfileService.shared
    let open: (CommunitySheet) -> Void

    @State private var query = ""
    @State private var results: [PublicPlayer] = []
    @State private var searched = false
    @State private var isSearching = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var copiedCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                friendCodeCard
                searchBox
                searchResults
                requestsSection
                friendsSection
            }
            .padding(16)
        }
        .refreshable { await game.loadFriends() }
    }

    @ViewBuilder
    private var friendCodeCard: some View {
        if let code = game.profile?.friendCode {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your friend code").font(.caption).foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .tracking(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(copiedCode ? "Copied" : "Copy") {
                    Platform.copyToClipboard(code)
                    copiedCode = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedCode = false }
                }
                ShareLink(item: "Add me on Endgame Fitness. My friend code is \(code).") {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share friend code")
            }
            .padding(14)
            .background(Color.brandPurple.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PlatformTextField(placeholder: "Name, friend code or email", text: $query, onCommit: search)
                Button(trimmedQuery.contains("@") ? "Send request" : "Search", action: search)
                    .disabled(trimmedQuery.count < 2 || isSearching)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageIsError ? Color.red : Color.secondary)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if isSearching {
            SwiftUI.ProgressView().controlSize(.small)
        } else if searched {
            if results.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No public players match \"\(trimmedQuery)\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if looksLikeFriendCode {
                        Button("Send a friend request to code \(trimmedQuery.uppercased())") {
                            Task { await sendRequest(query: trimmedQuery) }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            } else {
                Text("Players").font(.headline)
                ForEach(results) { player in
                    PlayerSearchRow(player: player, alreadyFriend: isFriend(player.userID)) {
                        Task { await addFriend(player) }
                    } onOpen: {
                        open(.player(PlayerRef(id: player.userID, displayName: player.displayName)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var requestsSection: some View {
        if !game.incomingRequests.isEmpty {
            Text("Requests").font(.headline)
            ForEach(game.incomingRequests) { friend in
                HStack {
                    Button { openProfile(friend) } label: { FriendRow(friend: friend) }
                        .buttonStyle(.plain)
                    Spacer()
                    Button("Accept") {
                        Task { show(await game.respondToFriendRequest(userID: friend.userID, accept: true), success: nil) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandGreen)
                    Button("Decline") {
                        Task { show(await game.respondToFriendRequest(userID: friend.userID, accept: false), success: nil) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        if !game.outgoingRequests.isEmpty {
            Text("Sent").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(game.outgoingRequests) { friend in
                HStack {
                    FriendRow(friend: friend)
                    Spacer()
                    Text("Pending").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var friendsSection: some View {
        Text("Friends").font(.headline)
        if game.friends.isEmpty {
            CommunityEmptyState(
                icon: "person.2",
                title: "No friends yet",
                message: "Training with someone watching is the whole point. Share your code, or search for a name above."
            )
        }
        ForEach(game.friends) { friend in
            Button { openProfile(friend) } label: {
                HStack {
                    FriendRow(friend: friend)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var looksLikeFriendCode: Bool {
        trimmedQuery.range(of: "^[A-Za-z0-9]{6,8}$", options: .regularExpression) != nil
    }

    private func isFriend(_ userID: String) -> Bool {
        game.friends.contains { $0.userID == userID }
    }

    private func openProfile(_ friend: Friend) {
        open(.player(PlayerRef(id: friend.userID, displayName: friend.displayName)))
    }

    private func search() {
        let text = trimmedQuery
        guard text.count >= 2 else { return }
        message = nil
        if text.contains("@") {
            // Emails can't be searched (no enumeration); send the request directly.
            Task { await sendRequest(query: text) }
            return
        }
        isSearching = true
        Task {
            do {
                results = try await game.searchPlayers(text)
            } catch {
                results = []
                show(error.localizedDescription, success: nil)
            }
            searched = true
            isSearching = false
        }
    }

    private func sendRequest(query: String) async {
        let failure = await game.requestFriend(query: query)
        show(failure, success: query.contains("@")
             ? "If that email has an account, they'll see your request."
             : "Friend request sent.")
        if failure == nil { self.query = "" }
    }

    private func addFriend(_ player: PublicPlayer) async {
        let failure = await game.requestFriend(userID: player.userID)
        show(failure, success: "Friend request sent to \(player.displayName).")
    }

    private func show(_ failure: String?, success: String?) {
        if let failure {
            message = failure
            messageIsError = true
        } else {
            message = success
            messageIsError = false
        }
    }
}

struct PlayerSearchRow: View {
    let player: PublicPlayer
    let alreadyFriend: Bool
    let onAdd: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    AvatarBadgeView(config: player.avatarConfig, level: player.level, cosmetic: player.cosmetic,
                                    size: 34, tint: FitnessProfile.rankColor(for: player.level))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.displayName).fontWeight(.medium)
                        Text("Lv \(player.level) · \(player.rankTitle) · \(player.hero.name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if player.isSelf {
                Text("You").font(.caption).foregroundStyle(.secondary)
            } else if alreadyFriend || player.isFriend {
                Label("Friends", systemImage: "checkmark").font(.caption).foregroundStyle(Color.brandGreen)
            } else {
                Button("Add", action: onAdd).buttonStyle(.bordered)
            }
        }
    }
}

struct FriendRow: View {
    let friend: Friend

    var body: some View {
        HStack(spacing: 10) {
            AvatarBadgeView(config: nil, level: friend.level, cosmetic: friend.cosmetic,
                            size: 32, tint: FitnessProfile.rankColor(for: friend.level))

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
    var hasPointToSpend = true
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
                Text(hasPointToSpend ? "You have a talent point to spend." : "New rank, same grind. Keep climbing.")
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

// MARK: - Cosmetic helpers

extension String {
    /// Human-readable name for an aura cosmetic ("aura_gold" → "Gold Aura").
    var auraDisplayName: String {
        guard hasPrefix("aura_") else {
            return replacingOccurrences(of: "_", with: " ").capitalized
        }
        return dropFirst("aura_".count).replacingOccurrences(of: "_", with: " ").capitalized + " Aura"
    }

    var auraColor: Color {
        switch self {
        case "aura_iron":    return Color(red: 0.7, green: 0.7, blue: 0.8)
        case "aura_mist":    return Color(red: 0.6, green: 0.8, blue: 0.9)
        case "aura_chalk":   return Color(red: 0.9, green: 0.9, blue: 0.95)
        case "aura_ember":   return Color.brandOrange
        case "aura_crimson": return Color(red: 1.0, green: 0.2, blue: 0.2)
        case "aura_verdant": return Color(red: 0.2, green: 0.8, blue: 0.4)
        case "aura_violet":  return Color(red: 0.8, green: 0.4, blue: 0.9)
        case "aura_gold":    return Color.brandYellow
        // Season auras — same hex values as _lib/seasons.js on the server.
        case "aura_dawn":     return Color(hex: 0xFFB347)
        case "aura_daybreak": return Color(hex: 0xFF7A45)
        case "aura_frost":    return Color(hex: 0x8FD3FF)
        case "aura_glacier":  return Color(hex: 0x4A90E2)
        case "aura_storm":    return Color(hex: 0x7B8CDE)
        case "aura_thunder":  return Color(hex: 0xFFE066)
        case "aura_sprout":   return Color(hex: 0x7ED957)
        case "aura_grove":    return Color(hex: 0x2E8B57)
        case "aura_cinder":   return Color(hex: 0xFF6B3D)
        case "aura_inferno":  return Color(hex: 0xD7263D)
        case "aura_star":     return Color(hex: 0xC7B8FF)
        case "aura_nova":     return Color(hex: 0xF5E663)
        case "":             return Color.clear
        default:             return Color.brandPurple   // season and future auras
        }
    }
}

extension Color {
    /// 0xRRGGBB, matching the server's "#RRGGBB" palette entries.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
