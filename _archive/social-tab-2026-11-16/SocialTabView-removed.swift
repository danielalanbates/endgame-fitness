// Archived 2026-11-16: the Social tab was folded into Community.
// SocialSection/SocialTabView: replaced by Community sections (Rivals, Gym Party, Game Center, Share).
// SocialFeedPane: duplicate of Community > Feed (local feed); rival events moved to Rivals > Rival activity.

enum SocialSection: String, CaseIterable, Identifiable {
    case rivals = "Rivals"
    case party = "Gym Party"
    case gameCenter = "Game Center"
    case share = "Share"
    case feed = "Feed"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .rivals:     return "person.2.wave.2.fill"
        case .party:      return "dot.radiowaves.left.and.right"
        case .gameCenter: return "gamecontroller.fill"
        case .share:      return "square.and.arrow.up"
        case .feed:       return "bolt.horizontal.fill"
        }
    }
}

struct SocialTabView: View {
    @ObservedObject private var game = GameProfileService.shared
    @ObservedObject private var rivals = RivalStore.shared
    @State private var section: SocialSection = {
        #if DEBUG
        if let v = RootView.debugArg("-ef.social"), let s = SocialSection(rawValue: v) { return s }
        #endif
        return .rivals
    }()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(SocialSection.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Divider()
            ScrollView {
                Group {
                    switch section {
                    case .rivals:     RivalsPane()
                    case .party:      GymPartyPane()
                    case .gameCenter: GameCenterPane()
                    case .share:      SharePane()
                    case .feed:       SocialFeedPane()
                    }
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.platformWindowBackground)
        .onAppear { rivals.reload() }
        .onChange(of: LocalPlayerStore.shared.currentID) { _, _ in rivals.reload() }
    }
}

// MARK: - Feed

struct SocialFeedPane: View {
    @ObservedObject private var game = GameProfileService.shared
    @ObservedObject private var rivals = RivalStore.shared

    private struct Row: Identifiable { let id: String; let at: Date; let symbol: String; let text: String; let tint: Color }

    private var rows: [Row] {
        let local = game.feed.map {
            Row(id: "h-\($0.id)", at: Date(timeIntervalSince1970: TimeInterval($0.createdAt)), symbol: "house.fill", text: "\($0.displayName): \($0.summary)", tint: .brandPurple)
        }
        let social = rivals.events.map {
            Row(id: "r-\($0.id)", at: Date(timeIntervalSince1970: TimeInterval($0.at)), symbol: $0.symbol, text: $0.text, tint: .brandOrange)
        }
        return (local + social).sorted { $0.at > $1.at }
    }

    var body: some View {
        SocialCard(title: "Feed", symbol: "bolt.horizontal.fill") {
            if rows.isEmpty { Text("Nothing yet. Train, add rivals, or start a Gym Party.").foregroundStyle(.secondary) }
            ForEach(rows.prefix(100)) { row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.symbol).foregroundStyle(row.tint).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.text)
                        Text(row.at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .task { await game.loadFeed() }
    }
}
